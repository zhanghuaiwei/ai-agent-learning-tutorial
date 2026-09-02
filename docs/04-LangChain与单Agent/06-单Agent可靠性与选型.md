# 单 Agent 可靠性与选型

> 预计 5 小时｜目标：知道何时用 Agent，何时退回确定性代码，以及怎样让一个单 Agent 在失控前停下来。

## 1. 本章从哪里开始

第 1～5 章已经把一个设备维护单 Agent 完整搭了起来：`ModelFactory` 统一模型接口、`create_agent` 负责循环、`ToolStrategy(AgentAnswer)` 负责结构化输出、Middleware 负责身份与横切控制、SSE 12 事件负责对外协议。但这些章节都在回答"怎么搭"，本章回答一个更前置、也更容易被忽略的问题：**这件事到底该不该用 Agent 做，以及怎么保证它一定会停下。**

这是本章要偿还的两笔债：

1. **选型债**：前面每一章都在默认"这里需要一个 Agent"，但没有人论证过哪些查询其实一个普通函数就能解决。把确定性工作误塞进 Agent，是 Agent 项目最常见、成本最高的错误之一。
2. **可靠性债**：`create_agent` 的循环在框架内部，如果模型反复调用同一个工具、或者永远不产生终态，框架不会自动替你踩刹车。第 3 章已经给出 `E_*` 错误契约，但"最大步数、Deadline、循环检测"这些任务级边界还没落到一个明确的执行边界定义上。

读完本章你应该能回答：

1. 面对一个具体需求，用什么决策表在"普通函数 / 2-step RAG / 单 Agent / LangGraph / 多 Agent"之间做出可辩护的选择？
2. 一次任务凭什么在 4 次模型调用、6 次 Tool Call、20 秒内收敛？这些数值从哪里来、怎么从真实 Trace 校准？
3. 强模型降级到小模型为什么不总是对的？真正可靠的降级路径是什么？
4. 一份选型 ADR 至少要写清哪几件事，才能让三个月后的自己或同事不推翻重来？

## 2. 本章完成标准（通过门槛）

1. 能为 30 个真实/模拟任务逐一标注"普通函数 / RAG / 单 Agent / Graph / 多 Agent"，且每个标注都能说出"为何不是更简单的那一档"；
2. 用代码把执行边界（最大模型调用 4、最大 Tool Call 6、总时限 20 秒、相同动作连续 2 次即判定循环）接进 Agent 运行路径，命中即进入受控终态 `run.execution_limit_reached`；
3. 费用只记录到 Trace 并做异常增长告警，**不设固定金额上限**（教程费用治理约定见第 1 阶段第 5 章）；
4. 产出一份选型 ADR（`docs/adr/0004-单Agent选型与执行边界.md`），记录决策、备选、证据与后果。

## 3. 选型决策表

选型的核心原则只有一句：**先用最小可控方案，把复杂度的引入推迟到证据出现之后。** 多 Agent 不是"高级版单 Agent"，它会同时增加提示、路由、上下文、观测、费用和故障组合；LangGraph 不是"万能的 Agent"，它是"有状态、可暂停恢复的工作流"。

| 需求特征 | 优先方案 | 判断依据 |
| --- | --- | --- |
| 路径固定、规则稳定 | 普通函数 / Workflow | 没有需要模型推理的分支，确定性代码可测试、零费用、零延迟 |
| 只是检索后回答，无需多步工具编排 | 2-step RAG | 检索 + 生成就够了，强行套 Agent 循环只会增加回合与费用 |
| 需要从少量工具中动态选择 | 单 Agent | 模型需要根据语义决定"查手册还是查告警"，这是 `create_agent` 的主场 |
| 有审批、暂停恢复、复杂状态机 | LangGraph | 需要 `Interrupt` + Human-in-the-loop + Checkpoint，超出无状态循环的能力 |
| 多领域上下文隔离且可独立评测 | 子图 / 少量多 Agent | 各领域工具与上下文边界清晰，混在一个 Agent 会互相污染 |

