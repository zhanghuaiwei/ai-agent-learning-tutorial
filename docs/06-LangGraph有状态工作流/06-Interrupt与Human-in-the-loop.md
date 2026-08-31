# Interrupt 与 Human-in-the-loop

> 预计 8 小时｜产出：可信确认后才提交工单的审批流程。

## 1. Interrupt 机制

节点调用 `interrupt(payload)` 暂停，Checkpointer 保存状态；外部系统展示审批信息，之后用同一 `thread_id` 和 `Command(resume=...)` 恢复。没有 Checkpointer 和稳定 Thread 就无法可靠恢复。

Payload 只含审批所需安全摘要：动作、目标设备、草稿、风险、预计影响，不包含内部 Prompt 或密钥。恢复值必须用 Pydantic 校验，并与已登录审批人、角色和待审批动作绑定。

## 2. 关键陷阱

恢复时节点会从开头重新执行，因此 `interrupt` 前的副作用必须幂等，或把副作用移到确认后的独立节点。不要在 `try/except` 中错误吞掉 Interrupt。审批内容若在等待期间过期，要重新读取设备状态并要求再次确认。

确认不是一个布尔值：至少记录 `approval_id/approver/action_digest/decision/timestamp/reason`，防止批准 A 后执行已变化的 B。

## 3. 最小暂停与恢复代码

```python
from typing import Literal

from langgraph.types import Command, interrupt
from pydantic import BaseModel


class ApprovalDecision(BaseModel):
    approval_id: str
    decision: Literal["approve", "reject", "edit"]
    action_digest: str
    reason: str | None = None


def review_draft(state: WorkOrderState) -> Command:
    raw_decision = interrupt({
        "approval_id": state["approval_id"],
        "action_digest": state["action_digest"],
        "summary": state["safe_draft_summary"],
        "expires_at": state["approval_expires_at"],
    })
    decision = ApprovalDecision.model_validate(raw_decision)
    verify_authenticated_approver(decision, state)

    if decision.decision == "approve":
        return Command(update={"approval": "approved"}, goto="revalidate")
    if decision.decision == "edit":
        return Command(update={"approval": "edit"}, goto="edit_draft")
    return Command(update={"approval": "rejected"}, goto="cancelled")


await graph.ainvoke(
    Command(resume=trusted_resume_payload),
    config={"configurable": {"thread_id": owned_thread_id}},
)
```

`trusted_resume_payload` 来自已鉴权审批 API，不来自聊天消息。恢复前重新读取草稿/设备版本并比较 `action_digest`；过期或内容变化时作废原批准。

同一节点中多个 `interrupt()` 的顺序不要随版本或条件任意变化。恢复依赖调用顺序匹配；复杂审批拆成清晰节点通常更可靠。

## 4. 项目任务

实现工单草稿审批：暂停、前端确认/拒绝、恢复、重新校验、提交。测试重启、重复确认、过期草稿、无权审批和篡改 Payload。

## 5. 练习与答案

### 练习 1：模型在消息中回答“确认”可以恢复吗？

**答案：**不能直接作为可信确认。恢复事件必须来自已鉴权的审批 API/UI，并绑定动作摘要。

### 练习 2：为什么 Interrupt 前写数据库危险？

**答案：**恢复可能重跑节点，导致重复写。写操作应幂等或放到恢复后的独立节点。

### 练习 3：审批 UI 把原草稿展示给用户，恢复时能直接执行原批准吗？

**答案：**不能默认。等待期间设备和草稿可能变化；恢复时重新读取并比较版本和 `action_digest`，不一致则要求重新批准。

## 6. 验收与资料

无审批绝不提交；重复恢复不重复建单；审批对象变化会失效。参考 [Interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts)、[Human-in-the-loop](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)。
