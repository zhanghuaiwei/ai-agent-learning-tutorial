# Structured Output 与 Schema 校验

> 所属阶段：第 3 阶段（LLM 应用与原生 Agent），第 3 章
> 预计用时：5～6 小时
> 项目产出：`Diagnosis` / `RouteDecision` 契约、三层约束校验与有限修复模块、首轮与修复后有效率评测
> 资料验证日期：2026-09-02

## 1. 本章从哪里开始

第 3 阶段第 1 章建立了一个判断："模型输出是概率性的，可靠性靠工程约束，不靠 Prompt 或采样参数。"第 2 章（Prompt 与 Context Engineering）解决了"怎么把正确的信息放进窗口"——`ContextBuilder` 已经能把系统规则、业务上下文和本轮检索证据按正确优先级装配进上下文。

但还差最后一步：**模型吐出来的是一段自由文本，我们怎么把它变成系统下游能安全消费的结构？** 这就是本章的主题。

本章的输入条件：

| 对象 | 所在文件 | 现状 |
| --- | --- | --- |
| `Severity = Literal["low", "medium", "high"]` | `schemas.py` | 三值枚举，第 2 阶段已定义 |
| `WorkOrderDraft` / `CreateWorkOrderDraftInput` | `schemas.py` | 工单草稿契约，第 2 阶段已定义 |
| `ToolResult`（`ok/code/data/retryable/observed_at`） | `schemas.py` | 统一错误信封，`code` 匹配 `^[A-Z][A-Z0-9_]*$` |
| `ModelGateway`（`chat`/`stream_chat`） | `gateway.py` | 只暴露文本接口，尚未有结构化输出能力 |
| `FakeGateway` | `fakes.py` | 离线替身，记录 `chat_calls` |
| `ContextBuilder` | 第 3 阶段第 2 章 | 已把证据放进上下文，产出"带证据 ID 的上下文" |

本章复用 `WorkOrderDraft` 契约，新增两个模型 `Diagnosis` 与 `RouteDecision`，写一个"校验 + 有限修复"模块，并为五类非法输出写测试、统计首轮与修复后有效率。

完成后你应该能回答：

1. 供应商已经"按 JSON Schema 生成"了，为什么本地还要再校验一遍？
2. `json.loads` 成功了，为什么这个结果仍然可能不能用？
3. 校验失败时，为什么最多只修复一次，而不是修到通过为止？
4. 伪造的 `evidence_id` 和"张冠李戴的设备 ID"分别由哪一层拦截？

## 2. 本章完成标准

必须同时满足：

- 在 `schemas.py` 新增 `Diagnosis`（`summary`/`severity`/`evidence_ids`/`requires_human`）与 `RouteDecision`，复用已有 `WorkOrderDraft`；
- 实现三层约束的降级路径与业务规则校验，修复重试有显式上限（`MAX_REPAIR_ATTEMPTS`）；
- 五类非法输出测试全部按预期失败：缺字段、额外字段、错误枚举、伪造引用、超长文本；
- 至少一条"语法合法但业务错误"的测试被业务校验拦截（如 `severity="high"` 但 `requires_human=false`）；
- 用剧本式网关离线跑通"首轮 / 修复后 / 失败"三态，统计首轮有效率与修复后有效率；
- `uv run pytest` 全绿，真实 API 调用次数为 0。

## 3. 三层约束：同一个结构，三条实现路径

### 3.1 心智模型

"让模型输出结构"这件事，从强到弱有三条路径：

1. **Provider 原生结构化输出**：把 JSON Schema 交给供应商，由推理引擎在生成时直接约束，输出符合 Schema 的概率最高；
2. **Tool Calling**：把结构伪装成一个工具的"参数"，模型为了触发工具而输出结构；
3. **文本 JSON + 本地解析**：模型输出自由文本，我们在本地 `json.loads` 解析——最脆弱，只作降级。

三层解决的是同一个问题——**把概率性的文本生成，收敛到可消费的结构**。它们的差异只在"约束发生在哪一侧、强度如何、失败模式是什么"。

一个贯穿全章的关键认知：**这三层都只是"让模型更可能输出合法 JSON"，没有一层能保证"业务正确"。** 所以无论选了哪一层，本地 Pydantic 校验 + 业务规则校验都必须照跑不误。这呼应了第 1 章的推论二：稳定环节必须落在确定性代码里。

### 3.2 第一层：Provider 原生结构化输出（优先）

供应商在采样时就用 Schema 约束每一步的合法 Token 空间，例如只允许 `severity` 字段生成 `low/medium/high/unknown` 之一。这是约束最强的路径，失败率最低，应该优先。

Pydantic 可以直接导出这个 Schema，不需要手写一份重复的 JSON Schema：

```python
from agent_service.schemas import Diagnosis

# Pydantic 单源导出：字段、枚举、max_length 全部自动落到 JSON Schema
diagnosis_schema = Diagnosis.model_json_schema()

# OpenAI 风格（Chat Completions）：
#   response_format={"type": "json_schema", "json_schema": {
#       "name": "diagnosis", "schema": diagnosis_schema, "strict": True}}
# OpenAI 风格（Responses API）：
#   text={"format": {"type": "json_schema", "name": "diagnosis",
#                    "schema": diagnosis_schema, "strict": True}}
# DeepSeek 兼容接口部分只支持到 json_object 粒度，约束弱于完整 json_schema：
#   response_format={"type": "json_object"}
```

注意两点：

