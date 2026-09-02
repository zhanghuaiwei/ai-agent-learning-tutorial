# 类型系统、Pydantic 与 Agent 数据契约

> 所属阶段：第 2 周  
> 预计用时：5～6 小时  
> 项目产出：带运行时校验的数据契约、`ModelGateway` 接口与离线可测的 Fake 网关  
> 资料验证日期：2026-09-02

## 1. 本章从哪里开始

第 1 章结束时，`agent-service` 里真正在工作的对象只有这几个：

| 对象 | 所在文件 | 类型 |
| --- | --- | --- |
| `LLMSettings` | `config.py` | `@dataclass(frozen=True)` |
| `ChatResult` | `gateway.py` | `@dataclass(frozen=True)` |
| `ChatCompletionsGateway` / `ResponsesGateway` | `gateway.py` | 普通类，`__init__` 完全重复 |
| `create_gateway` | `gateway.py` | 工厂函数 |

第 1 章留下了三笔债，本章全部偿还：

1. §8.1 承诺过：两个网关的 `__init__` 是刻意重复，“下一章会用 Protocol 和 Provider Adapter 统一构造逻辑”；
2. §18 承诺过：定义内部接口、建立输入输出 Schema、建立可测试的 Fake Provider；
3. `ChatResult` 和 `LLMSettings` 只有类型标注，没有任何运行时校验——构造一个 `input_tokens=-999` 的 `ChatResult` 不会报任何错。

完成后你应该能回答：

1. 类型标注解决什么问题，不解决什么问题？
2. 为什么边界数据要用 Pydantic，内部对象可以继续用 dataclass？
3. `Protocol` 与继承有什么区别，业务代码为什么要依赖它？
4. 契约怎么演进才不破坏已经依赖它的调用方？

## 2. 本章完成标准

必须同时满足：

- `ChatResult` 迁移到 Pydantic，`schemas.py` 建立所有边界模型；
- 8 个非法输入测试全部按预期失败（校验生效）；
- 两个网关共享同一个 SDK 客户端构造点，`__init__` 重复消失；
- `ModelGateway` Protocol 定义完成，业务代码只依赖接口；
- `FakeGateway` 在不联网的情况下通过网关契约测试；
- `uv run pytest` 全绿，本章真实 API 调用次数为 0。

## 3. 类型标注：你已经会用一半

第 1 章代码里已经出现过这些标注，先确认自己理解每一行：

| 标注 | 出处 | 含义 |
| --- | --- | --- |
| `str \| None` | `ChatResult.request_id` | 可以为空的用户 ID |
| `Iterator[str]` | `stream_chat` 返回值 | 惰性产出的文本流 |
| `ChatCompletionsGateway \| ResponsesGateway` | `create_gateway` 返回值 | 两种网关之一 |
| `dict[str, str]` | `config.py` 的 `values` | 字符串到字符串的映射 |

本章新增两个：

```python
from typing import Literal, Protocol

Severity = Literal["low", "medium", "high"]
```

`Literal` 把“允许的取值”写进类型：`severity` 只能是三个字符串之一，写错任何地方静态检查器都会标红。

### 3.1 类型标注的边界

类型标注只约束静态检查器，不约束解释器：

```python
def shout(text: str) -> str:
    return text + "!"

shout(123)  # 类型检查器报错；解释器照常运行，直到 text + "!" 才崩溃
```

也就是说，类型系统保护的是“我们自己写的代码之间”的约定。它对三类数据完全无能为力：

- 来自 HTTP 请求体的 JSON；
- 来自 LLM 的输出；
- 来自外部工具、供应商 SDK 返回的结构。

这些是**边界数据**，需要一个运行时的校验机制。这就是 Pydantic 的位置。

## 4. dataclass 在边界处失败了

用第 1 章的 `ChatResult` 做一个实验：

```python
from agent_service.gateway import ChatResult

bad = ChatResult(
    text="",
    provider="",
    model="",
    input_tokens=-999,   # Token 不可能是负数
    output_tokens=10 ** 9,
    request_id=12345,     # 类型要求 str，传了 int
)
print(bad)  # 构造成功，无任何报错
```

三处非法数据全部通过。`dataclass` 信任调用者，不做校验。在内部确定数据上这是优点：零开销、无魔法。但第 1 章已经看到了两个危险信号：

- 流式路径上 `request_id` 通过 `getattr(response, "_request_id", None)` 提取，供应商不返回时是 `None`，返回什么类型完全不受我们控制；
- 不同供应商的 Usage 字段名不同（`prompt_tokens` / `input_tokens`），手工搬运字段时拼错只能在运行后靠肉眼发现。

