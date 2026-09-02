# Redis、任务队列与 Agent 后台作业可靠性

> 建议投入：5 小时，分布在第 4、11、20 周｜目标：把长耗时 Agent 工作从 HTTP 请求中拆出，并在重复投递、Worker 崩溃和积压时保持正确。

> **本章从哪里开始**：第 4 章的 `RunRegistry` 是进程内存版——重启即失忆、多副本不共享，当时明确承诺"生产答案是 Redis + 任务队列，正是本阶段第 7 章的主题，届时该类被替换而端点协议不变"。M0 验收（第 6 章）通过后，本章偿还这笔债。阅读前置：第 2 阶段全部底座——幂等键（第 2 章 `CreateWorkOrderDraftInput`）、重试与错误分级（第 3 章 `ReliableInvoker`/`GatewayError`）、SSE 与运行登记（第 4 章）、结构化日志（第 5 章）。

## 1. 为什么 Agent 应用需要后台任务

以下工作不适合长期占用一次 HTTP 请求：

- PDF 解析、OCR、切分、Embedding 和批量入库；
- 需要数十秒或数分钟的研究型 Agent；
- 大规模离线评测和报表生成；
- 工单同步、通知、索引重建和数据清理；
- 供应商限流后需要延迟重试的操作。

FastAPI `BackgroundTasks` 会在响应返回后、同一应用进程内执行小任务。它适合“即使进程重启丢失也可接受”的轻量工作，不是持久任务队列。需要跨进程、跨机器、重投和独立伸缩时，应使用 Redis/RabbitMQ 等 Broker 与 Worker。

```text
POST /ingestions
  → 验证身份、文件元数据与幂等键
  → 数据库提交 Job=queued
  → 可靠发布任务
  → 202 Accepted + job_id

Worker
  → 领取任务
  → 标记 running/heartbeat
  → 分阶段处理并保存进度
  → success / retry_wait / dead_letter / canceled
```

关键认知：**HTTP 202 只表示已接受，不表示任务完成；消息被消费也不表示业务事务成功。**

## 2. Redis 在 Agent 系统中的不同角色

| 角色 | 示例 | 丢失后果 | 设计重点 |
| --- | --- | --- | --- |
| Cache | 模型路由、检索结果、短 TTL 配置 | 性能下降，可从源重建 | TTL、穿透、击穿、Key 版本 |
| Rate Limit | 用户/租户 Token Bucket | 可能短暂放宽或误限 | 原子操作、时钟、租户维度 |
| Idempotency | `tenant + operation + key` | 可能重复副作用 | 原子占位、Payload Hash、结果保留 |
| Session/临时状态 | SSE 游标、短期连接信息 | 会话恢复受影响 | 过期、租户隔离、权威源边界 |
| Job Queue/Stream | 文档摄取、评测任务 | 任务丢失或重复执行 | ACK、可见性超时、重投、DLQ |
| Pub/Sub | UI 进度通知 | 离线订阅者收不到 | 只做提示，不做权威任务记录 |

Redis Pub/Sub 通常是 at-most-once：订阅者断线期间的消息不会补发。需要恢复的任务不能只依赖 Pub/Sub；可使用带 Pending Entries/Consumer Group 的 Redis Streams、专用任务框架，或企业既有 MQ。

## 3. 最小 Job 契约

先定义与具体队列产品无关的业务契约：

```python
from datetime import datetime
from enum import StrEnum
from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field


class JobStatus(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    RETRY_WAIT = "retry_wait"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    DEAD_LETTER = "dead_letter"
    CANCELED = "canceled"


class JobMessage(BaseModel):
    schema_version: int = 1
    job_id: UUID
    tenant_id: UUID
    job_type: str
    payload: dict[str, Any]
    payload_hash: str
    attempt: int = Field(ge=0)
    traceparent: str | None = None
    created_at: datetime


class JobView(BaseModel):
    job_id: UUID
    status: JobStatus
    progress: int = Field(ge=0, le=100)
    attempt: int
    error_code: str | None = None
    next_retry_at: datetime | None = None
```

消息中只放稳定 ID 和必要参数，不放 API Key、完整文档、数据库连接或不可序列化对象。Worker 通过 `tenant_id + resource_id` 重新读取有权限的数据。

## 4. 至少一次投递与幂等

多数实用队列更接近 at-least-once：Worker 完成业务写入后、ACK 前崩溃，消息会再次投递。追求“消息绝不重复”通常不现实；正确目标是“重复执行不产生重复业务结果”。

### 4.1 幂等表

```text
job_effects
  tenant_id
  operation
  idempotency_key
  payload_hash
  status
  result_json
  created_at
  updated_at

UNIQUE (tenant_id, operation, idempotency_key)
```

执行过程：

