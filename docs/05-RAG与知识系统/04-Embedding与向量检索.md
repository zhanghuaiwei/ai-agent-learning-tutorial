# Embedding 与向量检索

> 预计 7 小时｜目标：理解向量相似度、索引版本和低成本本地方案。

> **阅读前置**：承接第 3 章的 Chunk 切分与元数据，本章把 Chunk 向量化并建立可版本化的向量索引。前置要求：第 3 章的 `Chunk`（含 `chunk_id/tenant_id/acl/content_hash`）；第 2 章的“新索引 + 原子切换”机制。不需要数据库，本地 Chroma 或纯内存 + 余弦相似度即可完成本章实验。

## 1. 本章从哪里开始

第 3 章结束时，我们有了语义完整、元数据齐全、ID 稳定的 Chunk。但它们还是字符串，无法做“语义相似”检索——用户问“泵体抖得厉害”，代码无法直接匹配到手册里“振动超限”的段落。本章要解决的是：**把 Chunk 变成向量，并让这个向量索引可版本化、可重建、可隔离租户**。

这里要偿还的债有两笔：一是把“向量相似度”当成可度量、可校准的工程对象，而不是一个魔法分数；二是把向量库的**存储能力**与**权限能力**严格分开——向量库负责召回“向量最近邻”，租户与 ACL 过滤必须由我们自己的代码在查询时强制注入。

## 2. 本章完成标准（通过门槛）

必须同时满足：

- 理解 Embedding 原理，明确余弦相似度、点积、欧氏距离不能跨模型/跨度量直接比较；
- Embedding 模型、维度、归一化、距离度量作为**索引版本**的一部分，换模型必须重嵌全部文档；
- 查询与文档使用兼容的 Embedding 模型，不同模型的向量不混入同一索引；
- 向量库不做权限判断，检索查询必须带服务端生成的 `tenant_id` 与 ACL 过滤，返回后做防御性校验；
- 实现批量嵌入、缓存、失败续跑、索引版本、原子切换；
- 用已知相似/不相似句子做烟雾测试，再在证据集上跑 `Recall@k`。

## 3. Embedding 核心原理

Embedding 把文本映射为高维向量，语义相近的文本通常距离更近。但“更近”依赖三个前提：

1. **同一个模型**：不同模型产出不同向量空间，向量不可跨模型比较；
2. **同一种度量**：余弦相似度、点积、欧氏距离各度量不同性质；
3. **同样的归一化**：点积在有归一化时等价于余弦相似度，无归一化时受模长影响。

距离度量选型速查：

| 度量 | 含义 | 适用 |
| --- | --- | --- |
| 余弦相似度 | 方向相似，忽略模长 | 语义检索最常用 |
| 点积 | 方向 + 模长 | 模型已归一化时等价余弦 |
| 欧氏距离 | 绝对距离 | 需要严格距离量纲时 |

一条铁律：**相似度分数不可跨模型、跨语料、跨度量直接比较**。第 7 章的拒答阈值、第 6 章的 RRF 排名融合，都建立在这条认知上——这也是为什么 M3 的 `Evidence.score` 只在本索引版本内可比较。

## 4. 索引版本：换模型就是数据迁移

Embedding 模型升级（如换更大的模型、改维度）意味着**重新嵌入全部文档**，不能把两种向量混在一个索引里。索引版本记录：

```python
from pydantic import BaseModel


class IndexVersion(BaseModel):
    index_id: str
    embedding_model: str
    dim: int
    normalize: bool
    distance_metric: str
    chunker_version: str
    parser_version: str
    status: str  # building / active / retired
```

切换模型的标准流程与第 2 章解析器升级同构：**新版本先构建到新索引，完整评测通过后原子切换 Alias，失败回到旧版本**。绝不在原索引上边删边写。

## 5. 本课程的低成本方案

小数据先本地，不依赖 Docker 或生产数据库：

| 层级 | 方案 | 说明 |
| --- | --- | --- |
| 开发/实验 | 内存 + 余弦相似度 | 几十万级 Chunk 以下够用，可离线跑评测 |
| 本地持久化 | Chroma（本地模式） | 持久化 + 元数据过滤 |
| 生产设计目标 | PostgreSQL + pgvector | 设计目标，本机不要求装 Docker |

