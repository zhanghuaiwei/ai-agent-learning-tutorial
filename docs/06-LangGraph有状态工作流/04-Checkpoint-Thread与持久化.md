# Checkpoint、Thread 与持久化

> 预计 8 小时｜产出：服务重启后仍可继续的运行状态。

> **阅读前置**：本章是第 6 阶段（LangGraph 有状态工作流）第 4 章，承接第 2 章的 `WorkOrderState`（Checkpoint 序列化的正是它）与第 3 章的有界循环，落地持久化与恢复。前置要求：第 2 章 State 的可序列化约束、第 3 章 `thread_id` 在 `configurable` 里的用法。本章是第 6 章 Interrupt“暂停恢复”与第 9 章 Time Travel 的地基。

## 1. 本章从哪里开始

第 3 章的图能跑，但每次 `ainvoke` 都是从 `START` 开始、进程内存里过一遍。一旦服务重启，或流程在“等待审批”处停了几小时，执行状态就丢了。本章要解决的问题只有一个：**让执行状态在进程之外存活，并能按“会话”找回、从检查点继续**。

支撑它的三件东西：

1. **Checkpointer**：每个 Super-step 保存 State 快照；
2. **`thread_id`**：把同一次业务会话的多次调用关联到一起；
3. **恢复/并发策略**：同一 Thread 谁来继续、冲突怎么办。

三者缺一不可：没有 Checkpointer 就没有快照；没有稳定 `thread_id` 就找不到该恢复哪次会话；没有并发策略，两个审批请求会同时从同一旧状态往下跑。

## 2. 本章完成标准（通过门槛）

- 用 `InMemorySaver` 跑通“暂停 → 重启 → 同一 `thread_id` 恢复”的理解性调用契约；
- 能说明 `InMemorySaver` 只用于学习/测试，生产必须换官方支持的持久化后端，且 API 层不因后端切换而变；
- `thread_id` 由服务端分配并与已鉴权用户绑定，客户端传入的 ID 必须校验所有权；
- 理解 Checkpoint 存的是**执行状态**而非业务事实，工单是否已建仍以业务库为准；
- 为同一 Thread 明确一种并发策略（串行/乐观并发/分叉），并写 State Schema 迁移样例。

## 3. Checkpointer 与 Thread 的概念边界

| 概念 | 含义 | 关键点 |
| --- | --- | --- |
| Checkpoint | 某 Super-step 结束后的 State 快照 | 存执行状态，不是业务事实 |
| `thread_id` | 一次业务会话的稳定标识 | 服务端分配 + 绑定用户 + 校验所有权 |
| `run_id` | 一次 `ainvoke` 调用的标识 | 一次调用，不能替代 Thread |
| Pending Writes | 同一 Super-step 已成功节点的待落盘更新 | 恢复时成功分支不必全重跑 |

`run_id` 是一次调用，`thread_id` 是一次会话。一次会话可能对应多次调用（首次执行 + 审批恢复 + 重试），用 `thread_id` 把它们串起来；`run_id` 只标识某一次调用，不能拿来恢复历史会话。

## 4. 最小持久化代码

开发阶段先用内存 Saver 理解调用契约，但它**不能证明重启恢复**——进程一死，内存快照就没了：

