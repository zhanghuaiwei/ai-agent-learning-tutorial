# Model、Message、Tool 与 Runnable

> 预计 6 小时｜产出：能独立替换模型、组合组件并观察输入输出。

## 1. 四个核心抽象

- Model：把供应商差异封装为统一聊天模型接口。
- Message：带角色、内容块、工具调用与元数据的对话单元。
- Tool：带名称、描述和参数 Schema 的可执行能力。
- Runnable：统一 `invoke/ainvoke/stream/batch` 语义的可组合对象。

`SystemMessage` 表示应用规则，`HumanMessage` 表示用户输入，`AIMessage` 可携带 Tool Calls，`ToolMessage` 必须通过对应调用 ID 与请求配对。消息顺序或调用 ID 错误会导致供应商拒绝或模型误解。

## 2. 组合与批处理

Runnable 管道适合确定性预处理、模型调用和解析；动态动作循环交给 Agent/Graph。I/O 调用优先 `ainvoke`；批处理要限制并发，避免一次评测耗尽 API 配额。

模型初始化必须位于组合根或依赖注入层，不在每个请求重复创建客户端。元数据中放 `run_id`、Prompt 版本、数据集版本，便于 Trace。

## 3. 项目任务

实现 `ModelFactory` 和 `ToolResultAdapter`；构造一组消息，手动经历 Tool Call → Tool Message → 最终回复，输出每步消息类型和 ID。

## 4. 练习与答案

### 练习 1：Tool 直接返回 2 万字手册正文有什么问题？

**答案：**迅速占满上下文、增加成本与噪声。应返回精简片段、证据 ID、来源元数据和可按需读取的引用。

### 练习 2：Runnable 能否替代所有 Agent？

**答案：**不能。固定管道适合预知路径；需要模型动态选择动作和循环时才使用 Agent，并设置边界。

## 5. 验收与资料

能从 Trace 还原消息序列；可在不改业务代码时切模型。参考 [Models](https://docs.langchain.com/oss/python/langchain/models)、[Messages](https://docs.langchain.com/oss/python/langchain/messages)、[Tools](https://docs.langchain.com/oss/python/langchain/tools)。

