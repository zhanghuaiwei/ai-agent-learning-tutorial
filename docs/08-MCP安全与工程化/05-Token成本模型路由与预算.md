# Token 成本、模型路由与调用治理

> 预计 6 小时｜产出：只观测 Usage 与异常增长、不设固定金额上限的调用治理层。

> **阅读前置**：本阶段第 4 章（超时/重试/降级）与第 11 章（SLO 与告警）。前置要求：第 4 阶段的 `usage_record` 字段直觉、第 8 阶段的 `tool_execution/usage_record` 数据模型、第 12 章的模型网关路由。本章不新增「扣费」逻辑，只做观测与对照。

## 1. 本章从哪里开始

第 4 章让每次调用都「有确定行为」，但行为是有价的：一次 Agent 可能包含规划、三次工具、修复和总结，Token 和费用分散在多次调用里。本章回答两个问题：**如何让成本可观测**（每次调用记了什么、按什么维度聚合），以及**费用异常时先做什么**（定位根因，而非静默降级）。核心立场：教程只观测 Usage + 异常增长告警，**不设固定金额上限**，也不因累计费用自动拒绝请求。

## 2. 本章完成标准（通过门槛）

- 每次调用记录输入/输出 Token、缓存 Token（如供应商提供）、单价版本、估算成本、任务、模型与是否重试；
- 计费表放配置并标记生效日期，不硬编码散落各处；
- 成本按任务聚合（而非只看单次调用），并统计失败任务成本、P50/P95 与每成功任务成本；
- 有模型路由器，路由决策有对照评测（成功率、延迟、成本）；
- 有异常增长告警：单位成功任务成本或小时费用偏离历史基线时告警，且告警链到 Runbook。

## 3. 成本可观测

每次模型调用至少记录：

```text
request_id / trace_id / task_id / tenant_id
logical_model / provider
input_tokens / output_tokens / cache_tokens
estimated_cost / billing_unit
retry_count / final_route / status
latency_ms
```

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class UsageRecord:
    request_id: str
    task_id: str
    tenant_id: str
    model: str
    input_tokens: int
    output_tokens: int
    cache_tokens: int
    unit_price: float       # 来自配置，带生效日期
    estimated_cost: float   # 按 unit_price 估算的人民币成本
    retry_count: int
```

价格会变化，计费表不能硬编码散落；放配置并标记生效日期：

```yaml
pricing:
  qwen-primary:
    input_per_mtok: 0.0      # 示例值，实施时以官方为准
    output_per_mtok: 0.0
    effective_from: "2026-08-01"
  deepseek-compatible:
    input_per_mtok: 0.0
    output_per_mtok: 0.0
    effective_from: "2026-08-01"
```

## 4. 按任务聚合，而不是只看单次调用

一次 Agent 的成本 = 规划 + 工具 + 修复 + 总结的总和。只看单次调用会漏掉「循环导致 12 次调用」这类真正的问题。聚合口径：

- 每任务成本 = 该任务所有模型调用的 `estimated_cost` 之和；
- 失败任务成本 = 未到成功终态却已消耗的费用；
- P50/P95 = 成功任务成本分布；
- 每成功任务成本 = 总成本 / 成功任务数，这是最关键的治理指标。

## 5. 模型路由与降本顺序

降本顺序要严格排序，最后才牺牲质量：

```text
消除无用调用与循环
  → 压缩 Tool 结果/检索重复
  → 小模型处理简单任务
  → 缓存稳定结果
  → 批量离线评测
  → 最后才牺牲质量
```

盲目缩短 Prompt 可能破坏安全规则。路由按规则与评测：

```python
def route(task: TaskShape) -> str:
    if task.kind in {"structure_extract", "classify"}:
        return "small-model"
    if task.kind == "diagnosis":
        return "qwen-primary"
    return "default"
```

结构抽取/分类用低价模型，复杂诊断候选用较强模型；高风险最终仍需证据与人工，不靠昂贵模型自动放权。

## 6. 调用治理：只观测 + 异常增长告警

教程不分配月度金额，也不因累计费用自动拒绝请求。按四类统计：

| 统计类别 | 说明 | 关注点 |
| --- | --- | --- |
| 日常交互 | 真实用户使用 | 每成功任务成本基线 |
| 在线评测 | Eval 与对照实验 | 是否与线上混算 |
| 演示 | Demo/内部试用 | 是否单独打标 |
| 失败浪费 | 未到成功终态 | 循环、重复检索占比 |

当单位成功任务成本或小时费用偏离历史基线时告警，重点排查：循环、重复检索、上下文膨胀、多层重试和路由错误。告警必须链到 Runbook（第 6 章）。

## 7. UsageMonitor 与路由器实现

```python
class UsageMonitor:
    def record(self, usage: UsageRecord) -> None:
        # 写入 usage_record，供聚合与告警
        self.sink.write(usage)

    def alert_if_anomalous(self, *, window_minutes: int = 60) -> list[str]:
        baseline = self.history.baseline()
        current = self.history.last(window_minutes)
        if current.per_success_cost > baseline.p95_per_success_cost * 1.5:
            return ["unit_success_cost_anomaly"]
        return []
