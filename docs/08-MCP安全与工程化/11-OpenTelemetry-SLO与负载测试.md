# OpenTelemetry、SLO 与负载测试

> 补缺章节｜预计 8 小时｜产出：能从用户请求追到模型、检索、工具和数据库，并用负载测试证明系统边界。

## 1. LangSmith 不能替代全部生产可观测性

LangSmith 擅长 LLM/Agent Trace、Dataset 和 Evaluation；企业服务还必须观察 HTTP、数据库、缓存、连接池、CPU/内存和跨服务调用。

推荐关联而不是二选一：

```text
request_id / trace_id
  ├── HTTP span
  ├── Agent run / LangSmith trace
  ├── retrieval span
  ├── model span
  ├── tool span
  │    └── Java HTTP + database span
  └── SSE lifecycle metrics
```

同一请求在日志、Metric、OpenTelemetry Trace、LangSmith Run 和业务审计中应能通过安全标识关联，但不要把完整 Prompt 或用户 ID 作为 Metric Label。

## 2. Logs、Metrics、Traces、Evals 的职责

| 信号 | 回答的问题 | 示例 |
| --- | --- | --- |
| Logs | 具体发生了什么 | Tool 返回 409，已按幂等键查询 |
| Metrics | 整体是否异常 | P95、错误率、活跃运行数、循环终止数 |
| Traces | 时间花在哪里、调用如何传播 | HTTP → RAG → Model → Java API |
| Evals | 输出和轨迹质量是否合格 | 引用正确率、Tool 选择率、越权数 |

只看日志难以发现总体退化；只看 Trace 不能证明样本质量；只看 Eval 也看不到连接池耗尽。

## 3. OpenTelemetry 最小接入

课程使用 OpenTelemetry 生成 Trace 与 Metrics，Exporter 由配置决定。本地可以输出到 Console/文件，部署环境再接 OTLP Collector。

```python
from opentelemetry import metrics, trace

tracer = trace.get_tracer("smart-maintenance-agent")
meter = metrics.get_meter("smart-maintenance-agent")

agent_runs = meter.create_counter(
    "agent.runs",
    description="Agent runs by final status",
)
agent_duration = meter.create_histogram(
    "agent.run.duration",
    unit="s",
    description="End-to-end Agent run latency",
)


async def run_agent(command: AgentCommand) -> AgentResult:
    with tracer.start_as_current_span("agent.run") as span:
        span.set_attribute("agent.graph.version", command.graph_version)
        span.set_attribute("agent.prompt.version", command.prompt_version)
        result = await agent_service.execute(command)
        agent_runs.add(1, {"status": result.status})
        agent_duration.record(result.duration_seconds)
        return result
```

身份、Tenant、Thread 等高基数字段放到受控 Trace/Log 属性并按隐私策略处理，不放入 Prometheus Label。每多一种 Label 组合都会产生新的时间序列。

## 4. Context Propagation

跨 Python → Java 请求传播标准 Trace Context，并单独保留业务 Request ID：

```text
traceparent: 00-<trace-id>-<span-id>-01
tracestate: vendor-specific
x-request-id: application-level correlation id
```

不要让客户端任意覆盖内部 Trace/Principal。入口可接收外部 Trace，但要按信任策略采样和限制 Baggage；用户输入、Token、Prompt 全文不要塞入 Baggage，因为它会传播到多个服务。

异步并发分支应成为同一父 Span 的子 Span。后台任务若脱离请求生命周期，要显式保存/链接 Context，不能靠全局变量。

## 5. Agent 核心指标

### 在线服务

- `http.server.requests`：请求数、状态、路由；
- `http.server.duration`：TTFT 与完整响应耗时分开；
- `sse.active_connections`、断开数和完成事件数；
- `agent.runs`：成功、拒答、等待审批、失败、取消；
- `agent.steps`、循环终止数、Tool Call 数；
- `model.calls`、Token、延迟、限流、重试；
- `tool.calls`：Tool 名、结果类别、延迟；
- `checkpoint.operations`：读写错误与延迟；
- 数据库连接池使用率、等待和超时。

### RAG 与质量

- 摄取成功/失败、文档版本和待重建数；
- 检索空结果率、Recall/引用/忠实度来自离线或抽样 Eval；
- 不把每个 Query 文本做 Label；
- 不将业务质量指标和基础设施指标混成一个“Agent 成功率”。

### 安全

- 未认证、缺 Scope、跨租户拒绝；
- Prompt Injection/敏感输出拦截；
- 未审批写操作拦截；
- 审计指标仅记录安全类别，具体对象放受保护审计日志。

## 6. SLI、SLO 和 Error Budget

SLI 是测量方式，SLO 是目标，Error Budget 是允许的不达标空间。例如：

```text
SLI：合法请求中，在 20 秒内到达成功/有依据拒答/等待审批终态的比例
SLO：滚动 7 天 ≥ 99%
```

Agent 的“成功”不能只看 HTTP 200。以下都要明确分类：

- 有依据完成；
- 证据不足而正确拒答；
- 合法等待人工审批；
- 业务冲突；
- 模型/工具/基础设施失败；
- 安全拦截；
- 用户取消。

初始 SLO 必须来自 Baseline 和业务风险，不应为了好看拍脑袋。教程给出的数值是练习起点，跑出真实分布后写 ADR 调整。

