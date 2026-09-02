# Query 处理、过滤与基础检索

> 预计 6 小时｜产出：带租户、设备和时间过滤的检索服务。

> **阅读前置**：承接第 4 章的向量索引，本章进入在线查询端的第一层——把用户问题变成可执行的检索查询。前置要求：第 4 章的向量检索（`tenant_id + allowed_doc_ids` 过滤与防御性断言）；第 1 章的 `RetrievalQuery` 契约；M2 的 `AgentContext`（身份来自服务端）。不需要重排与混合检索，本章先把单路向量 Top-k 管线做对。

## 1. 本章从哪里开始

第 4 章结束时，我们有一个可版本化、租户隔离的向量索引。但用户问题不是直接可查询的向量：它可能含指代（“这台泵”）、省略（“温度高了”没说是哪个设备）、多目标（“型号和故障码一起查”）。如果直接把原始问题向量化丢给索引，召回质量会很差。

本章要解决的债是：**在检索前把问题规范化、并建立“硬过滤在前、语义排序在后”的查询管线**。这是 RAG 里最容易“看起来做了、实则绕过权限”的一层——过滤必须由确定性代码完成，不能让 LLM 生成任意数据库过滤表达式。

## 2. 本章完成标准（通过门槛）

必须同时满足：

- 实现 `RetrievalQuery` 与白名单过滤器：`tenant_id`、ACL、有效版本、设备类型、时间范围都是结构化字段，不让 LLM 生成任意过滤表达式；
- 查询规范化：型号/故障码归一、基于可信会话状态补全指代、拆分多问题、生成少量同义查询，并**保留原问题、记录版本与结果**；
- 先执行硬过滤再做语义排序，Top-k 基线（召回 20 → 过滤去重 → 取 5）可配置；
- 对无相关结果返回“证据不足”，不强行选最相近片段；
- 查询日志只存脱敏文本或 Hash、过滤条件、候选 ID、分数、耗时；
- 设计同义词、错别字、跨型号、无答案、越权五类测试并通过。

## 3. 查询理解：先规范化，再改写

用户问题与手册语言之间隔着一层“口语化”。规范化与改写都要**保留原问题**，方便定位“改写是否引入退化”。

```python
class QueryPlan(BaseModel):
    original: str
    normalized: str
    equipment_ids: list[str] = Field(default_factory=list)
    fault_codes: list[str] = Field(default_factory=list)
    time_range: str | None = None
    sub_questions: list[str] = Field(default_factory=list)
    synonyms: list[str] = Field(default_factory=list)
    plan_version: str
```

四类处理的取舍：

| 处理 | 作用 | 风险 |
| --- | --- | --- |
| 型号/故障码归一 | “泵 01” → `eq-pump-01`，故障码大写化 | 归一规则要覆盖别名表 |
| 指代补全 | “这台” → 会话状态里的设备 | 会话状态必须可信，不能来自 Prompt |
| 多问题拆分 | “型号是什么 + 怎么修”拆两条 | 拆分错误会丢主目标 |
| 同义查询 | “振动” → “抖动/共振” 少量变体 | 变体过多稀释主查询 |

改写必须可关闭回退：改写后召回变差时，回退到原问题检索，并记录“改写是否生效”用于第 8 章评测。

## 4. 硬过滤：字段白名单，不是 LLM 拼表达式

用户可能说“帮我查 tenant_id 是 B 的所有告警”。如果让 LLM 生成过滤表达式，就是给注入开绿灯。正确做法是**白名单过滤器**：允许的字段和操作符结构化，值来自可信来源。

```python
class RetrievalFilter(BaseModel):
    tenant_id: str
    allowed_doc_ids: frozenset[str]
    active_version: str | None = None
    equipment_type: str | None = None
    time_range: tuple[str, str] | None = None


def build_filter(query: RetrievalQuery, principal: Principal) -> RetrievalFilter:
    # tenant_id / allowed_doc_ids 来自 Principal + ACL，绝不由用户/模型填写
    return RetrievalFilter(
        tenant_id=principal.tenant_id,
        allowed_doc_ids=principal.allowed_doc_ids(),
        equipment_type=parse_equipment_type(query.text),  # 从规范化结果提取，仍受白名单约束
    )
```