1. 尝试插入 `(tenant, operation, key, hash, processing)`；
2. 唯一冲突且 Hash 不同：拒绝，说明 Key 被错误复用；
3. 唯一冲突且已成功：返回原结果；
4. 唯一冲突且处理中：返回当前状态，不能并行重复写；
5. 业务写和幂等结果尽可能处于同一数据库事务；
6. 事务提交后再 ACK。

Redis `SET key value NX EX ttl` 可用于短期抢占或抑制并发，但不能单独替代业务数据库的最终唯一约束。锁过期、网络分区或进程暂停都可能让两个执行者同时进入。

## 5. 发布任务也可能失败：Transactional Outbox

错误写法：先提交数据库 Job，再直接发消息；若进程在二者之间崩溃，Job 永远不会被消费。反过来先发消息也会让 Worker 读不到尚未提交的数据。

Outbox 将“创建 Job”和“记录待发布事件”放在一个数据库事务：

```text
transaction:
  INSERT jobs (..., status='queued')
  INSERT outbox_events (event_id, aggregate_id, payload, published_at=NULL)
commit

publisher:
  SELECT 未发布事件（可加 skip locked）
  → 发布到 Broker
  → 标记 published_at
```

Publisher 自身也可能在发布后、标记前崩溃，所以消息仍可能重复；Consumer 幂等仍然必需。Outbox 解决原子可达性，不提供神奇的 exactly-once。

## 6. 重试、退避和 Dead Letter

### 6.1 错误分类

| 错误 | 是否重试 | 例子 |
| --- | --- | --- |
| 瞬时依赖故障 | 是，指数退避 + 抖动 | 429、部分 5xx、短暂网络错误 |
| 输入/Schema 错误 | 否 | 不支持文件、字段缺失、损坏文档 |
| 权限错误 | 默认否 | 401、403、租户资源不匹配 |
| 资源边界 | 条件重试或降级 | 文件过大、Token 上限、OOM |
| 未知内部错误 | 有限次数 | 程序 Bug，不允许无限热循环 |

重试时间可写成：

```text
delay = min(base × 2^attempt, max_delay) + random_jitter
```

达到最大次数后进入 Dead Letter，并保存 `job_id/error_code/attempt/last_error_class/trace_id`。不要把原始文档、Prompt 或 Secret 全量放入 DLQ。

### 6.2 为什么每个 I/O 仍需超时

Worker 的全局 Time Limit 只能作为最后防线。模型、HTTP、数据库、Redis 每个依赖都应有连接和读取超时，否则一个挂起任务可能长期占用 Worker，并造成队列积压。

## 7. 取消、心跳与可见性超时

用户取消不等于强制杀进程：

1. API 把 Job 标为 `cancel_requested`；
2. Worker 在安全检查点读取取消标记；
3. 停止新步骤，释放临时资源；
4. 已提交的外部副作用不能假装回滚，必要时进入补偿；
5. 保存 `canceled` 终态。

长任务定期更新 `heartbeat_at` 和阶段进度。监控发现 `running` 且心跳过期时，先判断原 Worker 是否确实失联，再重投；新的 Worker 仍依赖幂等保护。

## 8. redis-py 异步生命周期

`redis.asyncio` 适合 FastAPI 的异步调用。生产中在应用生命周期内共享一个带连接池的 Client，在关闭时 `aclose()`；不要每个请求新建连接池。

```python
from contextlib import asynccontextmanager

import redis.asyncio as redis
from fastapi import FastAPI


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = redis.Redis.from_url(
        "redis://redis.internal:6379/0",
        decode_responses=True,
        max_connections=20,
        socket_connect_timeout=1.0,
        socket_timeout=1.0,
    )
    await client.ping()
    app.state.redis = client
    try:
        yield
    finally:
        await client.aclose()


app = FastAPI(lifespan=lifespan)
```

连接数必须由“Web Worker 数 × 每进程池上限 + 后台 Worker”一起计算，不能只看单进程配置。Redis 故障时，Cache 可降级；权限、幂等和队列权威状态不能默认放行。

## 9. 不装本地 Redis 如何学习

当前设备约束不要求本地 Docker。采用三层验证：

1. **纯单元测试**：为 `JobQueue` 定义 Protocol，用 `InMemoryQueue` 模拟重复投递、超时和乱序；
2. **状态机测试**：用 SQLite/PostgreSQL 测 Job 状态和唯一约束，不依赖 Redis；
3. **集成验证**：在 GitHub Actions Service Container、临时云 Redis 或公司环境运行少量契约测试。

```python
from typing import Protocol


class JobQueue(Protocol):
    async def publish(self, message: JobMessage) -> str: ...
    async def ack(self, delivery_id: str) -> None: ...
    async def retry(self, delivery_id: str, delay_seconds: float) -> None: ...
```

业务 Service 依赖 `JobQueue`，而不是在路由里直接调用 Redis 命令。这样本地限制不会降低架构和测试标准。

