# Model、Message、Tool 与 Runnable

> 所属阶段：第 4 阶段（LangChain 与单 Agent），预计用时：6 小时
> 项目产出：`ModelFactory`、`ToolResultAdapter`、一条 Tool Call → Tool Message → final 的消息序列示例、四个抽象到 M0/M1 契约的映射表
> 资料验证日期：2026-09-02

## 1. 本章从哪里开始

第 3 阶段我们用原生代码手写了一个 ReAct Loop：`ModelGateway` 隔离供应商差异，`ToolRegistry` 承载工具分级与权限，`agent/loop.py` 负责有界循环。这些代码**没有依赖任何框架**，是我们理解 Agent 的基线。

本章进入第 4 阶段，把这些东西逐一映射到 LangChain 1.x 的四个核心抽象上。先说清楚关系：我们不是"推翻 M0/M1 重写"，而是**让框架表达我们已有的契约**。

| 已有交付物（M0/M1） | 所在文件 | LangChain 抽象 | 本章承接动作 |
| --- | --- | --- | --- |
| `ModelGateway` / `ChatResult` / `FakeGateway` | `gateway.py` / `schemas.py` / `fakes.py` | Model（`init_chat_model`） | `ModelFactory` 在组合根构造框架模型；M0 网关退居测试替身与对照基线 |
| `ChatResult` / 消息契约 | `schemas.py` / `loop.py` | Message（`SystemMessage` 等） | 用消息序列表达对话，`ToolMessage.tool_call_id` 与 `AIMessage.tool_calls[].id` 配对 |
| `search_manual` / `get_alarm` / `create_work_order_draft` + `ToolRegistry` | `tools.py` / `tool_registry.py` | Tool（`@tool` + `ToolRuntime`） | `ToolResultAdapter` 把 M0 `ToolResult` 信封翻译成工具返回值 |
| `agent/loop.py` 手写循环 | `loop.py` | Runnable / Agent | Runnable 只做确定性预处理；动态动作循环交给 `create_agent`（下一章） |

完成后你应该能回答：

1. LangChain 的 Model 抽象和我们 M0 的 `ModelGateway` 是什么关系？谁适配谁？
2. 一条 Tool Call 要经过哪几条消息、靠哪个 ID 配对，才会被供应商接受？
3. `Runnable` 适合做什么、不适合做什么？为什么动态动作循环必须交给 Agent/Graph？
4. 模型初始化为什么必须放组合根，而不是每个请求里重复创建？

## 2. 本章完成标准

必须同时满足：

- `ModelFactory` 在组合根构造 LangChain 模型，进程内只构造一次，且复用 M0 `LLMSettings` 的配置语义；
- `ToolResultAdapter` 能把 M0 的 `ToolResult`（`ok/code/data/retryable`）翻译成面向模型的紧凑返回值，`E_*` 错误码分类为"可修正/不可修正"；
- 手写一条 Tool Call → Tool Message → final 的消息序列，能打印出每一步的消息类型与 `tool_call_id` 配对关系；
- 能主动制造两个失败用例：消息顺序错、`tool_call_id` 错配，并解释供应商拒绝的原因；
- 能说出 `invoke/ainvoke/stream/batch` 四种语义的适用场景，以及 `batch` 为什么要限并发；
- 全程不依赖真实 API 也能跑通消息序列与适配器（用 `FakeGateway` / 内存工具），`uv run pytest` 保持绿色。

## 3. 四个抽象与 M0/M1 契约的映射总览

LangChain 1.x 的应用层抽象有四个地基，其余（`create_agent`、Middleware、结构化输出）都建立在这四个之上：

```text
┌─────────────────────────────────────────────────────────────┐
│ create_agent / Middleware / Structured Output（后续章节）       │
├─────────────────────────────────────────────────────────────┤
│ Runnable     统一 invoke/ainvoke/stream/batch 语义，可组合     │
├─────────────────────────────────────────────────────────────┤
│ Model ──┬── Message ──┬── Tool                               │
│         │             │                                      │
│  统一聊天模型接口  带角色/内容块/工具调用/元数据  名称+描述+参数Schema │
└─────────┴─────────────┴─────────────────────────────────────┘
```

