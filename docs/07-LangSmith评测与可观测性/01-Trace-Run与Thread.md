# Trace、Run 与 Thread

> 预计 5 小时｜产出：能从一次用户请求定位到模型、检索、工具和 Graph 节点。
> 所属阶段：第 7 阶段（LangSmith 评测与可观测性），第 1 章。

> **阅读前置**：第 4 阶段第 5 章（流式与 SSE 12 事件）、第 6 章（执行边界与循环检测）。本章把「运行过程」当作一等公民观测，承接第 4 章的 PII 边界与安全事件语义，是后续 Dataset/Experiment、Evaluator 与在线监控的共同底座。

## 1. 本章从哪里开始

第 4 阶段交付了一个「能跑、有终态、有边界」的智维 Agent，但它对外只暴露最终答案与 SSE 事件。一个用户问「EQ-001 出现 E42 先查什么」，Agent 回答了，可你有没有办法回答这三个问题：

1. 这次回答**调用了几次模型、走了哪个工具、检索了哪份手册**？
2. 为什么这次慢了 3 秒？是模型慢、检索慢，还是循环检测把它逼到了边界？
3. 同一个 `request_id`，SSE 事件、Trace、日志三者能不能对上同一条因果链？

「最终答案对」和「过程可观测」是两件事。第 4 章 §15 已经埋下一个约束：`search_manual` 只返回精简片段 + `evidence_ids`，不整段塞手册——这意味着「答案引用了哪条证据」是有据可查的。本章要做的，就是把这个「可查」从一句话变成一套**统一的 Case / Run / Event 契约**（对齐第 7 章权威契约），让你在失败发生时不必靠猜，而是从一次请求顺着执行树一路钻到某个 Run。

## 2. 本章完成标准（通过门槛）

必须同时满足：

- 能用自己的话讲清 Trace / Run / Thread 三者的关系，并知道业务 `request_id/run_id/thread_id` 与 LangSmith 自身 ID 的区别；
- 一次工单流程的失败，能从业务 ID 定位到**最慢的 Run、最贵的模型调用、失败的 Tool**，输出文字诊断而非只给截图；
- 生产环境默认**不采集正文或已脱敏**，敏感数据策略有代码落点，而不是一句口头承诺；
- 标签白名单、采样规则、与日志/Metrics 的分工各有明确记录；
- 接入 LangSmith 的同时保留**关闭开关**，关闭后不影响业务主流程；
- 所有可运行代码注明「以锁定版本官方文档为准」，不凭记忆写 API。

## 3. 三个核心概念：Trace / Run / Thread

LangSmith 的观测模型是一棵树：

| 概念 | 含义 | 智维 Agent 中的例子 |
| --- | --- | --- |
| Trace | 一次完整执行树，包含根 Run 与全部子 Run | 用户问「EQ-001 报 E42 先查什么」触发的整次调用 |
| Run | 树中一个节点：模型、工具、检索或自定义步骤 | `search_manual` 调用、`get_alarm` 调用、一次 LLM 生成 |
| Thread | 跨多次运行共享的会话上下文 | 用户连续追问三轮，共用一个 `thread_id` |

关键区分：**业务 ID 与平台 ID 是两套**。`request_id` 是 API 层为这次请求生成的；LangSmith 也会生成自己的 trace_id/run_id。两者必须同时存在：业务 ID 用于把 Trace、日志、Metrics、SSE 关联起来，平台 ID 用于在 LangSmith UI 里跳转。不要把业务 `run_id` 覆盖成平台 ID，否则离线复现与线上定位会脱节。

## 4. Run 的记录字段与语义事件

第 7 章权威契约把轨迹比较建立在**语义事件**上，而不是框架内部对象。一条 Run 至少记录：

```text
name / type / start / end / status
latency_ms / tokens / cost
model / prompt_version / data_version
error_code / metadata(业务 ID 等)
```

语义事件示例（与第 7 章 §8 一致）：

```json
{"type":"tool.requested","name":"search_manual","authorized":true}
{"type":"tool.completed","name":"search_manual","result_count":3,"evidence_ids":["manual-e42-v3-p18"]}
{"type":"approval.required","action":"create_work_order"}
```

注意：`tool.completed` 的 `result_count` 与 `evidence_ids` 是**安全摘要**，不回传完整手册正文。这正是第 4 章 §15 的延续——观测层也只记录「取回了什么、引用了什么」，不复制证据原文，从源头缩小 PII 与敏感数据暴露面。

## 5. 不泄露敏感数据：默认脱敏而非默认采集

Trace 的最大风险不是「看不到」，而是「看得太多」。生产环境默认对输入输出**脱敏或不采集正文**，理由有三：

1. Trace 常被索引、长期保存、在团队间分享，正文会扩大隐私暴露；
2. 用户问题里可能混入告警描述、设备资产号、甚至注入攻击载荷；
3. 模型输出可能包含从手册里带出的工艺参数，一旦入库就成了新的泄漏点。

脱敏建议分层：

