# Java 增强线验收与降级方案

> 第 21 周验收｜目标：证明能与企业既有 Java 业务系统集成，而非展示 CRUD 数量。

## 1. 完整验收

- Java 拥有设备、告警、工单、审批；Python 不直连业务库。
- JWT/Mock Auth 下的资源级租户隔离。
- OpenAPI 契约、请求/响应校验、稳定错误码。
- 工单幂等、事务、乐观锁、成功后超时调和。
- Python Fake/REST Adapter 契约一致，端到端 Trace 可串联。

## 2. 时间不足时的降级

优先级：OpenAPI 与数据所有权 → Mock Server → Python Adapter 契约测试 → Java 最小提交 API → 完整鉴权/Outbox。若第 20 周主项目仍不稳，只完成前三项，并在架构文档中说明生产实现；不要挪用最终三周的评测和面试时间。

## 3. 练习与答案

### 练习 1：Java 线完成很多 CRUD 但无幂等，算通过吗？

**答案：**不算。课程价值是业务边界与跨服务可靠性，CRUD 只是载体。

### 练习 2：面试时应把自己定位成 Java Agent 工程师吗？

**答案：**定位为 Python Agent 应用工程师，能与 Java 企业业务后端集成；如 JD 明确 Java AI 生态，再单独补 Spring AI，而非临时改主线。

## 4. 通过标准

演示一次跨服务正常提交和一次成功后超时恢复；架构图能说清数据所有权、身份、事务和失败语义。未完成 Java 实现时，Mock/契约与设计必须可运行、可评审。

## 对应资料

- [Spring Boot Reference](https://docs.spring.io/spring-boot/reference/)
- [Spring Transactions](https://spring.io/guides/gs/managing-transactions/)