四个抽象的职责边界必须记牢：

- **Model** 回答"用哪个模型、怎么发请求"，把供应商差异封装成统一接口；
- **Message** 回答"对话状态里有什么"，是循环里唯一在变的数据结构；
- **Tool** 回答"模型能触发哪些确定性的外部动作"，是模型与业务代码之间唯一的受控通道；
- **Runnable** 回答"这些对象怎么串联起来跑"，给出一致的执行语义。

它们分别对应 M0 的 `ModelGateway`、`ChatResult`、`tools.py` 三个工具，以及第 3 章手写循环里"串起网关与工具"的那段逻辑。本章逐一展开，并补上两个此前缺失的胶水件：`ModelFactory` 与 `ToolResultAdapter`。

## 4. Model：统一聊天模型接口

### 4.1 抽象解决什么问题

M0 的 `ModelGateway` 是我们**自己**的抽象：`chat()` 返回 `ChatResult`，隔离了 OpenAI-compatible 供应商之间的差异。LangChain 的 Model 抽象做的是同一件事，只是它要同时兼容更多 Provider，并提供 `ainvoke/stream/bind_tools` 等统一方法。

两个抽象不在同一层，不要混为一谈：

- M0 `ModelGateway`：为第 3 阶段手写 Loop 服务的窄接口，字段由我们控制；
- LangChain Model：框架级接口，`create_agent` 和 Runnable 都消费它。

迁移到 LangChain 后，框架代码（`create_agent`、管道）不再调用 M0 的 `ModelGateway`，而是调用 LangChain 模型对象。M0 网关保留下来做两件事：**离线测试替身**（`FakeGateway`）和**第 3 阶段手写 Loop 的对照基线**。

### 4.2 ModelFactory：组合根里的唯一构造点

模型对象（以及它内部的 SDK 客户端连接池）是昂贵的，必须在进程启动时构造一次、此后所有请求复用。这和第 2 阶段 `gateway.py` 里 `_build_client` 是同一个道理——只是这次产出的是框架模型：

```python
# src/agent_service/infrastructure/model_factory.py
from __future__ import annotations

from functools import lru_cache

from langchain.chat_models import init_chat_model  # LangChain 1.x 推荐入口

from agent_service.config import LLMSettings


@lru_cache(maxsize=1)
def create_model(settings: LLMSettings):
    """组合根里的唯一模型构造点，进程级单例。

    与 M0 的 _build_client 一脉相承：供应商 SDK 客户端是昂贵的连接池，
    必须在进程启动时构造一次、此后所有请求复用，而不是每次 ainvoke 都新建。
    """
    # settings.model 形如 "openai:qwen-plus"；api_key/base_url 的注入方式
    # （环境变量或 configurable_fields）以所用 LangChain 1.x 官方文档为准。
    return init_chat_model(settings.model)
```

三个要点：

- `lru_cache(maxsize=1)` 把"只构造一次"从口头约定变成代码保证；
- 函数签名**配置进、模型出**，不泄漏任何 Provider 细节给调用方；
- 具体参数名（`base_url` 如何传、超时如何设）不同小版本有差异，以官方文档为准，但**结构不变**：单一构造点 + 组合根装配。

反模式是在每个请求里 `init_chat_model(...)`——那等于每个请求重新握手、重建连接池，延迟和资源都不可控。这条规则对所有框架通用，不限于 LangChain。

### 4.3 模型选择不是本章重点

选型 ADR 在第 3 阶段第 1 章已经做过（千问 / DeepSeek 的能力边界、`FakeGateway` 替身）。本章只需确认一件事：**换模型不改业务代码**。验收标准里"可在不改业务代码时切模型"，靠的就是 `ModelFactory` 这一层——业务代码只依赖框架的 Model 接口，不感知具体是哪个 Provider。

## 5. Message：角色、内容块、工具调用与元数据

### 5.1 四种角色

消息是对话状态里唯一在变的数据结构。LangChain 把消息按角色分成四类，与我们 M1 里 `Message = dict[str, str]` 的 `role` 字段一一对应：

