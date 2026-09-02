# Python REST Tool Adapter

> 所属阶段：第 9 阶段（Java 业务服务集成增强线）
> 预计 5 小时｜目标：把第 2 章的 Java API 安全映射为 Agent Tool，模型只看到"工具"，看不到"裸 HTTP"。

## 1. 本章从哪里开始

第 2 章在 Java 侧守住了安全边界（鉴权、租户隔离、错误契约、乐观锁）。但 Python Agent 侧的三个工具 `search_manual`/`get_alarm`/`create_work_order_draft` 现在还不能直接调用 Java——它们要么还用着内存 Fake，要么把裸 HTTP 细节漏进了工具逻辑。

本章在 Python 侧加一层 **REST Tool Adapter**，职责是：把"模型能理解的工具"翻译成"Java 能执行的 HTTP 请求"，再把 Java 的结构化结果翻译回"模型能消费的安全摘要"。核心约束只有一条：**模型永远不能设置 `Authorization`、租户、内部 URL 或幂等策略。**

完成后你应该能回答：

1. Tool Schema 和 REST DTO 为什么不能直接等同？中间要映射什么？
2. 身份与租户从哪里来，为什么不由模型填写？
3. Java 返回 500 时，Tool 应该返回空列表吗？为什么？

## 2. 本章完成标准（通过门槛）

必须同时满足：

- `BusinessServicePort` 有 Fake 与 HTTP 两个实现，跑**同一组契约测试**行为一致；
- 身份（`user_id`/`tenant_id`/`scopes`）来自 `AgentContext`，模型无法通过参数篡改；
- 错误分类覆盖 401/403/404/409/422/429/5xx，并映射为 Python 侧 `E_*`；
- 只对可重放读取做有限重试，写请求依赖幂等键，不盲目重试；
- `traceparent`/`request_id` 透传，Python 内部 Prompt 不传给 Java。

达不到"Fake/HTTP 行为一致"，说明 Adapter 把 HTTP 细节漏进了工具逻辑，先抽端口。

## 3. 适配层职责与架构

架构一句话：

```text
Agent Tool -> Application Port -> JavaApiAdapter -> HTTP -> Java
                 FakeAdapter ---------------^
```

`Application Port` 是 Python 内部定义业务能力接口（`BusinessServicePort`），工具只依赖它，不依赖 httpx 或 URL。两个实现可互换：

| 实现 | 用途 |
| --- | --- |
| `FakeAdapter` | 离线契约测试、评测、CI，不联网 |
| `JavaApiAdapter` | 线上真实调用，httpx 客户端 |

Adapter 的六项职责：字段映射、认证、超时、错误分类、响应校验、脱敏与 Trace Header 传递。任何一项漏掉，都会把"外部服务的复杂度"泄露给 Agent 层。

## 4. Tool Schema 与 REST DTO 的分离

模型看到的工具 Schema 与 Java 的 DTO 不是一回事：

```python
# 面向模型的 Tool Schema（精简、稳定、可被模型理解）
class GetAlarmInput(BaseModel):
    equipment_id: str  # 模型只填业务意图

# 面向 Java 的 REST DTO（含租户、分页、追踪等横切字段）
class AlarmQueryRequest(BaseModel):
    equipment_id: str
    status: str = "ACTIVE"
    # tenant_id 等横切字段由 Adapter 注入，不来自模型
```

字段映射发生在 Adapter 内，不在工具内：

```python
class BusinessServicePort(Protocol):
    def get_alarms(self, ctx: AgentContext, equipment_id: str) -> AlarmResult: ...
    def create_draft(self, ctx: AgentContext, draft: DraftInput) -> DraftResult: ...
```

关键原则：**横切字段（租户、Trace、身份）由 Adapter 从 Runtime Context 注入，工具入参只保留模型该填的业务意图字段。** 这样模型既看不到也改不了安全上下文。

## 5. 身份与用户上下文注入

身份来源是本章的红线。`AgentContext` 是冻结 dataclass，只能由已验证 Token 的 API 层创建：

```python
@dataclass(frozen=True)
class AgentContext:
    user_id: str
    tenant_id: str
    scopes: frozenset[str]
    request_id: str
```

Adapter 从 `ctx` 取身份，映射到 Java 的鉴权头：

```python
class JavaApiAdapter:
    def __init__(self, base_url: str, token_exchange: TokenExchange):
        self._client = httpx.AsyncClient(base_url=base_url, timeout=10.0)
        self._token_exchange = token_exchange

    async def get_alarms(self, ctx: AgentContext, equipment_id: str) -> AlarmResult:
        headers = self._build_headers(ctx)
        r = await self._client.get(
            f"/api/v1/equipments/{equipment_id}/alarms",
            params={"status": "ACTIVE"},
            headers=headers,
        )
        return self._map_response(r)

    def _build_headers(self, ctx: AgentContext) -> dict[str, str]:
        # 服务身份或受控 Token Exchange，绝不是模型 Token 原样透传
        token = self._token_exchange.for_user(ctx.user_id, ctx.tenant_id)
        return {
            "Authorization": f"Bearer {token}",
            "X-User-Id": ctx.user_id,
            "traceparent": traceparent_for(ctx.request_id),
            "request_id": ctx.request_id,
        }
```