- **Schema 从 Pydantic 单源导出**，而不是在 Prompt 里用文字描述一遍"severity 有哪几个值"。文字描述是软约束，Schema 是硬约束，二者不能互相替代；
- **`strict` 只约束"结构"**。供应商的 `strict=True` 保证的是字段名、类型、枚举合法，它不保证"引用的 `evidence_id` 真的来自本轮证据"，也不保证"高风险结论带了 `requires_human`"。这些是业务规则，供应商不知道、也不该知道。

### 3.3 第二层：Tool Calling（结构作为工具参数）

把结构定义为某个工具的 `parameters`：

```python
# 定义 emit_diagnosis 工具，参数 Schema 就是 Diagnosis。
# 模型被迫以"调用工具"的形式输出结构，而不是自由文本。
emit_diagnosis_tool = {
    "type": "function",
    "function": {
        "name": "emit_diagnosis",
        "description": "输出设备诊断结论",
        "parameters": diagnosis_schema,
    },
}
```

约束强度介于第一层和第三层之间：模型被工具参数 Schema 约束，但它在"调用工具"这件事上的自由度更高，可能出现**不调用该工具、或用错工具名**这类第一层不会有的失败模式。

这一层的价值在于为下一章 Function Calling 铺路：下一章里，"输出结构"和"选择工具"会合流——模型既输出工具名，又输出工具参数。本章先把"结构"这一半想清楚，下一章再处理"工具选择 + 权限 + 执行"那一半。

### 3.4 第三层：文本 JSON + 本地解析（最脆弱，只作降级）

模型输出自由文本，可能带 ```` ```json ```` 围栏、可能带解释性废话、可能干脆不是 JSON。我们在本地剥围栏 + `json.loads`。兼容性最好（任何模型都支持），但失败率最高。

它是**降级路径**：当某个供应商不支持第一层、或第一层出问题时兜底。本章会把它的完整实现写清楚，因为它的校验、修复、失败处理逻辑是三层共用的——第一层和第二层拿到结构后，也要走同一套"本地 Pydantic + 业务规则"。

### 3.5 选择矩阵

| 维度 | ① Provider 原生 | ② Tool Calling | ③ 文本 JSON |
| --- | --- | --- | --- |
| 约束强度 | 最强 | 中 | 最弱 |
| 供应商支持 | 视模型而定 | 视模型而定 | 全部支持 |
| 典型失败 | 业务规则违规 | 不调用工具/工具名错 | JSON 残缺/围栏/废话 |
| 在项目里的用法 | 主路径 | 下一章合流为动作选择 | 降级兜底 |
| 本地校验 | 必须 | 必须 | 必须 |

选择顺序：**能用 ① 就用 ①，不能就用 ②，最后才用 ③**。但无论落到哪一层，第 4 节的本地校验都是不可省略的最后一道门。

## 4. 无论哪层，本地 Pydantic 都是底线

### 4.1 语法正确 ≠ 业务正确

这是本章最重要的一句话。看一个例子：

```python
from agent_service.schemas import Diagnosis

# 这段 JSON 语法合法、枚举合法、字段齐全，Pydantic 完全通过：
raw = """
{
  "summary": "轴承磨损严重，建议立即停机更换",
  "severity": "high",
  "evidence_ids": ["S1"],
  "requires_human": false
}
"""
d = Diagnosis.model_validate_json(raw)
print(d.severity)        # high —— 合法
print(d.requires_human)  # False —— 合法，但违反了"高风险必须人工"的铁律
```

`severity="high"` 是合法的枚举值，Pydantic 没有任何理由拒绝它。但"high 风险却不要求人工复核"是一条**业务规则**，Pydantic 不知道这条规则存在。所以校验必须分成两段：

1. **Schema 校验**（Pydantic）：结构对不对——字段全不全、类型对不对、枚举合法不合法、长度超没超；
2. **业务校验**（确定性代码）：语义对不对——引用是否真实、设备是否一致、风险是否该有人工。

第 1 段拦截"结构错误"，第 2 段拦截"业务错误"。只有两段都过，结果才允许进入下游。这条分界在第 2 阶段第 2 章的 §9 已经埋下伏笔："LLM 输出校验失败可以有限修复，但不能无限重试"——本章把它完整落地。

### 4.2 为什么不能只靠供应商的 strict

有人会问：供应商的 `strict=True` 不是已经保证结构了吗？为什么还要本地再跑 Pydantic？

三个理由：

- **供应商 API 会变**：某个字段的行为、枚举的取值、Schema 的接受范围都可能随模型版本漂移，本地校验是唯一稳定的锚点；
- **业务规则供应商不知道**：`strict` 不知道"引用必须来自本轮证据"，也不知道"设备 ID 必须与请求一致"；
- **可测试性**：本地校验可以用 `FakeGateway` 离线测，供应商的行为你测不了。落在本地的约束才是可回归、可复现的约束。

所以结论不是"供应商校验没用"，而是"供应商校验是优化，本地校验是底线"。

## 5. 新契约：Diagnosis 与 RouteDecision

### 5.1 写进 schemas.py

在 `schemas.py` 追加两个模型。注意 `Severity` 三值已经存在，本章的诊断场景需要表达"证据不足以判断严重程度"，所以引入一个独立的诊断枚举：

```python
from typing import Literal

# 已有：Severity = Literal["low", "medium", "high"]
DiagnosisSeverity = Literal["low", "medium", "high", "unknown"]
Route = Literal["answer", "ask_user", "create_work_order", "escalate"]


