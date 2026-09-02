# FastAPI 与 SSE 流式 Agent 接口

> 所属阶段：第 4 周  
> 预计用时：7～8 小时  
> 项目产出：非流式、流式与取消语义一致的 Agent HTTP API  
> 资料验证日期：2026-09-02

## 1. 本章从哪里开始

第 3 章结束时，项目已经有：异步网关（`ModelGateway` Protocol）、可靠执行器（`ReliableInvoker`，带 `InvokeOutcome` 观测数据）、错误分类（`GatewayError` 与稳定错误码）、故障注入替身（`FlakyGateway`）。但它们唯一的消费者是 `main.py` 里的 CLI。

CLI 的问题不是功能，而是**没有契约**：

- 没有稳定的对外协议——本周给未来的前端、下周给评测脚本、下月给自己复盘用的调用方式，都必须重新发明；
- 没有生命周期——配置、客户端、信号量在进程里如何创建和销毁，没有统一管理；
- 没有运行标识——一次调用发生了什么、重试了几次、花了多少 Token，事后无法关联。

本章把 CLI 升级为 HTTP 服务。完成后你应该能回答：

1. 为什么对外事件协议必须由我们自己定义，而不是把框架或 SDK 的内部事件直接转发？
2. SSE 流已经开始后，上游失败为什么不能再用 HTTP 500 表达？
3. 客户端断开连接后，上游模型调用如何被真正取消？
4. `run_id` 解决什么问题，没有它会失去什么？

## 2. 本章完成标准

必须同时满足：

- `POST /v1/chat` 与 `POST /v1/chat/stream` 共享同一个应用服务实现；
- SSE 事件按 `run.started` → `message.delta`* → `run.completed`/`run.failed` 顺序输出，每条带递增 `seq`；
- `curl -N` 能看到流式事件，中文不乱码；
- 客户端断开后，上游调用被取消（有测试证明）；
- 请求校验失败返回 422，上游临时不可用映射为 503，限流映射为 429，错误体含稳定 `code` 与 `run_id`；
- `GET /v1/runs/{run_id}` 与 `POST /v1/runs/{run_id}/cancel` 可用（内存版）；
- `/health/live` 与 `/health/ready` 语义正确；
- 除手动验证外，全部测试离线完成。

## 3. API 契约

先定义对外协议，再写实现。六个端点：

```text
POST /v1/chat                 普通响应：一次问答的完整结果
POST /v1/chat/stream          SSE 流：边生成边推送事件
GET  /v1/runs/{run_id}        查询一次运行的状态与结果摘要
POST /v1/runs/{run_id}/cancel 请求取消一次进行中的运行
GET  /health/live             进程存活（不检查依赖）
GET  /health/ready            依赖就绪（配置合法、网关可构造）
```

请求与响应模型（追加进 `schemas.py`）：

```python
class ChatRequest(BaseModel):
    """对外问答请求。"""

    model_config = ConfigDict(extra="forbid")

    conversation_id: str = Field(min_length=1, max_length=64)
    message: str = Field(min_length=1, max_length=8000)
    request_id: str | None = Field(default=None, min_length=8, max_length=64)


class ChatResponse(BaseModel):
    """非流式应答。"""

    model_config = ConfigDict(extra="forbid")

    run_id: str
    conversation_id: str
    text: str
    provider: str
    model: str
    input_tokens: int
    output_tokens: int
    attempts: int
    elapsed_ms: int


class RunStatus(BaseModel):
    """运行状态查询结果。"""

    model_config = ConfigDict(extra="forbid")

    run_id: str
    conversation_id: str
    status: Literal["running", "completed", "failed", "cancelled"]
    error_code: str | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
```

三条契约级约定：

1. **`run_id` 由服务端生成**，是这一次执行的唯一标识。日志、费用记录、状态查询、未来 LangSmith 的 Trace 全部以它关联。请求方可以带 `request_id`（用于幂等去重，本章先透传），但没有权利指定 `run_id`；
2. `conversation_id` 标识会话。本章还没有记忆（多轮上下文在后续阶段引入），但协议里先占位，避免未来破坏性变更——这是第 2 章契约演进规则的直接应用；
3. 查询和取消都指向 `run_id`，不是 `conversation_id`——取消“会话”没有意义，取消的是“这一次执行”。

## 4. SSE 事件协议

### 4.1 为什么不直接推 Token

最朴素的 SSE 实现是把文本增量直接 `yield` 出去。三个反例：

