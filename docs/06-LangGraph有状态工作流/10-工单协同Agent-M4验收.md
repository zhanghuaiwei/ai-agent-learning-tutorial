# 工单协同 Agent M4 验收

> 第 18 周里程碑｜目标：完成可暂停、可恢复、无重复副作用的核心业务闭环。

## 1. 必交能力

- 显式 State、Node、Edge、Reducer 与版本。
- 并行收集上下文，有界查询改写。
- 持久化 Checkpoint、Thread 所有权验证、重启恢复。
- 工单草稿 Human-in-the-loop；审批绑定动作摘要。
- 提交幂等、失败恢复、故障注入与只读 Time Travel。
- 子图拆分有明确理由，不以多 Agent 数量为目标。

## 2. 综合 State 与不变量

最终 State 只保存跨节点需要且可序列化的信息：

```python
from typing import Annotated, Literal
from typing_extensions import TypedDict

from langchain.messages import AnyMessage
from langgraph.graph.message import add_messages


class WorkOrderState(TypedDict, total=False):
    messages: Annotated[list[AnyMessage], add_messages]
    tenant_id: str
    user_id: str
    equipment_id: str
    equipment_version: int
    evidence_ids: list[str]
    diagnosis: str
    risk_level: Literal["low", "medium", "high"]
    draft_id: str
    draft_version: int
    action_digest: str
    approval_id: str
    approval_status: Literal["pending", "approved", "rejected", "expired"]
    work_order_id: str
    query_rewrite_count: int
    error_code: str
```

以下不变量写成测试，而不是只写在 Prompt：

1. 未知 `tenant_id/user_id` 的 State 不能进入任何 Tool Node；
2. `evidence_ids` 必须来自当前租户本次检索；
3. 高风险工单没有有效批准不能进入 `submit_work_order`；
4. 提交前重新读取设备和草稿版本；
5. `action_digest` 与当前动作不一致时批准失效；
6. 同一幂等键最多对应一个 `work_order_id`；
7. 所有循环在最大步骤、Token 或 Deadline 内终止；
8. 任意错误都到达已声明终态，不停留在“处理中”。

## 3. Graph 组装骨架

```python
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, StateGraph


builder = StateGraph(WorkOrderState)
builder.add_node("validate_request", validate_request)
builder.add_node("collect_context", collect_context)
builder.add_node("retrieve_knowledge", retrieve_knowledge)
builder.add_node("diagnose", diagnose)
builder.add_node("request_missing_input", request_missing_input)
builder.add_node("create_draft", create_draft)
builder.add_node("review_draft", review_draft)
builder.add_node("revalidate", revalidate)
builder.add_node("submit_work_order", submit_work_order)
builder.add_node("completed", completed)
builder.add_node("failed", failed)

builder.add_edge(START, "validate_request")
builder.add_edge("validate_request", "collect_context")
builder.add_edge("collect_context", "retrieve_knowledge")
builder.add_edge("retrieve_knowledge", "diagnose")
builder.add_conditional_edges(
    "diagnose",
    route_after_diagnosis,
    {
        "need_input": "request_missing_input",
        "draft": "create_draft",
        "fail": "failed",
    },
)
builder.add_edge("request_missing_input", "diagnose")
builder.add_edge("create_draft", "review_draft")
builder.add_edge("review_draft", "revalidate")
builder.add_conditional_edges(
    "revalidate",
    route_after_revalidation,
    {
        "submit": "submit_work_order",
        "reapprove": "review_draft",
        "fail": "failed",
    },
)
builder.add_edge("submit_work_order", "completed")
builder.add_edge("completed", END)
builder.add_edge("failed", END)

graph = builder.compile(checkpointer=InMemorySaver())
```

此骨架用于学习拓扑；重启验收时替换为持久化 Checkpointer。`review_draft` 内使用 `interrupt()`；`submit_work_order` 调用带幂等键的业务 API。不要在 Node 中创建全局数据库连接或把 Principal 交给模型修改。

## 4. 启动、暂停与恢复

```python
from langgraph.types import Command

config = {
    "configurable": {
        "thread_id": owned_thread_id,
    },
    "recursion_limit": 30,
}

first = await graph.ainvoke(initial_state, config=config, version="v2")
assert first.interrupts  # 等待可信审批

resumed = await graph.ainvoke(
    Command(resume=approval_payload),
    config=config,
    version="v2",
)
```

