# ADR 架构决策记录指南

> 目标：把“为什么这样设计”变成可审查的项目资产。

## 1. 模板

```markdown
# ADR-00X：决策标题
状态：提议/接受/废弃/替代
日期与负责人：
背景与约束：
决策驱动因素：
候选方案：
决定：
正面/负面后果：
验证证据：
回滚或复审条件：
```

## 2. 项目必写 ADR

1. Python Agent + 可选 Java 业务服务。
2. LangChain 单 Agent 到 LangGraph 的升级边界。
3. 2-step/Agentic/Hybrid RAG 选择。
4. Chroma 本地与生产 pgvector 目标。
5. 千问/DeepSeek 模型路由。
6. Human-in-the-loop 与禁止自动执行范围。
7. LangSmith 数据采集与隐私。
8. MCP 版本和只读范围。

ADR 记录当时上下文，不要求“永远正确”。被数据推翻时新建 ADR 替代旧记录，保留历史。

## 3. 练习与答案

### 练习 1：ADR 能否只写最终方案优点？

**答案：**不能。必须写候选、代价和负面后果，否则无法审查取舍。

### 练习 2：什么情况下复审模型选型 ADR？

**答案：**价格/版本变化、质量或延迟 SLO 失守、新任务分布、供应商风险或数据合规要求改变时。

## 4. 验收与资料

至少 8 份 ADR，每份有证据或明确待验证项。参考 [ADR GitHub](https://adr.github.io/)、[AWS ADR 指南](https://docs.aws.amazon.com/prescriptive-guidance/latest/architectural-decision-records/welcome.html)。