class Diagnosis(BaseModel):
    """基于本轮证据的设备诊断结论。

    severity 多出 ``unknown``：证据不足以判断严重程度时，模型应诚实标
    unknown，而不是强行编一个 high/low。一旦进入工单草稿
    （WorkOrderDraft.severity），必须回落到三值 Severity——
    unknown 不允许直接建单，需人工确认。
    """

    model_config = ConfigDict(extra="forbid")

    summary: str = Field(min_length=1, max_length=500)
    severity: DiagnosisSeverity
    evidence_ids: list[str] = Field(min_length=1, max_length=8)
    requires_human: bool = False


class RouteDecision(BaseModel):
    """诊断后的下一步路由，为下一章 Function Calling 铺路。

    route 语义：
    - answer            直接回答（证据充分、风险可控）
    - ask_user          追问缺失信息（如设备型号、故障现象）
    - create_work_order 转工单草稿（调用 create_work_order_draft）
    - escalate          升级人工（高风险或证据严重不足）
    """

    model_config = ConfigDict(extra="forbid")

    route: Route
    reason: str = Field(min_length=1, max_length=500)
    target_equipment_id: str | None = Field(default=None, max_length=64)
```

### 5.2 severity 为什么多一个 unknown

`Diagnosis` 和 `WorkOrderDraft` 的 `severity` 字段**刻意不同**：

- `WorkOrderDraft.severity` 是三值 `Severity`——工单草稿是即将进入业务系统的对象，必须落在一个确定等级上；
- `Diagnosis.severity` 是四值 `DiagnosisSeverity`——诊断允许诚实地说"我判断不了"。

这个差异就是第 1 章"推论三：它擅长续写，不擅长'不知道'"的工程解法：**给模型一个合法的"不知道"出口**。如果没有 `unknown` 这个值，模型在证据不足时会被迫在 low/medium/high 里编一个，反而制造出"看起来有结论、其实是幻觉"的危险输出。

`unknown` 的下游语义很清晰：它**不能**直接转成工单草稿（见 §5.4），而应触发 `escalate`（升级人工）或 `ask_user`（追问补证据）。

### 5.3 RouteDecision 为 Function Calling 铺路

`RouteDecision` 不是"另一个结构输出"，它是**动作选择的雏形**。下一章 Function Calling 里，模型要输出"工具名 + 工具参数"；本章先让模型输出"路由 + 理由 + 目标设备"，把"决策"与"执行"分离：

- `answer` / `ask_user` / `escalate` 不触发任何写工具，只是决定了回复形态；
- `create_work_order` 触发唯一的写工具，且 `target_equipment_id` 必须与请求一致（§8.3 的业务校验）。

这样设计，是为了下一章把 `RouteDecision` 平滑替换成"真正的工具调用"时，业务校验逻辑可以原样保留——校验关心的始终是"引用真不真、设备对不对、风险该不该有人工"，与"结构来自工具调用还是文本"无关。

### 5.4 复用 WorkOrderDraft：Diagnosis 如何转草稿

`create_work_order` 路由 + `Diagnosis` 校验通过后，转成草稿入参。这里复用第 2 阶段的 `CreateWorkOrderDraftInput`，不需要新契约：

```python
from agent_service.schemas import CreateWorkOrderDraftInput, Diagnosis


def diagnosis_to_draft_input(
    diagnosis: Diagnosis,
    *,
    equipment_id: str,
    idempotency_key: str,
) -> CreateWorkOrderDraftInput:
    """Diagnosis → 工单草稿入参：复用第 2 阶段 WorkOrderDraft 契约。

    关键转换：Diagnosis.severity 允许 unknown，但草稿 severity 必须是三值。
    unknown 时升级人工确认，绝不在此处硬编一个等级。
    """
    if diagnosis.severity == "unknown":
        raise ValueError("E_UNKNOWN_SEVERITY: 诊断严重程度未知，禁止直接建单")

    return CreateWorkOrderDraftInput(
        equipment_id=equipment_id,
        summary=diagnosis.summary,
        # 排除 unknown 后，severity 运行时必是 low/medium/high 之一，
        # 由 Pydantic 在三值 Severity 上做最终校验兜底。
        severity=diagnosis.severity,
        idempotency_key=idempotency_key,
    )
```

这就是"复用既有契约"的含义：`Diagnosis` 是本章的新东西，但它最终落到草稿时，走的是第 2 阶段已经定义好的 `WorkOrderDraft` 管线，`idempotency_key` 的幂等语义也一并继承。

## 6. 三层校验的实现

新建 `src/agent_service/structured_output.py`。核心立场写在模块 docstring 里：

```python
"""Structured Output：三层约束的降级路径与有限修复。

核心立场：
1. Provider 原生结构化输出优先，Tool Calling 次之，文本 JSON 最脆弱只作降级；
2. 无论哪一层，Pydantic 校验 + 业务规则校验都必须本地再跑一遍；
3. 校验失败只做有限修复（MAX_REPAIR_ATTEMPTS），用尽则进入受控错误，不无限重试；
4. 残缺 JSON 只定位不抢救——绝不写正则去补逗号、补引号。
"""
from __future__ import annotations

import json
from collections.abc import Callable

from pydantic import ValidationError

from agent_service.schemas import Diagnosis, RouteDecision

MAX_REPAIR_ATTEMPTS = 1  # 首轮 + 最多修复一次；这是显式的费用与延迟上限


class SchemaRepairExhausted(Exception):
    """修复次数用尽仍未通过校验，进入受控错误/人工路径。"""

    def __init__(self, code: str, detail: list[str]) -> None:
        super().__init__(code)
        self.code = code
        self.detail = detail