| LangChain 类型 | 角色语义 | 对应我们 M1 的用法 |
| --- | --- | --- |
| `SystemMessage` | 应用规则、边界、工具使用准则 | `system_prompt` |
| `HumanMessage` | 用户输入 | 请求里的 `user_text` |
| `AIMessage` | 模型回复，可携带 `tool_calls` | `AgentTurn.kind == "tool_call"` 或 `"final_answer"` |
| `ToolMessage` | 工具执行结果，必须带 `tool_call_id` | Loop 里追加的工具结果 |

关键认知：`SystemMessage` 是**应用规则**，不是"让模型变聪明的话术"。它的定位与第 3 阶段第 2 章 `ContextBuilder` 一致——规则的硬边界（权限、禁止动作、停止条件）必须落在确定性代码里，`SystemMessage` 只负责让模型理解语境。**不要指望在 SystemMessage 里写"你没有权限"来替代真实鉴权。**

### 5.2 AIMessage 可携带 Tool Calls

模型不是每次都说人话。当它决定调用工具时，`AIMessage` 的 `content` 通常为空，工具调用意图放在 `tool_calls` 列表里，每一项带一个模型生成的 `id`：

```python
AIMessage(
    content="",
    tool_calls=[{
        "name": "get_alarm",
        "args": {"equipment_id": "eq-pump-01"},
        "id": "call_abc123",        # 模型生成的调用 ID，后续配对的关键
        "type": "tool_call",
    }],
)
```

这个 `id` 是整条 Tool Call 链的"合同号"——模型用它对账，供应商用它校验 `ToolMessage` 是否合法。

### 5.3 ToolMessage 必须用调用 ID 配对

工具执行完，结果必须作为 `ToolMessage` 回填，且 `tool_call_id` 必须与对应 `AIMessage.tool_calls[].id` 完全一致：

```python
ToolMessage(
    content='{"ok": true, "data": {"alarms": [...]}}',
    tool_call_id="call_abc123",   # 与上面 AIMessage 的 id 一致，否则供应商拒绝
)
```

为什么必须是 `tool_call_id` 而不是"按顺序回填"？因为模型可以**并行发起多个工具调用**（一条 `AIMessage` 里多个 `tool_calls`），工具执行的完成顺序是不确定的。只有靠 ID 配对，供应商才能把每条结果归到正确的调用上。这个机制在下一章 `create_agent` 里由框架自动完成，但本章要手动经历一遍，才知道框架替你省掉了什么。

### 5.4 元数据：run_id、Prompt 版本、数据集版本

消息的 `content` 是给模型看的；元数据是给 Trace 看的。把 `run_id`、Prompt 版本、数据集版本放进消息的 `additional_kwargs`（或上层调用上下文），而不是塞进 `content`：

```python
HumanMessage(
    content="查询 EQ-001 的高危告警。",
    additional_kwargs={
        "run_id": "req-001",          # 一次运行全局唯一的追踪 ID
        "prompt_version": "v7",       # 出问题时能区分"Prompt 变了"还是"数据变了"
        "dataset_version": "2026-09", # 评测时对齐数据集快照
    },
)
```

原则：**模型不该"看见"这些元数据，但 Trace 必须能定位到它们。** 这与第 2 阶段第 2 章"Schema 契约记录 `schema_version`"是同一类工程习惯——版本信息是诊断锚点，不是模型输入。

## 6. Tool：名称、描述、参数 Schema

### 6.1 三个要素

一个 LangChain 工具由三样东西定义：

- **名称（name）**：模型用来"点名"调用哪个工具，对应 M1 `ToolRegistry` 的键；
- **描述（description）**：告诉模型何时用、何时别用、有什么副作用——这是选型信号，不是安全机制；
- **参数 Schema（args_schema）**：强类型入参，对应 M1 各工具的 `*Input` Pydantic 模型。

LangChain 用 `@tool` 装饰器从函数签名自动推断参数 Schema：

