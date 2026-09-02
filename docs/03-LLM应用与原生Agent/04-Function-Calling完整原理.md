# Function Calling 完整原理

> 所属阶段：第 3 阶段（LLM 应用与原生 Agent），第 4 章
> 预计用时：7 小时
> 项目产出：`ToolRegistry` 工具执行层（注册 Schema / 执行函数 / 权限 / 超时 / 副作用等级）与失败路径测试
> 资料验证日期：2026-09-02

## 1. 本章从哪里开始

到第 3 章结束时，`agent-service` 已经有两样东西：一套能被校验的结构化输出契约，和三个"光杆"的内存工具。它们之间还缺一个关键的连接器——**工具执行层**。

| 对象 | 所在文件 | 状态 |
| --- | --- | --- |
| `ToolResult` 信封 | `schemas.py` | 已定义（`ok/code/data/retryable/observed_at`） |
| `SearchManualInput` / `GetAlarmInput` / `CreateWorkOrderDraftInput` | `schemas.py` | 已定义，均 `extra="forbid"` |
| `search_manual` / `get_alarm` / `create_work_order_draft` | `tools.py` | 内存实现，直接接收 Pydantic 入参 |
| `Diagnosis` / `RouteDecision` | 第 3 章 | 结构化输出契约已定义 |
| `ModelGateway` / `FakeGateway` | `gateway.py` / `fakes.py` | 网关接口与离线替身 |

第 3 章解决的是"模型输出的 JSON 怎么校验"。但模型输出还有一种更危险的形态：**它不只是输出一段结论，而是输出"请帮我调用某个工具"**。这时产生了一组第 3 章没有回答的问题：

1. 模型说"调用 `get_alarm`"，**谁来决定真的执行**？执行需要什么前提？
2. 模型编造一个不存在的工具名（比如 `close_alarm`），系统怎么拒绝？
3. 模型给 `create_work_order_draft` 多塞一个 `admin_bypass=True`，这个参数会被拦截吗？

本章用一个手写的 `ToolRegistry` 回答这三个问题。它把第 2 阶段 `tools.py` 里的三个内存工具包装成"带安全契约的、可被模型建议但必须经应用批准才执行"的能力。**模型只能建议，不能执行**——这句话是 Function Calling 全部安全边界的内核。

完成后你应该能回答：

1. 模型输出 `tool_calls` 与"系统真的执行了这个动作"之间，隔着哪几道检查？
2. 一个工具的描述要写清哪些内容，才能让模型"选对、不滥用"？
3. 只读、可逆写、高风险写、禁止，四级工具各自的兜底手段是什么？
4. 工具返回给模型的结果，为什么不能是数据库整行或异常堆栈？

## 2. 本章完成标准

必须同时满足：

- `ToolRegistry` 能 `register` 一条 `ToolSpec`，`to_tool_schemas()` 输出发给模型的工具 JSON Schema；
- `execute()` 在执行前拒绝：未知工具（`E_UNKNOWN_TOOL`）、额外参数（`E_INVALID_ARGUMENT`）、权限不足（`E_FORBIDDEN`）；
- 三个内存工具全部包装进默认注册表，且副作用等级标注正确（两个 `read`，一个 `reversible_write`）；
- 幂等写行为不退化：相同 `idempotency_key` 重复调用返回 `OK_DUPLICATE`，不建第二份草稿；
- 失败路径测试至少覆盖：未知工具、额外参数、权限不足、正常执行、幂等写五类；
- `uv run pytest` 全绿，本章真实 API 调用次数为 0。

## 3. Function Calling 的完整生命周期

### 3.1 心智模型：模型输出"意图"，不是"动作"

很多人第一次用 Function Calling 会有一个误解：以为模型"调用"了工具，工具就真的执行了。事实上，模型从头到尾**只做了一件事——生成文本**。它生成的一段文本恰好符合"工具调用"的结构（工具名 + JSON 参数），供应商 SDK 或我们的代码再把这段文本解析成一个 `tool_call` 对象。

从模型的角度看，它说"我想调用 `get_alarm`"和它说"建议检查地脚螺栓"，本质相同：都是预测下一个 Token。区别只在于，前者的输出被我们**约定**成了一种结构，代码据此去做一件真实世界里有副作用的事。

因此完整生命周期是：

