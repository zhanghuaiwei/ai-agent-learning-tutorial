# Middleware 与运行时控制

> 所属阶段：第 4 阶段（LangChain 与单 Agent），预计用时：7 小时
> 项目产出：四个 Middleware（注入 Prompt 版本、按角色过滤工具、超 Token 预算裁剪上下文、记录模型调用费用）+ Hook 顺序集成测试。
> 资料验证日期：2026-09-02

## 1. 本章从哪里开始

第 3 章已经交付了「用 `create_agent` 跑通设备查询单 Agent」。本章把原本散落在 Agent 内外的横切策略（身份解析、工具白名单、上下文裁剪、模型路由、费用观测）收敛到 Middleware 这个统一入口。

| 第 3 章交付物 | 本章承接 |
| --- | --- |
| `create_agent(model, tools=[...], context_schema=AgentContext, response_format=ToolStrategy(AgentAnswer), system_prompt=...)` | 给 `create_agent` 增加 `middleware=[...]`，在模型/工具调用前后插入横切策略 |
| `get_alarm(equipment_id, runtime: ToolRuntime[AgentContext])` | Middleware 从 `runtime.context` 读身份、过滤工具，不信任模型消息 |
| `AgentAnswer.status: Literal["answered","needs_input","refused"]` | Middleware 拦截/改造调用时，不破坏结构化输出契约 |
| `E_*` 错误码与 `ToolResult.code` | Middleware 内的重试/降级沿用同一错误分类，不另造一套 |

读完本章，你能回答：

1. Middleware 在模型/工具调用前后各能拦截什么？为什么 `before_*`、`after_*`、`wrap_*` 的执行顺序不是直觉的「全部从上到下」？
2. 为什么 `AgentContext` 必须由 API 层注入、工具和 Middleware 都从 `runtime.context` 读取，而不能由模型消息填充？
3. 模型路由、工具过滤、上下文裁剪各应放在哪个 Hook，为什么不能藏进复杂业务流程？
4. 把 `create_agent` 返回的 Agent 放进更大的 StateGraph 后，Middleware 还会执行吗？如何避免外层 Graph 与内层 Middleware 对同一调用重复重试？

## 2. 本章完成标准

- 四个 Middleware 全部落地，且各自有单元测试 + 一个顺序集成测试通过。
- 有一条集成测试用记录 Hook 名的 Fake Middleware 断言真实执行顺序：`before_*` 声明顺序、`after_*` 相反顺序、`wrap_*` 嵌套（靠前在外层）。
- `AgentContext` 的 `user_id/tenant_id/scopes/request_id` 无法被用户消息覆盖，伪造测试通过。
- 工具白名单过滤后，模型无法越权选择未授权工具（即使 Prompt 诱导也不行）。
- 费用只记录 Usage 并做异常增长告警，不设固定金额终止逻辑（教程费用治理约定）。
- 同一类错误不会被 HTTP Client、Middleware、Provider SDK 多层重复重试放大，重试所有者唯一。

## 3. Middleware 适用场景与推荐顺序

Middleware 在模型或工具调用前后执行横切策略：动态选模型、裁剪消息、注入运行时 Prompt、拦截 Tool Call、重试、记录指标、加入 Human-in-the-loop。它适合「每个请求都做、与业务主流程正交」的策略，不应藏入复杂业务流程。

推荐顺序（顺序本身是架构决策，应写测试）：

```text
请求身份解析 → 工具白名单 → 上下文裁剪 → 模型路由 → 调用 → 输出校验 → 脱敏观测与费用记录
```

- 身份解析最早：后续所有中间件都依赖 `AgentContext`，没有身份就谈不上白名单与裁剪。
- 白名单在裁剪之前：先过滤无权工具，再算 Token 预算，避免为永远用不到的工具留预算。
- 费用记录放最后：观测的是「最终实际发生的调用」，且必须在脱敏之后再落日志。

## 4. 运行时 Context：AgentContext 不可被模型篡改

Context 是本次运行中「由可信服务注入、模型无法篡改」的依赖。第 3 章已定下唯一命名 `AgentContext`（不是 RuntimeContext）：

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class AgentContext:
    user_id: str
    tenant_id: str
    scopes: frozenset[str]
    request_id: str
