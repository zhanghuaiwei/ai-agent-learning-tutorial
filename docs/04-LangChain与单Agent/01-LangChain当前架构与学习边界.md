# LangChain 当前架构与学习边界

> 所属阶段：第 4 阶段（LangChain 与单 Agent），预计用时：4 小时
> 项目产出：一份「LangChain 抽象 ↔ M1 手写构件」对照笔记、第 4 阶段分层目录骨架、简版 ADR、三篇官方文档阅读笔记
> 资料验证日期：2026-09-02

## 1. 本章从哪里开始

本章是第 4 阶段的起点章，**在本阶段内没有前置代码**，但它站在第 2、3 阶段两个里程碑的肩膀上。你要做的不是立刻写新 Agent，而是先立住一个心智模型：LangChain 1.x 到底替 M1 的手写实现替代了什么、又要求你重新声明什么。

前置交付物（都已落地，本章只对照、不重写）：

| 交付物 | 所在文件 | 在本章的角色 |
| --- | --- | --- |
| `ModelGateway` / `ChatResult` / `FakeGateway` / 错误体系 | M0（`gateway.py` / `schemas.py` / `errors.py` / `fakes.py`） | 模型调用底座；框架的 Model 抽象要对齐它 |
| `ToolRegistry` / `ToolSpec`（Schema/权限/超时/副作用分级） | M1（`tool_registry.py`） | 工具执行边界；框架的 Tool 抽象要对齐它 |
| `search_manual` / `get_alarm` / `create_work_order_draft` | M1（`tools.py`） | 2 只读 + 1 可逆写，是框架工具迁移的原型 |
| `agent/loop.py`（`AgentLoop` / `LoopOutcome` / 停止条件全集） | M1 | **本章被替代的核心对象**，保留为参考实现 |
| 6 条红队用例 + 50 条轨迹断言 | M1 验收（`test_m1_redteam.py` / `m1_trajectory_stats.py`） | **迁移对照基线**：迁移后任何一条变红 = 行为漂移 |

这些对象解决的是"手写一个安全的单 Agent"。本章开始回答的问题只有一个：**如果交给 LangChain 1.x 的 `create_agent`，哪些样板代码可以省掉，哪些边界必须由你重新声明？**

完成后你应该能回答：

1. LangChain 1.x 提供哪些应用层抽象？它们与 M0/M1 里手写的构件一一对应到哪？
2. `create_agent` 与 LangGraph 是什么关系？为什么"用了 `create_agent`"不等于"懂了 LangGraph"？
3. 学习边界三档（必学/理解即可/暂缓）各含哪些内容？判定标准是什么？
4. 迁移到框架后，哪些边界仍然是你自己的（权限、幂等、错误映射、证据校验）？

## 2. 本章完成标准

必须同时满足：

- 能画出「LangChain 应用层抽象 → LangGraph 执行引擎」的分层图，并在图上标注每个抽象对应 M1 的哪个手写构件；
- 能默写并解释第 4 阶段三条权威契约：`AgentContext`（`frozen` dataclass，`user_id/tenant_id/scopes/request_id`）、`ToolStrategy(AgentAnswer)`（`status` 三态 + `answer` + `evidence_ids`）、`E_*` 错误码集合，**不改名**；
- 能说出分层目录 `api/ application/ agent/ tools/ domain/ infrastructure/` 每一层"放什么、不放什么"，以及两条硬边界（路由不直接建 Agent、Tool 不越过业务服务直接改表）；
- 能把「必学/理解即可/暂缓」三档落到具体 API，并说清"暂缓旧版 `LLMChain`/`AgentExecutor`"的理由；
- 能讲清「框架负责编排、不负责边界定义」，并给出至少 2 个边界例子（停止条件语义、权限钩子、证据校验）。

## 3. LangChain 1.x 是什么：一组应用层抽象

LangChain 不是"一个 Agent 产品"，也不是"一个大而全的框架"。在 1.x 里，它收敛为一组**应用层抽象**，每层解决一个明确问题：