```text
[用户消息 + 系统提示 + 工具 Schema 列表]
        │  (1) 组装请求：把注册表导出的工具 Schema 一并发给模型
        ▼
    [LLM]
        │  (2) 模型输出：finish_reason="tool_calls"
        │      tool_call{ name: "get_alarm", arguments: "{\"query\":{...}}" }
        ▼
 [应用解析 tool_call]
        │  (3) ToolRegistry.execute(name, raw_args, permissions)
        │      未知工具?    → E_UNKNOWN_TOOL
        │      额外参数?    → E_INVALID_ARGUMENT
        │      权限不足?    → E_FORBIDDEN
        │      校验失败?    → E_INVALID_ARGUMENT
        │      执行超时?    → E_TIMEOUT
        ▼
 [执行工具 → ToolResult]
        │  (4) 结果包成 tool message 回传给模型
        ▼
    [LLM]
        │  (5) 模型基于工具结果生成最终回答，或继续输出下一个 tool_call
        ▼
 [最终答案 → Schema + 业务规则校验 → 返回用户]
```

第 (2) 步模型只输出了一个**建议**；第 (3) 步才是系统真正"拥有权限"并决定是否执行的地方。第 (5) 步之后如果模型又输出工具调用，就回到第 (3) 步——这个循环会在第 5 章被扩展成完整的 Agent Loop，本章先把第 (3) 步这个"执行关卡"做扎实。

### 3.2 模型不会因为"说了要调用"就拥有权限

这是本章最重要的一句话：**模型生成工具调用，不等于系统自动执行；模型更不会因此获得任何系统权限。**

权限从哪来？从受信的身份系统来。蓝图第 3 节已经写明：维护工程师"只读设备信息，可创建草稿，不可直接批准高风险工单"；这份权限由业务服务签发，写进身份上下文，而不是由模型的一句话决定。模型输出 `tool_calls` 只提供了"想做什么"，"能不能做"必须由 `execute()` 里的确定性代码判断。

这意味着一个推理模型再聪明，也不能靠"它自己判断该不该派单"来替代审批。审批是一个 Human-in-the-loop 事件，需要关联用户身份、动作摘要、时间和幂等键；模型嘴里说出的"用户已同意"永远不是审批证据。

### 3.3 工具参数也是 LLM 输出，同样要过 Schema

`tool_call.arguments` 是一个 JSON 字符串，它**同样是模型生成的、概率性的、不可信的文本**。第 3 章"LLM 输出的校验与修复"在这里完整复用：`arguments` 先被 `json.loads` 解析，再被工具自己的 Input 模型（`SearchManualInput` 等）做 Pydantic 校验。语法合法 ≠ 业务合法——`severity="high"` 可能格式正确，却与证据矛盾，这类业务规则还要在上层（Agent Loop）继续校验。

结论：Function Calling 没有创造新的信任来源，它只是把"模型输出"从自由文本换成了"结构化的、附带动作语义的文本"。所有针对 LLM 输出的纪律——Schema 校验、业务规则、权限、重试上限——一条都不能少。

## 4. 工具描述：写给模型的"安全契约"

工具描述（`description`）是模型选择工具的唯一依据。它写得越含糊，模型越容易选错工具或编造参数。蓝图第 8.3 节列出的契约字段，落到底就是描述里要覆盖的这几个维度：

| 维度 | 回答的问题 | 反面例子 |
| --- | --- | --- |
| 用途 | 这个工具干什么 | "处理设备相关的事情" |
| 何时用 / 何时不用 | 什么场景选它、什么场景别选 | 不写边界，模型在"查设备"时也调用"建工单" |
| 参数单位与约束 | 每个参数是什么、取值区间 | 不写 `top_k` 上限，模型传 999 |
| 数据新鲜度 | 结果是实时还是静态、可能滞后 | 不提示手册是静态资料，模型把旧规程当现行规定 |
| 副作用 | 有没有写入、可不可撤销 | 不写"会建草稿"，模型误以为只读 |
| 可能错误 | 什么情况会失败、失败长什么样 | 不写"无告警返回空列表"，模型把空当错误 |

命名采用**动词 + 对象**：`search_manual`、`get_alarm`、`create_work_order_draft`。这比 `do_stuff`、`handle` 这类万能名更能让模型区分。更关键的反模式是**万能工具**：把"查设备、查告警、建工单、派单、关闭告警"塞进一个 `execute_action(action_type, ...)`，等于把选择权从模型手上抢回一个巨大的 `action_type` 枚举——模型选错一个字符串的后果无法被工具名这一层拦住。正确做法是拆成多个小而清晰的工具，让工具名本身就承担一层筛选。

下面是本章三个工具的真实描述：

