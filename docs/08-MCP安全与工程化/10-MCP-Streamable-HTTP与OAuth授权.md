# MCP Streamable HTTP 与 OAuth 授权

> 补缺章节｜预计 7 小时｜规范基线：MCP 2025-11-25｜产出：可说明远程 MCP 传输、会话、鉴权和威胁边界。

## 1. 为什么只会写本地 MCP Tool 不够

本地 `stdio` Demo 能证明工具协议可用，却不能回答企业远程接入的核心问题：

- 客户端如何发现并连接服务器；
- HTTP 断线后消息是否需要恢复；
- 谁签发访问令牌，令牌是否发给了正确资源；
- MCP Server 如何把 Scope 映射到具体 Tool/Resource；
- 为什么不能把上游 Token 原样透传给第三方服务；
- 如何防止 DNS Rebinding、Session 劫持和跨租户访问。

本章仍以只读设备目录 Server 为主，不把 MCP 误用为服务内部所有 API 的替代品。

## 2. 规范版本必须固定

MCP 演进速度快。课程实现统一记录：

```text
protocol_version = 2025-11-25
python_sdk_version = 由 uv.lock 固定
transport = stdio | streamable-http
authorization_profile = none | oauth
```

不要把不同版本示例拼在一起。尤其要识别：旧的独立 `HTTP+SSE` Transport 已被 Streamable HTTP 取代；Streamable HTTP 内部仍可使用 SSE 发送多个消息，但二者不是同一个协议版本。

## 3. stdio 与 Streamable HTTP

| 维度 | stdio | Streamable HTTP |
| --- | --- | --- |
| 进程关系 | Client 启动本地 Server 子进程 | Server 独立部署、处理多个连接 |
| 消息载体 | stdin/stdout，每行 JSON-RPC | HTTP POST/GET，可返回 JSON 或 SSE |
| 典型用途 | 本地开发、桌面工具、单机集成 | 远程服务、共享能力、企业网关 |
| 凭证 | 通常从环境或进程配置获得 | 按 MCP Authorization 规范使用 OAuth |
| 主要风险 | 子进程权限、环境变量、stdout 污染 | Origin、网络、Token、Session、重放 |

`stdio` Server 的 stdout 只能输出合法 MCP 消息，日志写 stderr。远程 Server 应提供单一 MCP Endpoint，例如 `https://mcp.example.com/mcp`，支持规范要求的 HTTP 方法和 Content-Type。

## 4. Streamable HTTP 关键语义

Client 发送 JSON-RPC 消息时使用新的 HTTP POST；请求响应可能是一个 JSON，也可能建立 SSE Stream。Client 必须理解二者，而不能假设所有 Tool 都只返回同步 JSON。

需要记住的协议元素：

- 初始化后协商 Protocol Version；后续 HTTP 请求携带 `MCP-Protocol-Version`；
- Stateful Server 可返回 `MCP-Session-Id`，Client 后续请求必须安全携带；
- SSE 事件可包含唯一 `id`，断线后 Client 使用 `Last-Event-ID` 请求恢复；
- 断线本身不等于取消，取消应发送明确的取消通知；
- 本地 HTTP Server 绑定 `127.0.0.1`，不要默认暴露 `0.0.0.0`；
- Server 校验 `Origin`，非法 Origin 返回 403，防止 DNS Rebinding。

Session ID 是路由运行上下文的游标，不是用户身份，也不能替代 Access Token。Server 必须把 Session 与已验证 Principal 绑定，禁止拿 A 用户 Token 恢复 B 用户 Session。

## 5. OAuth 角色模型

在受保护的远程 MCP 场景中：

```text
Resource Owner：用户
MCP Client：代表用户访问能力的客户端
Authorization Server：认证用户并签发 Access Token
MCP Server：OAuth Resource Server，验证 Token 并提供 Tool/Resource
```

MCP Server 不是必须自己实现 Authorization Server。企业环境通常复用 IdP，通过 Protected Resource Metadata 和 Authorization Server Metadata 完成发现。

典型流程：

1. Client 请求受保护的 MCP Endpoint；
2. Server 返回 401，并通过 `WWW-Authenticate` 指向 Protected Resource Metadata；
3. Client 发现 Authorization Server、支持的 Scope 和注册方式；
4. 用户授权，Client 使用 Authorization Code + PKCE 获取 Token；
5. Client 请求 Token 时绑定目标 MCP Resource；
6. MCP Server 验证签名、Issuer、Audience/Resource、有效期和 Scope；
7. Server 再按用户、租户、Tool 和 Resource 做细粒度授权。

OAuth 只解决授权框架；资源所有权和业务规则仍由 MCP Server/业务服务处理。

## 6. Scope 设计

不要只设计一个无限权限的 `mcp:all`：

