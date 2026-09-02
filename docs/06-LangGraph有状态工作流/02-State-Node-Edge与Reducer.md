# State、Node、Edge 与 Reducer

> 预计 7 小时｜产出：类型明确、更新可预测的工单 Graph 骨架。

> **阅读前置**：本章是第 6 阶段（LangGraph 有状态工作流）第 2 章，承接第 1 章的“为什么需要图”，落地 State/Node/Edge/Reducer 的定义。前置要求：第 1 章的五类节点角色与第 4 阶段的 `schemas.py` 契约（`idempotency_key`、`E_*`、`AgentContext`）。本章定义的 State 是第 4 章 Checkpoint 的序列化对象、第 10 章 M4 验收的装配基准。

## 1. 本章从哪里开始

第 1 章画了一张工单拓扑，但“接收请求 → 诊断 → 审批 → 提交”还只是文字。要把拓扑变成可编译、可持久化的 Graph，必须先回答三个问题：

1. **State 里放什么**：哪些字段跨节点需要、可序列化、值得被 Checkpointer 存下来；
2. **Node 怎么改 State**：节点是“原地改全局变量”，还是“返回局部更新”；
3. **多次/并发更新怎么合并**：并行分支各自往同一个字段写时，谁覆盖谁，这就是 Reducer。

本章产出一个 `WorkOrderState` 和一个能编译的最小骨架，它是第 10 章 M4 验收的 `WorkOrderState`（含 `equipment_version`/`action_digest`/`query_rewrite_count` 等完整字段）的逐字来源。

## 2. 本章完成标准（通过门槛）

- `WorkOrderState` 类型明确：消息用 `add_messages`，累积列表用 `operator.add`，其余字段标 `| None`，并用 `total=False` 表达“部分字段可能缺失”；
- 每个 State 字段都有**所有者**（哪个节点写入、哪个节点读取），没有“谁都能改”的字段；
- Node 只返回局部更新 dict，不原地改 State、不塞数据库连接/SDK Client/整个文档对象；
- Reducer 有并发更新、重复更新、空更新三类测试；
- 路由函数返回 `Literal` 枚举，未知值落到 `failed`，不由模型输出任意节点名。

## 3. State 设计原则

State 是图的核心契约。三条原则：

1. **只放跨节点需要的数据**。单节点内部用得到、别的节点不用，就放函数局部变量，不进 State；
2. **必须可序列化**。Checkpointer 要把 State 落盘，数据库连接、SDK Client、文件句柄、整个文档对象都不能放进去；
3. **权威事实按需查询**。State 存引用（`draft_id`、`equipment_id`）与必要快照（`equipment_version`），不把整份手册、整条工单塞进 State；权威对象以业务库为准。

第 10 章 M4 验收的最终 State 如下，本章逐字段解释：

```python
from typing import Annotated, Literal
from typing_extensions import TypedDict

from langchain.messages import AnyMessage
from langgraph.graph.message import add_messages


class WorkOrderState(TypedDict, total=False):
    messages: Annotated[list[AnyMessage], add_messages]
    tenant_id: str
    user_id: str
    equipment_id: str
    equipment_version: int
    evidence_ids: list[str]
    diagnosis: str
    risk_level: Literal["low", "medium", "high"]
    draft_id: str
    draft_version: int
    action_digest: str
    approval_id: str
    approval_status: Literal["pending", "approved", "rejected", "expired"]
    work_order_id: str
    query_rewrite_count: int
    error_code: str
```

`total=False` 表示不是每个字段一开始都有值（`equipment_version`、`draft_id` 是后来才填的）；`messages` 用 `add_messages`，其余字段默认“后写覆盖前写”。

## 4. 字段所有权表

State 字段的“谁写、谁读、谁不许碰”是安全与一致性的关键。下表与 M4 验收的“字段所有权表”一致：

