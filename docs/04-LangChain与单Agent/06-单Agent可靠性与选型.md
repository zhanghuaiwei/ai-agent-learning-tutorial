# 单 Agent 可靠性与选型

> 预计 5 小时｜目标：知道何时用 Agent，何时退回确定性代码。

## 1. 决策表

| 问题 | 优先方案 |
|---|---|
| 路径固定、规则稳定 | 普通函数/Workflow |
| 需要从少量工具动态选择 | 单 Agent |
| 有审批、暂停恢复、复杂状态 | LangGraph |
| 多领域上下文隔离且可独立评测 | 子图/少量多 Agent |
| 只是检索后回答 | 2-step RAG，未必需要 Agent |

先使用最小可控方案。多 Agent 不是高级版单 Agent，会增加提示、路由、上下文、观测、费用和故障组合。

## 2. 可靠性执行边界

为一次任务设：最大模型调用 4 次、最大 Tool Call 6 次、总时限 20 秒、相同动作最多 2 次；费用记录到 Trace 并设置异常增长告警，但不设置教程累计金额上限。数值不是固定答案，应从真实 Trace 调整。

降级路径：强模型失败转小模型不一定合理；更常见是返回已取得的证据、只读结果或工单草稿，引导人工继续。

## 3. 项目任务

为 30 个任务标注应使用普通函数、RAG、单 Agent 或 Graph；实现步骤、Token、Deadline 边界和循环检测，输出选型 ADR。

## 4. 练习与答案

### 练习 1：设备状态查询需要 Agent 吗？

**答案：**单一确定查询通常不需要；自然语言需要组合多个查询并解释时才考虑 Agent。

### 练习 2：多 Agent 是否自动提升质量？

**答案：**否。只有职责、上下文、工具和评测边界确实可分时才可能获益，否则增加错误传递和费用。

## 5. 验收与资料

每个 Agent 用例都有“为何不是普通代码”的理由、步骤/Token/Deadline 运行边界和降级路径。参考 [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)、[LangGraph Workflows and agents](https://docs.langchain.com/oss/python/langgraph/workflows-agents)。