判定顺序建议用"往上加复杂度要付出代价"的视角，而不是"往下减复杂度损失能力"：

1. 先问"能不能不调用模型就完成？"（普通函数）
2. 再问"能不能只用一次检索加一次生成完成？"（2-step RAG）
3. 再问"是否需要模型根据中间结果动态决定下一步工具？"（单 Agent）
4. 最后才问"是否有需要人类审批、暂停恢复的复杂状态？"（LangGraph）或"上下文是否大到必须隔离？"（多 Agent）

> 智维 Agent 项目里，`get_alarm` 的"查询单个设备最新告警"本质上是一个带租户隔离的确定性查询。它之所以还需要 Agent，是因为用户会用自然语言同时表达"查手册 → 查告警 → 建工单草稿"这种组合意图。如果用户只问"EQ-001 告警是什么"，最诚实的选择是一个普通 API 调用，而不是让模型绕一圈再决定调 `get_alarm`。

## 4. 可靠性执行边界

单 Agent 最危险的失败模式不是"答错"，而是"停不下来"。答错会被评测发现；停不下来会持续消耗 Token、占用上游连接、堆积副作用，且难以回滚。所以执行边界必须是**确定性代码**，不能是 Prompt 里一句"请不要重复"。

### 4.1 四个边界及其语义

| 边界 | 建议值 | 命中后果 | 为什么需要它 |
| --- | --- | --- | --- |
| 最大模型调用 | 4 次 | `run.execution_limit_reached` | 防止模型反复"再想一次"而不产出终态 |
| 最大 Tool Call | 6 次 | `run.execution_limit_reached` | 防止工具链无限延伸 |
| 总时限 Deadline | 20 秒 | `run.execution_limit_reached` | 保护上游与前端体验，超时即止损 |
| 循环检测 | 相同工具 + 规范化参数连续 2 次 | `run.execution_limit_reached` | 防止"查 A → 再查 A → 再查 A"空转 |

循环检测的关键在"规范化参数"：把参数按稳定顺序序列化后比较，避免模型把 `{"equipment_id":"EQ-001"}` 和 `{"equipment_id": "EQ-001"}` 判成两个动作而漏报。同时要避免误伤正常路径——"先查 A 告警、再查 B 告警"是两次不同 `equipment_id` 的合法调用，不是循环（见 §9 工程挑战第 2 条）。

### 4.2 数值不是真理，是起点

这组数值不是从天上掉下来的，而是从真实 Trace 里"读"出来的：统计正常任务完成的模型调用分布，取一个能覆盖 95% 任务的宽松上界，再留一点余量。你的项目里应该有一份脚本，把每个任务的 `step_count`、`tool_call_count`、`elapsed_ms` 落库，然后定期重算阈值。**固定数值 + 定期校准**，才是执行边界的正确打开方式，而不是拍脑袋写死。

### 4.3 费用只观测、只告警，不设金额上限

与执行边界不同，费用治理**不设"累计金额上限"这类会中途终止任务的逻辑**。做法是：每次调用的 Token 与费用写进 Trace（含模型、输入/输出 Token、单价、时间戳），单独一条"异常增长"监控——当日费用环比超过阈值时告警，由人去判断是否要降级模型或收紧路由。理由：金额上限会让一个长任务在用户最需要结果时被掐断，而"观测 + 异常告警"在保留可用性的同时提供了治理抓手。

## 5. 执行边界的代码落点

边界必须接在"Agent 运行路径"上，而不是写在评测脚本外面。下面是一个把四个边界包成运行守卫的骨架（节选）：

