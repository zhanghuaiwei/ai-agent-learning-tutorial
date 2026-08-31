# Dataset、Experiment 与版本对比

> 预计 6 小时｜产出：可复现的离线回归流程。

## 1. 数据集设计

每条 Example 包含输入、Reference Output/证据、标签和禁止行为。数据集按来源分：手工核心集、历史脱敏失败集、合成边界集、红队安全集。划分开发集与保留测试集，避免反复调 Prompt 过拟合测试集。

数据集与文档、Prompt、Graph、模型都要版本化。修复线上失败时先加入样本，再改系统，防止同类问题回归。

## 2. Experiment

每次实验只改变一个主要变量，记录基线和候选：质量、轨迹、延迟、Token、费用、安全。模型输出有随机性，对关键候选重复运行 2～3 次，查看方差而非只看均值。

发布门槛应包含“不退化”规则，例如总体任务成功不下降、越权始终为 0、P95 不超过 SLO 目标、成本增幅可解释。

## 3. 项目任务

导入 M3/M4 数据集，运行 Prompt A/B；按故障码、无答案、注入、审批分组对比，并写“保留/回滚”的决策。

## 4. 练习与答案

### 练习 1：所有线上失败都加入一个数据集好吗？

**答案：**应脱敏、去重、标注并按任务分层；否则数据污染、分布失衡且难以解释指标。

### 练习 2：候选平均分高 1% 就发布吗？

**答案：**不能直接决定。检查关键安全分组、方差、统计稳定性、成本延迟与具体退化样本。

## 5. 验收与资料

实验可重跑，参数和数据版本完整。参考 [Evaluation](https://docs.langchain.com/langsmith/evaluation)、[Manage datasets](https://docs.langchain.com/langsmith/manage-datasets)、[Run an evaluation](https://docs.langchain.com/langsmith/evaluate-llm-application)。
