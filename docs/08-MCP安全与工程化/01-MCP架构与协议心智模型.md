# MCP 架构与协议心智模型

> 预计 6 小时｜目标：理解协议边界，不把 MCP 误认为 Agent 框架。

## 1. MCP 是什么

MCP 用标准协议连接 Host、Client 与 Server。Server 暴露 Tools、Resources 等能力，Host 负责模型集成、连接、授权与用户控制。它解决互操作性，不自动解决 Agent 规划、业务权限或工具安全。

传统版本基于 JSON-RPC，常见传输为本地 `stdio` 与远程 Streamable HTTP。协议仍快速演进；本课程要求在 ADR 中写清使用的 Specification/SDK 版本，先读对应版本迁移说明，不照搬旧版 HTTP+SSE 示例。

## 2. 安全边界

- Server 只接收完成任务所需上下文，不应看到全部对话。
- Host 决定连接、能力允许列表和用户授权。
- Server 声明的 Tool 描述不是可信授权策略。
- 远程服务校验身份、Audience、Scope 和资源范围；禁止无验证转发 Token。
- 本地 stdio Server 也是可执行程序，安装来源和文件权限必须审查。

## 3. Tool、Resource 的选择

Tool 表示可调用动作或动态查询；Resource 表示由应用读取的上下文。把静态手册全部做 Tool 会增加模型选择负担；把有副作用动作伪装成 Resource 会模糊权限。

## 4. 项目任务

画出智维 Agent Host、MCP Client、只读设备 MCP Server、Java API 的信任边界；列出每条连接的身份、数据、超时与审计字段。

## 5. 练习与答案

### 练习 1：接入 MCP Server 后工具是否可直接信任？

**答案：**不能。仍要审查来源、Schema、权限、副作用、数据去向和返回内容；Host 只暴露最小工具集。

### 练习 2：MCP 能替代 LangGraph 吗？

**答案：**不能。MCP 是能力连接协议，LangGraph 是有状态编排；两者可组合。

## 6. 验收与资料

能解释 Host/Client/Server 责任，仓库固定协议和 SDK 版本。参考 [MCP Architecture](https://modelcontextprotocol.io/specification/2025-06-18/architecture)、[2026-07-28 版本说明](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)、[Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)。

