# Agent 运行时、模型网关、沙箱与平台化

> 目标：从“一个 Agent API”进阶到可承载多个应用和租户的平台架构；理解控制面、数据面、Durable Execution、模型网关、沙箱和开发者体验，不要求本机部署整套平台。

> **阅读前置**：G10 平台化专题（长期发展章节）。前置要求：M0～M6 的全部主线证据与"网关/工具/审批/租户"的拆分直觉；本章会在 RC 验收（第 10 阶段第 8 章）后作为架构展望阅读。

## 1. 应用岗位为什么要懂 Runtime

Agent 应用开发工程师不一定负责建设全公司平台，但高级岗位会追问：

- 多个 Agent 如何共享模型、认证、配额和审计？
- 长任务在发布、崩溃和人工等待后如何恢复？
- 模型生成的代码或 Shell 在哪里执行？
- 如何隔离租户、Secret、文件和网络？
- Prompt、Tool、Skill 和 Graph 如何版本化发布？
- 如何观察一次任务跨模型、Worker、MCP 和业务服务的完整链路？

本章以架构和最小 Fake 实验为主，不要求低配置电脑运行 Kubernetes、vLLM 或真实沙箱集群。

## 2. 从单服务到平台的演进

```text
阶段 A：Agent API 内直接调用模型与 Tool
阶段 B：API + Queue + Worker + Checkpoint
阶段 C：统一 LLM Gateway、身份、Trace 与配置
阶段 D：多租户 Agent Runtime、版本/任务控制面
阶段 E：Sandbox、MCP/A2A、插件与开发者门户
```

只有出现多个团队、多个模型、长任务、代码执行或统一治理需求时，才进入后续阶段。过早平台化会让一个业务 Demo 背负大量运维复杂度。

## 3. 控制面与数据面

### 3.1 控制面

保存期望配置：

- Agent/Graph/Prompt/Skill 版本；
- 模型别名与路由策略；
- Tool/MCP/A2A 注册信息；
- 租户套餐、配额和 Policy；
- 发布、灰度、回滚和兼容策略；
- Dataset/Evaluator/Gate；
- Secret 引用而非 Secret 明文。

### 3.2 数据面

处理真实流量：

- 请求认证和路由；
- 模型调用；
- Agent 任务调度与 Worker 执行；
- Checkpoint/Artifact/Memory；
- Tool/MCP/A2A 调用；
- Sandbox；
- Logs/Metrics/Traces/Evals。

控制面故障不应立即中断已发布版本的数据面；数据面不能自行修改租户策略。

## 4. Agent 定义与发布快照

一次可复现发布不只是 Git SHA：

```python
class AgentRelease(BaseModel):
    release_id: str
    agent_id: str
    code_sha: str
    graph_version: str
    prompt_bundle_hash: str
    tool_schema_versions: dict[str, str]
    skill_hashes: dict[str, str]
    model_policy_version: str
    evaluator_version: str
    created_by: str
```

Task 创建时绑定 `release_id`。运行中的长任务恢复时默认继续原 Release；直接加载“最新 Prompt/Graph”可能让状态 Schema 和行为不兼容。

升级策略：

- 兼容恢复：新代码能读取旧 State；
- 固定旧 Worker：旧任务继续运行原镜像；
- 显式迁移：状态经过版本化迁移后切换；
- 终止重开：仅用于允许放弃的低风险任务，并通知用户。

## 5. Durable Execution

持久化不等于 Durable Execution。后者要求明确每一步的重放语义：

- LLM 调用可重做，但结果可能变化；
- 只读 Tool 可在策略允许时重试；
- 写 Tool 必须使用幂等键或查询结果；
- 时间、随机数、外部响应等非确定输入需要记录；
- 并行结果合并顺序要可重复；
- 人工信号只消费一次；
- Task/Node 有心跳、租约和取消。

Runtime 应把“决策”和“副作用提交”分离：先保存意图/审批，再执行带幂等键的业务操作。

## 6. 任务调度模型

```text
API 接收任务
  → 持久化 Task + Outbox
  → Dispatcher 发布 Queue
  → Worker 获取 Lease
  → 执行一个可恢复步骤
  → 保存 Checkpoint/Event
  → ACK 或发布下一步
```

Task 表关键字段：

