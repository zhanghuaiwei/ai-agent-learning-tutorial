# 版本迁移与过时 API

> 原则：学习稳定概念，代码固定版本；升级是独立工程任务。

## 1. 识别过时教程

出现以下信号先停下核验：导入路径含已移除模块；大量使用旧 `LLMChain`/旧 Agent Executor；教程要求混装多个主版本；LangGraph 示例没有当前 State/Graph 编译方式；MCP 使用旧 HTTP+SSE 却声称是最新；异常提示 Deprecated。

旧内容并非全无价值，可提取 Prompt、Tool、State、检索等概念，但按当前官方 API 重写最小例子。

## 2. 升级步骤

1. 创建升级分支并保存基线指标。
2. 阅读目标版本 Release Notes/Migration。
3. 更新一个依赖组，不一次升级全部生态。
4. 运行导入/类型/单元/契约/E2E。
5. 运行小型固定评测，检查轨迹、质量、成本、延迟。
6. 检查 Trace/Checkpoint/序列化兼容。
7. 更新锁文件、ADR、版本矩阵和回滚方式。

## 3. 兼容层

供应商 Model、Vector Store、Business API、MCP Client 都在 Adapter 后面；框架对象不穿透到 Domain 和对外 API。这样版本迁移集中在少数模块。

State Schema 变化需迁移旧 Checkpoint；Prompt 或 Tool Schema 变化也要升级版本并跑轨迹回归。能导入不代表行为兼容。

## 4. 版本矩阵模板

| 日期 | Python | LangChain | LangGraph | LangSmith SDK | MCP Spec/SDK | 模型 | 状态 |
|---|---|---|---|---|---|---|---|
| 2026-08-31 | 3.12 | 1.x | 1.x | 锁文件为准 | ADR 为准 | 配置为准 | 课程基线 |

## 5. 练习与答案

### 练习 1：Patch 版本升级可跳过评测吗？

**答案：**不能假设。至少跑 Smoke 和核心回归；模型/框架行为可能在非大版本变化。

### 练习 2：为兼容新旧 API 在每个业务文件写条件判断好吗？

**答案：**不好。集中在 Adapter，设明确移除日期，避免兼容逻辑扩散。

## 资料

- [LangChain Versioning](https://docs.langchain.com/oss/python/versioning)
- [LangChain Releases](https://github.com/langchain-ai/langchain/releases)
- [LangGraph Releases](https://github.com/langchain-ai/langgraph/releases)

