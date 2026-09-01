# 子图与多 Agent 模式

> 目标：以职责、上下文、权限和评测证据决定拆分；掌握 Subgraph、Router、Supervisor、Handoff 和并行专家，而不是追求 Agent 数量。

## 1. 先区分函数、Tool、子图和 Agent

| 组件 | 适用 | 是否由模型自主决定 |
| --- | --- | --- |
| 普通函数 | 确定性复用、格式转换、规则 | 否 |
| Tool | Agent 可选择的外部能力 | 通常是，但执行受代码策略控制 |
| 子图 | 可独立测试/持久化的多步 Workflow | 内部可含确定性和模型节点 |
| Agent | 有模型、指令、工具和停止条件的自主单元 | 是 |

只是为了复用代码时用函数；需要封装多个状态步骤时用子图；只有职责需要自主选择和独立上下文时才增加 Agent。

## 2. 拆分的有效理由

- 上下文隔离：财务 Agent 不需要维修手册，诊断 Agent 不看工资数据；
- 工具权限不同：安全审查只能读，执行 Agent 只能操作批准后的资源；
- 不同专业 Prompt/模型：视觉、SQL、代码等能力明显不同；
- 独立团队/发布生命周期；
- 可并行且结果可确定合并；
- 独立评测数据和 SLO；
- 需要将控制权显式交给另一角色。

无效理由：名字更酷、Prompt 太长、代码文件太大、希望“多个 Agent 投票自然更准”。

## 3. 子图的状态边界

父图状态：

```python
class MainState(TypedDict):
    tenant_id: str
    user_id: str
    request: str
    diagnosis: dict | None
    work_order_draft: dict | None
    errors: Annotated[list[dict], operator.add]
```

检索子图只接收：

```python
class RetrievalState(TypedDict):
    tenant_id: str
    query: str
    evidence: list[dict]
    retrieval_error: dict | None
```

父图通过显式 Adapter 传入/取回字段，避免子图读取所有消息、Principal 或内部控制标记。最小状态让测试、权限和未来迁移更清晰。

## 4. 持久化选择

### Per-invocation 子图

每次由父图调用，状态随父图 Checkpoint；适合短期检索/生成流程。

### Per-thread 子图

子图有持续会话或独立 Memory；必须为不同调用建立稳定 namespace/thread 标识，并防止并发冲突。

### 独立服务/远端 Agent

若子图由另一团队部署、独立扩缩或有安全边界，考虑普通 API/MCP/A2A，而不是强行共享 Checkpointer。

面试时说明状态所有权，不只说“LangGraph 支持 subgraph”。

## 5. Router 模式

Router 根据请求选择一个或多个专业路径：

```text
request
  → route_intent
       ├─ knowledge → RAG subgraph
       ├─ analytics → Text2SQL subgraph
       ├─ work_order → business workflow
       └─ unsupported → clarify/refuse
```

路由结果使用 Structured Output：

```python
class RouteDecision(BaseModel):
    destination: Literal["knowledge", "analytics", "work_order", "unsupported"]
    confidence: float
    missing_information: list[str]
```

低置信度或高风险意图走澄清/确定性规则；路由器不能决定用户权限。

评测：分类准确率、错误路由成本、澄清率、跨租户和攻击样本。路由错到“写操作”属于严重错误，不与普通分类错等权。

## 6. Supervisor 模式

Supervisor 选择下一位专家、判断是否完成：

```text
Supervisor
  ├─ Retrieval Agent
  ├─ Data Agent
  └─ Safety Review Agent
```

State 必须包含：

- 明确目标和已完成子任务；
- 可调用成员白名单；
- 最大轮数/Token/Deadline；
- 每个成员的结构化结果；
- 最终终止原因；
- 权限/审批状态（由代码控制）。

Supervisor 只负责协调，不获得所有成员工具的并集。否则中心 Agent 被注入后可越过专业边界。

## 7. Handoff 模式

Handoff 表示对话或任务控制权转移，例如一线客服把复杂故障转给维修专家。

设计问题：

- 转交条件和目标白名单；
- 传递完整历史还是经过过滤的摘要；
- 当前 Agent 的 Tool 是否撤销；
- 用户是否看到角色变化；
- 新 Agent 缺信息如何追问；
- 何时交回或结束；
- Handoff 链和最大次数。

Handoff Payload 使用结构化 Schema，不能简单拼接“请接着做”的自然语言。接收方对历史和摘要仍按不可信输入处理。

