# Spring Boot 受控业务 API

> 所属阶段：第 9 阶段（Java 业务服务集成增强线）
> 预计 7 小时｜目标：用 Spring Boot 3.x（Java 17/21）产出设备/告警查询与工单草稿/提交的最小受控 API。

## 1. 本章从哪里开始

第 1 章定了边界：Python 管编排与生成，Java 管业务真相。本章把边界落成**最小可运行的 Spring Boot 业务服务**——只做设备、告警、工单、审批四类确定性规则，不讲普通 Java 基础，不写第二套 Agent。

上一章的时间线结论是"保留 Python 主线"，所以本章 Java 侧的定位很克制：**Controller 只做协议与验证，Application Service 负责用例和事务，Domain 执行业务规则，Repository 持久化。** 这套分层不是为了显得"规范"，而是为了让"确定性业务规则"有唯一落点。

完成后你应该能回答：

1. 一个写接口从 HTTP 到数据库要经过哪几层？每层各自拒绝什么？
2. `tenant_id` 为什么不能由 JSON 指定，只能来自可信 Claim？
3. 为什么 DTO 不直接暴露 JPA Entity？

## 2. 本章完成标准（通过门槛）

必须同时满足：

- 下述 5 个接口全部实现并可通过 `@WebMvcTest` 与集成测试；
- 越权请求返回 403，非法输入返回 4xx，并发更新有冲突语义；
- 错误统一为 `code/message/request_id/details`，不返回堆栈；
- `tenant_id` 来自可信 Claim 并与资源关联，JSON 传 `tenant_id` 不生效；
- 用 H2 或 SQLite 兼容方案本地运行，Flyway 管理迁移，无需 Docker。

达不到"越权 403 + 非法 4xx"，说明边界还没坐实，先修鉴权再谈功能。

## 3. 最小 API 契约

对齐第 1 章第 8 节，暴露 5 个接口，逐个对应 Python 工具：

```text
GET  /api/v1/equipments/{id}                     # search_manual 之外的设备查询，只读
GET  /api/v1/equipments/{id}/alarms?status=ACTIVE # get_alarm 对应
POST /api/v1/work-order-drafts                    # create_work_order_draft 对应
POST /api/v1/work-orders                          # 工单草稿提交（不可逆写）
GET  /api/v1/idempotency/{key}                    # 幂等键查询（第 4 章展开）
```

请求/响应示例（工单草稿）：

```json
POST /api/v1/work-order-drafts
Idempotency-Key: wk-20260902-0001
X-User-Id: u-001

{
  "equipmentId": "eq-turbine-09",
  "title": "A 工厂 3 号汽轮机轴承温度偏高",
  "summary": "建议更换润滑油并复查传感器",
  "approverId": "u-099"
}
```

```json
{
  "code": "OK",
  "request_id": "req-9-0001",
  "data": {
    "work_order_id": "wo-20260902-0001",
    "status": "DRAFT"
  }
}
```

注意 `X-User-Id` 只是示例头名，实际以鉴权方案为准；身份绝不能从请求体里读。

## 4. 分层与代码骨架

四层各自拒绝什么，比类名更重要：

| 层 | 职责 | 拒绝什么 |
| --- | --- | --- |
| Controller | 协议解析、DTO 校验、调用 Service | 业务规则、事务、SQL |
| Application Service | 用例编排、事务边界 | 协议细节、SQL |
| Domain | 业务规则、状态机、不变量 | 持久化细节、HTTP |
| Repository | 持久化、查询 | 业务规则、HTTP |

最小 Controller（Spring Boot 3.x，`record` + 构造注入）：

```java
@RestController
@RequestMapping("/api/v1/equipments")
public class EquipmentController {
    private final EquipmentQueryService queryService;

    public EquipmentController(EquipmentQueryService queryService) {
        this.queryService = queryService;
    }

    @GetMapping("/{id}/alarms")
    public ApiResponse<List<AlarmView>> listAlarms(
            @PathVariable String id,
            @RequestParam(defaultValue = "ACTIVE") String status,
            Principal principal) {
        Tenant tenant = TenantPrincipal.from(principal); // 见 §5，绝不由参数决定
        return ApiResponse.ok(queryService.listAlarmsForTenant(tenant, id, status));
    }
}
```

Application Service 是唯一的事务边界与用例入口：

```java
@Service
public class WorkOrderApplicationService {
    private final WorkOrderRepository repository;
    private final EquipmentQueryService equipmentQuery;

    @Transactional
    public WorkOrderDraft createDraft(CreateDraftCommand cmd, Tenant tenant, String idempotencyKey) {
        equipmentQuery.requireActive(cmd.equipmentId(), tenant);
        // 幂等占用见第 4 章，这里先保留接口
        return repository.saveDraft(WorkOrderDraft.create(cmd, tenant, idempotencyKey));
    }
}
```

