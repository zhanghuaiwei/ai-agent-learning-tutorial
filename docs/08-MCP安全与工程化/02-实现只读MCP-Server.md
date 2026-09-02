# 实现只读 MCP Server

> 预计 8 小时｜产出：暴露设备与告警查询的最小权限 MCP Server，可被 M6 验收脚本调用。

> **阅读前置**：本阶段第 1 章（MCP 架构与协议心智模型）。前置要求：第 2 阶段的 Pydantic 契约、第 3 阶段 Function Calling 的三个工具（`search_manual`/`get_alarm`/`create_work_order_draft`）与 `AgentAnswer`、第 5 阶段的 `E_*` 错误码契约。不依赖本章之后的远程/OAuth 章节。

## 1. 本章从哪里开始

第 1 章说清了「MCP 是连接协议」，但没有一行代码。本章把智维 Agent 的三个既有工具封装成最小权限的 MCP Server：只暴露 `search_manual`、`get_alarm` 两个只读 Tool；`create_work_order_draft` 是可逆写，若开放必须走审批门，默认不进入只读 Server。目标是让第 7 章 M6 验收脚本能用一个内存 Client 完成 `initialize → tools/list → tools/call` 并断言契约。

核心立场只有一句：**只读不等于无风险**。只读 Server 仍会被模型循环调用、批量枚举敏感数据、或通过错误参数拖垮下游，因此限流、租户过滤、返回截断和契约测试一个都不能少。

## 2. 本章完成标准（通过门槛）

- Server 只暴露 `search_manual`/`get_alarm` 两个只读 Tool，无通用 SQL、Shell、文件系统或任意 URL 抓取能力；
- 每个 Tool Schema 写清字段长度、枚举、返回上限与错误码，服务端**再次**校验输入；
- 所有读取路径强制 `tenant_id` 过滤，越权返回 `E_FORBIDDEN` 且不枚举其他租户对象；
- 结果只返回业务所需字段，列表数量与正文大小有硬上限并截断；
- `initialize`、`tools/list` Schema 快照、正常/未知设备/非法参数/越权/上游超时/超大返回截断/并发限制/日志不污染 stdout 全部有测试。

## 3. 只读范围：两个工具 + 一个审批门

| 工具 | 分级 | 副作用 | MCP Server 中的暴露策略 |
| --- | --- | --- | --- |
| `search_manual` | `read` | 无 | 暴露，返回精简片段 + `evidence_ids` |
| `get_alarm` | `read` | 无 | 暴露，按 `equipment_id` + `tenant_id` 过滤 |
| `create_work_order_draft` | `reversible_write` | 建草稿 | 默认不暴露；开放时经 HITL 审批 + 幂等键 |

Server 内部调用 Fake 或受控业务 API，不直连数据库。Fake 与真实业务 API 共享同一接口，使 M6 验收可以离线复跑（与第 4 阶段 M2 的 `ScriptedFakeModel` 思路一致）。

## 4. Server 骨架（stdio）

本机练习优先 stdio，无需 Docker。下面是结构示意，具体装饰器以锁定的 Python SDK 版本为准：

```python
# mcp_server/readonly_server.py（结构示意，API 以锁定的 python-sdk 版本为准）
from __future__ import annotations

from mcp.server.fastmcp import FastMCP

from app.services import equipment_service

mcp = FastMCP("smart-maintenance-readonly")


@mcp.tool()
def search_manual(query: str, top_k: int = 5) -> dict:
    """在设备维护手册中按问题检索证据片段，返回精简片段与 evidence_ids。"""
    return equipment_service.search_manual(query=query, top_k=top_k)


@mcp.tool()
def get_alarm(equipment_id: str, limit: int = 20) -> dict:
    """查询某台设备的活动告警，仅返回当前租户可见数据。"""
    return equipment_service.get_alarm(equipment_id=equipment_id, limit=limit)
```

关键约束：

1. stdout 只能输出合法 MCP 消息，日志写 stderr；
2. Tool 描述是给模型的**选择提示**，不是安全边界；
3. 服务端在 `equipment_service` 内部再次校验参数、Scope 与 `tenant_id`，不能只依赖 SDK 的 JSON Schema 校验。

## 5. Tool Schema 与服务端校验

