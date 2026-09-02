# Agent 应用工程指南

这是一套系统讲解企业级 AI Agent 应用开发的完整中文教程，覆盖从 Python 工程基础、LLM 应用原理，到 LangChain、LangGraph、RAG、评测、安全与企业集成的完整链路。

## 学习目标

完成主线后，应能够独立完成以下工作：

- 将真实业务拆分为确定性业务流程与非确定性 Agent 决策流程；
- 使用 Python、FastAPI、Pydantic 和异步编程构建 Agent 服务；
- 使用 Redis/任务队列、Outbox 和幂等 Worker 承载文档摄取与长任务；
- 理解并实现 Prompt、Context、Structured Output 和 Tool Calling；
- 理解 Transformer、KV Cache、SFT/LoRA 与云 API/自托管推理的选型边界；
- 使用 LangChain 构建常规 Agent，使用 LangGraph 编排有状态工作流；
- 使用 Dify 完成受控工作流，并能与 LangGraph 做治理和迁移对照；
- 将统一业务契约迁移到 LlamaIndex、AutoGen、Semantic Kernel、AgentScope/ADK 等目标框架，并基于证据选型；
- 构建可引用、可拒答、可评测的 RAG 知识系统；
- 构建只读、安全、可评测的 Text2SQL 数据 Agent，以及文档/图片/语音多模态处理链；
- 使用 LangSmith 完成 Trace、Dataset、Experiment 和回归评测；
- 建立不依赖单一平台的 Dataset、Evaluator、发布门禁与线上数据飞轮；
- 实现 MCP 工具接入、权限控制、人工审批、安全防护和审计；
- 理解 A2A 与 Agent Skills，并完成跨 Agent 任务和可移植 Skill 实验；
- 使用 SQLAlchemy 2 与 Alembic 管理 Agent 数据、事务和 Schema 演进；
- 实现 OAuth/OIDC 接入边界、RBAC、Scope、资源级授权和多租户隔离；
- 使用 OpenTelemetry、SLO 和负载测试定位跨服务性能与可靠性问题；
- 使用 Linux 诊断、Docker CI、SSE 代理和 Kubernetes 应用概念完成部署排障；
- 设计 Agent Runtime、LLM Gateway、Durable Task、Sandbox、Artifact 和多租户配额边界；
- 控制模型成本、延迟、循环次数、重试与失败恢复；
- 让 Python Agent 服务与 Java 业务服务通过明确的 API 和权限边界协作；
- 在目标 JD 要求时，使用 Spring AI 完成 ChatClient、Advisor、Tool、RAG/MCP 的统一契约迁移实验；
- 交付可运行、可测试、可演示、可解释取舍的企业级项目。
- 根据真实 JD 建立岗位证据矩阵，诚实区分应用开发、算法和推理 Infra 能力；
- 能阅读英文官方文档、Release Notes 和关键源码，用最小实验验证陌生技术。

## 已确认约束

| 项目 | 约束 |
| --- | --- |
| 每周时间 | 15 小时 |
| 默认学习方式 | G0～G10 能力门槛制，不以固定周数判定完成 |
| 压缩排期 | 原 24 周计划保留为优先级参考，不限制教程范围 |
| 目标城市 | 西安 |
| Agent 主语言 | Python |
| Java 定位 | 后期可插拔的业务服务，不承担 Agent 编排 |
| 模型 | 千问为默认模型，DeepSeek 用于对照与复杂任务实验 |
| API 预算 | 无固定金额上限；仍记录 Usage、费用、延迟和重试，防止工程性浪费 |
| 本地条件 | 不使用本地大模型，不在本机运行 Docker |
| 教程语言 | 除技术名词、API 和代码外，使用简体中文 |
| 教程形态 | 长篇深度解析，练习答案紧随题目 |
| 源码方式 | 边学边建，不提前提供完整成品 |
| 项目重点 | 业务完成度、稳定性、评测证据；架构知识不因此缩减 |

## 企业级实战项目

主项目暂定名为：

**智维 Agent——工业设备维护知识与工单协同平台**

选择这个方向的原因不是追逐概念，而是它同时映射西安未来五年的先进制造、航空航天、低空经济、汽车、能源和工业软件场景。项目只处理知识辅助、信息收集、方案建议和工单协作，不允许 Agent 直接控制真实设备。

项目采用逐步演进方式：

```text
模型对话
  → 结构化输出
  → 工具调用
  → 异步摄取与任务队列
  → 设备手册 RAG
  → 故障任务状态图
  → 工单人工审批
  → Java 业务服务集成
  → MCP 工具接入
  → 自动评测与安全测试
  → 稳定性、成本与部署交付
```