| 字段 | 写入者 | 读取者 | 说明 |
| --- | --- | --- | --- |
| `messages` | 各节点 append | 模型节点 | 对话/推理历史，`add_messages` 合并 |
| `tenant_id`/`user_id` | 外部 Runtime 注入 | 所有 Tool Node | 模型与节点都不得改写 |
| `equipment_id` | `validate_request` | 检索/诊断/提交 | 由请求解析，校验后固定 |
| `equipment_version` | `collect_context` | `revalidate` | 提交前重读比对 |
| `evidence_ids` | `retrieve_knowledge` | `diagnose`/`revalidate` | 必须来自当前租户本次检索 |
| `diagnosis`/`risk_level` | `diagnose` | `create_draft` | 结构化诊断输出 |
| `draft_id`/`draft_version` | `create_draft` | `review_draft`/`revalidate` | 草稿引用与版本 |
| `action_digest` | `create_draft` | `review_draft`/`revalidate` | 审批绑定的动作摘要 |
| `approval_id`/`approval_status` | `review_draft` | `revalidate` | 审批身份与状态 |
| `work_order_id` | `submit_work_order` | `completed` | 提交结果引用 |
| `query_rewrite_count` | `diagnose` | `diagnose`（路由） | 有界循环计数 |
| `error_code` | 任意失败节点 | `failed` | 统一 `E_*` 错误码 |

红线：`tenant_id`/`user_id` 由外部 Runtime Context 传入，任何模型输出、任何用户 Prompt 都不能改写它们——这是第 4 阶段“身份来自服务端”结论在 State 层的延续。

## 5. Reducer：并发与多次更新的合并语义

Reducer 决定“同一个字段被多个分支/多次写”时怎么合并。LangGraph 里，未标 Reducer 的字段默认**覆盖**；标了 Reducer 的字段按你给的函数合并。三种典型：

| 字段类型 | Reducer | 语义 | 风险 |
| --- | --- | --- | --- |
| 消息列表 | `add_messages` | 追加并去重/更新同 ID 消息 | 不追加会丢历史 |
| 累加列表 | `operator.add` | 拼接 | 重放节点会重复 |
| 标量（版本号） | 自定义 max | 取较大版本 | 默认覆盖可能回退 |

`evidence_ids` 若用默认覆盖，两个并行检索分支会互相覆盖，只留下最后一支的结果。正确做法要么 `operator.add`（再在聚合处去重、校验来源），要么由一个聚合节点显式汇总。M4 的不变量“`evidence_ids` 必须来自当前租户本次检索”就要求在合并后重新校验，而不是信任任何单个分支的返回值。

自定义 Reducer 示例（取版本较大者，防回退）：

```python
import operator
from typing import Annotated

def keep_higher_version(a: int, b: int) -> int:
    return a if a >= b else b

class VersionedState(TypedDict, total=False):
    draft_version: Annotated[int, keep_higher_version]
    summaries: Annotated[list[dict], operator.add]
```

关键提醒：Reducer 解决的是 Graph State 的合并，**不能替代业务幂等**。`operator.add` 的列表在节点重放时仍会重复，所以第 7 章会要求副作用节点本身幂等。

## 6. Node：返回局部更新，不原地改

Node 是一个普通函数（可同步可异步），接收当前 State，返回一个**局部更新 dict**；LangGraph 用 Reducer 把它合并进 State。不要原地改 State 对象，也不要返回整个 State：

```python
def validate_request(state: WorkOrderState) -> dict:
    if not state.get("tenant_id") or not state.get("user_id"):
        return {"error_code": "E_FORBIDDEN"}
    if not state.get("equipment_id"):
        return {"error_code": "E_INVALID_ARGUMENT"}
    return {}  # 合法时无更新

async def diagnose(state: WorkOrderState) -> dict:
    # 模型只做语义判断，结构化输出经 Pydantic 校验
    result = await model_diagnose(state["evidence_ids"])
    return {
        "diagnosis": result.diagnosis,
        "risk_level": result.risk_level,
        "query_rewrite_count": state.get("query_rewrite_count", 0) + 1,
    }
```

两条铁律：

1. **不持有跨节点可变状态**：数据库连接、SDK Client 在组合根创建并注入，节点内部用完即弃，不放 State；
2. **不做未声明的副作用**：写操作只发生在明确标记的节点（`create_draft`/`submit_work_order`），且带幂等键（第 7 章）。

## 7. Edge：固定连接与条件路由

```python
from langgraph.graph import END, START, StateGraph

builder = StateGraph(WorkOrderState)

# 固定边：START 只能去 validate_request
builder.add_edge(START, "validate_request")

# 条件边：路由函数返回 Literal，映射到目标节点
def route_after_diagnosis(state: WorkOrderState) -> Literal["need_input", "draft", "fail"]:
    if state.get("error_code") == "E_INTERNAL_ERROR":
        return "fail"
    if not state.get("evidence_ids"):
        return "need_input"
    return "draft"

builder.add_conditional_edges(
    "diagnose",
    route_after_diagnosis,
    {"need_input": "request_missing_input", "draft": "create_draft", "fail": "failed"},
)
```