结论可以写成一张表：

| 数据来源 | 信任程度 | 应该用 |
| --- | --- | --- |
| 我们自己构造、内部传递 | 完全信任 | `dataclass` 足够 |
| 配置、HTTP 请求体、工具入参 | 半信任 | Pydantic，强校验 |
| LLM 输出、供应商响应、外部系统数据 | 不信任 | Pydantic + `extra="forbid"` + 明确的错误码 |

Agent 系统的特殊性在于：LLM 输出是概率性的，外部工具可能返回脏数据。Prompt 只能“请求”模型输出正确 JSON，它是软约束；Schema 校验是可测试的运行时硬边界。这会贯穿整个教程。

## 5. 把 ChatResult 迁移到 Pydantic

### 5.1 建立 schemas.py

创建 `src/agent_service/schemas.py`。数据契约集中在一个文件，网关只负责协议翻译：

```python
from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class ChatResult(BaseModel):
    """两种网关共用的内部结果契约。"""

    model_config = ConfigDict(frozen=True, extra="forbid")

    text: str
    provider: str = Field(min_length=1)
    model: str = Field(min_length=1)
    input_tokens: int = Field(ge=0)
    output_tokens: int = Field(ge=0)
    request_id: str | None = None
```

与第 1 章的 dataclass 版本逐项对比：

| 特性 | `@dataclass(frozen=True)` | Pydantic `BaseModel` |
| --- | --- | --- |
| 冻结（防篡改） | `frozen=True` | `ConfigDict(frozen=True)` |
| 运行时校验 | 无 | 构造时校验所有约束 |
| 拒绝未知字段 | 无（静默忽略） | `extra="forbid"` |
| 序列化 | 手写 `asdict` | `model_dump()` / `model_dump_json()` |
| 从字典构造 | 手写 `**mapping` | `model_validate(mapping)` |
| JSON Schema 导出 | 无 | 内置，后续工具协议直接复用 |

关键约束的含义：

- `ge=0`：Token 数量非负。`input_tokens=-999` 现在会在构造时抛 `ValidationError`；
- `min_length=1`：`provider=""` 被拒绝；
- `extra="forbid"`：多传任何未知字段直接报错，防止拼写错误的字段名被静默吞掉（比如把 `output_tokens` 写成 `outputToken`）。

### 5.2 迁移成本：零

`gateway.py` 删除 dataclass 定义，改为从 `schemas` 导入：

```python
from agent_service.schemas import ChatResult
```

两个网关内部 `ChatResult(text=..., provider=..., ...)` 的构造代码**一个字都不用改**——Pydantic 的构造语法与 dataclass 的关键字构造兼容。`main.py` 里 `result.text`、`result.input_tokens` 的读取也不受影响。

这就是“契约先行”的好处：只要字段集合不变，实现从 dataclass 换成 Pydantic 对调用方是透明的。

### 5.3 校验失败长什么样

```python
from pydantic import ValidationError
from agent_service.schemas import ChatResult

try:
    ChatResult(text="ok", provider="", model="qwen", input_tokens=-1, output_tokens=0)
except ValidationError as exc:
    for error in exc.errors():
        print(error["loc"], error["type"], error["msg"])
```

输出会逐条列出非法字段、位置和原因。注意 `ValidationError` 是**可预期的边界错误**，应该被转换成稳定错误码返回调用方，而不是任由它带着堆栈往外冒。错误码体系在第 2 阶段第 5 章统一建立，本章先在工具层实现最小版本。

## 6. 领域模型与工具契约

### 6.1 数据流向

第 1 章的 `SYSTEM_PROMPT` 已经定义了业务：“设备维护知识助手”。数据在系统中经过的路径是：

```text
HTTP 请求 → Agent State → Tool 参数 → 外部数据源
                                 ↓
HTTP 响应 ← Agent State ← Tool 结果
```

每一条边界都需要模型。本章先为“设备、告警、工单、引用来源”四个领域概念和三个未来工具建立契约。工具的完整执行机制（Function Calling）在下一阶段学习，但数据契约现在就可以固定。

### 6.2 领域模型

继续写入 `schemas.py`：