```text
task_id, tenant_id, release_id, thread_id
status, current_step, priority
attempt, max_attempts
deadline_at, lease_owner, lease_expires_at
cancel_requested_at
created_at, started_at, finished_at
error_code, result_artifact_id
```

队列只是传输/调度信号，Task 数据库是可查询事实。不能仅靠 Redis 消息推断任务是否存在。

## 7. 公平性、优先级和背压

多租户平台需要防止“吵闹邻居”：

- 每租户并发上限；
- 每模型 RPM/TPM；
- 每任务最大步数、Token、时长和 Artifact；
- 分优先级队列，但防止低优先级永久饥饿；
- 队列深度/最老消息年龄告警；
- 接近容量时返回 429/202 排队，而不是让超时扩散；
- 按租户和应用记录成功任务成本。

Little's Law 可帮助估算：稳定系统中 `并发中的任务数 ≈ 到达率 × 平均处理时间`。模型延迟翻倍时，即使请求率不变，也可能使队列和连接数翻倍。

## 8. LLM Gateway 的职责

统一网关可提供：

- 供应商/OpenAI-compatible 协议归一；
- 模型别名和版本策略；
- 身份、虚拟 Key、租户/团队配额；
- RPM/TPM、并发和预算控制；
- 超时、健康检查、Fallback 和负载均衡；
- Usage、费用、TTFT 和错误归一；
- Prompt Cache/Response Cache 策略；
- 内容/数据策略；
- 审计和 Trace Context。

网关不应拥有业务 Prompt 和 Agent 状态，也不能仅因主模型失败就无条件换模型。

## 9. Fallback 需要质量约束

切换模型可能改变：

- Tool Calling/Structured Output 支持；
- Context Window；
- 安全策略；
- 中文、领域和视觉能力；
- 延迟和价格；
- 数据驻留与供应商条款。

按能力建立路由组：

```yaml
model_policy:
  diagnosis-structured:
    required_capabilities:
      - tool_calling
      - json_schema
    primary: qwen-primary
    fallback: deepseek-compatible
    timeout_seconds: 20
    max_retries: 1
```

Fallback 模型必须通过同一回归集。内容策略拒绝通常不应被当成普通 5xx 换模型绕过。

## 10. Gateway 的观测字段

每次调用至少关联：

```text
request_id / trace_id / task_id / tenant_id / agent_id / release_id
logical_model / provider / deployment / model_version(if known)
input_tokens / output_tokens / cache_tokens
ttft / total_latency
retry_count / attempted_fallbacks / final_route
status / normalized_error
estimated_cost / billing_unit
```

Prompt/Response 默认不进入普通日志。需要调试时使用脱敏、采样、访问审计和短保留期。

## 11. Sandbox 的威胁模型

代码执行、Shell、浏览器自动化和不可信文件解析必须假设：

- 读取宿主文件和环境变量；
- 扫描内网/云 Metadata；
- 消耗 CPU、内存、磁盘、进程和网络；
- 持久化恶意文件；
- 利用内核/运行时漏洞逃逸；
- 从输出窃取 Secret；
- 供应链安装恶意包。

“使用 Docker”不是完整沙箱保证。生产沙箱需要结合容器/VM 隔离、Linux 安全策略、网络代理、只读文件系统、短生命周期和配额。

## 12. Sandbox Policy

```python
class SandboxPolicy(BaseModel):
    image_digest: str
    cpu_millis: int
    memory_mb: int
    disk_mb: int
    timeout_seconds: int
    max_processes: int
    network_mode: Literal["none", "allowlist"]
    allowed_domains: list[str]
    read_only_root: bool = True
    artifact_max_bytes: int
```

原则：

- 镜像使用 digest 和依赖锁；
- 非 root，删除多余 capabilities；
- 不挂载 Docker Socket、宿主 Home 或生产 Secret；
- 默认无网络，按域名/协议允许；
- 出站经过可审计代理并防 DNS Rebinding/SSRF；
- Workspace 每任务隔离，结束后销毁；
- 输出文件扫描后才能成为 Artifact；
- 超时不仅杀主进程，还清理子进程和资源。

## 13. Secret Broker

Agent 不应直接看到长期 API Key。更安全的模式：

```text
Agent 提交受控 Tool 请求
  → Policy 检查 Principal/Task/Scope
  → Broker 使用服务凭据调用目标
  → 返回最小结果
```