| 抽象 | 解决什么 | 对应 M1 手写构件 |
| --- | --- | --- |
| Model | 把供应商差异封装为统一聊天模型接口 | `ModelGateway` / `LoopModel` Protocol |
| Message | 带角色、内容块、工具调用、元数据的对话单元 | `Message = dict[str, str]` |
| Tool | 带名称、描述、参数 Schema 的可执行能力 | `ToolSpec` + `ToolRegistry.resolve/execute` |
| Structured Output | 输出 Schema 校验与有限的修复重试 | `AgentTurn` + Pydantic `extra="forbid"` |
| Middleware | 模型/工具调用前后的横切策略（路由、裁剪、观测） | M1 未单列，散在 Loop 里 |
| Runtime Context | 本次运行不可由模型篡改的依赖（身份/权限） | `permissions` 集合注入 |
| `create_agent` | 把上述抽象拼成带动态 Tool Loop 的 Agent | `agent/loop.py` 的 `while` 循环 |

关键判断：M1 手写时你逐行实现了"组装 messages → 解析动作 → 校验/授权/执行工具 → 判定停止 → 记录轨迹"这五件事。LangChain 把这些**编排样板**打包成了抽象，但**边界的语义**（停止条件怎么算、权限点怎么切、证据怎么校验）它一个都没替你定义——这正是下一节"框架不是架构"要展开的。

## 4. `create_agent` 与 LangGraph 的关系

第 4 阶段权威入口是：

```python
from langchain.agents import create_agent
```

`create_agent` 是**便捷入口**，不是独立引擎：它在底层把"模型 ↔ 工具"的动态循环编译成一个 LangGraph 图。因此它天然具备图的扩展路径：

- **Checkpoint 持久化**：运行状态可落盘、可恢复；
- **Interrupt / Human-in-the-loop**：高风险写工具可以挂起等待审批（对应 M1 的 `awaiting_approval`）；
- **流式事件**：按事件粒度向前端推送（对应第 5 章）；
- **作为子图嵌入更大的 StateGraph**：单 Agent 可以是一个大工作流里的一个节点。

这带来一张心智地图：

```text
┌────────────────────────────────────────────────────────────┐
│  应用层抽象（LangChain 1.x，本阶段主用）                       │
│  Model · Message · Tool · Structured Output · Middleware    │
│  Runtime Context · create_agent                             │
└─────────────────────────────┬──────────────────────────────┘
                              │ create_agent 底层编译为图
                              ▼
┌────────────────────────────────────────────────────────────┐
│  LangGraph（图执行引擎，第 6 阶段主用）                        │
│  节点/边 · State/Reducer · Checkpoint · Interrupt · 流式事件  │
└────────────────────────────────────────────────────────────┘
```

这条边界直接决定学习策略：**简单动态工具循环用 `create_agent`；需要显式状态机、固定业务流程、审批分支、补偿恢复时，才直接设计 Graph。** 本章只立边界，不展开 Graph（那是第 6 阶段的事），但你要从现在就知道"框架替你接好了哪条上升通道"。

## 5. 分层目录：框架不是架构

第 4 阶段统一的分层目录如下，后续章节都会往里填代码：

```text
agent-service/src/agent_service/
├── api/             # 自有 HTTP/SSE 契约（FastAPI 路由、SSE 事件、错误映射）
├── application/     # 用例编排，鉴权后组装 AgentContext
├── agent/           # create_agent、system_prompt、Middleware 装配
├── tools/           # @tool 定义与业务服务适配器（薄封装）
├── domain/          # 设备/告警/工单规则、错误码 E_*、证据契约
└── infrastructure/  # 模型网关、数据库、LangSmith、日志
```

每层职责与两条硬边界：

- `api/` 只负责把 HTTP/SSE 契约翻译成用例调用，**不直接创建 Agent**——创建 Agent 需要已经通过鉴权的 `AgentContext`，那是 `application/` 的职责；
- `tools/` 里的 `@tool` 只做参数适配 + 身份校验 + 调用应用服务，**不越过业务服务直接改任意表**；
- `domain/` 承载业务规则和 `E_*` 错误码，是唯一能"说业务语言"的层；
- `infrastructure/` 收敛模型网关、数据库、观测，框架对象**不穿透到 `domain/` 和 `api/`**。

