# FastAPI 与 SSE 流式 Agent 接口

> 预计 7 小时｜产出：非流式、流式和取消语义一致的 Agent API。

## 1. API 契约

```text
POST /v1/chat                 普通响应
POST /v1/chat/stream          SSE 流
GET  /v1/runs/{run_id}        查询运行状态
POST /v1/runs/{run_id}/cancel 请求取消
GET  /health/live             进程存活
GET  /health/ready            依赖就绪
```

请求带 `conversation_id`、`request_id` 和消息；服务端生成 `run_id`，日志、Trace、费用都以它关联。

## 2. SSE 事件协议

不要只推字符串 Token。定义 `run.started`、`message.delta`、`tool.started`、`tool.completed`、`run.failed`、`run.completed`。每条事件有递增 `seq`；断线重连可用 `Last-Event-ID` 或状态查询补偿。SSE 是单向流，需要双向实时控制时再评估 WebSocket。

请求格式错误 422；鉴权失败 401；无权限 403；幂等冲突 409；限流 429；上游暂不可用 503。流开始后不能改变 HTTP 状态码，错误须作为 `run.failed` 事件。

## 3. 项目任务

实现普通与流式接口，共享同一应用服务。测试事件顺序、中文编码、客户端断开、上游超时和敏感错误脱敏。

## 4. 练习与答案

### 练习 1：为何不把 LangChain 内部事件原样给前端？

**答案：**内部事件会随版本变化且可能含敏感上下文；对外应有自有、稳定、脱敏的协议。

### 练习 2：流输出一半时工具失败，能返回 HTTP 500 吗？

**答案：**响应头已发送，应发 `run.failed` 事件并结束流，同时记录可关联错误码。

## 5. 验收与资料

`curl -N` 可看事件；取消后上游终止；OpenAPI 与模型一致。参考 [FastAPI 异步](https://fastapi.tiangolo.com/async/)、[FastAPI 测试](https://fastapi.tiangolo.com/tutorial/testing/)、[MDN SSE](https://developer.mozilla.org/zh-CN/docs/Web/API/Server-sent_events)。