- 前端无法区分“文本增量”和“工具开始执行”——将来 Agent 会调工具，协议里必须有位置放这些事件；
- 框架内部事件（比如 LangChain 的消息块）含版本相关结构和潜在敏感上下文，直接转发等于把内部实现焊死在对外协议上，供应商或框架升级 = 前端跟着改；
- 没有统一的错误通道——流到一半失败时，前端只能显示一个截断的回答，用户以为回答就是完整的。

所以对外事件协议必须**自定义、稳定、脱敏**。本章定义四种事件，为后续阶段的工具事件预留命名空间：

| 事件 | 载荷 | 时机 |
| --- | --- | --- |
| `run.started` | `run_id`、`conversation_id` | 服务端接受请求 |
| `message.delta` | `delta`（文本增量） | 每个文本片段 |
| `run.completed` | `usage` 摘要、`attempts`、`elapsed_ms` | 正常结束 |
| `run.failed` | `code`（稳定错误码）、`message` | 失败结束 |

（后续阶段将追加 `tool.started` / `tool.completed`，命名与这里的风格一致。）

### 4.2 事件格式

SSE 的线上格式是固定的：`event:` 行、`id:` 行、`data:` 行，事件之间空行分隔。`seq` 放在 `id:` 字段里，客户端断线重连时可用 `Last-Event-ID` 告诉服务端从哪之后补偿：

```text
event: run.started
id: 1
data: {"run_id": "run-9f2c", "conversation_id": "conv-001"}

event: message.delta
id: 2
data: {"delta": "设备温度升高时，"}

event: message.delta
id: 3
data: {"delta": "应先核对最近 24 小时告警。"}

event: run.completed
id: 4
data: {"input_tokens": 126, "output_tokens": 88, "attempts": 1, "elapsed_ms": 3420}
```

### 4.3 状态码语义

- 请求格式错误 → 422（FastAPI + Pydantic 自动完成）；
- 上游临时不可用（重试耗尽）→ 503；
- 上游限流（重试耗尽）→ 429；
- 永久请求错误 → 400 系（本章 `GatewayError.status_code` 映射）；
- **流开始后，HTTP 状态码已经发出（200），不能再改**。此后一切失败只能以 `run.failed` 事件表达，同时服务端记录完整错误供排查。

SSE 是单向流（服务端→客户端）。需要客户端实时推送控制指令时再评估 WebSocket，本章不做——协议够用就好，双向是新的复杂度。

## 5. 应用服务层

`api.py` 的路由应该薄。业务编排放 `service.py`，非流式与流式端点共享它：

```python
from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from dataclasses import dataclass

from agent_service.errors import GatewayError
from agent_service.executor import InvokeOutcome, ReliableInvoker
from agent_service.gateway import ModelGateway
from agent_service.schemas import ChatRequest, ChatResponse, RunStatus


@dataclass(frozen=True, slots=True)
class StreamEvent:
    """对外 SSE 事件的最小内部表示。"""

    name: str
    seq: int
    payload: dict


class ChatService:
    """非流式与流式共享的应用服务。"""

    def __init__(self, gateway: ModelGateway, invoker: ReliableInvoker) -> None:
        self._gateway = gateway
        self._invoker = invoker

    async def chat(self, request: ChatRequest, run_id: str) -> ChatResponse:
        outcome: InvokeOutcome = await self._invoker.chat(
            self._gateway, request.message
        )
        result = outcome.result
        return ChatResponse(
            run_id=run_id,
            conversation_id=request.conversation_id,
            text=result.text,
            provider=result.provider,
            model=result.model,
            input_tokens=result.input_tokens,
            output_tokens=result.output_tokens,
            attempts=outcome.stats.attempts,
            elapsed_ms=outcome.stats.elapsed_ms,
        )

    async def stream_events(
        self, request: ChatRequest, run_id: str
    ) -> AsyncIterator[StreamEvent]:
        seq = 0

        def event(name: str, payload: dict) -> StreamEvent:
            nonlocal seq
            seq += 1
            return StreamEvent(name=name, seq=seq, payload=payload)

        yield event(
            "run.started",
            {"run_id": run_id, "conversation_id": request.conversation_id},
        )

        try:
            async for delta in self._gateway.stream_chat(request.message):
                yield event("message.delta", {"delta": delta})
        except GatewayError as exc:
            yield event(
                "run.failed",
                {"code": exc.code, "message": "上游暂时不可用，请稍后重试"},
            )
            return

        yield event("run.completed", {"note": "流式路径的 Usage 统计在后续阶段接入"})
```