```text
equipment:read
alarm:read
manual:search
workorder:draft
workorder:submit
```

Server 返回工具列表时可以根据 Scope 做最小暴露；执行 Tool 时仍须再次检查 Scope 和资源范围。读取与写入分开，高风险写操作还要经过 Human-in-the-loop。

动态 Scope 不应由模型决定。模型只能在已授权工具集合中选择，不能自行申请更高权限；需要 Step-up Authorization 时，由可信 UI/Client 与用户完成。

## 7. 禁止 Token Passthrough

假设 MCP Server 需要调用 Java Business API：

```text
用户给 MCP Server 的 Token
        ≠
MCP Server 调 Java API 的 Token
```

不要把收到的 MCP Token 原样转发给下游服务，除非协议和信任模型明确支持 Token Exchange。直接透传会造成 Audience 混乱、权限扩大、审计主体错误和 Confused Deputy 风险。

更安全的方式：

- MCP Server 验证用户 Token；
- 根据业务策略生成委托上下文；
- 使用面向 Java API 的服务凭证或标准 Token Exchange；
- 下游同时获得调用服务身份和最终用户/租户审计上下文；
- 每个 Token 只用于其声明的 Audience/Resource。

## 8. Server 安全检查表

### 网络与协议

- HTTPS；本地开发仅绑定 localhost；
- 校验 Origin，不允许通配全部来源；
- 限制请求体、消息大小、并发、Deadline 和 Session 数；
- Protocol Version 不支持时明确返回错误；
- Session ID 随机、不可预测、可过期、可撤销；
- Resume/Redelivery 不重复执行有副作用 Tool。

### 身份与授权

- 验证 Issuer、Audience/Resource、过期时间、Scope；
- Token 与 Session、租户和用户绑定；
- Tool List 和 Tool Call 都执行最小权限；
- Tool 内部再次验证资源归属；
- 不接受 Prompt 提供的身份、Scope 和审批状态；
- 日志、Trace、Tool Result 不泄漏 Token。

### 工具与数据

- 参数通过 JSON Schema 和业务规则双重验证；
- Tool 描述和返回值视为潜在注入载体；
- 写操作具备幂等键、审批、审计和结果查询；
- Resource URI 防止路径穿越、SSRF 和跨租户枚举；
- 第三方 MCP Server 先审查来源、权限、数据去向和更新机制。

## 9. 项目任务

为同一个只读设备目录 Server 建立两种配置：

```text
local:
  transport: stdio
  auth: environment/test principal

remote-design:
  transport: streamable-http
  auth: oauth resource server
  scopes: equipment:read, alarm:read
  origin_allowlist: explicit
  session_ttl: documented
```

由于本机不运行 Docker，远程模式可以通过以下证据完成：

1. SDK 的内存/测试 Client 集成测试；
2. HTTP 层 401/403/Protocol Version/Origin 测试；
3. CI 中启动临时 Server 做 Smoke Test；
4. Threat Model 与 Sequence Diagram；
5. 可选部署到临时托管环境，使用合成数据验证。

## 10. 练习与答案

### 练习 1：Streamable HTTP 是否表示不再使用 SSE？

**答案：**不是。它取代的是旧的独立 HTTP+SSE Transport，但自身允许 HTTP 响应使用 SSE 发送多个 Server Message。必须区分协议名称和底层流式机制。

### 练习 2：为什么 Session ID 不能当登录凭证？

**答案：**Session ID 只定位协议会话/运行上下文，不证明调用者身份和权限。每次访问仍需验证 Token，并确认 Session 属于该 Principal。

### 练习 3：MCP Server 收到 `equipment:read` Token，可以传给 Java API 吗？

**答案：**不能默认透传。该 Token 可能只以 MCP Server 为 Audience。应使用下游接受的服务凭证或标准委托/交换机制，同时保留用户审计上下文。

## 11. 验收标准

- 能画出 Client、MCP Resource Server、Authorization Server 与 Java API 的信任边界；
- 能解释 stdio、旧 HTTP+SSE 和 Streamable HTTP 的区别；
- Origin、错误 Protocol Version、无 Token、错误 Audience、缺 Scope 均有负向测试；
- Session 无法跨用户/租户恢复，断线重投不重复副作用；
- Tool List、Tool Call 和业务资源均执行授权；
- ADR 固定 MCP Specification 与 Python SDK 版本，未混用不同版本示例。

## 12. 资料来源

- [MCP 2025-11-25：Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [MCP 2025-11-25：Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [MCP Security Best Practices](https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices)
- [OAuth Protected Resource Metadata（RFC 9728）](https://www.rfc-editor.org/rfc/rfc9728)
- [OAuth Authorization Server Metadata（RFC 8414）](https://www.rfc-editor.org/rfc/rfc8414)