```python
# src/agent_service/tool_registry.py
SEARCH_MANUAL_DESCRIPTION = (
    "检索设备维护手册，返回匹配的手册片段。"
    "用于回答检查步骤、故障排查、维护规程类问题。"
    "不要用于查询设备台账或历史告警（那属于其他工具）。"
    "参数 equipment_id 是设备编号（如 eq-pump-01）；keywords 是关键词列表（1~8 个）；top_k 是返回条数（1~10，默认 5）。"
    "数据新鲜度：手册为静态资料，可能滞后于现场工艺变更。"
    "副作用：无。可能错误：设备编号无对应手册时返回空结果而非报错。"
)

GET_ALARM_DESCRIPTION = (
    "查询设备的历史告警记录。"
    "用于需要结合告警信息判断故障时；不要用于检索手册或创建工单。"
    "参数 query.equipment_id 是设备编号；query.severity 可选，取值 low/medium/high，缺省返回全部级别。"
    "数据新鲜度：当前为内存假数据，接入真实数据源后以系统时间为准。"
    "副作用：无。可能错误：设备无告警时返回空列表而非报错。"
)

CREATE_DRAFT_DESCRIPTION = (
    "创建一条设备维护工单草稿（不提交、不派单）。"
    "用于把诊断结论落成可审批的草稿；不要用它直接派单或关闭告警（本项目不向模型暴露这些高风险能力）。"
    "参数 equipment_id 是设备编号；summary 是故障与建议摘要（1~2000 字）；severity 取值 low/medium/high；"
    "idempotency_key 是调用方生成的幂等键（8~64 位字母数字下划线连字符），相同键重复调用返回同一草稿。"
    "副作用：写入内存草稿库，可撤销、可审计。可能错误：幂等键格式非法会被拒绝。"
)
```

注意 `CREATE_DRAFT_DESCRIPTION` 里那句"不提交、不派单"——它既是给模型看的，也是给后续审计看的：任何绕过这条边界的调用，都能在描述里找到"本就不该发生"的对照。

## 5. 工具分级：只读 / 可逆写 / 高风险写 / 禁止

不是所有工具对模型"一视同仁"。按副作用的可逆程度分级，决定每一级用多重的控制手段：

| 级别 | 语义 | 本项目示例 | 控制手段 | 是否暴露给模型 |
| --- | --- | --- | --- | --- |
| `read` 只读 | 查询数据，不改变状态 | `search_manual`、`get_alarm` | 鉴权 + 限流 + 数据范围过滤 | 是 |
| `reversible_write` 可逆写 | 产生可撤销、可审计的中间产物 | `create_work_order_draft` | 幂等键 + 审计 + 可撤销 | 是 |
| `high_risk_write` 高风险写 | 影响真实业务状态 | 蓝图 §8.2 的 `submit_work_order`、`assign_work_order` | 确认 + 审批 + 最小权限 | 否（本阶段不注册） |
| `forbidden` 禁止 | 绕过安全联锁、控制真实设备 | 直接关闭告警、启停设备 | 不写实现、不进注册表 | 否 |

关键认知：**"只读"不等于"无风险"**。`get_alarm` 读的是某个设备的历史告警，如果权限不做数据范围过滤，一个低权限用户可能读到别的工厂的资产状态。所以只读工具同样要鉴权、限流、按租户/设备过滤数据范围——这在蓝图第 14 节"读取和写入权限分离""多租户检索在检索前过滤"里反复强调。

四级里，本章真正 `register` 的只有前两级（三个工具）。第三、四级在当前阶段**连 fn 实现都不进注册表**：模型即使"建议"调用 `submit_work_order`，`execute()` 也会因为查不到这个名字而返回 `E_UNKNOWN_TOOL`。**不暴露，是最强的一层权限控制。**

## 6. ToolSpec：一条工具的完整安全契约

先定义"一条工具"在注册表里的形态。这里刻意用了 `@dataclass(frozen=True)` 而不是 Pydantic——沿用第 2 阶段第 2 章的判断：`ToolSpec` 是我们自己定义、自己填充的内部对象，完全可信，dataclass 零校验开销；而它的 `input_schema` 是模型的边界数据，必须是 Pydantic 模型：

```python
# src/agent_service/tool_registry.py
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Literal

from pydantic import BaseModel, ValidationError

from agent_service.schemas import ToolResult

SideEffectLevel = Literal["read", "reversible_write", "high_risk_write"]

# 工具执行线程池：只保证调用方不再等待，无法强制终止线程（见 §8 的说明）。
_EXECUTOR = ThreadPoolExecutor(max_workers=4, thread_name_prefix="tool-")


class _ToolTimeout(Exception):
    """工具执行超过 spec.timeout_seconds 的受控信号。"""


@dataclass(frozen=True)
class ToolSpec:
    """一条工具在注册表里的完整安全契约。"""

    name: str
    description: str
    input_schema: type[BaseModel]
    fn: Callable[[Any], ToolResult]
    side_effect: SideEffectLevel
    required_permission: str | None = None
    timeout_seconds: float = 5.0


def _result(ok: bool, code: str, data: dict[str, Any], retryable: bool = False) -> ToolResult:
    """构造统一的 ToolResult，错误码严格用 E_* 前缀。"""
    return ToolResult(
        ok=ok,
        code=code,
        data=data,
        retryable=retryable,
        observed_at=datetime.now(timezone.utc),
    )


def _run_with_timeout(fn: Callable[[Any], ToolResult], payload: BaseModel, timeout_seconds: float) -> ToolResult:
    future = _EXECUTOR.submit(fn, payload)
    try:
        return future.result(timeout=timeout_seconds)
    except FutureTimeout:
        future.cancel()
        raise _ToolTimeout from None
```

