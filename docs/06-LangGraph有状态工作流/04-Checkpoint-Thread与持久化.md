# Checkpoint、Thread 与持久化

> 预计 8 小时｜产出：服务重启后仍可继续的运行状态。

## 1. 概念

Checkpointer 在每个 Super-step 保存 State 快照；同一业务会话用稳定 `thread_id` 关联。`run_id` 是一次调用，不能替代 Thread。Checkpoint 让中断恢复、查看历史和 Time Travel 成为可能。

开发可用内存或 SQLite 方案，部署设计使用官方支持的持久化后端。无论后端如何，都要考虑租户隔离、加密、保留期、删除请求、Schema 迁移和备份。

## 2. Thread 规则

- `thread_id` 由服务端分配并与已鉴权用户绑定。
- 客户端传入的 ID 必须校验所有权，防止会话枚举。
- 并发更新同一 Thread 要有版本/冲突策略。
- 运行完成不等于立即永久保存，按业务保留策略清理。

Checkpoint 保存的是执行状态，不是业务系统的最终事实。工单是否已创建仍以业务数据库为准。

## 3. 最小持久化代码

开发阶段可以用内存 Saver 理解调用契约，但它不能证明重启恢复：

```python
from langgraph.checkpoint.memory import InMemorySaver

checkpointer = InMemorySaver()
graph = builder.compile(checkpointer=checkpointer)

config = {
    "configurable": {
        "thread_id": "server-issued-thread-id",
    }
}

await graph.ainvoke(initial_state, config=config)
snapshot = await graph.aget_state(config)
history = [item async for item in graph.aget_state_history(config)]
```

随后切换到官方支持的 SQLite/PostgreSQL Checkpointer，API 层不改变。生产选型重点不只是“能保存”：还要验证连接池、并发冲突、备份恢复、加密、TTL、删除、Schema 迁移和故障时的写入语义。

Persistence 还会保存同一 Super-step 中已经成功节点的 Pending Writes。某个并行节点失败后恢复时，成功分支通常无需全部重跑；这能减少重复模型调用，但有副作用的节点仍必须幂等。

## 4. 恢复与并发策略

为同一 Thread 明确一种策略：

- 串行：同一时刻只允许一个 Active Run，后续请求排队或返回 409；
- 乐观并发：提交时检查预期 Checkpoint/业务版本，冲突后重新读取；
- 分叉：创建新 Thread/Checkpoint Branch，用于沙箱实验，不修改原业务历史。

不要让两个审批恢复请求同时从同一旧 State 执行写节点。Checkpointer 的存在不自动提供业务幂等和审批唯一性。

## 5. 项目任务

加入持久化：在等待确认处停止进程并重启，再用同一 Thread 恢复。测试错误 Thread、跨用户访问、并发恢复和过期清理。

保存一份 State Schema 迁移样例：将旧字段 `risk` 迁移为 `risk_level`，证明旧 Checkpoint 仍可读取或被明确拒绝并给出迁移命令。

## 6. 练习与答案

### 练习 1：为什么不能把 Checkpoint 当工单数据库？

**答案：**它服务执行恢复，事务、查询、审计和生命周期语义不同；权威业务状态必须由业务服务拥有。

### 练习 2：用户能否自己指定任意 `thread_id`？

**答案：**可作为客户端标识输入，但服务端必须校验所有权或映射为内部 ID，不能直接信任。

### 练习 3：有 Checkpointer 后，并行节点中的写 Tool 可以不做幂等吗？

**答案：**不可以。Checkpoint/Pending Writes 管理 Graph State，不能回滚或自动去重外部业务副作用；网络超时和恢复仍可能让写操作重复。

## 7. 验收与资料

重启可恢复，跨租户访问失败，State 版本可迁移。参考 [Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)、[Durable execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)。