两个刻意的设计：

- `run_id` 由调用方（API 层）生成后传入，服务层不关心它怎么来的——测试时可以直接注入固定值；
- 流式路径暂时不统计 Usage（第 1 章 §8.3 的约定仍然有效：不要为了让协议“看起来完整”而伪造数据）。`run.completed` 的事件载荷留了真实字段的位置，后续阶段接入统一 Usage Event 时补上。

## 6. FastAPI 骨架

安装依赖：

```bash
uv add fastapi uvicorn
```

创建 `src/agent_service/api.py`。三个构件：应用工厂、生命周期、依赖注入。

```python
from __future__ import annotations

import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request

from agent_service.config import LLMSettings
from agent_service.errors import GatewayError
from agent_service.executor import ReliableInvoker
from agent_service.gateway import create_gateway
from agent_service.schemas import ChatRequest, ChatResponse, RunStatus
from agent_service.service import ChatService
from agent_service import runs


@asynccontextmanager
async def lifespan(app: FastAPI):
    """进程生命周期内唯一的重对象构造点。"""
    settings = LLMSettings.from_env()
    app.state.settings = settings
    app.state.gateway = create_gateway(settings)
    app.state.invoker = ReliableInvoker(
        timeout_seconds=settings.timeout_seconds, max_retries=2
    )
    app.state.registry = runs.RunRegistry()
    yield
    # AsyncOpenAI 客户端随进程退出自动关闭；显式清理点在需要时补。


def create_app(settings: LLMSettings | None = None) -> FastAPI:
    app = FastAPI(title="agent-service", version="0.1.0", lifespan=lifespan)
    _register_routes(app)
    return app
```

为什么用应用工厂而不是模块级 `app = FastAPI()`：测试需要用不同配置（Fake 网关、不同超时）构造独立应用实例；模块级单例会让测试互相污染。第 5 章会大量用到这一点。

依赖注入通过 `app.state` 取回 lifespan 里构造的对象：

```python
def get_service(request: Request) -> ChatService:
    return ChatService(gateway=request.app.state.gateway,
                       invoker=request.app.state.invoker)


def get_registry(request: Request) -> runs.RunRegistry:
    return request.app.state.registry
```

## 7. 非流式端点与错误映射

```python
def _register_routes(app: FastAPI) -> None:
    @app.post("/v1/chat", response_model=ChatResponse)
    async def chat(
        payload: ChatRequest,
        service: ChatService = Depends(get_service),
        registry: runs.RunRegistry = Depends(get_registry),
    ) -> ChatResponse:
        run_id = f"run-{uuid.uuid4().hex[:12]}"
        registry.start(run_id, payload.conversation_id)
        try:
            response = await service.chat(payload, run_id)
        except GatewayError as exc:
            registry.finish(run_id, status="failed", error_code=exc.code)
            raise _to_http_error(exc) from exc
        registry.finish(run_id, status="completed")
        return response
```

`GatewayError` 到 HTTP 的映射规则集中在一个函数里：

```python
def _to_http_error(exc: GatewayError) -> HTTPException:
    status = exc.status_code
    if status == 429:
        http_status = 429
    elif status is not None and 500 <= status < 600:
        http_status = 503  # 上游 5xx 对外表现为"服务暂不可用"
    elif status is not None:
        http_status = status
    else:
        http_status = 500
    return HTTPException(
        status_code=http_status,
        detail={"code": exc.code, "message": "上游调用失败"},
    )
```

注意两点：错误体里的 `message` 是**脱敏后的稳定文案**，供应商的原始错误（可能含 Base URL、内部路径）不出边界——第 2 章“堆栈不出边界”原则在 HTTP 层的延续；429 和 503 的区别保留了“是谁的问题”这个信息，调用方可以据此决定自己的退避策略。

## 8. SSE 流式端点

