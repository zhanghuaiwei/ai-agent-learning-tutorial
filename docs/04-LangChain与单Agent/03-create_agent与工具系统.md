# create_agent 与工具系统

> 预计 8 小时｜产出：设备查询与工单草稿单 Agent。

## 1. 最小实现

```python
from langchain.agents import create_agent

agent = create_agent(
    model=model,
    tools=[get_alarm, search_manual, create_work_order_draft],
    system_prompt=SYSTEM_PROMPT,
)

result = await agent.ainvoke({
    "messages": [{"role": "user", "content": "查询 EQ-001 的高危告警"}]
})
```

这段代码只解决动态 Tool Loop，不自动解决权限、租户隔离、业务事务和对外响应。Tool 函数仍应调用应用服务，而不是把数据库连接交给模型。

## 2. 工具设计准则

- 一个工具一个清晰能力，参数尽量少且强类型。
- 描述包含使用时机、禁止场景、错误和副作用。
- Tool 通过运行时 Context 获取 `user_id/tenant_id/roles`，不要让模型填写身份。
- 返回面向模型的紧凑结果；完整对象留在服务端。
- 写工具默认先生成 Draft，再由可信事件确认。

工具太多会增加选择困难。按任务动态暴露最小工具集，而非把公司全部 API 塞给一个 Agent。

## 3. 项目任务

迁移 M1 三个工具；实现基于角色的工具过滤、参数校验、统一 Tool Error；对比 Tool 描述三个版本的选择准确率。

## 4. 练习与答案

### 练习 1：租户 ID 能作为 Tool 参数让模型填写吗？

**答案：**不能信任。租户 ID 来自服务端鉴权上下文，工具内部强制注入并校验资源范围。

### 练习 2：工具越细越好吗？

**答案：**也不是。过细会增加回合与失败面；以可独立授权、可清晰描述、可安全重试的业务能力为边界。

## 5. 验收与资料

模型无法越权选择隐藏工具；Tool 错误不崩溃且可追踪。参考 [Agents](https://docs.langchain.com/oss/python/langchain/agents)、[Tools](https://docs.langchain.com/oss/python/langchain/tools)、[Runtime](https://docs.langchain.com/oss/python/langchain/runtime)。

