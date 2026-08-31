# Python 后端与计算机基础题

> 目标：补足 Agent 岗不会因基础薄弱而失分的最小集合。

## 1. Python/异步

- `async/await` 适合 I/O；CPU 密集需进程/原生库，阻塞函数会卡事件循环。
- TaskGroup 结构化管理子任务；取消要清理并传播。
- 类型标注是静态提示，Pydantic 是运行时边界验证。
- 生成器惰性迭代；上下文管理器保证资源释放。

追问题：连接池耗尽、协程泄漏、同步 SDK、线程安全、超时预算。

## 2. HTTP/网络

掌握方法幂等语义、状态码、SSE/WebSocket、TLS、DNS、连接复用、反向代理、CORS、认证/授权。429 与 503 的重试策略不同；请求超时不等于远端未执行。

## 3. 数据库

主键/外键/唯一索引、联合索引最左前缀、事务 ACID、隔离与锁、乐观锁、分页、迁移。能写设备—告警—工单 JOIN，能解释 N+1 和慢查询。

## 4. 操作系统与工程

进程/线程/协程、内存与文件描述符、环境变量、信号与优雅停机、容器基本隔离、CI/CD、日志/指标/Trace。

## 5. 练习与答案

### 练习 1：接口超时后客户端重发 POST，如何防重复？

**答案：**稳定 Idempotency-Key、请求 Hash、数据库唯一约束、保存原结果；同 Key 不同 Payload 返回冲突。

### 练习 2：SQL `WHERE tenant_id=? AND status=? ORDER BY created_at DESC` 如何考虑索引？

**答案：**以真实选择性和查询计划验证，候选联合索引 `(tenant_id, status, created_at)`；同时考虑写放大与分页方式。

## 6. 资料

- [Python 文档](https://docs.python.org/3/)
- [FastAPI](https://fastapi.tiangolo.com/)
- [MySQL Reference](https://dev.mysql.com/doc/refman/8.4/en/)

