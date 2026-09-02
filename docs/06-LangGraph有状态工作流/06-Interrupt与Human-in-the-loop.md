# Interrupt 与 Human-in-the-loop

> 预计 8 小时｜产出：可信确认后才提交工单的审批流程。

> **阅读前置**：本章是第 6 阶段（LangGraph 有状态工作流）第 6 章，承接第 3 章的 `Command` 路由与第 4 章的 Checkpoint/Thread，落地工单草稿审批。前置要求：第 3 章 `Command(update=..., goto=...)`、第 4 章 `thread_id` 所有权校验。本章是第 10 章 M4 验收“工单草稿 Human-in-the-loop”的核心实现。

## 1. 本章从哪里开始

第 4 章让状态能跨重启存活，第 3 章让节点能用 `Command` 决定下一跳。现在把两者串起来解决 M4 的核心需求：**建工单草稿前需人工审批**——这是第 4 阶段单 Agent 做不到的（一轮对话里没有“暂停数小时等人点确认”的机制）。

Human-in-the-loop 的关键不是“让模型问一句‘你确定吗’”，而是：**在可信的人点确认之前，Graph 停在检查点；人点确认后，Graph 从检查点恢复继续**。三件套缺一不可：

1. `interrupt(payload)`：节点内暂停，把审批信息暴露给外部；
2. Checkpointer + 稳定 `thread_id`：暂停后状态能存、能找回（第 4 章）；
3. `Command(resume=...)`：用可信的审批决策恢复（第 3 章）。

## 2. 本章完成标准（通过门槛）

- `review_draft` 内调用 `interrupt(payload)` 暂停，外部用同一 `thread_id` + `Command(resume=...)` 恢复；
- Payload 只含审批所需安全摘要，不含内部 Prompt 或密钥；恢复值经 Pydantic 校验；
- 审批决策至少记录 `approval_id/approver/action_digest/decision/timestamp/reason`，防止“批准 A 后执行 B”；
- 无审批绝不提交，重复恢复不重复建单，审批对象变化（草稿/设备过期）会使原批准失效；
- 恢复值来自已鉴权审批 API，不来自聊天消息。

## 3. Interrupt 机制

`interrupt(payload)` 让节点暂停，Checkpointer 保存状态，`graph.ainvoke` 返回一个带 `interrupts` 的结果。外部系统展示审批信息，之后用 `Command(resume=...)` 恢复：

```python
from langgraph.types import Command, interrupt


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
```

首次调用：

```python
first = await graph.ainvoke(initial_state, config=config, version="v2")
assert first.interrupts  # 等待可信审批
```

审批后恢复：

```python
resumed = await graph.ainvoke(
    Command(resume=trusted_resume_payload),
    config={"configurable": {"thread_id": owned_thread_id}},
    version="v2",
)
```

`trusted_resume_payload` 来自已鉴权审批 API，不来自聊天消息。恢复前重新读取草稿/设备版本并比较 `action_digest`；过期或内容变化时作废原批准。

## 4. 审批决策不是布尔值

“确认/拒绝”用一个布尔表达是不够的。批准必须绑定**被批准的那个动作**，防止批准 A 后执行已变化的 B。最小 Schema：

```python
from typing import Literal

from pydantic import BaseModel


class ApprovalDecision(BaseModel):
    approval_id: str
    decision: Literal["approve", "reject", "edit"]
    action_digest: str
    approver_id: str
    timestamp: str
    reason: str | None = None
```

字段职责：

| 字段 | 作用 |
| --- | --- |
| `approval_id` | 审批记录唯一标识，可审计 |
| `decision` | `approve`/`reject`/`edit` 三种终态 |
| `action_digest` | 被批准动作的摘要，与当前草稿比对 |
| `approver_id` | 已鉴权审批人身份 |
| `timestamp` | 审批时间 |
| `reason` | 拒绝/修改原因，可审计 |

M4 不变量“`action_digest` 与当前动作不一致时批准失效”，就是靠 `revalidate` 节点在恢复后重新比对实现的。

## 5. 关键陷阱

### 5.1 恢复时节点从头重跑

恢复时，包含 `interrupt` 的节点会从开头重新执行。因此 `interrupt` 前的副作用必须幂等，或把副作用移到确认后的独立节点（第 7 章）。不要在 `try/except` 中错误吞掉 Interrupt——它会让暂停失效。

### 5.2 审批对象过期

审批 UI 展示的草稿在等待期间可能过期（设备状态变了、草稿被改了）。恢复时不能直接执行原批准，要重新读取设备/草稿版本并比较 `action_digest`，不一致则要求再次确认。

### 5.3 多个 `interrupt` 的顺序

同一节点中多个 `interrupt()` 的顺序不要随版本或条件任意变化，恢复依赖调用顺序匹配。复杂审批拆成清晰节点通常更可靠。

### 5.4 模型说“确认”不是可信确认

模型在消息里回答“确认”不能作为审批依据。恢复事件必须来自已鉴权的审批 API/UI，并绑定动作摘要。这是第 4 阶段“身份来自服务端”在审批上的延续。

## 6. 恢复前必须重校验

`review_draft` 之后接 `revalidate`，恢复后重新读取设备与草稿版本：

```python
async def revalidate(state: WorkOrderState) -> dict:
    current_equipment = await read_equipment(state["equipment_id"])
    if current_equipment.version != state["equipment_version"]:
        return {"error_code": "E_CONFLICT"}   # 设备已变化，批准作废
    current_draft = await read_draft(state["draft_id"])
    if current_draft.action_digest != state["action_digest"]:
        return {"error_code": "E_CONFLICT"}   # 草稿已变化，批准作废
    return {"approval_status": "approved"}
```