`equipment_type` / `time_range` 这类“内容过滤”可以从规范化结果提取，但取值必须落在白名单内；`tenant_id / allowed_doc_ids` 只来自可信 Principal 与 ACL 服务。过滤顺序铁律：**先硬过滤，再做语义排序**——语义排序不能放大已被过滤掉的候选。

## 5. 基础 Top-k 检索

先建立单路向量 Top-k 基线，别急着上混合检索：

```python
async def retrieve(query: RetrievalQuery, principal: Principal) -> RetrievalResult:
    plan = plan_query(query.text)
    filt = build_filter(query, principal)
    candidates = await vector_store.query(
        vector=embed(plan.normalized),
        top_k=query.top_k,          # 召回 20
        filter=filt,
    )
    # 去重（按 chunk_id）后取 top_k 条
    deduped = dedupe_by_chunk_id(candidates)[: query.top_k]
    if not deduped:
        return RetrievalResult(evidences=[], index_version=..., query_version=...)
    return RetrievalResult(
        evidences=[to_evidence(c) for c in deduped],
        index_version=index.current_version,
        query_version=plan.plan_version,
    )
```

三个要点：

1. `k` 过小漏召回、过大增加下游成本——基线“召回 20、过滤去重后取 5”，第 6 章会在此基础上融合与重排；
2. **无结果返回“证据不足”**，不强行选最相近片段，否则“无答案”问题会被硬凑成“答案”；
3. `index_version` 与 `query_version` 随每次结果记录，为第 8 章评测复现服务。

## 6. 查询日志：能诊断，但不泄露

查询日志要能定位问题，但不能把敏感问题原文外泄：

| 字段 | 处理 |
| --- | --- |
| 问题原文 | 默认只存 Hash 或脱敏文本 |
| 过滤条件 | 存结构（不含敏感值） |
| 候选 chunk_id / 分数 | 存 |
| 耗时 / index_version | 存 |
| 完整原文 | 仅必要时隔离保存 + 访问控制 |

日志键含租户与 ACL 版本，防止跨权限复用。这一步是第 7 章引用校验、第 8 章评测的数据基础。

## 7. 项目任务

1. 实现 `RetrievalQuery` 与白名单过滤器 `build_filter`，断言 `tenant_id/allowed_doc_ids` 不来自 Prompt；
2. 实现查询规范化（归一、指代补全、多问题拆分、同义查询），保留原问题并记录 `plan_version`；
3. 实现基础 Top-k 管线：召回 20 → 硬过滤 → 去重 → 取 5，无结果返回证据不足；
4. 实现查询日志（脱敏 + 结构字段 + 访问控制）；
5. 设计并跑通同义词、错别字、跨型号、无答案、越权五类测试；
6. 验证“改写可关闭回退”，记录改写前后召回对比。

## 8. 常见错误与诊断顺序

### 8.1 权限过滤晚于模型生成

现象：敏感片段已进 Context，最后才“拒答”。先查过滤是否在向量查询时就注入 `tenant_id + allowed_doc_ids`，而不是生成后再删。**不要**依赖“模型没看到”的侥幸。

### 8.2 LLM 生成过滤表达式

现象：用户说“查 B 租户”，模型生成了 `tenant_id='B'`。这是注入点。先查过滤字段是否走白名单、值是否来自 Principal。**不要**信任模型填写的任何权限字段。

### 8.3 查询改写后效果变差却找不到原因

现象：加了同义查询后 Recall 反而下降。先确认是否同时记录了原查询和改写查询、各自跑召回并比较证据命中。**不要**只观察最终答案——那会掩盖改写层的退化。

### 8.4 无答案问题被硬答