```

### 6.1 extract_json：只定位，不抢救

```python
def extract_json(raw: str) -> dict | None:
    """只做『定位』，不做『抢救』。

    职责边界：剥掉 ```json 围栏、去掉首尾空白，然后 json.loads。
    如果 JSON 缺逗号、缺引号、字段错位——直接返回 None，绝不尝试修复。
    """
    text = raw.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].strip().startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        text = "\n".join(lines).strip()
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) else None
```

为什么"不抢救"？用正则去补逗号、补引号，等于在猜模型想说什么。猜对了是运气，猜错了是把一段本来该被拒绝的垃圾塞进下游。工程上更稳的做法是：**残缺 JSON 直接判失败，把"修复"这件事交还给模型**——模型才是那个应该重新生成正确文本的角色，而不是我们。

### 6.2 Pydantic Schema 校验

```python
def _summarize_errors(exc: ValidationError) -> list[dict]:
    """把 ValidationError 精简成可安全回喂模型的字段级错误。"""
    return [
        {"loc": [str(p) for p in e["loc"]], "type": e["type"], "msg": e["msg"]}
        for e in exc.errors()
    ]


def _pydantic_validate_diagnosis(data: dict) -> tuple[Diagnosis | None, list[str]]:
    try:
        return Diagnosis.model_validate(data), []
    except ValidationError as exc:
        errs = [json.dumps(e, ensure_ascii=False) for e in _summarize_errors(exc)]
        return None, errs
```

`ValidationError.errors()` 会给出每条错误的 `loc`（位置）、`type`（错误类型）、`msg`（人话描述）。这里只保留这三样，丢弃 `input`（原始输入值）和 `ctx`（完整上下文）——**这是 §8.4"不把敏感内部字段异常给用户"的第一道闸门**。

### 6.3 业务规则校验

```python
def validate_diagnosis_business(
    diagnosis: Diagnosis,
    *,
    evidence_ids: set[str],
) -> list[str]:
    """模型输出通过 Pydantic 后，还要过业务规则。

    两条铁律：
    1. 引用 ID 必须来自本轮证据——伪造的 evidence_id 必须被拦截；
    2. 高风险结论必须 requires_human=true——severity="high" 是合法枚举，
       但它与证据/规则可能矛盾。
    """
    errors: list[str] = []

    fabricated = sorted(set(diagnosis.evidence_ids) - evidence_ids)
    if fabricated:
        errors.append(f"E_FABRICATED_EVIDENCE: 引用不在本轮证据中 {fabricated}")

    if diagnosis.severity == "high" and not diagnosis.requires_human:
        errors.append("E_MISSING_HUMAN_REVIEW: 高风险结论必须 requires_human=true")

    return errors


def validate_route_business(
    decision: RouteDecision,
    *,
    request_equipment_id: str,
) -> list[str]:
    errors: list[str] = []
    if decision.route == "create_work_order":
        if decision.target_equipment_id is None:
            errors.append("E_MISSING_TARGET: create_work_order 路由必须指定 target_equipment_id")
        elif decision.target_equipment_id != request_equipment_id:
            errors.append(
                "E_EQUIPMENT_MISMATCH: "
                f"设备 ID 与请求不一致 ({decision.target_equipment_id} != {request_equipment_id})"
            )
    return errors
```

错误码沿用 `E_*` 前缀约定（`code` 匹配 `^[A-Z][A-Z0-9_]*$`），与第 2 阶段 `ToolResult` 信封一致。注意这些错误码是**给系统/模型看的机器码**，最终展示给用户的中文文案由上层根据 `code` 映射，绝不把 `E_FABRICATED_EVIDENCE` 这类内部术语直接甩给用户。

## 7. 有限修复策略

### 7.1 为什么最多修一次

校验失败后，我们可以把错误反馈给模型，让它再试一次。问题在于：**要不要一直试到成功为止？**

答案是不能。三个理由：

- **费用黑洞**：每次重试都是一次真实的模型调用，都要计费；无限重试等于把账单交给一个"可能永远过不了校验"的模型；
- **延迟失控**：用户等的是答案，不是看你和模型来回拉扯；
- **不可预测**：一个连续失败的输出，重试十次大概率还是失败——错误不是靠重试消除的，而是靠"更清楚地告诉模型哪里错了"消除的。反馈一次是最划算的那一次。

所以 `MAX_REPAIR_ATTEMPTS = 1`：首轮 + 最多修复一次。这也呼应蓝图 §13.2 的明确要求："Schema 错误的修复重试次数有限"。

### 7.2 完整修复循环

```python
def build_diagnosis_prompt(context: str, evidence_ids: list[str]) -> str:
    ids = ", ".join(evidence_ids)
    return (
        "基于以下证据给出设备诊断。只允许引用 evidence_ids 里出现的 ID，"
        "severity 只能是 low/medium/high/unknown，证据不足就标 unknown。\n"
        f"可用证据 ID: {ids}\n"
        f"证据内容: {context}\n"
        "严格输出一个 JSON 对象，不要输出解释。"
    )


def build_repair_prompt(raw: str, errors: list[str]) -> str:
    """把精简后的字段错误回喂模型，要求其修复。绝不回喂完整堆栈或敏感内部字段。"""
    return (
        "你上一次输出未能通过校验，请修复后只输出 JSON。\n"
        f"上次输出: {raw}\n"
        f"校验错误: {json.dumps(errors, ensure_ascii=False)}\n"
        "只输出修复后的 JSON。"
    )