```python
from datetime import datetime
from typing import Any, Literal

Severity = Literal["low", "medium", "high"]


class Equipment(BaseModel):
    """被维护的物理设备。"""

    model_config = ConfigDict(extra="forbid")

    equipment_id: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=128)
    location: str | None = Field(default=None, max_length=128)


class AlarmQuery(BaseModel):
    """告警查询条件。"""

    model_config = ConfigDict(extra="forbid")

    equipment_id: str = Field(min_length=1, max_length=64)
    severity: Severity | None = None


class AlarmRecord(BaseModel):
    """一条设备告警。"""

    model_config = ConfigDict(extra="forbid")

    alarm_id: str = Field(min_length=1)
    equipment_id: str = Field(min_length=1, max_length=64)
    severity: Severity
    title: str = Field(min_length=1, max_length=200)
    observed_at: datetime
    resolved: bool = False


class CitationSource(BaseModel):
    """引用来源：回答里每条结论都应该能追溯到文档。"""

    model_config = ConfigDict(extra="forbid")

    doc_id: str = Field(min_length=1)
    title: str = Field(min_length=1)
    section: str | None = None
    version: str = Field(min_length=1)
```

约定说明：

- `AlarmQuery` 是查询条件而不是完整告警：字段数量刻意少，因为它是外部输入，暴露的字段越少，攻击面和校验成本越小；
- `CitationSource` 现在看着“用不上”，到 RAG 阶段（维护知识助手）会直接复用；
- 金额类字段（未来工单可能有备件费用）统一用整数“分”或 `Decimal`，禁止 `float`——二进制浮点数无法精确表示 0.1。

### 6.3 工具输入输出模型

三个工具各自拥有独立的输入输出模型，不复用一个大而全的结构：

```python
class ManualSnippet(BaseModel):
    """手册片段：检索的最小返回单元。"""

    model_config = ConfigDict(extra="forbid")

    doc_id: str = Field(min_length=1)
    title: str = Field(min_length=1)
    section: str | None = None
    version: str = Field(min_length=1)
    excerpt: str = Field(min_length=1, max_length=1000)


class SearchManualInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    equipment_id: str = Field(min_length=1, max_length=64)
    keywords: list[str] = Field(min_length=1, max_length=8)
    top_k: int = Field(default=5, ge=1, le=10)


class SearchManualOutput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    matches: list[ManualSnippet] = Field(default_factory=list)


class GetAlarmInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    query: AlarmQuery


class GetAlarmOutput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    alarms: list[AlarmRecord] = Field(default_factory=list)


class CreateWorkOrderDraftInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    equipment_id: str = Field(min_length=1, max_length=64)
    summary: str = Field(min_length=1, max_length=2000)
    severity: Severity
    idempotency_key: str = Field(min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")


class WorkOrderDraft(BaseModel):
    model_config = ConfigDict(extra="forbid")

    draft_id: str = Field(min_length=1)
    equipment_id: str = Field(min_length=1, max_length=64)
    summary: str = Field(min_length=1, max_length=2000)
    severity: Severity
    suggested_actions: list[str] = Field(default_factory=list)
    citations: list[CitationSource] = Field(default_factory=list)


class CreateWorkOrderDraftOutput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    draft: WorkOrderDraft
```

两个设计决策值得展开：

**`idempotency_key` 为什么现在就出现。**`create_work_order_draft` 是写操作。下一章会为模型调用加入有限重试，届时“重试一个已经执行过的写操作”就会产生重复工单。入口处带上调用方生成的幂等键，执行方就能识别“这是重试，不是新请求”。契约里预留这一字段，是为了让后续章节的重试机制不需要破坏性变更。

**`top_k` 有上界。**任何外部可控的数值都要加上界，否则一次请求可以要求返回海量结果，拖垮下游。这是最小版本的“资源保护”。

### 6.4 ToolResult 信封

所有工具的对外返回统一包在一个信封里：

```python
class ToolResult(BaseModel):
    """所有工具的统一输出信封。"""

    model_config = ConfigDict(extra="forbid")

    ok: bool
    code: str = Field(pattern=r"^[A-Z][A-Z0-9_]*$")
    data: dict[str, Any] = Field(default_factory=dict)
    retryable: bool = False
    observed_at: datetime
```

约定：

- `code` 用稳定机器码（如 `OK`、`E_INVALID_ARGUMENT`、`E_NOT_FOUND`），永远不用 `1/-1` 或中文文案；展示给用户的中文由上层根据 `code` 映射；
- `retryable` 标记调用方是否值得立刻重试，为下一章的重试分类做准备；
- `data` 是 `dict[str, Any]`，**这是唯一允许开放结构的区域**——它承载 `SearchManualOutput` 等类型化结果的序列化形式。除此之外不要在契约里使用裸 `dict`。

### 6.5 工具的内存实现

创建 `src/agent_service/tools.py`，用内存假数据实现三个工具。它们在本阶段只服务于测试和后续章节的并发实验，不接真实数据源：

