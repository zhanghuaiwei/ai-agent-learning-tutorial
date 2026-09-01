# Python 后端、算法、SQL 与计算机基础强化

> 目标：达到 AI 应用开发岗的工程基础门槛，而不是竞赛算法水平｜安排：24 周每周 2 小时，前 12 周学习、后 12 周复测与项目追问。

## 1. 为什么 Agent 岗仍会考基础

Agent 系统仍是网络服务：有数据结构、HTTP、数据库、缓存、并发、进程和故障。框架能生成 Graph，不能替你解释：

- 为什么一个 `list` 查找拖慢 Tool Allowlist；
- 为什么异步接口仍然阻塞；
- 为什么重试导致两张工单；
- 为什么联合索引没被使用；
- 为什么 SSE 通过代理后断开；
- 为什么 Queue 消息重复；
- 为什么增加 Worker 后数据库先崩。

面试目标是“能写出、能分析、能联系项目”，不追求背诵定义。

## 2. Python 语言与工程

### 2.1 对象与可变性

必须掌握：引用语义、可变/不可变、浅拷贝/深拷贝、默认可变参数、作用域、闭包和垃圾回收的基本直觉。

```python
def add_tag(tag: str, tags: list[str] = []) -> list[str]:
    tags.append(tag)
    return tags
```

问题：默认列表在函数定义时只创建一次，会跨调用共享。修复：

```python
def add_tag(tag: str, tags: list[str] | None = None) -> list[str]:
    result = [] if tags is None else list(tags)
    result.append(tag)
    return result
```

### 2.2 Iterator、Generator 与 Context Manager

Generator 惰性地产生元素，适合大文档流式处理，但错误可能推迟到迭代时发生。Context Manager 用 `with/async with` 保证连接、文件、锁和 Session 在异常路径释放。

```python
async with httpx.AsyncClient(timeout=10.0) as client:
    response = await client.get(url)
```

生产服务更常在 Lifespan 建长期 Client；示例只说明释放语义。

### 2.3 Decorator 与 Dependency Injection

能解释 Decorator 包装函数、`functools.wraps`、同步/异步装饰器差异。FastAPI `Depends` 负责组合依赖，不是安全授权本身；授权逻辑仍要查 Principal、Scope 和 Resource。

### 2.4 类型与 Pydantic

- 类型标注主要用于静态分析和可读契约；
- Pydantic 在运行时解析/校验外部边界；
- `Protocol` 支持结构化接口，方便 Fake 与 Adapter；
- `Any` 会让类型检查失效，外部 `dict` 应尽快转换为 Schema；
- 不信任模型输出，即便它符合 JSON。

### 2.5 异常

捕获最窄的可处理异常；保留 Cause；将内部异常映射为稳定错误码；`finally` 释放资源；不要 `except Exception: pass`。

## 3. asyncio、线程和进程

### 3.1 选择

| 任务 | 推荐起点 | 原因 |
| --- | --- | --- |
| 多个 HTTP/模型/DB I/O | asyncio | 等待期间可运行其他 Task |
| 同步 SDK 少量调用 | Thread Pool/换异步 SDK | 避免阻塞 Event Loop |
| PDF/OCR/重排 CPU 密集 | Process/独立 Worker | GIL 与资源隔离 |
| 长耗时可靠作业 | Queue + Worker | 跨请求恢复和独立伸缩 |

`async def` 中调用同步阻塞函数仍会阻塞。异步是并发组织方式，不等于并行，也不自动带来超时、限流和幂等。

### 3.2 必答概念

- Event Loop、Coroutine、Task、Future 的关系；
- `gather` 与 `TaskGroup` 的失败语义；
- Cancellation 是协作式，清理后通常要继续传播；
- Semaphore 限并发，不能代替供应商全局 Rate Limit；
- Deadline 是整个调用链剩余时间，单层 Timeout 不能各自取满；
- 不要在并发 Task 间共享 SQLAlchemy `AsyncSession`。

### 3.3 现场题

实现“并发调用三个只读 Tool，总期限 2 秒，最多并发 2，保留每个结果/错误”。评分关注：

- 是否限制并发；
- 是否使用统一 Deadline；
- 取消后是否等待清理；
- 是否保留结构化错误而非全部吞掉；
- 是否禁止并发写副作用。

