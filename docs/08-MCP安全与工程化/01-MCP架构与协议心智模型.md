# MCP 架构与协议心智模型

> 预计 6 小时｜目标：建立 Host / Client / Server 的协议边界心智模型，不把 MCP 误认为 Agent 框架或安全边界。

## 1. 本章从哪里开始

很多人的第一个 MCP 错误，是在没分清「协议」「框架」「安全边界」三者之前就开始写 Server。结果是把一个工具调用协议，误当成能自动解决规划、权限和安全的银弹。本章先建立心智模型，后续每一章都在这张图上叠加：第 2 章实现只读 Server，第 3 章补安全，第 4 章补可靠性，第 5 章补成本，第 7 章做 M6 验收。

本章是第 8 阶段（MCP 安全与工程化）的第 1 章。先回答一个判断题：

- MCP 是**能力连接协议**：约定 Host 如何发现、协商、调用 Server 暴露的 Tools / Resources。
- MCP **不是** Agent 框架：它不编排状态机、不管理消息历史、不负责循环检测。
- MCP **不是**安全边界：Server 声明的 Tool 描述不是授权策略，协议握手成功也不代表业务允许。

## 2. 本章完成标准（通过门槛）

- 能画出智维 Agent 的 Host、MCP Client、只读设备 MCP Server、Java 业务 API 四者之间的信任边界；
- 能背出 JSON-RPC 层、initialize 协商、tools/list、tools/call、resources 各自解决什么问题；
- 能用一句话说清 Tool 与 Resource 的选择边界，以及「静态手册该做成 Tool 还是 Resource」的取舍；
- 能在 ADR 中写死 MCP Specification（2025-11-25）与 Python SDK 版本，不混用旧版示例；
- 能回答「MCP 能否替代 LangGraph」「接入后工具能否直接信任」两个经典判断题。

## 3. MCP 是什么、不是什么

MCP（Model Context Protocol）用标准协议连接三个角色：

| 角色 | 责任 | 智维 Agent 中的例子 |
| --- | --- | --- |
| Host | 模型集成、连接管理、用户授权与同意、能力允许列表 | FastAPI + LangGraph Agent 服务 |
| Client | 与单个 Server 的协议会话，维护握手、请求与生命周期 | 每个 MCP Server 对应的连接适配器 |
| Server | 暴露 Tools / Resources / Prompts 等能力 | 只读设备 MCP Server（`search_manual`/`get_alarm`） |

Server 暴露的能力由协议元数据描述，但**描述不是授权**：一个 Tool 写「只读查询设备」，实际可能带副作用或跨租户返回数据。Host 必须自行校验 Schema、权限、数据去向与返回内容。

它解决的核心问题是**互操作性**：让不同厂商的模型客户端与工具服务端用同一套消息格式对接，避免每接入一个新工具都写一个 bespoke adapter。它**不自动解决**的，恰恰是 Agent 工程里最难的部分——规划、业务权限、工具安全、执行边界与成本治理。

## 4. 协议栈：JSON-RPC 之上

MCP 消息基于 JSON-RPC 2.0。一个请求有 `jsonrpc`、`id`、`method`、`params`；响应有 `result` 或 `error`；还有不带 `id` 的 `notification`（通知不要求响应）。

### 4.1 initialize 协商

Client 先发 `initialize` 声明自己支持的协议版本与能力，Server 回以自己支持的范围：

```json
// Client → Server
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-11-25",
    "capabilities": { "tools": {}, "resources": {} },
    "clientInfo": { "name": "smart-maintenance-host", "version": "1.0.0" }
  }
}
```

```json
// Server → Client
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-11-25",
    "capabilities": { "tools": { "listChanged": false } },
    "serverInfo": { "name": "readonly-device-mcp", "version": "1.2.0" }
  }
}
```

协商成功后 Client 发送 `notifications/initialized`。**版本不支持时必须明确失败**，不能静默降级到旧语义。协议具体字段与错误对象以 2025-11-25 规范为准。

### 4.2 能力发现与调用

`tools/list` 返回 Tool 名称、描述与 JSON Schema；`tools/call` 用名称 + 参数触发执行：

