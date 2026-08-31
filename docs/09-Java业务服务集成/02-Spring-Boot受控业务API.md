# Spring Boot 受控业务 API

> 预计 7 小时｜产出：设备/告警查询与工单草稿/提交 API。

## 1. 最小 API

```text
GET  /api/v1/equipments/{id}
GET  /api/v1/equipments/{id}/alarms?status=ACTIVE
POST /api/v1/work-order-drafts
POST /api/v1/work-orders
GET  /api/v1/idempotency/{key}
```

Controller 只做协议与验证，Application Service 负责用例和事务，Domain 执行业务规则，Repository 持久化。DTO 不直接暴露 JPA Entity。

## 2. 权限与校验

Resource Server 校验签名、`iss/exp/aud`，再把 Scope/Role 映射到方法权限。`tenant_id` 来自可信 Claim 并与资源关联，不能由 JSON 任意指定。工单提交验证：草稿存在、未过期、设备状态未失效、审批人与动作摘要匹配。

使用 Bean Validation 做长度/枚举，数据库使用主外键、唯一索引和乐观锁。错误统一为 `code/message/request_id/details`，不返回堆栈。

## 3. 项目任务

用 H2 或 SQLite 兼容方案本地运行，Flyway 管理迁移。实现上述 API、OpenAPI、`@WebMvcTest`/集成测试；无需 Docker。

## 4. 练习与答案

### 练习 1：JWT 验签通过是否代表能访问任意设备？

**答案：**不是。认证只确认身份，还要校验 Audience、Scope/Role、租户与资源级权限。

### 练习 2：为什么 DTO 与 Entity 分离？

**答案：**避免持久化结构、延迟加载和内部字段泄露到 API，也便于契约独立演进。

## 5. 验收与资料

越权请求 403；非法输入 4xx；并发更新有冲突语义。参考 [Spring Boot Testing](https://docs.spring.io/spring-boot/reference/testing/)、[Spring Security JWT](https://docs.spring.io/spring-security/reference/servlet/oauth2/resource-server/jwt.html)、[Validation](https://docs.spring.io/spring-framework/reference/core/validation/beanvalidation.html)。

