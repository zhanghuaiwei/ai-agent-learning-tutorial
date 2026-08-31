# 子图与多 Agent 模式

> 预计 6 小时｜目标：以职责和上下文边界决定拆分，而非追求“Agent 数量”。

## 1. 子图

子图适合封装可独立测试的流程，如知识检索、告警分析、工单草稿。父图只依赖清晰输入/输出，不共享所有 State。子图可继承或自有持久化策略，取决于是否需要独立记忆。

## 2. 多 Agent 模式

- Supervisor：中心路由到专业 Agent，适合任务边界明确。
- Handoff：当前 Agent 把对话控制权交给另一个。
- Parallel specialists：并行生成多个专业判断，再由确定性规则/聚合器合并。

每增加一个 Agent，都要新增独立 Prompt、工具权限、数据集、终止条件、上下文传递和成本观测。若只是代码复用，用普通函数或子图即可。

## 3. 项目选择

课程最终项目默认“单主图 + 检索子图 + 工单子图”，不强制多 Agent。可选加入一个只读“安全审查子图”，并用评测证明收益后才保留。

## 4. 练习与答案

### 练习 1：让三个 Agent 自由讨论能提高可靠性吗？

**答案：**未必，可能形成互相强化的错误并显著增费。需要独立证据、有限回合、明确聚合规则和对照实验。

### 练习 2：子图与 Tool 的区别？

**答案：**Tool 是 Agent 可选择的外部能力接口；子图是工作流内部的多步编排单元，可包含 Tool 和状态。

## 5. 验收与资料

每个拆分都有上下文、权限或可测试性理由。参考 [Subgraphs](https://docs.langchain.com/oss/python/langgraph/use-subgraphs)、[Multi-agent](https://docs.langchain.com/oss/python/langchain/multi-agent)。