```python
# src/agent_service/tools/langchain_tools.py
from langchain.tools import ToolRuntime, tool

from agent_service.domain.context import AgentContext
from agent_service.schemas import SearchManualInput
from agent_service.tools.adapter import ToolResultAdapter
from agent_service import tools as m1_tools


@tool
async def search_manual(
    equipment_id: str,
    keywords: list[str],
    runtime: ToolRuntime[AgentContext],
) -> dict:
    """按设备与关键词检索维护手册片段；只读，无副作用，不得据此修改任何配置。"""
    adapter = ToolResultAdapter()
    result = m1_tools.search_manual(
        SearchManualInput(equipment_id=equipment_id, keywords=keywords)
    )
    return adapter.adapt(result)
```

注意两点：

- **身份从 `runtime.context` 注入，不是模型填写。** `ToolRuntime[AgentContext]` 让框架把运行上下文传进来，`tenant_id`/`scopes` 等身份字段由 API 层在鉴权后构造，模型永远拿不到、也改不了它们。下一章会看到用户如何在 Prompt 里伪造 `tenant_id` 都无效——因为它根本不经过模型。
- **工具函数返回"面向模型的紧凑结果"。** 完整对象留在服务端，模型只拿到摘要。这和第 3 阶段第 4 章"工具返回精简片段 + 证据 ID"的约定一致。

`AgentContext` 定义（`@dataclass(frozen=True)`，内部确定性数据不需要 Pydantic）：

```python
# src/agent_service/domain/context.py
from dataclasses import dataclass


@dataclass(frozen=True)
class AgentContext:
    user_id: str
    tenant_id: str
    scopes: frozenset[str]
    request_id: str
```

### 6.2 ToolResultAdapter：把 M0 信封翻译成工具返回值

M1 的三个工具返回的是 M0 的 `ToolResult` 信封（`ok/code/data/retryable/observed_at`）。但 LangChain 工具返回的东西会直接进入 `ToolMessage.content` 让模型读。直接把整个信封塞给模型会泄漏内部字段（`retryable`、`observed_at` 对模型无用且是噪声），所以需要适配：

```python
# src/agent_service/tools/adapter.py
from __future__ import annotations

from typing import Any

from agent_service.schemas import ToolResult


class ToolResultAdapter:
    """把 M0 的 ToolResult 信封翻译成 LangChain 工具返回值。

    职责边界：
    - 成功：返回紧凑 data 摘要，不把整个手册正文塞给模型（第 3 阶段第 4 章约定）；
    - 失败：把 E_* 错误码分类成"模型可修正 / 不可修正"，转稳定文案，不泄漏堆栈。
    """

    # 不可修正错误：安全终止，不让模型尝试绕过。
    TERMINAL = frozenset({"E_FORBIDDEN", "E_UNKNOWN_TOOL", "E_UNREFERENCED_EVIDENCE"})

    def adapt(self, result: ToolResult) -> dict[str, Any]:
        if result.ok:
            return {"ok": True, "data": result.data}
        code = result.code
        if code in self.TERMINAL:
            return {"ok": False, "code": code, "hint": self._terminal_hint(code)}
        return {"ok": False, "code": code, "hint": self._retryable_hint(result)}

    def _terminal_hint(self, code: str) -> str:
        return {
            "E_FORBIDDEN": "无权限执行此操作，请勿重试。",
            "E_UNKNOWN_TOOL": "工具不存在，请勿臆造工具名。",
            "E_UNREFERENCED_EVIDENCE": "引用证据不可见，请基于已检索证据回答。",
        }.get(code, "不可恢复错误。")

    def _retryable_hint(self, result: ToolResult) -> str:
        return "临时失败，可重试一次。" if result.retryable else "操作失败。"
```

这个适配器是本章最关键的胶水件，它体现了两个原则：

- **`E_*` 错误码沿用第 2 阶段第 2 章 `ToolResult.code` 约定**，跨阶段可对照；`TERMINAL` 集合把"安全终止"与"可重试"分开，和下一章 Tool Error 契约（`E_FORBIDDEN` 不让模型绕过）对齐；
- **错误分类落在确定性代码里，不在 Prompt 里**。模型读到的是稳定的 `hint` 文案，而不是内部异常堆栈——`E_FORBIDDEN` 的提示语是"请勿重试"，而不是让模型自己判断"我要不要换个说法再试"。

