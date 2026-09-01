# A2A、Agent Skills 与跨 Agent 协作

> 目标：理解 MCP、A2A、Agent Skills 和框架内多 Agent 的不同层次；完成一个可审计的跨 Agent 任务实验，不把协议名当成功能。

## 1. 四个概念先分层

| 概念 | 解决的问题 | 不解决的问题 |
| --- | --- | --- |
| 框架内多 Agent | 同一应用内如何分工、路由、共享状态 | 跨组织发现、通用远程协议 |
| MCP | Agent/应用如何访问 Tool、Resource、Prompt | 两个独立 Agent 如何协作完成长任务 |
| A2A | 独立 Agent 如何发现能力、创建/跟踪任务和交换产物 | Agent 内部如何调用数据库或业务 API |
| Agent Skills | 如何把可复用说明、脚本、参考资料和资产打包 | 远程认证、任务状态和网络传输 |

一个系统可以同时使用：LangGraph 编排本地状态，MCP 连接工具，Skill 提供任务知识，A2A 调用外部专业 Agent。它们不是互相替代的框架。

## 2. 为什么企业会需要跨 Agent 协作

当不同团队分别拥有：

- 设备诊断 Agent；
- 备件库存 Agent；
- 合规审查 Agent；
- 供应商服务 Agent；

直接共享 Prompt、Memory 和内部 Tool 会破坏边界。跨 Agent 协议允许调用方只看到能力描述、任务状态和产物，不读取对方内部推理或数据库。

但如果所有组件由同一团队维护、部署和发布，普通函数、内部 API 或 LangGraph 子图通常更简单。A2A 不是进程内模块化工具。

## 3. A2A 核心心智模型

以规范为准，不背 SDK 类名。需要理解：

- Agent Card：对外声明身份、能力、端点和支持的交互方式；
- Message/Part：用户或 Agent 交换的内容，可包含文本、文件或结构化数据；
- Task：具有生命周期的协作任务；
- Artifact：任务产生的可交付结果；
- Streaming/Push：长任务的进度传递方式；
- Authentication/Authorization：调用者身份和能力权限；
- Extension：双方明确协商的扩展，不能静默假设。

具体字段和版本会演进，实验前在 ADR 中固定规范版本。

## 4. 任务状态映射

内部 LangGraph Thread 和远端 A2A Task 不能共用一个 ID，也不能假设状态完全相同。

```python
class RemoteTaskBinding(BaseModel):
    tenant_id: str
    local_thread_id: str
    local_node: str
    remote_agent_id: str
    remote_task_id: str
    protocol_version: str
    request_hash: str
    last_remote_status: str
```

本地状态至少区分：

```text
REMOTE_SUBMITTING
REMOTE_WORKING
REMOTE_INPUT_REQUIRED
REMOTE_SUCCEEDED
REMOTE_FAILED
REMOTE_CANCELLED
REMOTE_UNKNOWN
```

网络超时时不能直接再次创建任务。先用幂等键或已保存 remote task ID 查询，避免远端重复执行。

## 5. Agent Card 不是可信证明

能力描述可能过期、夸大或被篡改。消费远端 Agent 时建立信任策略：

- 允许的域名/注册中心；
- TLS 与服务身份；
- Agent Card 缓存和过期时间；
- 能力/Schema 版本；
- 数据分类和允许发送的字段；
- 最大任务时长、费用和产物大小；
- 是否允许继续调用其他 Agent；
- 审计和合同/SLA。

发现能力后仍要做授权；“它声明能处理工单”不代表当前用户可以把本租户工单发给它。

## 6. 示例：备件可用性 Agent

本地主图只把最小数据发送给远端：

```json
{
  "part_number": "BRG-6205",
  "required_quantity": 2,
  "site_code": "XA-01",
  "needed_before": "2026-09-15"
}
```

不发送整段对话、用户 Prompt、其他设备记录和内部系统指令。远端返回 Artifact：

```json
{
  "availability": "available",
  "quantity": 6,
  "warehouse": "XA-W2",
  "reservation_required": true,
  "valid_until": "2026-09-01T10:10:00Z"
}
```