def generate_diagnosis_with_repair(
    generate: Callable[[str], str],
    *,
    context: str,
    evidence_ids: set[str],
) -> Diagnosis:
    """三层约束里『文本 JSON + 本地解析』降级路径的完整实现。

    参数 generate 是"把 prompt 变成文本"的可调用对象：真实环境传
    ``lambda p: gateway.chat(p).text``，测试里传剧本式替身。
    """
    prompt = build_diagnosis_prompt(context, sorted(evidence_ids))
    raw = generate(prompt)

    for attempt in range(MAX_REPAIR_ATTEMPTS + 1):
        diagnosis, errors = parse_and_validate_diagnosis(raw, evidence_ids=evidence_ids)
        if diagnosis is not None and not errors:
            return diagnosis

        if attempt >= MAX_REPAIR_ATTEMPTS:
            raise SchemaRepairExhausted("E_SCHEMA_REPAIR_EXHAUSTED", errors)

        raw = generate(build_repair_prompt(raw, errors))

    raise AssertionError("unreachable")
```

`generate` 是一个 `Callable[[str], str]`，把"调模型"抽象掉。这样测试和评测脚本里可以注入一个剧本式替身（第一次返回坏 JSON、第二次返回好 JSON），**完全离线**验证修复循环。真实环境里传 `lambda p: gateway.chat(p).text`，一行接入 `ModelGateway`。

### 7.3 反馈给模型的错误要精简

`build_repair_prompt` 只把两样东西回喂给模型：

- 模型**自己上次的输出**（它需要知道自己错在哪）；
- **精简后的字段级错误**（`loc`/`type`/`msg`）。

刻意不回喂的东西同样重要：

- 不回喂 `ValidationError` 的完整 `input`/`ctx`——那里可能带着原始数据；
- 不回喂内部堆栈、数据库字段映射、代码路径——模型不需要知道这些，知道了也没用；
- 不回喂"业务规则如何实现"的细节——只需要告诉它"引用不在证据里"，不需要告诉它"我们有一个 `set` 差集判断"。

一句话：**反馈的目的是纠正，不是解释系统。**

## 8. 失败路径与安全边界

### 8.1 json.loads 成功 ≠ 业务正确

这是最容易踩的坑。`json.loads` 只回答"这是不是合法 JSON"，不回答"这 JSON 能不能用"。完整链路是：

```python
def parse_and_validate_diagnosis(
    raw: str,
    *,
    evidence_ids: set[str],
) -> tuple[Diagnosis | None, list[str]]:
    """语法解析 → Schema 校验 → 业务校验，三步串起来。"""
    data = extract_json(raw)
    if data is None:
        return None, ["E_INVALID_JSON: 输出不是可解析的 JSON 对象"]
    diagnosis, errors = _pydantic_validate_diagnosis(data)
    if diagnosis is None:
        return None, errors
    return diagnosis, validate_diagnosis_business(diagnosis, evidence_ids=evidence_ids)
```

三段式：**`json.loads` 成功（语法）→ Pydantic 通过（结构）→ 业务规则通过（语义）**。前两段过了，第三段仍可能失败——`severity="high"` 配 `requires_human=false` 就是"语法、结构都合法，业务非法"的典型。

### 8.2 伪造 evidence_id 的拦截

模型可能"编"一个不存在的引用 ID。这对应第 1 章幻觉分类里的第 3 类"引用不忠实"。拦截点不在 Schema，而在业务校验：

```python
# 本轮证据只有 {"S1", "S2"}，模型却引用了 S99
d = Diagnosis(
    summary="振动超限",
    severity="high",
    evidence_ids=["S1", "S99"],   # S99 是伪造的
    requires_human=True,
)
errors = validate_diagnosis_business(d, evidence_ids={"S1", "S2"})
assert "E_FABRICATED_EVIDENCE" in errors[0]
```

为什么这条规则必须落在确定性代码，而不是靠 Prompt 请求"请只引用真实 ID"？因为 Prompt 是软约束，模型可能"忘了"。而 `set(diagnosis.evidence_ids) - evidence_ids` 是确定性计算，伪造引用**必然**被差集算出来。这正是第 1 章结论的落地："引用不忠实靠证据 + 评测解决"，而这里的 `evidence_ids` 就是最小版本的"证据锚点"。

### 8.3 设备 ID 一致性

模型可能把设备 ID"张冠李戴"——对设备 A 的问题，给出了设备 B 的工单草稿。拦截点在 `RouteDecision`：

```python
r = RouteDecision(
    route="create_work_order",
    reason="需要建单",
    target_equipment_id="eq-other",   # 与请求的 eq-pump-01 不一致
)
errors = validate_route_business(r, request_equipment_id="eq-pump-01")
assert "E_EQUIPMENT_MISMATCH" in errors[0]
```

设备 ID 是**请求上下文里的既定事实**，模型无权篡改。凡是输出里出现设备 ID 的位置，都要与请求比对。这条规则和"引用必须来自证据"是同一类问题：**上下文里已有的确定信息，不允许被模型的输出覆盖。**

### 8.4 不把敏感内部异常给用户

校验失败时，用户不应该看到 `ValidationError` 堆栈、内部字段名、代码路径。用户看到的是：

- 一个稳定的错误码（如 `E_SCHEMA_REPAIR_EXHAUSTED`）；
- 一条不泄露内部细节的中文提示（如"本次诊断未能生成有效结论，请稍后重试或转人工"）。

内部细节只留在日志和 Trace 里，供开发排查。区分两类信息：

| 信息 | 给谁 | 例子 |
| --- | --- | --- |
| 精简字段错误 | 模型（修复反馈） | `{"loc": ["severity"], "type": "literal_error"}` |
| 稳定错误码 | 调用方/用户映射层 | `E_SCHEMA_REPAIR_EXHAUSTED` |
| 完整堆栈与原始输入 | 日志/Trace（脱敏） | 完整 `ValidationError` |

`SchemaRepairExhausted` 异常里只带 `code` 和 `detail`（字段级错误），不带堆栈，就是这个边界在代码上的体现。

## 9. 测试：五类非法输出与修复循环

新建 `tests/test_structured_output.py`。任务要求的五类非法输出——缺字段、额外字段、错误枚举、伪造引用、超长文本——分别对应一条测试：

```python
import pytest
from pydantic import ValidationError