```

它由已经验证 Token 的 API 层构造，通过 `create_agent(context_schema=AgentContext)` 声明，调用时用 `agent.ainvoke(..., context=AgentContext(...))` 传入。用户消息不能覆盖这些字段——即使模型在对话里写出 `"我的 tenant_id 是 tenant-b"`，工具与 Middleware 读到的仍是注入值。

两条纪律：

- **身份只从 `runtime.context` 读**，不从消息正文解析。把身份当普通 State 字段、允许模型「帮忙填」，等于把权限交给不可信输入。
- **长期变化的业务状态从可信服务查询**，不要永久复制进 Prompt。Prompt 里固化的是「提示词版本 / 角色说明」这类不变上下文，而不是告警状态、审批结果这类会过期的数据。

## 5. 模型路由

用确定性规则先路由：普通问答选低延迟模型，复杂多工具规划选强模型。路由决策必须可解释、可评测：

- 路由规则记录原因（命中了哪条规则），进入 Trace，方便回溯。
- 用带标签的数据集评测「该走强模型却没走」和「该走弱模型却走了强模型」两类错误。
- 费用是**对比指标**（哪个路由组合更划算），不是模型禁用的触发条件；费用观测只在异常时告警，不做上限终止。

路由放 `wrap_model_call`：它能看到完整请求、用 `request.override(model=...)` 换模型，且作用域只在本次调用。

## 6. Hook 顺序与中间件模型

多个 Middleware 的执行不是简单地全部从上到下：

| Hook 类型 | 声明顺序为 `[A, B, C]` 时的执行 | 常见用途 |
| --- | --- | --- |
| `before_*` | A → B → C（声明顺序） | 校验、埋点、状态预更新 |
| `wrap_*` | 嵌套：A 在外层、C 在最内层（A 进 → B 进 → C 进 → handler → C 出 → B 出 → A 出） | 重试、缓存、请求/响应改写 |
| `after_*` | C → B → A（相反顺序） | 观测、费用记录、脱敏后落日志 |

关键推论：**「先脱敏再记录」和「先记录再脱敏」的结果完全不同**。因为 `after_model` 反序执行，想让「记录」发生在「脱敏」之后，必须把脱敏 Middleware 声明在记录 Middleware **前面**（反直觉，见第 8 节失败路径）。

不要靠读代码猜顺序，用记录 Hook 名的 Fake Middleware 跑集成测试断言（见第 7 节）。

Middleware 运行在 `create_agent` 返回的 LangGraph 内。把这个 Agent 放进更大的 StateGraph 作为节点或子图时，所有 Middleware Hook 仍会执行。此时要明确**重试边界**：外层 Graph 与内层 Middleware 不能对同一调用各自重试（见第 8 节）。

## 7. 可运行代码：四个 Middleware 落地

> 以下基于 LangChain 1.x 的 `AgentMiddleware`。具体 Hook 签名与 `override` 支持字段以官方文档为准。

### 7.1 自定义 Middleware 最小骨架

```python
from typing import Callable

from langchain.agents.middleware import (
    AgentMiddleware,
    AgentState,
    ModelRequest,
    ModelResponse,
)


class MinimalMiddleware(AgentMiddleware):
    # 可选类属性：state_schema 扩展状态、tools 附带额外工具、transformers 注册流转换器
    def before_model(self, state: AgentState, runtime) -> dict | None:
        return None  # 返回 dict 会合并进 state，None 表示不更新

    def after_model(self, state: AgentState, runtime) -> dict | None:
        return None

    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelResponse:
        return handler(request)
```

`before_model/after_model` 是 node 风格 Hook（顺序执行）；`wrap_model_call/wrap_tool_call` 是环绕 Hook（可决定 `handler` 调用零次、一次或多次）。异步版本以 `a` 前缀命名（如 `abefore_model`），以官方文档为准。

### 7.2 注入 Prompt 版本

```python
from langchain.agents.middleware import AgentMiddleware, ModelRequest, ModelResponse
from langchain.messages import SystemMessage


class PromptVersionMiddleware(AgentMiddleware):
    def __init__(self, version: str):
        self.version = version

    def wrap_model_call(
        self,
        request: ModelRequest,
        handler: Callable[[ModelRequest], ModelResponse],
    ) -> ModelResponse:
        block = {"type": "text", "text": f"\n[运行上下文] 提示词版本：{self.version}"}
        blocks = list(request.system_message.content_blocks) + [block]
        return handler(request.override(system_message=SystemMessage(content=blocks)))
