# MCP 与工程化 M6 验收

> 第 22 周里程碑｜目标：证明系统可接入、可防护、可降级、可部署。

## 1. 必交能力

- 固定版本的只读 MCP Server 与契约测试。
- Host 工具 Allowlist、租户鉴权、Schema 校验、超时和输出限制。
- Agent 威胁模型及不少于 30 条红队集。
- 重试所有权、限流、熔断、缓存、降级策略表。
- 每任务 Usage/成本、模型路由与费用异常告警；不设置教程金额上限。
- Dockerfile、CI、部署/回滚设计；本地无需 Docker。
- Agent 数据层可从空库执行 Alembic Migration；事务中不等待模型或远程 Tool。
- API、Thread、RAG、Cache 与 Tool 通过 Principal/Scope 执行多租户隔离。
- 远程 MCP 设计固定 Streamable HTTP/Authorization 规范版本，不使用 Token Passthrough。
- HTTP、Agent、检索、模型、Tool 与数据库可通过 Trace ID 关联。

## 2. 破坏性验收

恶意文档要求外传数据；MCP 返回注入文本；用户伪造租户；错误 Audience/Scope；篡改 Thread/Session；Tool 超时风暴；模型循环；费用异常飙升；CI 泄密扫描；远端成功后连接断开。所有场景必须有安全终态和可关联证据。

## 3. 练习与答案

### 练习 1：MCP 接入最大的简历价值是什么？

**答案：**不是“用过协议”，而是能说明 Host/Server 边界、版本迁移、授权、最小能力和故障隔离，并用契约与红队测试证明。

### 练习 2：没有本地 Docker 会影响面试吗？

**答案：**不会成为核心问题，只要能解释镜像、配置、健康检查、CI 构建、状态外置、发布与回滚，并有远程 CI 证据。

## 4. 通过标准

越权和未经批准写入为 0；跨租户读取/恢复成功数为 0；错误 Audience/Scope 的 MCP Token 通过数为 0；`alembic check` 通过；故障不会无限重试；Usage 与费用异常可观测；完成 Fake Model Smoke Load Test；CI 全绿；Runbook 能指导另一位开发者恢复服务。完整 Average Load 在第 23 周完成。通过后进入 Java 业务后端增强线。

## 对应资料

- [MCP Specification](https://modelcontextprotocol.io/specification/)
- [OWASP GenAI](https://genai.owasp.org/)
- [MCP Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [Alembic](https://alembic.sqlalchemy.org/en/latest/)
- [OpenTelemetry Python](https://opentelemetry.io/docs/languages/python/)
