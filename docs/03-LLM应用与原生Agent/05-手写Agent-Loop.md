# 手写 Agent Loop

> 所属阶段：第 3 阶段（LLM 应用与原生 Agent），第 6 周
> 预计用时：8 小时
> 项目产出：`agent/loop.py`（有界 ReAct 循环）、`ScriptedGateway`（脚本模型）、六种轨迹的自动化测试
> 资料验证日期：2026-09-02

## 1. 本章从哪里开始

第 3 阶段第 4 章结束时，`agent-service` 已经把"模型建议调用工具"和"系统真正执行工具"之间的边界立起来了：

| 对象 | 所在文件 | 作用 |
| --- | --- | --- |
| `ChatResult` / `ToolResult` | `schemas.py` | 结果信封：`ToolResult` 用 `ok/code/data/retryable/observed_at` 约束工具结果 |
| `ModelGateway` | `gateway.py` | 业务代码依赖的 `chat` / `stream_chat` 接口 |
| `search_manual` / `get_alarm` / `create_work_order_draft` | `tools.py` | 三个内存工具（两个只读、一个可逆写） |
| `ToolRegistry` / `ToolSpec` | `tool_registry.py` | 注册 Schema/执行函数/权限/超时/副作用等级，拒绝未知工具和额外参数 |
| `Diagnosis` | `schemas.py` | `summary/severity/evidence_ids/requires_human` 的结构化诊断契约 |

这些对象解决的是**单次交互**的问题：一次模型调用、一次工具校验、一次工具执行。但它们还没有被串成一个**循环**——模型调用工具后要拿到结果、继续推理、可能再调用工具，直到给出最终答案或进入受控停止。这一"循环"正是 Agent 与普通 Workflow 的本质区别：

- Workflow 的路径由代码**预先决定**（A 之后必然 B）；
- Agent 让模型在**受限边界内动态选择下一步动作**（A 之后可能是 B、C 或直接回答）。

框架（LangChain/LangGraph）的价值在于把这个循环里大量样板代码替你写好。但如果不先手写一遍，你无法分辨"框架替你做了什么"和"框架替你承担了什么边界"。本章就用 `agent/loop.py` 一个文件，把最小 ReAct 循环写透。

完成后你应该能回答：

1. 为什么"循环"是 Agent 与 Workflow 的分界？框架在 Loop 里替你做了哪几件事？
2. 停止条件为什么必须全部落在确定性代码里，而不是交给模型自觉？
3. 循环检测为什么要"相同工具 + 规范化参数"，而不是只比较工具名？
4. 费用为什么只做 Usage 记录与告警，不拿累计金额终止正常学习？

## 2. 本章完成标准

必须同时满足：

- `agent/loop.py` 实现有界 ReAct 循环，`max_steps` / `deadline_seconds` / `max_total_tokens` 全部显式可配置；
- 循环检测用"相同工具 + 规范化参数"连续出现判定，触发后进入 `loop_detected` 受控终态；
- 每一步都产出 `StepRecord`，含 `step_id` / 输入摘要 / 选择 / 结果 / 耗时 / 费用；
- 最终答案只能引用本轮工具返回的可见证据 ID，引用不可见证据进入 `E_UNREFERENCED_EVIDENCE` 失败终态；
- 用 `ScriptedGateway` 精确复现"直接回答 / 一次工具 / 多工具 / 未知工具 / 循环 / 超时"六种轨迹；
- `uv run pytest` 全绿，六轨迹测试全部断言到终态（`status` + `stop_reason`），真实 API 调用次数为 0。

## 3. 心智模型：ReAct 循环与"框架替你做了什么"

### 3.1 一句话理解 ReAct

ReAct（Reasoning + Acting）的本质是把"想"和"做"交替进行：模型读上下文 → 决定下一步动作（回答 or 调工具）→ 系统执行工具并把结果回填 → 模型再读 → 再决定。循环本身不神秘，神秘的是**谁在约束这个循环不失控**。

框架替你做的五件事，手写时你都要自己负责：

| 框架替你做的 | 手写时落在哪 |
| --- | --- |
| 组装 messages（system/user/tool） | `run()` 里的 `messages` 列表 |
| 解析模型输出（文本 → 结构化动作） | `AgentTurn` + `_parse_turn` |
| 校验/授权/执行工具并回填结果 | `ToolRegistry.resolve/execute` + 授权检查 |
| 判定停止（步数/时间/Token/循环） | `ExecutionLimits` + `while` 里的检查 |
| 记录轨迹（可观测/可审计） | `StepRecord` + `LoopOutcome` |

### 3.2 循环伪代码

