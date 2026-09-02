# Text2SQL 数据 Agent 与数据库安全

> 目标：让 Agent 安全回答结构化数据问题；重点不是生成一条漂亮 SQL，而是 Schema 检索、权限、验证、执行、评测和审计的完整闭环。

> **阅读前置**：G9 结构化数据专题。前置要求：M0 底座、第 3 阶段 Structured Output 的 Schema 校验概念（当前为大纲态）；SQL 基础可与第 11 阶段基础训练并行补齐。不依赖本阶段 RAG 主线章节正文。

## 1. Text2SQL 为什么值得单独学习

企业知识并不全在 PDF。设备状态、告警、工单、库存和维修记录通常位于关系数据库。业务用户会问：

- “过去 30 天 A 型设备故障率最高的部件是什么？”
- “西安工厂仍未关闭的高等级告警有多少？”
- “同一设备七天内重复报修的工单有哪些？”

把整库 DDL 塞给模型并执行其输出，是高风险 Demo。生产系统至少包含：

```text
用户问题
  → 身份与租户范围
  → 数据域/Schema 检索
  → 查询计划
  → SQL 生成
  → AST 与策略校验
  → 只读执行 + 超时/行数限制
  → 结果检查
  → 自然语言总结与来源
  → 审计与评测
```

## 2. 先决定是否真的需要模型生成 SQL

优先级从低风险到高灵活性：

1. 固定报表 API：参数明确、SQL 预写，适合高频核心指标；
2. 语义层/指标 API：模型选择指标、维度和过滤，不直接写 SQL；
3. SQL 模板：模型填受控枚举和参数；
4. Text2SQL：只用于长尾分析，经过严格验证和只读执行；
5. 人工审核 SQL：复杂或高敏场景。

能用普通 API 或模板解决时，不因“Agent”而升级为自由 SQL。

## 3. 项目数据域

为“智维 Agent”准备只读分析副本或本地 SQLite 样例：

```sql
CREATE TABLE devices (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    model TEXT NOT NULL,
    site TEXT NOT NULL,
    status TEXT NOT NULL
);

CREATE TABLE alarms (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    severity TEXT NOT NULL,
    code TEXT NOT NULL,
    opened_at TIMESTAMP NOT NULL,
    closed_at TIMESTAMP NULL
);

CREATE TABLE work_orders (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL,
    closed_at TIMESTAMP NULL
);
```

数据库只是练习数据，不连接真实生产库。正式架构使用只读副本、视图或受控查询服务。

## 4. Schema 不是一次性大 Prompt

大库应先选择数据域，再装配相关 Schema：

```text
问题分类
  → 设备/告警/工单/库存数据域
  → 检索表说明、字段含义、关系和指标定义
  → 只加入相关表及少量示例
```

Schema Catalog 至少记录：

| 字段 | 作用 |
| --- | --- |
| table/column | 精确数据库对象 |
| business_description | 中文业务含义 |
| data_type | 类型与可比较方式 |
| sensitivity | public/internal/sensitive |
| allowed_roles | 可查询角色 |
| tenant_column | 租户过滤字段 |
| relations | 允许 Join 的键 |
| freshness | 数据更新时间 |
| examples | 脱敏值，不放真实敏感数据 |

表名相似不等于语义相同。“设备数”可能指注册、在线或投入生产设备，必须由语义定义消除歧义。

## 5. 两阶段输出：先计划，再 SQL

```python
from pydantic import BaseModel


class QueryPlan(BaseModel):
    intent: str
    metrics: list[str]
    dimensions: list[str]
    filters: list[str]
    time_range: str | None
    tables: list[str]
    ambiguity: str | None


class SqlCandidate(BaseModel):
    sql: str
    parameters: dict[str, str | int | float]
    assumptions: list[str]
```

计划阶段发现“最近”没有时间范围、“故障率”分母未知或用户无权访问某数据域时，先澄清或拒绝，不生成 SQL。

## 6. SQL 验证不能只用正则

正则可以做早期拦截，但不能可靠理解 CTE、子查询、注释和多语句。使用 SQL Parser/AST 完成：

- 只允许单条 `SELECT`；
- 禁止 INSERT/UPDATE/DELETE/MERGE/DDL/COPY/CALL；
- 表和列必须在白名单；
- 强制 tenant 条件，且不能被 `OR` 绕过；
- 禁止系统目录、文件函数和危险扩展；
- 限制 Join 数、子查询深度和复杂度；
- 自动加入或收紧 `LIMIT`；
- 参数必须绑定，不能字符串拼接；
- 记录规范化 SQL 指纹。