```python
from __future__ import annotations

from datetime import datetime, timezone

from agent_service.schemas import (
    AlarmRecord,
    CreateWorkOrderDraftInput,
    CreateWorkOrderDraftOutput,
    GetAlarmInput,
    GetAlarmOutput,
    SearchManualInput,
    SearchManualOutput,
    ToolResult,
)

_FAKE_ALARMS: list[AlarmRecord] = [
    AlarmRecord(
        alarm_id="alarm-0001",
        equipment_id="eq-pump-01",
        severity="high",
        title="泵体振动超限",
        observed_at=datetime(2026, 9, 1, 8, 30, tzinfo=timezone.utc),
        resolved=False,
    ),
    AlarmRecord(
        alarm_id="alarm-0002",
        equipment_id="eq-pump-01",
        severity="low",
        title="出口温度轻微升高",
        observed_at=datetime(2026, 9, 1, 9, 5, tzinfo=timezone.utc),
        resolved=False,
    ),
]

_DRAFT_STORE: dict[str, CreateWorkOrderDraftOutput] = {}


def _envelope(ok: bool, code: str, data: dict, retryable: bool = False) -> ToolResult:
    return ToolResult(
        ok=ok,
        code=code,
        data=data,
        retryable=retryable,
        observed_at=datetime.now(timezone.utc),
    )


def search_manual(payload: SearchManualInput) -> ToolResult:
    """在内存手册库里按关键词过滤。真实检索在 RAG 阶段实现。"""
    from agent_service.schemas import ManualSnippet

    snippets = [
        ManualSnippet(
            doc_id="manual-pump-01",
            title="离心泵维护手册",
            section="振动排查",
            version="v3",
            excerpt=f"设备 {payload.equipment_id} 振动超限时，先检查地脚螺栓与联轴器对中。",
        )
    ]
    output = SearchManualOutput(matches=snippets)
    return _envelope(True, "OK", output.model_dump())


def get_alarm(payload: GetAlarmInput) -> ToolResult:
    alarms = [
        a for a in _FAKE_ALARMS
        if a.equipment_id == payload.query.equipment_id
        and (payload.query.severity is None or a.severity == payload.query.severity)
    ]
    output = GetAlarmOutput(alarms=alarms)
    return _envelope(True, "OK", output.model_dump())


def create_work_order_draft(payload: CreateWorkOrderDraftInput) -> ToolResult:
    if payload.idempotency_key in _DRAFT_STORE:
        # 幂等：同一个键重复提交，返回第一次的结果而不是再建一份。
        output = _DRAFT_STORE[payload.idempotency_key]
        return _envelope(True, "OK_DUPLICATE", output.model_dump(), retryable=False)

    from agent_service.schemas import WorkOrderDraft

    draft = WorkOrderDraft(
        draft_id=f"draft-{len(_DRAFT_STORE) + 1:04d}",
        equipment_id=payload.equipment_id,
        summary=payload.summary,
        severity=payload.severity,
    )
    output = CreateWorkOrderDraftOutput(draft=draft)
    _DRAFT_STORE[payload.idempotency_key] = output
    return _envelope(True, "OK", output.model_dump())
```

注意 `create_work_order_draft` 的幂等分支：内存版用字典模拟“执行方识别重复请求”，生产环境会是数据库唯一约束或 Redis 键，但**契约行为从第一天就固定**。

非法输入在这层怎么处理？入口即校验：

```python
def safe_tool_call(payload_dict: dict) -> ToolResult:
    """工具边界：先校验再执行，校验失败转稳定错误码。"""
    from pydantic import ValidationError

    try:
        # 由调用方决定用哪个 Input 模型，这里只演示转换逻辑
        raise ValidationError("demo", SearchManualInput)
    except ValidationError as exc:
        return _envelope(False, "E_INVALID_ARGUMENT", {"errors": exc.errors()})
```

实际工程里不需要 `safe_tool_call` 这种转发函数——每个工具函数开头直接 `try: payload = XxxInput.model_validate(raw)`。要点是：**堆栈不出边界，错误码必须出边界**。

## 7. ModelGateway Protocol 与网关重构

### 7.1 用接口描述“网关是什么”

第 1 章 `create_gateway` 的返回值类型是 `ChatCompletionsGateway | ResponsesGateway` 的联合类型。两个问题：

- 每加一种网关（Fake、录制回放、未来的 Agent 专用网关），联合类型都要改；
- 调用方知道的具体类型越多，越容易偷懒访问实现细节。

定义接口：

```python
from typing import Protocol, Iterator

from agent_service.schemas import ChatResult


class ModelGateway(Protocol):
    """业务代码依赖的模型网关契约。"""

    def chat(self, user_text: str) -> ChatResult: ...

    def stream_chat(self, user_text: str) -> Iterator[str]: ...
```