```text
初始化 messages = [system, user]
step = 0，total_tokens = 0，started = now
while True:
    if 超步数 or 超期限 or 超 Token: 停止并说明
    调模型 complete(messages)
    解析输出 → AgentTurn（Schema 硬校验，失败即受控失败）
    if kind == "final_answer":
        校验 evidence_ids ⊆ 本轮可见证据 → 返回
    if kind == "tool_call":
        循环检测（相同工具 + 规范化参数连续出现）→ 停止
        registry.resolve 校验未知工具/额外参数/Schema → 失败即受控失败
        授权：权限 ⊆ 当前权限集，否则 E_FORBIDDEN
        授权：副作用等级 = 高风险写，否则进入 awaiting_approval
        registry.execute → ToolResult
        ToolResult.ok == False → 受控失败
        截断过大结果 + 收集证据 ID + 追加 Tool Message
        step += 1
```

注意两个刻意之处：

1. **停止检查在循环顶部**。这样哪怕某一步执行完发现超步数，下一次进循环也必然被拦下，不会出现"多跑一步"的越界。
2. **失败不重试**。模型输出无效、工具失败都直接进入受控终态，而不是在 Loop 里自动重试——自动重试是费用黑洞（第 2 阶段第 2 章的 `max_retries=0` 已经埋过这个伏笔）。有限的"修复重试"属于第 3 章 Structured Output 的范畴，本章 Loop 只做"校验 → 失败 → 终态"。

### 3.3 停止条件全集

停止条件必须覆盖八类，缺一不可，且**全部落在确定性代码里**：

| 停止条件 | 触发位置 | 终态 |
| --- | --- | --- |
| 最终答案 | 模型输出 `final_answer` 且通过引用校验 | `completed/final_answer` |
| 最大步数 | `len(steps) >= max_steps` | `stopped/max_steps` |
| 总期限 | `elapsed >= deadline_seconds` | `stopped/deadline` |
| Token 上限 | `total_tokens >= max_total_tokens` | `stopped/token_limit` |
| 连续相同工具调用 | 规范化参数哈希连续出现 N 次 | `stopped/loop_detected` |
| 用户取消 | 外部取消信号（本章预留接口） | `stopped/cancelled` |
| 不可恢复错误 | 模型输出无效 / 未知工具 / 越权 / 工具失败 | `failed/unrecoverable_error` |
| 等待人工批准 | 高风险写工具被模型选中 | `stopped/awaiting_approval` |

费用**不在这张表里**。费用只做 Usage 记录 + 异常增长告警，不以累计金额终止正常学习调用——一个"多花几分钱但能学到东西"的调用不应该被硬性砍掉，但异常增长（单次 run 费用超过阈值）必须留下可告警的标记。这条在 `ExecutionLimits.max_run_cost_cny` 和 `LoopOutcome.cost_alert` 里落地。

## 4. 执行上限：先有边界，再有智能

执行上限是 Loop 的第一道防线。它必须是**数据**而不是散落在代码里的魔法数字：

```python
@dataclass(frozen=True)
class ExecutionLimits:
    """执行上限：全部显式可配置，缺省为学习场景的安全值。"""

    max_steps: int = 6                 # 最多 6 步（任务要求）
    deadline_seconds: float = 30.0     # 总期限
    max_total_tokens: int = 16_000     # 累计 Token 上限
    max_tool_result_chars: int = 2_000 # 工具结果回传的最大字符数
    max_repeated_tool_calls: int = 3   # 相同工具+相同参数连续出现的容忍次数
    max_run_cost_cny: float = 0.50     # 单次 run 的费用告警阈值（不终止，只告警）
```

为什么用 `frozen=True` 的 dataclass 而不是散落常量：上限是"配置"，不同环境（测试 / 学习 / 生产）要能注入不同值，而一旦进入一次 run 就不该被中途篡改。测试里把 `deadline_seconds` 设成极小值就能精确触发超时，把 `max_repeated_tool_calls` 设成 3 就能复现循环检测——**边界可注入，是边界可测试的前提**。

费用口径：只记录、只告警、不终止。`total_cost` 是累加的 Usage 观测值，`cost_alert` 只是一个布尔标记，供上层（第 5 阶段的费用观测）决定要不要告警。这样"防失控"防的是**行为和资源**（步数、时间、Token、重复调用），而不是"防花钱"——它们是两个不同的工程目标。

## 5. 可观测：StepRecord 与 LoopOutcome

蓝图第 10 节要求 Agent 状态可审计：不记录隐秘思维链，只记录**可审计的动作 + 简短决策原因**。每一步落一条 `StepRecord`：

```python
@dataclass
class StepRecord:
    """一次动作的可观测记录：输入摘要 / 选择 / 结果 / 耗时 / 费用。"""

    step_id: str
    step_no: int
    input_summary: str        # 本轮看到的最后一条消息摘要（截断）
    decision: str             # "final_answer" 或 "tool_call:<name>"
    tool_name: str | None
    normalized_args: str | None  # 规范化参数的哈希，用于循环检测与审计去重
    result_summary: str       # 结果摘要或错误码
    elapsed_ms: int
    input_tokens: int
    output_tokens: int
    cost_cny: float
```

`StepRecord` 里**没有** `model_raw_output`、没有思维链、没有完整工具返回。它是"审计摘要"，不是"调试快照"。要复现行为，靠的是 `step_id` 关联的输入版本、工具选择、参数哈希、状态转移和简短 `reason`，而不是靠模型那段私密推理过程。这对应蓝图第 2.2 节"不暴露模型私密推理过程"和第 10 节"副作用工具执行 ID 必须持久化"。