```

关键点：告警看的是**偏离历史基线的倍数**，不是撞到某个预设金额。费用账还要与供应商后台抽样核对，防止配置里的单价过期导致估算失真。

## 8. 项目任务

1. 实现 `UsageMonitor` 与模型路由器；
2. 回放历史轨迹，比较三种策略（全部大模型 / 全小模型 / 规则路由）的成功率、延迟和成本；
3. 写对照评测报告，费用账与供应商后台抽样核对；
4. 写一条「单位成功任务成本异常增长」的告警测试，断言告警触发但不拒绝请求。

## 9. 常见错误与诊断顺序

### 9.1 费用升高时静默切到最便宜模型

症状：为省钱自动降级，质量退化被成功率掩盖。诊断顺序：先定位增长根因，再依据质量、延迟和业务风险决定路由；不能为降低费用而无评测地牺牲关键任务质量。

### 9.2 只看单次调用成本

症状：漏掉循环和重复检索。诊断顺序：按任务聚合，看每成功任务成本与 P95，再拆解到工具调用次数与上下文长度。

### 9.3 计费单价硬编码散落

症状：价格变了，估算失真。诊断顺序：单价收敛到配置并标生效日期，抽样核对供应商后台。

## 10. 练习题与答案

### 练习 1：失败调用也要计费吗？

**答案：**很多情况下会产生 Token/请求费用；应按供应商 usage 记录，缺失时保守估算。

### 练习 2：费用突然升高时静默切到最便宜模型好吗？

**答案：**不好。先定位增长根因，并依据质量、延迟和业务风险决定路由；不能为降低费用而无评测地牺牲关键任务质量。

### 练习 3：为什么按任务聚合成本，而不是只看单次调用？

**答案：**一次 Agent 由多次调用组成，单次调用会漏掉循环、重复检索和上下文膨胀；每成功任务成本才是治理的关键指标。

## 11. 工程挑战

1. 回放一条「循环调用 12 次」的轨迹，证明单次调用成本看着正常、但每成功任务成本异常；
2. 给路由器写对照评测：全大模型 / 全小模型 / 规则路由，输出成功率、延迟、成本三列；
3. 模拟单价配置过期，验证费用估算偏离供应商后台并被抽样核对发现。

## 12. 面试追问

### 12.1 你们怎么控制 Token 成本？

回答框架：先观测——每次调用记 Usage，按任务聚合出每成功任务成本；再治理——异常增长告警，排查循环/重复检索/上下文膨胀/重试/路由错误；路由靠规则 + 对照评测。不设固定金额上限，不做「撞线就拒」。

### 12.2 为什么不做固定金额上限？

回答框架：固定上限会把正常业务和浪费一刀切，且金额本身会随价格波动失效。更可靠的是观测 Usage + 异常增长告警，让异常显形并定位根因，同时用评测保证降本不降质。

## 13. 本章复盘模板

```text
完成日期：
实际投入小时：
每次调用是否记录 input/output/cache Token + 单价版本 + 估算成本 + 重试：
计费表是否配置化并标记生效日期：
成本是否按任务聚合，是否统计失败任务成本与每成功任务成本：
是否有模型路由器，路由是否有对照评测：
是否有异常增长告警且链到 Runbook：
是否确认只观测 + 告警，不设固定金额上限：
仍不理解的问题：
```

## 14. 官方资料与中文阅读指引

- [DeepSeek 计费](https://api-docs.deepseek.com/quick_start/pricing)：重点看 Token 计价口径与缓存命中，用于 §3；
- [阿里云百炼模型价格](https://help.aliyun.com/zh/model-studio/model-pricing)：重点看不同模型的单价差异，用于 §5 路由对照；
- [LiteLLM Proxy 成本与 Usage](https://docs.litellm.ai/docs/proxy/cost_tracking)：重点看统一计费与 Usage 归一，用于 §7 的 UsageMonitor。

中文阅读重点：先看计费口径（input/output/cache 分开），再看路由对照怎么做；单价一律以官方为准、配置化并标生效日期，不凭记忆写价格。

## 15. 下一章入口

本章把成本做成了可观测、可对照、可告警的治理层，且明确「只观测 + 异常告警、不设固定金额上限」。至此，前 5 章的交付物——只读 Server、威胁模型、可靠性层、成本观测——都已就位。下一章（第 8 阶段第 7 章）是 M6 验收，把它们收口成可复跑的验收证据。