## 7. Runnable：统一的 invoke/ainvoke/stream/batch

### 7.1 一种语义，四种执行方式

Runnable 是 LangChain 里"可执行对象"的统一协议。任何 Runnable（模型、Prompt、管道）都提供同一组方法：

| 方法 | 语义 | 适用场景 |
| --- | --- | --- |
| `invoke` | 同步调用，返回完整结果 | 脚本、CLI、离线实验 |
| `ainvoke` | 异步调用，返回完整结果 | **生产首选**，不阻塞事件循环 |
| `stream` | 增量产出（token 级或事件级） | 前端流式输出 |
| `batch` | 批量处理多个输入 | 离线评测、批量标注 |

I/O 调用优先 `ainvoke`：LangChain 模型调用是网络 I/O，同步 `invoke` 在 FastAPI 里会阻塞整个事件循环。第 2 阶段第 3 章已经建立了"异步并发、超时、取消"的肌肉记忆，这里直接沿用。

`batch` 必须限并发。它会把一批输入并发发给供应商，不设上限会同时打爆供应商的速率限制（rate limit），也放大一次评测的资源占用。限流手段（信号量、分批）在第 2 阶段第 3 章有现成模式，此处不展开。

### 7.2 Runnable 管道适合什么，不适合什么

用 `|` 把 Runnable 串成管道，适合**确定性、可预知路径**的预处理：

```text
输入清洗 → 模板填充 → 模型调用 → 结构化解析
```

但**动态动作循环不适合用 Runnable 硬写**。循环里"这一步该不该调工具、调哪个、调完下一步做什么"是模型在每个回合动态决定的，路径无法预先画成一条直线。硬用 Runnable 表达循环，等于在第 3 阶段手写 Loop 之外又发明一种更别扭的手写 Loop。

正确的分工是：

- **Runnable**：确定性预处理、模型调用、输出解析——路径固定，可复用、可测试；
- **Agent / Graph**：模型动态选择动作、需要循环和状态持久化的场景。

这条分界线也是下一章 `create_agent` 的入场理由：它把"动态工具循环"这件事从我们手里接过去，运行在 LangGraph 上（第 4 阶段第 1 章已说明）。

## 8. 完整演练：一条 Tool Call → Tool Message → final 的消息序列

手动经历一次完整链路，是理解消息协议最快的路径。下面用 M1 的内存工具，把模型两轮调用之间的消息状态打印出来：

```python
# scripts/manual_tool_call_trace.py
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage


def main() -> None:
    # 1) 初始对话状态：系统规则 + 用户输入
    messages = [
        SystemMessage(content="你是设备维护知识助手。信息不足时明确说明，不编造事实。"),
        HumanMessage(content="查询 eq-pump-01 的高危告警。"),
    ]

    # 2) 第一轮模型输出：决定调用 get_alarm，而不是直接回答
    messages.append(
        AIMessage(
            content="",
            tool_calls=[{
                "name": "get_alarm",
                "args": {"equipment_id": "eq-pump-01"},
                "id": "call_abc123",
                "type": "tool_call",
            }],
        )
    )

    # 3) 工具执行（真实代码里由 ToolRegistry 执行 get_alarm，这里用内存工具）
    #    结果必须作为 ToolMessage 回填，tool_call_id 与上一步 id 严格一致。
    tool_result = '{"ok": true, "data": {"alarms": [{"alarm_id": "alarm-0001", "severity": "high"}]}}'
    messages.append(
        ToolMessage(content=tool_result, tool_call_id="call_abc123")
    )

    # 4) 第二轮模型输出：基于工具结果给出最终回答
    messages.append(
        AIMessage(content="eq-pump-01 存在一条高危告警：泵体振动超限。")
    )

    # 打印每一步的类型与配对关系，验证消息协议
    for i, msg in enumerate(messages):
        extra = ""
        if isinstance(msg, AIMessage) and msg.tool_calls:
            extra = f"tool_call_ids={[c['id'] for c in msg.tool_calls]}"
        elif isinstance(msg, ToolMessage):
            extra = f"tool_call_id={msg.tool_call_id}"
        print(f"[{i}] {type(msg).__name__}: {extra or msg.content[:40]}")


if __name__ == "__main__":
    main()
```