路由函数三条纪律：

1. **短小、确定、可单测**：只读 State，不做副作用；
2. **返回有限枚举**：`Literal`/`Enum`，不返回模型生成的任意字符串；
3. **未知值落到安全终态**：映射表里找不到的枚举直接进 `failed`，绝不动态执行节点名。

这对应 M4 验收的“路由测试”：每个条件组合必须是表驱动，未知枚举走 `failed`，不能由字符串动态执行节点。

## 8. 最小可编译骨架

把第 1 章拓扑落成骨架（与第 10 章一致，此处只保留关键边以说明语法）：

```python
builder = StateGraph(WorkOrderState)
builder.add_node("validate_request", validate_request)
builder.add_node("collect_context", collect_context)
builder.add_node("retrieve_knowledge", retrieve_knowledge)
builder.add_node("diagnose", diagnose)
builder.add_node("request_missing_input", request_missing_input)
builder.add_node("create_draft", create_draft)
builder.add_node("review_draft", review_draft)
builder.add_node("revalidate", revalidate)
builder.add_node("submit_work_order", submit_work_order)
builder.add_node("completed", completed)
builder.add_node("failed", failed)

builder.add_edge(START, "validate_request")
builder.add_edge("validate_request", "collect_context")
builder.add_edge("collect_context", "retrieve_knowledge")
builder.add_edge("retrieve_knowledge", "diagnose")
builder.add_conditional_edges(
    "diagnose", route_after_diagnosis,
    {"need_input": "request_missing_input", "draft": "create_draft", "fail": "failed"},
)
builder.add_edge("request_missing_input", "diagnose")
builder.add_edge("create_draft", "review_draft")
builder.add_edge("review_draft", "revalidate")
builder.add_conditional_edges(
    "revalidate", route_after_revalidation,
    {"submit": "submit_work_order", "reapprove": "review_draft", "fail": "failed"},
)
builder.add_edge("submit_work_order", "completed")
builder.add_edge("completed", END)
builder.add_edge("failed", END)

graph = builder.compile()
```

`compile()` 不带 Checkpointer 时只适合离线拓扑验证；第 4 章会接入 `checkpointer=InMemorySaver()`（学习）或持久化后端（生产）。`add_node`/`add_edge`/`add_conditional_edges` 是 LangGraph 1.x 的当前写法，具体签名以锁定版本官方文档为准。

## 9. 项目任务

1. 定义 `WorkOrderState` 及至少 7 个节点的输入/输出字段表（照抄 §4 的所有权表并补全）；
2. 为 `messages`（`add_messages`）、`evidence_ids`（`operator.add` 或显式聚合）、`draft_version`（自定义 `keep_higher_version`）各写一个 Reducer 测试；
3. 写三组 Reducer 测试：并发更新、重复更新、空更新，断言合并结果与预期一致；
4. 让 `diagnose → route_after_diagnosis` 走一遍表驱动测试，覆盖 `need_input/draft/fail` 及未知枚举进 `failed`。

## 10. 常见错误与诊断顺序

### 10.1 把数据库连接或 SDK Client 放进 State

根因是图省事、想“哪里都能用”。诊断顺序：先 grep State 字段 → 找出非 JSON 可序列化类型 → 移到组合根注入 → 保留引用 ID 而非对象。症状是 Checkpoint 序列化报错或迁移困难。

### 10.2 列表字段默认覆盖导致丢数据

并行分支都往 `evidence_ids` 写，最后只剩一支。诊断顺序：确认字段是否有 Reducer → 判断语义该“覆盖”还是“累积” → 累积用 `operator.add` 并在聚合处去重校验。不是所有列表都该用 `operator.add`，要按字段语义选。

### 10.3 节点原地改 State 对象

返回了 `None` 却直接 `state["x"] = 1`，LangGraph 拿不到更新。诊断顺序：确认每个 Node 都 `return` 局部更新 dict → 删掉原地赋值 → 用测试断言 State 变化来源可追溯。

### 10.4 路由函数让模型返回节点名

模型返回 `"submit"`，代码直接 `builder.add_edge(from, model_output)` 动态执行。诊断顺序：路由函数必须返回 `Literal` → 映射表白名单 → 未知值进 `failed`。这是命令注入/越权的一类入口，必须封死。

## 11. 练习题与答案

