# Agent 系统设计面试：方法、题库与评分标准

> 目标：在 35～45 分钟内从业务目标推导 Agent 架构，覆盖数据、状态、权限、评测、可靠性、容量、发布和取舍，而不是画一张“LLM + 向量库”图。

## 1. 面试官真正评估什么

系统设计题通常没有唯一答案。面试官关注：

- 是否主动澄清目标、范围和风险；
- 能否判断哪里需要 LLM、哪里必须确定性；
- 是否理解 RAG、Tool、Memory、Workflow 的数据边界；
- 能否设计失败终态、幂等、恢复和降级；
- 是否把认证、授权、租户、审批放在代码而非 Prompt；
- 是否会用评测和业务指标证明价值；
- 是否能估算规模、发现瓶颈并逐步演进；
- 能否表达取舍，而不是罗列热门组件。

四年前端经验可用于说明用户交互、流式体验和跨团队交付，但回答主体仍需证明 Python 后端和 Agent 工程深度。

## 2. 45 分钟时间分配

| 时间 | 内容 |
| ---: | --- |
| 0～5 分钟 | 澄清用户、任务、指标、风险、规模和范围外 |
| 5～10 分钟 | 核心用例、LLM/确定性边界、API 与数据契约 |
| 10～18 分钟 | 高层架构和一次请求/任务主链路 |
| 18～28 分钟 | 深挖 RAG、Graph、Tool 或 Runtime 中最关键一项 |
| 28～35 分钟 | 安全、隐私、权限、可靠性和降级 |
| 35～40 分钟 | 评测、观测、发布和反馈闭环 |
| 40～45 分钟 | 容量、成本、取舍与后续演进 |

若面试官要求深挖某部分，及时调整；不要机械念模板。

## 3. 开场澄清清单

### 3.1 业务

- 主要用户是谁，在哪个工作流中使用？
- 期望 Agent 给建议、生成草稿还是自动执行？
- 当前人工流程和最大痛点是什么？
- 成功指标是解决率、节省时间、收入还是风险降低？
- 哪些错误不可接受，是否要求人工负责最终决定？

### 3.2 数据

- 数据来自文档、数据库、实时系统还是第三方？
- 是否包含敏感、个人或跨租户数据？
- 新鲜度、删除、版本和数据驻留要求？
- 是否已有 ACL、搜索和指标语义层？

### 3.3 规模与体验

- DAU、峰值 RPS、平均会话长度、长任务比例？
- 首 Token、完整响应、后台任务的延迟目标？
- 是否需要流式、文件、图片、语音和移动端？
- 可用性、恢复目标和成本边界？

### 3.4 组织与约束

- 模型/API、云、本地部署和合规限制？
- 现有 Java/数据库/消息队列/身份系统？
- 是单团队应用还是多团队 Agent 平台？

没有给数字时，提出明确假设并说明规模变化如何影响设计。

## 4. 先做能力选择，不要先选框架

| 问题特征 | 首选 |
| --- | --- |
| 输入输出规则明确 | 普通代码/规则 |
| 开放文本生成但无工具 | 单次 LLM 调用 + Structured Output |
| 需要企业文档事实 | RAG |
| 模型选择一个或少量工具 | 单 Agent/Tool Calling |
| 跨请求、审批、恢复、多阶段 | 显式 Workflow/LangGraph |
| 职责/权限/上下文独立且收益经评测 | 多 Agent |
| 独立组织的 Agent 互操作 | A2A |
| 外部 Tool/Resource 标准接入 | MCP |

一个系统可以组合多种，但每个组件必须有需求来源。

## 5. 通用架构骨架