`ToolSpec` 的六个字段各司其职：

- `name`：工具名，动词 + 对象，同时是模型输出的 `tool_call.name`；
- `description`：写给模型的安全契约（§4）；
- `input_schema`：Pydantic 输入模型，它的 `model_json_schema()` 直接导出给模型，也用于执行前校验；
- `fn`：真正的执行函数，签名是 `(InputModel) -> ToolResult`；
- `side_effect`：副作用等级，`Literal` 限定了只有三个合法取值；
- `required_permission`：执行所需的权限点，`None` 表示无需鉴权（本项目三个工具都显式声明了权限）；
- `timeout_seconds`：单次执行预算，超时返回 `E_TIMEOUT`。

`_result` 是本章的错误码出口，所有错误都走它：`code` 满足 `^[A-Z][A-Z0-9_]*$`（`ToolResult` 里的正则已经锁死），`retryable` 标记是否值得立刻重试。

## 7. ToolRegistry：注册与执行

注册表本身是一个普通类。它不引入任何框架——`LangChain` 的 Tool、`OpenAI` 的 function 协议，以后都能在它外面套一层适配器；本章先用最直白的形式把"关卡"立起来：

```python
# src/agent_service/tool_registry.py（续）
class ToolRegistry:
    """工具执行层：模型只能"建议"调用，真正执行必须经过这里。"""

    def __init__(self) -> None:
        self._specs: dict[str, ToolSpec] = {}

    def register(self, spec: ToolSpec) -> None:
        if spec.name in self._specs:
            raise ValueError(f"工具重复注册: {spec.name}")
        self._specs[spec.name] = spec

    def has(self, name: str) -> bool:
        return name in self._specs

    def get(self, name: str) -> ToolSpec | None:
        """供调用方（如 Agent Loop）在执行前读取 spec 的 side_effect / required_permission。"""
        return self._specs.get(name)

    def names(self) -> list[str]:
        return list(self._specs)

    def to_tool_schemas(self) -> list[dict[str, Any]]:
        """把注册表导出为发给模型的工具 Schema 列表。"""
        return [
            {
                "type": "function",
                "function": {
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": spec.input_schema.model_json_schema(),
                },
            }
            for spec in self._specs.values()
        ]

    def execute(
        self,
        name: str,
        raw_args: dict[str, Any],
        *,
        permissions: frozenset[str],
    ) -> ToolResult:
        spec = self._specs.get(name)
        if spec is None:
            return _result(False, "E_UNKNOWN_TOOL", {"tool": name, "available": self.names()})

        if spec.required_permission is not None and spec.required_permission not in permissions:
            return _result(False, "E_FORBIDDEN", {"tool": name, "required_permission": spec.required_permission})

        unknown = [key for key in raw_args if key not in spec.input_schema.model_fields]
        if unknown:
            return _result(False, "E_INVALID_ARGUMENT", {"tool": name, "unexpected_keys": unknown})

        try:
            payload = spec.input_schema.model_validate(raw_args)
        except ValidationError as exc:
            return _result(
                False,
                "E_INVALID_ARGUMENT",
                {"tool": name, "safe_message": "参数校验失败", "errors": exc.errors()},
            )

        try:
            return _run_with_timeout(spec.fn, payload, spec.timeout_seconds)
        except _ToolTimeout:
            return _result(False, "E_TIMEOUT", {"tool": name, "safe_message": "工具执行超时"}, retryable=True)
        except Exception:
            return _result(False, "E_TOOL_EXECUTION_FAILED", {"tool": name, "safe_message": "工具执行失败"}, retryable=True)
```

`execute()` 的检查顺序是**有意设计的**：先查工具存不存在（`E_UNKNOWN_TOOL`），再查权限（`E_FORBIDDEN`），再查额外参数（`E_INVALID_ARGUMENT`），然后才是 Pydantic 校验和真正执行。顺序的优先级是：**身份与存在性 > 结构与参数 > 执行**。未知工具和越权必须在参数解析之前挡掉——这两类错误的性质更严重，且不该消耗任何解析成本。

最后把三个内存工具装进默认注册表：