## 8. 并行专家模式

适合彼此独立的分析：

```text
告警
  ├─ 手册证据专家
  ├─ 历史工单专家
  └─ 风险规则专家
       → deterministic aggregator
```

并行状态合并要定义 Reducer，不让“最后完成的节点覆盖前一个”。每个输出包含 source、confidence、evidence 和 error。

聚合优先使用确定性规则；如果必须用模型合并，输入保留来源，并对冲突/缺失明确处理。

延迟通常由最慢分支决定；设置每分支超时和允许的部分成功策略。

## 9. Orchestrator-Worker 模式

用于动态分解但 Worker 执行边界明确的任务：

```text
Orchestrator 生成 TaskPlan
  → 代码验证计划数量、类型和预算
  → Send 给多个 Worker
  → Worker 返回结构化结果
  → 聚合与验收
```

TaskPlan 不应允许模型任意创造工具名、Shell 命令或无限子任务。代码限制 worker_type、max_tasks、并发、Token、超时和数据范围。

文档批量摘要是好例子；高风险工单写入不是自由 fan-out 的好例子。

## 10. Critic/Reviewer 模式

生成 Agent 产出草稿，Reviewer 检查明确 Rubric：

- 证据是否覆盖；
- 是否包含禁止动作；
- 字段是否完整；
- 是否应升级人工。

Reviewer 不能无限要求重写。最多一到两轮，并为每轮记录具体缺陷。安全规则能由代码判断的部分不交给 Reviewer。

同一个模型扮演生成和评审可能共享偏差；关键场景结合规则、独立数据和人工抽样。

## 11. 多 Agent Context Engineering

不要在每个 Handoff 传完整会话。建立 Context Contract：

```python
class SpecialistContext(BaseModel):
    task_id: str
    objective: str
    tenant_id: str
    allowed_resource_ids: list[str]
    facts: list[dict]
    unresolved_questions: list[str]
    output_schema_version: str
```

系统指令、隐藏推理、其他 Agent 的 Secret 不传递。摘要注明来源，不能把模型生成摘要当业务事实。

## 12. 权限矩阵

| Agent/子图 | 允许 | 禁止 |
| --- | --- | --- |
| Router | 读取请求元数据、选择路径 | 调写 Tool |
| Retrieval | 读取授权文档 | 访问其他租户、写业务 |
| Data Agent | 只读分析视图 | 任意 SQL、业务写入 |
| Safety Reviewer | 读取草稿/证据 | 修改审批状态 |
| Work-order Executor | 执行已批准 Action | 生成或伪造 Approval |

权限由运行时 Tool Registry/Policy 注入，不能只在各 Agent Prompt 中声明。

## 13. 失败模型

| 失败 | 处理 |
| --- | --- |
| Router 低置信度 | 澄清/默认安全路径 |
| 专家超时 | 部分结果、降级或人工，不重复全部流程 |
| Handoff 循环 | 最大次数 + 已访问集合 |
| Supervisor 死循环 | 步数/Token/Deadline + 无进展检测 |
| 并行结果冲突 | 显式冲突状态，不随机选一个 |
| 子图状态 Schema 升级 | 版本迁移或固定旧 Release |
| 写 Worker 超时未知 | 幂等查询，不盲目重做 |
| Reviewer 持续拒绝 | 达上限后转人工 |

## 14. 无进展检测

除最大轮数外，可判断：

- 连续调用同一 Tool 和相同参数；
- State 核心字段没有变化；
- 重复 Handoff 链；
- 子任务结果哈希重复；
- 计划未完成项数量不下降。

命中后以 `stalled` 终止，保存轨迹供评测，而不是再让模型“认真思考”。

## 15. 评测多 Agent 是否值得

建立同任务对照：

```text
Baseline A：单 Agent
Candidate B：单主图 + 子图
Candidate C：Supervisor + 2 Specialists
```

比较：

- 任务成功和高风险错误；
- Tool/路由/交接正确性；
- 平均/P95 步数、延迟、Token、成本；
- 失败恢复和 Trace 可解释性；
- Prompt、数据集和部署维护量；
- 同一失败修复需要修改多少组件。

只有业务收益明显且可重复，才保留多 Agent。

## 16. 项目默认选择

“智维 Agent”默认：