```python
# src/agent_service/limits.py
from dataclasses import dataclass, field
import time

@dataclass
class ExecutionLimits:
    max_model_calls: int = 4
    max_tool_calls: int = 6
    deadline_seconds: float = 20.0
    max_repeat_same_action: int = 2

@dataclass
class RunGuard:
    limits: ExecutionLimits
    started_at: float = field(default_factory=time.monotonic)
    model_calls: int = 0
    tool_calls: int = 0
    _last_actions: list[str] = field(default_factory=list)

    def check_deadline(self) -> None:
        if time.monotonic() - self.started_at > self.limits.deadline_seconds:
            raise ExecutionLimitReached("E_DEADLINE")

    def note_model_call(self) -> None:
        self.model_calls += 1
        if self.model_calls > self.limits.max_model_calls:
            raise ExecutionLimitReached("E_MAX_STEPS")

    def note_tool_call(self, name: str, normalized_args: str) -> None:
        self.tool_calls += 1
        if self.tool_calls > self.limits.max_tool_calls:
            raise ExecutionLimitReached("E_MAX_STEPS")
        key = f"{name}:{normalized_args}"
        self._last_actions.append(key)
        if len(self._last_actions) > self.limits.max_repeat_same_action:
            self._last_actions.pop(0)
        if (len(self._last_actions) == self.limits.max_repeat_same_action
                and len(set(self._last_actions)) == 1):
            raise ExecutionLimitReached("E_LOOP_DETECTED")
```

`ExecutionLimitReached` 会被统一映射为 `run.execution_limit_reached` 终态（第 5 章 SSE 事件契约中的 `run.execution_limit_reached`），错误码沿用第 3 阶段定下的 `E_MAX_STEPS` / `E_DEADLINE` / `E_LOOP_DETECTED`。注意：这些是**运行期边界**，与第 3 章 `ToolStrategy` 的"结构化输出修复重试"是两层——后者只管单次输出校验，前者管整次任务的收敛。

## 6. 降级路径：为什么"强转小"常是陷阱

一个流行的直觉是"强模型失败时换小模型省钱兜底"，这在大多数场景下是错的：

1. **失败未必是模型不够强**，更可能是输入本身有问题（越权、对象不存在、上下文缺失）。换小模型只会换一种方式错；
2. **小模型不一定省钱省到点子上**，它可能多绕几次、多调几个工具，反而更贵；
3. **"重试 + 换模型"会掩盖真正的失败语义**，让上游等更久才拿到一个坏结果。

真正可靠的降级路径是**降能力、不降正确性**：

| 触发 | 降级动作 | 用户看到什么 |
| --- | --- | --- |
| 越权 / 对象不可见 | 直接 `E_FORBIDDEN` / `E_NOT_FOUND`，不换模型重试 | 明确"无权限/未找到"，不泄漏其他租户 |
| 多步编排跑偏 | 返回**已取得的证据** + 安全错误码 | 部分结果 + 引导，而非凭空编造 |
| 写操作无法确认 | 返回已生成的工单草稿 + 幂等键 | 草稿可续作，不重复建单 |
| 死循环 / 超时 | 返回只读结果或"任务超时，请缩小范围" | 可继续人工，不无限重试 |

一句话：**降级的目标是"把已取得的、可信的那部分交还给用户并引导人工继续"，而不是"换个更便宜的模型把完整流程再赌一遍"。**

## 7. 选型 ADR 骨架

选型不是写完代码才补的说明，而是动手前就要落地的决策记录。一份最小可用 ADR 至少包含以下字段，直接存到 `docs/adr/`：

```markdown
# ADR-0004：单 Agent 选型与执行边界

## 状态
已接受（2026-09-02）

## 背景
用户用自然语言表达"查手册 + 查告警 + 建工单草稿"的组合意图，需要模型动态选择工具。
但单个确定查询（如"EQ-001 告警"）并不需要 Agent。

## 决策
- 组合意图 → 单 Agent（create_agent + 三个工具）
- 单个确定查询 → 普通 API，不走 Agent 循环
- 执行边界：模型调用 ≤4、Tool Call ≤6、Deadline 20s、相同动作 ≤2 次
- 费用：只观测 + 异常告警，不设累计金额上限

## 备选方案
1. 全部走普通函数：组合意图的表达能力不足，需手写大量 if/else
2. 直接上 LangGraph：当前无审批/暂停恢复需求，引入状态机复杂度过早
3. 多 Agent：三个工具上下文边界不清，多 Agent 只会增加路由与费用

## 后果
- 正面：最小复杂度满足组合意图；执行边界可控、可观测
- 负面：未来若加入"工单审批流"，需评估迁移到 LangGraph 的成本（Interrupt + Checkpoint）
- 需要持续：定期从 Trace 校准执行边界数值
```