预期输出：

```text
[0] SystemMessage: 你是设备维护知识助手。信息不足时明确说明，不编造事实。
[1] HumanMessage: 查询 eq-pump-01 的高危告警。
[2] AIMessage: tool_call_ids=['call_abc123']
[3] ToolMessage: tool_call_id=call_abc123
[4] AIMessage: eq-pump-01 存在一条高危告警：泵体振动超限。
```

这一条序列就是 `create_agent` 内部循环每一次"工具往返"的最小单元。下一章用框架跑时，同样的序列由框架自动 append，但你现在已经知道每个 append 的语义和约束了。

## 9. 失败路径：消息顺序错与 tool_call_id 错配

消息协议是**有严格约束**的，供应商会在请求到达时校验。两个最常见的失败：

### 9.1 消息顺序错

一条带 `tool_calls` 的 `AIMessage` 之后，**必须紧跟对应的 `ToolMessage`**，中间不能插入 `HumanMessage`，也不能让 `ToolMessage` 排在 `AIMessage` 之前：

```python
# 错误示例 1：ToolMessage 排在了对应 AIMessage 之前
bad = [
    SystemMessage(content="..."),
    HumanMessage(content="..."),
    ToolMessage(content="...", tool_call_id="call_abc123"),  # 顺序错：还没有对应的 tool_call
    AIMessage(content="", tool_calls=[{"name": "get_alarm", "args": {}, "id": "call_abc123", "type": "tool_call"}]),
]

# 错误示例 2：两个 AIMessage 之间漏掉了工具结果
bad = [
    SystemMessage(content="..."),
    HumanMessage(content="..."),
    AIMessage(content="", tool_calls=[{"name": "get_alarm", "args": {}, "id": "call_1", "type": "tool_call"}]),
    AIMessage(content="我直接回答了。"),  # 错：前一个 tool_call 没有配对的 ToolMessage
]
```

供应商行为：返回 400 类错误，提示消息序列不满足"assistant（含 tool_calls）之后必须跟随 tool 消息"的约束。

### 9.2 tool_call_id 错配

`ToolMessage.tool_call_id` 与任何一条 `AIMessage.tool_calls[].id` 都对不上：

```python
# 错误示例：ID 拼写不一致
AIMessage(content="", tool_calls=[{"name": "get_alarm", "args": {}, "id": "call_abc123", "type": "tool_call"}])
ToolMessage(content="...", tool_call_id="call_ABC123")  # 大小写不符 → 错配
```

供应商行为：拒绝请求，因为它无法把这条工具结果归属到任何一次工具调用。并行多工具时，这类错配尤其隐蔽——结果都回来了，但张冠李戴。

**诊断顺序**：先确认 `AIMessage.tool_calls` 是否存在（模型这轮到底有没有发起调用）→ 再核对每条 `ToolMessage.tool_call_id` 是否与某个 `tool_calls[].id` 完全一致（含大小写）→ 最后核对顺序是否满足"tool_call 之后紧跟 tool 消息"。三者都正确，供应商才会接受。

## 10. 项目任务

在 M0/M1 代码基础上完成：

1. 实现 `src/agent_service/infrastructure/model_factory.py` 的 `create_model`，用 `lru_cache` 保证进程级单例，复用 `LLMSettings`；
2. 实现 `src/agent_service/tools/adapter.py` 的 `ToolResultAdapter`，覆盖 `OK`、`E_FORBIDDEN`、`E_UNKNOWN_TOOL`、`E_INVALID_ARGUMENT`、`E_UPSTREAM_TIMEOUT` 至少五种 `code` 的分类；
3. 写 `scripts/manual_tool_call_trace.py`，手动经历 Tool Call → Tool Message → final，打印每一步消息类型与 `tool_call_id`；
4. 写两个失败用例测试（消息顺序错、`tool_call_id` 错配），断言构造出的消息序列能被你自己的校验函数识别为非法（不依赖真实供应商返回 400）；
5. 写 `ToolResultAdapter` 的单元测试：成功信封返回 `{"ok": True, "data": ...}`，`E_FORBIDDEN` 返回 `hint` 且标记为不可修正，全程不联网。