```text
单个主 LangGraph
  ├─ RAG 子图
  ├─ Text2SQL 子图（选修）
  ├─ 工单草稿子图
  └─ 确定性 Policy + Human Approval
```

可选实验：新增只读 Safety Reviewer，对 40 条高风险样本做 A/B。若未明显降低错误或只增加“谨慎措辞”，删除该 Agent，保留规则门禁。

## 17. 最小 Supervisor 状态骨架

```python
class TeamState(TypedDict):
    task_id: str
    objective: str
    completed: Annotated[list[str], operator.add]
    specialist_results: Annotated[list[dict], operator.add]
    next_agent: str | None
    steps: int
    token_used: int
    deadline_at: str
    terminal_reason: str | None
```

路由函数在代码中验证 `next_agent` 白名单和预算；State 中的 `tenant_id`/Principal 由外部 Runtime Context 传入，不允许 Supervisor 改写。

## 18. 测试策略

### 节点测试

使用 Fake Model/Tool 验证输入输出和错误映射。

### 图测试

固定路由响应，断言路径、Reducer、Interrupt、终止和 Checkpoint。

### 性质测试

- 步数永不超过上限；
- 未批准状态永不进入写节点；
- 不同 tenant 的资源不进入相同 Context；
- 写操作最多一次；
- 任一专家失败最终仍进入定义终态。

### 真实模型评测

只在契约测试通过后运行，关注路由、Handoff、无进展和任务成功。

## 19. 面试追问

1. 子图与 Tool 有什么区别？
2. Supervisor 为什么不应拥有所有 Tool？
3. Handoff 传完整对话有什么风险？
4. 并行结果如何合并？
5. 如何检测多 Agent 死循环？
6. Reviewer Agent 是否能替代安全规则？
7. 怎样用评测证明多 Agent 值得？
8. 什么时候应该用 A2A 而不是 LangGraph 子图？

## 20. 练习与答案

### 练习 1：让三个 Agent 自由讨论能提高可靠性吗？

**答案：**未必。它们可能共享模型偏差、互相强化错误并显著增费。需要独立证据、有限回合、结构化交接、明确聚合和单 Agent 对照实验。

### 练习 2：子图与 Tool 的区别？

**答案：**Tool 是 Agent 可选择的能力接口；子图是 Workflow 内的多步编排单元，可包含 Tool、状态和路由。Tool 的边界通常更窄，也可能由外部服务实现。

### 练习 3：Prompt 太长，是否应拆成多 Agent？

**答案：**先清理上下文、按需检索、分离步骤或使用子图。只有职责、权限、模型或独立生命周期需要时才拆 Agent；Prompt 长本身不是充分理由。

### 练习 4：并行三个专家，一个失败怎么办？

**答案：**由业务定义最小成功集合。可使用部分结果并标记缺失、重试安全分支或转人工；聚合节点必须看到失败状态，不能把缺失误认为“无风险”。

### 练习 5：Reviewer 判断通过后能否直接创建工单？

**答案：**不能把 Reviewer 输出当用户审批。Reviewer 是质量信号；业务写入仍需可信 Principal、Policy、Approval 和幂等执行。

## 21. 验收标准

- [ ] 每个拆分都有上下文、权限、模型或生命周期理由；
- [ ] 父图与子图通过显式 Schema 交接；
- [ ] Router/Supervisor/Handoff/并行至少完成两个实验；
- [ ] 最大步数、Token、Deadline 和无进展检测有效；
- [ ] Tool 权限不因 Agent 增加而扩大；
- [ ] 状态持久化、版本和并发隔离有测试；
- [ ] 使用同一数据集完成单 Agent/子图/多 Agent 对照；
- [ ] 无收益的多 Agent 设计被删除并记录 ADR。

## 22. 资料来源

- [LangGraph Subgraphs](https://docs.langchain.com/oss/python/langgraph/use-subgraphs)
- [LangChain Multi-agent](https://docs.langchain.com/oss/python/langchain/multi-agent)
- [LangGraph Graph API](https://docs.langchain.com/oss/python/langgraph/graph-api)
- [LangGraph Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)
- [LangGraph Interrupts](https://docs.langchain.com/oss/python/langgraph/interrupts)
- [AutoGen AgentChat Teams](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/teams.html)
- [Semantic Kernel Agent Orchestration](https://learn.microsoft.com/en-us/semantic-kernel/frameworks/agent/agent-orchestration/)
- [A2A Protocol](https://a2a-protocol.org/latest/specification/)
