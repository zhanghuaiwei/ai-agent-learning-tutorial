# Prompt Injection 与 Agent 安全

> 预计 9 小时｜产出：威胁模型、红队集和分层安全控制。

## 1. 主要威胁

- 直接/间接 Prompt Injection：用户、网页、文档或工具结果带恶意指令。
- 敏感信息泄露：Prompt、Trace、日志、向量库或 Tool 返回泄密。
- Excessive Agency：模型获得过多工具、权限或自治范围。
- 不安全输出处理：模型文本被当 SQL、HTML、Shell 或配置执行。
- Supply Chain：恶意包、模型、MCP Server 或提示模板。
- Unbounded Consumption：循环、超长输入、并发导致费用/资源耗尽。

## 2. 分层防御

身份与租户隔离 → 最小工具/Scope → 输入与文档视为不可信 → Tool Schema/参数验证 → 权限与资源校验 → 高风险动作可信确认 → 输出按目标上下文转义 → 预算/限流 → 审计/红队/响应。

Prompt 只能是其中一层。不要尝试“检测到 injection 就解决一切”；即使模型被诱导，也不应有能力越权。

## 3. 威胁建模

对每个资产（密钥、手册、告警、工单）、入口（用户、文件、MCP、API）、信任边界和副作用列威胁、控制、检测、残余风险。安全不变量包括：跨租户泄露为 0；无可信审批写入为 0；文档指令不能改变权限。

## 4. 项目任务

创建 30 条红队集：直接注入、文档注入、工具结果注入、数据外传、越权、DoS、伪审批。对每条给攻击路径、期望阻断层和自动判定。

## 5. 练习与答案

### 练习 1：隐藏 System Prompt 能保证安全吗？

**答案：**不能。提示可能泄露，且保密不是授权；关键边界必须由代码、身份、权限和审批保证。

### 练习 2：模型输出 Markdown 为什么还要处理？

**答案：**可能含恶意链接、HTML、脚本或指令。前端按不可信内容渲染，禁危险 HTML，链接和下载需策略。

## 6. 验收与资料

威胁模型覆盖数据流，红队失败可定位控制层。参考 [OWASP GenAI Top 10](https://genai.owasp.org/llm-top-10/)、[Prompt Injection](https://genai.owasp.org/llmrisk/llm01-prompt-injection/)、[NIST AI RMF](https://www.nist.gov/itl/ai-risk-management-framework)。

