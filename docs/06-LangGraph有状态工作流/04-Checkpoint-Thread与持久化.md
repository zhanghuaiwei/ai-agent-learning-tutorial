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

## 3. 项目任务

加入持久化：在等待确认处停止进程并重启，再用同一 Thread 恢复。测试错误 Thread、跨用户访问、并发恢复和过期清理。

## 4. 练习与答案

### 练习 1：为什么不能把 Checkpoint 当工单数据库？

**答案：**它服务执行恢复，事务、查询、审计和生命周期语义不同；权威业务状态必须由业务服务拥有。

### 练习 2：用户能否自己指定任意 `thread_id`？

**答案：**可作为客户端标识输入，但服务端必须校验所有权或映射为内部 ID，不能直接信任。

## 5. 验收与资料

重启可恢复，跨租户访问失败，State 版本可迁移。参考 [Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)、[Durable execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)。