```json
{ "jsonrpc": "2.0", "id": 2, "method": "tools/list" }
```

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "get_alarm",
    "arguments": { "equipment_id": "eq-turbine-09" }
  }
}
```

`resources/list` / `resources/read` 用于读取应用上下文（如手册 URI）。`prompts/*` 用于服务端提供的模板化提示，本课程基本不用，避免把提示模板能力误当成授权通道。

## 5. Tool 与 Resource 的选择

这是一道反复被问的边界题：

| 维度 | Tool | Resource |
| --- | --- | --- |
| 语义 | 可调用动作 / 动态查询 | 由应用读取的上下文 |
| 典型调用 | `search_manual(query)`、`get_alarm(equipment_id)` | `manual://section/…`、设备目录 URI |
| 模型负担 | 多一个选择点，描述要可区分 | 模型按需订阅/读取 |
| 错误使用 | 把有副作用动作伪装成 Resource，模糊权限 | 把静态手册全做成 Tool，增加选择负担 |

智维 Agent 的取舍：手册检索是**动态查询**（按用户问题匹配片段），用 `search_manual` Tool；告警查询是**参数化读取**，用 `get_alarm` Tool；而一份「已确定要读的规范章节」更适合用 Resource URI 表达「按引用取上下文」。原则是：**动作和查询归 Tool，被读取的上下文归 Resource，副作用必须显式**。

## 6. 安全边界：Server 不该看到什么

- Server 只接收完成任务所需的**最小上下文**，不应看到全部对话历史或无关租户数据。
- Host 决定连接建立、能力允许列表和用户授权；Server 不能越过 Host 直接向用户要更高权限。
- Server 声明的 Tool 描述是**元数据，不是可信授权策略**。
- 远程服务校验身份、Audience、Scope 和资源范围；禁止无验证转发 Token（Token Passthrough，详见第 10 章）。
- 本地 stdio Server 也是可执行程序：安装来源、文件权限、环境变量与 stdout 输出都必须审查。

## 7. 传输：stdio 与 Streamable HTTP

| 维度 | stdio | Streamable HTTP |
| --- | --- | --- |
| 进程关系 | Client 启动本地子进程 | Server 独立部署、服务多连接 |
| 消息载体 | stdin/stdout，逐行 JSON-RPC | HTTP POST/GET，可返回 JSON 或 SSE |
| 典型场景 | 本地开发、单机集成 | 远程共享能力、企业网关 |
| 主要风险 | 子进程权限、stdout 污染 | Origin、Token、Session、重放 |

旧版独立的 `HTTP+SSE` Transport 已被 Streamable HTTP 取代，但 Streamable HTTP 内部仍可用 SSE 发送多个消息，二者不是同一个协议版本。本课程本机练习优先 stdio；远程设计在 ADR 中写清传输与授权版本，不照搬旧示例。

## 8. 版本固定与 ADR

MCP 演进速度快，混用不同版本示例是 CI 与线上最隐蔽的坑。本课程统一：

```text
protocol_version = 2025-11-25
python_sdk_version = 由 uv.lock 固定
transport = stdio | streamable-http
authorization_profile = none | oauth
```

写 ADR 时固定 Specification 版本与 SDK 版本，并先读对应版本的迁移说明。任何「这段代码是从旧教程抄的」都必须重写为 2025-11-25 语义。

## 9. 项目任务

1. 画出智维 Agent 的 Host、MCP Client、只读设备 MCP Server、Java 业务 API 的信任边界图。
2. 为每条连接列出字段：身份、数据方向、超时、审计标识（`request_id`/`trace_id`/`tenant_id`）。
3. 用一段 JSON-RPC 示例完整走一遍 `initialize → tools/list → tools/call`，并标注每个字段属于协议层还是业务层。
4. 写一份 `docs/adr/0004-MCP协议与SDK版本.md`（简版），固定 2025-11-25 与 SDK 版本。

## 10. 常见错误与诊断顺序

### 10.1 把 MCP 当 Agent 框架

症状：想用 MCP 管理消息历史、循环检测、执行边界。诊断顺序：先判断这属于「状态编排」还是「能力连接」——编排归 LangGraph，连接归 MCP；两者组合，不互相替代。

### 10.2 混用旧版 HTTP+SSE 示例

症状：远程示例里出现旧 Transport 字段，握手失败或行为不一致。诊断顺序：grep 仓库确认没有旧版本示例，统一为 Streamable HTTP + 2025-11-25 语义。

### 10.3 把 Tool 描述当授权

症状：靠「描述里写只读」来保证安全。诊断顺序：确认授权是否落到 Host 允许列表 + Server 侧 Scope/租户校验，而不是文档字符串。

## 11. 练习题与答案

### 练习 1：接入 MCP Server 后工具是否可直接信任？

**答案：**不能。仍要审查来源、Schema、权限、副作用、数据去向和返回内容；Host 只暴露最小工具集，并把 Server 描述当作不可信元数据。

### 练习 2：MCP 能替代 LangGraph 吗？

**答案：**不能。MCP 是能力连接协议，LangGraph 是有状态编排；两者可组合。MCP 不负责循环检测、消息历史、权限和成本治理。

### 练习 3：静态手册应该全做成 Tool 吗？

**答案：**不该。静态手册做 Resource（按 URI 引用）或做 `search_manual` 这种动态查询 Tool；全做成独立 Tool 会增加模型选择负担。有副作用的动作更不能伪装成 Resource。

## 12. 工程挑战

1. 用内存 Client 完成一次真实 `initialize` 握手，断言协商出的 `protocolVersion == "2025-11-25"`。
2. 写一个「Tool 描述谎称只读、但 Schema 暴露写参数」的恶意 Server，证明 Host 不能靠描述信任它。
3. 对比 stdio 与 Streamable HTTP 在同一 Server 上的消息形态差异，写进 ADR。

## 13. 面试追问

### 13.1 MCP 和 Function Calling 有什么区别？

回答框架：Function Calling 是模型厂商让模型输出结构化工具调用的机制，不定义服务端连接与授权；MCP 是跨 Host/Server 的能力连接协议，解决的是互操作、发现与协商。二者不在同一层，MCP Server 内部仍可能用 Function Calling 风格执行。

### 13.2 为什么协议版本必须固定？

回答框架：MCP 演进快，旧 HTTP+SSE Transport 与 Streamable HTTP 语义不同；混用会导致握手失败或安全语义漂移。工程上必须锁定 Specification + SDK 版本并写 ADR，本课程基线为 2025-11-25。

## 14. 本章复盘模板

```text
完成日期：
实际投入小时：
能否画出 Host/Client/Server/Java API 四者信任边界：
能否背出 JSON-RPC、initialize、tools/list、tools/call、resources 的职责：
Tool 与 Resource 的取舍是否能用智维 Agent 例子讲清：
安全边界 5 条是否都理解（最小上下文/允许列表/描述非授权/禁 Token 透传/stdio 审查）：
ADR 是否固定 2025-11-25 与 SDK 版本：
仍不理解的问题：
```

## 15. 官方资料与中文阅读指引

- [MCP 2025-11-25：Architecture](https://modelcontextprotocol.io/specification/2025-11-25/architecture)：重点看 Host/Client/Server 角色与能力模型，用于 §3；
- [MCP 2025-11-25：Basic Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)：重点看 stdio 与 Streamable HTTP 的差异，用于 §7；
- [MCP 2025-11-25：Server Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)：Tool Schema 与调用语义，用于 §4.2；
- [MCP 版本说明](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)：只用于理解版本演进节奏，课程实现仍以 2025-11-25 为准。

中文阅读重点：先读 Architecture 建立三角色边界，再读 Transports 分清 stdio 与 Streamable HTTP；Tool/Resource 取舍对照 §5 表格自查。具体 JSON-RPC 字段以 2025-11-25 规范为准，不凭记忆写。

## 16. 下一章入口

本章建立了「协议是连接、不是框架、更不是安全边界」的心智模型。下一章（第 8 阶段第 2 章）把这张图落到代码：实现只读设备 MCP Server，暴露 `search_manual`/`get_alarm` 两个只读 Tool，并预留 `create_work_order_draft` 的审批门，为 M6 验收脚本提供可调用的契约。