Embedding 可选低价远程服务，开发时缓存结果；**不要将企业敏感文档发送给未批准的 Embedding 服务**——向量也是数据，能还原或泄露信息，数据条款必须核验。

批量嵌入与缓存：

```python
async def embed_chunks(chunks: list[Chunk], *, model: str, cache: EmbeddingCache):
    out: list[tuple[Chunk, list[float]]] = []
    for c in chunks:
        if vec := await cache.get(c.chunk_id, model):
            out.append((c, vec))
            continue
        vec = await embed(model, c.text)
        await cache.put(c.chunk_id, model, vec)
        out.append((c, vec))
    return out
```

缓存键必须含 `chunk_id + model`——换模型后旧缓存向量不能复用。失败续跑靠幂等：`chunk_id` 稳定，重跑已嵌入的 Chunk 直接命中缓存，不重复计费。

## 6. 向量库不是权限系统

向量库负责“向量最近邻”，不负责“谁有权看”。如果只靠向量库，跨租户泄漏无法避免。正确做法：

```python
async def vector_search(query: RetrievalQuery) -> list[Evidence]:
    # 1. 查询时强制注入服务端租户与 ACL 过滤
    results = await store.query(
        vector=embed(query.text),
        top_k=query.top_k * 2,  # 召回多一点，供过滤后仍够
        filter={
            "tenant_id": query.tenant_id,
            "doc_id": {"$in": sorted(query.allowed_doc_ids)},
        },
    )
    # 2. 返回后做防御性二次断言
    for r in results:
        assert r.tenant_id == query.tenant_id
    return results
```

两点：`tenant_id/allowed_doc_ids` 来自可信 Principal 和 ACL 服务（第 1 章已定），**不从用户 Prompt 抽取**；即使存储层声称过滤了，返回后仍做防御性断言，防止实现差异或缓存串味。`query.top_k * 2` 召回多一点，是因为过滤可能淘汰一部分，保证过滤后仍够用（第 5 章会正式化这个“先硬过滤再语义排序”的顺序）。

## 7. 烟雾测试与 Recall@k

Embedding 正确性的第一步不是跑大数据集，而是**烟雾测试**——一组已知相似/不相似的句子：

```python
SMOKE = [
    ("泵体振动超限如何处理", "设备振动值超过阈值时的排查步骤", "similar"),
    ("泵体振动超限如何处理", "本月工单审批流程", "dissimilar"),
]

def smoke_test(model: str) -> None:
    for a, b, label in SMOKE:
        s = cosine_similarity(embed(a, model), embed(b, model))
        assert (s > 0.7) == (label == "similar"), f"{a} vs {b} 异常"
```

烟雾测试通过后再跑证据集 `Recall@k`（至少一个标准证据进入 Top-K 的样本比例，口径与 M3 验收一致）。烟雾测试抓“模型/维度/度量用错”这类低级错误，数据集评测抓真实检索质量。

## 8. 项目任务

1. 实现批量嵌入 + 缓存（缓存键含 `chunk_id + model`）；
2. 实现失败续跑：嵌入中途失败，重跑已嵌入 Chunk 命中缓存不重复计算；
3. 实现 `IndexVersion` 与原子切换：新版本构建到新索引，评测后切换 Alias，失败回滚；
4. 实现查询时的 `tenant_id + allowed_doc_ids` 过滤与返回后防御性断言；
5. 写烟雾测试（相似/不相似各若干），再在证据集上跑 `Recall@5`；
6. 模拟一次 Embedding 模型切换，跑通“重嵌 → 评测 → 原子切换”。

## 9. 常见错误与诊断顺序

### 9.1 换模型后新向量混进旧索引

现象：部分结果相似度异常、召回质量波动。先查索引是否记录 `embedding_model/dim/normalize`，是否用“新索引 + 别名切换”而非原地混合。**不要**试图把两种向量归一化后硬拼。

### 9.2 跨租户召回

现象：A 租户能检索到 B 租户的 Chunk。先查查询 filter 是否真的注入 `tenant_id`、`allowed_doc_ids` 是否来自 ACL 服务，再查缓存键是否混入租户信息。**不要**只在生成层删答案掩盖。

### 9.3 相似度阈值拍脑袋