**框架不是架构。** 这句话是本章最重要的一句。LangChain 给了你编排骨架，但下面这些架构决策它一样都不替你定：

- 数据所有权与租户隔离（谁能读谁的设备/告警）；
- 权限模型与工具分级（只读 / 可逆写 / 高风险写）；
- 幂等与副作用（写操作怎么防重复、怎么补偿）；
- 错误码契约（`E_*`）与对外脱敏口径；
- 对外协议与验收指标（什么算一次越权、怎么自动断言）。

把 LangChain 的分层当架构，等于把供应商 SDK 的目录结构当成自己的业务规范。第 3 阶段你已经证明了：六条红队用例没有一条是靠"换个更会说话的 Prompt"解决的。迁移到框架后，这六条边界**仍然必须由你的确定性代码承担**，框架只是换了个地方让你声明它们。

## 6. 学习边界：三档

LangChain 生态很大，但本阶段只用其中一小块。按"必学 / 理解即可 / 暂缓"三档切，避免把时间花在过时 API 上。

### 6.1 必学

- **Message**：角色、内容块、工具调用与元数据，消息顺序与调用 ID 配对（下一章展开）；
- **Tool**：`from langchain.tools import tool, ToolRuntime`，身份从 `runtime.context` 注入，**不由模型填写**；
- **Structured Output**：`ToolStrategy(AgentAnswer)`，以及"直接传 Schema / `ProviderStrategy` / `ToolStrategy`"三选一；
- **`create_agent`**：`from langchain.agents import create_agent`，`context_schema`、`response_format`、`system_prompt` 的装配；
- **Middleware**：`before_* / after_* / wrap_*` 的执行顺序与横切策略（第 4 章展开）；
- **Runtime Context**：`AgentContext` 由已验证 Token 的 API 层创建，运行中不可篡改；
- **流式事件**：向前的 SSE 协议对接（第 5 章展开）。

### 6.2 理解即可

- **Runnable 组合**：`invoke/ainvoke/stream/batch` 的统一语义，用于确定性管道，不做深入链式嵌套；
- **各 Provider 的 Model 适配细节**：以"能切模型"为验收，不背每个 SDK 的边角参数；
- **LangGraph 图模型的基本概念**（State / Node / Edge）：只为第 6 阶段铺垫，本章不实现。

### 6.3 暂缓

- **旧版 `LLMChain`**：1.x 已不是推荐入口，旧链式 API 教程直接跳过；
- **旧 Agent Executor（`AgentExecutor` / `initialize_agent` / `AgentType`）**：已被 `create_agent` 取代，背它价值为负——它会污染你对当前版本的心智模型；
- **靠记忆大量历史 API**：版本会漂移，正确姿势是"确认版本 → 查 1.x 文档 → 概念映射到当前 API"，而不是复现旧视频里的代码。

判定的唯一标准是：**这个抽象在第 4 阶段的交付（设备查询与工单草稿单 Agent）里用不用得上，以及它是否是当前 1.x 的推荐入口。** 用不上的、过时的，一律暂缓。

## 7. 框架负责什么、不负责什么

把 M1 的对照做成一张"替代边界"表，这是本章交付的核心笔记：

| 编排能力 | 框架（LangChain 1.x）是否替代 | 你的职责 |
| --- | --- | --- |
| 消息历史 append、工具结果回传 | 是 | 只关注消息语义，不再手写 `messages.append` |
| 动态 Tool Loop（模型 ↔ 工具） | 是 | 通过 `create_agent` 声明工具集与 System Prompt |
| 结构化输出的 Schema 校验 + 有限修复 | 是 | 定义 `AgentAnswer`，并把修复次数限制在有限范围内 |
| Middleware 执行顺序 | 是 | 定义横切策略与顺序，并写测试锁定顺序 |
| 流式 / 持久化扩展路径 | 是（经 LangGraph） | 决定何时从 `create_agent` 升级到显式 Graph |
| 停止条件语义（`max_steps`、循环检测） | **否** | 你定义"重复调用"怎么算、上限给多少 |
| 权限钩子与工具分级 | **否** | `runtime.context.scopes` 校验 + `E_FORBIDDEN` 安全终止 |
| 业务校验（证据引用、设备 ID 一致性） | **否** | `evidence_ids ⊆ 本轮可见证据`，否则 `E_MODEL_OUTPUT_INVALID` |
| 错误码契约与对外脱敏 | **否** | 统一 `E_*`，堆栈/SQL/Token 不出边界 |
| 费用观测口径 | **否** | 记录 Usage + 异常增长告警，不设固定金额上限终止 |

