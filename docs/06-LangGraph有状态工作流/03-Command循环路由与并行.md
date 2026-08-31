# Command、循环、路由与并行

> 预计 7 小时｜产出：有界路由与并行上下文收集。

## 1. Command

`Command` 可在同一节点中返回 State 更新并指定下一目标，适合动作与路由紧密相关的场景。普通条件边更易可视化；不要为追求 API 技巧把所有边藏入 Node。

循环必须有最大步骤、Token、Deadline 或收敛判断。例如最多两次查询改写，第二次仍无证据就拒答。路由值定义 Literal/Enum，并为未知值设安全终态。

## 2. 并行

告警查询、设备基本信息和手册检索互不依赖时可并行。合并前分别记录错误；不是所有分支失败都要整次失败，例如手册服务降级时仍可返回实时告警但不得给维修结论。

并行放大上游压力，需要并发上限、每分支超时和总时限。Reducer 必须处理多分支更新。

LangGraph 按 Super-step 执行：同一步中的多个活跃节点可并行运行，下一步通常在它们完成后继续。并行分支的完成顺序不可作为业务排序依据；需要稳定顺序时返回显式 `position/id`，聚合后排序。

## 3. Command 与 Send 的边界

- `Command(update=..., goto=...)`：节点既更新 State 又决定下一跳，适合路由与结果紧密相关的单次跳转。
- Conditional Edge：路由与节点计算分离，图更容易可视化和单测。
- `Send(node, state)`：运行时才知道分支数量，并且每个分支需要不同输入，适合 Map-Reduce。

例如对检索到的多个手册章节并行做安全摘要：

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

分支数必须限制，不能让模型生成 10,000 个主题后直接创建 10,000 个 `Send`。调用 Graph 时还要配置 `max_concurrency`，并为每个外部依赖设置容量边界。

## 4. 项目任务

并行执行告警、资产、知识检索；实现“证据不足 → 改写一次 → 拒答”的有界循环。注入一个分支超时，验证降级路径。

再实现一个最多 5 个 Chunk 的 `Send` Map-Reduce，对比分支顺序变化时最终结果是否稳定；记录并发 1、3、5 的 P95 和上游错误率。

## 5. 练习与答案

### 练习 1：三个节点并行后延迟一定变成最大单节点延迟吗？

**答案：**理想情况下接近最大值，但还受调度、连接池、限流、合并和重试影响，必须测 P95。

### 练习 2：模型能否直接返回节点函数名？

**答案：**不应。先将模型结构化结果映射到允许的业务枚举，再由代码选择节点。

### 练习 3：何时使用 `Send` 而不是预先画五条并行 Edge？

**答案：**分支数量或每个分支输入在运行时才确定时使用 `Send`。若拓扑固定，普通 Edge 更直观、更容易审计。

## 6. 验收与资料

循环有界、路由封闭、分支失败可解释；动态 Fan-out 有数量与并发上限。参考 [Graph API](https://docs.langchain.com/oss/python/langgraph/graph-api)、[Use the Graph API](https://docs.langchain.com/oss/python/langgraph/use-graph-api)、[Workflows](https://docs.langchain.com/oss/python/langgraph/workflows-agents)。