## 4. 数据结构与复杂度

### 4.1 必修集合

| 结构 | 常见复杂度 | Agent 场景 |
| --- | --- | --- |
| list/动态数组 | 索引 O(1)，中间插入 O(n) | Message 顺序、事件列表 |
| dict/hash map | 平均查找 O(1) | Tool Registry、幂等结果 |
| set | 平均包含 O(1) | Allowlist、重复动作检测 |
| deque | 两端 O(1) | 滑动窗口、BFS、任务缓冲 |
| heap | Push/Pop O(log n) | 定时重试、Top-K、优先队列 |
| stack | Push/Pop O(1) | 解析、调用栈、DFS |
| graph | O(V+E) 遍历 | LangGraph 路径、依赖和环检测 |

复杂度必须包含数据规模和操作模式。把 20 个 Tool 的 `list` 换 `set`没有可见收益，不要为理论复杂度牺牲清晰；但处理百万 Chunk 或长任务队列时必须量化。

### 4.2 需要完成的 12 道题

1. 括号匹配：Stack；
2. LRU Cache：Hash Map + 双向链表概念，代码可用 `OrderedDict`；
3. 合并区间：排序；
4. Top-K 错误码：Heap/Counter；
5. 滑动窗口内重复 Tool Call：Deque + Set/Counter；
6. 二叉树层序：BFS；
7. 图是否有环：DFS Color/Kahn；
8. 最短依赖步数：无权图 BFS；
9. 限制并发任务：Semaphore/Queue；
10. 带 TTL 的幂等缓存：Hash + Expiry Heap，讨论惰性删除；
11. 两个有序检索结果合并：双指针；
12. 流式事件重排：Buffer + Sequence，讨论缺包与超时。

每题要求：先说输入/输出/边界，再写代码，给时间和空间复杂度，至少测空值、一个值、重复值和大输入。

## 5. SQL 与数据库

### 5.1 主项目数据关系

```text
tenants 1—N users
tenants 1—N devices
devices 1—N alarms
devices 1—N work_orders
documents 1—N chunks
agent_runs 1—N tool_calls
agent_runs 1—N approvals
```

必须从零写出：JOIN、GROUP BY/HAVING、子查询/CTE、窗口函数、分页、INSERT/UPDATE 和事务。

### 5.2 SQL 题一：每台设备最新告警

```sql
WITH ranked AS (
  SELECT
    a.*,
    ROW_NUMBER() OVER (
      PARTITION BY a.tenant_id, a.device_id
      ORDER BY a.occurred_at DESC, a.id DESC
    ) AS rn
  FROM alarms AS a
  WHERE a.tenant_id = :tenant_id
)
SELECT *
FROM ranked
WHERE rn = 1;
```

说明：`tenant_id` 必须进入过滤与索引；相同时间用稳定 ID 打破平局；不是先查全表再在 Python 分组。

### 5.3 SQL 题二：失败率最高的 Tool

```sql
SELECT
  tool_name,
  COUNT(*) AS calls,
  SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failures,
  1.0 * SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) / COUNT(*) AS failure_rate
FROM tool_calls
WHERE tenant_id = :tenant_id
  AND started_at >= :from_time
GROUP BY tool_name
HAVING COUNT(*) >= 20
ORDER BY failure_rate DESC, calls DESC
LIMIT 10;
```

### 5.4 索引

查询：

```sql
SELECT id, status, created_at
FROM jobs
WHERE tenant_id = :tenant_id AND status = 'queued'
ORDER BY created_at
LIMIT 100;
```

候选索引 `(tenant_id, status, created_at)`。不能只背最左前缀；使用 `EXPLAIN`/`EXPLAIN ANALYZE` 验证行数估算、扫描方式、排序和实际耗时。索引会增加存储和写放大。

### 5.5 事务、隔离和锁

必须解释：

- ACID 与数据库提交边界；
- 脏读、不可重复读、幻读的直觉；
- 乐观锁版本号与悲观锁；
- 唯一约束是幂等的最后防线之一；
- 网络超时后“结果未知”，不能默认事务未提交；
- 数据库事务不能包住分钟级模型调用；
- Outbox 解决数据库写与消息发布的可靠衔接，但 Consumer 仍需幂等。

