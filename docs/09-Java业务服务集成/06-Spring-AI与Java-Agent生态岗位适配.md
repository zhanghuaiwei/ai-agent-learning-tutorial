# Spring AI 与 Java Agent 生态岗位适配

> 目标：在 Python Agent 主线完成后，掌握 Spring AI 的 Model、ChatClient、Advisor、Tool、RAG、MCP 和 Observability 边界；不重复建设第二套完整主项目。

> **阅读前置**：Java 增强线专题，位于 Python 主线（M0～M5）之后。前置要求：Spring Boot 基础与"统一契约、自有协议"的主线经验——本章的核心价值正是把这套思想映射到 Java 生态。不依赖本阶段第 1～5 章正文。

## 1. 为什么补这一章但不改双主线

企业 AI 应用岗位可能写：

- Python/FastAPI 或 Java/Spring Boot 任一；
- Spring AI/Spring AI Alibaba；
- 将大模型接入现有 Java 微服务；
- Tool Calling、RAG、MCP、流式和可观测性；
- Python Agent 与 Java 业务系统协作。

你的最优策略仍是：

```text
Python：Agent/RAG/LangGraph/评测深入主线
Java：业务真相 + Spring AI 岗位适配实验
```

只有目标 JD 明确以 Java AI 为主，且连续出现，才把 Spring AI 实验升级为完整 Java Agent 服务。

## 2. 稳定概念映射

| Python 主线 | Spring AI |
| --- | --- |
| Model Adapter | `ChatModel` / Model API |
| 高层模型客户端 | `ChatClient` |
| Middleware | Advisor Chain |
| Tool Schema/Executor | Tool Callback / Tool Calling Advisor |
| Structured Output | Structured Output Converter/Schema |
| Memory | Chat Memory + Advisor |
| RAG Pipeline | VectorStore + RAG Advisors/模块 |
| MCP Client/Server | Spring AI MCP Starters/API |
| Trace/Metric | Spring Observability/Micrometer |
| FastAPI DI/Config | Spring Boot DI/Auto-configuration |

不要只背类名。比较输入输出、生命周期、顺序、并发、错误和版本。

## 3. 先复用统一领域契约

Java 定义同一请求/响应：

```java
public record DiagnoseRequest(
    String tenantId,
    String userId,
    String deviceId,
    String symptom
) {}

public record Evidence(String sourceId, String quote) {}

public record DiagnoseResponse(
    String status,
    String summary,
    List<Evidence> evidence,
    String proposedAction
) {}
```

与 Python Pydantic Schema 通过 OpenAPI/JSON Schema 契约测试校验。Java 和 Python 可以各自使用语言对象，但外部字段语义、错误码和版本兼容必须一致。

## 4. ChatClient 最小实验

```java
@Service
public class DiagnosisAssistant {
    private final ChatClient chatClient;

    public DiagnosisAssistant(ChatClient.Builder builder) {
        this.chatClient = builder
            .defaultSystem("你是设备维护助手。信息不足时必须追问，不执行工单写入。")
            .build();
    }

    public DiagnoseResponse diagnose(String symptom) {
        return chatClient.prompt()
            .user(symptom)
            .call()
            .entity(DiagnoseResponse.class);
    }
}
```

示例只说明最小路径。生产还需 Principal、超时、模型路由、错误映射、Schema 失败、日志脱敏和测试。

具体 API 以项目锁定版本为准。Spring AI 版本演进较快，实验前核对 Reference 与 Release Notes。

## 5. Tool Calling 的责任

工具方法：

```java
public class DeviceTools {
    private final DeviceQueryService deviceQueryService;
    private final AuthorizationService authorizationService;

    @Tool(description = "查询当前租户内的设备基本信息，只读")
    public DeviceView getDevice(String deviceId) {
        var principal = CurrentPrincipal.require();
        authorizationService.checkReadDevice(principal, deviceId);
        return deviceQueryService.getForTenant(principal.tenantId(), deviceId);
    }
}
```

关键原则：

- 模型只能请求 Tool，应用执行 Tool；
- 当前用户/tenant 不作为可由模型自由填写的普通参数；
- Tool 内再次进行资源级授权；
- 写 Tool 使用幂等、预览和审批；
- Tool 结果仍是不可信模型输入；
- 设置循环次数、Deadline 和观测事件。