一次 run 的终态用 `LoopOutcome` 表达，**永远有明确的 status 和 stop_reason**：

```python
StopReason = Literal[
    "final_answer", "max_steps", "deadline", "token_limit",
    "loop_detected", "cancelled", "unrecoverable_error", "awaiting_approval",
]

@dataclass
class LoopOutcome:
    """一次 run 的终态：永远有明确的 status 与 stop_reason。"""

    status: Literal["completed", "stopped", "failed"]
    stop_reason: StopReason
    final_answer: str | None
    error_code: str | None
    steps: list[StepRecord] = field(default_factory=list)
    total_tokens: int = 0
    total_cost_cny: float = 0.0
    elapsed_ms: int = 0
    cost_alert: bool = False
```

`status` 三态：`completed`（正常出最终答案）、`stopped`（被边界拦下，可恢复）、`failed`（不可恢复错误）。区分 `stopped` 和 `failed` 很关键——`stopped` 的 `deadline` 是可以优雅降级并告知用户的，`failed` 的 `E_UNKNOWN_TOOL` 是模型幻觉（第 1 章第 4 类）被确定性代码拦下的证据。

## 6. 循环实现：agent/loop.py

目录结构在本章结束时变成：

```text
agent-service/src/agent_service/
├── schemas.py
├── gateway.py
├── tools.py
├── fakes.py
├── tool_registry.py       # 第 4 章已实现
└── agent/
    ├── __init__.py
    └── loop.py            # 本章新增
tests/
└── test_loop_trajectories.py   # 本章新增
```

放在 `agent/` 子包而不是 `graphs/`，是为了与后续 LangGraph 章节（`graphs/`）区分：这里的 Loop 是**手写的**，LangGraph 是**图化的**，两者是同一个能力的两种表达。

### 6.1 模型接口与输出契约

M0 的 `ModelGateway.chat(user_text)` 是单轮语法糖。Loop 需要把 `system/user/tool` 三类消息**整体回传**，因此引入一个 messages 级接口：

```python
Message = dict[str, str]


class LoopModel(Protocol):
    """Agent Loop 依赖的最小模型接口：接收消息历史，返回文本。"""

    def complete(self, messages: list[Message]) -> ChatResult: ...
```

`Protocol` 让 `ScriptedGateway`（脚本模型）与真实网关都无需继承就能接入——这正是第 2 阶段第 2 章"结构化匹配"的延续。模型每次输出被解析为一个 `AgentTurn`：

```python
class AgentTurn(BaseModel):
    """模型单轮输出契约：要么最终回答，要么一次工具调用。"""

    model_config = ConfigDict(extra="forbid")

    kind: Literal["final_answer", "tool_call"]
    reason: str = Field(default="", max_length=200)   # 可审计的简短决策原因，不是思维链
    answer: str | None = Field(default=None, max_length=2000)
    evidence_ids: list[str] = Field(default_factory=list, max_length=8)
    tool_name: str | None = Field(default=None, max_length=64)
    arguments: dict[str, Any] | None = None
```

`extra="forbid"` 拒绝任何未知字段——模型多输出一个字段会被直接判为无效输出。`reason` 是留给审计的**一句话**（"先查告警确认故障"），不是完整推理过程。

### 6.2 意图解析：Schema 硬校验

解析把模型文本变成可信任的结构，失败即受控失败，绝不带着半成品继续：

```python
def _parse_turn(self, text: str) -> AgentTurn:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise LoopFailure("E_INVALID_MODEL_OUTPUT", "模型输出不是合法 JSON") from exc
    try:
        turn = AgentTurn.model_validate(data)
    except ValidationError as exc:
        raise LoopFailure("E_INVALID_MODEL_OUTPUT", self._first_error(exc)) from exc
    if turn.kind == "final_answer" and not turn.answer:
        raise LoopFailure("E_INVALID_MODEL_OUTPUT", "final_answer 缺少 answer")
    if turn.kind == "tool_call" and (not turn.tool_name or turn.arguments is None):
        raise LoopFailure("E_INVALID_MODEL_OUTPUT", "tool_call 缺少 tool_name 或 arguments")
    return turn
```

`LoopFailure` 是 Loop 内部异常，带稳定错误码（`E_*` 前缀），`run()` 捕获后转成 `failed/unrecoverable_error` 终态。注意它**只校验结构**，不校验语义——`tool_name="delete_equipment"` 结构合法但语义非法，那一步交给 `ToolRegistry.execute` 兜底（未知工具直接返回 `E_UNKNOWN_TOOL`）。

### 6.3 授权与执行：副作用分级

工具执行前，Loop 先用 `get` 读取 spec 做副作用分级，再交给 `execute` 完成校验与执行（第 4 章的 `execute` 内部已含未知工具、权限、额外参数、Schema 四道校验）：