### 5.6 N+1

查询 100 个 Run 后逐个查 Tool Calls 会产生 101 次查询。解决方式包括 Join、预加载、批量 `IN` 和专门 Projection；不是所有关联都一次 Join，需看数据量和分页。

## 6. HTTP、网络与流式协议

### 6.1 一次 HTTPS 请求

```text
URL 解析
  → DNS
  → TCP（或新协议对应传输）
  → TLS 验证
  → HTTP 请求/响应
  → 连接复用
```

面试至少能解释：DNS 失败、连接超时、读取超时、TLS 证书错误、服务 429/5xx 分别发生在哪里。

### 6.2 HTTP 语义

- GET 应安全且幂等；PUT 通常幂等；POST 默认不幂等但可加 Idempotency-Key；
- 401 是未认证/凭证无效，403 是身份已知但不允许；
- 409 可表示状态冲突/幂等 Key Payload 冲突；
- 422 表示语义校验失败（结合框架约定）；
- 429 看 `Retry-After`；503 可能是暂不可用；
- 客户端超时不代表服务端没有完成。

### 6.3 SSE 与 WebSocket

SSE 是服务器到客户端的文本事件流，基于 HTTP、重连简单；WebSocket 是全双工。Agent 文本/工具进度通常 SSE 足够；需要高频双向实时控制才考虑 WebSocket。

追问：代理缓冲、Heartbeat、Last-Event-ID、断线取消、重复事件、终态事件和敏感推理不下发。

### 6.4 CORS 不是认证

CORS 是浏览器安全策略，不阻止服务器或脚本直接调用 API。业务服务仍需认证、授权、CSRF/Token 边界和输入验证。

## 7. 操作系统与运行时

- 进程有独立地址空间；线程共享进程内存；协程是用户态调度的并发任务；
- GIL 影响 CPython CPU 密集线程并行，但 I/O 等待可释放/切换；
- 虚拟内存、Page、RSS、Swap、OOM 的基本含义；
- 文件描述符覆盖文件/Socket/Pipe；
- Signal 用于终止、重载等协作；
- 容器共享宿主内核，不是虚拟机；
- CPU/Memory Limit 会影响调度与 OOM；
- 多 Worker 会复制进程内 Cache 和连接池。

## 8. Redis、Queue 和分布式基础

回答路径：

- Cache Aside 的读写与失效；
- TTL、穿透、击穿、雪崩；
- Pub/Sub 与持久 Queue 的区别；
- At-most-once、At-least-once 与业务幂等；
- ACK、Visibility Timeout、Dead Letter；
- 分布式锁只解决部分互斥，不等于事务和幂等；
- CAP 不作为万能口号，先说明具体故障与一致性需求。

对应实作见“Redis、任务队列与 Agent 后台作业可靠性”。

## 9. 12 周滚动训练表

| 周 | 2 小时训练 | 必须产出 |
| ---: | --- | --- |
| 1 | Python 可变性、类型、异常 | 6 个最小测试 |
| 2 | Generator、Context、Decorator | 文件流 + Client 生命周期代码 |
| 3 | asyncio、取消、Deadline | 并发 Tool 现场题 |
| 4 | HTTP、状态码、SSE | 请求链路图和断线测试 |
| 5 | list/dict/set/deque | 3 道题 + 复杂度 |
| 6 | heap/stack/interval | 3 道题 + 测试 |
| 7 | tree/graph/BFS/DFS | 3 道题 + 环检测 |
| 8 | SQL JOIN/聚合/窗口 | 5 条主项目 SQL |
| 9 | 索引/EXPLAIN/N+1 | 查询计划对比报告 |
| 10 | 事务/幂等/Outbox | 失败时间线图 |
| 11 | Redis/Queue | 重复投递测试 |
| 12 | Linux/进程/资源 | 一次故障诊断记录 |

第 13～24 周重复同样主题，但题目必须来自主项目和目标 JD；首次错误的题在 48 小时、7 天和 30 天复测。

## 10. 现场编码答题框架