`Protocol` 是结构化类型：任何类只要拥有签名匹配的 `chat` 和 `stream_chat` 方法，就自动满足这个接口，**不需要显式继承**。与 `abc.ABC` 的区别：

| 维度 | `abc.ABC` | `Protocol` |
| --- | --- | --- |
| 判定方式 | 显式继承 | 结构匹配（鸭子类型的静态版） |
| 为第三方类实现接口 | 做不到（不能改它的继承） | 可以，只要方法签名对上 |
| 适合场景 | 框架内强约束 | 边界接口、测试替身 |

对 Agent 项目尤其重要的一点：**Fake 不需要继承任何基类**，只要长得像网关，就能被注入到任何依赖 `ModelGateway` 的位置。

### 7.2 统一客户端构造

重构 `gateway.py`，偿还第 1 章“`__init__` 刻意重复”的债：

```python
from __future__ import annotations

from typing import Iterator, Protocol

from openai import OpenAI

from agent_service.config import LLMSettings
from agent_service.schemas import ChatResult

SYSTEM_PROMPT = "你是设备维护知识助手。信息不足时明确说明，不编造事实。"


def _build_client(settings: LLMSettings) -> OpenAI:
    """全项目唯一的 SDK 客户端构造点（Provider Adapter 的最小形态）。"""
    return OpenAI(
        api_key=settings.api_key,
        base_url=settings.base_url,
        timeout=settings.timeout_seconds,
        # 重试策略由下一章在网关之上显式实现，SDK 层保持关闭。
        max_retries=0,
    )


class ModelGateway(Protocol):
    def chat(self, user_text: str) -> ChatResult: ...

    def stream_chat(self, user_text: str) -> Iterator[str]: ...


class ChatCompletionsGateway:
    """基于 Chat Completions API 的网关。"""

    def __init__(self, settings: LLMSettings, client: OpenAI) -> None:
        self._settings = settings
        self._client = client

    # chat / stream_chat 的实现与第 1 章完全相同


class ResponsesGateway:
    """基于 Responses API 的网关。"""

    def __init__(self, settings: LLMSettings, client: OpenAI) -> None:
        self._settings = settings
        self._client = client

    # chat / stream_chat 的实现与第 1 章完全相同


def create_gateway(settings: LLMSettings) -> ModelGateway:
    """按配置组装网关，业务代码不感知差异。"""
    client = _build_client(settings)
    if settings.api_style == "responses":
        return ResponsesGateway(settings, client)
    return ChatCompletionsGateway(settings, client)
```

重构前后的结构对比：

```text
重构前                                  重构后
─────────────────────                  ─────────────────────
create_gateway                         _build_client（唯一构造点）
  ├─ ChatCompletionsGateway(            create_gateway
  │    自建 client)                        ├─ client = _build_client()
  └─ ResponsesGateway(                    └─ Gateway(settings, client)
       自建 client)
                                        业务代码 ──依赖──▶ ModelGateway
                                                              ▲
                                        ┌──────────────┬──────┴─────┐
                                 ChatCompletions ResponsesGateway  Fake
```

这就是 Provider Adapter 的最小形态：**供应商差异被压缩到两处**——客户端构造（`_build_client`）和协议翻译（各网关类内部）。`max_retries=0` 这类供应商策略只写一遍，不会再出现“改了一个忘了另一个”。

`create_gateway` 的签名和返回行为都没变，`main.py` 无需任何修改。

### 7.3 依赖方向

重构后项目的依赖方向变成：

```text
main.py / 业务代码
      │ 只依赖
      ▼
ModelGateway（Protocol，定义在 gateway.py）
      ▲                ▲                ▲
      │实现            │实现            │结构匹配
ChatCompletions    Responses       FakeGateway
  Gateway            Gateway      （无需继承）
```

判断一个重构是否值得，就看它有没有让“变化”更便宜：现在新增一种网关，是加一个类；之前是改联合类型 + 复制 `__init__`。

## 8. FakeGateway 与第一批测试

### 8.1 安装 pytest

```bash
uv add --dev pytest
```

在 `pyproject.toml` 中追加：

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
```

目录结构更新为：

```text
agent-service/
├── pyproject.toml
├── uv.lock
├── src/agent_service/
│   ├── __init__.py
│   ├── config.py
│   ├── schemas.py      # 本章新增：数据契约
│   ├── gateway.py      # 本章重构：Protocol + 客户端注入
│   ├── tools.py        # 本章新增：内存工具
│   ├── fakes.py        # 本章新增：测试替身
│   └── main.py
└── tests/
    ├── test_schemas.py
    └── test_gateway_fake.py