一个最小装配示意（不是完整实现，`AgentContext` 必须由鉴权后的 API 层创建）：

```python
from dataclasses import dataclass
from typing import Literal

from langchain.agents import create_agent
from langchain.agents.structured_output import ToolStrategy
from langchain.tools import tool, ToolRuntime
from pydantic import BaseModel


@dataclass(frozen=True)
class AgentContext:
    user_id: str
    tenant_id: str
    scopes: frozenset[str]
    request_id: str


class AgentAnswer(BaseModel):
    status: Literal["answered", "needs_input", "refused"]
    answer: str
    evidence_ids: list[str]


@tool
async def get_alarm(equipment_id: str, runtime: ToolRuntime[AgentContext]) -> dict:
    """读取当前租户中指定设备的最新告警；仅用于查询。"""
    ctx = runtime.context
    if "equipment:read" not in ctx.scopes:
        raise PermissionError("E_FORBIDDEN: missing equipment:read")
    return await alarm_service.get_visible_alarm(
        tenant_id=ctx.tenant_id, equipment_id=equipment_id
    )


agent = create_agent(
    model=model,
    tools=[get_alarm],
    context_schema=AgentContext,
    response_format=ToolStrategy(AgentAnswer),
    system_prompt=SYSTEM_PROMPT,
)
```

注意两处刻意的边界：

1. `tenant_id` / `user_id` / `scopes` 全部来自 `runtime.context`，**不在 Tool 参数里让模型填写**——用户 Prompt 里伪造 `tenant_id` 不会改变运行时身份；
2. 权限校验在 Tool 函数体内做确定性抛错（`E_FORBIDDEN`），**不靠 Prompt 里的"你没有权限"**。Prompt 可以提醒模型，但安全边界只落在代码里。

`AgentContext` 的 `frozen=True` 保证它进入一次 run 后不可被中途篡改；它由 `api/` 层在验证 Token 后构造，经 `application/` 传入，绝不允许从请求 JSON 或用户消息里直接拼装身份字段。

## 项目任务

在本章不写完整 Agent 代码的前提下完成：

1. 画一张「LangChain 1.x 抽象 ↔ M1 手写构件」对照表，逐项标注"框架替代 / 未替代"，并补 2 个第 7 节之外的边界例子；
2. 新建第 4 阶段目录骨架 `api/ application/ agent/ tools/ domain/ infrastructure/`，把 M1 的 `tools.py`、`tool_registry.py` 归位到对应层，**保留 `agent/loop.py` 作为参考实现、不删除**；
3. 写一份简版 ADR（`docs/adr/0003-用create_agent迁移单Agent.md`）：记录"为什么用 `create_agent` 而不是继续手写 Loop、也不是直接上 LangGraph"，以及迁移对照基线；
4. 用最小代码验证 `from langchain.agents import create_agent` 与 `from langchain.tools import tool, ToolRuntime` 能导入，确认版本落在 `≥1.1,<2` 且由 `uv.lock` 固定；
5. 精读 Overview / Agents / Versioning 三篇官方文档，各产出 3 条笔记，且每条都用当前 API 重写一个最小示例。

## 常见错误与诊断顺序

### 手写 Loop 正常、迁移 `create_agent` 后红队用例变红

现象：某条 M1 红队用例（越权/循环/伪引用）迁移后从绿变红。根因：迁移引入**行为漂移**——停止条件语义或权限钩子没在新边界里重新声明，被框架默认行为覆盖。诊断：用同一组 50 条轨迹断言逐条对照，定位是哪一类边界（权限 / 循环 / 引用）在框架层被绕过或改变了语义，再回第 7 节确认"框架不负责"的清单。