```text
Client
  → API Gateway / Auth / Rate Limit
  → Agent API
       ├─ Session / Task Service
       ├─ Agent Orchestrator
       │    ├─ RAG Service
       │    ├─ Tool Policy + Tool Adapters
       │    └─ Human Approval
       ├─ Queue / Worker / Checkpoint
       └─ Event Stream

Shared platform
  ├─ LLM Gateway
  ├─ Prompt/Release Config
  ├─ Trace/Eval/Metric
  └─ Secret/Policy

Data
  ├─ PostgreSQL: business/task/audit
  ├─ Redis: cache/queue/ephemeral
  ├─ Vector/Search Index
  └─ Object Storage: documents/artifacts

External
  ├─ Java business services
  ├─ MCP tools
  └─ A2A agents
```

小规模第一版可以合并服务，但逻辑责任仍需分清。

## 6. 数据所有权

| 数据 | Owner | 原因 |
| --- | --- | --- |
| 设备/订单/工单 | 业务服务 | 事务和业务规则 |
| Agent Thread/Checkpoint | Agent Runtime | 恢复和编排 |
| 文档原件/Chunk/Index | Knowledge Service | 摄取、版本和删除 |
| Prompt/Graph/Tool Schema | Release Config | 可复现发布 |
| Trace/Eval | Observability/Eval | 质量与审计 |
| User/Tenant/Role | Identity/业务系统 | 权限事实 |

向量库不应成为业务事实库；模型 Memory 不能覆盖业务数据库。

## 7. 同步请求与异步任务

### 同步

适合简单问答和短 Tool 调用：

```text
POST /v1/agent/runs → SSE events → final/error
```

设置总 Deadline、并发上限和断线取消。SSE 事件区分 Token、Tool、Approval、Status 和 Error。

### 异步

适合文档摄取、批量分析、长时 Agent 和导出：

```text
POST /v1/tasks → 202 + task_id
GET /v1/tasks/{id}
POST /v1/tasks/{id}/cancel
GET /v1/tasks/{id}/events
```

Task 存数据库，Queue 传递调度信号；Worker 使用 lease、幂等、心跳、重试和 DLQ。

## 8. Agent 状态与 Memory

分开设计：

- Request Context：tenant、user、roles、deadline，不由模型修改；
- Conversation：当前会话消息，可压缩；
- Workflow State：结构化任务状态，可持久化和迁移；
- Long-term Memory：经策略提取的偏好/事实，有来源、过期和删除；
- Business State：订单、工单等只由业务服务拥有。

Memory 写入必须经过分类、去重、来源、租户隔离和用户删除策略。不要把整段对话永久向量化。

## 9. Tool 和副作用

Tool 设计需要：

- 窄 Schema 和业务语义；
- Principal/tenant/Scope；
- 参数校验和资源级授权；
- read/write/high-risk 分类；
- 超时、取消、重试和幂等；
- 预览与审批；
- 错误码和审计。

写操作推荐：

```text
Agent 生成 ActionProposal
  → Policy 验证
  → 用户看到结构化预览
  → Approval 保存
  → 使用 approval_id + idempotency_key 调业务 API
  → 查询最终业务状态
```

自然语言“好的”不是高风险审批的唯一证据。

## 10. RAG 深挖框架

回答 RAG 题至少覆盖：

```text
Source + ACL
  → Parse/OCR
  → Normalize/Deduplicate/Version
  → Chunk + Metadata
  → Embedding + Sparse Index
  → Query rewrite/filter
  → Hybrid retrieval + rerank
  → Context assembly
  → Grounded answer/citation/refusal
  → Layered evaluation
```

追问删除：通过 Asset/Document/Chunk/Embedding/Cache 的数据血缘执行删除；使用新索引构建、验证、原子切换避免半成品。

追问权限：检索前过滤 + 存储层隔离 + 返回前验证；不能先取回跨租户 Chunk 再让模型忽略。

## 11. 可靠性设计

### 11.1 时间预算

```text
request deadline 15s
  ├─ retrieval 1.5s
  ├─ primary model 8s
  ├─ tools 3s
  └─ response reserve 2.5s
```

每层超时小于上层；重试要消耗剩余预算。

### 11.2 重试矩阵