ADR 的价值在于"后果"一节——它逼你承认每个决策的代价，并给出"什么信号出现时该重新评估"。

## 8. 项目任务

1. 准备 30 个任务样本（覆盖：单个确定查询、组合查询、检索问答、需要审批的写操作、跨领域协作），逐一标注应使用"普通函数 / 2-step RAG / 单 Agent / LangGraph / 多 Agent"，并给每个标注写一句"为何不是更简单的那一档"；
2. 实现 `src/agent_service/limits.py` 的 `RunGuard`，把四个执行边界接进 Agent 运行路径，命中即映射为 `run.execution_limit_reached`；
3. 写 `tests/test_limits.py`：正常任务不误伤、单边界分别命中、循环检测能区分"相同动作重复"与"不同参数的合法连续调用"；
4. 实现费用 Trace 写入 + 异常增长告警（只观测、不设金额上限），并加一条测试证明"不存在以固定金额终止调用的逻辑"；
5. 产出 `docs/adr/0004-单Agent选型与执行边界.md`，按 §7 骨架填写，并连同代码一起提交。

## 9. 常见错误与诊断顺序

### 9.1 把"能跑"当成"该用 Agent"

看到 `create_agent` 能跑通就认定该用 Agent，是最大的误区。诊断顺序：先问"这个任务有没有需要模型推理的分支"，没有就退回普通函数或 2-step RAG；有，再问"分支的中间结果是否决定下一步工具"，是才轮到单 Agent。

### 9.2 执行边界写进 Prompt 而不是代码

"请不要重复调用同一个工具"这种 Prompt 约束可以被模型无视，也可能被用户注入绕过。诊断顺序：确认循环检测、最大步数、Deadline 是否落在 `RunGuard` 这类确定性代码里，而不是系统提示词里。

### 9.3 循环检测误伤正常路径

把"调了两次 `get_alarm`"一律判成循环，会误伤"先查 A 再查 B"的合法场景。诊断顺序：确认循环判定用的是"规范化参数 + 连续次数"，且对"同工具、不同参数"留了反例测试。

### 9.4 用"换小模型"掩盖失败

任务失败就换模型重试，等于把失败语义吞掉。诊断顺序：先看错误码是 `E_FORBIDDEN`/`E_NOT_FOUND`（换模型无用）还是 `E_MODEL_OUTPUT_INVALID`（才考虑模型能力），再决定是否调整模型或降级路径。

## 10. 练习题与答案

### 练习 1：设备状态查询需要 Agent 吗？

**答案：**单个确定查询通常不需要。`get_alarm` 本身是一个带租户隔离的确定性读取，如果用户只问"EQ-001 的告警"，一个普通 API 调用即可；只有自然语言需要**组合多个查询并解释结果**时，才考虑让 Agent 动态选择工具。

### 练习 2：多 Agent 是否自动提升质量？

**答案：**否。只有职责、上下文、工具和评测边界确实可分时才可能获益，否则只会增加路由开销、错误传递和费用。多数"看起来要多个 Agent"的任务，用一个单 Agent 加清晰工具描述就能解决。

### 练习 3：为什么执行边界不能只靠 Prompt？

**答案：**Prompt 是软约束，模型可被诱导或无视；执行边界必须落在确定性代码（`RunGuard`）里，命中即进入受控终态 `run.execution_limit_reached`，且错误码可观测、可测试、可复现。

### 练习 4：费用治理为什么"只观测 + 告警"而不是设金额上限？

**答案：**金额上限会在长任务中途掐断调用，牺牲可用性；观测 + 异常增长告警在保留可用性的同时提供治理抓手——把"是否降级、是否收紧"的决定权交给人，而不是让一段代码替用户放弃结果。

## 11. 工程挑战

在不联网、不破坏既有测试的前提下完成：

