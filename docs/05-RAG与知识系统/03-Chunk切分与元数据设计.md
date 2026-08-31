# Chunk 切分与元数据设计

> 预计 6 小时｜产出：适合设备手册的结构感知切分器。

## 1. 切分目标

Chunk 要在“语义完整”和“检索精确”间平衡。固定字符长度只是基线；维护文档优先按章节、设备型号、故障码、操作步骤和警告边界切分，再对过长段落递归切分。

每个 Chunk 建议包含：`chunk_id/document_id/version/heading_path/page/start_offset/equipment_type/fault_codes/tenant_id/acl/content_hash`。用于展示的来源字段与用于权限的字段不可让模型生成。

## 2. 重叠与父子块

重叠可保留边界上下文，但会制造重复召回和成本。先用小重叠基线再评测。父块用于生成完整上下文，子块用于精确检索，是长步骤文档的实用策略。

不要在编号操作步骤中间切断；不要把“警告”与其操作分开；表格行必须带表头，否则脱离上下文无法理解。

## 3. 项目任务

实现字符基线、结构感知、父子块三种方案，在同一 30 条证据集上比较 Recall@5、重复率、平均 Context Token 和人工可读性。

## 4. 练习与答案

### 练习 1：Chunk 越小检索越准吗？

**答案：**不一定。小块可能缺少条件、对象和结论，向量语义也会变弱；必须以证据命中和回答质量评测。

### 练习 2：ACL 为什么必须随 Chunk 存储？

**答案：**检索时需在生成前过滤权限；只在最终回答层拦截会让敏感片段已进入模型上下文。

## 5. 验收与资料

关键步骤和警告不被割裂，Chunk 可追踪且权限字段完整。参考 [Text splitters](https://docs.langchain.com/oss/python/integrations/splitters/index)、[Recursive splitter](https://docs.langchain.com/oss/python/integrations/splitters/recursive_text_splitter)。