1. 复述需求，确认输入、输出、规模和错误；
2. 给一个直接方案和复杂度；
3. 写最小正确代码，命名清楚；
4. 边写边说不变量，不沉默十分钟；
5. 手工跑正常、空、边界、重复和异常；
6. 再讨论优化、并发和生产化；
7. 不会时缩小问题并明确假设。

## 11. 高频追问题

### 11.1 `asyncio.gather` 中一个任务失败会怎样？

**答案要点：**说明使用的 Python 版本和参数；默认会向等待者传播首个异常，但其他 Task 的生命周期需显式管理，不能假定全部自动安全停止。结构化并发优先评估 `TaskGroup`，并处理取消与清理。

### 11.2 连接池耗尽为什么不只增加池大小？

**答案要点：**可能是 Session/Client 泄漏、慢查询、事务过长、Worker 总数乘池大小超过数据库上限或突发并发无背压。先观察等待、占用时间与泄漏，再按容量调整。

### 11.3 Offset 和 Keyset 分页如何选？

**答案要点：**Offset 简单但深页扫描和并发插入会导致性能/漂移；Keyset 用稳定排序键继续，适合大数据连续翻页。主项目可用 `(created_at,id)` 并始终带租户过滤。

### 11.4 为什么模型调用不能放数据库事务里？

**答案要点：**模型延迟长且不稳定，会长期持锁/占连接，放大死锁和吞吐问题。先读必要数据并结束事务，调用模型，再开启短事务重校验版本与写入。

## 12. 练习与答案

### 练习 1：Tool Registry 用 `list` 还是 `dict`？

**答案：**按名称频繁查找用 `dict[str, Tool]` 更直接，平均 O(1)；若只需保序遍历且数量极小，list 也可。安全 Allowlist 可用 set，但最终权限仍按 Principal/Resource 检查。

### 练习 2：接口超时后客户端重发 POST，如何防重复？

**答案：**稳定 Idempotency-Key、Payload Hash、数据库唯一约束、保存原结果；同 Key 不同 Payload 返回冲突。远端超时未知结果时先按 Key 查询，不盲目重做。

### 练习 3：SQL `WHERE tenant_id=? AND status=? ORDER BY created_at DESC` 如何考虑索引？

**答案：**候选联合索引 `(tenant_id,status,created_at DESC)`，再用真实数据和 EXPLAIN 验证。还要考虑选择性、写放大、返回列、分页和数据库具体实现。

### 练习 4：`async def` 中直接调用同步 PDF 解析有什么问题？

**答案：**会阻塞 Event Loop，拖慢同进程其他请求。小任务可放受限 Thread，CPU/内存重任务放进程或独立 Queue Worker，并设置大小、时间和并发边界。

### 练习 5：为什么 401/403 不能统一返回 200 + 错误文本？

**答案：**破坏 HTTP/网关/客户端语义，监控也无法正确统计。使用标准状态码和稳定错误 Body；同时避免通过差异错误泄露资源是否存在。

## 13. 验收标准

- [ ] 12 道数据结构题全部在 30 分钟内独立完成并写测试；
- [ ] 能为主项目写 10 条 SQL，包含 Join、聚合、窗口与分页；
- [ ] 至少两次用 EXPLAIN 证明索引调整，而非口头猜测；
- [ ] 能手写并发 Tool 调用，包含 Deadline、限流、取消与错误结果；
- [ ] 能画 HTTPS、SSE、Queue 和数据库事务的失败时间线；
- [ ] 模拟面试中 Python/SQL/网络连续两轮不出现 P0 错误；
- [ ] 所有答案能联系智维 Agent 的真实代码或故障记录。

## 14. 资料来源

- [Python Data Structures](https://docs.python.org/3/tutorial/datastructures.html)
- [Python asyncio](https://docs.python.org/3/library/asyncio.html)
- [Python typing](https://docs.python.org/3/library/typing.html)
- [FastAPI](https://fastapi.tiangolo.com/)
- [PostgreSQL Using EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html)
- [PostgreSQL Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)
- [MySQL 8.4 Reference](https://dev.mysql.com/doc/refman/8.4/en/)
- [MDN HTTP Overview](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Overview)
- [Redis Data Types](https://redis.io/docs/latest/develop/data-types/)