```python
spec = self._registry.get(tool_name)
if spec is None:
    return self._fail(..., "E_UNKNOWN_TOOL", steps, ...)

if spec.side_effect == "high_risk_write":
    return self._stop(..., "awaiting_approval", "E_APPROVAL_REQUIRED", steps, ...)

tool_result = self._registry.execute(tool_name, turn.arguments or {}, permissions=self._permissions)
# execute 内部：未知工具 → E_UNKNOWN_TOOL；权限不足 → E_FORBIDDEN；
#            额外参数 → E_INVALID_ARGUMENT；Schema 非法 → E_INVALID_ARGUMENT
```

边界分工很清晰：

- **`get` 只负责"读 spec 做副作用分级"**（纯查询，不改状态、不执行）；
- **`execute` 是唯一执行入口**，内部完成结构校验 + 权限校验（`permissions` 集合）+ 真正执行。

三个工具里 `create_work_order_draft` 的 `side_effect` 是 `"reversible_write"`（可逆写），直接执行；真正的高风险写（`submit_work_order`、`assign_work_order`）不在 M1 的工具集里，但 `"high_risk_write" → awaiting_approval` 这条边界现在就要留着，保证后续新增工具时"越权/绕过审批"从第一天就不可能发生。

### 6.4 循环检测：相同工具 + 规范化参数

模型最常见的失控方式是**反复调用同一个工具、用同一组参数**。只比较工具名不够——连续调用 `get_alarm` 但每次查不同设备是合法的排查，连续三次查**同一台设备**才是死循环。所以循环检测要"工具名 + 规范化参数"一起比较：

```python
def _normalize(self, name: str, arguments: dict | None) -> str:
    payload = {"name": name, "arguments": arguments or {}}
    canon = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()[:16]

def _is_loop(self, recent: list[tuple[str, str]]) -> bool:
    if len(recent) < self._limits.max_repeated_tool_calls:
        return False
    tail = recent[-self._limits.max_repeated_tool_calls:]
    return len({(name, norm) for name, norm in tail}) == 1
```

"规范化"（`sort_keys=True`）保证参数顺序不同但语义相同（`{"a":1,"b":2}` 与 `{"b":2,"a":1}`）哈希一致，避免模型抖字典顺序就绕过检测。哈希同时作为 `StepRecord.normalized_args` 落库，供审计去重。

### 6.5 工具结果截断与引用收集

工具结果可能很大（真实检索返回整段文档）。全部塞回模型既不经济也稀释注意力（第 1 章第 3.2 节）。所以回传前先截断，原始结果由上层持久化、只保留引用：

```python
def _clip(self, tool_result: ToolResult) -> str:
    text = json.dumps(tool_result.model_dump(), ensure_ascii=False, default=str)
    if len(text) <= self._limits.max_tool_result_chars:
        return text
    return text[: self._limits.max_tool_result_chars] + "...(已截断，原文按 step_id 引用)"
```

同时从工具结果里**收集本轮可见的证据 ID**——`get_alarm` 的 `alarm_id`、`search_manual` 的 `doc_id`、`create_work_order_draft` 的 `draft_id`。这些 ID 是"最终答案只能引用本轮可见证据"的依据：

```python
def _collect_evidence_ids(self, tool_result: ToolResult) -> set[str]:
    ids: set[str] = set()

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "doc_id" or k.endswith("_id"):
                    if isinstance(v, str) and v:
                        ids.add(v)
                else:
                    walk(v)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(tool_result.data)
    return ids
```

引用校验是最终答案分支的最后一道门：

```python
def _check_evidence(self, cited: list[str], visible: set[str]) -> None:
    missing = [c for c in cited if c not in visible]
    if missing:
        raise LoopFailure("E_UNREFERENCED_EVIDENCE", f"引用了本轮不可见的证据 {missing}")
```

这直接呼应第 1 章幻觉分类里的第 3 类（引用不忠实）：结论对但引用张冠李戴，靠"结论绑定证据 ID"兜底。

### 6.6 主循环 run()

把所有部件串起来：