项目完整设计见 [企业级项目蓝图](01-总览与使用方式/03-企业级项目蓝图.md)。

## Java 与 Python 的最终决定

教程采用“Python 必修主线 + Java 可插拔增强线”：

- G0～G5 优先使用 Python 完成 Agent 原理、RAG、LangGraph 与评测，保证核心能力不被双栈稀释；
- Python Agent 服务负责模型访问、RAG、工具编排、状态、评测和 Agent 安全；
- G7 生产工程阶段在核心验收通过的前提下加入 Spring Boot 业务服务；
- Java 服务拥有设备、告警、工单、审批等业务真相与事务边界；
- Python 只能通过受控 REST Tool 调用 Java 服务，不能绕过业务校验直接修改数据库；
- 若学习进度落后，Java 服务可由 Python 中的同接口模拟实现替代，不影响 Agent 主线完成。

这个选择保留了企业常见的 Java 业务系统集成场景，同时确保应聘 Agent 应用开发岗位所需的 Python 深度。

## 每周 15 小时资源建议

| 活动 | 每周时间 | 说明 |
| --- | ---: | --- |
| 长教程与官方资料 | 3 小时 | 理解原理，不机械抄写 |
| 编码与企业项目 | 7 小时 | 当周知识必须进入可运行代码 |
| 练习、测试与评测 | 2 小时 | 包括答案核对和失败复盘 |
| 横向基础补给 | 2 小时 | 算法、网络、操作系统、数据库 |
| 复盘与面试表达 | 1 小时 | 周报、架构决定、口述题 |

## API 费用与调用治理

本教程不设置月度 API 金额上限。费用不限制学习范围，但仍保留以下工程能力，因为生产 Agent 必须可观测、可解释、可防止循环与重试浪费：

1. 千问和 DeepSeek 都可用于日常开发、模型对照与完整评测，由评测结果选择，而非由固定金额限制。
2. 所有 Agent Loop 设置最大步骤、最大 Token 和 Deadline；这些是稳定性边界，不是月度消费上限。
3. 单元测试继续使用 Fake Model、固定响应或录制回放，以获得确定、快速、可重复的测试，而不仅是为了节省费用。
4. Prompt、RAG 和代码先通过确定性测试，再进行真实模型评测，避免把网络和随机性混入普通 CI。
5. 每次调用记录模型、Token、延迟、实际或估算费用、成功状态和重试次数。
6. 成本异常只触发告警和分析，不因教程预设金额自动停止；是否设置生产配额由具体业务另行决定。

千问和 DeepSeek 当前都提供 OpenAI-compatible 调用方式，可以通过统一模型网关切换供应商；具体模型名称和价格会在开课及面试前重新核验，不写死在长期教程中。

## 无本地 Docker、无本地模型的开发方式

- Python 使用 `uv` 与项目虚拟环境；
- 开发阶段使用 SQLite、嵌入式向量库和文件缓存；
- Java 增强线使用嵌入式 H2 开发配置；
- 大模型全部通过远程 API 调用；
- 教程仍讲解 Docker、镜像、健康检查和部署，但不要求本机启动 Docker；
- Dockerfile 通过 CI 构建或静态检查验证，持续在线部署属于可选项；
- 企业部署配置与轻量本地开发配置分离，避免用设备条件降低架构标准。

## 学习纪律

每章必须完成以下闭环：

1. 能用自己的话解释核心原理；
2. 完成基础练习和工程练习；
3. 运行测试或评测，而不是只看程序“似乎能跑”；
4. 将知识并入主项目；
5. 记录至少一个失败案例；
6. 回答本章面试追问；
7. 达到验收标准后再进入下一章。

复杂度不能成为目标本身。只有当单 Agent、确定性代码或普通工作流无法满足需求时，才引入多 Agent、动态规划或更复杂的图。

## 导航