### 旧视频里的 `initialize_agent` / `LLMChain` 跑不通

现象：照着旧教程抄代码，导入报错或行为对不上。根因：版本过时，1.x 已用 `create_agent` 取代旧 Agent 执行器。诊断：确认安装版本 → 查 1.x 官方文档与迁移指南 → 把旧概念映射到 `create_agent`/Runnable → **不要为了复现旧视频降级整个项目**。

### 把 `tenant_id` 当作 Tool 参数让模型填

现象：用户 Prompt 里伪造 `tenant_id` 就能读到别的租户数据。根因：身份来源错误，把"谁能看什么"交给了模型。诊断：身份必须从 `runtime.context` 注入，Tool 内部强制用 `ctx.tenant_id`；并写一条伪造测试，断言"用户消息里的 `tenant_id` 不影响结果"。

### 把 Prompt 当安全保证

现象：System Prompt 里写"你没有权限就拒绝"，但越权工具调用仍然发生。根因：安全边界放错了层，Prompt 只能提醒、不能约束。诊断：授权必须落在 Tool / 服务端的确定性代码（`E_FORBIDDEN`），并用红队用例"越权读取"自动断言 `status` 与 `error_code`，而不是断言日志里有没有报错。

## 练习题与答案

### 练习 1：既然 `create_agent` 底层是 LangGraph，还需要单独学 LangGraph 吗？

**答案：**要。`create_agent` 覆盖"单个 Agent + 动态工具循环"这一常见场景；一旦需要显式状态、审批分支、恢复补偿、并行分支和固定业务流程，就必须直接设计 Graph。两者是"便捷入口 vs 显式图"的关系，不是替代关系——`create_agent` 替你接好了升级通道，但通道的尽头（第 6 阶段）仍要你自己走过去。

### 练习 2：旧视频里的 API 跑不通怎么办？

**答案：**先确认安装版本，查 1.x 官方文档与迁移指南，再把旧概念映射到当前 API（如 `LLMChain` → Runnable、`AgentExecutor` → `create_agent`）；不要为了复现旧视频盲目降级整个项目。旧内容可提取 Prompt / Tool / State 等概念，但按当前 API 重写最小例子。

### 练习 3：「框架不是架构」具体指什么？

**答案：**框架给的是**编排骨架**（消息回传、工具循环、结构化输出、Middleware），架构决策——数据所有权、权限模型、幂等、错误码契约、对外协议、验收指标——仍然是你自己的。把框架的分层目录当成业务架构，等于把供应商 SDK 当业务规范，会丢掉"谁能读谁的设备"这类真正的架构问题。

### 练习 4：`AgentContext` 为什么用 `frozen=True`，且必须由 API 层创建？

**答案：**`frozen` 保证它进入一次 run 后不可被中途篡改（身份在运行中是常量）；由 API 层在验证 Token 后创建，保证身份来自可信鉴权而非请求体。两者共同切断"用户伪造身份"的路径，也让权限校验可以安全地依赖 `runtime.context`。

## 工程挑战

在不联网、不破坏 M1 既有测试的前提下完成：

1. 把 M1 的 3 个工具用 `@tool` + `ToolRuntime[AgentContext]` 重写，身份从 `runtime.context` 注入，并写一条"Prompt 伪造 `tenant_id`"的测试，断言结果仍绑定真实租户；
2. 写一个依赖方向检查：证明 `tools/` 不 import `infrastructure/` 的数据库连接、`agent/` 不 import `api/` 的路由（可用一个 20 行的 import 扫描脚本，或 `import-linter` 契约）；
3. 用 `ToolStrategy(AgentAnswer)` 让输出落到 `AgentAnswer` 三态，注入非法 JSON 断言修复重试有上限、连续失败返回 `E_MODEL_OUTPUT_INVALID`；
4. 离线跑一个 `create_agent` 最小冒烟（Fake 模型），断言 `result["structured_response"]` 能取出，真实 API 调用次数为 0。

