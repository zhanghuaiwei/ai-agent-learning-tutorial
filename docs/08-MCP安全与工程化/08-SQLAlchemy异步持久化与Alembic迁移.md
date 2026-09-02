# SQLAlchemy 2 异步持久化与 Alembic 迁移

> 补缺章节｜预计 8 小时｜产出：可迁移、可测试、事务边界清晰的 Agent 数据层。

> **阅读前置**：数据层补缺专题。前置要求：第 2 阶段的 Pydantic 契约（第 2 章 `schemas.py`）、asyncio 基础（第 3 章）与三级错误体系（第 5 章）——本章的表模型与 `RunRegistry` 的持久化需求直接衔接。不依赖本阶段 MCP 章节正文。

## 1. 为什么 Agent 工程师必须补数据库工程

Agent 并没有消除数据库。相反，它比普通聊天接口多出 Thread、Checkpoint、审批、工具执行、Usage、幂等记录和评测版本等状态。如果只会“建表 + CRUD”，很容易出现以下问题：

- 把 Checkpoint 当作业务数据库，恢复运行后却无法证明工单是否真实创建；
- 在一个数据库事务里等待模型几十秒，长期占用连接和锁；
- 多个异步任务共享同一个 `AsyncSession`，产生并发状态错误；
- 修改 Pydantic/ORM 类后直接启动，生产数据库没有迁移记录；
- 仅用 SQLite 测试通过，却忽略 PostgreSQL 的类型、锁和并发差异；
- 只在 Prompt 中约束租户，SQL 查询忘记加入 `tenant_id`。

本章不要求成为 DBA，但要求能独立设计 Agent 服务的数据边界、事务和迁移流程。

## 2. 四类存储不要混用

| 数据 | 推荐所有者 | 典型内容 | 能否作为业务真相 |
| --- | --- | --- | --- |
| 业务数据库 | Java 业务服务；Java 未接入前由 Python Adapter 暂代 | 设备、告警、工单、审批 | 是 |
| Agent 应用数据库 | Python Agent 服务 | Run 索引、Usage、工具执行、幂等记录 | 仅对 Agent 运行事实负责 |
| LangGraph Checkpointer/Store | LangGraph 运行层 | State 快照、Thread、短期/长期记忆 | 否 |
| 向量/全文索引 | RAG 检索层 | Chunk、Embedding、倒排索引 | 否，原文和 ACL 才是依据 |

一条原则：**能恢复运行不等于业务操作已经提交；能检索到 Chunk 也不等于原文仍有效。**

## 3. 最小数据模型

Python Agent 服务至少需要考虑以下记录：

```text
agent_run
  id, tenant_id, user_id, thread_id, status
  graph_version, prompt_version, started_at, finished_at

tool_execution
  id, run_id, tool_name, idempotency_key
  request_digest, status, result_ref, attempt, latency_ms

approval_request
  id, tenant_id, thread_id, action_digest
  status, approver_id, decided_at, expires_at

usage_record
  id, run_id, provider, model
  input_tokens, output_tokens, estimated_cost, latency_ms
```

不要把完整 Prompt、文档全文或密钥无条件存入这些表。需要调试时保存脱敏摘要、哈希、对象引用和版本。

## 4. SQLAlchemy 2.x 异步骨架

下面只展示课程需要的 2.x 写法。SQLite 用于本地学习，部署目标使用 PostgreSQL；数据库 URL 由环境配置注入。

```python
from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import DateTime, String, UniqueConstraint, select
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class ToolExecution(Base):
    __tablename__ = "tool_execution"
    __table_args__ = (
        UniqueConstraint("tenant_id", "idempotency_key"),
    )

    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    tenant_id: Mapped[str] = mapped_column(String(64), index=True)
    run_id: Mapped[UUID] = mapped_column(index=True)
    tool_name: Mapped[str] = mapped_column(String(100))
    idempotency_key: Mapped[str] = mapped_column(String(128))
    request_digest: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(32))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


engine = create_async_engine(settings.database_url, pool_pre_ping=True)
SessionFactory = async_sessionmaker(engine, expire_on_commit=False)


async def find_execution(
    session: AsyncSession,
    *,
    tenant_id: str,
    idempotency_key: str,
) -> ToolExecution | None:
    statement = select(ToolExecution).where(
        ToolExecution.tenant_id == tenant_id,
        ToolExecution.idempotency_key == idempotency_key,
    )
    return await session.scalar(statement)
```

关键点：

1. 使用 `select()`，不要从旧教程复制 `session.query()`。
2. 一个并发 Task 使用一个独立 `AsyncSession`；`AsyncSession` 是有状态事务对象，不能在 `gather()` 的多个任务间共享。
3. 默认避免异步环境中的隐式 Lazy Load；查询时明确加载所需字段或关系。
4. `tenant_id` 同时参与查询条件、唯一约束和授权校验，不能只存在于 DTO。
5. `expire_on_commit=False` 便于异步服务在提交后读取已加载字段，但不代表对象永远最新。

