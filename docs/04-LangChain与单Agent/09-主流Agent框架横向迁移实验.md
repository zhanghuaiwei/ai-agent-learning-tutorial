# 主流 Agent 框架横向迁移实验

> 目标：不靠背诵框架 API，使用统一契约比较 LangChain/LangGraph、LlamaIndex、AutoGen、Semantic Kernel、AgentScope/ADK，并形成目标 JD 的选型证据。

> **阅读前置**：G9 框架广度专题。前置要求：M0～M5 的主线项目证据——本章的核心方法是"用自有统一契约迁移同一业务"，没有主线积累就没有迁移对象。不依赖本阶段其他章节正文，建议在 M5 后执行。

## 1. 为什么需要框架广度

招聘信息经常同时列出多种框架，但招聘方通常不是要求候选人分别做六个玩具项目，而是在判断：

- 是否理解 Agent 的稳定组成；
- 能否快速阅读英文官方文档；
- 能否把业务契约迁移到不同运行时；
- 是否知道框架优势、代价和成熟度；
- 是否能避免业务代码被框架对象污染。

课程仍以 LangChain + LangGraph 为深入主线。其他框架采用“同题迁移”，每个只验证其特色和边界。

## 2. 先定义平台无关契约

### 2.1 统一输入输出

```python
from typing import Literal

from pydantic import BaseModel, Field


class DiagnoseRequest(BaseModel):
    tenant_id: str
    user_id: str
    device_id: str
    symptom: str = Field(min_length=3, max_length=2_000)


class Evidence(BaseModel):
    source_id: str
    quote: str


class DiagnoseResponse(BaseModel):
    status: Literal["answered", "need_more_info", "escalated", "failed"]
    summary: str
    evidence: list[Evidence]
    proposed_action: str | None = None
```

### 2.2 统一工具端口

```python
from typing import Protocol


class DeviceRepository(Protocol):
    async def get_device(self, tenant_id: str, device_id: str) -> dict: ...


class KnowledgeRetriever(Protocol):
    async def search(self, tenant_id: str, query: str, top_k: int) -> list[dict]: ...


class WorkOrderPort(Protocol):
    async def preview(self, payload: dict) -> dict: ...
```

框架 Adapter 可以变化，但 Domain Model、授权 Principal、错误码、审计事件和端口不能跟着变化。迁移实验因此是在换“编排实现”，不是复制一套业务。

## 3. 比较维度

| 维度 | 必问问题 |
| --- | --- |
| Agent/Workflow 抽象 | 默认是循环、图、事件驱动还是对话团队？ |
| 状态 | 状态由谁拥有，是否可持久化、迁移、并发隔离？ |
| Tool | Schema、错误、权限和取消如何表达？ |
| 多 Agent | Supervisor、Handoff、Group Chat 的终止条件是什么？ |
| Human-in-the-loop | 能否跨请求暂停，批准后是否从安全位置恢复？ |
| 流式 | 输出 Token、Tool Event、State Update 是否可区分？ |
| 评测/Trace | 是否能导出平台无关轨迹？ |
| 部署 | 普通 ASGI 服务、专用 Runtime 或托管平台？ |
| 锁定风险 | 业务对象是否依赖框架类型，迁移成本多大？ |
| 社区与版本 | API 稳定性、迁移说明、License 和维护情况？ |

不要只比较“代码行数”。少 20 行代码不代表状态恢复、权限和可测试性更好。

## 4. LangChain + LangGraph：课程基线

本课程使用它们建立最完整证据：

- LangChain 负责模型、消息、工具、中间件和常规 Agent；
- LangGraph 负责显式状态、条件路由、持久化、Interrupt、恢复和子图；
- LangSmith 用于 Trace、Dataset 和 Experiment，但测试契约不依赖它。

优势是应用开发资料完整、与招聘关键词直接匹配、状态工作流表达清晰。风险是版本演进快、抽象层较多；需要依赖锁和契约测试。

## 5. LlamaIndex：以数据和检索为中心

LlamaIndex 的迁移重点不是重写聊天机器人，而是比较数据链：

1. 使用相同的 20 份设备文档；
2. 复用相同 Chunk ID、tenant metadata 和评测集；
3. 用其 Ingestion、Index/Retriever 或 Query Engine 完成同一检索任务；
4. 比较召回、延迟、索引更新、删除和可观测性；
5. 可选使用 `FunctionAgent` 或 `AgentWorkflow` 包装检索工具。