参考方向：依赖方向检查用 AST 扫描 import 语句即可，不必上重工具；结构化输出修复上限参考 M1 的 `max_retries=0` 思路——"校验 → 失败 → 受控终态"优于无限重试；Fake 模型直接复用 M0 的 `FakeGateway`/`ScriptedGateway` 结构。

## 面试追问

### "你们为什么从手写 Agent Loop 迁移到 LangChain？"

回答框架：手写是为了搞清楚"框架替你做了什么、没替你做什么"；迁移是为了省掉消息回传、工具循环、结构化输出这些编排样板。迁移不是替换逻辑，而是**用同一套红队用例和 50 条轨迹断言做对照**——任何一条变红都说明迁移引入了行为漂移。结论落点：框架替代编排，不替代边界定义。

### "LangChain 的 `create_agent` 和 LangGraph 是什么关系？"

回答框架：`create_agent` 是便捷入口，底层把"模型 ↔ 工具"循环编译成一个 LangGraph 图，因此天然获得 Checkpoint、Interrupt、流式事件这些图能力；但它是单 Agent 场景的封装，需要显式状态机、审批分支、补偿恢复时直接设计 Graph。两者是"便捷入口 vs 显式图"的关系。

### "你们怎么保证模型不越权？"

回答框架：三层。一是身份从 `runtime.context` 注入（`frozen` 的 `AgentContext` 由鉴权后的 API 层创建），不可由模型填写；二是 Tool 内做确定性权限校验（`scopes` 检查，不足抛 `E_FORBIDDEN` 安全终止）；三是工具分级（只读 / 可逆写 / 高风险写），高风险写进入 Human-in-the-loop。Prompt 可以提醒模型，但不承担安全边界。

## 本章复盘模板

完成后记录：

```text
完成日期：
实际投入小时：
是否画出「LangChain 抽象 → LangGraph 引擎」分层图：
是否默写出 AgentContext / ToolStrategy(AgentAnswer) / E_* 错误码三条契约（不改名）：
「必学 / 理解即可 / 暂缓」三档是否各自落到具体 API：
能否说出「框架负责编排、不负责边界定义」并给出 2 个边界例子：
目录骨架是否建好且 M1 参考实现未被删除：
简版 ADR 是否记录了迁移决策与对照基线：
仍不理解的问题：
```

## 官方资料与中文阅读指引

- [LangChain Overview](https://docs.langchain.com/oss/python/langchain/overview)：1.x 的抽象全景，先通读建立地图，重点找 Model / Message / Tool / Structured Output 在文档里的位置；
- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)：`create_agent` 的官方入口，重点看它的循环、工具绑定与停止机制，用于第 7 节的"框架能替代"论证；
- [LangChain Versioning](https://docs.langchain.com/oss/python/versioning)：版本策略与迁移口径，用于识别过时教程、处理版本漂移；
- [LangGraph Overview](https://docs.langchain.com/oss/python/langgraph/overview)：`create_agent` 底层的执行引擎，第 6 阶段正式展开，本章只做背景阅读。

重点阅读：Agents 页里"框架替你管理循环"的部分，对照 M1 手写 `agent/loop.py` 看它替你省掉了哪些样板、又要求你重新声明哪些边界——这是面试里"你懂框架还是懂原理"的分水岭。任何 API 签名与示例代码，**以当前 1.x 官方文档为准**，不要照抄旧博客。

## 下一章入口

本章交付的是一个**心智模型**：LangChain 1.x 的抽象分层、`create_agent` 与 LangGraph 的关系、以及"框架不负责边界"的分界线。下一章《Model、Message、Tool 与 Runnable》开始落地这组抽象的最底层——把 M0 的 `ModelGateway` 映射到 LangChain 的 Model 抽象，把 M1 的 `Message = dict[str, str]` 映射到带角色、内容块、工具调用与元数据的 Message 类型，并回答"哪些组合该用 Runnable、哪些该交给 Agent"。届时你会发现，本章立的三条契约（`AgentContext`、`AgentAnswer`、`E_*`）在后续每一章都会被引用、且不得改名。