## 5. 事务边界

推荐将事务限制在短小、确定的数据库操作中：

```python
async def reserve_tool_execution(command: ReserveToolExecution) -> UUID:
    async with SessionFactory() as session:
        async with session.begin():
            row = ToolExecution.from_command(command)
            session.add(row)
        return row.id
```

错误做法是打开事务后依次调用 LLM、向量库和 Java API。模型延迟和网络重试会长期占用连接；即使最后回滚，也无法回滚已发送的外部请求。

一次有副作用的 Tool 推荐拆为：

1. 短事务写入 `PENDING` 与幂等键；
2. 事务外调用业务服务；
3. 短事务写回 `SUCCEEDED/FAILED/UNKNOWN`；
4. 若网络超时导致结果未知，按幂等键查询业务服务，不盲目再次创建；
5. 需要跨服务通知时理解 Outbox，而不是让数据库事务覆盖网络。

## 6. Alembic 迁移工作流

ORM Model 是代码期望，Migration 才是数据库变更历史。

```bash
uv add sqlalchemy alembic aiosqlite
uv add --optional postgres asyncpg
uv run alembic init migrations
uv run alembic revision --autogenerate -m "create tool execution"
uv run alembic upgrade head
uv run alembic current
uv run alembic history
uv run alembic check
```

`--autogenerate` 不是自动批准。每个迁移必须人工检查：

- 是否把“改名”错误识别成删除旧列再创建新列；
- 新增非空列对历史数据如何回填；
- 唯一约束创建前是否存在重复数据；
- 大表加索引是否会锁表；
- downgrade 是否可行，还是应采用前向修复；
- 应用新旧版本能否在滚动发布期间同时工作。

建议使用 Expand/Contract：先增加向后兼容字段并双读/双写，完成回填和切流后再删除旧字段。不要把破坏性 Schema 修改和应用切换塞进同一瞬间。

## 7. SQLite 与 PostgreSQL 的双配置

本地不安装 Docker 不影响学习：

- 单元测试和大多数 Repository 测试使用临时 SQLite；
- SQL 生成、唯一约束、租户条件和事务边界在本地测试；
- PostgreSQL 兼容性通过 CI 服务容器或托管测试实例验证；
- `JSON/UUID/TIMESTAMP WITH TIME ZONE`、并发锁、隔离级别和全文/向量索引必须在 PostgreSQL 测试；
- 不要为了让 SQLite 通过而隐藏生产数据库差异。

SQLite 是快速反馈工具，不是 PostgreSQL 的行为模拟器。

## 8. 项目练习与答案

### 练习 1：为什么不能让三个并发 Tool 共用同一个 `AsyncSession`？

**答案：**Session 表示一个有状态事务和 Identity Map。并发 Task 会交叉执行 flush、commit、rollback 和对象状态变更。应为每个并发 Task 创建独立 Session，再在应用层合并结果。

### 练习 2：给 `tool_execution` 增加非空 `action_digest`，直接 autogenerate 后上线可以吗？

**答案：**不可以。历史行没有该值，迁移可能失败。先增加可空列，部署新代码写入，回填并验证，再增加非空约束；每一步均可观测和回滚。

### 练习 3：模型调用成功后数据库提交失败，能否再次完整运行 Agent？

**答案：**不能默认重跑。先区分模型调用是否只是读取、是否产生外部副作用；利用 `run_id/idempotency_key` 查询现有结果，按节点级恢复，避免重复写和重复通知。

## 9. 工程任务

1. 为 `tool_execution/approval_request/usage_record` 建立 SQLAlchemy Model。
2. 建立 Repository 接口，让 Agent/Tool 不直接操作 ORM 对象。
3. 创建第一条 Alembic Migration，并在空库和带历史数据的库各跑一次。
4. 写两个并发请求使用同一幂等键的测试，证明只产生一条业务记录。
5. 写一条遗漏 `tenant_id` 条件时必然失败的安全测试。
6. 记录 SQLite 与 PostgreSQL 的差异和迁移 ADR。

## 10. 验收标准

- 新环境可通过 `alembic upgrade head` 建库，`alembic check` 不报告遗漏变更；
- Repository 集成测试覆盖 commit、rollback、唯一冲突和租户隔离；
- 所有外部模型/HTTP 调用都在数据库事务之外；
- 并发 Task 不共享 `AsyncSession`；
- Migration 可说明上线顺序、历史数据处理和回滚/前向修复方案；
- 能口述业务数据库、Checkpoint、Store 和向量索引的所有权差异。

## 11. 资料来源

- [SQLAlchemy 2.0 Unified Tutorial](https://docs.sqlalchemy.org/en/20/tutorial/index.html)
- [SQLAlchemy asyncio](https://docs.sqlalchemy.org/en/20/orm/extensions/asyncio.html)
- [Alembic 官方文档](https://alembic.sqlalchemy.org/en/latest/)
- [PostgreSQL Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)