Spring AI 当前 Tool Calling 可能由 `ChatClient` 的 Tool Calling Advisor 驱动循环；直接使用低层 `ChatModel` 时的行为可能不同，必须核对版本而不是沿用旧教程认知。

## 6. Advisor Chain 对照 Middleware

Advisor 可用于：

- 动态 Context；
- Memory；
- RAG；
- Tool Calling Loop；
- 日志/Trace；
- 安全策略或输出处理。

顺序决定某个 Advisor 是每个 Tool Loop 都执行，还是只在外层执行。为以下行为写测试：

```text
Principal 注入
  → PII/权限前置检查
  → Memory/RAG Context
  → Tool Calling Loop
  → 输出校验
  → Trace/Usage
```

权限不能只靠一个可能被后续 Advisor 覆盖的 System Message；Tool Enforcement 独立存在。

## 7. RAG 迁移实验

不要在 Java 再造全部文档管道。选择两种方案对照：

### 方案 A：Python Knowledge Service

Spring Boot 调受控检索 API，继续复用 Python 摄取、混合检索、重排、评测和索引。

优势：一套数据链和评测；代价：远程调用、故障和部署边界。

### 方案 B：Spring AI VectorStore/RAG

使用相同 20 份文档、Chunk ID、metadata 和 Dataset 完成 Java 最小 RAG。

优势：Java 团队内聚；代价：双实现、索引一致性和评测维护。

通过 Recall@K、引用、P95、索引更新和代码/运维复杂度决定，不以框架偏好决定。

## 8. MCP 角色选择

Spring AI 可以作为：

- MCP Client：消费外部工具；
- MCP Server：把受控 Java 业务能力暴露为 Tool/Resource；
- 普通 REST Service：由 Python MCP Server/Tool Adapter 包装。

决策：

| 场景 | 推荐 |
| --- | --- |
| 仅 Python 主项目调用 Java | 普通 REST 最简单 |
| 多个 Agent Host 需要发现同一 Java Tool | Spring AI MCP Server 可评估 |
| Java Agent 消费现有 MCP 生态 | MCP Client |
| 高风险业务写入 | 仍由业务 API、Policy、审批和事务控制 |

使用 MCP 不改变 Java 服务的数据所有权和授权规则。

## 9. 流式接口

Spring AI 支持响应式流，但外部 SSE 契约仍应与 Python 前端协议对齐：

```json
{"type":"message.delta","run_id":"...","seq":1,"text":"..."}
{"type":"tool.status","run_id":"...","seq":2,"name":"get_device","status":"completed"}
{"type":"run.completed","run_id":"...","seq":3}
```

不要把框架内部对象直接序列化给前端。处理断线取消、背压、代理缓冲和最终状态查询。

## 10. Observability

Spring AI Observability 与 Micrometer/Spring Boot Actuator 集成时，仍要统一项目字段：

```text
trace_id, tenant_id, run_id, task_id, release_id
logical_model, provider, tool_name
input/output tokens, latency, status
```

Tool 参数、结果和 Prompt 可能含敏感数据，默认不导出正文。Java Trace 与 Python/Queue/MCP 使用 W3C Trace Context 贯通。

## 11. Python 与 Java 三种架构

### A. Python Agent + Java Business（课程默认）

适合 LangGraph/RAG 深度和现有 Java 业务系统。

### B. 全 Java Spring AI

适合公司 Java 技术栈统一、流程复杂度适中、JD 明确要求 Spring AI。

### C. Python/Java 各有 Agent

只有职责、数据/权限和团队生命周期明确分离时考虑，并使用 API/A2A 等契约协作。避免两个 Agent 同时拥有工单决策权。

## 12. Spring AI Alibaba 的位置

目标岗位若明确要求 Spring AI Alibaba，再完成其模型适配、Graph/Agent 或生态组件实验。仍复用本章统一契约和数据集，重点比较：

- 国产模型和阿里云集成；
- Workflow/Graph 能力；
- Tool/MCP 和可观测性；
- 与 Spring AI 主版本兼容；
- 文档、社区和升级风险。

不因名称包含“Alibaba”就默认优于标准 Spring AI，也不在无 JD 证据时同时维护两套 Java Agent。