| 操作 | 是否重试 |
| --- | --- |
| 模型 429/短暂 5xx | 有限、退避、抖动，必要时兼容 Fallback |
| 只读查询超时 | 可有限重试 |
| 写操作超时未知 | 先按幂等键查询，不盲目重做 |
| 权限拒绝 | 不重试 |
| Schema/业务校验失败 | 最多一次受限修复 |
| 内容安全拒绝 | 不通过换模型绕过 |

### 11.3 降级

- Agent → 受控 Workflow；
- 生成回答 → 只返回检索结果；
- 写操作 → 草稿/人工队列；
- 主模型 → 已评测兼容模型；
- 实时 → 202 后台任务；
- 个性化 Memory → 无状态模式。

## 12. 安全威胁模型

输入面：直接/间接 Prompt Injection、恶意文件、SSRF。

身份面：跨租户、Agent 身份伪造、Token 转发错误、过宽 Scope。

执行面：Tool 滥用、重复副作用、Sandbox Escape、资源/费用耗尽。

状态面：Memory Poisoning、Checkpoint 篡改、旧版本恢复。

供应链：MCP Server、Skill、Prompt、模型和依赖更新。

输出面：敏感信息、错误引用、恶意 Artifact、日志泄漏。

防御使用代码 Policy、最小权限、Schema、审批、隔离、预算、审计和红队评测；System Prompt 只是一层软约束。

## 13. 评测与业务闭环

发布前：

- 确定性契约测试；
- RAG 组件指标；
- Agent 轨迹/任务成功；
- 安全红队和越权零容忍；
- 延迟、成本和负载；
- 人工业务验收。

线上：

- 任务完成、人工采纳、转人工、用户修正；
- 模型/Tool/Queue 系统指标；
- 高风险与随机抽样；
- 失败脱敏回流 Dataset；
- Prompt/Release/Model/Index 版本关联。

## 14. 容量估算示例

假设：

- 峰值 50 个新请求/秒；
- 40% 进入模型；
- 每个模型任务平均 6 秒；
- 每任务平均 1.4 次模型调用；
- 流式连接平均 10 秒。

粗估：

```text
model calls/s = 50 × 40% × 1.4 = 28
in-flight model calls ≈ 28 × 6 = 168
concurrent SSE ≈ 50 × 10 = 500
```

再加入重试、峰值系数和供应商 RPM/TPM。由此决定并发限制、队列、连接池、Worker 数和模型配额，而不是随口说“上 Kubernetes”。

## 15. 可观测性与 SLO

指标分层：

| 层 | 指标 |
| --- | --- |
| API | RPS、4xx/5xx、TTFT、P95、断线 |
| Task | 成功、取消、未知、队列年龄、重放 |
| Agent | 步数、终止原因、Tool 成功、审批等待 |
| RAG | 检索延迟、空结果、权限过滤、索引版本 |
| LLM | Token、TTFT、错误、Fallback、成本 |
| Business | 采纳率、解决时长、错误动作、转人工 |

SLO 以用户任务定义，例如“99% 的普通知识问答在 12 秒内返回可用终态”，而不是只看模型 API 200。

## 16. 发布与演进

Release 绑定代码、Graph、Prompt、Tool Schema、模型策略和索引版本。流程：离线门禁 → 内部/Shadow → Canary → 扩量 → 观察 → 回滚。

数据库 Schema 使用 Expand/Contract；运行中 Thread 固定或迁移版本；回滚不撤销已发生副作用。

第一版应尽量简单：单 Agent、少量工具、显式审批。只有评测证明瓶颈后再增加多 Agent、A2A、Sandbox 或平台控制面。

## 17. 题一：企业知识与工单 Agent

### 需求

维修人员查询设备手册、分析告警并创建工单草稿；高风险工单需主管批准。

### 必须命中

- 文档 ACL/版本/混合检索/引用/拒答；
- 告警和设备事实来自业务 API；
- LangGraph 跨请求审批；
- 工单写入的 approval + idempotency；
- 文档注入和跨租户负向测试；
- 任务成功、引用、轨迹和副作用评测。