## 11. 常见错误与诊断顺序

### 11.1 把 M0 的 ModelGateway 和 LangChain Model 当成同一个东西

现象：想直接用 `init_chat_model` 替换 `ModelGateway`，或反过来给 `ModelGateway` 强加 LangChain 的方法。

诊断顺序：确认代码消费方是谁。框架代码（`create_agent`、Runnable）消费 LangChain Model；第 3 阶段手写 Loop 消费 `ModelGateway`。两者并存，靠 `ModelFactory` 与 `FakeGateway` 各司其职，不要互相替代。

### 11.2 ToolMessage 报"找不到对应 tool_call"

现象：真实供应商返回 400，报 tool_call 无法匹配。

诊断顺序：见 §9.2 的三步——先确认模型这轮是否真的发了 `tool_calls`，再核对 ID 完全一致（含大小写），最后核对顺序。九成是 `tool_call_id` 拼写或大小写不一致。

### 11.3 工具返回值直接把整个 ToolResult 信封塞给模型

现象：模型回复里出现了 `retryable`、`observed_at` 这类它不该关心的字段，甚至开始"解释"这些字段。

诊断顺序：确认工具函数返回前是否经过了 `ToolResultAdapter`。模型只需要 `data` 摘要和稳定的 `hint` 文案，内部字段是噪声，也是信息泄漏面。

### 11.4 每次请求都重新 init_chat_model

现象：高并发下连接数暴涨、P99 延迟飙升。

诊断顺序：检查 `ModelFactory` 是否被 `lru_cache` 包住、是否在组合根调用一次而非每个请求调用。供应商 SDK 客户端是连接池，重复创建是资源泄漏。

## 12. 练习题与答案

### 练习 1：Tool 直接返回 2 万字手册正文有什么问题？

**答案：**迅速占满上下文窗口、放大 Token 消耗、引入大量与当前问题无关的噪声，还增大了注入攻击面。应返回精简片段、证据 ID、来源元数据和可按需读取的引用；完整正文留在服务端，由后续检索按需取回。这正是 `ToolResultAdapter` 存在的意义。

### 练习 2：Runnable 能否替代所有 Agent？

**答案：**不能。Runnable 管道适合路径固定的确定性流程（预处理 → 模型 → 解析）；需要模型**动态选择动作、循环、有条件分支**时，路径无法预先画成直线，必须用 Agent 或 Graph。判断标准是"这一步的选择权在模型手里，还是在代码手里"。

### 练习 3：为什么 `ToolMessage` 必须用 `tool_call_id` 配对，而不是按顺序回填？

**答案：**模型可以并行发起多个工具调用（一条 `AIMessage` 里多个 `tool_calls`），工具执行完成顺序不确定，按顺序回填会张冠李戴。只有靠 ID 配对，供应商才能把每条结果归到正确的调用。

## 13. 工程挑战

在不联网、不破坏既有测试的前提下完成：

1. 给 `ToolResultAdapter` 增加一个参数 `include_data_keys: frozenset[str]`，白名单控制 `data` 里哪些键返回给模型，其余省略，并补测试；
2. 写一个消息序列校验函数 `validate_tool_call_sequence(messages)`，能识别 §9.1 和 §9.2 两类错误并返回具体错误位置；
3. 用 `FakeGateway` 模拟一次"模型连续两次发起 tool_call"的序列，验证 `ToolMessage` 的 ID 配对在并行场景下依然正确；
4. 为 `ModelFactory` 写一个契约测试，证明它返回的对象具备 `ainvoke` 方法（即满足框架 Model 接口的最小结构）。

参考方向：白名单过滤复用 `ToolResult.data` 的 `dict` 结构，键不存在时安全跳过；序列校验函数遍历消息列表、维护"未配对的 tool_call_id 栈"；并行场景给两条 `tool_calls` 配两条 `ToolMessage`、故意打乱回填顺序，验证 ID 配对而非顺序配对。

## 14. 面试追问

