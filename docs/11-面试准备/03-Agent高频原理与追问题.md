# Agent 高频原理与追问题

> 使用方法：先口述 90 秒，再看答案补缺；每题继续追问失败路径和取舍。

## 1. Agent 与 Workflow 有何区别？

**答案要点：**Agent 让模型在边界内动态选动作；Workflow 由代码预定路径。生产常混合：语义判断用模型，权限、审批、事务、停止由确定性系统控制。

## 2. Function Calling 如何执行？

**答案要点：**模型只生成工具建议和参数；应用校验 Schema、身份、权限与副作用，执行后返回 Tool Message。追问：未知工具、参数修复、幂等、超时。

## 3. 为什么需要 LangGraph？

**答案要点：**显式 State/Node/Edge、Checkpoint、Interrupt、恢复和故障重放，适合跨请求、审批和复杂流程。简单工具循环用 `create_agent` 即可。

## 4. Memory 有哪些？

**答案要点：**Thread 短期状态、跨 Thread 长期 Store、业务数据库事实；分别有作用域、来源、保留和删除。摘要不可替代权威事实。

## 5. 如何防 Agent 死循环？

**答案要点：**最大步数、总期限、Token/费用、重复动作检测、工具次数、不可恢复错误、人工中断；监控步数分布并以数据调整。

## 6. 多 Agent 何时有价值？

**答案要点：**职责、上下文和工具确实可隔离且能独立评测时；否则子图/函数更简单。必须量化质量收益、成本、延迟与故障面。

## 7. Agent 怎么测试？

**答案要点：**确定性单元/契约/E2E + 概率性数据集评测；既测最终答案，也测 Tool 轨迹、权限、终止、副作用、成本和安全。

## 8. 练习与答案

### 练习：选两题，各追加三个追问。

**示例答案：**“为什么选择”“失败怎么办”“如何证明”是通用追问；回答必须落到本项目的 ADR、故障注入和指标。

## 资料

- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)
- [LangGraph Overview](https://docs.langchain.com/oss/python/langgraph/overview)
- [MCP Architecture](https://modelcontextprotocol.io/specification/2025-11-25/architecture)

