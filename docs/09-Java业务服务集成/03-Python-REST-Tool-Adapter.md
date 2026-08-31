# Python REST Tool Adapter

> 预计 5 小时｜产出：把 Java API 安全映射为 Agent Tool。

## 1. 适配层职责

Tool Schema 面向模型，REST DTO 面向服务契约，两者不应直接等同。Adapter 完成字段映射、认证、超时、错误分类、响应校验、脱敏和 Trace Header 传递。

```text
Agent Tool -> Application Port -> JavaApiAdapter -> HTTP -> Java
                 FakeAdapter ---------------^
```

模型不能设置 `Authorization`、租户、内部 URL 或幂等策略。服务身份/用户委托身份由 Adapter 从 Runtime Context 获取。转发 `traceparent`、`request_id`，但不把 Python 内部 Prompt 传给 Java。

## 2. 契约稳定性

OpenAPI 生成/校验客户端可减少手写漂移，但领域错误仍要显式映射。对 401/403/404/409/422/429/5xx 分类；仅对可重放读取做有限重试，写请求依赖幂等键。

## 3. 项目任务

实现 `BusinessServicePort` 的 Fake 与 HTTP 两个 Adapter。跑同一组契约测试，模拟字段新增、缺失、Java 慢响应和 409。

## 4. 练习与答案

### 练习 1：Java 返回 500 时 Tool 应返回空列表吗？

**答案：**不应把依赖失败伪装为“无数据”。返回结构化不可用错误，Graph 决定降级或终止。

### 练习 2：服务间调用需要用户 Token 原样透传吗？

**答案：**取决于安全架构，但不能默认透传。应采用明确的服务身份或受控 Token Exchange，校验 Audience 与最小 Scope。

## 5. 验收与资料

Fake/HTTP 行为契约一致，身份与租户不由模型控制。参考 [HTTPX Clients](https://www.python-httpx.org/advanced/clients/)、[OpenAPI 规范](https://spec.openapis.org/oas/latest.html)。