```python
# src/observability/redact.py
import hashlib

REDACT_KEYS = {"content", "question", "answer", "evidence_text"}
MASK = "[REDACTED]"


def redact(obj):
    if isinstance(obj, dict):
        return {k: (MASK if k in REDACT_KEYS else redact(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(x) for x in obj]
    return obj


def fingerprint(text: str) -> str:
    # 用于检索"同一类问题"的哈希，替代明文正文进入标签或检索
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
```

`fingerprint` 只保留一个不可逆的短哈希，让你能统计「同一问题反复出现」而不保留问题原文。LangSmith 的输入输出过滤、`hide_inputs`/`hide_outputs` 等能力的具体用法**以锁定版本官方文档为准**，但「默认不采集正文」这个策略必须写进代码和运行规范。

## 6. 标签与采样

标签是检索 Trace 的入口，也是「哪些 Tag 可以打、哪些禁止打」的边界：

| 类型 | 推荐标签 | 禁止 |
| --- | --- | --- |
| 版本 | `env` / `app_version` / `graph_version` / `prompt_version` | — |
| 模型 | `model` | — |
| 租户 | `tenant_class`（如 `tenant-a` 这类分类） | 用户姓名、手机号、具体租户真实名 |
| 实验 | `feature_flag` | — |

**禁止把用户姓名、手机号当标签**——标签会被索引、聚合、展示，把 PII 打进标签等于把隐私暴露面再扩大一层。

采样策略：开发环境全量采样；生产按风险与费用设置采样率。**错误、高延迟、高风险动作可提高采样率**，正常快速请求可降低。这样在「观测成本可控」与「异常必然可见」之间取得平衡。费用这里只做 **Usage 观测 + 异常增长告警，不设固定金额上限**（延续第 4 阶段 M2 的契约）。

## 7. 与日志、Metrics 的分工

Trace 不是日志的替代品，三者职责不同：

| 通道 | 看什么 | 典型问题 |
| --- | --- | --- |
| 日志 | 服务事件、错误堆栈、单个进程状态 | 「哪个服务 429 了」「哪行报错」 |
| Metrics | 聚合趋势、分位数、SLO | 「P95 延迟这周涨了 30%」 |
| Trace | 单次因果链、调用树 | 「这一次为什么慢 / 为什么越权」 |

三者通过业务 ID 关联：从 Metrics 发现 P95 上升 → 抽一条慢 Trace → 顺着 Run 找到瓶颈 → 用日志看该 Run 的底层报错。缺了任何一环，「告警响了却查不到原因」就必然发生。

## 8. 可运行代码：接入与关闭开关

LangChain 生态下多数框架会自动上报 Trace，业务侧只需补 Metadata 与自定义 Run 名称：

```python
# src/observability/tracing.py
import os

from langsmith import traceable

TRACING_ENABLED = os.getenv("AGENT_TRACING_ENABLED", "0") == "1"

# 业务 ID 白名单：只把不敏感字段写进 metadata
def _safe_metadata(inputs: dict) -> dict:
    return {
        "request_id": inputs.get("request_id"),
        "tenant_class": inputs.get("tenant_class"),
        "graph_version": inputs.get("graph_version", "unknown"),
    }


@traceable(
    name="diagnose_equipment",
    metadata_fn=_safe_metadata,
)
def diagnose(inputs: dict) -> dict:
    # 业务主流程，不因关闭 tracing 而改变
    return agent.invoke(inputs)
```

要点：

- `TRACING_ENABLED` 是硬开关，关闭后业务照常跑，只是不上报；
- `_safe_metadata` 只放业务 ID 与版本号，正文绝不进 metadata；
- `@traceable` 的 `name` 稳定，避免 UI 里同名节点在不同版本含义漂移（对应第 6 章 M5 的「Evaluator 名称稳定」要求）。

`@traceable` 参数与 metadata 过滤的精确签名**以锁定版本官方文档为准**；上面的结构表达的是契约而非逐字 API。

## 9. 项目任务

1. 接入 LangSmith，同时保留 `AGENT_TRACING_ENABLED` 关闭开关，写一个开关关闭后业务仍通过的测试；
2. 为一次「查手册 → 查告警 → 建工单草稿」流程，定位**最慢 Run、最贵模型调用、失败 Tool**，输出文字诊断（含 `request_id`、调用树路径、结论）；
3. 实现 `redact.py` 与 `fingerprint`，写测试断言：正文键被替换为 `[REDACTED]`，标签中不出现用户姓名/手机号；
4. 在一条 Trace 里补上语义事件（`tool.requested/completed`、`approval.required`），证明它与 SSE 12 事件同源但字段不同（SSE 面向客户端，Trace 面向诊断）。

## 10. 常见错误与诊断顺序

### 10.1 把正文直接塞进 metadata

metadata 会被索引和展示，放正文等于把隐私暴露面扩大。诊断顺序：检查 `metadata_fn` 或埋点是否只放业务 ID 与版本 → 用 `redact` 对正文脱敏 → 需要检索同一类问题时用 `fingerprint` 短哈希替代明文。

### 10.2 业务 ID 与平台 ID 混用