DTO 与 Entity 分离：`WorkOrderDraft`（领域对象）与 `WorkOrderDraftDto`（API 契约）是两个类型，互不直接暴露。

> Spring Boot 3.x 的 `@RestController`、构造注入、`record`、`@Transactional` 等 API 均为稳定用法，具体版本细节（如 `jakarta.*` 命名空间、`Principal` 类型）以锁定版本官方文档为准。

## 5. 权限与校验

鉴权是本章最容易写错的地方，三条硬规则：

1. **认证 ≠ 授权**：JWT 验签通过只证明"你是谁"，不证明"你能访问任意设备"；
2. **`tenant_id` 只来自可信 Claim**：Resource Server 校验 `iss/exp/aud` 后，把 Scope/Role 映射到方法权限，`tenant_id` 从 Token 的受信任声明里取，再与资源关联——**不能由 JSON 任意指定**；
3. **工具内二次授权**：即使 Java API 层做了方法级鉴权，Python 侧 Tool 内部仍要做 scope 检查（纵深防御，对应第 3 章）。

校验分三层：

```text
Bean Validation（长度/枚举/非空）
  → Domain 不变量（状态机、唯一约束）
  → DB 约束（主外键、唯一索引、乐观锁 @Version）
```

工单提交时验证：草稿存在、未过期、设备状态未失效、审批人与动作摘要匹配。任何一条不满足都返回明确错误码，而不是静默通过。

## 6. 错误契约

Java 侧错误统一为结构化 JSON，与 Python 侧 `E_*` 对齐（第 3 章做映射）：

```json
{
  "code": "E_NOT_FOUND",
  "message": "设备不存在或对当前租户不可见",
  "request_id": "req-9-0001",
  "details": {}
}
```

规则：

- 不返回堆栈、SQL、内部类名（`details` 只放非敏感的业务字段）；
- 401/403/404/409/422/429/5xx 分类清晰，错误码与 HTTP 状态一一映射；
- `E_CONFLICT` 用于乐观锁冲突、`E_FORBIDDEN` 用于越权、`E_NOT_FOUND` 不枚举其他租户是否存在（防止探测）。

```java
@ExceptionHandler(EquipmentNotFoundException.class)
public ResponseEntity<ApiResponse<Void>> handleNotFound(EquipmentNotFoundException e) {
    return ResponseEntity.status(404).body(ApiResponse.error("E_NOT_FOUND", e.getSafeMessage(), requestId()));
}
```

## 7. 工单提交：不可逆写的边界

`POST /api/v1/work-orders` 是本章唯一的不可逆写，规则最严：

```text
草稿存在 + 未过期
  → 设备状态未失效
  → 审批人匹配动作摘要
  → 幂等键占用（第 4 章）
  → 状态 DRAFT → SUBMITTED（乐观锁 @Version 防并发）
```

若草稿状态不是 `DRAFT`（已提交/已撤销），返回 `E_CONFLICT` 而不是覆盖写；这是第 1 章"可逆写 vs 不可逆写"边界的直接体现。

## 8. 项目任务

1. 用 Spring Boot 3.x（Java 17/21）+ H2（或 SQLite 兼容方案）+ Flyway 搭建最小服务，无需 Docker；
2. 实现第 3 节 5 个接口，DTO 与 Entity 分离，四层职责各就各位；
3. 接入 JWT/Mock Auth 的 Resource Server 校验，`tenant_id` 从 Claim 取，JSON 指定不生效；
4. 写 `@WebMvcTest`（Controller 层）+ 集成测试（含越权 403、非法 4xx、并发乐观锁冲突）；
5. 生成 OpenAPI 文档，供第 3 章 Adapter 做契约校验。

## 9. 常见错误与诊断顺序

### 9.1 越权请求返回 200 而不是 403

现象：租户 A 能查到租户 B 的设备。**先查**：查询条件有没有强制带 `tenant_id`？`tenant_id` 是从 Claim 取的还是从 JSON 取的？**不要先做**：加更多 if 判断，而没从根上切断"JSON 指定租户"的路径。

### 9.2 错误响应把堆栈发给前端

现象：500 错误里带了 `at com.example...` 堆栈。**先查**：全局异常处理器是否兜住所有异常？`details` 是否只放非敏感字段？**不要先做**：只给 Controller 局部 try/catch，漏了 Service 层抛出的异常。

### 9.3 DTO 直接返回 JPA Entity

现象：接口返回了带 `@OneToMany` 懒加载的 Entity，触发序列化报错或泄露内部字段。**先查**：是否在 Controller 返回 Entity？**不要先做**：在 Entity 上加 `@JsonIgnore` 到处打补丁——正确做法是 DTO 与 Entity 分离。

### 9.4 并发提交把同一草稿提交两次

现象：两个请求同时提交，状态都变成 `SUBMITTED`。**先查**：有没有 `@Version` 乐观锁？状态迁移有没有在事务内用带版本号的条件更新？**不要先做**：加粗粒度锁把并发直接挡掉——先看乐观锁是否生效。

