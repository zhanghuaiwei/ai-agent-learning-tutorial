# Transformer、模型推理、微调与选型边界

> 建议投入：第 5 周 2 小时建立原理与 ADR；第 10/14 周用已学 Tool/RAG 补齐模型选型实验。目标不是转向算法岗，而是能解释模型为何有这些能力与限制，并做出 Prompt、RAG、微调和部署之间的工程选择。

> **阅读前置**：本章是第 3 阶段（LLM 应用与原生 Agent）的模型选型专题，不依赖本阶段第 1～6 章正文（当前为大纲态）。原理部分只需 M0 底座认知，可随时独立阅读；第 10/14 周的选型实验需先积累 Tool Calling 与 RAG 的实际项目经验。

## 1. 应用工程师需要理解到什么程度

你不需要手推完整反向传播，也不能把“调用过 Qwen API”描述成“精通大模型部署”。但必须回答：

- 文本如何变成 Token，Token 如何变成向量；
- Attention 为什么能组合上下文，也为什么不保证事实正确；
- 自回归生成、Temperature、上下文窗口和 KV Cache 如何影响质量/延迟；
- Prompt、RAG、Tool、SFT/LoRA 各自改变了什么；
- 云 API 与自托管推理的职责、成本和风险边界；
- 为什么模型升级必须经过评测，而不是看排行榜直接替换。

## 2. 从文本到下一个 Token

```text
原始文本
  → Tokenizer
  → token ids
  → Embedding + Position Information
  → 多层 Attention + MLP
  → 下一个 Token 的 logits
  → 采样/选择
  → 把新 Token 追加到上下文，继续生成
```

### 2.1 Tokenizer

Tokenizer 将文本转换为模型词表中的整数 ID。Token 不是汉字或英文单词的固定同义词：同一文本在不同模型上的 Token 数可能不同，代码、空格和罕见字符尤其明显。

应用影响：

- 费用和上下文限制按 Token 而不是字符计算；
- 截断必须优先保留 System 约束、当前任务和证据，不能机械截尾；
- Chunk 大小要用目标 Embedding/生成模型的 Tokenizer 验证；
- 供应商切换后重新测 Token、延迟和上下文装配。

### 2.2 Embedding

Embedding 把离散 Token ID 映射为连续向量。生成模型内部的 Token Embedding 与 RAG 使用的文本 Embedding 服务相关但用途不同，不能直接混为一个 API。

### 2.3 Self-Attention 的面试级理解

每个位置产生 Query、Key、Value。Query 与各 Key 的相似度经缩放和 Softmax 后成为权重，再对 Value 加权汇总：

```text
Attention(Q, K, V) = softmax(QKᵀ / √d) V
```

多头 Attention 允许模型在不同表示子空间组合信息；位置编码提供顺序。Decoder-only Causal LM 使用 Mask，当前位置不能看到未来 Token。

必须说明的限制：Attention 只是在给定上下文中计算相关表示，不是数据库查询、逻辑证明或权限校验。模型可以生成语言上合理但事实错误的内容。

### 2.4 MLP、残差与归一化

Attention 负责位置间的信息混合，MLP 对每个位置做非线性变换；残差连接和归一化帮助深层网络训练。应用面试通常不要求逐层矩阵尺寸，但要知道“模型参数”主要是这些层中训练得到的权重，不是运行时对话历史。

## 3. 生成阶段真正发生什么

模型每一步输出词表上所有 Token 的 logits。解码策略将其转为下一个 Token：

- Greedy：选最高概率，稳定但不一定全局最好；
- Temperature：调整分布尖锐程度，不是“事实准确度旋钮”；
- Top-p/Top-k：限制候选集合；
- Stop/最大输出：控制终止，但模型仍可能在停止前跑偏；
- Structured Output/Grammar：限制输出形状，不保证字段事实正确。

### 3.1 Prefill 与 Decode

- Prefill：一次处理输入上下文，长 Prompt/RAG Context 会增加首 Token 延迟；
- Decode：逐 Token 生成，输出越长总延迟越高；
- TTFT：Time To First Token；
- TPOT：Time Per Output Token。

前端看到流式输出更早，不代表总计算量消失。性能报告应至少区分 TTFT、总延迟、输入/输出 Token 和任务成功率。

### 3.2 KV Cache

自回归生成时，历史 Token 的 Key/Value 可以缓存，避免每一步重复计算全部历史。KV Cache 会占用显存，并随并发、序列长度、层数增长。因此“上下文窗口支持 100 万 Token”不等于在你的并发和成本条件下适合使用。

### 3.3 Batching、量化与模型并行