- [原始分析与确认结果](00-教程设计确认.md)
- [最终课程架构](01-总览与使用方式/01-最终课程架构.md)
- [无固定周期的能力门槛学习路线](01-总览与使用方式/09-无固定周期的能力门槛学习路线.md)
- [24 周压缩排期参考](01-总览与使用方式/02-24周学习计划.md)
- [企业级项目蓝图](01-总览与使用方式/03-企业级项目蓝图.md)
- [完整教程目录](01-总览与使用方式/04-完整教程目录.md)
- [内容自检与补充记录](01-总览与使用方式/07-内容自检与补充记录.md)
- [岗位能力再审计](01-总览与使用方式/08-岗位能力再审计.md)
- [第一课：学习环境与第一个模型网关](02-Python-Agent后端基础/01-学习环境与第一个模型网关.md)
- [Redis、任务队列与后台作业](02-Python-Agent后端基础/07-Redis任务队列与后台作业可靠性.md)
- [LLM 应用与原生 Agent](03-LLM应用与原生Agent/01-LLM应用开发必需原理.md)
- [Transformer、微调与推理边界](03-LLM应用与原生Agent/07-Transformer模型推理微调与选型边界.md)
- [LangChain 与单 Agent](04-LangChain与单Agent/01-LangChain当前架构与学习边界.md)
- [Dify 与代码框架选型](04-LangChain与单Agent/08-Dify工作流与代码框架选型.md)
- [主流 Agent 框架横向迁移](04-LangChain与单Agent/09-主流Agent框架横向迁移实验.md)
- [RAG 与知识系统](05-RAG与知识系统/01-RAG系统全景与失败分类.md)
- [Text2SQL 数据 Agent](05-RAG与知识系统/10-Text2SQL数据Agent与数据库安全.md)
- [多模态文档、图片与语音 Agent](05-RAG与知识系统/11-多模态文档图片与语音Agent.md)
- [LangGraph 有状态工作流](06-LangGraph有状态工作流/01-为什么需要图工作流.md)
- [A2A、Agent Skills 与跨 Agent 协作](06-LangGraph有状态工作流/11-A2A-Agent-Skills与跨Agent协作.md)
- [LangSmith 评测与可观测性](07-LangSmith评测与可观测性/01-Trace-Run与Thread.md)
- [平台无关评测体系与数据飞轮](07-LangSmith评测与可观测性/07-平台无关评测体系与数据飞轮.md)
- [MCP、安全与工程化](08-MCP安全与工程化/01-MCP架构与协议心智模型.md)
- [SQLAlchemy 与 Alembic 补缺](08-MCP安全与工程化/08-SQLAlchemy异步持久化与Alembic迁移.md)
- [RBAC 与多租户补缺](08-MCP安全与工程化/09-身份认证RBAC与多租户隔离.md)
- [MCP Streamable HTTP 与 OAuth](08-MCP安全与工程化/10-MCP-Streamable-HTTP与OAuth授权.md)
- [OpenTelemetry、SLO 与负载测试](08-MCP安全与工程化/11-OpenTelemetry-SLO与负载测试.md)
- [Agent Runtime、模型网关与沙箱](08-MCP安全与工程化/12-Agent运行时模型网关沙箱与平台化.md)
- [Linux、Docker、CI 与部署排障](08-MCP安全与工程化/06-Docker-CI与部署设计.md)
- [Java 业务服务集成](09-Java业务服务集成/01-AI服务与业务服务边界.md)
- [Spring AI 与 Java Agent 生态岗位适配](09-Java业务服务集成/06-Spring-AI与Java-Agent生态岗位适配.md)
- [企业级实战项目](10-企业级实战项目/01-需求领域模型与用户故事.md)
- [从需求澄清到上线的交付评审](10-企业级实战项目/09-从需求澄清到上线的交付评审.md)
- [面试准备](11-面试准备/01-西安岗位检索与JD能力映射.md)
- [岗位证据矩阵与投递门槛](11-面试准备/08-岗位证据矩阵简历筛选与投递门槛.md)
- [英文官方文档、源码阅读与陌生技术学习](11-面试准备/09-英文官方文档源码阅读与陌生技术学习.md)
- [官方资料索引](99-附录/01-官方资料索引.md)

## 资料来源原则

每篇技术教程都包含对应练习、答案与资料入口；统一的核验日期、版本迁移方法和分类官方资料位于 [官方资料索引](99-附录/01-官方资料索引.md) 与 [版本迁移说明](99-附录/03-版本迁移与过时API.md)。资料优先级为官方概念文档、官方 API Reference、官方示例、论文或维护者课程，最后才是社区文章。

当前整体架构参考：

- [OpenAI Agents SDK Quickstart](https://developers.openai.com/api/docs/guides/agents/quickstart)
- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)
- [LangGraph Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)
- [LangSmith Evaluation Concepts](https://docs.langchain.com/langsmith/evaluation-concepts)
- [MCP Architecture](https://modelcontextprotocol.io/specification/2025-11-25/architecture)
- [千问 Function Calling](https://help.aliyun.com/zh/model-studio/qwen-function-calling)
- [DeepSeek Tool Calls](https://api-docs.deepseek.com/guides/tool_calls/)

> 框架和模型更新较快。教程中的稳定概念长期有效，但示例依赖版本将在对应阶段开始前重新核验。