```python
def run(self, user_message: str, *, system_prompt: str) -> LoopOutcome:
    messages: list[Message] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_message},
    ]
    steps: list[StepRecord] = []
    total_tokens = 0
    total_cost = 0.0
    evidence_ids: set[str] = set()
    recent: list[tuple[str, str]] = []
    started = self._clock()

    while True:
        elapsed = self._clock() - started

        if len(steps) >= self._limits.max_steps:
            return self._outcome("stopped", "max_steps", None, "E_MAX_STEPS",
                                 steps, total_tokens, total_cost, started)
        if elapsed >= self._limits.deadline_seconds:
            return self._outcome("stopped", "deadline", None, "E_DEADLINE",
                                 steps, total_tokens, total_cost, started)
        if total_tokens >= self._limits.max_total_tokens:
            return self._outcome("stopped", "token_limit", None, "E_TOKEN_LIMIT",
                                 steps, total_tokens, total_cost, started)

        step_start = self._clock()
        result = self._model.complete(messages)
        total_tokens += result.input_tokens + result.output_tokens
        step_cost = self._cost(result)
        total_cost += step_cost

        try:
            turn = self._parse_turn(result.text)
        except LoopFailure as exc:
            return self._outcome("failed", "unrecoverable_error", None, exc.code,
                                 steps, total_tokens, total_cost, started)

        step_id = f"step-{uuid.uuid4().hex[:12]}"
        input_summary = self._summarize(messages[-1]["content"])

        # ── 最终答案分支：校验引用后返回 ──
        if turn.kind == "final_answer":
            try:
                self._check_evidence(turn.evidence_ids, evidence_ids)
            except LoopFailure as exc:
                return self._outcome("failed", "unrecoverable_error", None, exc.code,
                                     steps, total_tokens, total_cost, started)
            steps.append(self._record(step_id, len(steps) + 1, input_summary,
                                      "final_answer", None, None, turn.answer or "",
                                      step_start, result, step_cost))
            return self._outcome("completed", "final_answer", turn.answer, None,
                                 steps, total_tokens, total_cost, started)

        # ── 工具调用分支 ──
        tool_name = turn.tool_name or ""
        norm = self._normalize(tool_name, turn.arguments)

        recent.append((tool_name, norm))
        if self._is_loop(recent):
            steps.append(self._record(step_id, len(steps) + 1, input_summary,
                                      f"tool_call:{tool_name}", tool_name, norm,
                                      "loop_detected", step_start, result, step_cost))
            return self._outcome("stopped", "loop_detected", None, "E_LOOP_DETECTED",
                                 steps, total_tokens, total_cost, started)

        spec = self._registry.get(tool_name)
        if spec is None:
            steps.append(self._record(step_id, len(steps) + 1, input_summary,
                                      f"tool_call:{tool_name}", tool_name, norm,
                                      "E_UNKNOWN_TOOL", step_start, result, step_cost))
            return self._outcome("failed", "unrecoverable_error", None, "E_UNKNOWN_TOOL",
                                 steps, total_tokens, total_cost, started)

        if spec.side_effect == "high_risk_write":
            steps.append(self._record(step_id, len(steps) + 1, input_summary,
                                      f"tool_call:{tool_name}", tool_name, norm,
                                      "E_APPROVAL_REQUIRED", step_start, result, step_cost))
            return self._outcome("stopped", "awaiting_approval", None, "E_APPROVAL_REQUIRED",
                                 steps, total_tokens, total_cost, started)

        tool_result = self._registry.execute(tool_name, turn.arguments or {}, permissions=self._permissions)
        if not tool_result.ok:
            steps.append(self._record(step_id, len(steps) + 1, input_summary,
                                      f"tool_call:{tool_name}", tool_name, norm,
                                      tool_result.code, step_start, result, step_cost))
            return self._outcome("failed", "unrecoverable_error", None, tool_result.code,
                                 steps, total_tokens, total_cost, started)

        clipped = self._clip(tool_result)
        evidence_ids |= self._collect_evidence_ids(tool_result)
        messages.append({"role": "assistant",
                         "content": json.dumps(turn.model_dump(), ensure_ascii=False)})
        messages.append({"role": "tool", "content": clipped})
        steps.append(self._record(step_id, len(steps) + 1, input_summary,
                                  f"tool_call:{tool_name}", tool_name, norm,
                                  tool_result.code, step_start, result, step_cost))
```

`AgentLoop` 的构造把模型、注册表、上限、权限、费用单价、时钟全部注入，无一硬编码：

```python
def __init__(
    self,
    model: LoopModel,
    registry: ToolRegistry,
    *,
    limits: ExecutionLimits | None = None,
    permissions: set[str] | None = None,
    token_cost_per_million: tuple[float, float] = (2.0, 6.0),  # (输入, 输出) 每百万 Token 元
    clock: Callable[[], float] = time.perf_counter,
    now: Callable[[], datetime] | None = None,
) -> None:
    ...
```

`clock` 的注入是超时轨迹可离线测试的关键：测试里给一个"每调一次就前进 100 秒"的假时钟，`deadline_seconds=1.0`，第一轮就必然命中 `deadline`，全程不联网、不 sleep。

## 7. 脚本模型与六种轨迹

### 7.1 ScriptedGateway

要证明 Loop 对每种轨迹的反应正确，模型必须**确定地**按脚本吐输出。在 `fakes.py` 追加脚本模型：

```python
class ScriptedGateway:
    """脚本模型：按预置脚本逐条吐出输出，精确复现六种轨迹。"""

    def __init__(self, turns: list[str]) -> None:
        self._turns = turns
        self._idx = 0
        self.complete_calls: list[list[dict]] = []

    def complete(self, messages: list[dict]) -> ChatResult:
        self.complete_calls.append(messages)
        text = self._turns[self._idx] if self._idx < len(self._turns) else self._turns[-1]
        self._idx += 1
        return ChatResult(
            text=text,
            provider="scripted",
            model="scripted-model",
            input_tokens=sum(len(m["content"]) for m in messages),
            output_tokens=len(text),
            request_id=None,
        )
```