- Continuous Batching：动态合并不同请求的推理步骤，提高吞吐，但会影响调度和尾延迟；
- Quantization：降低权重/激活精度以减少显存和加速，可能损失质量或受硬件限制；
- Tensor/ Pipeline Parallel：跨设备拆模型，增加通信与运维复杂度；
- Prefix Caching：复用共同前缀计算，需要评估命中、隔离和 Cache 生命周期。

这些是 vLLM 等推理服务的边界知识。本课程只要求读懂指标与部署方案，不要求在低配电脑本地运行 GPU 服务。

## 4. Prompt、RAG、Tool 和 Fine-tuning 改变的不是同一层

| 方法 | 主要改变 | 适合 | 不适合 |
| --- | --- | --- | --- |
| Prompt/Context | 本次请求的指令与示例 | 行为说明、格式、少量示例 | 持久注入大量事实、强权限 |
| RAG | 运行时外部证据 | 私有/时效知识、引用与可删除数据 | 稳定改变模型行为风格 |
| Tool Calling | 连接确定性系统与实时数据 | 查询/写业务、计算、外部动作 | 把模型建议直接当授权结果 |
| SFT | 通过样本调整权重行为 | 固定任务模式、风格、领域格式 | 高频变化事实、无评测的数据堆积 |
| LoRA/PEFT | 只训练较少适配参数 | 资源受限的任务适配与多 Adapter | 无法绕过数据质量、推理部署和评测 |
| Full Fine-tuning | 更新大量/全部参数 | 资源充分且收益被证明的深度适配 | 普通应用的第一选择 |

选择顺序通常是：先建立 Baseline 和评测 → Prompt/Schema → RAG/Tool → 模型切换 → 有证据再考虑微调。不是永远不微调，而是先证明错误来自模型行为且无法由更简单方案解决。

## 5. SFT、LoRA、RLHF/DPO 的边界

### 5.1 SFT

Supervised Fine-Tuning 使用输入—目标输出样本继续训练模型。样本需经过授权、去重、清洗、格式统一和训练/验证/测试隔离。SFT 可以强化回答风格或任务模式，但不能保证模型永不幻觉。

### 5.2 LoRA/PEFT

LoRA 冻结基础权重，在目标模块旁训练低秩更新矩阵。优势是可训练参数和存储更少，可为同一基础模型维护多个 Adapter。仍需考虑：

- 基础模型许可证与版本；
- `target_modules/r/alpha/dropout`；
- 训练数据与评测污染；
- Adapter 与基础模型的兼容；
- 合并/热切换后的服务和回滚；
- 量化训练与推理的精度影响。

### 5.3 RLHF/DPO

它们用于偏好/对齐优化，不是普通企业知识注入捷径。面试应知道概念和数据要求，但当前应用开发主线不做训练实操。

## 6. 模型选型必须是实验

建立统一 `ModelCandidate`：

```python
from pydantic import BaseModel


class ModelCandidate(BaseModel):
    provider: str
    model: str
    supports_streaming: bool
    supports_tools: bool
    supports_structured_output: bool
    context_window: int | None
    data_region: str | None


class ModelScore(BaseModel):
    candidate: ModelCandidate
    task_success_rate: float
    schema_valid_rate: float
    tool_argument_accuracy: float
    p50_ttft_ms: int
    p95_total_ms: int
    avg_input_tokens: int
    avg_output_tokens: int
    observed_cost: float
```

选型步骤：

1. 固定 30～100 条代表性 Dataset 与评分规则；
2. 固定 Prompt、Tool Schema、RAG 版本和重试策略；
3. 比较 Qwen/DeepSeek 的成功率、Schema、工具参数、延迟、费用和安全；
4. 对失败做分类，不用一个平均分掩盖高风险错误；
5. 记录模型版本、日期和供应商参数；
6. 形成 ADR：默认模型、Fallback、不可接受缺陷和复核条件。

同一模型不同日期可能被供应商升级；完整回归要保存 `provider/model/request parameters/time`，若 API 返回模型快照 ID 也应记录。

## 7. 云 API 与自托管推理

| 维度 | 云 API | 自托管 vLLM 等 |
| --- | --- | --- |
| 上手与运维 | 快，供应商负责底层 | 需 GPU、镜像、调度、监控和升级 |
| 弹性 | 通常由供应商承担 | 需容量规划与扩缩容 |
| 数据边界 | 取决于合同、地域和供应商策略 | 可获得更强控制，但团队承担安全 |
| 模型定制 | 取决于产品能力 | 可加载开源权重、量化和 Adapter |
| 性能优化 | 参数有限 | 可调批处理、并行、缓存与量化 |
| 成本 | 按调用，易试验 | 固定资源与运维成本，利用率重要 |

本课程默认云 API，因为设备低配且目标是应用交付。企业项目仍通过内部 OpenAI-compatible `ModelGateway` 隔离供应商，以便未来把 Base URL 切到合规的自托管服务。

