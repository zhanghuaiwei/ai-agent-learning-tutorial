# Chunk 切分与元数据设计

> 预计 6 小时｜产出：适合设备手册的结构感知切分器。

> **阅读前置**：承接第 2 章的解析清洗与版本，本章把清洗后的结构化文本切成 Chunk，并设计 Chunk 元数据与稳定 ID。前置要求：第 2 章的 `DocumentRecord`（`document_id/version/content_hash/parser_version`）与 `section_path`；第 1 章的数据所有权表。不需要 Embedding，切分器的正确性可用纯文本断言验证。

## 1. 本章从哪里开始

第 2 章结束时，我们手里有了“带结构、可溯源”的解析文本。但解析文本还不能直接进索引：一段 5000 字的手册章节塞进一个 Chunk，检索时要么召回整章噪声，要么 Embedding 的语义被稀释。切分要回答的是：**最小检索单元应该多大、边界划在哪、元数据记什么**。

本章的债集中在两点：一是切分边界，固定字符长度会把“警告”和它的操作割裂、把表格行和表头分开；二是**Chunk ID 与元数据要为第 7 章的证据引用服务**——如果切分时没有 `chunk_id / document_id / version / heading_path / page / fault_codes / tenant_id / acl`，第 7 章就无法校验“引用是否真的存在于本轮 Context”。

## 2. 本章完成标准（通过门槛）

必须同时满足：

- 结构感知切分：按章节、设备型号、故障码、操作步骤、警告边界优先切分，过长段落再递归切分；
- 每个 Chunk 携带完整元数据，且权限字段（`tenant_id / acl`）与展示字段（标题、页码）分开，**均不可由模型生成**；
- Chunk ID 由稳定输入生成（`sha256(tenant_id + document_id + version + section_path + normalized_text)`），可重建、可去重；
- 关键步骤与警告不被割裂，表格行带表头；
- 实现字符基线、结构感知、父子块三种方案，在同一 30 条证据集上比较 `Recall@5`、重复率、平均 Context Token、人工可读性。

## 3. 切分目标：语义完整与检索精确的平衡

Chunk 太小，检索精确但语义不全（“先断电”脱离了“为什么断电”）；Chunk 太大，语义完整但检索噪声多、Embedding 被稀释。固定字符长度只是基线，维护文档有更强的结构信号可用：

| 结构信号 | 切分优先级 | 原因 |
| --- | --- | --- |
| 章节标题 | 高 | `heading_path` 是引用和过滤的依据 |
| 设备型号 | 高 | 型号是检索过滤的硬条件 |
| 故障码 | 高 | 精确匹配（配合 BM25） |
| 操作步骤编号 | 高 | 步骤是完整语义单元 |
| 警告框 | 高（不割裂） | 安全信息不能与操作分离 |

切分器的输出是结构化 Chunk，不是裸字符串：

```python
from pydantic import BaseModel, Field


class Chunk(BaseModel):
    chunk_id: str = Field(min_length=1)
    document_id: str = Field(min_length=1)
    version: str = Field(min_length=1)
    heading_path: str
    page: int | None = None
    start_offset: int
    equipment_type: str | None = None
    fault_codes: list[str] = Field(default_factory=list)
    tenant_id: str = Field(min_length=1)
    acl: frozenset[str]
    content_hash: str = Field(min_length=1)
    text: str = Field(min_length=1)
```

注意两类字段的分工：`heading_path / page / fault_codes / equipment_type` 是**检索与展示**字段；`tenant_id / acl` 是**权限**字段。它们分开建模，因为权限来自可信 ACL 服务，展示字段来自文档内容——一旦混用，就会给“用文档内容覆盖权限”留出空间。

## 4. 稳定 Chunk ID 的生成

Chunk ID 由稳定输入生成，是“可重建、可引用、可评测”的基石：

```python
import hashlib


def build_chunk_id(
    tenant_id: str,
    document_id: str,
    version: str,
    section_path: str,
    normalized_text: str,
) -> str:
    raw = f"{tenant_id}|{document_id}|{version}|{section_path}|{normalized_text}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()
```

三个约束：

1. **不依赖随机数或时间戳**——同一输入必须产出同一 ID，否则无法重建、无法去重；
2. **包含租户**——不同租户上传相同文本，ID 也不碰撞（`tenant_id` 参与哈希）；
3. **包含版本与 section_path**——文档改版或切分边界变化，ID 随之变化，天然支持版本化。

