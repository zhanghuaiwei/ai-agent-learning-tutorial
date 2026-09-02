# 多模态文档、图片与语音 Agent

> 目标：把 PDF 页面、设备图片和语音描述接入受控 Agent 流程；不训练视觉/语音模型，重点学习输入治理、异步处理、证据、评测与降级。

> **阅读前置**：G9 多模态专题。前置要求：M0 底座与第 2 阶段第 7 章的后台作业（202 Job、异步处理、幂等投递）——多模态管道本质是长耗时 Job 编排。不依赖本阶段 RAG 主线章节正文。

## 1. 多模态应用开发的正确边界

应用工程师通常不是从零训练 OCR、ASR 或视觉语言模型，而是组合已有能力：

```text
文件/图片/音频上传
  → 类型与安全检查
  → 对象存储
  → 异步预处理
  → OCR/ASR/VLM Adapter
  → 结构化中间结果
  → 业务校验和 RAG/Agent
  → 引用原始证据
  → 评测、审计与删除
```

核心问题是：模型看到了什么、证据能否回溯、失败能否重跑、敏感数据如何处理、不同模态的误差如何传播。

## 2. 选择一个真实场景

“智维 Agent”使用三个受控场景：

1. 扫描版设备手册：OCR 后进入 RAG；
2. 设备铭牌/仪表盘图片：抽取型号、序列号和读数，必须人工确认；
3. 现场人员语音故障描述：ASR 转写后生成结构化告警信息，原音频不直接触发工单写入。

范围外：自动控制设备、人脸识别、声纹认证、医学诊断、训练视觉/语音基础模型。

## 3. 上传接口不是把 Base64 塞进 JSON

推荐流程：

```text
POST /v1/assets/presign
  → 客户端直传对象存储
POST /v1/assets/{id}/process
  → 返回 202 + job_id
GET /v1/jobs/{job_id}
  → 查询状态或订阅事件
```

上传阶段检查：

- 认证用户、tenant 和资源配额；
- 声明 MIME 与文件魔数是否一致；
- 允许的扩展名、大小、页数、时长和像素；
- 文件名不参与本地路径拼接；
- 恶意文件/压缩炸弹扫描；
- 对象存储路径包含不可猜 ID，不包含敏感原文件名；
- 短期签名 URL，不公开永久链接；
- 保存内容哈希用于去重和审计。

模型供应商可能保留上传内容，使用前必须核验数据条款；敏感数据优先脱敏、裁剪或选用企业合规通道。

## 4. 统一 Asset 与 Job 契约

```python
from datetime import datetime
from typing import Literal

from pydantic import BaseModel


class Asset(BaseModel):
    asset_id: str
    tenant_id: str
    media_type: Literal["document", "image", "audio"]
    object_key: str
    sha256: str
    size_bytes: int
    created_at: datetime


class MediaJob(BaseModel):
    job_id: str
    asset_id: str
    pipeline_version: str
    status: Literal["queued", "running", "succeeded", "failed", "cancelled"]
    attempt: int
    error_code: str | None = None
```

Worker 任务使用 `asset_id + pipeline_version` 作为幂等维度。相同文件在处理完成后重复提交，应返回既有结果或创建明确的新版本，而不是生成重复 Chunk。

## 5. 扫描文档与 OCR 管道

### 5.1 页面级中间结果

不要只保存拼接后的纯文本。每页至少保存：

```json
{
  "asset_id": "asset_123",
  "page": 7,
  "width": 2480,
  "height": 3508,
  "blocks": [
    {
      "type": "text",
      "text": "额定电压 380V",
      "bbox": [120, 410, 980, 520],
      "confidence": 0.96
    }
  ],
  "engine": "provider/model",
  "pipeline_version": "ocr-v2"
}
```

页码与坐标使最终回答可以链接到原始页面区域，也便于重新 OCR 或人工纠错。

### 5.2 表格和版面

扫描手册常见失败：页眉页脚混入正文、双栏顺序错乱、表格行列错位、单位丢失、图片说明与图片分离。处理策略：

- 先进行版面检测，再按阅读顺序组合；
- 表格同时保存 HTML/Markdown 与单元格坐标；
- 标题层级作为 Chunk 元数据；
- 单位和数值采用规则二次校验；
- 低置信度页进入人工复核队列；
- OCR Pipeline 版本变化触发可控重建索引。

## 6. 图片理解不是“看图说话”

设备图片任务应使用明确 Schema：

```python
class GaugeReading(BaseModel):
    device_type: str | None
    value: float | None
    unit: str | None
    min_visible: float | None
    max_visible: float | None
    confidence: float
    evidence_region: list[int] | None
    needs_human_review: bool
```

输入 Prompt 要求模型：看不清时返回 `null`，不猜序列号；读数接近安全阈值或置信度不足时强制人工确认。

图片预处理记录旋转、裁剪、压缩和 EXIF 删除。任何变换都保存派生 Asset 与父 ID，避免无法追溯模型实际输入。

## 7. 语音输入与流式 ASR

语音链包括：

```text
音频分片
  → VAD/格式归一
  → 流式或批量 ASR
  → partial/final transcript
  → 时间戳/说话人（若需要）
  → 术语纠正
  → 结构化故障描述
```

事件协议区分：

```json
{"type":"transcript.partial","seq":12,"text":"电机温度"}
{"type":"transcript.final","seq":13,"text":"电机温度超过八十度","start_ms":1200,"end_ms":4300}
```

Partial 只能用于 UI 反馈，不能触发 Tool。业务动作只消费 final transcript，并要求用户确认型号、数值和高风险结论。

断线后使用 `session_id + seq` 去重；超长音频进入后台 Job。不要在 Web 请求中无限等待整段转写。

