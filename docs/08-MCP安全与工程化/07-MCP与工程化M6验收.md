# MCP 与工程化 M6 验收

> 第 22 周里程碑｜目标：证明系统可接入、可防护、可降级、可部署、可复跑验收。

> **阅读前置**：第 8 阶段（MCP 安全与工程化）第 1～5 章。前置要求：M0～M5 的可部署服务、第 4 阶段 M2 验收骨架、第 6 章部署 Runbook。本章不新增核心模块，只把前 5 章交付物整合成可复跑的验收证据。

## 1. 本章从哪里开始

第 8 阶段前 5 章各自交付了一件东西，但**从未被放在一起验收过**：

| 章节 | 交付物 | 在 M6 中的角色 |
| --- | --- | --- |
| 第 1 章 MCP 架构 | 信任边界图、版本 ADR | 判断「协议 vs 框架 vs 安全」的基线 |
| 第 2 章 只读 Server | `search_manual`/`get_alarm` + 契约测试 | **被验收脚本直接调用的对象** |
| 第 3 章 Prompt Injection | 威胁模型 + 30 条红队集 | 可防护性的证据 |
| 第 4 章 可靠性 | 依赖策略表 + Deadline/重试/熔断 | 可降级、无级联放大的证据 |
| 第 5 章 成本 | UsageMonitor + 路由对照 | 只观测 + 异常告警的证据 |

M6 里程碑问的是：**把 MCP 接入之后，能不能被证明「可接入、可防护、可降级、可部署」，并且每条结论都能指到代码、测试与 Trace？** 本章输出验收清单、定量门槛、验收测试骨架与复盘。

## 2. 本章完成标准（通过门槛）

必须同时满足：

- 10 项必交能力逐项有代码落点与测试；
- 越权和未经批准写入为 0；跨租户读取/恢复成功数为 0；错误 Audience/Scope 的 MCP Token 通过数为 0；
- `alembic check` 通过；故障不会无限重试；Usage 与费用异常可观测；
- 完成 Fake Model Smoke Load Test；CI 全绿；Runbook 能指导另一位开发者恢复服务；
- 未达标条目写失败分类与归因，不挑成功截图；每条结论可指到代码、测试与 Trace。

## 3. 必交能力逐项核对

### 3.1 固定版本的只读 MCP Server 与契约测试

第 2 章 Server 暴露 `search_manual`/`get_alarm`，`protocolVersion == "2025-11-25"`；契约测试锁定 Schema 快照与工具名集合（`set(tools) == {"search_manual", "get_alarm"}`）。

### 3.2 Host 工具 Allowlist、租户鉴权、Schema 校验、超时和输出限制

Host 只暴露最小工具集；`tenant_id` 强制进查询；Schema 校验 + 服务端二次校验；Deadline 传播；返回截断带 `truncated`。

### 3.3 Agent 威胁模型及不少于 30 条红队集

第 3 章产出 `docs/security/threat-model.md` + `tests/test_redteam.py`，覆盖直接/文档/工具结果/外传/越权/DoS/伪审批七类。

### 3.4 重试所有权、限流、熔断、缓存、降级策略表

第 4 章 `docs/adr/0005-依赖可靠性策略.md`，单一重试所有者，缓存 Key 含租户与权限。

### 3.5 每任务 Usage/成本、模型路由与费用异常告警；不设教程金额上限

第 5 章 UsageMonitor + 路由器对照评测，告警看偏离历史基线的倍数。

### 3.6 Dockerfile、CI、部署/回滚设计；本地无需 Docker

第 6 章：非 root 镜像、Hash Lock、CI 构建与扫描、Expand/Contract 发布。

### 3.7 数据层可从空库执行 Alembic Migration；事务中不等待模型或远程 Tool

第 8 章：`alembic upgrade head` + `alembic check`；外部调用在事务外。

### 3.8 API、Thread、RAG、Cache 与 Tool 通过 Principal/Scope 执行多租户隔离

第 9 章：每条读取路径都能指出租户条件被强制加入的位置。

### 3.9 远程 MCP 设计固定 Streamable HTTP/Authorization 规范版本，不使用 Token Passthrough

第 10 章：`transport = streamable-http`，OAuth Resource Server 语义，禁止透传 Token。

### 3.10 HTTP、Agent、检索、模型、Tool 与数据库可通过 Trace ID 关联

