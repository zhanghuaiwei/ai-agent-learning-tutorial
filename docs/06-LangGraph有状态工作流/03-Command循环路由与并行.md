# Command、循环、路由与并行

> 预计 7 小时｜产出：有界路由与并行上下文收集。

> **阅读前置**：本章是第 6 阶段（LangGraph 有状态工作流）第 3 章，承接第 2 章的 State/Node/Edge/Reducer，落地“流转”三件事：节点内路由（`Command`）、有界循环、并行与动态 Fan-out。前置要求：第 2 章的 `WorkOrderState` 与 `route_after_diagnosis` 路由函数。本章的 `Command(update=..., goto=...)` 是第 6 章 Interrupt 恢复入口 `Command(resume=...)` 的前置概念。

## 1. 本章从哪里开始

第 2 章的骨架里，路由全靠 `add_conditional_edges`，循环用 `request_missing_input → diagnose` 的边来表达。但真实工单流程有三个需求用纯“条件边”表达很别扭：

1. **动作与路由紧密相关**：诊断结果既更新 State（写入 `diagnosis`/`risk_level`），又决定下一跳（进草稿还是补输入），把两者拆进两个函数会割裂；
2. **循环要有界**：证据不足时允许改写查询，但不能无限改写；
3. **并行**：告警、资产、手册三路检索互不依赖，串行太慢，并行又要面对合并与降级。

本章把这三件事讲透，产出“证据不足 → 改写一次 → 拒答”的有界循环与可降级的并行上下文收集。

## 2. 本章完成标准（通过门槛）

- 能用 `Command(update=..., goto=...)` 在节点内同时更新 State 并指定下一跳，且知道它与条件边的取舍；
- 诊断循环用 `query_rewrite_count` 显式计数，最多改写两次，第二次仍无证据即进入结构化拒答；
- 并行分支的合并由 Reducer 承接，任一分支失败可解释、可降级（如手册服务降级仍返回告警但不给维修结论）；
- 动态 Fan-out 用 `Send` 且有数量上限与 `max_concurrency` 上限，分支顺序不影响最终结果；
- 路由值封闭为 `Literal`，未知值进 `failed`。

## 3. `Command`：在节点内同时更新与路由

`Command` 是 LangGraph 的“控制原语”，让一个节点既返回 State 更新，又指定下一跳。典型场景：诊断完成后，根据风险级别直接决定进草稿还是补输入：

```python
from langgraph.types import Command


async def diagnose(state: WorkOrderState) -> Command:
    result = await model_diagnose(state["evidence_ids"])

    if result.needs_input:
        return Command(
            update={"query_rewrite_count": state.get("query_rewrite_count", 0) + 1},
            goto="request_missing_input",
        )
    return Command(
        update={"diagnosis": result.diagnosis, "risk_level": result.risk_level},
        goto="create_draft",
    )
```

`Command` 与条件边的取舍：

| 方式 | 适用 | 优点 | 代价 |
| --- | --- | --- | --- |
| 条件边 `add_conditional_edges` | 路由与节点计算可分离 | 图更容易可视化、路由函数可独立单测 | 需额外路由函数 |
| `Command(update=..., goto=...)` | 动作与路由强相关 | 逻辑内聚，少一个函数 | 路由藏进节点，图的可视化变差 |

原则：**不要为追求 API 技巧把所有边藏进 Node**。能被条件边清晰表达的，用条件边；只有“结果与下一跳天然一体”时用 `Command`。第 6 章的 `review_draft` 用 `Command(update=..., goto=...)` 正是后一种——审批结果直接决定去 `revalidate`、`edit_draft` 还是 `cancelled`。

## 4. 有界循环：查询改写

“证据不足 → 改写查询 → 再检索 → 仍无证据 → 拒答”是一个典型循环。循环必须有界，否则就是无进展空转。智维 Agent 的边界是 `query_rewrite_count` 最多 2 次：

```python
MAX_QUERY_REWRITE = 2


def route_after_diagnosis(state: WorkOrderState) -> str:
    if state.get("error_code"):
        return "fail"
    if not state.get("evidence_ids") and state.get("query_rewrite_count", 0) < MAX_QUERY_REWRITE:
        return "need_input"          # 还有改写额度，回去补输入再检索
    if not state.get("evidence_ids"):
        return "no_evidence"         # 额度用尽，结构化拒答
    return "draft"
```

要点：

1. **显式计数**在 State 里（`query_rewrite_count`），每次改写前递增，而不是靠“感觉”判断循环了几次；
2. **全局 `recursion_limit` 只做最后保险**，不能替代业务计数——它只能粗暴终止整张图，无法给出“已改写两次仍无证据”的可解释拒答；
3. **终态明确**：额度用尽必须进入结构化拒答（`no_evidence`/`failed`），不停留在“处理中”。