from agent_service.schemas import Diagnosis, RouteDecision
from agent_service.structured_output import (
    SchemaRepairExhausted,
    extract_json,
    generate_diagnosis_with_repair,
    validate_diagnosis_business,
    validate_route_business,
)


def _diag(**overrides) -> dict:
    base = dict(
        summary="泵体振动超限，建议检查联轴器对中",
        severity="high",
        evidence_ids=["S1"],
        requires_human=True,
    )
    base.update(overrides)
    return base


class TestDiagnosisSchema:
    def test_missing_field_rejected(self) -> None:
        with pytest.raises(ValidationError):
            Diagnosis.model_validate({"summary": "缺 severity", "evidence_ids": ["S1"]})

    def test_extra_field_rejected(self) -> None:
        with pytest.raises(ValidationError):
            Diagnosis.model_validate({**_diag(), "unexpected": 1})

    def test_invalid_enum_rejected(self) -> None:
        with pytest.raises(ValidationError):
            Diagnosis.model_validate(_diag(severity="critical"))

    def test_too_long_summary_rejected(self) -> None:
        with pytest.raises(ValidationError):
            Diagnosis.model_validate(_diag(summary="超长" * 300))

    def test_empty_evidence_rejected(self) -> None:
        with pytest.raises(ValidationError):
            Diagnosis.model_validate(_diag(evidence_ids=[]))


class TestExtractJson:
    def test_plain_json(self) -> None:
        assert extract_json('{"a": 1}') == {"a": 1}

    def test_fenced_json(self) -> None:
        assert extract_json('```json\n{"a": 1}\n```') == {"a": 1}

    def test_broken_json_returns_none(self) -> None:
        # 缺逗号：定位成功、解析失败——绝不抢救
        assert extract_json('{"a": 1 "b": 2}') is None


class TestBusinessRules:
    def test_fabricated_evidence_blocked(self) -> None:
        d = Diagnosis.model_validate(_diag(evidence_ids=["S1", "S99"]))
        errors = validate_diagnosis_business(d, evidence_ids={"S1", "S2"})
        assert any("E_FABRICATED_EVIDENCE" in e for e in errors)

    def test_high_without_human_review_blocked(self) -> None:
        # json.loads 成功、Pydantic 通过，但业务规则拦截
        d = Diagnosis.model_validate(_diag(severity="high", requires_human=False))
        errors = validate_diagnosis_business(d, evidence_ids={"S1"})
        assert any("E_MISSING_HUMAN_REVIEW" in e for e in errors)

    def test_equipment_mismatch_blocked(self) -> None:
        r = RouteDecision(
            route="create_work_order", reason="x", target_equipment_id="eq-other"
        )
        errors = validate_route_business(r, request_equipment_id="eq-pump-01")
        assert any("E_EQUIPMENT_MISMATCH" in e for e in errors)


class TestRepairLoop:
    def _gen(self, outputs: list[str]):
        def _g(_prompt: str) -> str:
            return outputs.pop(0)
        return _g

    def test_first_try_success(self) -> None:
        good = '{"summary":"振动超限","severity":"high","evidence_ids":["S1"],"requires_human":true}'
        d = generate_diagnosis_with_repair(
            self._gen([good]), context="...", evidence_ids={"S1"}
        )
        assert d.severity == "high"

    def test_repair_once_then_success(self) -> None:
        bad = '{"summary":"振动超限","severity":"critical","evidence_ids":["S1"],"requires_human":true}'
        good = '{"summary":"振动超限","severity":"high","evidence_ids":["S1"],"requires_human":true}'
        d = generate_diagnosis_with_repair(
            self._gen([bad, good]), context="...", evidence_ids={"S1"}
        )
        assert d.severity == "high"

    def test_exhausted_raises(self) -> None:
        bad = '{"summary":"x","severity":"critical","evidence_ids":["S1"],"requires_human":true}'
        with pytest.raises(SchemaRepairExhausted):
            generate_diagnosis_with_repair(
                self._gen([bad, bad]), context="...", evidence_ids={"S1"}
            )
```

运行 `uv run pytest`，全部通过且真实 API 调用次数为 0——`_gen` 是剧本式替身，符合 `Callable[[str], str]` 签名，完全离线。

## 10. 首轮与修复后有效率

光有"能不能拦截"还不够，还要回答"拦下来之后有多少能被救回来"。新建 `scripts/structured_output_eval.py`，离线统计三态：

```python
"""统计结构化输出的首轮有效率与修复后有效率（离线，剧本式网关）。"""
from __future__ import annotations

from dataclasses import dataclass

from agent_service.structured_output import (
    SchemaRepairExhausted,
    generate_diagnosis_with_repair,
)

EVIDENCE = {"S1", "S2", "S3"}