## 13. 测试矩阵

| 测试 | 内容 |
| --- | --- |
| Schema | Java/Python OpenAPI 与 JSON 字段兼容 |
| Tool | 参数、Principal、权限、错误和幂等 |
| Advisor | 顺序、每轮/外层执行次数、失败传播 |
| Model Adapter | Fake 响应、429、超时、Schema 漂移 |
| RAG | 同 Dataset 的检索/引用对照 |
| MCP | Tool Schema、Scope、错误和超时 |
| Streaming | Event/seq、断线和最终状态 |
| Trace | 跨 Java/Python 的 Context Propagation |

## 14. 项目练习

完成一个小型 `spring-ai-adapter` 分支：

1. Spring Boot 暴露 `/ai/diagnose`；
2. ChatClient 生成 `DiagnoseResponse`；
3. 一个只读 `getDevice` Tool；
4. Tool 从可信 Principal 获取 tenant；
5. 一个 Advisor 记录脱敏 Trace；
6. 使用 Fake Model 完成契约和权限测试；
7. 用 20 条同数据集与 Python 版本对照；
8. 写 ADR：保留 Python 主线、切全 Java 或仅保留业务 Tool。

无需重写 LangGraph 企业项目，也无需本机 Docker。

## 15. 练习与答案

### 练习 1：已有 Spring Boot 服务，是否应把 Python Agent 全部改写为 Spring AI？

**答案：**不应默认改写。比较团队语言、现有业务、Workflow/评测深度、部署、招聘要求和迁移成本。当前课程用 Python 深入 Agent，Java 保持业务真相，通常风险更低。

### 练习 2：`@Tool` 中有参数 `tenantId`，模型传入后能否直接使用？

**答案：**不能。tenant 来自认证 Principal；模型参数只能表达用户意图，不能决定安全上下文。Tool 服务端执行资源级授权。

### 练习 3：Advisor 中写“禁止创建工单”是否足够？

**答案：**不够。这只是 Prompt/请求层软约束。真正的 Tool Registry、Scope、业务 API、审批和幂等层必须阻止未授权写入。

### 练习 4：Java 与 Python RAG 哪个更快？

**答案：**不能按语言猜。使用同文档、检索配置、模型和 Dataset 测摄取、Recall、P95 与资源；网络边界和组件选择往往比语言影响更大。

## 16. 面试追问

1. Spring AI ChatClient、ChatModel 和 Advisor 的关系？
2. Spring AI Tool Calling 与 LangChain Tool 有何共同点？
3. Advisor 顺序为什么影响 Tool Loop？
4. Python Agent 与 Java 业务服务如何划分数据所有权？
5. 何时把 Java 服务暴露为 MCP Server？
6. 如何贯通 Java/Python Trace？
7. 如何证明能迁移框架而不是只跑 Quickstart？
8. Spring AI 版本升级如何保护？

## 17. 验收标准

- [ ] 能映射 Python 主线与 Spring AI 核心抽象；
- [ ] 完成 ChatClient、Structured Output 和一个只读 Tool；
- [ ] tenant/Principal 不由模型控制；
- [ ] Advisor 顺序和 Tool Loop 有测试；
- [ ] Java/Python 复用同一 Dataset 和外部 Schema；
- [ ] MCP/REST 选择有 ADR；
- [ ] 跨语言 Trace 可关联；
- [ ] 明确本实验不等同于 Java AI 生产经验。

## 18. 资料来源

- [Spring AI Reference](https://docs.spring.io/spring-ai/reference/)
- [Spring AI ChatClient](https://docs.spring.io/spring-ai/reference/api/chatclient.html)
- [Spring AI Advisors](https://docs.spring.io/spring-ai/reference/api/advisors.html)
- [Spring AI Tool Calling](https://docs.spring.io/spring-ai/reference/api/tools.html)
- [Spring AI RAG](https://docs.spring.io/spring-ai/reference/api/retrieval-augmented-generation.html)
- [Spring AI MCP](https://docs.spring.io/spring-ai/reference/api/mcp/mcp-overview.html)
- [Spring AI Observability](https://docs.spring.io/spring-ai/reference/observability/)
- [Spring AI GitHub](https://github.com/spring-projects/spring-ai)
- [Spring AI Alibaba](https://java2ai.com/)