```python
# src/agent_service/tool_registry.py（续）
from agent_service import tools as memory_tools
from agent_service.schemas import CreateWorkOrderDraftInput, GetAlarmInput, SearchManualInput


def build_default_registry() -> ToolRegistry:
    registry = ToolRegistry()
    registry.register(ToolSpec(
        name="search_manual",
        description=SEARCH_MANUAL_DESCRIPTION,
        input_schema=SearchManualInput,
        fn=memory_tools.search_manual,
        side_effect="read",
        required_permission="manual:read",
        timeout_seconds=5.0,
    ))
    registry.register(ToolSpec(
        name="get_alarm",
        description=GET_ALARM_DESCRIPTION,
        input_schema=GetAlarmInput,
        fn=memory_tools.get_alarm,
        side_effect="read",
        required_permission="alarm:read",
        timeout_seconds=5.0,
    ))
    registry.register(ToolSpec(
        name="create_work_order_draft",
        description=CREATE_DRAFT_DESCRIPTION,
        input_schema=CreateWorkOrderDraftInput,
        fn=memory_tools.create_work_order_draft,
        side_effect="reversible_write",
        required_permission="workorder:draft:create",
        timeout_seconds=10.0,
    ))
    return registry
```

注意三点：

1. `fn` 直接指向第 2 阶段 `tools.py` 里的内存函数——**没有重写业务逻辑**，只是给它们套上了安全契约；
2. `create_work_order_draft` 的超时给到 10 秒，比只读工具宽松——写操作天然更慢，且它的幂等行为已经由 `tools.py` 保证；
3. 三个工具的 `required_permission` 是三个不同的权限点，粒度到"哪个工具、哪个域"（`manual:read` / `alarm:read` / `workorder:draft:create`），而不是一个笼统的 `read` 或 `write`。

## 8. 执行前校验与失败路径

### 8.1 失败路径一：模型编造未知工具

模型输出了 `tool_call.name = "close_alarm"`。`close_alarm` 从来不在注册表里，`execute()` 第一行 `self._specs.get(name)` 返回 `None`，直接返回 `E_UNKNOWN_TOOL`。**没有任何 fn 被执行，没有任何副作用发生。**

### 8.2 失败路径二：额外参数被拦截

模型给 `search_manual` 塞了一个 `admin_bypass: True`。`SearchManualInput.model_fields` 里只有 `equipment_id/keywords/top_k`，`unknown` 列表非空，返回 `E_INVALID_ARGUMENT`，`data` 里带上 `unexpected_keys: ["admin_bypass"]`。这里做了两层防护：注册表层显式比对字段名，`extra="forbid"` 的 Pydantic 模型是第二道防线——即使有人绕过第一层，`model_validate` 也会拒绝未知字段。

### 8.3 失败路径三：权限不足

模型建议调用 `create_work_order_draft`，但当前用户权限集合里没有 `workorder:draft:create`。`execute()` 返回 `E_FORBIDDEN`，且**不执行**。权限判断是确定性代码，不是 Prompt 里写一句"你没有权限"——蓝图第 3 节末尾那句话在这里变成了一行可测试的代码。

### 8.4 失败路径四：超时与线程的真相

`_run_with_timeout` 用 `ThreadPoolExecutor` 把执行放进工作线程，主线程 `future.result(timeout=...)` 等不到结果就抛 `_ToolTimeout`，`execute()` 返回 `E_TIMEOUT`（`retryable=True`）。但这里有一个必须说破的工程真相：**Python 线程无法被强制杀死**。`future.cancel()` 只对还没开始运行的任务有效；一个已经卡死在阻塞调用里的线程，会一直在池子里占着。所以超时保证的是"调用方不再等待、上层能拿到受控错误码"，**不保证**"副作用一定没发生"。真正可控的取消要等到协程（async）或进程隔离；对写操作，这条尤其重要——第 5 章的 Agent Loop 会依赖幂等键来兜"超时了但草稿其实已经建了"的情况。

### 8.5 用测试钉死这些失败路径