若 Sandbox 必须访问外部服务，发放短时、窄 Scope、可撤销凭据，并绑定 Task/Sandbox 身份。Secret 不能出现在 Prompt、Trace、Artifact 或异常堆栈。

## 14. Artifact 与工作空间

Artifact 是任务产物，不等于聊天消息：

```python
class Artifact(BaseModel):
    artifact_id: str
    tenant_id: str
    task_id: str
    media_type: str
    object_key: str
    sha256: str
    size_bytes: int
    created_by_step: str
    security_scan_status: str
    expires_at: datetime | None
```

下载使用短期签名 URL 和资源级授权。文件名、MIME、压缩包和 HTML 都按不可信内容处理。

## 15. Tool、MCP、A2A 注册中心

Registry 保存元数据而不是运行时 Secret：

- owner、版本、Schema、端点；
- transport 和认证方式；
- 数据分类和允许租户；
- read/write/high-risk 标签；
- 超时、幂等和 Rate Limit；
- 健康状态和弃用日期；
- 安全审查/回归状态。

新 Tool 进入生产前必须通过 Schema、授权、Prompt Injection、超时和审计测试。动态发现不能绕过准入。

## 16. 策略执行点

```text
入口：认证、租户、请求配额
模型前：数据分类、模型/地域策略、Token 上限
Tool 前：Scope、资源、风险、审批、参数
远端 Agent 前：数据最小化、信任域、任务预算
Sandbox 前：镜像、网络、资源、Secret
输出前：敏感数据、引用、内容与 Artifact 扫描
```

Policy Decision 与 Enforcement 分离：策略服务可以做决定，但每个调用边界必须真正执行，不能只把“禁止”写进 System Prompt。

## 17. 平台可观测性

一次 Trace 跨越：

```text
HTTP → Agent Task → Queue → Worker → LLM Gateway
     → Retriever/MCP/A2A/Sandbox → DB → Artifact
```

关键指标：

- Task success/failed/cancelled/unknown；
- Queue depth、oldest age、lease timeout；
- Step attempts、replay、duplicate prevented；
- LLM route/fallback/Token/TTFT/cost；
- Tool success、authorization denied、approval wait；
- Sandbox create latency、timeout、resource kill、network denied；
- 每租户 SLO 和配额使用；
- 每 Release 的质量评测和线上反馈。

使用 OpenTelemetry Context Propagation 贯通 HTTP、队列和远端调用；不能只靠日志搜索 task_id。

## 18. 发布、灰度与回滚

Agent 发布同时影响代码、Prompt、模型策略、Tool Schema 和数据索引。建议：

1. Release Snapshot；
2. 离线回归与安全门禁；
3. Shadow 或内部租户；
4. 小流量 Canary；
5. 对比成功率、成本、延迟和关键失败；
6. 扩大流量；
7. 保留快速路由回旧 Release；
8. 处理运行中 Task 的兼容策略。

回滚不能回滚已经发生的业务副作用；这部分依靠幂等、审批、补偿和审计。

## 19. 开发者体验

平台价值不只是“集中管控”，还要让应用团队：

- 本地用 Fake Gateway/Queue/Sandbox 开发；
- 一条命令验证 Agent Manifest；
- 自动生成 Tool Client 和契约测试；
- 查询 Task/Trace/Artifact；
- 创建 Dataset 并比较 Release；
- 查看租户配额和成本；
- 安全管理 Secret 引用；
- 清楚知道失败属于应用、平台、模型还是业务服务。

如果接入平台比直接写硬编码更困难，团队会绕开治理。

## 20. 何时自建、何时购买

决策维度：

| 维度 | 购买/托管更合适 | 自建更合适 |
| --- | --- | --- |
| 差异化 | 通用网关、Trace、基础 Sandbox | 核心业务 Runtime/策略是竞争力 |
| 团队 | 运维人力少 | 有专门平台/SRE/安全团队 |
| 合规 | 供应商满足要求 | 数据/部署有强定制和本地化要求 |
| 时间 | 需要快速交付 | 长期规模能抵消维护成本 |
| 锁定 | 可接受标准 API/导出 | 需要完全控制数据和路线 |

常见组合是购买模型/API 和部分观测能力，自建业务编排、权限与数据层。

## 21. 本课程最小实验