这只是查询结果。真正预留备件仍使用本地受控业务 API、用户授权和审批。

## 7. 消息和 Artifact 都是不可信输入

远端 Agent 可能返回：

- Prompt Injection；
- 与声明 Schema 不符的字段；
- 超大文件或恶意 URL；
- 要求调用本地高权限 Tool 的文本；
- 过期或无来源结论；
- 伪造“用户已批准”。

边界控制：

1. 按协商 Schema 校验；
2. 内容类型、大小和 URL 白名单；
3. Artifact 与自然语言指令分离；
4. 不继承远端声称的用户权限；
5. 本地重新执行业务 Policy；
6. 保存来源 Agent、Task、时间和内容哈希；
7. 高风险动作仍在本地 Human-in-the-loop。

## 8. 错误、取消和补偿

| 场景 | 本地策略 |
| --- | --- |
| 提交超时 | 查询幂等绑定，未知时进入 REMOTE_UNKNOWN |
| 远端需要输入 | 校验请求字段，再向用户或本地节点获取 |
| 远端失败 | 根据错误类别降级、本地处理或人工转交 |
| 本地用户取消 | 发送远端取消并跟踪最终状态 |
| 远端已完成但本地崩溃 | 恢复后按 task ID 拉取 Artifact |
| Artifact 已过期 | 重新创建新任务，不复用旧结论 |
| 本地后续写入失败 | 远端查询无需补偿；远端预留则调用明确补偿 API |

跨 Agent Saga 必须明确每一步谁拥有事务和补偿，不能期待分布式 ACID。

## 9. Agent Skills 的结构

Skill 是一个目录，至少包含 `SKILL.md`，可选包含 scripts、references 和 assets：

```text
equipment-diagnosis/
├── SKILL.md
├── scripts/
│   └── normalize_alarm.py
├── references/
│   ├── fault-codes.md
│   └── response-schema.json
└── assets/
    └── report-template.md
```

`SKILL.md` 的 frontmatter 至少声明 `name` 和 `description`。描述必须说明“做什么、何时使用”，否则 Agent 无法可靠选择。

## 10. Skill 设计原则

一个好的 Skill：

- 单一职责且触发条件清晰；
- 主文件提供流程和边界，长资料按需放 references；
- 脚本参数明确、默认只读、输出结构化；
- 不内嵌 Secret、真实客户数据或环境专属绝对路径；
- 声明依赖、网络要求和兼容性；
- 包含失败处理、样例和反例；
- 有版本、License、作者/维护者和变更记录；
- 在不同 Agent Host 上做可移植性测试。

Skill 内容同样可能是供应链攻击面。安装前需要来源、Diff、脚本和依赖审查。

## 11. 最小 Skill 示例

```markdown
---
name: alarm-triage
description: 将工业设备告警归一为严重级别和所需信息；当输入包含告警代码或设备异常描述时使用。
license: MIT
compatibility: 需要 Python 3.12；默认不访问网络；不执行工单写入。
---

# 告警分诊

1. 校验设备 ID、告警代码和时间。
2. 调用 `scripts/normalize_alarm.py` 生成结构化结果。
3. 缺字段时列出问题，不猜测。
4. 输出只包含分级和建议，不创建或关闭工单。
```

脚本应能单独运行和测试，Agent 只是调用者，不是脚本正确性的保障。

## 12. Skill 与 MCP 组合

典型组合：

- Skill：告诉 Agent 何时、按什么步骤处理告警；
- MCP Tool：提供受控的设备查询；
- LangGraph：保存状态和人工审批；
- A2A：把备件查询交给另一个团队的 Agent。

Skill 不应该把 `curl`、数据库密码或高权限 Shell 当便捷步骤。真实能力通过经过认证的 Tool 暴露。

## 13. 版本和兼容性

同时记录：

```text
A2A spec version
Agent Card version/hash
Skill version/hash
Tool schema version
Local graph version
Artifact schema version
```

远端 Schema 增加可选字段通常可兼容；删除字段、改变含义或状态语义需要新版本。运行中的 Task 使用创建时版本，不能被新部署静默改变。