```

### 7.3 按角色过滤工具

```python
SCOPE_TOOLS = {
    "equipment:read": {"get_alarm", "search_manual"},
    "workorder:write": {"create_work_order_draft"},
}


class RoleToolFilterMiddleware(AgentMiddleware):
    def wrap_model_call(self, request: ModelRequest, handler) -> ModelResponse:
        scopes = request.runtime.context.scopes
        allowed: set[str] = set()
        for scope in scopes:
            allowed |= SCOPE_TOOLS.get(scope, set())
        # request.tools 字段名以官方文档为准；@tool 装饰的函数名即工具 .name
        tools = [t for t in request.tools if t.name in allowed]
        return handler(request.override(tools=tools))
```

注意：这只是**第一道防线**。`get_alarm` 内部仍要用 `context.scopes` 做最终校验，纵深防御——过滤只是减少模型可选项，不能替代服务端授权。

### 7.4 超 Token 预算裁剪上下文

```python
class TokenBudgetTrimMiddleware(AgentMiddleware):
    def __init__(self, max_tokens: int, estimate):
        self.max_tokens = max_tokens
        self.estimate = estimate  # 与模型一致的 token 估算函数，注入便于替换

    def wrap_model_call(self, request: ModelRequest, handler) -> ModelResponse:
        messages = list(request.messages)
        # 保留 system（索引 0）与最近消息（末尾），从最早的历史开始裁剪
        while len(messages) > 2 and self.estimate(messages) > self.max_tokens:
            messages.pop(1)
        return handler(request.override(messages=messages))
```

不要在 `before_model` 里靠 `return {"messages": [...]}` 裁剪：`messages` 是加法 reducer，返回会被**累加**而非替换，反而让上下文翻倍。裁剪应通过 `wrap_model_call` 的 `request.override(messages=...)` 完成。

### 7.5 记录模型调用费用

```python
class ModelUsageMiddleware(AgentMiddleware):
    def __init__(self, metrics):
        self.metrics = metrics  # 注入 MetricsRecorder 端口，不在这里写死存储

    def after_model(self, state: AgentState, runtime) -> dict | None:
        last = state["messages"][-1]
        usage = getattr(last, "usage_metadata", None)  # 字段以官方文档为准
        if not usage:
            return None
        self.metrics.record_model_call(
            request_id=runtime.context.request_id,
            tenant_id=runtime.context.tenant_id,
            input_tokens=usage.get("input_tokens", 0),
            output_tokens=usage.get("output_tokens", 0),
        )
        return None
```

费用由「用量 × 模型单价」在观测层换算，**只记录与异常告警**：单次调用量、短期窗口 spike 触发告警，不设上限、不据此终止 Agent。

### 7.6 注册与顺序集成测试

```python
agent = create_agent(
    model=model,
    tools=[get_alarm, search_manual, create_work_order_draft],
    context_schema=AgentContext,
    response_format=ToolStrategy(AgentAnswer),
    system_prompt=SYSTEM_PROMPT,
    middleware=[
        PromptVersionMiddleware(version=PROMPT_VERSION),
        RoleToolFilterMiddleware(),
        TokenBudgetTrimMiddleware(max_tokens=8000, estimate=estimate_tokens),
        ModelUsageMiddleware(metrics=metrics),
    ],
)
```

顺序集成测试用一个记录 Hook 名的 Fake Middleware 验证真实顺序：

```python
class HookRecorder(AgentMiddleware):
    def __init__(self, name: str, log: list):
        self.name = name
        self.log = log

    def before_model(self, state, runtime):
        self.log.append(f"{self.name}:before_model")
        return None

    def after_model(self, state, runtime):
        self.log.append(f"{self.name}:after_model")
        return None

    def wrap_model_call(self, request, handler):
        self.log.append(f"{self.name}:wrap:enter")
        result = handler(request)
        self.log.append(f"{self.name}:wrap:exit")
        return result