伪代码：

```python
def validate_query(sql: str, policy: QueryPolicy) -> ValidatedQuery:
    tree = parse_one_statement(sql, dialect=policy.dialect)
    assert_select_only(tree)
    assert_allowed_relations(tree, policy.allowed_tables, policy.allowed_columns)
    assert_tenant_isolation(tree, tenant_id=policy.tenant_id)
    assert_complexity(tree, max_joins=4, max_depth=3)
    rewritten = enforce_limit(tree, max_rows=200)
    return ValidatedQuery(sql=rewritten.sql(), fingerprint=rewritten.fingerprint())
```

不要把模型生成的 `tenant_id` 当可信值。租户条件来自认证上下文，并由代码注入或查询服务强制执行。

## 7. 数据库侧仍要纵深防御

即使 AST 验证完善，也要使用：

- 专用只读数据库账号；
- 只授权分析视图，不授权业务基表；
- Row-Level Security 或服务端租户过滤；
- `statement_timeout`；
- 连接池和并发上限；
- 只读事务；
- 最大结果行、最大响应字节；
- 查询审计和慢查询日志；
- 与在线交易库隔离的只读副本。

应用层错误不应让数据库账号获得写权限。安全不是单点 Guardrail。

## 8. 查询成本与性能

执行前可使用 `EXPLAIN` 或数据库成本估计，拒绝明显全表扫描/笛卡尔积的查询。注意 `EXPLAIN ANALYZE` 会真实执行查询，不能在未知 SQL 上默认使用。

策略示例：

| 风险 | 控制 |
| --- | --- |
| 无时间范围的大表查询 | 要求澄清或默认受控窗口 |
| 高基数明细 | 聚合优先，限制返回行 |
| 多表 Join | 白名单关系和最大 Join 数 |
| 重复问题 | 规范化指纹 + 权限感知缓存 |
| 并发分析 | 独立队列和租户配额 |
| 超时未知 | 取消 DB 查询并记录终态 |

缓存键必须包含 tenant、role、Schema 版本、SQL 指纹和参数，防止跨权限复用。

## 9. 结果不是事实的最后一步

模型总结查询结果时仍可能：

- 把数量说成比例；
- 忽略空值与时间范围；
- 为没有统计显著性的差异下结论；
- 引入结果中不存在的原因；
- 隐藏查询假设。

返回结构应包含：

```json
{
  "answer": "过去30天……",
  "columns": ["model", "alarm_count"],
  "rows": [],
  "sql_id": "qry_...",
  "time_range": "...",
  "assumptions": [],
  "data_freshness": "...",
  "truncated": false
}
```

UI 可默认折叠 SQL，但应允许授权用户查看规范化查询、参数和数据更新时间。

## 10. 错误分类

| 类别 | 示例 | 系统动作 |
| --- | --- | --- |
| ambiguous_question | “最近故障多吗” | 请求补充时间/指标 |
| schema_miss | 字段不存在 | 回到 Schema 检索，最多一次 |
| policy_denied | 未授权表/列 | 拒绝，不让模型改写绕过 |
| syntax_error | SQL 方言错误 | 允许受限修复一次 |
| expensive_query | 超过复杂度/成本 | 缩小范围或转人工 |
| execution_timeout | 查询超时 | 取消并记录，不无限重试 |
| empty_result | 合法但无数据 | 明确无结果，不生成原因 |
| result_too_large | 超出行数/字节 | 聚合或分页 |

权限拒绝不是“生成失败”，不能通过换 Prompt 重试。

## 11. Text2SQL 评测集

至少 60 条，分为：

- 20 条单表过滤/聚合；
- 15 条 Join 和时间范围；
- 10 条业务歧义；
- 5 条无答案/Schema 不支持；
- 5 条权限攻击；
- 5 条高成本/危险 SQL 诱导。

指标：

| 指标 | 说明 |
| --- | --- |
| plan_accuracy | 指标、维度、过滤是否正确 |
| schema_selection_recall | 需要的表/列是否被选中 |
| execution_accuracy | 与参考 SQL 返回集合是否一致 |
| policy_violation_count | 必须为 0 |
| clarification_accuracy | 歧义问题是否正确追问 |
| answer_groundedness | 总结是否只来自结果 |
| P95 latency | 端到端与 DB 执行分别记录 |
| rows_scanned/cost | 查询代价，视数据库能力 |