`tools/list` 返回的 Schema 是给 Client 和模型的结构约束，但业务规则仍要服务端再查一次：

```json
{
  "name": "get_alarm",
  "description": "查询设备活动告警",
  "inputSchema": {
    "type": "object",
    "properties": {
      "equipment_id": { "type": "string", "minLength": 3, "maxLength": 64 },
      "limit": { "type": "integer", "minimum": 1, "maximum": 50 }
    },
    "required": ["equipment_id"]
  }
}
```

```python
from app.errors import AppError

class AppError(Exception):
    def __init__(self, code: str, message: str, safe: bool = True):
        self.code = code          # E_* 错误码
        self.message = message    # 安全摘要
        self.safe = safe          # 是否可返回给模型

def validate_equipment_id(equipment_id: str) -> None:
    if not (3 <= len(equipment_id) <= 64):
        raise AppError("E_INVALID_ARGUMENT", "equipment_id 长度非法", safe=True)
```

Schema 校验拦截的是**结构**错误，服务端校验拦截的是**业务**错误（枚举、租户、状态）。两层都要有，缺一层都会被绕过。

## 6. 调用身份与租户过滤

身份必须由 Host/服务端注入，不能让模型在 Tool 参数里填 `tenant_id`。Server 侧从运行时上下文取 Principal：

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class MCPContext:
    user_id: str
    tenant_id: str
    scopes: frozenset[str]
    request_id: str


async def get_alarm(ctx: MCPContext, equipment_id: str, limit: int = 20) -> dict:
    require_scope(ctx, "alarm:read")
    return await alarm_service.get_visible(
        tenant_id=ctx.tenant_id,
        equipment_id=equipment_id,
        limit=limit,
    )
```

越权或跨租户请求返回 `E_FORBIDDEN`，且**不区分**「对象不存在」与「不可见」，对外统一不可见，对内审计记录真实原因（与第 9 章 RBAC 一致）。

## 7. 返回截断与错误码

只读结果同样要截断：

```python
def get_alarm(equipment_id: str, limit: int) -> dict:
    rows = alarm_service.query(equipment_id, limit=limit)
    if len(rows) > limit:
        rows = rows[:limit]
        truncated = True
    return {"equipment_id": equipment_id, "alarms": rows, "truncated": truncated}
```

错误码沿用 `E_*` 契约，模型可修正与不可修正分开：

| 错误码 | 含义 | 模型可修正？ |
| --- | --- | --- |
| `E_INVALID_ARGUMENT` | 参数格式/枚举错 | 可提示修正一次 |
| `E_NOT_FOUND` | 对象不存在或不可见 | 否，不枚举其他租户 |
| `E_FORBIDDEN` | 越权 | 否，安全终止 |
| `E_UPSTREAM_TIMEOUT` | 上游超时 | 按读/写与幂等决定有限重试 |
| `E_INTERNAL_ERROR` | 内部错误 | 否，对外安全摘要 |

详细堆栈只进受控日志并关联 `request_id`，不返回给模型。

## 8. stdio 与远程

- 本机练习优先 stdio，无需 Docker；
- 标准输出只写协议消息，日志写标准错误；
- 远程设计使用 Streamable HTTP、HTTPS、标准授权、限流与请求大小限制（第 10 章展开）；
- 本教程不要求在低配置电脑部署远程 Server，远程模式用内存 Client 集成测试 + CI Smoke Test 证明。

## 9. 契约测试

客户端使用允许列表按工具名和 Schema Hash 校验，发现意外新增/变更时拒绝自动启用：

```python
def assert_tool_contract(result: dict) -> None:
    tools = {t["name"]: t for t in result["tools"]}
    assert set(tools) == {"search_manual", "get_alarm"}
    assert tools["get_alarm"]["inputSchema"]["required"] == ["equipment_id"]