# 每个样本：模型首轮输出 / 修复后输出（None 表示首轮即通过）
CASES = [
    {"id": "c01", "first": '{"summary":"振动超限","severity":"high","evidence_ids":["S1"],"requires_human":true}',
     "repair": None},
    {"id": "c02", "first": '{"summary":"振动超限","severity":"critical","evidence_ids":["S1"],"requires_human":true}',
     "repair": '{"summary":"振动超限","severity":"high","evidence_ids":["S1"],"requires_human":true}'},
    {"id": "c03", "first": '{"summary":"振动超限","severity":"high","evidence_ids":["S99"],"requires_human":true}',
     "repair": '{"summary":"振动超限","severity":"high","evidence_ids":["S1"],"requires_human":true}'},
    {"id": "c04", "first": '{"summary":"x","severity":"critical","evidence_ids":["S1"],"requires_human":true}',
     "repair": '{"summary":"x","severity":"critical","evidence_ids":["S1"],"requires_human":true}'},
    {"id": "c05", "first": '{"summary":"振动超限","severity":"high","evidence_ids":["S1"],"requires_human":false}',
     "repair": '{"summary":"振动超限","severity":"high","evidence_ids":["S1"],"requires_human":true}'},
]


def _scripted(outputs: list[str]):
    def generate(_prompt: str) -> str:
        return outputs.pop(0)
    return generate


@dataclass
class EvalResult:
    total: int = 0
    first_pass: int = 0
    repaired_pass: int = 0
    failed: int = 0


def run() -> EvalResult:
    r = EvalResult(total=len(CASES))
    for case in CASES:
        outputs = [case["first"]]
        if case["repair"] is not None:
            outputs.append(case["repair"])
        try:
            generate_diagnosis_with_repair(
                _scripted(outputs), context="...", evidence_ids=EVIDENCE
            )
            if case["repair"] is None:
                r.first_pass += 1
            else:
                r.repaired_pass += 1
        except SchemaRepairExhausted:
            r.failed += 1
    return r


if __name__ == "__main__":
    r = run()
    print(f"total={r.total} first_pass={r.first_pass} "
          f"repaired_pass={r.repaired_pass} failed={r.failed}")
    print(f"首轮有效率 = {r.first_pass / r.total:.0%}")
    print(f"修复后有效率 = {(r.first_pass + r.repaired_pass) / r.total:.0%}")