这个 ID 会一路流到第 4 章向量存储、第 6 章混合检索、第 7 章引用校验：`Evidence.chunk_id` 就是它。切分时做重复检测：同一 `content_hash` 的 Chunk 只入库一次，空 Chunk（清洗后无有效文本）直接丢弃并计数。

## 5. 重叠与父子块

### 5.1 重叠（overlap）

相邻 Chunk 之间保留少量重叠（如 50～100 token）可以保留边界上下文，防止一个语义被硬切在两段里。但它会制造重复召回和成本。基线建议：**先小重叠（甚至 0）跑通，再用评测决定是否加大**——不要默认开大重叠，那会让“同一段证据”在 Context 里重复出现。

### 5.2 父子块（parent-child）

长步骤文档的实用策略：**子块用于精确检索，父块用于生成完整上下文**。检索时命中子块，组装 Context 时带回它的父块，让模型看到完整步骤而不是半截：

```text
父块（完整操作流程，如"电机拆卸 8 步"）
  ├─ 子块 1（步骤 1-2，带 heading_path）
  ├─ 子块 2（步骤 3-5，带 heading_path）
  └─ 子块 3（步骤 6-8 + 警告，带 heading_path）
```

父子关系通过元数据字段（如 `parent_chunk_id`）表达，子块和父块共用同一 `document_id/version/tenant_id/acl`。

## 6. 三条切分红线

1. **不在编号操作步骤中间切断**——步骤是完整动作单元，切断了模型可能只看到“断电”没看到“挂牌”；
2. **不把“警告”与其操作分开**——警告必须落在它约束的那个步骤附近，否则安全信息丢失；
3. **表格行必须带表头**——脱离表头的数字无法理解，切分时把表头作为每行的上下文复制，或用父块承载整表。

这三条对应第 1 章“接入失败”里最危险的一类：不是召回不到，而是召回到了错误语义，模型却答得自信。

## 7. 三种切分方案对照

| 方案 | 实现 | 优点 | 缺点 |
| --- | --- | --- | --- |
| 字符基线 | 固定 512/1024 字符，带 overlap | 简单、可复现 | 无视语义边界，易割裂步骤 |
| 结构感知 | 按标题/步骤/警告边界切 | 语义完整，元数据准 | 实现更复杂，需解析结构 |
| 父子块 | 结构感知 + 父子关系 | 检索精确 + 上下文完整 | 索引量增，需管理父子关系 |

本章项目任务要求三者在**同一 30 条证据集**上比较 `Recall@5`、重复率、平均 Context Token、人工可读性。目的不是“选最花哨的”，而是拿到“结构感知相对字符基线有没有稳定收益”的数据——没有收益就不要为复杂度买单。

## 8. 项目任务

1. 实现字符基线切分器（固定长度 + overlap）；
2. 实现结构感知切分器（按标题/步骤/警告边界，递归切过长段落）；
3. 实现父子块切分器（子块检索 + 父块上下文）；
4. 实现 `build_chunk_id` 稳定 ID 与重复/空 Chunk 检测；
5. 在同一 30 条证据集上，比较三者的 `Recall@5`、重复率、平均 Context Token、人工可读性，写一份对照报告；
6. 断言：关键步骤与警告不被割裂、表格行带表头、ACL 字段完整。

## 9. 常见错误与诊断顺序

### 9.1 固定长度切分把步骤切断

现象：召回内容只有“断电”没有后续步骤，模型答不完整。先查切分是否用了结构信号，不要先调 Embedding。按顺序：是否识别了步骤编号边界 → 是否把警告与操作绑定 → 过长段落是否递归切分而非硬切。

### 9.2 相邻 Chunk 霸榜（重复召回）

现象：Top-K 里都是同一文档相邻 Chunk。先查 overlap 是否过大、是否缺少单文档候选数限制。第 6 章会做去重与多样性，但根因在切分的 overlap 设置。

### 9.3 Chunk ID 不稳定

现象：同一文本每次切分 ID 都变，去重失效、重建后引用对不上。先查 `build_chunk_id` 是否混入了随机数/时间戳，是否漏了 `tenant_id` 或 `version`。

### 9.4 权限字段被模型改写

