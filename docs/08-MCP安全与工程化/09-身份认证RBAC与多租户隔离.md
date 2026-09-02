# 身份认证、RBAC 与多租户隔离

> 补缺章节｜预计 7 小时｜产出：身份不可由 Prompt 伪造、资源不可跨租户访问的 Agent API。

> **阅读前置**：安全补缺专题。前置要求：第 2 阶段的 API 骨架与三级错误体系（第 4～5 章）；若已具备第 3 阶段 Function Calling 的 Tool 权限语境（当前为大纲态），"身份从运行时注入而非模型填写"的动机会更直观。不依赖本阶段 MCP 章节正文。

## 1. 先区分四个问题

| 问题 | 含义 | 本项目例子 |
| --- | --- | --- |
| Authentication | 你是谁 | 验证访问令牌得到 `user_id` |
| Authorization | 你能做什么 | `workorder:draft`、`workorder:approve` |
| Resource ownership | 这个对象是否属于你的范围 | 设备是否属于当前 `tenant_id` |
| Human approval | 这次高风险动作是否被明确确认 | 某审批人批准某一份动作摘要 |

登录成功不代表能访问任意设备；具备审批角色也不代表批准过当前动作；模型说“我是管理员”不属于任何可信身份信号。

## 2. 课程实现边界

生产系统通常接入企业 IdP，通过 OpenID Connect/OAuth 2.x 获得访问令牌。本教程不从零实现身份提供商：

- 本地开发使用测试签发器或固定测试 Principal；
- API 层验证令牌签名、算法、Issuer、Audience、过期时间和 Scope；
- Authorization 在应用服务和工具内部执行；
- 前端只负责携带令牌和展示结果，不能替代服务端授权；
- 真实密钥来自 Secret 管理，不提交仓库。

不要把 FastAPI 官方密码示例直接当成企业账号系统。教程学习重点是“如何消费可信身份并执行授权”。

## 3. Principal 与令牌校验

一个最小 Principal：

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class Principal:
    user_id: str
    tenant_id: str
    scopes: frozenset[str]
    token_id: str
```

访问令牌至少核验：

- 签名有效，算法来自服务端 Allowlist，不能信任 Token Header 任意指定算法；
- `iss` 等于配置的可信签发者；
- `aud` 包含当前 Agent API，而不是另一个服务；
- `exp/nbf` 合法并考虑有限时钟偏差；
- `sub/tenant_id/scope` 类型和取值合法；
- 需要撤销能力时检查 `jti/session` 状态；
- 日志不记录完整 Token。

JWT 是一种令牌格式，不自动等于安全。长期有效、无 Audience 校验的有效签名 Token 仍可能被滥用。

## 4. FastAPI 授权依赖

将鉴权集中在依赖层，并在路由声明最小 Scope：

```python
from typing import Annotated

from fastapi import Depends, HTTPException, Security, status
from fastapi.security import OAuth2AuthorizationCodeBearer, SecurityScopes


oauth2 = OAuth2AuthorizationCodeBearer(
    authorizationUrl=settings.authorization_url,
    tokenUrl=settings.token_url,
    scopes={
        "equipment:read": "读取设备与告警",
        "workorder:draft": "创建工单草稿",
        "workorder:approve": "批准工单提交",
    },
)


async def get_principal(
    security_scopes: SecurityScopes,
    token: Annotated[str, Depends(oauth2)],
) -> Principal:
    claims = token_verifier.verify(token)  # 验签并校验 iss/aud/exp
    principal = Principal.from_claims(claims)
    missing = set(security_scopes.scopes) - principal.scopes
    if missing:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"code": "insufficient_scope"},
        )
    return principal


@app.get("/equipment/{equipment_id}")
async def get_equipment(
    equipment_id: str,
    principal: Annotated[
        Principal,
        Security(get_principal, scopes=["equipment:read"]),
    ],
):
    return await equipment_service.get_visible_equipment(
        tenant_id=principal.tenant_id,
        equipment_id=equipment_id,
    )
```

示例省略具体 IdP SDK，但没有省略校验责任。生产优先使用成熟 IdP/验证库，不手写密码存储和加密协议。

## 5. RBAC、Scope 与资源级授权

RBAC 用角色聚合权限，Scope 表达令牌已获授权的能力；最终仍要检查资源范围。

| 角色 | 读取设备 | 建草稿 | 批准提交 | 管理知识库 |
| --- | --- | --- | --- | --- |
| viewer | 是 | 否 | 否 | 否 |
| maintainer | 是 | 是 | 否 | 否 |
| approver | 是 | 是 | 是 | 否 |
| knowledge_admin | 是 | 否 | 否 | 是 |

这张表只能回答“通常能做什么”，不能回答“能否操作 EQ-001”。服务还要验证：

```text
principal.tenant_id == equipment.tenant_id
principal.scope 包含所需能力
设备状态允许该动作
审批人不能审批自己发起且违反职责分离的动作
approval.action_digest == 当前待执行动作摘要
```

不要返回 403 与 404 的细节让攻击者枚举其他租户对象。对外可统一成不可见，对内审计记录真实拒绝原因。

## 6. 身份如何进入 LangChain/LangGraph

可信调用链：

```text
Bearer Token
  → API 验证并生成 Principal
  → 应用服务创建不可变 Runtime Context
  → Middleware 过滤可见工具
  → Tool 再做 Scope + tenant + resource 校验
  → 业务服务执行最终授权
