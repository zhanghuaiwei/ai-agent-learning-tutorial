# State、Node、Edge 与 Reducer

> 预计 7 小时｜产出：类型明确、更新可预测的工单 Graph 骨架。

## 1. State 设计

State 只放跨节点需要的数据：消息、用户/租户引用、设备快照版本、证据 ID、诊断结果、工单草稿 ID、审批状态、错误与预算。不要把数据库连接、SDK Client 或整个文档对象放入 State。

```python
class WorkOrderState(TypedDict):
    messages: Annotated[list, add_messages]
    equipment_id: str
    evidence_ids: list[str]
    risk_level: str
    draft_id: str | None
    approval: str | None
    error_code: str | None
```

Node 接收 State，返回“局部更新”，不要原地随意修改。Reducer 决定并发或多次更新如何合并；列表若无 Reducer 可能覆盖，有 Reducer 又可能重复，必须按字段语义选择。

## 2. Edge

普通 Edge 固定连接；Conditional Edge 根据路由函数选择目标；入口与终点显式定义。路由函数应短小、确定、可单测，返回有限枚举，不让模型输出任意节点名。

## 3. 项目任务

定义 `WorkOrderState` 与至少 7 个节点的输入/输出字段表；为 Reducer 写并发更新、重复更新和空更新测试。

## 4. 练习与答案

### 练习 1：为什么 State 不应塞入所有历史对象？

**答案：**会让序列化、持久化、隐私、迁移和 Token 管理失控；保存必要事实或引用，权威对象按需查询。

### 练习 2：节点直接修改数据库后只返回成功标志有何风险？

**答案：**重放节点可能重复副作用；应设计幂等写、记录业务 ID，并明确提交边界。

## 5. 验收与资料

State 可序列化；字段有所有者；Reducer 行为有测试。参考 [Graph API](https://docs.langchain.com/oss/python/langgraph/graph-api)、[Use the graph API](https://docs.langchain.com/oss/python/langgraph/use-graph-api)。

