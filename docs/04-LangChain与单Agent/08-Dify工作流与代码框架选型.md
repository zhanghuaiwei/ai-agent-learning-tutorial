# Dify 工作流与 LangChain/LangGraph 代码框架选型

> 建议投入：第 10 周 2 小时｜目标：具备企业 JD 常见的 Dify 工作流认知，并能把可视化平台、LangChain Agent 和 LangGraph 的边界讲清楚。

## 1. 为什么代码主线还要学习 Dify

企业采用低代码 Agent 平台，常见原因是原型速度、统一模型配置、业务人员可视化编排、知识库和运营界面。招聘方写 Dify/Coze，并不一定要求你成为平台管理员，而是希望你能：

- 快速把需求转成可运行 Workflow；
- 理解节点、变量、分支、迭代、Tool 和知识检索；
- 通过 API 与业务系统集成；
- 调试运行记录并定位失败节点；
- 知道何时低代码平台不再适合；
- 能把平台原型迁移为可测试、可版本化的代码服务。

本课程仍以 LangChain/LangGraph 为主，因为应聘的是开发工程师。Dify 作为交付和选型能力，不替代 Python、测试、权限和系统设计。

## 2. 三种实现方式的心智映射

| 业务概念 | Dify Workflow | LangChain | LangGraph |
| --- | --- | --- | --- |
| 输入契约 | User Input/Start variables | Pydantic/Input Schema | State Schema |
| 模型调用 | LLM Node | Chat Model/Runnable | LLM Node |
| 参数抽取 | Parameter Extractor | Structured Output | 确定性/LLM Node |
| 工具 | Tool/HTTP Request/Plugin | `@tool` + ToolRuntime | Tool Node/普通 Node |
| 分支 | IF/ELSE/Question Classifier | Runnable branch/代码 | Conditional Edge/Command |
| 循环/批量 | Iteration/Loop | 代码控制 | Send/Edge/循环 |
| 知识检索 | Knowledge Retrieval | Retriever | Retriever Node |
| 状态与恢复 | 平台运行记录/会话能力 | Agent State/Checkpointer | Checkpoint/Thread/Interrupt |
| 评测与观测 | 平台日志/运营能力 | LangSmith/自建 | LangSmith/OTel/自建 |
| 发布 | Web App/API | 自建 FastAPI | 自建 FastAPI/Worker |

映射只帮助理解，不能假设语义完全相同。尤其是事务、跨请求恢复、审批身份和重放行为，必须以实际平台版本与文档验证。

## 3. 用智维 Agent 搭一个受控 Workflow

选取“故障描述 → 风险分类 → 知识检索 → 生成建议”只读链路，不在平台内直接创建工单。

```text
User Input
  → Parameter Extractor(FaultReport)
  → IF/ELSE(schema/risk)
      ├─ invalid → Output(补充信息)
      ├─ high risk → Output(停止并联系人工)
      └─ normal
          → Knowledge Retrieval(tenant/document filters)
          → LLM(仅基于证据)
          → Code/Template(引用格式)
          → Output
```

### 3.1 输入变量

- `tenant_id` 不应由普通用户文本自由填写，真实系统由可信网关注入；
- `device_id` 仅是资源标识，仍需后端鉴权；
- `fault_description` 长度限制、内容安全与日志脱敏；
- `request_id` 用于跨平台 Trace 关联；
- 文件上传必须限制类型、大小、数量和处理权限。

### 3.2 Parameter Extractor

输出 `device_id/symptoms/error_codes/risk_signals/missing_fields`。提取结果仍是不可信模型输出，后续由确定性节点校验：设备编号格式、错误码 Allowlist、风险词规则和必填字段。

### 3.3 知识检索

课程主项目的生产设计仍让自建 RAG Service 负责文档版本、ACL 和评测。Dify PoC 可以使用平台知识库，但必须记录：

- Chunk/Embedding/检索设置；
- 文档版本与删除行为；
- 多租户隔离方式；
- 检索结果是否提供可验证来源；
- 如何导出 Dataset 与做回归。