## 8. 多模态 Prompt Injection

攻击指令可能藏在：

- PDF 白色小字、页脚或二维码；
- 图片内文字；
- 音频转写内容；
- 文件元数据和文件名；
- OCR/ASR 服务返回的字段。

防御原则：

1. 所有提取内容都是数据，不获得系统指令优先级；
2. 检索 Chunk 标注来源和信任等级；
3. 工具授权只依赖 Principal/Policy，不依赖文档文本；
4. 高风险操作预览并人工批准；
5. 将“要求泄露 Secret/修改权限/忽略规则”的内容加入红队集；
6. 图片、文档和音频的外部 URL 获取防 SSRF。

## 9. 失败与降级

| 失败 | 处理 |
| --- | --- |
| MIME 不支持 | 上传阶段拒绝 |
| 文件过大/过长 | 明确配额，提示拆分 |
| OCR 低置信度 | 标记页面，人工复核或换引擎 |
| VLM 超时 | 重试安全的读操作，必要时降级 OCR |
| ASR 断线 | 从已确认 seq 恢复 |
| 供应商不可用 | 排队、切换 Adapter 或稍后处理 |
| 结果 Schema 错误 | 有限修复，保留原响应用于诊断 |
| 人工拒绝 | 记录原因，不继续调用写工具 |

失败结果不能进入正式知识索引。处理状态与索引发布状态分离，使用“构建新版本 → 验证 → 原子切换”。

## 10. 多模态评测

### 10.1 文档/OCR

- 字符/词错误率；
- 标题层级准确率；
- 表格单元格准确率；
- 页码/坐标引用正确率；
- 最终 RAG Recall@K 和回答忠实度。

### 10.2 图片

- 字段级 Exact/容差准确率；
- 单位准确率；
- 应拒绝/应人工复核召回率；
- 低清、旋转、遮挡和强光分组表现。

### 10.3 语音

- WER/CER；
- 领域术语准确率；
- 数字和单位准确率；
- Partial 到 Final 延迟；
- 断线恢复和重复片段率。

### 10.4 业务指标

最终仍要测：故障信息收集完成率、人工修正率、错误工单数、处理时长和用户放弃率。单个模型指标不能替代业务效果。

## 11. 测试数据与隐私

建立四层数据：

1. 自制无敏感样本；
2. 获授权并脱敏的真实形态样本；
3. 扰动样本：模糊、旋转、噪声、口音、断续；
4. 红队样本：隐藏指令、恶意 URL、二维码和越权请求。

记录数据授权、保留期限和删除方式。删除 Asset 时同步处理派生图片、转写、OCR 块、向量和缓存；只删原文件并不算完成删除。

## 12. 项目练习

完成一个最小多模态闭环：

```text
上传扫描手册 5 页
  → 异步 OCR
  → 人工确认 1 个低置信度表格
  → 增量索引
  → 问答引用页码与区域
  → 删除 Asset 并验证索引不可检索
```

再选择图片或语音中的一个完成结构化抽取实验。无需同时购买多个供应商 API；Adapter、Fake 响应和少量真实样本即可验证工程契约。

## 13. 练习与答案

### 练习 1：VLM 可以直接读 PDF，为什么还需要 OCR 中间结果？

**答案：**直接读适合小规模理解，但企业检索需要页码、坐标、增量、版本、权限、低置信度复核和可重复索引。是否保留 OCR 取决于场景，但必须保留可追溯中间证据。

### 练习 2：ASR Partial 已经识别出“创建工单”，能否提前调用工具降低延迟？

**答案：**不能。Partial 会修订且语义不完整。只消费 Final，并对写操作要求结构化预览和明确确认。

### 练习 3：图片模型返回置信度 0.99，是否可以自动采信？

**答案：**模型自报置信度未必校准。应基于标注数据测其可靠性，并结合图像质量、业务阈值和规则；高风险读数仍需人工确认。

### 练习 4：删除原 PDF 后为什么向量库仍可能泄漏？

**答案：**派生 OCR 文本、Chunk、Embedding、缓存、Trace 和备份仍保存内容。需要通过数据血缘找到所有派生对象并执行可审计删除。

## 14. 面试追问

1. 多模态 API、OCR/ASR 专用模型如何选？
2. 如何设计大文件异步处理和幂等重跑？
3. 图片或音频里的 Prompt Injection 如何处理？
4. 如何从最终回答追溯到 PDF 页面或音频时间段？
5. OCR 模型升级后索引如何灰度重建？
6. 如何评测数字、单位和表格准确性？
7. 多模态数据删除为什么比文本消息删除更复杂？

## 15. 验收标准

- [ ] 上传、对象存储和异步 Job 有明确契约；
- [ ] MIME、大小、页数/时长、安全扫描和配额受控；
- [ ] 保存页面/区域或音频时间戳级证据；
- [ ] 低置信度和高风险结论进入人工复核；
- [ ] 多模态内容不能扩大 Tool 权限；
- [ ] 评测包含扰动、拒答和红队样本；
- [ ] 删除覆盖所有派生数据；
- [ ] 产出一个可演示的多模态业务闭环。

## 16. 资料来源

- [阿里云百炼：视觉理解](https://help.aliyun.com/zh/model-studio/vision)
- [阿里云百炼：语音识别](https://help.aliyun.com/zh/model-studio/speech-recognition)
- [PaddleOCR Documentation](https://www.paddleocr.ai/latest/en/index.html)
- [FastAPI Request Files](https://fastapi.tiangolo.com/tutorial/request-files/)
- [OWASP File Upload Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html)
- [OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [Qwen-VL Paper](https://arxiv.org/abs/2308.12966)
- [OpenTelemetry Generative AI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
