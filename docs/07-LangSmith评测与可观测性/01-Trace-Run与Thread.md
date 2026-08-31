# Trace、Run 与 Thread

> 预计 5 小时｜产出：能从一次用户请求定位到模型、检索、工具和 Graph 节点。

## 1. 可观测对象

Trace 表示一次完整执行树，Run 是其中某个模型、工具、检索或自定义步骤，Thread 关联跨多次运行的会话。业务 `request_id/run_id/thread_id` 应作为 Metadata 写入，但不要与 LangSmith 自身 ID 混淆。

Span/Run 至少记录名称、类型、开始结束、状态、延迟、Token、费用、模型、Prompt 版本、数据版本和错误码。生产默认对输入输出脱敏或不采集正文。

## 2. 标签与采样

推荐标签：`env/app_version/graph_version/prompt_version/model/tenant_class/feature_flag`。禁止把用户姓名、手机号当标签。开发全量采样，生产按风险和费用设置；错误、高延迟和高风险动作可提高采样率。

Trace 不是日志替代品：日志适合服务事件与检索；Metrics 看趋势；Trace 看单次因果链；三者通过业务 ID 关联。

## 3. 项目任务

接入 LangSmith，同时保留关闭开关。为一次工单流程定位最慢 Run、最贵模型调用和失败 Tool；输出截图之外的文字诊断。

## 4. 练习与答案

### 练习 1：为什么不能在 Metadata 放完整用户问题？

**答案：**Metadata 常被索引、展示和长期保存，会扩大隐私暴露；正文应按策略脱敏、加密和限期保留。

### 练习 2：只看最终 Trace 成功够吗？

**答案：**不够。成功可能经历多余循环、降级或高成本，应检查轨迹、延迟、费用和工具副作用。

## 5. 验收与资料

任意失败可由业务 ID 找到，敏感数据策略可证明。参考 [Observability concepts](https://docs.langchain.com/langsmith/observability-concepts)、[Trace an application](https://docs.langchain.com/langsmith/trace-with-langchain)。