不变量：**批准的对象变了，批准就失效**。这是“批准 A 不执行 B”的确定性保证，不是 Prompt 提醒。

## 7. 项目任务

1. 实现工单草稿审批：`review_draft` 暂停 → 前端展示安全摘要 → 审批人 approve/reject/edit → `Command(resume=...)` 恢复 → `revalidate` → 提交；
2. 写测试：重启恢复、重复确认、过期草稿、无权审批、篡改 `action_digest`；
3. 实现 `action_digest` 比对：草稿在等待期间变化后，恢复被 `E_CONFLICT` 拒绝并回到重新审批；
4. 写审计记录：每次审批落 `approval_id/approver_id/action_digest/decision/timestamp/reason`。

## 8. 常见错误与诊断顺序

### 8.1 模型在聊天里说“确认”就提交

根因是把聊天文本当审批凭证。诊断顺序：确认恢复事件是否来自已鉴权审批 API → 是否经 Pydantic 校验 → 是否绑定 `action_digest`。聊天消息永远不是可信确认。

### 8.2 Interrupt 前写数据库

根因是没意识到恢复会重跑节点。诊断顺序：检查 `interrupt` 前的副作用 → 移到确认后的独立节点 → 或做成幂等写。重复恢复不重复建单是硬门槛。

### 8.3 审批展示的内容已过期仍执行

根因是恢复前没有重读版本。诊断顺序：恢复后 `revalidate` 重读设备/草稿版本 → 比对 `action_digest` → 不一致作废原批准并 `E_CONFLICT`。

### 8.4 在 `try/except` 里吞掉 Interrupt

根因是异常处理把暂停信号当普通错误吞了。诊断顺序：确认 `interrupt` 抛出的控制流不被 `except` 捕获吞掉 → 恢复调用顺序与暂停点匹配。

## 9. 练习题与答案

### 练习 1：模型在消息中回答“确认”可以恢复吗？

**答案：**不能直接作为可信确认。恢复事件必须来自已鉴权的审批 API/UI，并绑定动作摘要。模型输出永远被当作不可信数据。

### 练习 2：为什么 Interrupt 前写数据库危险？

**答案：**恢复可能重跑节点，导致重复写。写操作应幂等或放到恢复后的独立节点。

### 练习 3：审批 UI 把原草稿展示给用户，恢复时能直接执行原批准吗？

**答案：**不能默认。等待期间设备和草稿可能变化；恢复时重新读取并比较版本和 `action_digest`，不一致则要求重新批准。

### 练习 4：审批决策为什么不能是一个布尔？

**答案：**布尔丢失了“批准的是哪个动作”。需记录 `approval_id/approver/action_digest/decision/timestamp/reason`，防止批准 A 后执行已变化的 B。

## 10. 工程挑战

1. 写“重复 approve”测试：同一审批恢复两次，断言只建一张工单，第二次恢复命中幂等或被拒绝；
2. 写“批准后草稿变化”测试：恢复前篡改 `action_digest`，断言 `revalidate` 返回 `E_CONFLICT` 且不进入 `submit_work_order`；
3. 写“approve 与 reject 并发”测试：两个恢复请求同时到达，断言只有一个生效、另一个被拒绝，无双重提交。

参考方向：第 1、3 题对照 M4 恢复测试“重复 approve / approve 与 reject 并发”；第 2 题对照 M4 不变量“`action_digest` 与当前动作不一致时批准失效”。

## 11. 面试追问

### 11.1 “Human-in-the-loop 是怎么实现的？”

回答框架：`interrupt(payload)` 暂停 + Checkpointer 存状态 + `Command(resume=...)` 恢复。恢复值来自已鉴权审批 API，经 Pydantic 校验并绑定 `action_digest`；恢复前 `revalidate` 重读版本，对象变了批准失效。

### 11.2 “怎么保证批准 A 不执行 B？”

回答框架：批准绑定 `action_digest`，恢复后重读设备/草稿版本比对，不一致 `E_CONFLICT` 作废。审批不是布尔，是绑定动作摘要的审计记录。

### 11.3 “Interrupt 前有副作用怎么办？”

回答框架：恢复会重跑节点，所以 Interrupt 前副作用必须幂等，或移到确认后的独立节点。这是第 7 章幂等的直接动机。

## 12. 本章复盘模板

```text
完成日期：
实际投入小时：
review_draft 是否用 interrupt(payload) 暂停、外部用 Command(resume=...) 恢复：
恢复值是否来自已鉴权审批 API 并经 Pydantic 校验：
审批是否记录 approval_id/approver/action_digest/decision/timestamp/reason：
无审批是否绝不进入 submit_work_order：
重复恢复是否不重复建单：
草稿/设备过期是否使批准失效（E_CONFLICT）：
Interrupt 前副作用是否幂等或已移到确认后节点：
仍不理解的问题：
```

## 13. 官方资料与中文阅读指引

- [LangGraph Interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts)：`interrupt` 与 `Command(resume=...)` 的官方说明；
- [LangChain Human-in-the-loop](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)：审批与暂停的官方口径；
- [LangGraph Durable execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)：暂停恢复与副作用幂等的关系。

重点阅读 Interrupts 的暂停/恢复语义与“恢复重跑节点”的警告；`interrupt` 返回值、`Command(resume=...)` 的构造以锁定版本官方文档为准。

## 14. 下一章入口

本章让工单在可信审批前停在检查点、审批后安全恢复。但恢复会重跑节点，任何 Interrupt 前的副作用都可能重复。下一章正面解决它：副作用、幂等键与故障恢复，让“重复执行仍只建一张工单”。

**关键闸门**：如果审批还依赖聊天消息里的“确认”，先回补 §3/§8.1，否则 M4 的“无审批绝不提交”不成立。
