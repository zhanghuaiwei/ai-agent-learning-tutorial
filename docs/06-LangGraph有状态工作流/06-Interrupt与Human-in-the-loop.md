# Interrupt 与 Human-in-the-loop

> 预计 8 小时｜产出：可信确认后才提交工单的审批流程。

## 1. Interrupt 机制

节点调用 `interrupt(payload)` 暂停，Checkpointer 保存状态；外部系统展示审批信息，之后用同一 `thread_id` 和 `Command(resume=...)` 恢复。没有 Checkpointer 和稳定 Thread 就无法可靠恢复。

Payload 只含审批所需安全摘要：动作、目标设备、草稿、风险、预计影响，不包含内部 Prompt 或密钥。恢复值必须用 Pydantic 校验，并与已登录审批人、角色和待审批动作绑定。

## 2. 关键陷阱

恢复时节点会从开头重新执行，因此 `interrupt` 前的副作用必须幂等，或把副作用移到确认后的独立节点。不要在 `try/except` 中错误吞掉 Interrupt。审批内容若在等待期间过期，要重新读取设备状态并要求再次确认。

确认不是一个布尔值：至少记录 `approval_id/approver/action_digest/decision/timestamp/reason`，防止批准 A 后执行已变化的 B。

## 3. 项目任务

实现工单草稿审批：暂停、前端确认/拒绝、恢复、重新校验、提交。测试重启、重复确认、过期草稿、无权审批和篡改 Payload。

## 4. 练习与答案

### 练习 1：模型在消息中回答“确认”可以恢复吗？

**答案：**不能直接作为可信确认。恢复事件必须来自已鉴权的审批 API/UI，并绑定动作摘要。

### 练习 2：为什么 Interrupt 前写数据库危险？

**答案：**恢复可能重跑节点，导致重复写。写操作应幂等或放到恢复后的独立节点。

## 5. 验收与资料

无审批绝不提交；重复恢复不重复建单；审批对象变化会失效。参考 [Interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts)、[Human-in-the-loop](https://docs.langchain.com/oss/python/langchain/human-in-the-loop)。