适合 JD：RAG 工程师、知识库、复杂文档摄取、LlamaIndex 明确为硬要求。

面试边界：LlamaIndex 也支持 Agent、多 Agent、状态和 MCP，不能简单说“它只做 RAG”；应说明本项目为何只验证其数据框架优势。

## 6. AutoGen：会话团队与事件驱动运行时

迁移题：实现“诊断 Agent + 安全审查 Agent”，最多两次 Handoff，任何一方不能直接创建工单。

重点验证：

- `AssistantAgent` 的工具、结构化输出和流式事件；
- Team 的终止条件，而不是让 Agent 无限讨论；
- Agent/Team State 保存与恢复；
- Human-in-the-loop 的调用位置；
- `McpWorkbench` 或 Code Executor 的安全边界；
- Agent 实例是否能被并发请求共享。

AutoGen 官方文档明确提示 Agent 是有状态的，实例不能无条件跨并发任务共享。实验必须为每个 Thread 建立隔离实例或明确同步策略。

适合 JD：多 Agent 研究、对话协作、事件驱动 Agent Runtime、AutoGen 明确为要求。

## 7. Semantic Kernel：企业语言生态和插件

Semantic Kernel 支持 Python、Java 和 .NET。对本项目最有价值的迁移不是再写 Python，而是验证 Java 业务系统能否通过 Plugin/OpenAPI 暴露受控能力。

实验：

1. Spring Boot 继续拥有工单事务；
2. 通过只读 OpenAPI 或 Semantic Kernel Plugin 暴露设备查询；
3. 禁止模型直接获得数据库连接；
4. 比较 Plugin、MCP Tool、普通 REST Adapter 的契约和治理；
5. 记录预览/实验性编排 API 的版本风险。

适合 JD：微软/.NET 生态、Java/Spring 企业 AI 集成、Semantic Kernel 明确出现。

## 8. AgentScope 或 Google ADK：国产/多语言生态抽样

二者不要求都安装。根据目标公司选择一个，完成：

- 一个 LLM Agent；
- 两个工具；
- 一个顺序或并行 Workflow；
- 结构化事件和 Trace；
- 明确终止与失败状态；
- 与 LangGraph 的 1 页 ADR。

若目标岗位强调阿里生态、国产框架或 AgentScope，优先 AgentScope；若强调 Google Cloud、ADK、A2A 或多语言 SDK，优先 ADK。选择必须来自 JD，而不是 GitHub 热度。

## 9. Dify/Coze 属于另一比较维度

低代码平台比较的是交付速度、运营可编辑、DSL 版本、插件生态和治理，不应与代码框架只比“能不能调用模型”。继续使用第 8 章的 Dify/LangGraph 对照实验，并补充：

- 导出 DSL 是否进入 Git；
- 节点变更如何评审；
- API 鉴权、租户和 Secret 如何处理；
- 如何接入统一 Trace 和评测；
- 复杂度达到什么条件时迁回代码。

Coze 只在目标岗位要求时做同类最小验证，不需要复制完整项目。

## 10. 迁移实验目录

```text
experiments/framework-matrix/
├── contract/
│   ├── models.py
│   ├── ports.py
│   └── cases.jsonl
├── langchain_langgraph/
├── llamaindex/
├── autogen/
├── semantic_kernel/
├── agentscope_or_adk/
├── reports/
│   ├── benchmark.csv
│   └── ADR-framework-selection.md
└── README.md
```

每个实现只允许修改 Adapter 和 Composition Root。若为了框架迁移必须修改业务 Schema，先说明是框架限制还是原契约设计错误。

## 11. 统一测试集

至少包含：

| 分组 | 用例 |
| --- | --- |
| happy path | 根据故障现象检索证据并生成草稿 |
| missing data | 缺设备 ID 时询问，不猜测 |
| tool error | 检索超时，返回可恢复终态 |
| authorization | 跨租户设备必须拒绝 |
| injection | 文档要求忽略系统规则时不得执行 |
| loop | 工具持续返回空结果时必须停止 |
| handoff | 只在风险标签命中时交给审查 Agent |
| concurrency | 两个 Thread 的状态不得串线 |

统一记录任务成功率、越权数、步骤数、P50/P95、Token、框架事件完整性和实现复杂度。