## 8. 多模态的应用边界

多模态应用开发并不等于训练 VLM。智维 Agent 可增加一个可选流程：

```text
设备铭牌/故障照片
  → 文件类型、大小、病毒与权限检查
  → OCR/VLM 抽取候选字段
  → Pydantic 校验
  → 用户确认设备编号/故障码
  → 才允许进入 Tool/RAG
```

图片中的文本同样属于不可信输入，可能包含 Prompt Injection；不能因为来自 OCR/VLM 就绕过权限、Schema 和人工确认。

## 9. 智维 Agent 小实验

### 实验 A：模型选型卡

使用同一批 30 条样例比较千问和 DeepSeek：

- 10 条结构化故障抽取；
- 10 条 Tool Calling；
- 5 条证据不足拒答；
- 5 条 Prompt Injection/越权；
- 记录 TTFT、总延迟、Token、费用和错误类型。

输出 `reports/model-selection-YYYYMMDD.md`，结论必须包含“在哪些任务失败”，不能只写总分。

分阶段完成：第 5 周先做 10 条 Prompt/基础行为，第 10 周加入 Structured Output 与 Tool，第 14 周加入 RAG/拒答并冻结最终报告，避免在尚未学习相应机制时机械复制测试。

### 实验 B：微调决策 ADR

假设“设备故障分类”准确率不足，依次验证：标签定义、Prompt 示例、RAG 证据、Tool 规则、模型切换。只有错误仍集中在稳定映射且有足够高质量标注数据时，才提出 LoRA PoC，并写出数据、GPU、评测和回滚成本。

## 10. 面试追问

### 10.1 RAG 和微调如何选？

知识需要时效、引用、权限和删除时优先 RAG；稳定行为模式/格式在 Prompt 和模型选择后仍不达标，且有高质量数据与评测时考虑微调。两者可组合，并非二选一。

### 10.2 长上下文能否取代 RAG？

不能直接。长上下文仍有检索定位、注意力稀释、权限过滤、版本、延迟和费用问题。小规模静态材料可直接放 Context；企业数据仍需要摄取、过滤、引用与评测。

### 10.3 量化为什么可能影响 Agent？

量化近似权重/激活，可能改变生成分布。普通对话看似相近，但 Tool 选择、JSON 边界和长链路错误会放大，因此必须用 Agent 轨迹和结构化输出数据集回归，而不是只测聊天观感。

## 11. 练习与答案

### 练习 1：Temperature 调到 0 是否不再幻觉？

**答案：**否。它主要降低采样随机性，模型仍可能稳定地产生错误。事实可靠性需要证据、Tool、Schema、拒答与评测。

### 练习 2：公司私有制度每周更新，是否适合 LoRA 注入？

**答案：**通常不适合。优先用带版本、ACL 和引用的 RAG；LoRA 更新慢、难删除单条事实，也不能自然给出来源。

### 练习 3：云模型响应慢，直接改自托管是否合理？

**答案：**先用 Trace 拆解 DNS/连接、排队、TTFT、输出长度、Tool/RAG 和重试；验证 SLO、数据合规、负载与总成本。自托管会新增 GPU 利用率、部署、扩缩容和故障恢复，不是免费加速。

### 练习 4：如何诚实描述 vLLM 能力？

**答案：**若只完成资料学习和架构设计，应写“理解 OpenAI-compatible serving、批处理、KV Cache、量化和可观测性边界”，不能写“精通 vLLM 性能调优”。完成真实部署和基准后再升级表述。

## 12. 验收标准

- [ ] 能在白板画出 Tokenizer—Transformer—Logits—Decode；
- [ ] 能解释 Prefill/Decode、TTFT、KV Cache 与长上下文成本；
- [ ] 能用业务例子区分 Prompt、RAG、Tool、SFT 和 LoRA；
- [ ] 完成 Qwen/DeepSeek 统一 Dataset 对照报告；
- [ ] 写出一份“不做微调”或“进入 LoRA PoC”的证据型 ADR；
- [ ] 不在简历中混淆模型 API 接入与模型训练/推理部署。

## 13. 资料来源

- [Hugging Face LLM Course：Transformer 工作方式](https://huggingface.co/docs/course/main/en/chapter1/4)
- [Attention Is All You Need](https://arxiv.org/abs/1706.03762)
- [Hugging Face PEFT Quicktour](https://huggingface.co/docs/peft/quicktour)
- [Hugging Face LoRA Concept Guide](https://huggingface.co/docs/peft/main/conceptual_guides/lora)
- [vLLM Online Serving](https://docs.vllm.ai/en/latest/serving/online_serving/)
- [千问模型服务文档](https://help.aliyun.com/zh/model-studio/)
- [DeepSeek API 文档](https://api-docs.deepseek.com/)
