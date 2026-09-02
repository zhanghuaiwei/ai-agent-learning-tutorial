# create_agent 与工具系统

> 预计 8 小时｜产出：设备查询与工单草稿单 Agent。

> **阅读前置**：本章是 LangChain 主线的核心实现章。默认读者已完成第 2 阶段 M0——本章的工具直接复用 M0 建立的 `tools.py` 三个契约（`search_manual`、`get_alarm`、`create_work_order_draft`）与 Pydantic Schema；还需要第 3 阶段 Function Calling 的概念（该阶段正文当前为大纲态，可在学习本章时对照手写实现回看）。本阶段第 1～2 章（架构与核心抽象）扩写前，本章可先作为"框架如何表达我们已有的契约"的对照实验。

## 1. 最小实现

```python
from langchain.agents import create_agent

agent = create_agent(
    model=model,
    tools=[get_alarm, search_manual, create_work_order_draft],
    system_prompt=SYSTEM_PROMPT,
)

result = await agent.ainvoke({
    "messages": [{"role": "user", "content": "查询 EQ-001 的高危告警"}]
})
```

这段代码只解决动态 Tool Loop，不自动解决权限、租户隔离、业务事务和对外响应。Tool 函数仍应调用应用服务，而不是把数据库连接交给模型。

## 2. 工具设计准则

- 一个工具一个清晰能力，参数尽量少且强类型。
- 描述包含使用时机、禁止场景、错误和副作用。
- Tool 通过运行时 Context 获取 `user_id/tenant_id/roles`，不要让模型填写身份。
- 返回面向模型的紧凑结果；完整对象留在服务端。
- 写工具默认先生成 Draft，再由可信事件确认。

工具太多会增加选择困难。按任务动态暴露最小工具集，而非把公司全部 API 塞给一个 Agent。

## 3. 可运行的 Context 与结构化响应

下面示例展示三个关键边界：身份从 Runtime 注入、Tool 返回紧凑数据、最终结果由 Schema 校验。示例需要当前 LangChain 1.x；实际小版本由 `uv.lock` 固定。

```python
from dataclasses import dataclass
from typing import Literal

from langchain.agents import create_agent
from langchain.agents.structured_output import ToolStrategy
from langchain.tools import ToolRuntime, tool
from pydantic import BaseModel, Field


@dataclass(frozen=True)
class AgentContext:
    user_id: str
    tenant_id: str
    scopes: frozenset[str]
    request_id: str


class AlarmView(BaseModel):
    equipment_id: str
    level: Literal["low", "medium", "high"]
    summary: str = Field(max_length=300)


class AgentAnswer(BaseModel):
    status: Literal["answered", "needs_input", "refused"]
    answer: str
    evidence_ids: list[str]


@tool
async def get_alarm(
    equipment_id: str,
    runtime: ToolRuntime[AgentContext],
) -> AlarmView:
    """读取当前租户中指定设备的最新告警；仅用于查询。"""
    context = runtime.context
    if "equipment:read" not in context.scopes:
        raise PermissionError("missing equipment:read")
    return await alarm_service.get_visible_alarm(
        tenant_id=context.tenant_id,
        equipment_id=equipment_id,
    )


agent = create_agent(
    model=model,
    tools=[get_alarm],
    context_schema=AgentContext,
    response_format=ToolStrategy(AgentAnswer),
    system_prompt=SYSTEM_PROMPT,
)

result = await agent.ainvoke(
    {"messages": [{"role": "user", "content": "查询 EQ-001 的高危告警"}]},
    context=AgentContext(
        user_id="u-001",
        tenant_id="tenant-a",
        scopes=frozenset({"equipment:read"}),
        request_id="req-001",
    ),
)
answer: AgentAnswer = result["structured_response"]
```

这不是完整认证实现：`AgentContext` 必须由已经验证 Token 的 API 层创建。不要从请求 JSON 或用户消息直接构造其中的身份字段。

## 4. Structured Output 策略

`response_format` 有三种实际用法：

| 方式 | 适用情况 | 注意点 |
| --- | --- | --- |
| 直接传 Schema | 让 LangChain 根据模型能力选择策略 | 需要确认模型 Profile 是否准确 |
| `ProviderStrategy(Schema)` | Provider 原生结构化输出可靠且支持 | 并非所有模型都支持 |
| `ToolStrategy(Schema)` | 支持 Tool Calling，但无可靠原生结构化输出 | 校验失败可能进入修复重试 |

结果读取 `result["structured_response"]`，不要再从最后一条自然语言消息手工正则解析 JSON。对千问和 DeepSeek 分别跑能力 Smoke Test：是否支持工具与结构化输出同时使用、错误响应形态、并行 Tool Calls 和流式行为，都以实际模型与官方说明为准。

修复重试必须有限。连续失败后返回结构化 `MODEL_OUTPUT_INVALID`，不能无限要求模型“再试一次”。

## 5. Tool Error 契约

把错误分成模型可修正与不可修正：

```text
INVALID_ARGUMENT：参数格式错，可提示模型修正一次
NOT_FOUND：对象不存在或不可见，不枚举其他租户
CONFLICT：状态已变化，需要重新读取
FORBIDDEN：安全终止，不让模型尝试绕过
UPSTREAM_TIMEOUT：按读/写与幂等性决定有限重试
INTERNAL_ERROR：对外安全摘要，详细异常只进受控日志
```

Tool 不要把堆栈、SQL、Token 或完整内部响应交给模型。对外消息和内部诊断信息分开保存。

## 6. 项目任务

迁移 M1 三个工具；实现基于角色的工具过滤、参数校验、统一 Tool Error；对比 Tool 描述三个版本的选择准确率。

额外完成：

1. 使用同一数据集对比直接 Schema、`ToolStrategy` 的结构合规率。
2. 注入 403、404、409、超时和非法 Tool 参数，验证错误路线。
3. 证明用户在 Prompt 中伪造 `tenant_id` 不会改变 Runtime Context。
4. 保存 Tool 名、调用 ID、参数摘要、结果类别和延迟，不保存密钥。

## 7. 练习与答案

### 练习 1：租户 ID 能作为 Tool 参数让模型填写吗？

**答案：**不能信任。租户 ID 来自服务端鉴权上下文，工具内部强制注入并校验资源范围。

### 练习 2：工具越细越好吗？

**答案：**也不是。过细会增加回合与失败面；以可独立授权、可清晰描述、可安全重试的业务能力为边界。

### 练习 3：`ToolStrategy` 能修复 Schema 错误，为什么还要任务级运行边界？

**答案：**框架重试不能替代最大步骤、Deadline 和错误分类。模型可能反复输出同类错误；必须在有限次数后形成可观测失败。

## 8. 验收与资料

模型无法越权选择隐藏工具；Tool 错误不崩溃且可追踪；结构化输出不靠正则解析；Context 伪造测试通过。参考 [Agents](https://docs.langchain.com/oss/python/langchain/agents)、[Tools](https://docs.langchain.com/oss/python/langchain/tools)、[Runtime](https://docs.langchain.com/oss/python/langchain/runtime)、[Structured output](https://docs.langchain.com/oss/python/langchain/structured-output)。