现象：检索无结果却返回了最相近片段，导致“无答案”变“错误答案”。先查是否对空结果做了拒答分支，是否设了证据门槛。

## 9. 练习题与答案

### 练习 1：为什么权限过滤必须早于模型生成？

**答案：**敏感片段一旦进入上下文就已发生数据暴露，最终答案拒绝不能撤销。过滤必须在检索查询阶段就由代码注入可信身份与 ACL。

### 练习 2：查询改写后效果变差如何定位？

**答案：**同时记录原查询和改写查询，各自跑召回并比较证据命中；不要只观察最终答案。改写必须可关闭回退。

### 练习 3：为什么不让 LLM 生成过滤表达式？

**答案：**LLM 输出的过滤条件不可信，可能被注入诱导（如“tenant_id 改成 B”）。过滤字段和操作符必须白名单化，值来自可信 Principal 与 ACL 服务。

### 练习 4：Top-k 取多少合适？

**答案：**没有固定值。召回层 k 可稍大（如 20）保证不漏，经硬过滤、去重、融合、重排后只送少量高质量 Chunk 进 Context（如 5）。k 过小漏召回，过大增加下游成本与噪声。

## 10. 工程挑战

不联网的前提下完成：

1. 写一个过滤器契约测试：构造一个“用户要求查 B 租户”的输入，断言 `build_filter` 返回的 `tenant_id` 仍是 Principal 的租户，而非 Prompt 里的值；
2. 写一个无答案测试：检索空结果返回 `RetrievalResult(evidences=[])` 而非最近邻硬凑；
3. 写一个查询改写回退测试：改写召回为空时，回退原查询并记录 `used_fallback=True`。

参考方向：Principal 用 `dataclass(frozen=True)` 构造；空结果断言 `evidences` 为空列表；回退用 `plan_version` 与一个 `used_fallback` 标志记录。

## 11. 面试追问

1. 用户问题进索引前要做哪些处理？为什么保留原问题？
2. 硬过滤和语义排序为什么必须这个顺序？
3. 为什么不能信任 LLM 生成的过滤表达式？
4. 无答案问题如何处理，为什么不能硬选最近邻？
5. 查询日志如何做到能诊断又不泄露敏感问题？

## 12. 本章复盘模板

```text
完成日期：
实际投入小时：
RetrievalQuery 与白名单过滤器是否实现且不信任 Prompt 身份：
查询规范化是否保留原问题并记录 plan_version：
硬过滤是否先于语义排序：
无答案是否返回证据不足而非硬凑最近邻：
查询日志是否脱敏并记录候选 ID/分数/耗时/版本：
同义词/错别字/跨型号/无答案/越权五类测试是否通过：
改写是否可关闭回退：
仍不理解的问题：
```

## 13. 官方资料与中文阅读指引

- [LangChain Retrieval](https://docs.langchain.com/oss/python/langchain/retrieval)：检索管线的概念总览，用于 §5 基础检索；
- [LangChain Retrievers](https://docs.langchain.com/oss/python/integrations/retrievers/index)：Retriever 集成，用于 §5 的检索抽象；
- [LangChain Vector stores](https://docs.langchain.com/oss/python/integrations/vectorstores/)：向量库元数据过滤，用于 §4 硬过滤落地。

重点阅读：Retrieval 的查询/检索/过滤顺序，Vector stores 的 filter 能力边界；API 细节以锁定版本官方文档为准。

## 14. 下一章入口

本章建立了“硬过滤在前、语义排序在后”的单路向量检索管线。下一章进入混合检索：引入 BM25 关键词检索与 RRF 融合，解决“纯向量对精确型号/故障码/零件号召回不足”的问题。本章的 `RetrievalResult` 会作为融合的输入复用。

**关键闸门**：如果查询过滤还做不到“权限不来自 Prompt、硬过滤先于语义排序”，先回补，不要进入混合检索——混合检索只放大候选集，不修正权限漏洞，甚至会把更多候选带入重排，扩大泄漏面。