这对应第 10 章 M4 的练习 3：局部计数能形成可解释拒答，全局限制只做最后保险。

## 5. 并行：Super-step 语义

告警查询、资产查询、手册检索互不依赖，可并行。LangGraph 按 **Super-step** 执行：同一步中多个活跃节点可并行运行，下一步通常在它们全部完成后继续。两个关键认知：

1. **并行完成顺序不是业务排序依据**：三个分支谁先回来不确定，需要稳定顺序时返回显式 `position`/`id`，聚合后排序；
2. **Reducer 必须处理多分支更新**：三支都往 `evidence_ids` 写，默认覆盖会丢两支，需要 `operator.add` 或显式聚合（第 2 章 §5）。

并行放大上游压力，必须设置**并发上限**（`max_concurrency`）、**每分支超时**和**总时限**。LangGraph 提供 `max_concurrency` 限制同时执行的节点数，调用时配置：

```python
config = {
    "configurable": {"thread_id": owned_thread_id},
    "max_concurrency": 3,
    "recursion_limit": 30,
}
result = await graph.ainvoke(initial_state, config=config)
```

不是所有分支失败都要整次失败：手册服务降级时，仍可返回实时告警，但**不得给出维修结论**（缺手册证据就下结论是伪引用）。降级策略要写进聚合节点的逻辑，而不是让模型“看情况”。

## 6. `Send`：动态 Fan-out（Map-Reduce）

当分支数量或每个分支输入在**运行时**才知道时，用 `Send(node, state)` 做动态 Fan-out。例如对检索到的多个手册章节并行做安全摘要：

```python
import operator
from typing import Annotated
from typing_extensions import TypedDict

from langgraph.types import Send


class OverallState(TypedDict):
    chunk_ids: list[str]
    summaries: Annotated[list[dict], operator.add]


def fan_out(state: OverallState) -> list[Send]:
    return [
        Send("summarize_chunk", {"chunk_id": chunk_id})
        for chunk_id in state["chunk_ids"][:10]
    ]


async def summarize_chunk(state: dict) -> dict:
    summary = await summarize_by_id(state["chunk_id"])
    return {"summaries": [{"chunk_id": state["chunk_id"], "text": summary}]}
```

`Send` 与固定并行 Edge 的取舍：

| 方式 | 适用 | 例子 |
| --- | --- | --- |
| 预画 N 条并行 Edge | 拓扑固定、分支数已知 | 告警 + 资产 + 手册三路固定并行 |
| `Send` | 分支数/输入运行时确定 | 检索出 7 个章节，逐章摘要 |

两条硬约束：

1. **分支数必须限制**：不能让模型生成 10,000 个主题后直接创建 10,000 个 `Send`。代码里 `[:10]` 就是上限，还要校验 `chunk_ids` 来源（当前租户本次检索）；
2. **`max_concurrency` 限制同时执行数**：`Send` 决定了“有多少分支”，`max_concurrency` 决定了“同时跑多少”，两者都要有。

## 7. 并行合并的稳定顺序

并行分支返回后，`operator.add` 的合并顺序由完成先后决定，可能导致结果抖动。需要稳定顺序时：

```python
async def summarize_chunk(state: dict) -> dict:
    return {
        "summaries": [{
            "position": state["position"],   # 显式排序键
            "chunk_id": state["chunk_id"],
            "text": await summarize_by_id(state["chunk_id"]),
        }]
    }

def aggregate(state: OverallState) -> dict:
    ordered = sorted(state["summaries"], key=lambda s: s["position"])
    return {"final_summary": "\n\n".join(s["text"] for s in ordered)}
```

关键：**别依赖“完成顺序”当排序依据**，显式 `position`/`id` + 聚合后排序才是确定的。

## 8. 项目任务

1. 并行执行告警、资产、知识检索（三路固定并行），聚合时对 `evidence_ids` 去重并校验租户来源；
2. 实现“证据不足 → 改写一次 → 拒答”的有界循环，用 `query_rewrite_count` 计数，断言第二次仍无证据进 `no_evidence`；
3. 注入一个分支超时，验证降级路径：手册分支失败，告警/资产仍返回，最终不下维修结论；
4. 实现一个最多 5 个 Chunk 的 `Send` Map-Reduce，对比分支顺序变化时最终结果是否稳定；记录并发 1、3、5 的 P95 与上游错误率。

## 9. 常见错误与诊断顺序

### 9.1 循环靠“感觉”终止，没有计数

根因是把循环上限写进 Prompt 让模型“自觉”。诊断顺序：先加 State 字段计数 → 路由函数显式判断上限 → 额度用尽进明确终态。`recursion_limit` 只做最后保险，不能当业务边界。

### 9.2 并行结果抖动

三路并行的结果每次顺序不同，断言时对不齐。诊断顺序：检查是否用了 `operator.add` 且依赖完成顺序 → 加显式 `position`/`id` → 聚合后排序。顺序不稳是合并设计问题，不是框架问题。