```

Prompt 中可以告诉模型当前可做什么，但 Prompt 不是安全边界。Tool 参数中也不提供 `tenant_id/user_id/roles` 让模型填写。

```python
@tool
async def get_alarm(
    equipment_id: str,
    runtime: ToolRuntime[AgentContext],
) -> AlarmView:
    principal = runtime.context.principal
    require_scope(principal, "equipment:read")
    return await alarm_service.get_visible(
        tenant_id=principal.tenant_id,
        equipment_id=equipment_id,
    )
```

Middleware 的工具过滤用于减少误选和纵深防御；真正授权必须留在 Tool/应用服务/业务服务内，防止工具被其他入口直接调用时绕过。

## 7. 多租户数据隔离

每个读取路径都要回答“租户条件在哪里被强制加入”：

- Repository 方法强制接收 `tenant_id`；
- 唯一约束通常包含 `tenant_id`；
- Checkpoint Thread 与租户/用户建立所有权映射；
- LangGraph Store Namespace 包含租户和用户；
- RAG 在检索前执行 ACL/租户过滤，而不是生成答案后过滤；
- Cache Key 包含租户、权限范围和数据版本；
- Trace 和导出任务也执行租户过滤；
- 管理员跨租户操作使用独立显式流程并完整审计。

不要依赖开发人员每次手工记得写过滤条件。通过 Repository API、数据库策略或集中查询构造器使“遗漏租户”难以发生，并用负向测试证明。

## 8. 必测攻击用例

| 用例 | 预期 |
| --- | --- |
| Prompt 声称自己是管理员 | 工具集合和权限不改变 |
| A 租户请求 B 租户设备 ID | 资源不可见且产生安全审计 |
| 有读 Scope 调写 Tool | 403，Tool 不执行 |
| 过期、错误 Audience Token | 401，不进入 Agent |
| 篡改 `thread_id` | 无法读取或恢复其他用户状态 |
| 批准后修改工单参数 | `action_digest` 不匹配，要求重新批准 |
| Cache 命中其他角色结果 | 测试失败，修正 Cache Key |
| 日志/Trace 搜索 Token | 不得出现完整凭证 |

## 9. 练习与答案

### 练习 1：已经用 Middleware 隐藏了写工具，还要在 Tool 内鉴权吗？

**答案：**要。Middleware 可能配置错误，Tool 也可能被 Graph、测试接口或未来入口直接调用。工具和业务服务必须执行最终授权，形成纵深防御。

### 练习 2：用户拥有 `workorder:approve`，为什么还不能直接执行提交？

**答案：**Scope 只表示有资格审批，还需要检查租户、资源、职责分离、审批有效期，以及批准的动作摘要是否与待执行动作完全一致。

### 练习 3：把 `tenant_id` 放入向量检索结果后再过滤可以吗？

**答案：**不可以。未授权 Chunk 已进入候选、重排或模型上下文，可能泄漏。过滤必须尽可能在检索前或检索引擎内部完成。

## 10. 工程任务与验收

工程任务：

1. 定义 Principal、Scope 和四角色权限矩阵。
2. 为 FastAPI 非流式与 SSE 接口接入同一鉴权依赖。
3. 将 Principal 注入 LangChain Runtime Context；删除所有由模型提供身份的参数。
4. 为设备、RAG、Thread、审批、Cache 和 Trace 写跨租户负向测试。
5. 保存授权拒绝审计，但不保存 Token 和敏感 Prompt 全文。

验收标准：

- 未认证请求不触发任何模型或工具调用；
- 越权、跨租户、篡改 Thread 和过期审批测试成功拦截率为 100%；
- 每个写 Tool 都能指出最终授权发生的位置；
- 401、403、404 的外部语义和内部审计语义明确；
- 能解释 Authentication、RBAC、Scope、资源所有权和 Human approval 的区别。

## 11. 资料来源

- [FastAPI Security](https://fastapi.tiangolo.com/tutorial/security/)
- [FastAPI OAuth2 Scopes](https://fastapi.tiangolo.com/advanced/security/oauth2-scopes/)
- [JWT Best Current Practices（RFC 8725）](https://www.rfc-editor.org/rfc/rfc8725)
- [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)
- [LangChain Runtime](https://docs.langchain.com/oss/python/langchain/runtime)