现象：用“相似度 0.8 以上才算命中”这类全局硬阈值，不同语料表现忽好忽坏。先查阈值是否在验证集上校准、是否结合了重排与拒答策略。第 7 章会正式化证据门槛。

### 9.4 烟雾测试通过但 Recall 低

现象：相似/不相似句子对没问题，但证据集召回差。先查切分质量（第 3 章）和查询处理（第 5 章），不要先换更大 Embedding——Recall 低常常不在向量层。

## 10. 练习题与答案

### 练习 1：更高维 Embedding 一定更好吗？

**答案：**不一定。质量取决于模型与领域的匹配，还增加存储与计算。用自有数据比较召回、成本与延迟，不要只看维度。

### 练习 2：能否直接按相似度 0.8 作为通用阈值？

**答案：**不能。分数随模型、度量和语料分布变化，应在验证集上校准，并结合重排与拒答策略。全局硬阈值会在不同语料上失效。

### 练习 3：向量库能当权限系统吗？

**答案：**不能。向量库只做最近邻，不做授权。租户与 ACL 过滤必须由代码在查询时注入可信身份，并在返回后做防御性断言。

### 练习 4：换 Embedding 模型为什么必须重嵌全部文档？

**答案：**不同模型的向量空间不同，向量不可跨模型比较，混入同一索引会破坏相似度语义。必须走“重嵌 → 新索引 → 评测 → 原子切换”。

## 11. 工程挑战

不联网的前提下完成：

1. 写一个索引版本契约测试：`IndexVersion` 记录 `embedding_model/dim/normalize/distance_metric`，缺失任何一项构造失败；
2. 写一个缓存键隔离测试：同一 `chunk_id` 在不同 `model` 下不命中同一缓存向量；
3. 写一个跨租户泄漏测试：构造两个租户的 Chunk，断言查询 A 租户时 B 租户 Chunk 不出现在结果里（即使存储层不配合，防御性断言也能兜底）。

参考方向：缓存用字典 `{ (chunk_id, model): vec }`；跨租户测试用内存向量存储 + 过滤断言；契约测试复用 Pydantic 边界测试写法。

## 12. 面试追问

1. 余弦相似度、点积、欧氏距离有什么区别？怎么选？
2. 为什么相似度分数不能跨模型比较？
3. 换 Embedding 模型的标准流程是什么？
4. 向量库为什么不能做权限判断？
5. 批量嵌入如何做到失败续跑不重复计费？

## 13. 本章复盘模板

```text
完成日期：
实际投入小时：
是否理解三种距离度量及不可跨模型比较的原因：
索引版本是否记录 embedding_model/dim/normalize/distance_metric：
查询是否注入 tenant_id + allowed_doc_ids 且返回后二次断言：
批量嵌入 + 缓存 + 失败续跑是否可用（缓存键含 model）：
烟雾测试与 Recall@5 是否跑通：
换模型是否跑通“重嵌 → 评测 → 原子切换”：
仍不理解的问题：
```

## 14. 官方资料与中文阅读指引

- [LangChain Semantic search](https://docs.langchain.com/oss/python/langchain/knowledge-base)：语义检索的知识库视角，用于 §3 原理与 §5 方案选型；
- [LangChain Chroma Integration](https://docs.langchain.com/oss/python/integrations/vectorstores/chroma)：Chroma 向量库集成，用于 §5 本地持久化；
- [pgvector README](https://github.com/pgvector/pgvector)：PostgreSQL 向量扩展，作为生产设计目标参考。

重点阅读：语义检索的嵌入与相似度口径；Chroma 的元数据过滤与本地持久化；API 细节以锁定版本官方文档为准。

## 15. 下一章入口

本章建立了可版本化、可重建、租户隔离的向量索引。下一章进入在线查询端的第一层：Query 处理、过滤与基础检索，把“硬过滤 + Top-k”的查询管线正式化。向量存储的抽象会在那里第一次被“查询”消费。

**关键闸门**：如果向量查询还没做到 `tenant_id + allowed_doc_ids` 过滤 + 返回后防御性断言，先回补，不要进入下一章——因为后续混合检索、Context 组装都建立在“索引层已经隔离租户”的假设上，这里漏了，越往后泄漏面越大。