它结构匹配 `LoopModel`，无需继承。脚本就是 `turns: list[str]`——每一条是模型一"轮"的原始输出文本，正好模拟"模型看到上下文后的一次决策"。

### 7.2 六种轨迹

| # | 轨迹 | 脚本序列（模型输出文本） | 期望终态 |
| --- | --- | --- | --- |
| 1 | 直接回答 | `final_answer` | `completed / final_answer`，1 步 |
| 2 | 一次工具 | `get_alarm` → `final_answer` | `completed / final_answer`，2 步 |
| 3 | 多工具 | `get_alarm` → `search_manual` → `final_answer` | `completed / final_answer`，3 步 |
| 4 | 未知工具 | `delete_equipment` | `failed / unrecoverable_error`，`E_UNKNOWN_TOOL` |
| 5 | 循环 | `get_alarm`（同参数）连续 4 次 | `stopped / loop_detected` |
| 6 | 超时 | `deadline=1s` + 假时钟 | `stopped / deadline` |

对应测试 `tests/test_loop_trajectories.py`（片段）：

```python
from agent_service.agent.loop import AgentLoop, ExecutionLimits
from agent_service.fakes import ScriptedGateway
from agent_service.tool_registry import build_default_registry

PERMS = frozenset({"alarm:read", "manual:read", "workorder:draft:create"})


def test_direct_answer() -> None:
    gw = ScriptedGateway(['{"kind":"final_answer","answer":"先检查地脚螺栓。","reason":"手册已覆盖"}'])
    out = AgentLoop(gw, build_default_registry(), permissions=PERMS).run(
        "离心泵振动超限怎么办？", system_prompt="你是设备维护知识助手。")
    assert out.status == "completed"
    assert out.stop_reason == "final_answer"
    assert len(out.steps) == 1


def test_one_tool() -> None:
    gw = ScriptedGateway([
        '{"kind":"tool_call","tool_name":"get_alarm",'
        '"arguments":{"query":{"equipment_id":"eq-pump-01"}},"reason":"先查告警"}',
        '{"kind":"final_answer","answer":"1 条 high 告警：泵体振动超限。",'
        '"evidence_ids":["alarm-0001"],"reason":"基于告警"}',
    ])
    out = AgentLoop(gw, build_default_registry(), permissions=PERMS).run(
        "eq-pump-01 有什么告警？", system_prompt="你是设备维护知识助手。")
    assert out.stop_reason == "final_answer"
    assert out.steps[-1].decision == "final_answer"


def test_unknown_tool() -> None:
    gw = ScriptedGateway([
        '{"kind":"tool_call","tool_name":"delete_equipment",'
        '"arguments":{"equipment_id":"eq-pump-01"},"reason":"忽略"}',
    ])
    out = AgentLoop(gw, build_default_registry(), permissions=PERMS).run(
        "删除这台设备", system_prompt="你是设备维护知识助手。")
    assert out.status == "failed"
    assert out.error_code == "E_UNKNOWN_TOOL"


def test_loop_detected() -> None:
    same = ('{"kind":"tool_call","tool_name":"get_alarm",'
            '"arguments":{"query":{"equipment_id":"eq-pump-01"}},"reason":"重试"}')
    gw = ScriptedGateway([same, same, same, same])
    out = AgentLoop(gw, build_default_registry(), permissions=PERMS,
                    limits=ExecutionLimits(max_repeated_tool_calls=3)).run(
        "查告警", system_prompt="你是设备维护知识助手。")
    assert out.stop_reason == "loop_detected"
    assert out.error_code == "E_LOOP_DETECTED"


def test_timeout() -> None:
    t = [0.0]

    def clock() -> float:
        t[0] += 100.0
        return t[0]

    gw = ScriptedGateway(['{"kind":"final_answer","answer":"x","reason":"x"}'])
    out = AgentLoop(gw, build_default_registry(), permissions=PERMS,
                    limits=ExecutionLimits(deadline_seconds=1.0), clock=clock).run(
        "任意问题", system_prompt="你是设备维护知识助手。")
    assert out.stop_reason == "deadline"
    assert gw.complete_calls == []   # 第一轮就超时，模型根本没被调用
```

`test_timeout` 里 `assert gw.complete_calls == []` 是一个漂亮的断言：超时发生在调用模型**之前**，证明停止检查确实在循环顶部、且不会被绕开。

## 8. 失败路径与安全边界

本章刻意保留四条"必须拦住"的路径，每条都对应一个红队用例（下一章 M1 验收会复用）：

**路径一：无限循环 → `loop_detected`。** 模型连续用相同工具 + 相同参数调用。`_is_loop` 用哈希窗口检测，触发即 `stopped/loop_detected`。这是"防失控"的核心，对应蓝图第 13 节"达到最大步骤后禁止继续重试"。