## 7. 告警设计

避免“任意一次失败就报警”。优先使用能代表用户影响和需要行动的信号：

| 告警 | 触发思路 | 第一诊断动作 |
| --- | --- | --- |
| Agent 失败率升高 | 多窗口错误率偏离 SLO | 按 graph/model/tool/version 分解 |
| P95/TTFT 退化 | 连续窗口超过基线 | 查看 Trace 中模型、检索、连接池 |
| 循环异常 | 步骤数/重复 Tool 显著上升 | 检查 Prompt、Tool Error、路由版本 |
| 跨租户拒绝突增 | 安全拒绝高于历史基线 | 排查攻击、前端 Bug、鉴权配置 |
| 单位成功任务费用突增 | 偏离历史基线 | 检查上下文膨胀、重试和模型路由 |

每个告警必须链接 Runbook，包含影响判断、止血、诊断、恢复和结束条件。

## 8. 负载测试为什么要使用 Fake Model

性能测试首先测你的系统，而不是无授权地冲击模型供应商。默认方案：

- Fake Model 提供可配置延迟、流式 Chunk、429、超时和非法输出；
- Fake Retriever/Business API 提供可配置延迟与错误；
- 协议级负载主要请求 FastAPI，不启动大量浏览器；
- 少量真实模型 Smoke Test 只验证集成，不用于制造高并发；
- 不对不属于你的第三方 API 做负载测试。

这样可以稳定复现连接池、SSE、取消、并发限制和排队行为，也不会把供应商波动误认为本地性能。

## 9. k6 最小场景

可以直接使用 JavaScript 编写协议级测试：

```javascript
import http from "k6/http";
import { check } from "k6";

export const options = {
  scenarios: {
    agent_api: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: "30s", target: 10 },
        { duration: "60s", target: 10 },
        { duration: "30s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<2000"],
  },
};

export default function () {
  const response = http.post(
    `${__ENV.BASE_URL}/v1/agent/runs`,
    JSON.stringify({ message: "查询 EQ-001 告警" }),
    {
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${__ENV.TEST_TOKEN}`,
      },
    },
  );
  check(response, {
    "accepted": (r) => r.status === 200 || r.status === 202,
  });
}
```

示例阈值不是最终 SLO。先 Smoke，再 Average Load，再 Stress；每次测试固定 Fake 延迟、数据集、机器配置和代码版本，才可比较。

## 10. Agent 专项性能场景

1. 非流式 30 并发，观察连接池和任务排队。
2. SSE 10 个慢消费者，验证背压、缓冲上限和断开清理。
3. 一个上游持续 429，验证有限重试和熔断，避免重试风暴。
4. 同一 Thread 并发恢复，验证冲突策略。
5. 100 个重复审批请求，验证幂等且只创建一次工单。
6. RAG 索引切换期间查询，验证版本一致性。
7. Checkpointer 变慢，确认 P95 告警和受控降级。
8. Java API 成功后超时，确认恢复查询而非重复创建。

每个场景同时记录吞吐、P50/P95/P99、错误类型、CPU/内存、连接池、模型/工具步骤和最终业务正确性。性能更快但出现重复工单不算优化成功。

## 11. 练习与答案

### 练习 1：为什么不能把 `user_id` 作为 Prometheus Label？

**答案：**用户数量会造成高基数时间序列，显著增加监控资源并带来隐私风险。用户级定位放受保护的 Trace/Log，Metric 只保留低基数业务维度。

### 练习 2：HTTP 200 率 99.9%，能说明 Agent 成功率高吗？

**答案：**不能。接口可能用 200 返回无依据幻觉、错误 Tool 或重复副作用。需要定义业务终态、质量 Eval 和安全指标。

### 练习 3：真实模型无限预算，是否应直接用它做 100 并发压测？

**答案：**不应。问题不是预算，而是供应商限流、测试可重复性和对第三方服务的授权。用 Fake 模拟可控延迟/错误，真实模型只做合规的集成与容量验证。

## 12. 验收标准

- 一次请求可从 FastAPI Trace 定位到 Agent、检索、模型、Tool、Java API 与数据库；
- Metrics 无用户、Thread、Prompt 等高基数/敏感 Label；
- 至少定义可计算的可用性、延迟和业务成功 SLI，并说明分母；
- 完成 Smoke、Average Load、慢 SSE、429 风暴和幂等并发测试；
- 性能报告记录环境、Fake 行为、版本、负载模型、阈值与瓶颈；
- 至少修复一个经 Trace/Metric 证明的瓶颈，并用同一场景回归。

## 13. 资料来源

- [OpenTelemetry Python](https://opentelemetry.io/docs/languages/python/)
- [OpenTelemetry Python Instrumentation Libraries](https://opentelemetry.io/docs/languages/python/libraries/)
- [Prometheus Instrumentation Best Practices](https://prometheus.io/docs/practices/instrumentation/)
- [Grafana k6 API Load Testing](https://grafana.com/docs/k6/latest/testing-guides/api-load-testing/)
- [Grafana k6 Automated Performance Testing](https://grafana.com/docs/k6/latest/testing-guides/automated-performance-testing/)
- [Google SRE Workbook：Implementing SLOs](https://sre.google/workbook/implementing-slos/)