```

这组样本的统计口径：

- **首轮有效率**：首轮就通过的比例（`c01`，1/5 = 20%）；
- **修复后有效率**：首轮通过 + 修复一次后通过的总比例（`c01+c02+c03+c05`，4/5 = 80%）；
- **失败率**：修复后仍失败，进入受控错误/人工（`c04`，1/5 = 20%）。

三个数字合起来回答了一个完整的工程问题：**这套校验会拦下多少、拦下的能救回多少、救不回的怎么办。** 蓝图 §12.2 的验收目标是"核心结构化输出 Schema 合规率 ≥ 95%"，本章的离线样本只是最小演示，真实数字要用第 7 阶段的金标准数据集来跑——但统计口径和代码结构现在就能定。

## 11. 项目任务

在第 2 阶段 M0 代码 + 第 3 阶段第 2 章 `ContextBuilder` 的基础上完成：

1. 在 `schemas.py` 新增 `Diagnosis`（`summary`/`severity`/`evidence_ids`/`requires_human`）与 `RouteDecision`，保留 `WorkOrderDraft` 不动；
2. 实现 `src/agent_service/structured_output.py`：`extract_json`、Pydantic 校验、业务规则校验、`generate_diagnosis_with_repair`（显式上限 `MAX_REPAIR_ATTEMPTS=1`）；
3. 写 `tests/test_structured_output.py`，覆盖缺字段、额外字段、错误枚举、伪造引用、超长文本五类非法输出，以及修复循环三态（首轮成功/修复成功/修复耗尽）；
4. 写 `scripts/structured_output_eval.py`，离线统计首轮有效率与修复后有效率；
5. 全程 `uv run pytest` 保持绿色，M0 与第 2 章的既有测试不被破坏。

## 12. 常见错误与诊断顺序

### 12.1 供应商开了 strict 就跳过本地校验

现象：以为 `strict=True` 已经保证结构，结果上线后偶发"合法结构、非法业务"的数据流进下游。

诊断顺序：确认业务规则校验（引用、设备、风险人工）是否在本地确定性代码里落地。供应商的 strict 是优化，本地校验是底线，二者不冲突也不互相替代。

### 12.2 校验失败就无限重试

现象：为了"抢救"一个失败输出，循环里一直重试，费用和延迟失控。

诊断顺序：检查重试是否有显式上限（`MAX_REPAIR_ATTEMPTS`）。没有上限的重试是费用黑洞，必须在代码层强制。

### 12.3 用正则抢救残缺 JSON

现象：模型输出缺逗号，写正则去补，偶尔能救回，偶尔把垃圾塞进下游。

诊断顺序：明确 `extract_json` 的职责边界——只定位、不抢救。残缺 JSON 直接判失败，把"修复"交还给模型重新生成，而不是自己猜。

### 12.4 把 ValidationError 原样抛给用户

现象：用户看到一堆内部字段名和堆栈，既看不懂，又泄露了系统内部结构。

诊断顺序：边界处把 `ValidationError` 转成稳定错误码（`E_*`），只把字段级精简错误回喂模型，完整堆栈留日志/Trace 并脱敏。

## 13. 练习题与答案

### 练习 1：`json.loads` 成功了，为什么结果仍然可能不能用？

**答案：**`json.loads` 只证明语法是合法 JSON，不证明字段齐全、类型正确、枚举合法（那是 Pydantic 的活），更不证明业务正确——引用的 `evidence_id` 是否真实、设备 ID 是否与请求一致、高风险是否有人工复核。三段式校验（语法 → Schema → 业务）缺一不可。

### 练习 2：模型连续两次校验失败怎么办？

**答案：**停止修复，抛 `SchemaRepairExhausted` 进入受控错误或人工路径。无限修复会增加费用和不可预测性；错误不是靠重试消除的，反馈一次是最划算的一次，之后继续重试大概率仍是失败。

### 练习 3：为什么"伪造引用"不能靠 Prompt 解决，必须靠业务校验？

**答案：**Prompt 是软约束，模型可能"忘了"。而 `set(diagnosis.evidence_ids) - evidence_ids` 是确定性计算，伪造引用必然被差集算出来。凡是要绝对保证的规则，必须落在可测试的确定性代码里。

## 14. 工程挑战

在不联网的前提下完成：

1. 给 `Diagnosis` 增加一条业务规则：`severity != "unknown"` 且 `evidence_ids` 为空时，判定为 `E_EMPTY_EVIDENCE_FOR_CONFIRMED_DIAGNOSIS`，并补对应测试；
2. 把 `RouteDecision` 的 `answer` 路由拆成 `answer_confirmed`（有确定结论）和 `answer_uncertain`（结论带 uncertainty），说明这个改动对下游校验的影响；
3. 用剧本式网关构造一个"首轮坏、修复也坏、但修复后错误类型变了"的样本，断言修复循环在第二次失败后停止且错误码仍为 `E_SCHEMA_REPAIR_EXHAUSTED`。

参考方向：第 1 题的规则本质是"越确定的结论要求越强的证据"，与 §5.2 的 `unknown` 语义互补；第 2 题提醒你，路由枚举的扩改会牵动所有 `route == "answer"` 的判断分支，是"契约演进规则"在结构化输出上的又一次应用。

## 15. 面试追问

### 15.1 "你们怎么保证模型输出可靠？"

回答框架：三层约束（Provider 原生 > Tool Calling > 文本 JSON 降级）+ 无论哪层都本地 Pydantic 校验 + 业务规则校验（引用真实、设备一致、高风险人工）+ 有限修复（最多一次，失败进受控错误）。落点：可靠性靠工程约束，不靠 Prompt 或采样参数。

### 15.2 "`strict=True` 之后还要自己校验，是不是重复劳动？"

回答框架：不是。供应商 strict 保证结构，本地校验保证业务；供应商行为不可测、会漂移，本地校验可离线回归。两者是"优化"与"底线"的关系，各自兜住不同层的问题。

### 15.3 "校验失败为什么要限制重试次数？"

回答框架：费用（每次都是真实调用）、延迟（用户在等）、不可预测（连续失败重试十次仍失败）三个原因。显式上限 `MAX_REPAIR_ATTEMPTS`，失败进受控错误或人工，绝不让模型无限循环。

## 16. 本章复盘模板

完成后记录：

```text
完成日期：
实际投入小时：
Diagnosis / RouteDecision 是否已写入 schemas.py 且复用 WorkOrderDraft：
五类非法输出测试是否全部按预期失败：
"语法合法但业务错误"的测试是否被业务校验拦截：
修复循环三态（首轮成功/修复成功/修复耗尽）是否都跑通：
首轮有效率与修复后有效率是否已统计：
现在能否不看代码说出"三层约束"与"三段式校验"：
仍不理解的问题：
```

## 17. 官方资料与中文阅读指引

- [Pydantic JSON Schema](https://docs.pydantic.dev/latest/concepts/json_schema/)：`model_json_schema()` 如何把字段约束、`Literal` 枚举、`max_length` 导出为 JSON Schema；
- [Pydantic Validators](https://docs.pydantic.dev/latest/concepts/validators/)：`@field_validator` / `@model_validator`——本章的业务校验写在独立函数里（因为它需要 `evidence_ids` 等外部上下文），需要"纯跨字段规则"（如 `end > start`）时再学校验器；
- [LangChain Structured Output](https://docs.langchain.com/oss/python/langchain/structured-output)：结构化输出的框架级封装，含 `.with_structured_output()` 与错误重试（`reparse`）；
- [OpenAI Structured Outputs](https://platform.openai.com/docs/guides/structured-outputs)：Provider 原生 `json_schema` 与 `strict` 的官方口径；
- [DeepSeek API 文档](https://api-docs.deepseek.com/)：`response_format` 的兼容粒度（`json_object` 与更完整 Schema 的差异）。

重点阅读：Pydantic 导出 JSON Schema 的默认行为（哪些约束会落到 Schema、哪些不会），以及 LangChain 的 `with_structured_output` 内部其实也在做"解析 + 有限重试"——对照本章手写版本，理解框架帮我们省掉了什么、又替我们做了什么决策。

## 18. 下一章入口

本章把"模型的自由文本"收敛成了"校验过的结构"，但结构只是数据，还不是**动作**。`RouteDecision` 里的 `create_work_order` 已经暗示了下一步：模型不仅要输出结构，还要**选择调用哪个工具、带什么参数**，而系统要负责校验参数、鉴权、执行、再把结果回传。

下一章《Function Calling 完整原理》讲的就是这个：模型"建议调用"与系统"真正执行"之间的边界，以及 `ToolRegistry` 如何注册第 2 阶段 `tools.py` 里的 `search_manual` / `get_alarm` / `create_work_order_draft`、拒绝未知工具和额外参数。本章写好的 `validate_route_business` 与"结构来自哪里无关"的校验思路，会直接复用到工具参数校验上。