```python
# tests/test_tool_registry.py
from agent_service.tool_registry import build_default_registry

FULL_PERMISSIONS = frozenset({"manual:read", "alarm:read", "workorder:draft:create"})
READ_ONLY_PERMISSIONS = frozenset({"manual:read", "alarm:read"})


def test_unknown_tool_rejected() -> None:
    registry = build_default_registry()
    result = registry.execute("close_alarm", {}, permissions=FULL_PERMISSIONS)
    assert result.ok is False
    assert result.code == "E_UNKNOWN_TOOL"


def test_extra_arguments_rejected() -> None:
    registry = build_default_registry()
    result = registry.execute(
        "search_manual",
        {"equipment_id": "eq-pump-01", "keywords": ["振动"], "top_k": 5, "admin_bypass": True},
        permissions=FULL_PERMISSIONS,
    )
    assert result.ok is False
    assert result.code == "E_INVALID_ARGUMENT"
    assert "admin_bypass" in result.data["unexpected_keys"]


def test_permission_denied_for_write_tool() -> None:
    registry = build_default_registry()
    result = registry.execute(
        "create_work_order_draft",
        {
            "equipment_id": "eq-pump-01",
            "summary": "更换密封件",
            "severity": "high",
            "idempotency_key": "wo-2026-0001",
        },
        permissions=READ_ONLY_PERMISSIONS,
    )
    assert result.ok is False
    assert result.code == "E_FORBIDDEN"


def test_valid_read_tool_executes() -> None:
    registry = build_default_registry()
    result = registry.execute(
        "get_alarm",
        {"query": {"equipment_id": "eq-pump-01"}},
        permissions=FULL_PERMISSIONS,
    )
    assert result.ok is True
    assert result.code == "OK"


def test_idempotent_draft_creation() -> None:
    registry = build_default_registry()
    args = {
        "equipment_id": "eq-pump-01",
        "summary": "更换密封件",
        "severity": "high",
        "idempotency_key": "wo-2026-0001",
    }
    first = registry.execute("create_work_order_draft", args, permissions=FULL_PERMISSIONS)
    second = registry.execute("create_work_order_draft", args, permissions=FULL_PERMISSIONS)
    assert first.code == "OK"
    assert second.code == "OK_DUPLICATE"
    assert first.data["draft"]["draft_id"] == second.data["draft"]["draft_id"]
```

这组测试没有一次真实 API 调用：`FakeGateway` 不在，模型也不在，被测试的只有"执行关卡"本身。这正是把安全边界放在确定性代码里的意义——**它能被自动化测试覆盖，而不依赖某个模型这次有没有抽对**。

## 9. 返回结果：小而稳定，错误结构化

### 9.1 不要把数据库整行喂回模型

工具执行成功后的返回，会被包成 tool message 回传给模型。回传的内容必须**小、稳定、只含任务需要的字段**：

- 不要返回数据库整行（含内部主键、创建人、审计字段）；
- 不要返回没被裁剪的检索原文全文（那是 RAG 阶段用引用 ID 解决的问题）；
- 不要返回任何内部标识、密钥、堆栈。

本项目三个工具返回的都是 `ToolResult.data` 里的序列化输出——`SearchManualOutput`、`GetAlarmOutput`、`CreateWorkOrderDraftOutput`，字段由第 2 阶段的契约精确控制。`ManualSnippet.excerpt` 有 1000 字上限，`top_k` 有 10 条上限，这些约束在源头就把"喂回模型的体积"限制住了。

### 9.2 错误也要结构化：code / retryable / safe_message

工具失败时，最忌讳两件事：把异常堆栈原样塞进结果，以及返回一个"失败了但不知道为何、能不能重试"的模糊字符串。本章统一成三要素：

| 字段 | 含义 | 落点 |
| --- | --- | --- |
| `code` | 稳定机器码（`E_UNKNOWN_TOOL` 等） | `ToolResult.code`，供上层逻辑分支 |
| `retryable` | 是否值得立刻重试 | `ToolResult.retryable` |
| `safe_message` | 给模型/用户看的、不含堆栈与内部细节的错误说明 | 约定放在 `ToolResult.data` 里 |

`ToolResult` 契约本身只有 `code/retryable`（外加 `ok/data/observed_at`），`safe_message` 是本章在 `data` 里建立的**约定**：`data = {"safe_message": "...", ...}`。原始异常（`except Exception:` 捕获的那个）**永不出现在 `data` 里**——它可能携带数据库连接串、内部路径等敏感信息，只该进服务端日志。

`retryable` 的取值逻辑：`E_TIMEOUT`、`E_TOOL_EXECUTION_FAILED` 标记 `True`（瞬时错误，值得重试）；`E_UNKNOWN_TOOL`、`E_INVALID_ARGUMENT`、`E_FORBIDDEN` 标记 `False`（重试一万次也不会变好）。这个标记直接喂给第 2 阶段第 5 章的 `ReliableInvoker`，以及第 5 章 Agent Loop 的停止条件。

## 10. 与下一章 Agent Loop 的接口约定

`ToolRegistry.execute()` 的签名，就是第 5 章"手写 Agent Loop"里循环体要调用的那一个动作：

```text
Agent Loop 伪代码（第 5 章展开）
    tool_call = 模型输出
    result = registry.execute(tool_call.name, tool_call.arguments, permissions=ctx.permissions)
    messages.append(tool_message(result))   # result 已是被裁剪过的 ToolResult
    # 若 result.ok 为 False，由 loop 决定：反馈给模型重试、还是进入受控失败
```

因此本章为下一章交付了三样东西：