```

### 8.2 FakeGateway

创建 `src/agent_service/fakes.py`。测试替身放在 `src` 而不是 `tests` 下，因为它属于项目的一部分——后续章节的离线演示、CI 回归都要用它，而且它本身就是 `ModelGateway` 契约的一个活文档：

```python
from __future__ import annotations

from typing import Iterator

from agent_service.schemas import ChatResult

DEFAULT_FAKE_TEXT = "（Fake 网关固定回复）维护前请先断电并挂牌。"


class FakeGateway:
    """ModelGateway 的离线测试替身：不联网、行为确定。"""

    def __init__(
        self,
        *,
        text: str = DEFAULT_FAKE_TEXT,
        chunks: list[str] | None = None,
    ) -> None:
        self._text = text
        self._chunks = chunks if chunks is not None else list(text)
        self.chat_calls: list[str] = []

    def chat(self, user_text: str) -> ChatResult:
        self.chat_calls.append(user_text)
        return ChatResult(
            text=self._text,
            provider="fake",
            model="fake-model",
            input_tokens=len(user_text),
            output_tokens=len(self._text),
            request_id=None,
        )

    def stream_chat(self, user_text: str) -> Iterator[str]:
        yield from self._chunks
```

注意它没有继承任何基类——结构匹配 `ModelGateway`。`chat_calls` 记录调用历史，供测试断言“到底调了几次模型”，这是下一章重试机制的关键观测点。

### 8.3 网关契约测试

`tests/test_gateway_fake.py`：

```python
from agent_service.fakes import FakeGateway


def test_fake_gateway_returns_valid_chat_result() -> None:
    gateway = FakeGateway()
    result = gateway.chat("设备温度升高怎么办？")

    assert result.provider == "fake"
    assert result.input_tokens >= 0
    assert result.output_tokens >= 0
    assert result.text  # 非空回复


def test_fake_gateway_streams_in_order() -> None:
    gateway = FakeGateway(chunks=["设备", "维护", "三步"])
    assert list(gateway.stream_chat("任意问题")) == ["设备", "维护", "三步"]


def test_fake_gateway_records_calls() -> None:
    gateway = FakeGateway()
    gateway.chat("第一次")
    gateway.chat("第二次")
    assert gateway.chat_calls == ["第一次", "第二次"]
```

这组测试同时是 `ModelGateway` 契约的**可执行文档**：任何新网关实现，都跑同一组断言（用参数化把 `FakeGateway` 换成新实现即可），这就是契约测试的雏形。

### 8.4 八个非法输入测试

`tests/test_schemas.py`。每个测试对应一条边界规则：

```python
import pytest
from pydantic import ValidationError

from agent_service.schemas import (
    AlarmQuery,
    ChatResult,
    CreateWorkOrderDraftInput,
    SearchManualInput,
    ToolResult,
)


class TestChatResult:
    def test_negative_tokens_rejected(self) -> None:
        with pytest.raises(ValidationError):
            ChatResult(text="ok", provider="p", model="m", input_tokens=-1, output_tokens=0)

    def test_extra_fields_rejected(self) -> None:
        with pytest.raises(ValidationError):
            ChatResult(
                text="ok", provider="p", model="m",
                input_tokens=1, output_tokens=1,
                unknown_field="不应被接受",
            )


class TestAlarmQuery:
    def test_extra_fields_rejected(self) -> None:
        with pytest.raises(ValidationError):
            AlarmQuery(equipment_id="eq-01", unexpected=1)

    def test_empty_equipment_id_rejected(self) -> None:
        with pytest.raises(ValidationError):
            AlarmQuery(equipment_id="")

    def test_invalid_severity_rejected(self) -> None:
        with pytest.raises(ValidationError):
            AlarmQuery(equipment_id="eq-01", severity="critical")


class TestToolInputs:
    def test_empty_keywords_rejected(self) -> None:
        with pytest.raises(ValidationError):
            SearchManualInput(equipment_id="eq-01", keywords=[])

    def test_top_k_out_of_range_rejected(self) -> None:
        with pytest.raises(ValidationError):
            SearchManualInput(equipment_id="eq-01", keywords=["泵"], top_k=99)


class TestCreateWorkOrderDraft:
    def test_bad_idempotency_key_rejected(self) -> None:
        with pytest.raises(ValidationError):
            CreateWorkOrderDraftInput(
                equipment_id="eq-01",
                summary="更换密封件",
                severity="high",
                idempotency_key="有 非法 字符",
            )