三条硬规则：

- 模型不能设置 `Authorization`、租户、内部 URL 或幂等策略；
- 服务身份/用户委托身份由 Adapter 从 Runtime Context 获取；
- 服务间调用**不默认原样透传用户 Token**，采用明确的服务身份或受控 Token Exchange，校验 Audience 与最小 Scope。

## 6. 错误分类与 E_* 映射

Java 的结构化错误（第 2 章 §6）要映射为 Python 侧 `E_*`，不能原样抛给模型：

```python
def _map_http_error(status: int, body: dict) -> ToolError:
    code = body.get("code")
    table = {
        401: "E_FORBIDDEN",
        403: "E_FORBIDDEN",
        404: "E_NOT_FOUND",
        409: "E_CONFLICT",
        422: "E_INVALID_ARGUMENT",
        429: "E_UPSTREAM_RATE_LIMITED",
    }
    if status in table:
        return ToolError(table[status], safe_message(body))
    if status >= 500:
        return ToolError("E_UPSTREAM_TIMEOUT" if is_timeout(body) else "E_INTERNAL_ERROR", safe_message(body))
    return ToolError("E_INTERNAL_ERROR", "upstream error")
```

重试策略分级（与主线副作用分级一致）：

| 请求类型 | 可重试？ | 依据 |
| --- | --- | --- |
| 可重放读取（GET 无副作用） | 有限重试 + 退避 | 幂等天然 |
| 写请求（POST） | 不盲目重试 | 依赖幂等键，第 4 章 |
| 429 | 按 Retry-After 限速重试 | 保护上游 |

**绝不把依赖失败伪装成"无数据"**——Java 500 时返回空列表是灾难，模型会以为"没有告警"而给出错误结论。

## 7. Trace 透传与脱敏

跨服务 Trace 用 W3C Trace Context 贯通，字段对齐主线观测：

```text
trace_id, tenant_id, run_id, task_id, request_id
logical_model, provider, tool_name
input/output tokens, latency, status
```

规则：

- 转发 `traceparent`、`request_id`，Java 日志与 Python Trace 能串联；
- **不把 Python 内部 Prompt 传给 Java**——Java 只需要业务入参与身份，不需要你的 system prompt；
- 工具参数、结果、Prompt 可能含敏感数据，默认不导出正文，日志脱敏。

## 8. Fake 与 HTTP 契约一致

Fake 与 HTTP 跑同一组契约测试，是本章验收的核心证据：

```python
async def test_get_alarm_contract(adapter: BusinessServicePort, ctx: AgentContext):
    result = await adapter.get_alarms(ctx, "eq-turbine-09")
    assert result.equipment_id == "eq-turbine-09"
    assert all(a.status in {"ACTIVE", "RESOLVED"} for a in result.alarms)
```

契约测试覆盖四类场景：

1. 正常返回：字段映射正确、结果结构一致；
2. 字段新增：Java 多返回一个字段，Fake/HTTP 都不崩（向后兼容）；
3. 字段缺失：必需字段缺失，两者都返回校验错误而非静默；
4. 慢响应与 409：超时归 `E_UPSTREAM_TIMEOUT`，冲突归 `E_CONFLICT`。

OpenAPI 生成/校验客户端能减少手写漂移，但**领域错误仍要显式映射**，不能靠"HTTP 200 就成功"判断。

## 9. 项目任务

1. 定义 `BusinessServicePort`（`get_alarms`/`create_draft`），工具只依赖该端口；
2. 实现 `FakeAdapter` 与 `JavaApiAdapter`（httpx，超时、Token Exchange、Trace 头）；
3. 写错误分类函数，覆盖 401/403/404/409/422/429/5xx 到 `E_*` 的映射；
4. 跑同一组契约测试，模拟字段新增、缺失、Java 慢响应和 409；
5. 写越权注入测试：模型在参数里塞 `tenant_id`，断言最终数据仍落在 `ctx.tenant_id` 范围内。

## 10. 常见错误与诊断顺序

### 10.1 Java 返回 500，Tool 返回空列表

现象：上游挂了，模型收到空告警列表，以为真没告警。**先查**：`_map_http_error` 是否把 5xx 映射成结构化错误而非空结果？**不要先做**：在工具里 `try/except` 后 `return []`——这会把"依赖失败"伪装成"无数据"。

### 10.2 模型参数里出现了 `tenant_id`

现象：工具入参 Schema 暴露了 `tenant_id` 字段，模型能填。**先查**：横切字段是否从 Tool Schema 移除、由 Adapter 从 `ctx` 注入？**不要先做**：在 Prompt 里写"不要填 tenant_id"——软约束挡不住注入。

### 10.3 服务间原样透传用户 Token

现象：Python 把用户 Token 直接转发给 Java。**先查**：是否用了受控 Token Exchange？Audience 与最小 Scope 是否校验？**不要先做**：默认透传——一旦 Python 与 Java 的 Token 边界被混用，权限面会扩大。

### 10.4 写请求超时后盲目重试