## 12. 选型评分表

使用 1～5 分，但评分必须附证据：

| 指标 | 权重建议 | 证据 |
| --- | ---: | --- |
| 业务契合 | 25% | 目标流程实现和限制 |
| 可靠恢复 | 15% | 崩溃/暂停恢复实验 |
| 安全治理 | 15% | 权限与红队测试 |
| 可测试/评测 | 15% | 契约测试和 Trace 导出 |
| 团队生态 | 10% | 语言、现有平台、招聘供给 |
| 运维复杂度 | 10% | 依赖、部署、状态组件 |
| 版本/锁定 | 10% | 升级记录和迁移难度 |

最终 ADR 必须允许“普通代码 + 少量框架”获胜。框架不是默认必选项。

## 13. 面试表达模板

避免：

> 我会 LangChain、LangGraph、LlamaIndex、AutoGen、ADK、Dify。

推荐：

> 我用 LangChain/LangGraph 完成了主项目的完整生产链路；为验证迁移能力，我把相同工具契约和评测集迁到 LlamaIndex 与 AutoGen。LlamaIndex 的数据摄取抽象更贴近知识库场景，AutoGen 的团队和事件模型适合对话式多 Agent，但主项目需要跨请求审批和可控恢复，因此最终保留 LangGraph。对其他框架我会明确标注实验深度。

## 14. 常见错误

- 跟着旧博客安装已经迁移的 AutoGen 0.2 API；
- 用不同数据和不同 Prompt 比较框架，然后把模型波动当成框架差异；
- 在 Domain 层直接传递各框架 Message/State 对象；
- 多 Agent 没有终止条件和最大预算；
- 只做 happy path，不测状态隔离和并发；
- 把“跑过 Hello World”写成“熟练掌握”；
- 没有记录版本、模型、参数和 Git SHA。

## 15. 练习与答案

### 练习 1：JD 列出四个框架，简历应该都写“熟练”吗？

**答案：**不应该。按证据写成“主项目使用”“完成迁移实验”“理解选型边界”。技术面通常会沿着“熟练”连续追问状态、并发、恢复和源码实现，夸大只会降低可信度。

### 练习 2：为什么统一 Schema 仍不能保证完全可移植？

**答案：**框架在状态生命周期、事件、暂停恢复、并行语义和托管能力上不同。统一 Schema 只是隔离业务数据，运行语义仍需 Adapter、测试和迁移 ADR 处理。

### 练习 3：多 Agent 框架得分高，就应该把单 Agent 改成多 Agent 吗？

**答案：**不一定。首先证明任务确实需要独立职责、上下文或权限；再通过同一评测集证明成功率或可维护性收益超过延迟、费用和故障面增长。

### 练习 4：如何低成本完成实验？

**答案：**先用 Fake Model 验证状态、事件和工具契约，再对每个框架运行同一小型真实模型数据集。无需为每个框架重建完整 UI、数据库和部署环境。

## 16. 验收标准

- [ ] 平台无关契约和测试集进入 Git；
- [ ] LangChain/LangGraph 为完整基线；
- [ ] 至少选择两个目标 JD 出现的框架完成迁移；
- [ ] 每个实验包含失败、越权、循环和并发隔离用例；
- [ ] 输出带版本和数据的评分表；
- [ ] 完成一个最终选型 ADR；
- [ ] 简历表述与实际证据等级一致。

## 17. 资料来源

- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)
- [LangGraph Overview](https://docs.langchain.com/oss/python/langgraph/overview)
- [LlamaIndex：Building an Agent](https://developers.llamaindex.ai/python/framework/understanding/agent/)
- [LlamaIndex：Building a RAG Pipeline](https://developers.llamaindex.ai/python/framework/understanding/rag/)
- [AutoGen AgentChat](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/index.html)
- [AutoGen API Reference](https://microsoft.github.io/autogen/stable/reference/index.html)
- [Semantic Kernel Agent Framework](https://learn.microsoft.com/en-us/semantic-kernel/frameworks/agent/)
- [Semantic Kernel Documentation](https://learn.microsoft.com/en-us/semantic-kernel/)
- [AgentScope Documentation](https://doc.agentscope.io/)
- [Google Agent Development Kit](https://adk.dev/)
- [Dify Documentation](https://docs.dify.ai/)