## 10. 练习题与答案

### 练习 1：JWT 验签通过是否代表能访问任意设备？

**答案：**不是。认证只确认身份，还要校验 Audience、Scope/Role、租户与资源级权限。验签通过只是第一道门，授权是独立的第二道门。

### 练习 2：为什么 DTO 与 Entity 分离？

**答案：**避免持久化结构、延迟加载和内部字段泄露到 API，也便于契约独立演进。Entity 随表结构变，DTO 随 API 契约变，二者不该绑定。

### 练习 3：`tenant_id` 为什么不能放进请求 JSON？

**答案：**JSON 是客户端（可能被模型或用户篡改）提供的不可信数据；租户是安全边界，必须来自 Resource Server 校验后的可信 Claim，否则任何客户端都能伪装成别的租户。

### 练习 4：工单草稿已提交，再调用提交接口应该怎样？

**答案：**返回 `E_CONFLICT`，而不是覆盖写或静默成功。提交是不可逆写，状态迁移必须在事务内用乐观锁保证，冲突要被显式暴露。

## 11. 工程挑战

1. 写一个跨租户越权测试：租户 A 的 Token 请求租户 B 的设备告警，断言返回 403 且不泄露"设备是否存在"；
2. 用 `@WebMvcTest` 只测 Controller 层：Mock Service，断言 DTO 校验失败时返回 4xx 且错误码正确；
3. 用 `@Version` 乐观锁写并发提交测试：两个线程同时提交同一草稿，断言只有一个成功、另一个 `E_CONFLICT`。

参考方向：越权测试的核心是断言"资源级权限"而非只断言"有 Token"；并发测试用两个事务同时读同一版本号，其中一个更新时版本号不匹配而失败。

## 12. 面试追问

### 12.1 "你们的 Java 服务怎么保证租户隔离？"

回答框架：`tenant_id` 来自 Resource Server 校验后的可信 Claim，绝不从 JSON 取；所有查询在 Application Service 层强制带上租户条件；工具侧再做二次 scope 检查，形成纵深防御。

### 12.2 "为什么分 Controller/Service/Domain/Repository 四层？"

回答框架：四层各自拒绝一类错误——Controller 拒绝协议细节混入业务，Service 是唯一事务边界，Domain 是确定性规则的唯一落点，Repository 隔离持久化。分层是为了让"业务规则"有唯一归属，而不是为了显得规范。

### 12.3 "DTO 和 Entity 怎么不泄露？"

回答框架：DTO 是 API 契约，Entity 是持久化结构，两者独立演进；Controller 只返回 DTO，序列化不触碰 Entity 的懒加载与内部字段；错误响应不返回堆栈与内部类名。

## 13. 本章复盘模板

```text
完成日期：
实际投入小时：
5 个接口是否全部实现并通过 @WebMvcTest 与集成测试：
越权是否返回 403、非法输入是否返回 4xx：
tenant_id 是否只来自可信 Claim（JSON 指定不生效）：
DTO 与 Entity 是否分离、错误是否不返回堆栈：
并发提交是否有乐观锁冲突语义：
是否用 Flyway + H2/SQLite 本地运行（无需 Docker）：
仍不理解的问题：
```

## 14. 官方资料与中文阅读指引

- [Spring Boot Reference](https://docs.spring.io/spring-boot/reference/)：本阶段 Java 侧权威入口，重点看 Web、Data、测试三部分；
- [Spring Boot Testing](https://docs.spring.io/spring-boot/reference/testing/)：`@WebMvcTest`、集成测试的官方口径，用于第 8 节测试任务；
- [Spring Security JWT](https://docs.spring.io/spring-security/reference/servlet/oauth2/resource-server/jwt.html)：Resource Server 校验 `iss/exp/aud` 与 Claim 的权威文档，用于第 5 节鉴权；
- [Bean Validation](https://docs.spring.io/spring-framework/reference/core/validation/beanvalidation.html)：DTO 校验的官方口径，用于第 5 节校验三层。

重点阅读：Spring Security JWT 的 Resource Server 部分（对应鉴权与 `tenant_id` 来源）与 Spring Boot Testing 的 `@WebMvcTest`（对应 Controller 测试）；具体注解与版本细节以锁定版本的官方文档为准，不凭记忆写 API。

## 15. 下一章入口

本章把边界落成 5 个受控接口，坐实了设备/告警查询与工单草稿/提交的确定性规则。下一章进入第 3 章，把 Java API **安全映射为 Python Agent 的 Tool Adapter**——字段映射、认证、超时、错误分类、脱敏与 Trace 透传，让模型只看到"工具"，看不到"裸 HTTP"。

**关键闸门**：如果越权请求还能返回 200，说明第 5 节的租户隔离没过关，**先修鉴权再谈 Adapter**。因为第 3 章 Adapter 的一切努力，都建立在"Java 侧已经把安全边界守住"的前提之上。