### 练习 1：为什么 State 不应塞入所有历史对象？

**答案：**会让序列化、持久化、隐私、迁移和 Token 管理失控；保存必要事实或引用，权威对象按需查询。State 是跨节点契约，不是仓库。

### 练习 2：节点直接修改数据库后只返回成功标志有何风险？

**答案：**重放节点可能重复副作用；应设计幂等写、记录业务 ID，并明确提交边界。State 里存 `work_order_id` 而不是“我写过了”这个布尔。

### 练习 3：`evidence_ids` 用默认覆盖会怎样？

**答案：**两个并行检索分支只留最后一支，证据链断裂。需要用 `operator.add` 累积或显式聚合，并在合并后校验来源与租户，防止“证据来自别处”。

### 练习 4：`total=False` 的作用是什么？

**答案：**表达部分字段可能缺失（如初始没有 `draft_id`），避免每个字段都强制填 `None` 的样板，同时保留类型检查。

## 12. 工程挑战

1. 为 `keep_higher_version` 写测试，证明并行写 `draft_version=3` 与 `draft_version=5` 后结果是 5，而不是后写覆盖前写；
2. 构造一个“证据来源越界”的 Reducer 反例：一个分支返回别租户的 `evidence_ids`，聚合节点必须拦截并置 `error_code="E_FORBIDDEN"`，反证 Reducer 不是安全边界、校验才是；
3. 用 `graph.get_graph()` 打印 Mermaid 图，确认拓扑与第 1 章 §7 一致，且不存在“孤儿节点”或不可达的 `failed` 终态。

参考方向：第 2 题对应 M4 不变量“`evidence_ids` 必须来自当前租户本次检索”；第 3 题可在 CI 里做成拓扑断言。

## 13. 面试追问

### 13.1 “State 和数据库表有什么区别？”

回答框架：State 是一次业务运行的跨节点执行契约，为 Checkpoint 序列化与恢复服务；数据库是权威事实。State 存引用与快照，权威对象按需查询，二者生命周期、一致性、审计语义不同。

### 13.2 “Reducer 能解决业务幂等吗？”

回答框架：不能。Reducer 只决定 Graph State 字段的合并方式，不回滚、不自动去重外部副作用。节点重放时 `operator.add` 仍会重复追加，业务幂等要靠幂等键（第 7 章）。

### 13.3 “为什么不给每个字段都加 Reducer？”

回答框架：加不加取决于字段语义。默认覆盖对“单写者标量”（如 `draft_id`）是正确的；只有多写者并发字段才需要显式合并。无脑加 Reducer 会让重放产生重复，反而更危险。

## 14. 本章复盘模板

```text
完成日期：
实际投入小时：
WorkOrderState 是否逐字采用 M4 验收字段（含 equipment_version/action_digest/query_rewrite_count）：
每个字段是否都有明确写入者与读取者：
Node 是否只返回局部更新、不原地改 State、不塞连接/Client：
messages/evidence_ids/draft_version 三类 Reducer 是否各有测试：
并发/重复/空更新三类 Reducer 测试是否通过：
路由函数是否返回 Literal 且未知值进 failed：
graph.get_graph() 拓扑是否无孤儿节点、failed 可达：
仍不理解的问题：
```

## 15. 官方资料与中文阅读指引

- [LangGraph Graph API](https://docs.langchain.com/oss/python/langgraph/graph-api)：State/Node/Edge 的官方定义；
- [LangGraph Use the graph API](https://docs.langchain.com/oss/python/langgraph/use-graph-api)：`StateGraph`、`add_node`/`add_edge`/`add_conditional_edges` 的当前用法；
- [LangGraph Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)：State 与 Checkpoint 序列化的关系，为第 4 章铺路。

重点阅读 Graph API 的 State 与 Reducer 章节；`add_messages`、`operator.add` 的导入路径与 `total=False` 语义以锁定版本官方文档为准。

## 16. 下一章入口

本章让 State/Node/Edge/Reducer 有了确定语义与所有权边界。下一章处理“流转”：用 `Command(update=..., goto=...)` 做节点内路由、用 `Send` 做动态并行、给诊断循环加 `query_rewrite_count` 上限，把第 1 章的“有界循环”变成可运行的实现。

**关键闸门**：如果 `WorkOrderState` 里还有“谁都能改”或“不可序列化”的字段，先按 §4 的所有权表清理，否则第 4 章的 Checkpoint 序列化会在中途翻车。
