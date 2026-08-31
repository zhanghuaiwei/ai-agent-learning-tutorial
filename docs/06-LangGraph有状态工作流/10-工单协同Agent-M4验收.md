# 工单协同 Agent M4 验收

> 第 15 周里程碑｜目标：完成可暂停、可恢复、无重复副作用的核心业务闭环。

## 1. 必交能力

- 显式 State、Node、Edge、Reducer 与版本。
- 并行收集上下文，有界查询改写。
- 持久化 Checkpoint、Thread 所有权验证、重启恢复。
- 工单草稿 Human-in-the-loop；审批绑定动作摘要。
- 提交幂等、失败恢复、故障注入与只读 Time Travel。
- 子图拆分有明确理由，不以多 Agent 数量为目标。

## 2. 定量门槛

100 次 Fake 故障运行均到合法终态；重复审批/恢复不重复建单；跨租户 Thread 访问 0 成功；所有循环在预算内终止；关键节点 P95、错误率和费用可查。

## 3. 练习与答案

### 练习 1：如何用一句话说明项目企业级价值？

**答案：**它不是自动聊天，而是在权限、证据、审批、幂等和可恢复边界内，把设备知识查询推进到可审计的工单协同。

### 练习 2：最值得展示的失败场景是什么？

**答案：**业务提交成功但网络超时，Graph 恢复后利用幂等键取得原工单而不重复创建，能体现分布式可靠性。

## 4. 演示顺序

正常诊断 → 暂停审批 → 重启服务 → 恢复提交 → 模拟成功后超时 → 证明无重复 → 展示 Trace/Checkpoint。通过后进入 LangSmith，把“我觉得稳定”变成可测证据。

## 对应资料

- [LangGraph Durable execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)
- [LangGraph Interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts)