1. **一个可调用的执行函数**：`execute(name, raw_args, permissions) -> ToolResult`，失败时返回 `E_*` 而不是抛异常——loop 不用 try/except 包一层，看 `result.ok` 和 `result.code` 就能分支；
2. **一个可导出的 Schema 列表**：`to_tool_schemas()` 给 loop 的第一次模型调用提供工具清单；
3. **一套可观测的边界**：`execute()` 是 `tool.started` / `tool.completed` / `tool.failed` 这三个 SSE 事件的天然发射点（蓝图第 11 节），敏感返回值在服务端摘要后经 SSE 暴露，不把完整 `data` 推给前端。

本章刻意没有引入 LangChain / LangGraph。第 5 章会先用纯 Python 把 loop 手写一遍，理解框架替你做了什么；到 M2（蓝图第 16 节）再把这个 `ToolRegistry` 套一层 LangChain Tool 适配器。工具执行层保持框架无关，是它能被两个阶段复用的前提。

## 项目任务

在第 3 章代码基础上完成：

1. 新建 `src/agent_service/tool_registry.py`：`SideEffectLevel`、`ToolSpec`、`ToolRegistry`、`build_default_registry` 四个要素齐全；
2. 用 `build_default_registry()` 包装第 2 阶段 `tools.py` 的三个内存工具，副作用与权限标注正确；
3. 写 `tests/test_tool_registry.py`，至少覆盖 §8.5 的五个失败/成功路径；
4. 补一个超时测试：注册一个 `time.sleep` 的慢工具，断言返回 `E_TIMEOUT` 且 `retryable is True`；
5. 全程 `uv run pytest` 保持绿色，第 2 阶段既有测试不被破坏，真实 API 调用次数为 0。

## 常见错误与诊断顺序

### 模型编造未知工具名

现象：`execute()` 返回 `E_UNKNOWN_TOOL`，但你以为自己注册过这个工具。按顺序检查：工具名是否真的 `register` 了；`to_tool_schemas()` 导出给模型的名字是否与注册名一致（一个字母之差都不行）；是否把"想让模型做的事"写进了 Prompt 但没写进注册表——Prompt 里的动词不是工具，注册表里的才是。

### 额外参数没有被拦截

现象：`E_INVALID_ARGUMENT` 没触发，非法参数"漏"进去了。根因通常有两个：输入模型没设 `extra="forbid"`（静默忽略未知字段），或者校验放到了工具函数内部而不是入口。第 2 阶段契约已统一 `extra="forbid"`，本章的显式 `unknown` 检查是第二道保险——两道都在入口，不要等业务逻辑跑到一半才报错。

### 把权限判断写在 Prompt 里

现象：`system` 提示里写"你没有权限执行该操作"，代码却直接执行。这是最危险的错误——Prompt 是软约束，模型可以被注入、被诱导说"用户已授权"。权限必须落在 `execute()` 的 `E_FORBIDDEN` 分支，且不依赖任何模型输出。

### 把异常堆栈塞进返回结果

现象：工具抛异常，直接把 `str(exc)` 或 `traceback` 放进 `data` 回传。这会泄漏内部路径、连接串、表结构。诊断顺序：先确认 `except Exception` 分支是否统一走 `_result`，再确认 `data` 里只有 `safe_message` 这类裁剪过的文案，堆栈只进服务端日志。

### 超时了但副作用仍发生了

现象：`E_TIMEOUT` 返回后，发现草稿其实已经建了。这不是 bug，是 Python 线程无法强杀的必然结果（§8.4）。正确姿态：写操作必须携带幂等键，让"重试/重复"无害；`E_TIMEOUT` 时上层不要盲目重试写操作，而是用幂等键去重后确认。

## 练习题与答案

### 练习 1：模型输出 `tool_calls` 后，系统是否自动执行了该工具？

**答案：**没有。模型只生成了"想调用某工具"的结构化文本，它不拥有执行权限。真正的执行必须经过 `ToolRegistry.execute()` 的确定性检查：工具存在性、权限、参数、超时、副作用等级。模型生成工具调用只是"建议"，应用才是"决策者"。

### 练习 2：`E_UNKNOWN_TOOL` 和 `E_INVALID_ARGUMENT` 为什么必须是两个不同的错误码？

**答案：**两者性质与处理方式完全不同。未知工具意味着模型臆造了不存在的能力，属于幻觉第 4 类（工具臆造），应停止并把错误反馈给模型；参数非法意味着工具选对了但参数错了，可以有限地让模型修参数。用不同 `code` 才能让上层 Agent Loop 做出不同的分支决策，且 `retryable` 取值也不同。

### 练习 3：查设备（只读）工具为什么也要鉴权？

**答案：**只读不等于无风险。`get_alarm` 可能读到其他租户、其他工厂的设备状态，造成越权信息泄露。所以只读工具同样要鉴权、限流、按数据范围过滤。权限来自受信身份系统，不来自模型或用户的一句话。