1. 给 `RunGuard` 的循环检测写一个"规范化参数"单元测试，证明 `{"equipment_id":"EQ-001"}` 与 `{"equipment_id": "EQ-001"}` 被归一化后能识别为同一动作；
2. 写一个"相同工具、不同参数"的反例，证明不会误伤"先查 A 告警、再查 B 告警"的正常路径；
3. 实现 `run.execution_limit_reached` 终态在 SSE 上的互斥与只发一次断言（复用第 5 章 stream adapter）；
4. 用 §3 决策表回看前三章已实现的 `search_manual` / `get_alarm` / `create_work_order_draft`，各写一句"这个工具在什么输入下其实不需要 Agent"，作为选型复盘。

## 12. 面试追问

### 12.1 "你们怎么决定一个功能该用 Agent 还是普通代码？"

回答框架：给决策表——普通函数（路径固定）、2-step RAG（只检索后回答）、单 Agent（需动态选工具）、LangGraph（审批/暂停恢复）、多 Agent（上下文隔离）。强调原则是"先用最小可控方案，复杂度推迟到证据出现"，并举例：单个确定查询走普通 API，组合意图才走 Agent。

### 12.2 "Agent 停不下来怎么办？"

回答框架：四个确定性执行边界——最大模型调用、最大 Tool Call、总时限 Deadline、循环检测（相同工具 + 规范化参数连续 N 次），命中即进入 `run.execution_limit_reached` 受控终态；数值从真实 Trace 校准。补充：这些边界落在代码而非 Prompt，且费用只观测 + 异常告警、不设金额上限。

### 12.3 "模型失败直接换小模型兜底有什么问题？"

回答框架：失败未必是模型不够强（越权/未找到/上下文缺失换模型无用），小模型可能多绕更贵，且掩盖失败语义。正确降级是"降能力不降正确性"——返回已取得的证据、只读结果或工单草稿，引导人工继续。

## 13. 本章复盘模板

```text
完成日期：
实际投入小时：
30 个任务样本是否逐一标注且每个都有"为何不是更简单一档"的理由：
RunGuard 四个执行边界是否接入运行路径并命中受控终态：
循环检测是否区分"相同动作重复"与"不同参数合法连续调用"：
费用是否只观测 + 异常告警，是否存在以固定金额终止调用的逻辑：
降级路径是否"降能力不降正确性"而非"换小模型重试"：
是否产出选型 ADR（含决策/备选/证据/后果）：
仍不理解的问题：
```

## 14. 官方资料与中文阅读指引

- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)：重点看 Agent 循环的停止机制与工具绑定，用于 §4 执行边界的"框架负责什么、你必须自己做什么"；
- [LangGraph Workflows and agents](https://docs.langchain.com/oss/python/langgraph/workflows-agents)：官方对"何时用 Workflow、何时用 Agent"的定位，直接对应 §3 决策表；
- [LangChain Structured output](https://docs.langchain.com/oss/python/langchain/structured-output)：`ToolStrategy` 的修复重试边界，用于区分"输出校验重试"与"任务级执行边界"两层；
- [LangChain Tools](https://docs.langchain.com/oss/python/langchain/tools)：工具描述如何影响选择准确率，用于 §9.1 的诊断。

重点阅读：Agents 的停止/循环机制与 LangGraph 的 Workflows vs agents 定位；其余细节以锁定的 LangChain/LangGraph 版本官方文档为准，不凭记忆写 API。

## 15. 下一章入口

本章回答了"该不该用 Agent、怎么让它停下"，并用一份 ADR 把选型与执行边界固化下来。下一章进入第 4 阶段的里程碑——M2 验收（第 7 章），把第 1～6 章的交付物整合成可复跑的验收证据：工具选择准确率、参数结构有效率、越权拦截率、任务终止率四项定量门槛，正是本章执行边界与第 3 章 `E_*` 契约的落点校验。

**关键闸门**：如果现在还不能回答"某个具体查询为什么需要 Agent 而不是普通函数"，说明选型决策表没过关，先补 §8 的 30 个任务标注，再进入 M2——否则验收测出来的"工具选择准确率"是建立在错误前提上的数字。