```python
    @app.post("/v1/chat/stream")
    async def chat_stream(
        payload: ChatRequest,
        request: Request,
        service: ChatService = Depends(get_service),
        registry: runs.RunRegistry = Depends(get_registry),
    ) -> StreamingResponse:
        run_id = f"run-{uuid.uuid4().hex[:12]}"
        registry.start(run_id, payload.conversation_id)
        await registry.bind_task(run_id, asyncio.current_task())

        async def to_sse(event) -> str:
            payload_json = json.dumps(event.payload, ensure_ascii=False)
            return f"event: {event.name}\nid: {event.seq}\ndata: {payload_json}\n\n"

        async def event_source():
            try:
                async for event in service.stream_events(payload, run_id):
                    if await request.is_disconnected():
                        break
                    yield to_sse(event)
                    if event.name in ("run.completed", "run.failed"):
                        registry.finish(
                            run_id,
                            status="completed" if event.name == "run.completed" else "failed",
                        )
            except asyncio.CancelledError:
                registry.finish(run_id, status="cancelled")
                raise
            finally:
                registry.finish(run_id, status="cancelled")

        return StreamingResponse(
            event_source(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )
```

四个关键机制：

**`ensure_ascii=False`。**默认的 `json.dumps` 会把中文转成 `\uXXXX` 转义。SSE 载荷直接输出 UTF-8 中文，配合 `media_type="text/event-stream"`，浏览器端不乱码。

**`X-Accel-Buffering: no`。**Nginx 等反向代理默认会缓冲响应再转发，SSE 的实时性会被毁掉。这个头告诉代理不要缓冲。本地开发没有代理也建议先写上，部署阶段（第 8 阶段）会重新遇到它。

**客户端断开检测。**每个事件之间检查 `request.is_disconnected()`。更根本的是下一行：客户端断开时，ASGI 服务器会取消整个响应任务，`CancelledError` 在生成器的 `await` 点抛出——我们在 `except` 里把运行标记为 `cancelled` 后**重新抛出**（第 3 章的铁律），上游的 `stream_chat` 迭代随之被取消，模型调用真正停止。

**事件结束即运行结束。**`run.completed` / `run.failed` 既是给客户端的信号，也是服务端登记运行终态的钩子。

## 9. RunRegistry 与取消

`src/agent_service/runs.py`，内存版实现：

```python
from __future__ import annotations

import asyncio

from agent_service.schemas import RunStatus


class RunRegistry:
    """进程内运行登记表。重启即失忆——生产版在后续章节换成 Redis。"""

    def __init__(self) -> None:
        self._runs: dict[str, RunStatus] = {}
        self._tasks: dict[str, asyncio.Task] = {}

    def start(self, run_id: str, conversation_id: str) -> None:
        self._runs[run_id] = RunStatus(
            run_id=run_id, conversation_id=conversation_id, status="running"
        )

    async def bind_task(self, run_id: str, task: asyncio.Task) -> None:
        self._tasks[run_id] = task

    def finish(
        self,
        run_id: str,
        *,
        status: str,
        error_code: str | None = None,
    ) -> None:
        current = self._runs.get(run_id)
        if current is None:
            return
        self._runs[run_id] = current.model_copy(
            update={"status": status, "error_code": error_code}
        )

    def get(self, run_id: str) -> RunStatus | None:
        return self._runs.get(run_id)

    async def cancel(self, run_id: str) -> bool:
        task = self._tasks.get(run_id)
        if task is None or task.done():
            return False
        task.cancel()
        return True
```

对应端点：

```python
    @app.get("/v1/runs/{run_id}", response_model=RunStatus)
    async def get_run(
        run_id: str, registry: runs.RunRegistry = Depends(get_registry)
    ) -> RunStatus:
        status = registry.get(run_id)
        if status is None:
            raise HTTPException(status_code=404, detail={"code": "RUN_NOT_FOUND"})
        return status

    @app.post("/v1/runs/{run_id}/cancel")
    async def cancel_run(
        run_id: str, registry: runs.RunRegistry = Depends(get_registry)
    ) -> dict:
        cancelled = await registry.cancel(run_id)
        return {"run_id": run_id, "cancelled": cancelled}
```

诚实说明内存版的边界：进程重启后运行记录消失、多副本部署时查询和取消必须命中同一副本。生产答案是 Redis + 任务队列——正是本阶段第 7 章的主题，届时这个类会被替换而**端点协议不变**。这也是把 `RunRegistry` 做成可替换类的意义。

## 10. 健康检查

```python
    @app.get("/health/live")
    async def live() -> dict:
        return {"status": "alive"}

    @app.get("/health/ready")
    async def ready(request: Request) -> dict:
        ready = hasattr(request.app.state, "gateway")
        return {"status": "ready" if ready else "not_ready"}
```

