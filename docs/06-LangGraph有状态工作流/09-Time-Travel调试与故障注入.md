# Time Travel 调试与故障注入

> 预计 7 小时｜产出：能从历史检查点复现失败并安全分叉实验。

## 1. Time Travel

Checkpoint 历史允许查看某步 State，并从旧状态分叉运行。它适合调试和假设验证，不等于修改真实业务历史。分叉运行默认使用沙箱/只读工具，禁止再次执行生产副作用。

记录 Graph 版本、节点版本、Prompt、模型、工具 Schema 和数据版本，否则旧 Checkpoint 可能无法由新代码解释。State Schema 变更需要迁移函数。

## 2. 故障注入矩阵

| 注入点 | 故障 | 期望 |
|---|---|---|
| 模型 | 超时/非法结构 | 有限重试或降级 |
| 检索 | 空结果/慢 | 拒答或只返回告警 |
| Checkpoint | 写失败 | 不宣称已暂停成功 |
| 审批 | 重复/过期 | 幂等拒绝 |
| 业务提交 | 成功后超时 | 查询幂等结果 |
| 流 | 客户端断开 | 按策略取消/继续 |

## 3. 项目任务

为每个注入场景保存 Trace、用户结果和恢复证明；从诊断前 Checkpoint 分叉对比两个 Prompt，但提交 Tool 替换为 Fake。

## 4. 练习与答案

### 练习 1：能否用 Time Travel 撤销已创建工单？

**答案：**不能。它重放执行状态，不回滚外部事实；撤销必须调用明确的业务补偿流程。

### 练习 2：为什么故障注入优于等线上出错？

**答案：**可重复验证最危险路径，提前发现恢复与幂等缺陷，并形成 Runbook。

## 5. 验收与资料

历史可检查，分叉无真实副作用，六类故障均有预期终态。参考 [Time travel](https://docs.langchain.com/oss/python/langgraph/use-time-travel)、[Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)。