用平台生成的 run_id 覆盖业务 `request_id`，会让日志、Metrics、SSE 无法对回同一条链。诊断顺序：确认埋点里 `request_id` 独立存在 → 检索时先按业务 ID，再跳平台 UI → 明确两套 ID 的映射关系，不互相覆盖。

### 10.3 只看最终 Trace 成功就下结论

成功 Trace 可能经历多余循环、降级或高成本。诊断顺序：先看整棵树的 Run 列表 → 检查轨迹（多余 Tool、重复调用）→ 检查延迟与费用 → 检查是否有被掩盖的副作用。

### 10.4 生产全量采样导致成本与噪声失控

全量采样既昂贵又制造海量低价值 Trace。诊断顺序：按风险分层采样 → 错误/高延迟/高风险动作提高采样率 → 正常路径降采样 → 费用仅观测 Usage + 异常增长告警，不设固定金额上限。

## 11. 练习题与答案

### 练习 1：为什么不能在 Metadata 放完整用户问题？

**答案：**Metadata 常被索引、展示和长期保存，放正文会扩大隐私暴露。正确做法是正文按策略脱敏（`redact`），需要检索同类问题时用 `fingerprint` 短哈希，正文加密且限期保留。

### 练习 2：只看最终 Trace 成功够吗？

**答案：**不够。成功可能经历多余循环、降级或高成本，也可能踩到了执行边界（模型调用 ≤4 / Tool Call ≤6 / 20s / 循环检测）才勉强成功。应检查轨迹、延迟、费用和工具副作用。

### 练习 3：Trace、日志、Metrics 三者如何分工？

**答案：**日志看服务事件与错误堆栈，Metrics 看聚合趋势与 SLO，Trace 看单次因果链。三者通过业务 ID 关联，不能互相替代。

## 12. 工程挑战

1. 写一个「失败 Trace 定位器」脚本：输入 `request_id`，输出按延迟排序的 Run 列表、每个模型调用的 Token/费用、第一个失败的 Tool 及错误码，纯文字、不依赖 UI 截图；
2. 给 `redact` 写边界测试：嵌套 dict、list、中文正文、空值都不能绕过脱敏；
3. 证明关闭开关是硬开关：`AGENT_TRACING_ENABLED=0` 时，`diagnose` 的返回值与开启时完全一致（除观测副作用外）；
4. 给一条 Trace 打上 `tenant_class` 但故意尝试打 `phone=138xxxx`，写断言让标签校验器拒绝该标签。

参考方向：定位器读 Trace 的 Run 树（以锁定版本官方文档为准）；标签校验可复用第 4 章 Middleware 的 PII 检查思路。

## 13. 面试追问

### 13.1 「Trace 和日志有什么区别？为什么要两套？」

回答框架：日志是单进程服务事件与堆栈，Trace 是跨模型/工具/检索的一次执行因果树。Metrics 看趋势，Trace 看单次。三者通过业务 ID 关联，缺一环就「告警响了查不到原因」。

### 13.2 「你们怎么保证 Trace 不泄露用户数据？」

回答框架：生产默认不采集正文或脱敏，只放业务 ID 与版本进 metadata；标签有白名单、禁止 PII；需要统计同类问题时用短哈希 `fingerprint`；接入有硬开关，敏感数据策略有代码落点与测试。

## 14. 本章复盘模板

```text
完成日期：
实际投入小时：
能否讲清 Trace/Run/Thread 与业务 ID/平台 ID 的区别：
是否从业务 ID 定位到最慢 Run、最贵模型调用、失败 Tool：
生产默认是否不采集正文或已脱敏，有无代码与测试：
标签白名单与采样规则是否落盘：
与日志/Metrics 的分工是否写清：
关闭开关是否验证过不影响业务：
仍不理解的问题：
```

## 15. 官方资料与中文阅读指引

- [Observability concepts](https://docs.langchain.com/langsmith/observability-concepts)：可观测对象（Trace/Run/Thread）的官方定义，用于 §3；
- [Trace an application](https://docs.langchain.com/langsmith/trace-with-langchain)：接入与埋点的具体写法，用于 §8；
- [OpenTelemetry Generative AI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)：跨平台的生成式 AI 观测语义，用于理解语义事件契约；
- 第 7 章《平台无关评测体系与数据飞轮》§8：语义事件契约，用于 §4 的对齐。

重点阅读：Observability concepts 的 Trace/Run 层级，与 Trace an application 的 metadata 注入方式；其余 API 细节以锁定版本官方文档为准。

## 16. 下一章入口

本章解决了「怎么看到一次执行」。但「看到」本身不是目的——下一步要把可观测的 Run 固化成**可复现的数据集与实验**，用版本对比判断一次改动是否真的更好。进入第 2 章《Dataset、Experiment 与版本对比》。

**关键闸门**：如果此刻你仍回答不了「这次请求调了几次模型、走了哪个工具」，说明观测层没打通，**不要进入 Dataset/Experiment**——否则后面跑出的指标无法追溯、无法复现，评测就是空中楼阁。