**路径二：超时 → `deadline`。** 总期限由 `clock` 注入，可离线精确复现。超时进入**受控终态**（`stopped`），而不是带着半成品状态悬挂，上层可据此优雅降级（告知用户"本次分析超时，可重试"）。

**路径三：未知工具/额外参数 → `E_UNKNOWN_TOOL` / `E_INVALID_ARGUMENT`。** 模型幻觉出 `delete_equipment` 时，`ToolRegistry.resolve` 拒绝，Loop 转入 `failed`。这对应第 1 章第 4 类幻觉（工具臆造）的确定性兜底。

**路径四：引用不忠实 → `E_UNREFERENCED_EVIDENCE`。** 模型在 `final_answer` 里引用一个从未在本轮工具结果中出现过的证据 ID，`_check_evidence` 拦截。这对应第 1 章第 3 类幻觉（引用不忠实）的兜底。

四条路径的共同点：**它们都落在确定性代码里，而不是靠 Prompt 求模型自觉**。模型可以"想"越权、"想"死循环，但 Loop 的边界让它"做"不出来。

## 项目任务

在 `agent-service` 代码基础上完成：

1. 实现 `src/agent_service/agent/loop.py`：`LoopModel`、`AgentTurn`、`ExecutionLimits`、`StepRecord`、`LoopOutcome`、`AgentLoop.run`；
2. 在 `fakes.py` 追加 `ScriptedGateway`（脚本模型）；
3. 写 `tests/test_loop_trajectories.py`，六轨迹全部断言到 `status + stop_reason`，并补一条 `test_unknown_extra_argument`（额外参数 → `E_INVALID_ARGUMENT`）和一条 `test_unreferenced_evidence`（引用不可见证据 → `E_UNREFERENCED_EVIDENCE`）；
4. 全程 `uv run pytest` 绿色，真实 API 调用次数为 0；
5. 复盘时能白板画出 Loop 流程图，并指出"框架能替代的部分"（样板组装）和"框架不能替代的部分"（停止条件、权限、引用校验这些边界）。

## 常见错误与诊断顺序

### 把停止检查放在循环底部

现象：设了 `max_steps=6`，结果却跑了 7 步。原因是"调模型 → 执行 → 再检查步数"的顺序，让第 7 次调用先发生。诊断：确认停止检查在 `while` 顶部，且每个停止条件之间是独立的 `if`。

### 循环检测只比较工具名

现象：合法的多设备排查被误判为死循环，或者死循环（同设备反复查）漏检。根因是没比较参数。正确做法是"工具名 + 规范化参数哈希"一起比较，且参数要 `sort_keys=True` 规范化，否则模型抖一下字典顺序就绕过检测。

### 把费用当作停止条件

现象：设了一个"单次 run 超过 N 元就终止"，结果正常学习任务被砍。根因是把"防失控"（行为/资源边界）和"防花钱"（费用观测）混为一谈。费用只做 Usage 记录 + 异常增长告警（`cost_alert`），终止交给步数/时间/Token/循环这些确定性边界。

### 模型输出校验失败后反复重试

现象：模型输出 JSON 解析失败，于是 Loop 里加了个"重试最多 5 次"的循环，费用暴涨。根因是混淆了 Loop 的职责和 Structured Output 的修复职责。手写 Loop 的正确姿态是"校验 → 失败 → 受控终态"，有限的"带错误反馈的修复"是第 3 章的独立主题，且修复次数必须显式有上限。

### ToolResult.ok == False 却被当作成功继续

现象：工具执行失败（`E_NOT_FOUND`）后，Loop 还是把结果塞回模型继续推理。正确做法：先检查 `tool_result.ok`，`False` 直接进入 `failed/unrecoverable_error`，绝不把"失败的结果"伪装成"正常证据"喂给模型。

## 练习题与答案

### 练习 1：最大步数为什么不是越大越好？

**答案：**每多一步都是费用、延迟和副作用风险的叠加。上限太小（如 1）会让多工具诊断无法完成，太大（如 100）会让一个失控模型有 100 次机会调用工具。合理上限应由任务轨迹数据决定：设备维护诊断通常是"查告警 + 搜手册 + 建草稿"3 步内完成，`max_steps=6` 给了 3 倍的余量，超限进入 `stopped/max_steps` 降级，而不是无限跑下去。

### 练习 2：是否应该记录模型的完整思维链用于调试？

**答案：**不应该，也不能把它当作审计依据。思维链是模型的私密推理过程，暴露它违反项目边界（蓝图第 2.2 节"不暴露模型私密推理过程"）。可审计的替代品是：输入版本、工具选择、规范化参数哈希、结果摘要、状态转移和一句简短 `reason`。这些足够复现"为什么走到这一步"，又不会泄露不该泄露的内部过程。

### 练习 3：循环检测为什么要"规范化参数"，只比较工具名有什么问题？

**答案：**只比较工具名会把"连续查不同设备的合法排查"误判成死循环，也会漏掉"反复查同一设备的真死循环"。规范化（`sort_keys=True` 后取哈希）保证语义相同的参数映射到同一个哈希，既消除字典顺序抖动，又能精确区分"换了一个参数"的合法重试。