### 深挖问题

进程在批准后、写业务 API 前崩溃怎么办？恢复后读取 Approval 和幂等记录，使用同一 idempotency key 提交；超时未知时先查询业务服务，避免重复工单。

## 18. 题二：智能客服 Agent

### 需求

回答政策、查询订单、生成退款申请并在必要时转人工。

### 必须命中

- 登录前后能力不同；订单资源级授权；
- 知识时效、政策版本和引用；
- 退款为结构化提案，不由对话文本直接执行；
- 会话状态、敏感信息脱敏和删除；
- 峰值限流、转人工和降级；
- 解决率不能通过拒绝困难问题虚高。

### 深挖问题

如何防止用户把别人的订单号写进 Prompt？Tool 调用使用认证用户 ID，服务端按订单 Owner 授权；模型提供的订单号只是候选参数。

## 19. 题三：研发助手与代码 Agent

### 需求

读取仓库、分析 Issue、修改代码、运行测试并创建 PR 草稿。

### 必须命中

- 仓库/分支权限和最小 Scope；
- Issue、代码注释、README 都是不可信内容；
- 短生命周期隔离 Workspace/Sandbox；
- 默认受限网络、无宿主 Secret；
- Diff、测试和人工批准；
- MCP/Skill 供应链和审计；
- Token、步骤、时间、文件大小和命令预算。

### 深挖问题

为什么不能把生产 GitHub Token 放进 Sandbox？使用外部 Broker 执行受控 Git 操作，或发放绑定任务/仓库/短时 Scope 的凭据；Agent 只获得必要结果。

## 20. 题四：Text2SQL 数据分析 Agent

### 必须命中

- 固定 API/语义层/Text2SQL 的选择；
- Schema Catalog 与歧义澄清；
- AST 白名单、只读账号、RLS、超时和行数；
- tenant 来自 Principal；
- Execution Accuracy + Policy Violation；
- 大导出转异步 Job。

## 21. 题五：多模态现场助手

### 必须命中

- 对象存储和异步 OCR/ASR/VLM；
- 页码/坐标/时间戳证据；
- Partial Transcript 不触发 Tool；
- 低置信度人工复核；
- 恶意文件、图片/音频注入和数据删除；
- 模态级指标与业务指标。

## 22. 题六：多租户 Agent 平台

### 必须命中

- 控制面/数据面；
- Agent Release 和运行中任务版本；
- LLM Gateway、租户配额和能力兼容 Fallback；
- Task/Queue/Worker/Durable Execution；
- Tool/MCP/A2A Registry 与 Policy；
- Sandbox、Artifact、Secret Broker；
- 开发者体验、SLO 和成本归因。

## 23. 高频追问与回答骨架

### 为什么用 LangGraph？

因为流程跨请求、包含人工审批和持久化恢复，并需要显式状态与错误边；简单问答仍使用单 Agent/普通代码。

### 为什么不用多 Agent？

当前职责和权限可以由单主图 + 子图表达，多 Agent 会增加 Prompt、上下文、终止、评测和成本。只有独立上下文/权限且对照评测提升后才拆分。

### Redis 挂了怎么办？

说明 Redis 的具体职责。缓存可绕过/降级；Queue 暂停接收长任务或使用持久化 Outbox 恢复；Task 事实仍在数据库。不能笼统回答“主从切换”。

### 模型供应商不可用怎么办？

短任务有限重试，兼容模型经评测后 Fallback；否则降级检索/草稿/排队/人工。内容安全拒绝不应换模型绕过。

### 如何防幻觉？

按失败类型处理：事实用 RAG/Tool 和引用，格式用 Schema，业务动作由确定性校验，信息不足时拒答；用数据集评测而不是承诺“消除幻觉”。

### 如何降低成本？

减少无效上下文和步骤、用小模型处理简单分类、缓存稳定前缀/结果、批处理摄取、设置预算和停止条件；比较每成功任务成本并守住质量门禁。