### 练习 4：模型说"用户已经在界面上同意派单"，能否作为审批依据？

**答案：**不能。审批必须是一个可信的 Human-in-the-loop 事件，来自 UI/API，关联用户身份、动作摘要、时间和幂等键。模型输出里的任何"用户已同意"陈述都只是文本，不是审批证据，必须被 `E_FORBIDDEN` 或审批门挡住。

## 工程挑战

1. 给 `ToolRegistry` 增加**限流**：为 `read` 工具加"每分钟调用上限"，超限返回 `E_RATE_LIMITED`（`retryable=True`），用一个可注入的时钟测试它；
2. 给 `to_tool_schemas()` 增加 `filter_by_permissions(permissions)`：只导出当前用户有权使用的工具 Schema——没权限的工具连 Schema 都不发给模型，从源头缩小臆造空间；
3. 用 `FakeGateway` 写一个测试：模拟模型"请求调用 `close_alarm`"，断言 `execute()` 返回 `E_UNKNOWN_TOOL`，且断言没有任何副作用函数被调用；
4. 为超时路径补测试：注册一个 `time.sleep` 的慢工具，断言 `E_TIMEOUT` 且 `retryable is True`，并写清楚"线程无法强杀"这一限制的注释。

参考方向：限流用一个"当前时间 + 调用计数"的内存结构即可，别引入外部存储；`filter_by_permissions` 复用 `required_permission in permissions` 的同一判断，保持单一事实来源。

## 面试追问

### "Function Calling 里，模型会不会直接调用你的系统？"

回答框架：不会。模型只生成"调用建议"（工具名 + 参数 JSON），真正的执行经过 `ToolRegistry.execute()`：先验工具存在性，再验权限，再验参数与超时，最后才执行。模型的输出永远是文本，权限和能力来自受信身份系统与确定性代码。

### "只读工具为什么还要鉴权和限流？"

回答框架：只读≠无风险。跨租户/跨工厂的越权读取同样敏感，且无限制的只读调用也能拖垮下游。所以 read 工具同样有 `required_permission`、数据范围过滤和限流。工具分级不是"读就随便、写才管"，而是每级都有对应的最小控制集。

### "工具返回结果你会直接喂回模型吗？"

回答框架：不会。返回结果要裁剪成小而稳定的结构（只含任务需要的字段），错误要结构化（`code/retryable/safe_message`）。数据库整行、检索全文、异常堆栈都不回传——前者浪费窗口且稀释注意力，后者泄漏内部信息。引用用 ID 而非全文，是第 5 阶段 RAG 的契约方向。

## 本章复盘模板

完成后记录：

```text
完成日期：
实际投入小时：
ToolRegistry 是否能拒绝未知工具 / 额外参数 / 越权：
三个工具副作用等级是否标注正确：
幂等写是否通过相同 idempotency_key 不重复建单：
失败路径测试是否覆盖 5 类（未知/额外/越权/正常/幂等）：
能否一句话说清"模型建议调用"与"系统执行"的边界：
是否理解 Python 线程无法强杀对超时语义的影响：
仍不理解的问题：
```

## 官方资料与中文阅读指引

- [OpenAI Function Calling 概念](https://developers.openai.com/api/docs/guides/function-calling)：官方对 tool call 生命周期（`tool_calls`、`tool` message、`finish_reason`）的定义；
- [LangChain Tools](https://docs.langchain.com/oss/python/langchain/tools)：框架层如何包装工具、如何做工具调用；本章先手写，到 M2 再对照框架做适配；
- [Pydantic JSON Schema](https://docs.pydantic.dev/latest/concepts/json_schema/)：`model_json_schema()` 的输出结构，也就是 `to_tool_schemas()` 里 `parameters` 字段的来源。

重点阅读：OpenAI 文档里 `tool_calls` 与 `tool` 消息的字段结构，以及参数校验失败后"把错误反馈给模型"的官方建议——它会和下一章 Agent Loop 的重试上限衔接。

## 下一章入口

本章交付的是一个"有安全关卡的工具执行层"：模型建议、注册表拦截、权限与副作用分级、失败返回 `E_*` 错误码。但它还缺一个把这一切串起来的**循环**——谁负责第一次组装消息、谁负责把工具结果回传、谁负责在"继续调用"和"生成最终回答"之间做决定、谁负责在步数/Token/时间超限时停下。

下一章《手写 Agent Loop》回答的正是这些：用纯 Python 写一个不依赖框架的最小循环，调用本章的 `registry.execute()`，在最多 6 步内完成"查告警 / 搜手册 / 建草稿"的设备维护任务，并精确模拟直接回答、单工具、多工具、未知工具、循环、超时六类轨迹。
