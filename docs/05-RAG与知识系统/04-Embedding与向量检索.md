# Embedding 与向量检索

> 预计 7 小时｜目标：理解向量相似度、索引版本和低成本本地方案。

## 1. 核心原理

Embedding 把文本映射为向量，语义相近文本通常距离更近。余弦相似度、点积、欧氏距离的数值不可跨模型直接比较。模型、维度、归一化和距离度量必须作为索引版本的一部分。

查询与文档必须使用兼容的 Embedding 模型。切换模型意味着重新嵌入全部文档，不能把两种向量混在一个索引中。

## 2. 本课程方案

小数据先使用内存或本地 Chroma 持久化；Embedding 可选低价远程服务，开发时缓存结果。生产设计目标可写 PostgreSQL + pgvector，但不要求本机 Docker。不要将企业敏感文档发送给未批准的 Embedding 服务。

向量库不是权限系统：检索查询必须带服务端生成的租户与 ACL 过滤，返回后再做防御性校验。

## 3. 项目任务

实现批量嵌入、缓存、失败续跑、索引版本和原子切换。用已知相似/不相似句子做烟雾测试，再跑证据集 Recall@k。

## 4. 练习与答案

### 练习 1：更高维 Embedding 一定更好吗？

**答案：**不一定；质量取决于模型与领域匹配，还增加存储和计算。用自有数据比较召回、成本和延迟。

### 练习 2：能否直接按相似度 0.8 作为通用阈值？

**答案：**不能。分数随模型、度量和语料分布变化，应在验证集上校准，且结合重排与拒答策略。

## 5. 验收与资料

索引可重建、可版本化、无跨租户结果。参考 [Semantic search](https://docs.langchain.com/oss/python/langchain/knowledge-base)、[Chroma Integration](https://docs.langchain.com/oss/python/integrations/vectorstores/chroma)。