### 3.4 输出

平台输出映射为内部稳定 API：

```json
{
  "request_id": "req_123",
  "status": "completed",
  "answer": "...",
  "citations": [
    {"document_id": "manual-7", "version": "v3", "section": "4.2"}
  ],
  "risk_level": "medium"
}
```

前端不能直接依赖平台内部节点名、变量路径或未版本化的错误文本。

## 4. 发布 API 的 Adapter

把 Dify 视为外部供应商，通过 Adapter 隔离：

```python
from typing import Protocol

import httpx
from pydantic import BaseModel, Field


class WorkflowResult(BaseModel):
    request_id: str
    status: str
    answer: str | None = None
    citations: list[dict[str, str]] = Field(default_factory=list)


class FaultWorkflow(Protocol):
    async def run(self, *, principal_id: str, device_id: str, text: str) -> WorkflowResult: ...


class DifyFaultWorkflow:
    def __init__(self, base_url: str, api_key: str, timeout: float = 30.0):
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._timeout = timeout

    async def run(self, *, principal_id: str, device_id: str, text: str) -> WorkflowResult:
        payload = {
            "inputs": {"device_id": device_id, "fault_description": text},
            "response_mode": "blocking",
            "user": principal_id,
        }
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            response = await client.post(
                f"{self._base_url}/v1/workflows/run",
                headers={"Authorization": f"Bearer {self._api_key}"},
                json=payload,
            )
            response.raise_for_status()
            body = response.json()
        return adapt_dify_response(body)
```

示例强调 Adapter；具体路径、字段和流式事件必须在实验当天按官方 API Reference 核验。API Key 只在服务端 Secret 中，不能放入浏览器。

## 5. 可视化不等于免工程治理

### 5.1 版本

保存 Workflow DSL/导出物、平台版本、模型配置和知识库设置；变更通过 PR 附 Diff 或可读的变更摘要。只在平台 UI 点击修改且无审查，会让生产行为不可追溯。

### 5.2 测试

至少三层：

1. 节点测试：Parameter Extractor、条件分支和格式化；
2. Workflow Dataset：正常、缺字段、无证据、注入、越权和依赖失败；
3. Adapter Contract：平台响应转换为内部 API，覆盖字段缺失和错误码。

平台 Test Run 通过不等于发布通过。发布门禁仍要求离线 Dataset、权限负向测试和 Smoke Test。

### 5.3 安全

- 业务权限在 Tool/业务 API 再校验，不把隐藏变量当安全边界；
- 第三方 Plugin 按供应链依赖审查权限、网络和维护状态；
- Code Node 禁止任意网络/Secret 访问，遵守平台沙箱边界；
- Prompt 和知识文档都可能注入；
- 高风险写动作走外部审批服务，不依赖用户在对话中说“确认”。

### 5.4 可观测性

内部 `request_id/trace_id` 传入平台允许的变量或 Header；保存平台 Run ID，但不把完整 Prompt/文档默认写入应用日志。对平台外 HTTP Tool 继续记录独立 Span。

## 6. 什么时候选 Dify

适合：

- 业务流程较清晰，需要快速 PoC 和业务共同评审；
- 团队需要统一模型、Prompt、知识库和发布入口；
- 节点能力覆盖需求，扩展点和治理满足合规；
- 质量能通过外部 Dataset 和 API Contract 验证。

谨慎或转代码：

- 需要复杂持久状态、精细重放、长任务恢复和严格事务；
- 需要大量自定义并发、动态路由或特殊流式协议；
- 权限/多租户/审计无法达到业务要求；
- DSL Diff 难审、平台升级频繁破坏兼容；
- 锁定、成本或性能已被数据证明不可接受。

## 7. 与 LangGraph 的对照实验

对同一批 20 条 Fault Cases 跑 Dify 与 LangGraph 版本，保持模型、Prompt、知识数据和 Tool 语义尽量一致。比较：