### 9.3 一个分支失败整次全挂

手册服务降级却把整次诊断判失败。诊断顺序：明确“最小成功集合” → 聚合节点标记缺失分支 → 降级输出（有告警无手册时不给结论）。不能把“缺失”误当成“无风险”。

### 9.4 `Send` 分支数失控

模型生成了海量主题直接 Fan-out。诊断顺序：代码里对分支数硬上限 → 校验 `chunk_ids` 来源 → `max_concurrency` 限制并发。动态分支是能力也是攻击面。

## 10. 练习题与答案

### 练习 1：三个节点并行后延迟一定变成最大单节点延迟吗？

**答案：**理想情况下接近最大值，但还受调度、连接池、限流、合并和重试影响，必须测 P95。并行不减少最长分支的时间，只把“串行总和”变成“最长分支 + 合并开销”。

### 练习 2：模型能否直接返回节点函数名？

**答案：**不应。先将模型结构化结果映射到允许的业务枚举，再由代码选择节点。直接执行模型返回的字符串是命令注入/越权入口。

### 练习 3：何时使用 `Send` 而不是预先画五条并行 Edge？

**答案：**分支数量或每个分支输入在运行时才确定时使用 `Send`。若拓扑固定，普通 Edge 更直观、更容易审计。

### 练习 4：`Command` 什么时候比条件边更合适？

**答案：**当“动作结果”与“下一跳”强相关、拆开反而割裂时（如审批结果决定去 `revalidate`/`edit_draft`/`cancelled`）。能被条件边清晰表达的，优先用条件边以保持图可视化。

## 11. 工程挑战

1. 写一个“查询改写”路由的边界测试：`query_rewrite_count` 从 0 → 1 → 2，第三次无证据必须进 `no_evidence`，不允许进入 `need_input`；
2. 构造“手册分支超时但告警分支成功”的用例，断言最终输出含告警、不含维修结论，且 `error_code` 记录手册降级原因；
3. 对 `Send` Map-Reduce 写性质测试：`chunk_ids` 乱序输入时，聚合后的最终摘要字节完全一致。

参考方向：第 1 题直接对 `route_after_diagnosis` 表驱动；第 3 题用 `position` 排序保证确定性。

## 12. 面试追问

### 12.1 “为什么循环上限写在代码而不是 Prompt？”

回答框架：Prompt 是软约束，模型可被注入或忽略；计数在 State、判断在路由函数，才是确定性边界。局部计数还能形成“已改写两次仍无证据”的可解释拒答，全局 `recursion_limit` 做不到。

### 12.2 “并行能加速多少？”

回答框架：把串行总和变成最长分支加合并开销，但仍受调度、连接池、限流影响；必须测 P95，且并行会放大上游压力，需并发上限与降级策略。

### 12.3 “`Command` 会让图变得难懂吗？”

回答框架：用多了会，因为路由藏进节点。原则是能用条件边就用条件边；只有动作与下一跳天然一体时才用 `Command`，并在文档里说明路由意图。

## 13. 本章复盘模板

```text
完成日期：
实际投入小时：
是否用 Command(update=..., goto=...) 实现了动作+路由内聚，且知道与条件边的取舍：
query_rewrite_count 是否有界、额度用尽是否进明确终态：
并行三路是否用 Reducer 承接合并、是否做了来源校验：
分支失败是否可解释、是否有降级策略（有告警无手册不给结论）：
Send 是否有分支数上限与 max_concurrency 上限：
分支顺序变化时最终结果是否稳定（显式 position/id + 排序）：
并发 1/3/5 的 P95 与上游错误率是否记录：
仍不理解的问题：
```

## 14. 官方资料与中文阅读指引

- [LangGraph Graph API](https://docs.langchain.com/oss/python/langgraph/graph-api)：`Command`、`Send`、条件边的官方定义；
- [LangGraph Use the Graph API](https://docs.langchain.com/oss/python/langgraph/use-graph-api)：`max_concurrency`、Super-step 的执行语义；
- [LangGraph Workflows and agents](https://docs.langchain.com/oss/python/langgraph/workflows-agents)：循环与终止条件的官方口径。

重点阅读 `Command`、`Send` 与并行执行的章节；`Command` 的 `update`/`goto` 字段、`Send` 的导入路径以锁定版本官方文档为准。

## 15. 下一章入口

本章让流转有界、路由封闭、并行可降级。下一章把这一切“钉在盘上”：接入 Checkpointer 与稳定 `thread_id`，让图在进程重启后从检查点继续——这是“暂停恢复”和后续 Time Travel 的地基。

**关键闸门**：如果循环还没有显式计数、并行合并还没做来源校验，先回补 §4/§7，否则第 4 章的“重启恢复”会在一个没有终态保证的图上空转。