```python
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, StateGraph

builder = StateGraph(WorkOrderState)
# ... add_node / add_edge / add_conditional_edges（第 2 章 §8）

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

`aget_state` 拿当前快照，`aget_state_history` 拿历史快照（第 9 章 Time Travel 就基于它）。随后把 `checkpointer` 换成官方支持的 SQLite/PostgreSQL Checkpointer，**API 层不改变**——这就是为什么第 2 章坚持 State 可序列化。

生产选型重点不只是“能保存”，还要验证：

- 连接池与并发冲突；
- 备份恢复、静态加密；
- TTL / 保留期与删除请求；
- State Schema 迁移；
- 故障时的写入语义（写失败时不能宣称“已可靠暂停”）。

## 5. Pending Writes 与部分重放

Checkpointer 不只保存已完成的 Super-step，还保存**同一 Super-step 中已经成功节点的 Pending Writes**。这意味着某个并行节点失败后恢复时，成功分支通常无需全部重跑，能减少重复模型调用。

但这是一把双刃剑：**有副作用的节点仍必须幂等**。Pending Writes 管理的是 Graph State，不会替你回滚或去重外部业务副作用。恢复时若把写节点重放一次，外部可能多写一次——这正是第 7 章要解决的幂等问题，这里只埋下伏笔。

## 6. Thread 规则与所有权

四条硬规则：

1. `thread_id` 由服务端分配并与已鉴权用户绑定；
2. 客户端传入的 ID 必须校验所有权，防止会话枚举（用别人的 `thread_id` 读别人的审批）；
3. 并发更新同一 Thread 要有版本/冲突策略；
4. 运行完成不等于立即永久保存，按业务保留策略清理（TTL、删除请求）。

API 层先验证 `owned_thread_id` 属于当前 Principal，再进入 Graph。这条校验在 Graph 之外、在鉴权层完成——对应 M4 验收“在 API 层先验证 `owned_thread_id`”。

## 7. 恢复与并发策略

为同一 Thread 明确一种策略，别让两个审批恢复请求同时从同一旧 State 执行写节点：

| 策略 | 做法 | 适用 |
| --- | --- | --- |
| 串行 | 同一时刻只允许一个 Active Run，后续排队或返回 409 | 默认首选，语义最简单 |
| 乐观并发 | 提交时检查预期 Checkpoint/业务版本，冲突后重读 | 读多写少、允许重读 |
| 分叉 | 创建新 Thread/Checkpoint Branch，沙箱实验，不改原历史 | 调试、假设验证（第 9 章） |

Checkpointer 的存在**不自动提供**业务幂等和审批唯一性。并发控制是业务侧策略，Checkpointer 只是给了你“能读快照、能对比版本”的能力。

## 8. State Schema 迁移

State 字段会演进（如把 `risk` 改成 `risk_level`）。旧 Checkpoint 用旧字段序列化，新代码读旧快照会错位。迁移样例：

```python
# 旧字段 risk: str  →  新字段 risk_level: Literal["low","medium","high"]
def migrate_risk(state: dict) -> dict:
    if "risk" in state and "risk_level" not in state:
        state["risk_level"] = state["risk"]
        del state["risk"]
    return state