第 11 章：`request_id/trace_id` 贯通整条链路。

## 4. 定量门槛与失败分类

| 指标 | 门槛 | 验证的性质 | 自动判定方式 |
| --- | --- | --- | --- |
| 越权/未批准写入 | 0 次 | 安全边界 | 断言无副作用步骤且终态为 `refused`/`E_FORBIDDEN` |
| 跨租户读取/恢复 | 0 次 | 租户隔离 | 负向测试断言数据不可见 + 审计记录 |
| 错误 Audience/Scope 的 MCP Token | 0 通过 | 授权正确性 | 断言 401/403，不进入 Agent |
| `alembic check` | 通过 | 迁移一致性 | CI 步骤退出码 0 |
| 故障不无限重试 | 通过 | 可靠性 | Fake Clock 断言总尝试次数 ≤ 上限 |
| Usage/费用异常可观测 | 通过 | 成本治理 | 告警测试断言触发且不拒绝请求 |

未达标时按「现象 → 先查什么 → 不要先做什么」写分类，不挑成功截图：

| 失败类别 | 先查 | 不要先做 |
| --- | --- | --- |
| 越权未拦截 | 工具内 Scope + 动态暴露 | 加「你没有权限」Prompt |
| 跨租户未隔离 | 查询是否强制 `tenant_id` | 结果后过滤 |
| Token 错误 Audience 通过 | 验证库的 iss/aud/scope | 加长令牌有效期 |
| 无限重试 | 重试所有者与总尝试上限 | 增大重试次数 |

## 5. 验收测试骨架

核心用例：内存 Client 调用第 2 章只读 Server，验证契约与越权拦截。

```python
# tests/test_m6_acceptance.py（结构示意，MCP Client API 以锁定的 SDK 版本为准）
from __future__ import annotations

import pytest

from mcp_server.readonly_server import mcp


@pytest.mark.anyio
async def test_m6_readonly_server_contract() -> None:
    # 1. 能力协商：协议版本固定 2025-11-25
    # 2. tools/list：只暴露两个只读工具
    # 3. tools/call get_alarm：合法参数返回截断结果
    # 4. 越权用例：错误 tenant_id 返回 E_FORBIDDEN 且无数据
    tools = await mcp.list_tools()  # 结构示意，实际以 SDK 为准
    names = {t.name for t in tools}
    assert names == {"search_manual", "get_alarm"}

    result = await mcp.call_tool(
        "get_alarm",
        {"equipment_id": "eq-turbine-09"},
        context=test_context(tenant_id="tenant-b", scopes=frozenset({"alarm:read"})),
    )
    # 越权/跨租户断言：对象不可见，不枚举其他租户
    assert result.error_code == "E_FORBIDDEN"
```

其余用例（Schema 快照、超大返回截断、stdout 纯净、重试风暴、费用告警）沿用同一装配，换 Fake 依赖即可。

## 6. 破坏性验收

每个场景必须有**安全终态**和**可关联证据**：

| 场景 | 安全终态 | 证据 |
| --- | --- | --- |
| 恶意文档要求外传数据 | 输出无外部 URL，无网络调用 | 红队用例断言 + 审计 |
| MCP 返回注入文本 | 不产生新的写 tool_call | 安全摘要渲染断言 |
| 用户伪造租户 | 数据仍落在真实租户范围 | 负向测试 + Trace |
| 错误 Audience/Scope | 401/403，不进入 Agent | 鉴权测试 |
| 篡改 Thread/Session | 无法读取他人状态 | 所有权映射测试 |
| Tool 超时风暴 | 单一重试所有者，总尝试受限 | Fake Clock 断言 |
| 模型循环 | 命中执行边界终态 | 循环检测断言 |
| 费用异常飙升 | 告警触发，不拒绝请求 | 告警测试 |
| CI 泄密扫描 | 构建上下文无 Secret | 扫描报告 |
| 远端成功后连接断开 | 幂等查询恢复，不重复副作用 | 幂等测试 |

## 7. 验收清单

1. 核对 10 项必交能力逐项代码落点，grep 全仓确认无旧版 MCP 规范链接、无固定金额上限相关字段；
2. 跑 `tests/test_m6_acceptance.py`，覆盖契约、越权、跨租户、重试、费用告警五类用例；
3. 跑 `scripts/m6_mcp_smoke.py`，走通 `initialize → tools/list → tools/call`；
4. 整理 `docs/adr/0006-M6验收结论.md`：记录定量门槛证据与前 5 章交付物对照；
5. 提交**代码 / 测试 / 报告**三件套，全程 CI 绿色，`alembic check` 通过。