现象：超时后无脑重试 POST，可能重复建单。**先查**：写请求是否带幂等键、超时是否落"未知结果"查询而非重试？**不要先做**：把写请求当读请求一样重试（详见第 4 章）。

## 11. 练习题与答案

### 练习 1：Java 返回 500 时 Tool 应返回空列表吗？

**答案：**不应把依赖失败伪装为"无数据"。返回结构化不可用错误（`E_UPSTREAM_TIMEOUT`/`E_INTERNAL_ERROR`），Graph 决定降级或终止，而不是让模型误判。

### 练习 2：服务间调用需要用户 Token 原样透传吗？

**答案：**取决于安全架构，但不能默认透传。应采用明确的服务身份或受控 Token Exchange，校验 Audience 与最小 Scope，避免权限面被扩大。

### 练习 3：Tool Schema 能不能直接用 Java 的 DTO？

**答案：**不能。Tool Schema 面向模型，只含业务意图字段；REST DTO 含租户、分页、追踪等横切字段。二者通过 Adapter 做字段映射，横切字段由 Runtime Context 注入。

### 练习 4：为什么写请求超时不能盲目重试？

**答案：**因为写请求可能已经在 Java 侧成功，只是响应丢失；盲目重试会导致重复建单。正确做法是依赖幂等键，超时后用同 Key 查询或重试（见第 4 章）。

## 12. 工程挑战

1. 写字段漂移测试：Java 响应新增一个字段、缺失一个必需字段，断言 Fake/HTTP 两者行为一致（前者兼容、后者报错）；
2. 写越权注入测试：模型工具入参里带 `tenant_id=B`，断言 Adapter 仍用 `ctx.tenant_id=A` 构造请求，Java 侧数据落在 A 的范围内；
3. 写慢响应测试：用 httpx 的 Mock Transport 模拟超时，断言归为 `E_UPSTREAM_TIMEOUT` 且不重试写请求。

参考方向：字段漂移测试用 Pydantic 校验响应；越权注入测试断言 `_build_headers` 的 `X-User-Id` 来自 `ctx`；慢响应测试区分读（有限重试）与写（幂等键）。

## 13. 面试追问

### 13.1 "模型能直接调你们的 Java 接口吗？"

回答框架：不能。模型只通过 Tool 表达意图，Tool 依赖 `BusinessServicePort`；真正 HTTP 调用由 Adapter 完成，身份、租户、幂等策略由 Adapter 从 `AgentContext` 注入，模型既看不到也改不了。

### 13.2 "你们怎么处理上游 500？"

回答框架：5xx 映射为 `E_UPSTREAM_TIMEOUT` 或 `E_INTERNAL_ERROR` 结构化错误，Graph 决定降级或终止；绝不返回空列表伪装"无数据"。读请求有限重试，写请求依赖幂等键。

### 13.3 "Fake 和真实 HTTP Adapter 怎么保证一致？"

回答框架：两者实现同一个 `BusinessServicePort`，跑同一组契约测试，覆盖字段新增、缺失、慢响应、409；工具只依赖端口，不感知 HTTP 细节，所以换实现不改工具。

## 14. 本章复盘模板

```text
完成日期：
实际投入小时：
BusinessServicePort 是否有 Fake 与 HTTP 两个实现且契约测试一致：
身份/租户是否来自 AgentContext（模型无法篡改）：
401/403/404/409/422/429/5xx 是否映射为 E_*：
读请求是否有限重试、写请求是否依赖幂等键（不盲目重试）：
traceparent/request_id 是否透传、Python Prompt 是否不外泄：
Java 500 是否不返回空列表：
仍不理解的问题：
```

## 15. 官方资料与中文阅读指引

- [HTTPX Clients](https://www.python-httpx.org/advanced/clients/)：`AsyncClient`、超时、Mock Transport 的官方口径，用于第 3/8 节的 HTTP Adapter；
- [OpenAPI 规范](https://spec.openapis.org/oas/latest.html)：用于生成/校验客户端、减少手写漂移，用于第 8 节契约测试；
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)：`traceparent` 透传规范，用于第 7 节 Trace 贯通；
- [Pydantic](https://docs.pydantic.dev/)：Tool Schema 与响应校验的官方口径，用于第 4/6 节字段映射与错误分类。

重点阅读：HTTPX 的 `AsyncClient` 与 Mock Transport（对应 Fake/HTTP 契约测试）与 W3C Trace Context（对应跨服务 Trace）；具体 httpx/Pydantic 版本细节以锁定版本官方文档为准。

## 16. 下一章入口

本章把 Java API 安全包装成 Agent Tool，模型只看到工具、看不到裸 HTTP，身份与租户由 Adapter 注入。下一章进入第 4 章，解决 Adapter 之外最棘手的跨服务问题：**幂等、事务与跨服务失败**——重复写、超时未知结果、重试风暴与补偿。

**关键闸门**：如果 Java 500 还返回空列表，说明第 6 节错误分类没过关，**先修错误映射再谈幂等**。因为第 4 章的"超时未知结果"处理，前提是第 3 章已经能把超时与冲突识别成不同错误，而不是一把抓成"失败"。