在 API 层先验证 `owned_thread_id` 属于当前 Principal，并校验审批 Payload。Graph 的 `recursion_limit` 只是最后保护；每个业务循环还应有自己的计数和明确失败终态。

恢复时从头重跑包含 `interrupt` 的 Node，因此所有 Interrupt 前副作用必须幂等。提交成功但响应丢失时，用幂等键查询业务结果，不把整个 Graph 从头再跑。

## 5. 节点测试与 Graph 测试

### 节点单测

- 使用固定 State 和 Fake Dependency；
- 断言返回局部更新，不检查内部实现；
- 验证权限、空证据、Schema 错误和超时；
- 写 Node 的重复调用必须得到同一业务结果。

### 路由测试

把每个条件组合做成表驱动测试：`missing_fields/risk/approval/error/rewrite_count` → 唯一合法下一节点。未知枚举必须走 `failed`，不能由字符串动态执行节点。

### 恢复测试

```text
暂停前崩溃
暂停后进程重启
重复 approve
approve 与 reject 并发
批准后草稿变化
业务提交成功后网络超时
Checkpoint 写失败
旧 State Schema 恢复
```

### 安全测试

跨租户 Thread、Prompt 伪造审批人、篡改 `action_digest`、未授权 Tool、恶意文档诱导提交均必须失败，并产生可关联审计。

## 6. 故障终态表

| 故障 | 用户可见结果 | 系统动作 | 可否自动重试 |
| --- | --- | --- | --- |
| 模型临时超时 | 稍后重试/已有证据摘要 | 记录节点失败 | 只读且有限 |
| 检索无证据 | 结构化拒答 | 不创建草稿 | 否 |
| Checkpoint 写失败 | 未可靠暂停 | 不展示“等待审批”成功 | 修复存储后重试 |
| 批准过期 | 要求重新批准 | 作废旧 Approval | 否 |
| 提交成功后超时 | 状态核对中 | 按幂等键查询 | 不重复 POST |
| 业务 409 | 状态已变化 | 重新读取并重规划 | 不盲目重试 |
| 客户端断线 | 按 Run 状态查询 | 取消或后台继续 | 依 Use Case |

## 7. 定量门槛

100 次 Fake 故障运行均到合法终态；重复审批/恢复不重复建单；跨租户 Thread 访问 0 成功；所有循环在步骤/Token/Deadline 边界内终止；关键节点 P95、错误率和费用可查。

## 8. 练习与答案

### 练习 1：如何用一句话说明项目企业级价值？

**答案：**它不是自动聊天，而是在权限、证据、审批、幂等和可恢复边界内，把设备知识查询推进到可审计的工单协同。

### 练习 2：最值得展示的失败场景是什么？

**答案：**业务提交成功但网络超时，Graph 恢复后利用幂等键取得原工单而不重复创建，能体现分布式可靠性。

### 练习 3：`recursion_limit` 已设置，为什么 Query Rewrite 还要自己的计数？

**答案：**全局限制只能粗暴终止整个 Graph，无法给出具体业务失败原因。局部计数能形成“已改写两次仍无证据”的可解释拒答，全局限制只做最后保险。

### 练习 4：Time Travel 分叉后能否继续使用真实提交 Tool？

**答案：**默认不能。分叉用于调试和实验，应使用只读/Fake Tool；外部业务历史不会随 Checkpoint 回滚，真实 Tool 可能重复副作用。

## 9. 演示顺序

正常诊断 → 暂停审批 → 重启服务 → 恢复提交 → 模拟成功后超时 → 证明无重复 → 展示 Trace/Checkpoint。通过后进入 LangSmith，把“我觉得稳定”变成可测证据。

## 10. 提交清单

- Graph Mermaid 图、State 字段所有权表和版本；
- 节点、路由、Reducer、恢复、安全和故障注入测试；
- 持久化 Checkpointer 配置与 State Migration；
- Approval/action digest/幂等记录；
- 六类故障终态和 Runbook；
- 一份“为何使用单主图 + 有限子图，而非自由多 Agent”的 ADR。

## 11. 对应资料

- [LangGraph Durable execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)
- [LangGraph Interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts)
- [LangGraph Graph API](https://docs.langchain.com/oss/python/langgraph/graph-api)
- [LangGraph Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)