## 24. 常见失分点

- 开场就说 LangChain/LangGraph，而不问业务；
- 把模型输出当认证、授权或审批；
- 只画向量库，不谈数据版本/删除/ACL；
- 说“失败就重试”，不区分副作用和未知结果；
- 说“加缓存”但没有键、TTL、隔离和失效；
- 只看 API 延迟，不看任务成功和队列；
- 多 Agent 没有终止、权限和对照评测；
- 生产代码执行只回答 Docker；
- 指标只有“准确率”，没有任务/轨迹/安全/业务分层；
- 夸大未真实做过的 K8s、并发量或生产经验。

## 25. 自我评分表（100 分）

| 项目 | 分值 |
| --- | ---: |
| 需求、指标、风险和范围澄清 | 15 |
| LLM/确定性边界和技术选择 | 10 |
| API、数据所有权和核心链路 | 15 |
| RAG/Agent/Runtime 关键深挖 | 15 |
| 权限、安全、隐私与审批 | 15 |
| 可靠性、状态、幂等和降级 | 10 |
| 评测、观测、发布与反馈 | 10 |
| 容量、成本、取舍与表达 | 10 |

低于 70 分不计为完成；任意出现“越权动作可执行、跨租户数据可见、重复写不可控”直接失败。

## 26. 训练方法

每轮：

1. 随机抽题，5 分钟写澄清问题；
2. 35～45 分钟录屏/录音完成；
3. 按评分表自评；
4. 找出一个最薄弱的设计点；
5. 回到教程做一个最小代码/故障实验；
6. 48 小时后重新答同题；
7. 两周后用变体题检查迁移。

至少完成 12 次：六类题各一次，另外六次由目标 JD 改写。

## 27. 练习与答案

### 练习 1：系统设计一开始就选 LangGraph 合适吗？

**答案：**不合适。先确认是否跨请求、有持久状态、审批和恢复；从业务推出 Workflow。简单问答或一次 Tool 调用用普通代码/单 Agent 更易测试。

### 练习 2：面试官问规模但没给数字怎么办？

**答案：**提出合理假设并明确标注，再说明不同数量级的演进。例如先假设峰值 50 RPS、40% 进入模型；计算并发后讨论限流、队列和供应商配额。

### 练习 3：如何在时间不足时收尾？

**答案：**明确说出尚未展开的风险，优先补权限、失败终态、评测和核心取舍；不要继续添加组件。用 30 秒总结当前方案、最大风险和下一步验证。

### 练习 4：面试官质疑“项目规模不大，为何谈平台化”？

**答案：**承认主项目当前采用模块化单体/API + Worker 即可；平台化设计是岗位适配实验，不伪称已生产运行。说明达到多团队、多租户、代码执行等阈值后才拆控制面和数据面。

## 28. 验收标准

- [ ] 六类题都能在 45 分钟内完成；
- [ ] 每题先澄清业务，不先报框架；
- [ ] 至少一次容量计算和一个关键状态机；
- [ ] 能解释权限、幂等、超时未知和版本恢复；
- [ ] 能设计 Dataset、门禁、线上反馈和业务指标；
- [ ] 12 次训练记录和两次复答达到 80 分；
- [ ] 所有生产经验表述与项目证据一致。

## 29. 参考资料

- [AWS Well-Architected Framework](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html)
- [Google SRE Book](https://sre.google/sre-book/table-of-contents/)
- [Google SRE Workbook](https://sre.google/workbook/table-of-contents/)
- [C4 Model](https://c4model.com/)
- [LangGraph Durable Execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)
- [LangSmith Evaluation Concepts](https://docs.langchain.com/langsmith/evaluation-concepts)
- [OWASP Top 10 for Agentic Applications 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/)
- [OpenTelemetry Generative AI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [Redis Job Queue](https://redis.io/docs/latest/develop/use-cases/job-queue/redis-py/)
- [PostgreSQL EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html)