`live` 只回答“进程还在吗”——它崩溃时编排系统应该重启它。`ready` 回答“能接流量吗”——配置缺失、网关构造失败时应该把它摘出负载均衡。两者混用会导致配置错误的服务被反复重启而不是被摘除。

## 11. 运行与验证

### 11.1 启动

```bash
uv run uvicorn agent_service.api:create_app --factory --reload
```

### 11.2 非流式

```bash
curl -s -X POST http://127.0.0.1:8000/v1/chat \
  -H "Content-Type: application/json" \
  -d '{"conversation_id": "conv-001", "message": "泵振动超限先查什么？"}' | python3 -m json.tool
```

### 11.3 流式

```bash
curl -N -X POST http://127.0.0.1:8000/v1/chat/stream \
  -H "Content-Type: application/json" \
  -d '{"conversation_id": "conv-001", "message": "请用三点说明保留原始告警的原因"}'
```

`-N` 关闭 curl 的缓冲，否则事件会挤成一坨才显示。观察事件的顺序与 `seq` 递增。

### 11.4 验证取消

一个终端启动流式请求，回答生成中途 `Ctrl+C` 杀掉 curl；另一个终端在杀掉前调用：

```bash
curl -s -X POST http://127.0.0.1:8000/v1/runs/<run_id>/cancel
```

然后查询 `GET /v1/runs/<run_id>`，应看到 `cancelled`。（注意：本地开发用 `--reload` 时进程结构不同，做取消实验时去掉 `--reload`。）

### 11.5 OpenAPI

访问 `http://127.0.0.1:8000/docs`。FastAPI 从 Pydantic 模型自动生成的 OpenAPI 文档，就是第 2 章说的“契约的机器可读形态”——前端、评测脚本、未来的 MCP Server 都可以消费它。

## 12. 常见错误与诊断顺序

### 12.1 流式输出一坨才出现

按顺序检查：curl 是否用了 `-N`；中间是否有代理在缓冲（看 `X-Accel-Buffering` 是否生效）；客户端是否自己在攒够缓冲才渲染。

### 12.2 中文乱码

`json.dumps` 忘了 `ensure_ascii=False`，或响应 `media_type` 带错。先在终端用 `curl` 看原始字节，确认服务端输出正确，再排查客户端。

### 12.3 断开后上游还在跑

确认生成器的 `CancelledError` 被重新抛出而不是吞掉；确认没有 `except Exception` 罩在流式生成器外层把取消吃了。用 `FlakyGateway` 的 `chat_calls` 数量做证据。

### 12.4 lifespan 里抛 RuntimeError（缺环境变量）

这是“好错误”：服务带着坏配置启动不如不启动。检查环境变量，或确认部署环境注入了正确配置。

### 12.5 422 里的错误信息看不懂

FastAPI 的校验错误在 `detail` 数组里，包含字段路径和原因。如果需要稳定机器码，第 5 章会用全局异常处理器把 422 错误体重构成自有格式。

## 13. 项目任务

1. 实现 `service.py`、`api.py`、`runs.py` 与全部六个端点；
2. 用 `curl` 完成非流式、流式、状态查询、取消四类手工验证并记录输出；
3. 编写 `tests/test_api.py`：用 `httpx.AsyncClient` + `ASGITransport` 直连应用（不占端口），覆盖：事件顺序与 `seq` 递增、422 校验、`GatewayError` → 503 映射（用 `FlakyGateway` 注入）、客户端断开时 `chat_calls` 停止增长；
4. 在测试里用工厂构造带 Fake 的应用实例（覆盖 lifespan，避免读真实环境变量）。

第 3 点提示：测试构造应用时不必触发 lifespan，可以直接 `app.state.gateway = FakeGateway()` 后挂载路由；正式的 lifespan 测试（配置缺失即启动失败）放在第 5 章。

## 14. 练习题与答案

### 练习 1：为何不把框架内部事件原样给前端？

**答案：**内部事件随框架版本变化、可能含敏感上下文（完整 Prompt、工具参数、内部 ID），转发它们等于把内部实现焊进对外协议。自有事件协议让框架可以随意替换，前端零改动；脱敏发生在协议边界。

### 练习 2：流输出一半时工具失败，能返回 HTTP 500 吗？

**答案：**不能。响应头（200）已发出，HTTP 状态码无法改变。只能发 `run.failed` 事件并正常结束流，同时服务端记录带 `run_id` 与错误码的日志。这就是“流开始后错误走事件通道”的原因。

