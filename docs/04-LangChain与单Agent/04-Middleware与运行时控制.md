# Middleware 与运行时控制

> 预计 7 小时｜产出：模型、工具、Prompt 和安全策略的横切控制层。

## 1. Middleware 适用场景

Middleware 可在模型或工具调用前后执行：动态选择模型、裁剪消息、注入运行时 Prompt、拦截 Tool Call、重试、记录指标、加入 Human-in-the-loop。它适合横切策略，不应藏入复杂业务流程。

推荐顺序：请求身份解析 → 工具白名单 → 上下文裁剪 → 模型路由 → 调用 → 输出/费用记录。顺序本身是架构决策，应写测试。

## 2. 运行时 Context

Context 是本次运行不可由模型篡改的依赖。当前官方示例常用 `dataclass` 定义 `context_schema`；Agent 自定义 State 则使用扩展 `AgentState` 的 `TypedDict`，不要混成同一个对象：

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class RuntimeContext:
    user_id: str
    tenant_id: str
    scopes: frozenset[str]
    request_id: str
```

用户消息不能覆盖这些字段。长期会变化的业务状态应从可信服务查询，不要永久复制进 Prompt。

## 3. 模型路由

用确定性规则先路由：普通问答可选低延迟模型，复杂多工具规划可选强模型。路由规则记录原因并接受数据集评测；费用作为对比指标，而不是教程设置的模型禁用条件。

## 4. Hook 顺序必须写进测试

多个 Middleware 的执行不是简单地全部从上到下：

- `before_*` 按声明顺序执行；
- `after_*` 按相反顺序执行；
- `wrap_*` 像函数调用一样嵌套，列表中靠前的 Middleware 位于外层。

因此“先脱敏再记录”和“先记录再脱敏”的结果完全不同。建议顺序：入口身份/请求元数据 → 安全过滤 → Context 构建/裁剪 → 模型路由 → 调用 → 输出校验 → 脱敏观测。用一个记录 Hook 名的 Fake Middleware 测试真实顺序，不靠阅读代码猜测。

Middleware 运行在 `create_agent` 返回的 LangGraph 内。将这个 Agent 放入更大的 StateGraph 时，Middleware 仍会执行；要避免外层 Graph 和内层 Middleware 对同一调用重复重试。

## 5. 项目任务

实现四个 Middleware：注入 Prompt 版本、按角色过滤工具、超过 Token 预算裁剪上下文、记录模型调用费用。为执行顺序写集成测试。

## 6. 练习与答案

### 练习 1：权限校验放 Prompt 还是 Middleware？

**答案：**Prompt 可提醒模型，但真正授权必须在工具/服务端；Middleware 可提前过滤，形成纵深防御。

### 练习 2：何时不该使用 Middleware？

**答案：**需要显式状态、审批分支、补偿和恢复的业务流程应放 LangGraph/应用服务，隐藏在中间件中会难以理解和测试。

### 练习 3：HTTP Client、Middleware、Provider SDK 都各重试两次，会发生什么？

**答案：**最坏情况会乘法放大。必须指定唯一重试所有者，让其他层关闭重试或只处理互不重叠的错误；写操作还需幂等。

## 7. 验收与资料

Context 不可由用户伪造；Hook 顺序有集成测试；同一错误不会被多层重试放大；路由、工具过滤和费用有 Trace。参考 [Middleware overview](https://docs.langchain.com/oss/python/langchain/middleware/overview)、[Custom middleware](https://docs.langchain.com/oss/python/langchain/middleware/custom)、[Runtime](https://docs.langchain.com/oss/python/langchain/runtime)。
