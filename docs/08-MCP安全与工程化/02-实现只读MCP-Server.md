# 实现只读 MCP Server

> 预计 8 小时｜产出：暴露设备与告警查询的最小权限 Server。

## 1. 范围

只实现 `get_equipment`、`list_active_alarms` 两个只读 Tool。Server 内部调用 Fake 或受控业务 API；不提供通用 SQL、Shell、文件系统或任意 URL 抓取能力。

每个 Tool Schema 写清字段长度、枚举、返回上限和错误。服务端再次校验输入，使用调用身份强制租户过滤。结果只返回业务所需字段，限制列表数量和正文大小。

## 2. stdio 与远程

本机练习优先 stdio，无需 Docker；标准输出只写协议消息，日志写标准错误。远程设计使用 Streamable HTTP、HTTPS、标准授权、限流和请求大小限制。本教程不要求在低配置电脑部署远程 Server。

## 3. 测试

- 初始化与能力协商。
- tools/list Schema 快照。
- 正常、未知设备、非法参数、越权、上游超时。
- 超大返回截断、取消、并发限制。
- stdio 中日志不得污染 stdout。

客户端使用允许列表按工具名和 Schema Hash 校验，发现意外新增/变更时拒绝自动启用。

## 4. 项目任务

完成 Server、Fake Business API 和 LangChain MCP Adapter；对比直接 REST Tool 与 MCP Tool 的契约、可移植性和额外故障面。

## 5. 练习与答案

### 练习 1：只读 Server 为什么仍需限流？

**答案：**可被模型循环调用、拖垮下游或批量枚举敏感数据；只读仍消耗资源并产生泄露风险。

### 练习 2：Tool 返回内部异常堆栈好吗？

**答案：**不好。返回稳定错误码和安全摘要，详细堆栈只进入受控日志并关联请求 ID。

## 6. 验收与资料

无通用执行能力、无跨租户数据、契约测试通过。参考 [MCP Server Overview](https://modelcontextprotocol.io/specification/2025-11-25/server/index)、[MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[Python SDK](https://github.com/modelcontextprotocol/python-sdk)。