## 14. 评测矩阵

### A2A

- 正确发现能力；
- 不支持能力时拒绝；
- 幂等提交；
- 进度事件有序/可去重；
- 输入请求和取消；
- 远端失败与未知状态；
- Artifact Schema、大小和过期；
- 跨租户、伪造身份和恶意 Agent Card。

### Skill

- 正确触发、错误触发和漏触发；
- 指令执行完整性；
- 缺依赖和无网络降级；
- 脚本参数注入；
- 不同 Host 的行为一致性；
- 更新前后回归；
- 恶意 reference/asset 内容。

指标不只看最终答案，还要看是否选对能力、是否越权、步骤数、远端等待、失败恢复和成本。

## 15. 项目实验

### 实验 A：A2A 模拟服务

不需要真实外部团队。使用 FastAPI/Fake Remote Agent 实现：

1. Agent Card；
2. 创建备件查询 Task；
3. Working → Input Required → Completed；
4. SSE/轮询任选一种进度；
5. Artifact Schema；
6. 幂等、取消和超时未知测试；
7. 将远端任务绑定到本地 LangGraph Thread。

### 实验 B：可移植 Skill

创建 `alarm-triage` Skill，包含一个纯 Python 归一脚本、JSON Schema、10 个测试样本和安全说明。至少在两个支持 Skill 或等价指令加载的环境中验证；若无法访问第二个 Host，写静态兼容性报告并在后续补测。

## 16. 练习与答案

### 练习 1：MCP Server 能否直接改名为 A2A Agent？

**答案：**不能只改名。MCP 暴露工具和资源；A2A 面向独立 Agent 的能力发现、任务生命周期、消息和 Artifact。可以用 MCP Tool 实现某个 Agent 的内部能力，但外部契约不同。

### 练习 2：Agent Card 来自 HTTPS，是否可以完全信任？

**答案：**HTTPS 只保护传输和域名身份的一部分。仍要检查允许来源、服务身份、版本、能力授权、数据策略和内容 Schema，并防止可信服务被配置错误或入侵。

### 练习 3：Skill 是 Markdown，所以没有供应链风险吗？

**答案：**错误。Markdown 可诱导 Agent 执行危险步骤，Skill 还可能包含脚本、依赖、远程下载和资产。需要像代码依赖一样审查来源、Diff、权限和执行环境。

### 练习 4：远端 Agent 回复“用户已批准”，本地能否创建工单？

**答案：**不能。远端无法替代本地用户身份和审批记录。本地 Policy 必须根据可信 Principal、审批 ID、资源状态重新验证。

## 17. 面试追问

1. MCP 与 A2A 的边界是什么？
2. A2A Task 如何映射本地 LangGraph Thread？
3. 网络超时后如何避免远端重复任务？
4. 如何信任和版本化 Agent Card？
5. Skill 与 Tool 有什么区别？
6. 跨 Agent Prompt Injection 如何防御？
7. 什么场景不应该采用 A2A？
8. 远端长任务如何取消、恢复和审计？

## 18. 验收标准

- [ ] 能画出框架内多 Agent、MCP、A2A、Skill 分层图；
- [ ] 完成一个 A2A Task 生命周期模拟；
- [ ] 本地/远端 ID、状态和版本分离；
- [ ] 提交超时、取消、恶意 Artifact 和跨租户用例通过；
- [ ] 完成一个含脚本、资料和测试的可移植 Skill；
- [ ] Skill 安装/更新有供应链审查；
- [ ] 写出采用或不采用 A2A 的 ADR。

## 19. 资料来源

- [A2A Protocol Specification](https://a2a-protocol.org/latest/specification/)
- [A2A Project](https://a2a-protocol.org/latest/)
- [Agent Skills Specification](https://agentskills.io/specification)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/specification/)
- [LangChain Multi-agent](https://docs.langchain.com/oss/python/langchain/multi-agent)
- [LangGraph Subgraphs](https://docs.langchain.com/oss/python/langgraph/use-subgraphs)
- [OWASP Top 10 for Agentic Applications 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/)
- [Google ADK A2A Introduction](https://adk.dev/a2a/)