Exact String Match 不是核心指标：两条写法不同的 SQL 可能返回同一正确结果；但执行一致也不自动证明安全，需要单独策略门禁。

## 12. 与 RAG/Agent 的组合

数据 Agent 可以作为 LangGraph 中的只读子图：

```text
意图路由
  ├─ 文档知识 → RAG 子图
  ├─ 结构化统计 → Text2SQL 子图
  └─ 业务动作 → 受控 Tool + 人工审批
```

跨源回答先产生两个带来源的结构化结果，再由聚合节点合并。不要让一个模型同时自由检索文档、写 SQL 和执行工单，权限和错误归因会失控。

## 13. 项目练习

实现 `POST /v1/data-questions`：

1. 从认证上下文获得 tenant/user/roles；
2. 生成 QueryPlan；
3. 检索 Schema Catalog；
4. 生成参数化 SQL；
5. AST 策略验证并强制限制；
6. 只读执行；
7. 生成引用 SQL ID 的总结；
8. 保存 Trace、策略决定和评测字段。

本机使用 SQLite/Fake Executor 即可；PostgreSQL 策略、RLS 和 `statement_timeout` 通过 CI 或设计实验验证，不要求本地 Docker。

## 14. 练习与答案

### 练习 1：数据库用户是只读账号，是否可以跳过 SQL 校验？

**答案：**不能。只读查询仍可能读取敏感表、跨租户泄漏、执行资源耗尽或调用危险只读函数。数据库权限是最后一道防线，不替代应用策略。

### 练习 2：模型生成 `WHERE tenant_id = 't1'`，为什么还不安全？

**答案：**租户值来自模型而非认证上下文，且可能被 `OR`、子查询或 Join 绕过。应由策略层使用可信 Principal 注入，并在数据库视图/RLS 再次强制。

### 练习 3：执行结果与参考 SQL 相同，是否说明生成 SQL 正确？

**答案：**只说明当前数据上的结果一致。查询可能在边界数据上错误，或访问了不应访问的表。还要检查计划、Schema、策略、变形数据和权限测试。

### 练习 4：用户要求导出全部维修记录怎么办？

**答案：**Text2SQL 在线回答不承担大批量导出。检查权限后创建受控异步导出 Job，限制字段和范围，文件短期存储并审计下载；必要时人工审批。

## 15. 面试追问

1. Text2SQL、语义层和固定 API 如何选？
2. 如何防止跨租户查询？
3. 为什么正则不能验证 SQL？
4. 如何评测两个语义相同但写法不同的 SQL？
5. Schema 变化后如何避免旧 Prompt 生成错误字段？
6. 如何处理高成本查询和超时取消？
7. 能否允许写 SQL？若业务必须写入，你会如何拆分审批和事务？

## 16. 验收标准

- [ ] Schema Catalog 包含业务含义、权限、关系和版本；
- [ ] 问题先生成可审查 QueryPlan；
- [ ] 使用 AST 而非仅正则完成策略验证；
- [ ] 租户范围来自可信身份上下文；
- [ ] 只读账号、视图/RLS、超时和行数限制形成纵深防御；
- [ ] 60 条以上评测覆盖正确性、歧义、安全和成本；
- [ ] policy violation 为 0；
- [ ] 输出包含假设、时间范围、数据新鲜度和查询审计 ID。

## 17. 资料来源

- [LlamaIndex Text-to-SQL](https://developers.llamaindex.ai/python/examples/index_structs/struct_indices/sqlindexdemo/)
- [PostgreSQL Privileges](https://www.postgresql.org/docs/current/ddl-priv.html)
- [PostgreSQL Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- [PostgreSQL Client Connection Defaults：statement_timeout](https://www.postgresql.org/docs/current/runtime-config-client.html)
- [PostgreSQL EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html)
- [SQLAlchemy asyncio](https://docs.sqlalchemy.org/en/20/orm/extensions/asyncio.html)
- [SQLGlot](https://github.com/tobymao/sqlglot)
- [Ragas Metrics](https://docs.ragas.io/en/stable/concepts/metrics/available_metrics/)
- [OWASP SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