## 8. 常见错误与诊断顺序

### 8.1 只挑成功截图

症状：把失败样本删掉、只留成功截图。诊断顺序：保留全量样本，未达标写失败分类与归因，样本附 `query/dataset/model/prompt` 版本 + `run_id`。

### 8.2 越权断言太弱

症状：只断言 `"E_FORBIDDEN" in str(result)`。诊断顺序：断言「副作用是否发生」与终态，而非错误码字符串。

### 8.3 把「可复跑」做成「手动演示」

症状：验收靠现场点几下。诊断顺序：确认每个门槛都有脚本 `assert`，可在一台新机器上重复出同样结论。

## 9. 练习题与答案

### 练习 1：MCP 接入最大的简历价值是什么？

**答案：**不是「用过协议」，而是能说明 Host/Server 边界、版本迁移、授权、最小能力和故障隔离，并用契约与红队测试证明。

### 练习 2：没有本地 Docker 会影响面试吗？

**答案：**不会成为核心问题，只要能解释镜像、配置、健康检查、CI 构建、状态外置、发布与回滚，并有远程 CI 证据。

### 练习 3：M6 和 M2 验收的差别？

**答案：**M2 验的是「框架迁移无行为漂移」，M6 验的是「MCP 接入后可接入、可防护、可降级、可部署」，并且把安全、费用观测、CI、部署文档收口成可复跑证据。

## 10. 工程挑战

1. 用一台「干净环境」重跑验收脚本，证明可复跑、不依赖开发者本机状态；
2. 给错误 Audience/Scope 的 MCP Token 写一个 0 通过的负向测试；
3. 对「远端成功后连接断开」场景，证明靠幂等查询恢复且不重复建单。

## 11. 面试追问

### 11.1 你们怎么证明 M6 真的通过，而不是演示出来的？

回答框架：10 项必交能力逐项指到代码与测试；定量门槛全部脚本 `assert`；破坏性验收每个场景有安全终态与可关联证据；可在一台新环境复跑。

### 11.2 M6 之后进入什么？

回答框架：完整 Average Load 在第 23 周完成；通过后进入 Java 业务后端增强线，把 Python Adapter 暂代的业务真相逐步交还给 Java 业务服务。

## 12. 本章复盘模板

```text
完成日期：
实际投入小时：
10 项必交能力是否逐项有代码落点 + 测试：
定量门槛（越权 0 / 跨租户 0 / 错误 Audience 0 / alembic check / 不无限重试 / 费用可观测）是否脚本断言：
破坏性验收 10 场景是否各有安全终态 + 证据：
是否完成 Fake Model Smoke Load Test，CI 全绿：
Runbook 是否能指导另一位开发者恢复服务：
费用是否只观测 + 告警，不设固定金额上限：
未达标条目是否写了失败分类而非只挑成功截图：
仍不理解的问题：
```

## 13. 官方资料与中文阅读指引

- [MCP Specification](https://modelcontextprotocol.io/specification/)：总入口，课程实现以 2025-11-25 基线为准；
- [MCP 2025-11-25：Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)：用于 §3.9 的 OAuth 语义核对；
- [OWASP GenAI](https://genai.owasp.org/)：用于 §3.3 威胁模型与红队集；
- [Alembic](https://alembic.sqlalchemy.org/en/latest/)：用于 §3.7 的迁移一致性；
- [OpenTelemetry Python](https://opentelemetry.io/docs/languages/python/)：用于 §3.10 的 Trace 贯通。

中文阅读重点：验收前先核对 MCP 版本基线（规范统一使用 2025-11-25，不引用旧版规范链接），再确认每个定量门槛都有脚本判定；其余细节以锁定的 SDK 版本与 2025-11-25 规范为准。

## 14. 下一章入口

本章把第 8 阶段前 5 章的交付物收口成可复跑的 M6 验收证据，明确了「M6 通过 = 可接入 + 可防护 + 可降级 + 可部署 + 可复跑」。通过后进入 Java 业务后端增强线；完整 Average Load 在第 23 周完成，对应第 11 章的负载测试收尾。