### 练习 3：为什么 `run_id` 由服务端生成？

**答案：**运行标识需要全局唯一且不可伪造。客户端指定会带来幂等伪装（同一 ID 不同请求）和路由攻击面。客户端去重用自己的 `request_id`，两者职责分开。

### 练习 4：`/health/live` 返回 500 会发生什么？

**答案：**如果编排系统配置了按存活探针重启，服务会被反复重启——但“配置坏了”不是重启能治的病，正确行为是 `ready` 探针失败、摘出流量、等待修复。两个探针服务于两个不同的自动化决策。

## 15. 工程挑战

1. 给流式端点实现 `Last-Event-ID` 补偿：断线重连带 `Last-Event-ID: 3` 时，把 `seq > 3` 的事件重放（提示：`RunRegistry` 里给每个 run 缓存事件列表，上限 100 条，超限拒绝补偿并要求客户端走状态查询）；
2. 给 `run.failed` 事件的载荷加上 `retryable: bool`，让客户端知道该不该自动重试；
3. 实现请求级的 `X-Request-ID` 头透传：请求带了就沿用并记入日志，没带就生成。

参考方向：1 是内存缓冲 + 事件裁剪，注意内存上限就是 DoS 边界；2 直接复用 `GatewayError.retryable`；3 用 FastAPI 中间件实现，日志字段在第 5 章结构化后完整闭环。

## 16. 面试追问

### 16.1 SSE 和 WebSocket 怎么选？

回答框架：先看通信方向。服务端单向推送（流式回答、进度事件）用 SSE——基于 HTTP、自动重连、经过代理友好；双向实时控制才需要 WebSocket。加分项：说出 SSE 的 `Last-Event-ID` 重连机制，以及“协议升级、有状态连接”带来的运维成本。

### 16.2 你的 API 错误处理策略是什么？

回答框架：错误在边界分类（`GatewayError` 带稳定码）→ 集中映射（一个函数决定 HTTP 状态码）→ 脱敏（供应商原始错误不出边界）→ 可关联（错误体带 `code`，日志带 `run_id`）。主动说出“流开始后状态码不可变，错误走事件通道”的，说明真做过流式服务。

### 16.3 依赖注入在你项目里怎么做的？

回答框架：重对象在 lifespan 里构造一次，挂 `app.state`；路由用 `Depends` 取回；测试用应用工厂替换实现（Fake 网关注入）。要点不是背出 FastAPI 语法，而是说清“为什么要注入”——可测试性与配置隔离。

## 17. 本章复盘模板

```text
完成日期：
实际投入小时：
手工验证的 4 类端点输出是否都已记录：
流式事件 seq 是否严格递增：
断开测试里 chat_calls 的最终数量：
现在能否不看代码解释：为什么流开始后不能用 HTTP 500：
仍不理解的问题：
```

## 18. 官方资料与中文阅读指引

### 18.1 FastAPI

- [FastAPI 异步](https://fastapi.tiangolo.com/async/)
- [FastAPI Lifespan Events](https://fastapi.tiangolo.com/advanced/events/)
- [FastAPI Testing](https://fastapi.tiangolo.com/tutorial/testing/)

重点阅读：什么时候用 `async def` 什么时候用 `def`（FastAPI 会把同步路由丢线程池——结合第 3 章“阻塞是毒药”理解）；lifespan 替代已废弃的 startup/shutdown；`TestClient` 与异步测试的写法。

### 18.2 SSE 规范

- [MDN: Server-sent events](https://developer.mozilla.org/zh-CN/docs/Web/API/Server-sent_events)

重点阅读：事件流格式（`event`/`id`/`data` 行与空行分隔）、`Last-Event-ID` 与自动重连。规范很短，值得通读一遍。

### 18.3 uvicorn

- [uvicorn](https://www.uvicorn.org/)

重点阅读：`--factory`、`--reload` 的适用范围（reload 只用于开发）、worker 数量与事件循环的关系。

## 19. 下一章入口

服务能跑、能流式、能取消，但三块地基还是空的：

- 没有系统性的测试（现在的 API 测试只覆盖骨架）；
- 日志是裸奔的——`InvokeStats` 里的重试与耗时数据没有落盘，出问题只能靠猜；
- 配置仍是手写 dataclass + 环境变量，没有 `.env` 支持与集中验证。

下一章补齐测试分层、结构化日志、配置管理与完整错误体系，然后就能迎接 M0 里程碑验收。