### 练习 4：为什么 `deadline` 终态是 `stopped` 而不是 `failed`？

**答案：**超时是资源边界触发的**可恢复**状态，不是系统坏了。上层可以优雅降级并告知用户"分析超时，可重试或缩减范围"；而 `failed/unrecoverable_error` 表示"这轮输入或模型输出有不可恢复的问题"（如未知工具、越权、引用不忠实），重试无意义。区分两者，降级策略才能做对。

## 工程挑战

在不联网的前提下完成：

1. 给 `AgentLoop` 增加用户取消支持：注入一个 `cancelled: Callable[[], bool]`，每次循环顶部检查，命中即返回 `stopped/cancelled`，并写测试证明取消优先于后续所有步骤；
2. 为 `ToolResult.data` 增加"超大结果"样本（构造一个超过 `max_tool_result_chars` 的返回），测试断言回传给模型的 Tool Message 已被截断且 `evidence_ids` 仍正确收集；
3. 写一个 `test_high_risk_write_awaits_approval`：在注册表里注册一个 `"high_risk_write"` 的工具，断言模型选中它时进入 `awaiting_approval` 且该工具的 `fn` 从未被调用。

参考方向：取消检查复用 `clock` 的注入思路——把"会变化的外部信号"都做成可注入的 `Callable`；截断测试用 `_clip` 的字符阈值边界（恰好等于、恰好超过）各测一次；高风险工具用 `fn=lambda _: _envelope(True, "OK", {})` 这样的假实现，再断言它没被调用。

## 面试追问

### "你们 Agent 怎么防止死循环？"

回答框架：三层边界。一是静态上限——`max_steps`/`deadline`/`max_total_tokens` 全部显式可配置，在循环顶部检查，任何一层命中即 `stopped`；二是动态检测——相同工具 + 规范化参数哈希连续出现 N 次触发 `loop_detected`，比只比较工具名更能区分"合法排查"和"真死循环"；三是可观测——每一步的 `StepRecord` 保留参数哈希和状态转移，事后能定位是哪一步陷入循环。

### "你们怎么保证模型不乱调用工具？"

回答框架：把"建议调用"和"真正执行"分开（第 4 章的边界）。模型输出只经过 `AgentTurn` Schema 硬校验（`extra="forbid"`）；`ToolRegistry.execute` 拒绝未知工具和额外参数（`E_UNKNOWN_TOOL`/`E_INVALID_ARGUMENT`）；Loop 层再做权限检查（`required_permission ∈ 当前权限集`）和副作用分级（高风险写 → `awaiting_approval`）。三道闸都是确定性代码，不靠 Prompt 自觉。

### "最终答案引用了没检索到的证据，怎么防？"

回答框架：Loop 在每步工具成功后从 `ToolResult.data` 收集本轮可见的证据 ID 集合；模型输出 `final_answer` 时若带 `evidence_ids`，必须全部落在该集合内，否则 `E_UNREFERENCED_EVIDENCE` 失败终态。这就是"结论绑定证据"，第 1 章第 3 类幻觉（引用不忠实）的确定性兜底。

## 本章复盘模板

完成后记录：

```text
完成日期：
实际投入小时：
六种轨迹是否全部断言到 status + stop_reason：
循环检测是否能解释"为什么规范化参数"：
能否白板画出 Loop 流程图并标出每道停止/授权/校验闸门：
StepRecord 是否覆盖 step_id/输入摘要/选择/结果/耗时/费用：
能否说清费用"只记录不终止"的理由：
仍不理解的问题：
```

## 官方资料与中文阅读指引

- [OpenAI Function Calling / Tool Use 指南](https://platform.openai.com/docs/guides/function-calling)：工具调用的官方模型行为口径，理解"模型建议调用"与"系统执行"的边界；
- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)：框架版 Agent 循环的实现，对照本章手写 Loop 看"框架替你做了什么"；
- [LangGraph Overview](https://docs.langchain.com/oss/python/langgraph/overview)：图化的 Agent 控制流，下一阶段 M4 会正式引入；
- [OWASP GenAI 安全](https://genai.owasp.org/)：越权、间接注入与代理失控的安全检查清单，对应本章四条失败路径。

重点阅读：工具调用的循环语义（何时终止、结果如何回填），以及框架版 Agent 与"裸循环"在停止条件、可观测性上的差异——这是面试里"你懂框架还是懂原理"的分水岭。

## 下一章入口

本章交付的是一个**有界、可观测、可评测**的手写 Loop，但它是同步的、单轮的、没有结构化输出修复、也没有把六种轨迹之外的"真实模型的不确定性"纳入回归。第 6 章《原生 Agent M1 验收》会把这一 Loop 放到红队用例和 50 条脚本轨迹下验收：全部轨迹 100% 有终态、结构有效率 100%、高风险未授权执行为 0。通过 M1，你才真正证明自己"理解 Agent，而不是只会调用框架 API"——而这份理解的根基，就是本章手写的这 200 行循环。