## 10. 智维 Agent 实验

实现异步文档摄取：

```text
POST /v1/knowledge/documents
GET  /v1/jobs/{job_id}
POST /v1/jobs/{job_id}/cancel

阶段：validate → parse → clean → chunk → embed → index → verify
```

要求：

- 上传接口返回 202 和 `job_id`；
- 同租户、同文件版本、同幂等键不会创建两份索引；
- 每阶段可重入，Chunk ID 稳定；
- Embedding 429 后延迟重试，不占用 HTTP 请求；
- Worker 在 `index` 完成后、ACK 前崩溃，再次执行不会重复 Chunk；
- 失败可定位到阶段与错误码；
- UI 进度来自 Job 权威状态，Pub/Sub 只用于刷新提示。

## 11. 观测与告警

至少记录：

- `jobs_enqueued_total{job_type}`；
- `jobs_completed_total{job_type,status}`；
- `job_duration_seconds{job_type}`；
- `queue_lag_seconds{job_type}`；
- `job_retries_total{job_type,error_code}`；
- `dead_letter_total{job_type}`；
- 活跃 Worker、心跳过期数和 Redis 连接池等待；
- Trace 中的 `job_id/tenant_hash/attempt`，不记录原文和 Secret。

队列长度不是唯一告警：流量自然增加会让长度上升，更关键的是最老任务等待时间、完成速率、失败率和 Worker 饱和度。

## 12. 面试追问

### 12.1 FastAPI BackgroundTasks 和 Celery 如何选？

小、短、同进程且允许进程重启后丢失的任务可用 `BackgroundTasks`。需要持久化、跨进程伸缩、重投、路由、调度或可观测 Worker 时使用 Celery/其他任务系统。不能因为“异步函数”就认为任务已可靠持久化。

### 12.2 Redis Pub/Sub 能做任务队列吗？

不能直接承担需要补发的权威任务。Pub/Sub 对离线订阅者不保留消息，更适合实时通知。需要确认、Pending、重领和恢复时使用 Streams/任务框架/MQ。

### 12.3 为什么 ACK 放最后仍不能 exactly-once？

业务提交与 Broker ACK 通常跨两个系统，提交后 ACK 前可能崩溃。重投不可避免，因此通过业务幂等把“至少一次执行”收敛为“一次业务效果”。

## 13. 练习与答案

### 练习 1：Worker 创建工单成功，但 ACK 前宕机，如何处理？

**答案：**消息会重投。用稳定幂等键与业务库唯一约束查询原结果，第二次执行返回已有工单并 ACK。不能依赖“Worker 应该不会在这个时刻崩溃”。

### 练习 2：把用户权限结果缓存 30 分钟，管理员撤权后怎么办？

**答案：**高风险写操作必须在执行时向权威授权源重新校验，不能只信长 TTL Cache。权限 Cache 需要短 TTL、版本/撤销机制和失败关闭策略。

### 练习 3：队列长度持续 1000 是否一定故障？

**答案：**不一定。还要看进入速率、完成速率、最老任务等待、任务类型、Worker 数和 SLO。如果每秒进入/完成都为 100 且等待稳定，可能只是正常在途；若最老等待持续增长则是积压。

### 练习 4：设计三个必须通过的自动测试。

**答案：**至少包含：同一消息重复投递只产生一次业务结果；Worker 在阶段中失败后从合法检查点恢复；不可重试错误直接失败且不进入热重试。再补充取消、DLQ、不同租户同 Key 不冲突等用例。

## 14. 验收标准

- [ ] 能解释 Cache、Pub/Sub、Stream/Queue 和数据库权威状态的区别；
- [ ] 文档摄取 API 使用 202 + Job 查询，而不是保持分钟级 HTTP 请求；
- [ ] 重复消息、Worker 崩溃和 ACK 丢失测试通过；
- [ ] Job、Outbox 和业务副作用的事务边界有 ADR；
- [ ] 重试按错误分类，有最大次数、抖动和 DLQ；
- [ ] 本地 Fake 与真实 Broker 使用相同契约；
- [ ] Trace 和指标能定位任务类型、阶段、尝试次数与积压。

## 15. 资料来源

- [FastAPI Background Tasks](https://fastapi.tiangolo.com/tutorial/background-tasks/)
- [Redis redis-py Async](https://redis.io/docs/latest/develop/clients/redis-py/async/)
- [Redis Job Queue with redis-py](https://redis.io/docs/latest/develop/use-cases/job-queue/redis-py/)
- [Redis Streams with redis-py](https://redis.io/docs/latest/develop/use-cases/streaming/redis-py/)
- [Redis Pub/Sub with redis-py](https://redis.io/docs/latest/develop/use-cases/pub-sub/redis-py/)
- [Celery Tasks](https://docs.celeryq.dev/en/stable/userguide/tasks.html)