低配置电脑、不使用本地 Docker 时完成：

1. 写 `AgentRelease`、`Task`、`Artifact`、`SandboxPolicy` Schema；
2. SQLite 保存 Task/Outbox/Release；
3. In-memory Queue + Worker 模拟 lease、重试、取消；
4. Fake LLM Gateway 模拟主模型 429 后能力兼容 Fallback；
5. Fake Sandbox 验证 Policy 决定，不执行真实不可信代码；
6. OpenTelemetry 或结构化事件贯通 request/task/model/tool；
7. 输出平台 C4 图、容量表、威胁模型和 ADR；
8. CI 只做静态 Docker/K8s 配置和测试，不在本机启动集群。

目标是证明架构理解和契约，而不是伪称拥有生产 Kubernetes/Sandbox 经验。

## 22. 练习与答案

### 练习 1：有了 LangGraph Checkpointer，是否等于拥有完整 Agent Runtime？

**答案：**不等于。Checkpointer 解决图状态持久化的一部分；Runtime 还涉及任务调度、发布版本、租户配额、Worker lease、取消、Artifact、网关、策略、Sandbox 和跨服务观测。

### 练习 2：主模型 429 时直接切更便宜模型是否合理？

**答案：**只有 Fallback 具备所需 Tool/Schema/上下文和合规能力，并通过相同回归集时才可切换。还要记录路由变化，避免质量退化被系统成功率掩盖。

### 练习 3：Docker 容器为什么不能自动等同安全沙箱？

**答案：**配置错误、内核共享、宿主挂载、Docker Socket、网络和 Secret 暴露仍可导致逃逸或泄漏。需要资源、系统调用、文件、网络、身份和生命周期的组合隔离。

### 练习 4：控制面数据库故障时数据面怎么办？

**答案：**已发布的不可变 Release 和策略应有缓存/快照，使已有流量在明确期限内继续或安全降级；不能在控制面不可用时默认放开权限。新发布和高风险配置变更应停止。

### 练习 5：为什么 Task 数据库比队列消息更适合作为事实？

**答案：**队列可能重复、过期或被 ACK，难以查询完整生命周期。数据库保存业务状态、版本、租约、取消和结果，Outbox 保证调度信号最终发布。

## 23. 面试追问

1. Agent Runtime 与普通 Web 后端有什么不同？
2. 控制面和数据面如何拆分？
3. 运行中任务如何跨版本恢复？
4. 模型网关应该做什么、不应该做什么？
5. 多租户如何公平调度和限流？
6. 如何安全运行模型生成代码？
7. Sandbox 如何访问外部 API 而不拿长期 Secret？
8. Agent 发布为什么不能只回滚 Git SHA？
9. 如何贯通一次任务的 Trace？
10. 什么规模下不应该自建平台？

## 24. 验收标准

- [ ] 画出控制面/数据面 C4 图；
- [ ] Agent Release 能固定代码、Prompt、Tool、Skill 和模型策略；
- [ ] Task/Queue/Worker 的 lease、取消、重放和未知状态清晰；
- [ ] Fallback 通过能力与质量门禁；
- [ ] Sandbox Policy 覆盖资源、文件、网络、身份、Secret 和 Artifact；
- [ ] 多租户配额、公平性和背压有容量设计；
- [ ] Trace 贯通 HTTP、Queue、Worker、LLM 和 Tool；
- [ ] 完成自建/购买 ADR；
- [ ] 明确区分“设计/模拟验证”和真实生产经验。

## 25. 资料来源

- [LiteLLM Proxy](https://docs.litellm.ai/docs/simple_proxy)
- [LiteLLM Fallbacks](https://docs.litellm.ai/docs/proxy/reliability)
- [LiteLLM Virtual Keys](https://docs.litellm.ai/docs/proxy/virtual_keys)
- [LangGraph Durable Execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)
- [Redis Job Queue](https://redis.io/docs/latest/develop/use-cases/job-queue/redis-py/)
- [Kubernetes Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [OpenTelemetry Generative AI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [OWASP Top 10 for Agentic Applications 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/)
- [OWASP Agentic AI Threats and Mitigations](https://genai.owasp.org/resource/agentic-ai-threats-and-mitigations/)
- [Google SRE Workbook](https://sre.google/workbook/table-of-contents/)