```

必测用例清单：

- 初始化与能力协商；
- `tools/list` Schema 快照；
- 正常、未知设备、非法参数、越权、上游超时；
- 超大返回截断、取消、并发限制；
- stdio 中日志不得污染 stdout。

## 10. 项目任务

1. 完成 Server、Fake Business API 和 LangChain MCP Adapter；
2. 对比直接 REST Tool 与 MCP Tool 的契约、可移植性和额外故障面，写一段结论；
3. 写 `tests/test_mcp_readonly.py`：Schema 快照 + 越权 + 截断 + stdout 纯净；
4. 写 `scripts/m6_mcp_smoke.py`，供第 7 章 M6 验收复用。

## 11. 常见错误与诊断顺序

### 11.1 只读 Server 不加限流

症状：模型循环调用 `get_alarm`，下游被拖垮或数据被批量枚举。诊断顺序：先确认是否有限流 + 并发上限，再确认返回是否截断，最后确认是否有循环检测（第 4 章）。

### 11.2 把业务校验全交给 JSON Schema

症状：Schema 通过但业务枚举/租户校验缺失。诊断顺序：确认服务端是否再次校验，且校验位置在 Tool 内部而非仅 SDK 层。

### 11.3 返回内部异常堆栈

症状：模型看到 traceback 或数据库 SQL。诊断顺序：确认错误码是否走 `E_*` 安全摘要，堆栈是否只进受控日志并关联 `request_id`。

## 12. 练习题与答案

### 练习 1：只读 Server 为什么仍需限流？

**答案：**可被模型循环调用、拖垮下游或批量枚举敏感数据；只读仍消耗资源并产生泄露风险。

### 练习 2：Tool 返回内部异常堆栈好吗？

**答案：**不好。返回稳定错误码和安全摘要，详细堆栈只进入受控日志并关联请求 ID。

### 练习 3：`create_work_order_draft` 能否直接放进只读 Server？

**答案：**不能。它是可逆写，若开放必须经 HITL 审批 + 幂等键，默认不进入只读 Server；把写动作伪装成只读会破坏权限语义。

## 13. 工程挑战

1. 给 `get_alarm` 加一个「不同 `tenant_id` 传同一 `equipment_id`」的负向测试，断言返回 `E_FORBIDDEN` 且无数据。
2. 写一个超大返回用例，断言列表与正文被截断且带 `truncated` 标记。
3. 用内存 Client 走通完整握手，断言 `protocolVersion == "2025-11-25"` 且 stdout 无日志污染。

## 14. 面试追问

### 14.1 为什么只读 Server 还要做租户过滤？

回答框架：只读数据同样属于某个租户，跨租户读取就是泄露。租户条件必须强制进查询，不能靠开发人员每次记得写；越权返回不区分「不存在」与「不可见」，避免枚举。

### 14.2 直接 REST Tool 和 MCP Tool 的差别？

回答框架：MCP 用统一协议解决发现、Schema 描述和跨 Host/Server 互操作，代价是多一层协议、会话与版本治理；REST Tool 更直白但每接一个工具都要 bespoke adapter。选型看是否要跨团队复用能力。

## 15. 本章复盘模板

```text
完成日期：
实际投入小时：
只读 Server 是否只暴露 search_manual/get_alarm，写工具是否走审批门：
Tool Schema 是否写清长度/枚举/返回上限/错误码：
服务端是否再次校验参数 + tenant_id，越权返回 E_FORBIDDEN：
返回是否截断且带 truncated 标记：
stdio 是否日志不污染 stdout：
契约测试是否覆盖 Schema 快照/越权/截断/并发/超时：
仍不理解的问题：
```

## 16. 官方资料与中文阅读指引

- [MCP 2025-11-25：Server Overview](https://modelcontextprotocol.io/specification/2025-11-25/server/index)：重点看 Server 能力与生命周期，用于 §4；
- [MCP 2025-11-25：Server Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)：重点看 Tool Schema 与 `tools/call`，用于 §5；
- [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)：以 `uv.lock` 固定版本为准，用于 §4 骨架。

中文阅读重点：先确认 Server 的 stdio 输出约束（只输出协议消息），再核对 Tool Schema 的 `inputSchema` 与服务端二次校验的关系；具体装饰器与消息字段以锁定的 SDK 版本和 2025-11-25 规范为准。

## 17. 下一章入口

本章把第 1 章的心智模型落成了可调用的只读 Server。但 Server 一旦上线，攻击面就来自「模型被诱导去调用不该调用的东西」——下一章（第 8 阶段第 3 章）进入 Prompt Injection 与 Agent 安全，建立威胁模型、红队集和分层防御。