现象：用户 Prompt 诱导模型“把 acl 改成公开”。根因是权限字段从模型输出或 Prompt 里回填。正确做法：`tenant_id/acl` 只在摄取时由服务端写入 Chunk 元数据，检索时由代码过滤，模型永远接触不到可写的权限字段。

## 10. 练习题与答案

### 练习 1：Chunk 越小检索越准吗？

**答案：**不一定。小块可能缺少条件、对象和结论，向量语义变弱，且步骤被割裂后反而答错。必须以证据命中和回答质量评测，而不是只追求“越小越精确”。

### 练习 2：ACL 为什么必须随 Chunk 存储？

**答案：**检索时需要在生成前过滤权限；只在最终回答层拦截，敏感片段已经进入模型上下文，泄漏已发生。ACL 必须作为 Chunk 元数据在索引层就参与过滤。

### 练习 3：为什么 Chunk ID 要包含 `tenant_id`？

**答案：**防止不同租户上传相同文本时 ID 碰撞，同时保证租户数据在索引里的稳定隔离。这也是“删除某租户文档时能精确删干净”的前提。

### 练习 4：父子块解决了什么问题？

**答案：**子块检索精确、父块上下文完整，兼顾召回精度与生成所需语义；代价是索引量增大、需管理父子关系。适合长步骤、长流程文档。

## 11. 工程挑战

不联网的前提下完成：

1. 写一个切分契约测试：构造一段“警告 + 步骤”文本，断言切分后警告与对应步骤在同一 Chunk 内；
2. 写一个表格切分测试：断言每行 Chunk 都带表头上下文；
3. 写一个 ID 稳定测试：同一输入多次调用 `build_chunk_id` 返回相同值，改动 `tenant_id` 后返回不同值；
4. 实现一个最小 `parent_chunk_id` 反查：给定子块 ID 能取回父块，用于第 7 章 Context 组装预演。

参考方向：切分测试用内存结构文本即可；ID 稳定性断言字符串相等；父子反查用字典映射 `child_id -> parent_id`。

## 12. 面试追问

1. 固定长度切分和结构感知切分怎么选？
2. Chunk 元数据里哪些是权限字段、哪些是展示字段？为什么分开？
3. 稳定 Chunk ID 为什么重要？它的输入包含哪些？
4. overlap 和父子块分别解决什么问题，代价是什么？
5. 表格怎么切才不会丢表头语义？

## 13. 本章复盘模板

```text
完成日期：
实际投入小时：
结构感知切分是否优先章节/型号/故障码/步骤/警告边界：
Chunk 元数据是否齐全且权限与展示字段分离：
稳定 Chunk ID 是否可重建、可去重、含 tenant_id：
关键步骤与警告是否不被割裂、表格行是否带表头：
三种切分方案是否在 30 条证据集上出了对照报告：
Recall@5/重复率/平均 Context Token/可读性数据是否留存：
仍不理解的问题：
```

## 14. 官方资料与中文阅读指引

- [LangChain Text splitters](https://docs.langchain.com/oss/python/integrations/splitters/index)：切分器总览，用于 §3 的切分抽象；
- [RecursiveCharacterTextSplitter](https://docs.langchain.com/oss/python/integrations/splitters/recursive_text_splitter)：递归字符切分，用于 §7 字符基线；
- [MarkdownHeaderTextSplitter](https://docs.langchain.com/oss/python/integrations/splitters/markdown_header_text_splitter)：按标题层级切分，用于 §7 结构感知参考。

重点阅读：递归切分器的分隔符顺序与 chunk_size/chunk_overlap 语义；Markdown 标题切分的 heading_path 保留方式；API 细节以锁定版本官方文档为准。

## 15. 下一章入口

本章产出了带完整元数据和稳定 ID 的 Chunk。下一章进入 Embedding 与向量检索：把这些 Chunk 向量化、建立可版本化的向量索引，并回答“向量库为什么不是权限系统”。切分质量会直接决定 Embedding 的质量——如果切分边界错了，向量再好也召不回正确证据。

**关键闸门**：如果 Chunk 元数据还缺 `tenant_id/acl`，或 `build_chunk_id` 不稳定，先回补，不要进入 Embedding——因为下一章要建立的向量索引会假设这些字段已在切分层就绪，缺了它们，权限过滤和版本切换都会在更下游暴露。
