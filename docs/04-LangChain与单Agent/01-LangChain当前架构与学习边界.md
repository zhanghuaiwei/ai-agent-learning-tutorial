# LangChain 当前架构与学习边界

> 预计 4 小时｜版本基线：LangChain 1.x。目标是掌握稳定抽象，不背过时链式 API。

## 1. 当前心智模型

LangChain 提供 Model、Message、Tool、Structured Output、Middleware 和 `create_agent` 等应用层抽象；`create_agent` 底层运行在 LangGraph 上，因此具备图执行、持久化、流式和 Human-in-the-loop 的扩展路径。

学习边界：

- 必学：消息、工具、结构化输出、`create_agent`、Middleware、运行时 Context、流式事件。
- 理解即可：Runnable 组合与第三方集成定位。
- 暂缓：旧版 `LLMChain`、旧 Agent Executor 教程、靠记忆大量历史 API。

框架不是架构。业务权限、幂等、费用、数据所有权、对外协议和验收指标仍由你设计。

## 2. 分层建议

```text
api/              自有 HTTP/SSE 契约
application/      用例编排与权限上下文
agent/            create_agent、Prompt、Middleware
tools/            工具定义与适配器
domain/           设备/告警/工单规则
infrastructure/   模型、数据库、LangSmith
```

不要让路由函数直接创建 Agent，也不要让 Tool 越过业务服务直接修改任意表。

## 3. 项目任务

把 M1 手写 Loop 保留为参考实现，新建 LangChain 版本。用同一组契约测试比较消息、工具调用、停止行为和错误映射。

## 4. 练习与答案

### 练习 1：既然 `create_agent` 基于 LangGraph，还要单独学 LangGraph 吗？

**答案：**要。简单动态工具循环用 `create_agent`；需要显式状态、审批、恢复、并行分支和固定业务流程时要直接设计 Graph。

### 练习 2：旧视频中的 API 跑不通怎么办？

**答案：**先确认安装版本，查 1.x 官方文档与迁移指南，再把概念映射到当前 API；不要为了复现旧视频盲目降级整个项目。

## 5. 验收与资料

能画出上述分层，并列出框架负责/不负责的边界。参考 [LangChain Overview](https://docs.langchain.com/oss/python/langchain/overview)、[Agents](https://docs.langchain.com/oss/python/langchain/agents)、[Versioning](https://docs.langchain.com/oss/python/versioning)。