### 14.1 "你们为什么还要保留自己手写的 ModelGateway，直接用 LangChain 的 Model 不就行了？"

回答框架：两个抽象服务不同消费方。手写 `ModelGateway` 是第 3 阶段理解 Agent 的基线，且 `FakeGateway` 是离线测试替身；LangChain Model 是框架代码的入口。保留 M0 网关不是为了重复造轮子，而是为了（1）离线测试不依赖框架、（2）迁移到 LangChain 后用同一套契约做行为对照，任何漂移都能被发现。

### 14.2 "Tool 的描述写得好，能不能替代权限校验？"

回答框架：不能。工具描述是给模型的**选型信号**，是软约束；权限校验是**确定性代码**里的硬边界（`runtime.context.scopes` + `E_FORBIDDEN`），和描述无关。模型可能被注入、可能误解描述、可能被诱导调用越权工具，但权限钩子在执行前拦截，不依赖模型是否"听话"。一句话：描述管"选哪个"，代码管"能不能执行"。

### 14.3 "Runnable 和 Agent 的分界线到底在哪？"

回答框架：看每一步的动作选择权在谁手里。路径固定（预处理、单次模型调用、固定解析）用 Runnable；需要模型在每个回合动态决定"要不要调工具、调哪个、调完下一步做什么"时用 Agent。企业系统通常混合：高风险路径确定化为 Runnable/Workflow，低风险开放路径交给 Agent。

## 15. 本章复盘模板

完成后记录：

```text
完成日期：
实际投入小时：
ModelFactory 是否 lru_cache 且进程只构造一次：
ToolResultAdapter 覆盖了哪些 E_* 错误码（是否含 E_FORBIDDEN / E_UNKNOWN_TOOL / E_INVALID_ARGUMENT / E_UPSTREAM_TIMEOUT）：
能否手写 Tool Call → Tool Message → final 消息序列并说清 tool_call_id 配对：
能否主动构造"消息顺序错"和"tool_call_id 错配"两个失败用例并解释供应商为何拒绝：
能否说出 invoke/ainvoke/stream/batch 四种语义的适用场景：
仍不理解的问题：
```

## 16. 官方资料与中文阅读指引

- [LangChain Models](https://docs.langchain.com/oss/python/langchain/models)：重点读 `init_chat_model` 的用法、支持的 Provider 与模型命名格式，对照 `ModelFactory`；
- [LangChain Messages](https://docs.langchain.com/oss/python/langchain/messages)：重点读 `SystemMessage`/`HumanMessage`/`AIMessage`/`ToolMessage` 的字段与 `tool_calls`/`tool_call_id` 配对约束，对照 §5 和 §9；
- [LangChain Tools](https://docs.langchain.com/oss/python/langchain/tools)：重点读 `@tool` 装饰器、`ToolRuntime` 与运行时 Context 注入，对照 §6；
- [LangChain Runnable interface](https://docs.langchain.com/oss/python/langchain/runnable)：重点读 `invoke/ainvoke/stream/batch` 语义与管道组合 `|`，对照 §7。

重点阅读：Messages 文档里关于 `tool_calls` 与 `tool_call_id` 的约束说明（这是 §9 失败路径的官方口径），以及 Runnable 文档里关于异步与批处理的建议（对应 §7 的 `ainvoke` 优先、`batch` 限流）。所有具体参数签名以文档当前版本为准，本章代码只锁定"结构"，不锁定"具体参数名"。

## 17. 下一章入口

本章把 LangChain 的四个地基抽象逐一映射到 M0/M1 契约，并补上了 `ModelFactory` 与 `ToolResultAdapter` 两个胶水件。你此刻已经知道：模型在组合根构造一次、消息靠 `tool_call_id` 配对、工具身份从 `runtime.context` 注入、Runnable 只管确定性流程。

下一章《create_agent 与工具系统》把这些地基拼成真正的 Agent：用 `from langchain.agents import create_agent` 把动态工具循环交给框架，用 `ToolStrategy(AgentAnswer)` 做结构化输出，并回答上一章留下的核心问题——框架替你省掉了哪些编排样板，又要求你重新声明哪些边界（权限、租户隔离、错误分类）。