第 10 周先完成 Dify 与手写/LangChain 版的初步对照；第 18 周学完 LangGraph 后复用同一 Dataset 完成本节，不提前复制尚未理解的 Graph 实现。

| 指标 | Dify | LangGraph |
| --- | --- | --- |
| 从零到首个可演示版本的时间 | 记录 | 记录 |
| 任务成功率/拒答率 | 记录 | 记录 |
| P50/P95、Token、费用 | 记录 | 记录 |
| 权限与注入负向测试 | 记录 | 记录 |
| 暂停恢复/重放能力 | 记录 | 记录 |
| 版本 Diff 与代码审查 | 记录 | 记录 |
| 本地/CI 自动测试难度 | 记录 | 记录 |
| 平台依赖与迁移成本 | 记录 | 记录 |

输出 ADR 的结论可以是“PoC 用 Dify，生产核心编排用 LangGraph”，也可以是“整个低风险只读场景继续 Dify”；必须由需求和证据得出。

## 8. 面试追问

### 8.1 Dify 和 LangChain 是竞品吗？

不完全是。Dify 更接近带 UI、模型/知识/工作流/运营能力的应用平台；LangChain 是代码库与生态。可以由 Dify 调自建 LangChain 服务，也可以完全用代码交付。选型维度是控制力、治理、交付速度和团队协作。

### 8.2 会 Dify 是否等于会 Agent 开发？

不等于。能拖出流程只是起点；还要解释变量契约、Tool 权限、失败重试、状态、评测、发布、观察和平台边界。开发工程师应能在平台受限时下沉到代码。

### 8.3 平台内知识库和自建 RAG 如何选？

用文档规模、ACL、版本、检索策略、评测、数据地域、可观测性和运维成本比较。平台能力满足低风险场景可优先；复杂权限或定制检索需要自建服务并通过 API 接入。

## 9. 练习与答案

### 练习 1：把工单创建直接放在 Dify HTTP 节点，主要风险是什么？

**答案：**模型/工作流可能重复调用；平台重试和超时造成未知结果；身份可能来自不可信输入；难以保证幂等与审批。应调用受控业务 API，由 API 验证 Token、Scope、资源、审批摘要和幂等键。

### 练习 2：Dify PoC 成功后是否应立即重写 LangGraph？

**答案：**不应预设。先测状态恢复、权限、性能、测试、版本治理和团队维护。如果平台满足 SLO 和合规，重写没有收益；若出现被证实的边界，再渐进迁移并保持内部 API Contract。

### 练习 3：如何展示“熟悉 Dify”而不夸大？

**答案：**展示 Workflow 图/DSL、20 条 Dataset 报告、API Adapter、Dify/LangGraph ADR 和一个失败修复记录。简历写清完成的范围，不写“精通平台内核”。

## 10. 验收标准

- [ ] 能将 Dify 核心节点映射到 LangChain/LangGraph 概念；
- [ ] 完成只读故障建议 Workflow 或可审查设计；
- [ ] 平台通过服务端 Adapter 接入，API Key 不进入浏览器；
- [ ] 保存 Workflow 版本与 20 条回归结果；
- [ ] 至少覆盖注入、越权、无证据和 HTTP Tool 超时；
- [ ] 输出一份 Dify/LangGraph 选型 ADR；
- [ ] 能解释何时继续平台、何时下沉代码。

## 11. 资料来源

- [Dify 30-Minute Quick Start](https://docs.dify.ai/en/guides/application-orchestrate/creating-an-application)
- [Dify API Reference](https://docs.dify.ai/api-reference)
- [Dify Plugin Overview](https://docs.dify.ai/en/develop-plugin/getting-started/getting-started-dify-plugin)
- [Dify Plugin Publishing Overview](https://docs.dify.ai/en/develop-plugin/publishing/marketplace-listing/release-overview)
- [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)
- [LangGraph Graph API](https://docs.langchain.com/oss/python/langgraph/graph-api)