```

对 `middleware=[recorder("A"), recorder("B"), recorder("C")]` 跑一次 `ainvoke`，断言顺序满足：

```text
A:before_model → B:before_model → C:before_model
→ A:wrap:enter → B:wrap:enter → C:wrap:enter → C:wrap:exit → B:wrap:exit → A:wrap:exit
→ C:after_model → B:after_model → A:after_model
```

## 8. 失败路径：顺序写反与重复重试

**失败一：Hook 顺序写反，脱敏发生在记录之后。** 假设有 `M_redact`（脱敏）和 `M_log`（记录）两个 Middleware，期望「先脱敏再记录」。因为 `after_model` 反序执行，只有声明顺序 `[M_redact, M_log]` 才能让记录看到脱敏后的内容；写成 `[M_log, M_redact]` 时，`after_model` 先跑 `M_log`，日志里落的是**未脱敏**的原始输出。这是最典型的「看起来对、实际泄漏」的 bug，必须靠顺序测试而不是代码审查兜底。

**失败二：在 `before_model` 返回 `messages` 裁剪，导致上下文翻倍而非替换。** 见 7.4，加法 reducer 会把返回的消息累加进状态。

**失败三：多层重复重试乘法放大。** 如果 HTTP Client 重试 2 次、`wrap_model_call` 里又重试 2 次、Provider SDK 再重试 2 次，最坏情况是 3 × 3 × 3 = 27 次真实调用。必须指定唯一重试所有者，让其他层关闭重试或只处理互不重叠的错误；写操作还要保证幂等。

**失败四：外层 Graph 与内层 Middleware 各自重试同一调用。** 把 Agent 作为子图放进更大的 StateGraph 后，外层 Graph 若也有重试策略，会与内层 Middleware 的 `wrap_model_call` 重试叠加。只在边界确定一处负责重试，另一处只做观测。

## 项目任务

1. 实现 `PromptVersionMiddleware`，注入当前提示词版本到 system message，并用测试断言注入块出现在请求中。
2. 实现 `RoleToolFilterMiddleware`，按 `runtime.context.scopes` 过滤工具；测试无 `equipment:read` 时模型即使被 Prompt 诱导也无法调用 `get_alarm`。
3. 实现 `TokenBudgetTrimMiddleware`，用注入的 `estimate` 函数裁剪到预算内；测试裁剪后不丢 system 与最近一条用户消息。
4. 实现 `ModelUsageMiddleware`，记录每次模型调用的 `input_tokens/output_tokens`，异常 spike 触发告警；测试中不出现任何上限/终止逻辑。
5. 写 Hook 顺序集成测试，用 `HookRecorder` 断言 `before_*/after_*/wrap_*` 的真实顺序（含 `[A, B, C]` 的嵌套）。

## 常见错误与诊断顺序

1. **日志里出现未脱敏 PII** → 先查 Middleware 声明顺序：脱敏是否排在记录**之前**；再查 `after_model` 反序是否被误解。
2. **上下文没被裁掉反而变长** → 查是否在 node 风格 Hook 里 `return {"messages": [...]}`；`messages` 是加法 reducer，裁剪要走 `wrap_model_call` 的 `override`。
3. **同一调用被调用几十次** → 排查三层重试是否同时开启（HTTP Client / Middleware / Provider SDK），以及外层 Graph 与内层 Middleware 是否各自重试；收敛到唯一重试所有者。
4. **模型「越权」调用成功** → 确认工具内部仍有服务端校验；Middleware 过滤只是第一道防线，不是授权终点。

## 练习题与答案

### 练习 1：权限校验放 Prompt 还是 Middleware？

**答案：**Prompt 只能「提醒」模型，不能作为安全保证——模型可能被注入、被绕开或被诱导。正确做法是纵深防御：Middleware 提前按 `runtime.context.scopes` 过滤工具（减少可选项、快速失败），工具/服务端再基于注入的 `tenant_id/user_id` 做最终授权校验。Prompt 里的约束是体验优化，不是安全边界。

### 练习 2：何时不该使用 Middleware？

**答案：**需要显式状态、审批分支、补偿与恢复的业务流程应放 LangGraph 或应用服务，而不是藏进 Middleware。Middleware 适合横切且与主流程正交的策略；一旦业务逻辑进入 Hook，会变得难以理解、难以测试，也会因为 Hook 顺序语义（反序/嵌套）产生隐蔽耦合。

### 练习 3：HTTP Client、Middleware、Provider SDK 都各重试两次，会发生什么？

**答案：**最坏情况乘法放大：3 层各重试 2 次（共 3 次尝试）→ 3 × 3 × 3 = 27 次真实调用。必须指定唯一重试所有者，让其他层关闭重试或只处理互不重叠的错误；写操作还需幂等，否则重试会产生重复副作用。

## 工程挑战

1. **动态模型路由可解释化**：路由规则记录命中的规则与原因，进入 Trace；用数据集评测两类路由错误。参考方向：路由决策作为一等事件落库，配评测集做回归。
2. **上下文裁剪不丢关键事实**：裁剪策略（保留最近消息 + 关键实体）需证明设备 ID、告警 ID 不因裁剪丢失。参考方向：用「金标实体保留率」指标评测裁剪函数。
3. **费用异常告警**：定义单次调用量、短期窗口 spike 的告警阈值，只观测不终止。参考方向：metrics 端口抽象 + 监控面板，费用按 tenant/model 维度聚合。
4. **重试边界收敛**：证明同一错误只被一层重试，外层 Graph 与内层 Middleware 不叠加。参考方向：注入可计数故障，断言真实调用次数。

## 面试追问

**问题 1：为什么 Middleware 的 `before_*` 与 `after_*` 执行顺序不同？**

回答框架：`before_*` 是「进入前」的处理，天然按声明顺序逐层准备；`after_*` 是「返回后」的清理/观测，采用栈式反序（后进先出），保证最内层先完成收尾；`wrap_*` 本质是函数调用嵌套，靠前的 Middleware 包住靠后的。三者统一起来就是「声明顺序进、栈式出」，与装饰器/中间件链的通用模型一致。

**问题 2：为什么不能把权限校验写在 Prompt 里？**

回答框架：Prompt 不是安全边界——它是交给模型的软指令，可被注入、冲突指令覆盖或模型失误违反。安全的正确形态是纵深防御：Middleware 提前过滤工具、工具内部用 `runtime.context` 的 `tenant_id/scopes` 做强制校验、服务端再做资源级授权，三层都失败时安全终止（`E_FORBIDDEN`），而不是依赖模型自觉。

## 本章复盘模板

```text
- 我在哪个 Middleware 里做了什么横切策略？
- 它放在哪个 Hook（before / wrap / after）？为什么这个 Hook 最合适？
- 我如何证明它的执行顺序正确（有没有顺序测试）？
- AgentContext 的身份字段是否全程来自 runtime.context，而非模型消息？
- 是否存在以固定金额终止调用的逻辑？费用是否只记录 Usage 并异常告警？
- 同一类错误是否只被一层重试？重试所有者是谁？
- 把 Agent 放进更大 StateGraph 后，Middleware 是否仍执行？重试是否叠加？
```

## 官方资料与中文阅读指引

- [Middleware overview](https://docs.langchain.com/oss/python/langchain/middleware/overview)：重点读「agent loop 与 Hook 时机」图，以及「Use middleware inside a LangGraph workflow」——它解释了 Middleware 随子图一起执行的组合方式。
- [Custom middleware](https://docs.langchain.com/oss/python/langchain/middleware/custom)：重点读 `AgentMiddleware` 基类、`state_schema/tools/transformers` 类属性、`before_model/after_model/wrap_model_call/wrap_tool_call` 的签名与返回值，以及 `request.override` 与 `ExtendedModelResponse`/`Command` 的用法。
- [Runtime](https://docs.langchain.com/oss/python/langchain/runtime)：重点读 `runtime.context` 的注入方式，与第 3 章 `context_schema=AgentContext` 对照理解。

阅读时注意：各 Hook 的精确签名、`override` 支持的字段、异步版本命名，都以当前锁定的 LangChain 版本官方文档为准，不要照搬旧版本示例。

## 下一章入口

本章把横切策略收敛进 Middleware，Agent 内部已具备「可控的循环 + 身份 + 工具白名单 + 费用观测」。下一章《流式事件、短期记忆与前端协议》处理「运行过程如何安全地暴露给前端」：把 LangChain 内部流映射为自有 SSE 协议、区分 `conversation_id/thread_id/run_id/request_id`，并落地短期记忆的 Token 预算与摘要策略。