```

运行：

```bash
uv run pytest
```

9 个测试（含 3 个网关测试）全部通过，**真实 API 调用次数为 0**。这就是第 1 章 §11.1 承诺的“普通自动化测试使用 Fake”落到实处的样子。

## 9. 契约演进规则

契约一旦被别人依赖，修改就不再是自由行为。判断兼容性的速查表：

| 变更类型 | 例子 | 兼容性 |
| --- | --- | --- |
| 新增可选字段 | `ToolResult` 加 `schema_version: int = 1` | 兼容：旧调用方不受影响 |
| 放宽约束 | `top_k` 上界 10 → 20 | 通常兼容 |
| 新增必填字段 | `ToolResult` 加 `elapsed_ms: int`（无默认值） | 不兼容：旧生产者构造即失败 |
| 删除字段 | 移除 `request_id` | 不兼容 |
| 改名 | `text` → `content` | 不兼容 |
| 收紧取值 | `severity` 增加 `"critical"` 并强制 | 对部分旧调用方不兼容 |

给必填字段做“安全加字段”的标准流程：

1. 以**可选字段**形式加入（带默认值），发布；
2. 所有生产者升级为总是填充该字段；
3. 观察一段时间确认无缺省数据；
4. 再收紧为必填，此时只有“未升级的旧生产者”会失败。

其他三条纪律：

- **Tool 入参与出参都定义 Schema，日志记录 Schema 版本**——出问题时才能区分“数据坏了”和“契约变了”；
- `dict[str, Any]` 只用于真正的开放扩展区（`ToolResult.data`），不要因为“懒得建模”而在正式契约里裸奔；
- **LLM 输出校验失败可以有限修复**（最多重试一两次并附加错误提示），但不能无限重试——那是费用黑洞。输出修复的完整模式在下一阶段 Structured Output 章节展开，本章只需要记住边界：重试次数必须显式有上限。

本章与下一阶段《Structured-Output与Schema校验》的分界线：本章管理**我们自己代码的边界**（配置、网关结果、领域模型、工具入参出参）；LLM 生成的 JSON 如何校验、修复、重试，属于那章的主题。

## 10. 项目任务

在上一章代码基础上完成：

1. 建立 `schemas.py`，迁移 `ChatResult` 并实现全部领域模型与工具 IO 模型；
2. 重构 `gateway.py`：`ModelGateway` Protocol、`_build_client` 统一构造、客户端注入；
3. 实现 `tools.py` 三个内存工具与 `fakes.py` 的 `FakeGateway`；
4. 写出 8 个非法输入测试（上面 8.4 的清单是底线，可以更多）；
5. `main.py` 保持零修改可用（自行验证：`uv run python -m agent_service.main` 行为与第 1 章一致，前提是配置了环境变量）。

## 11. 常见错误与诊断顺序

### 11.1 ValidationError 在网关内部炸

现象：真实调用返回后构造 `ChatResult` 时抛校验错误。

按顺序检查：供应商是否返回了空的 `model` 字段（`min_length=1` 拒绝空串）；Usage 是否为 `None` 时被写成 `-1` 之类的哨兵值。**不要为了过关去放宽约束**，先确认是数据问题还是约束错了。

### 11.2 extra="forbid" 与外部数据冲突

现象：从外部 JSON 构造模型时报“额外字段”。

`forbid` 用在**我们定义输入**的契约上（请求体、工具入参）；对供应商响应这类“别人定义结构”的数据，转换层先挑选字段再构造模型。`ChatResult` 可以用 `forbid`，因为它的字段由我们自己填充。

### 11.3 Literal 取值写错

错误信息会列出所有合法取值，照着改即可。这也是 `Literal` 相比 `str` 的调试优势。

### 11.4 pytest 找不到测试

确认 `tests/` 目录下有 `__init__.py` 或已配置 `testpaths = ["tests"]`；测试文件名必须以 `test_` 开头。

### 11.5 Protocol 没有被类型检查器识别

确认使用较新的 mypy/pyright；`from typing import Protocol`（而不是过时的 `typing_extensions` 路径）。本教程不强制配置 mypy，但建议在 IDE 里启用基础的类型检查。

## 12. 练习题与答案

### 练习 1：为何不能只靠 Prompt 要求正确 JSON？

**答案：**Prompt 是软约束——模型“通常”遵循，但没有任何机制保证。Schema 验证是可测试的运行时硬边界：非法输出必然被拦截，且拦截行为可以用测试证明。企业系统里，约束必须落在能被测试的位置。

### 练习 2：给 Tool 结果加入必填字段会怎样？

**答案：**所有还没升级的旧生产者会在构造时验证失败，通常是破坏性变更。正确顺序是：先加可选字段 → 升级全部生产者 → 确认数据完整 → 再收紧为必填。

### 练习 3：`extra="forbid"` 应该用在哪些模型上？

**答案：**用在“结构由我们定义、输入方是外部”的模型上：HTTP 请求体、工具入参、查询条件。作用是尽早暴露字段拼写错误和结构漂移。相反，对于“解析别人返回的结构”的中间模型，`forbid` 会让对方新增字段时直接崩掉，应该先在转换层显式挑字段。

### 练习 4：为什么 FakeGateway 放在 `src` 而不是 `tests`？

**答案：**它不只是测试工具，还是契约的活文档和一个可交付的离线运行模式（演示、CI、后续章节的重试实验都要用）。契约的替身与契约本身同生命周期，属于项目代码。

## 13. 工程挑战

在不联网的前提下完成：

1. 给 `ToolResult` 增加 `schema_version: int` 字段，默认值 1，保证第 8.4 节的既有测试全部保持绿色（练习“兼容性新增”）；
2. 给 `AlarmQuery` 增加 `since: datetime | None = None`（只看某时间之后的告警），并让 `tools.get_alarm` 尊重它；
3. 为 1 和 2 各补一个非法输入测试；
4. 写一个契约测试：同一份输入字典分别构造 `SearchManualInput`，合法时断言 `model_dump()` 往返一致。

参考方向：新增可选字段不动旧测试；`since` 与 `observed_at` 比较时注意时区统一（统一用 UTC）；往返测试用 `model_validate(payload.model_dump()) == payload`。

## 14. 面试追问

### 14.1 dataclass 和 Pydantic 怎么选？

回答框架：先问数据的信任来源。内部传递、自己构造的确定性数据用 dataclass（零开销）；凡是跨边界——HTTP、LLM 输出、外部服务、配置——用 Pydantic 做运行时校验。再加一句权衡：Pydantic 构造有校验成本，热路径上的内部对象不需要为它付费。

### 14.2 Protocol 相比继承的优势？

回答框架：结构化匹配不需要改第三方类的继承树；测试替身零成本接入；接口定义与实现解耦，适合“边界接口”。劣势是约束力弱于显式继承（忘了实现方法要到使用处才暴露），运行时检查能力有限。

### 14.3 契约测试怎么写？

回答框架：为接口写一组通用断言（返回结构合法、字段约束满足、流式顺序正确），用参数化把所有实现（真实网关、Fake、未来的新 Provider）跑同一组断言。契约测试防的是“换实现引入行为漂移”。

## 15. 本章复盘模板

完成后记录：

```text
完成日期：
实际投入小时：
8 个非法输入测试是否全部按预期失败：
网关重构后 main.py 是否零修改：
FakeGateway 测试数：
现在能否不看代码说出 dataclass 与 Pydantic 的分界：
现在能否解释 idempotency_key 为什么在第 2 周就出现：
仍不理解的问题：
```

## 16. 官方资料与中文阅读指引

### 16.1 Python 类型系统

- [Python typing](https://docs.python.org/3/library/typing.html)

重点阅读：`Protocol`、`Literal`、联合类型语法。不需要记忆整个页面，遇到不认识的标注回查即可。

### 16.2 Pydantic

- [Pydantic Models](https://docs.pydantic.dev/latest/concepts/models/)：字段、`model_config`、序列化与校验基础；
- [Pydantic Fields](https://docs.pydantic.dev/latest/concepts/fields/)：`Field` 的数值与字符串约束、默认值；
- [Pydantic Validators](https://docs.pydantic.dev/latest/concepts/validators/)：`@field_validator`、`@model_validator`——本章刻意没用到自定义校验器，需要“跨字段规则”时（如 `end > start`）再学。

### 16.3 pytest

- [pytest Getting Started](https://docs.pytest.org/en/stable/getting-started.html)

重点阅读：测试发现规则、`pytest.raises`。Fixture 与 `monkeypatch` 在本阶段第 5 章展开。

## 17. 下一章入口

本章结束时，网关是同步的：`chat()` 调用一次要阻塞几十秒，CLI 里无所谓，但两件事马上会逼我们转向异步：

1. 一次诊断需要**并发**调用 `get_alarm` 和 `search_manual`，串行等待会把延迟翻倍；
2. 第 1 章关闭的 SDK 自动重试，要按“错误分类 + 有限次数 + 指数退避 + 可观测”重新设计——这套 `ReliableInvoker` 天生是异步世界的构件。

下一章把网关迁移到 `AsyncOpenAI`，建立超时预算、并发信号量、有限重试和取消传播。那是第 1 章埋下的 `max_retries=0` 真正被偿还的地方。