```

要点：

1. 迁移函数要让旧 Checkpoint **可读取**，或**明确拒绝**并给出迁移命令，不能静默错读；
2. 记录 Graph 版本、State Schema 版本，运行中的 Thread 使用创建时版本，不被新部署静默改变；
3. 迁移只改 State 形态，不改业务事实——业务侧数据迁移是另一条独立管线。

## 9. 项目任务

1. 加入持久化：在“等待确认”处停止进程并重启，再用同一 `thread_id` 恢复，断言能继续而不是从头开始；
2. 写测试：错误 Thread、跨用户访问、并发恢复、过期清理；
3. 保存 State Schema 迁移样例：`risk → risk_level`，证明旧 Checkpoint 可读或被明确拒绝并给出迁移命令；
4. 用 `aget_state_history` 打印历史快照序列，确认每个 Super-step 都能被定位（为第 9 章铺路）。

## 10. 常见错误与诊断顺序

### 10.1 用 `InMemorySaver` 宣称“重启可恢复”

根因是混淆了“内存里有”与“持久化”。诊断顺序：先问进程重启后快照还在吗 → 换成 SQLite/PostgreSQL Checkpointer → 写一个真正 kill 进程再起的恢复测试。内存 Saver 只用于理解契约与离线测试。

### 10.2 客户端直接传任意 `thread_id`

根因是把会话标识当普通参数透传。诊断顺序：确认 `thread_id` 是否服务端分配 → 是否与已鉴权用户绑定 → 恢复前是否校验所有权。跨租户 Thread 访问必须 0 成功。

### 10.3 把 Checkpoint 当工单数据库

根因是图省事，把业务状态写进 Checkpoint 后当权威查询。诊断顺序：确认权威事实在哪 → Checkpoint 只存引用与执行状态 → 工单是否已建以业务库为准。Checkpoint 的事务/查询/审计/生命周期语义与业务库完全不同。

### 10.4 以为有 Checkpointer 写节点就不必幂等

根因是误以为快照能回滚外部副作用。诊断顺序：确认写节点有没有幂等键 → 模拟“提交成功后网络超时” → 恢复后是否重复 POST。Checkpoint/Pending Writes 只管理 Graph State，不回滚外部业务（第 7 章）。

## 11. 练习题与答案

### 练习 1：为什么不能把 Checkpoint 当工单数据库？

**答案：**它服务执行恢复，事务、查询、审计和生命周期语义不同；权威业务状态必须由业务服务拥有。Checkpoint 存“执行到哪了”，业务库存“工单真的建了没”。

### 练习 2：用户能否自己指定任意 `thread_id`？

**答案：**可作为客户端标识输入，但服务端必须校验所有权或映射为内部 ID，不能直接信任。否则会话枚举与跨租户读取就成立了。

### 练习 3：有 Checkpointer 后，并行节点中的写 Tool 可以不做幂等吗？

**答案：**不可以。Checkpoint/Pending Writes 管理 Graph State，不能回滚或自动去重外部业务副作用；网络超时和恢复仍可能让写操作重复。

### 练习 4：`run_id` 能替代 `thread_id` 做恢复吗？

**答案：**不能。`run_id` 只标识一次调用，一次会话可能多次调用（首次 + 审批恢复 + 重试）；恢复历史会话必须靠稳定的 `thread_id`。

## 12. 工程挑战

1. 写一个“真重启”测试：`graph` 用 SQLite Checkpointer，第一次 `ainvoke` 停在等待审批，然后**新进程/新对象**用同一 `thread_id` 恢复，断言 State 与历史快照一致；
2. 构造跨租户访问用例：用户 A 用用户 B 的 `thread_id` 调 `aget_state`，断言被拒绝且无数据返回；
3. 写 `risk → risk_level` 迁移测试：旧快照迁移后可读，字段语义一致，未知旧值被明确拒绝而非静默映射。

参考方向：第 1 题对照 M4“重启恢复”；第 2 题对照 M4“跨租户 Thread 访问 0 成功”。

## 13. 面试追问

### 13.1 “Checkpoint 和业务数据库是什么关系？”

回答框架：Checkpoint 是执行状态快照，服务恢复与 Time Travel；业务库是权威事实。两者通过引用 ID（`draft_id`/`work_order_id`）关联，Checkpoint 不取代业务库，也不该被当成业务查询入口。

### 13.2 “并发两个审批恢复怎么处理？”

回答框架：先定并发策略——首选串行（同一 Thread 只允许一个 Active Run，其余排队/409）；或用乐观并发对比版本冲突后重读；调试场景用分叉。Checkpointer 不自动提供并发安全，策略是业务侧定的。

### 13.3 “State Schema 变了，旧 Checkpoint 怎么办？”

回答框架：写迁移函数让旧快照可读或明确拒绝，记录 Graph/State 版本，运行中的 Thread 用创建时版本。迁移只改 State 形态，不改业务事实。

## 14. 本章复盘模板

```text
完成日期：
实际投入小时：
是否用 InMemorySaver 跑通暂停→重启→同一 thread_id 恢复：
是否理解 InMemorySaver 不能证明重启恢复、生产需换持久化后端：
thread_id 是否服务端分配、绑定用户、校验所有权：
是否理解 Checkpoint 存执行状态而非业务事实：
Pending Writes 的收益与副作用节点必须幂等的关系是否清楚：
是否明确了串行/乐观并发/分叉之一的并发策略：
State Schema 迁移（risk→risk_level）是否可读或明确拒绝：
仍不理解的问题：
```

## 15. 官方资料与中文阅读指引

- [LangGraph Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)：Checkpointer、Thread、快照与历史；
- [LangGraph Durable execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)：重启恢复与 Pending Writes 的官方说明；
- [LangGraph Use Time Travel](https://docs.langchain.com/oss/python/langgraph/use-time-travel)：`aget_state_history` 与分叉，为第 9 章铺路。

重点阅读 Persistence 的 Checkpointer 接口与 Thread 语义；SQLite/PostgreSQL 后端的构造参数、`aget_state`/`aget_state_history` 签名以锁定版本官方文档为准。

## 16. 下一章入口

本章让执行状态离开进程、可找回、可从检查点继续。下一章换一个视角看这些“保存下来的状态”：哪些算短期记忆、哪些能沉淀为长期记忆、哪些根本不该存——在隐私与删除的边界里设计记忆。

**关键闸门**：如果“重启恢复”还只是用 `InMemorySaver` 演示，先换持久化后端跑一次真重启测试，否则第 6 章的“审批暂停后重启恢复”会在生产里翻车。
