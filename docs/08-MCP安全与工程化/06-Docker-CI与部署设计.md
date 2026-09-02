# Linux、Docker、CI 与 Agent 生产部署排障

> 建议投入：第 22～23 周共 4 小时｜本机不安装 Docker；通过 GitHub Actions 构建镜像，在临时 Linux/托管环境完成诊断实验。

> **阅读前置**：生产部署专题（第 22～23 周）。前置要求：M0～M5 的可部署服务与 CI 概念（本项目文档仓库的 GitHub Actions 工作流即最小 CI 实例，可直接对照）。不依赖本阶段 MCP 章节正文，可在服务成型后阅读。

## 1. 这一章的岗位目标

AI 应用开发岗不一定要求维护 Kubernetes 集群，但通常要求“服务能上线，出问题能定位”。完成后应能：

- 解释进程、端口、文件描述符、内存、信号、DNS/TLS 和反向代理；
- 写出安全、可复现的 Dockerfile，并在 CI 构建；
- 区分 Liveness、Readiness、Startup Probe；
- 处理 502、SSE 不流、OOM、连接池耗尽、磁盘满和优雅停机；
- 读懂最小 Kubernetes Deployment/Service，不冒充集群运维专家；
- 给 Agent API、Worker、数据库、Redis 和模型供应商画出部署边界。

## 2. 先理解 Linux 进程模型

```text
Client
  → DNS/TLS/LB/Nginx
  → Uvicorn/Gunicorn Worker Process
  → asyncio Event Loop
  → HTTP/DB/Redis/Model connection pools
  → external dependencies
```

一次请求慢，可能发生在任何一层。排障顺序是“确认影响 → 找到边界 → 用指标缩小范围 → 再看代码”，不是先重启。

### 2.1 常用只读诊断命令

```bash
ps -ef
top
free -h
df -h
df -i
ss -lntp
curl -v http://127.0.0.1:8000/health/live
curl -N http://127.0.0.1:8000/v1/agent/stream
journalctl -u agent-api --since "15 min ago"
```

命令目的：

- `ps/top`：进程是否存在，CPU 是否异常；
- `free`：内存与 Swap，不能只看“free”一列；
- `df -h/df -i`：空间或 inode 是否耗尽；
- `ss`：服务是否监听预期地址/端口；
- `curl -v/-N`：分别检查连接细节和禁用客户端输出缓冲；
- `journalctl`：按服务和时间查日志。

生产环境遵守最小权限和审计。不要为了排障临时输出 Secret、用户原文或完整 Prompt。

### 2.2 文件描述符与连接池

Socket、文件和 Pipe 都消耗 File Descriptor。泄漏可能表现为 `Too many open files`、新连接失败或依赖随机超时。检查：

```bash
ulimit -n
ls /proc/<pid>/fd | wc -l
```

根因通常不是简单提高上限：还要检查 HTTP Client 是否每请求创建、流式响应是否关闭、数据库 Session 是否归还、Redis Pool 和 SSE 断线是否清理。

### 2.3 信号与优雅停机

容器/编排系统通常先发送 `SIGTERM`，等待 Grace Period 后强制终止。Agent 服务应：

1. Readiness 变为失败，停止接收新流量；
2. 取消或完成短请求；
3. 长任务保存 Checkpoint/归还 Queue；
4. 关闭 SSE、HTTP、DB、Redis Client；
5. Flush 必要 Trace/Metric；
6. 在期限内退出。

如果 Worker 收到信号时正处于外部副作用，仍依赖幂等与恢复，不能只靠 `finally` 假设一定执行。

## 3. Dockerfile 的工程基线

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.lock ./
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir \
       --require-hashes -r requirements.lock

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

RUN groupadd --system app && useradd --system --gid app app
WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app src /app/src

USER app
EXPOSE 8000
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

这是使用 Hash Lock 的结构示意；若主项目采用 `uv.lock`，在 Builder 中改为经锁定版本的 `uv sync --frozen --no-dev`，同样不能从开发机复制 `.venv`。基线：

- 固定到受维护的 Python 小版本/镜像 Digest，并有升级流程；
- 锁定依赖，构建时校验 Lock；
- 最终镜像不含编译工具、Git、测试缓存和本地数据；
- 非 root 运行，只读根文件系统可行时启用；
- Secret 运行时注入，不写入 ARG/ENV/镜像层；
- `.dockerignore` 排除 `.git`、`.env`、Trace、数据集和 IDE 文件；
- 记录 SBOM、镜像来源和漏洞扫描结果；
- Image 只放程序，数据库迁移作为受控 Release Step。

### 3.1 不要把 Healthcheck 写成模型调用

模型供应商短暂 429 不应让所有 Pod 被杀死。分三类：

```text
/health/live    事件循环/进程仍可响应
/health/ready   配置有效，关键本地资源可用，可接收新流量
/health/startup 启动迁移/加载完成（若平台支持独立 Startup Probe）
```

模型、Embedding、Java API 的可用性由依赖指标和合成监控观察；Readiness 是否依赖数据库/Redis 要根据服务能否降级决定。

## 4. CI 构建而不是本机安装 Docker

流水线：

```text
checkout
  → setup Python/uv
  → lock check
  → format/lint/type
  → unit + contract + integration(Fake)
  → eval smoke
  → secret/dependency scan
  → docker build
  → image scan/SBOM
  → staging smoke
  → manual production gate
```

GitHub Actions 中用 Docker 官方 Actions 构建。CI 默认无真实模型 Key；必须联调时使用受保护 Environment Secret 和人工审批，Fork PR 不能取得生产 Secret。

```yaml
- name: Set up Buildx
  uses: docker/setup-buildx-action@v3

- name: Build image
  uses: docker/build-push-action@v6
  with:
    context: .
    push: false
    tags: smart-maintenance-agent:${{ github.sha }}
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

Action 版本在实施时核验并固定 Commit SHA；这里的 Major Tag 只用于教学可读性。

## 5. 反向代理与 SSE

SSE 常见故障：“接口 200，但浏览器很久才成批显示”。检查链路每一层：

- 应用是否每个 Event 后 Flush/Yield；
- 响应 `Content-Type: text/event-stream`；
- Nginx/CDN 是否缓冲或压缩；
- 代理读取超时是否小于最长静默时间；
- 是否发送安全 Heartbeat；
- 客户端是否用流式读取而不是等待完整 Body；
- 断线后任务是否取消或转后台 Job；
- 多实例下恢复 Cursor/Thread 是否可路由。

Nginx 概念配置：

```nginx
location /v1/agent/stream {
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_read_timeout 120s;
    proxy_pass http://agent_api;
}
```

具体指令需结合公司 Ingress/CDN 验证。盲目把所有超时调很大可能让僵尸连接耗尽资源。

## 6. Kubernetes 只掌握应用工程边界

```text
Deployment
  ├─ Pod: agent-api × N
  ├─ Pod: ingestion-worker × M
  └─ rollout / replica / resource / probe

Service → 稳定虚拟地址
Ingress/Gateway → TLS、路由、限流
ConfigMap → 非敏感配置
Secret → 敏感配置引用
Job → 数据库迁移/一次性任务
HPA → 依据 CPU 或业务指标扩缩
```

最小 Deployment 关注项：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-api
spec:
  replicas: 2
  selector:
    matchLabels: { app: agent-api }
  template:
    metadata:
      labels: { app: agent-api }
    spec:
      terminationGracePeriodSeconds: 45
      containers:
        - name: api
          image: registry.example/agent-api:sha-immutable
          ports:
            - containerPort: 8000
          resources:
            requests: { cpu: "250m", memory: "512Mi" }
            limits: { cpu: "1", memory: "1Gi" }
          readinessProbe:
            httpGet: { path: /health/ready, port: 8000 }
          livenessProbe:
            httpGet: { path: /health/live, port: 8000 }
```

面试中说明它缺少的企业配置：SecurityContext、ServiceAccount、NetworkPolicy、Secret 引用、Startup Probe、滚动策略、PodDisruptionBudget、Telemetry 和拓扑分布。不要假装一段 YAML 就是生产集群设计。

## 7. Agent 服务如何定 Worker 数

应用 Worker 越多不一定越快：

- 每进程都有 HTTP/DB/Redis 连接池；
- 每进程可能复制模型客户端、Cache 和内存；
- SSE 是长连接，会占用并发槽但不持续占 CPU；
- Python async 适合 I/O，并不能加速 CPU 密集 PDF/OCR；
- CPU 任务移到独立 Worker/进程；
- 外部模型限流可能先于本服务 CPU 成为瓶颈。

容量估算从 Little's Law 的直觉开始：平均并发约等于吞吐 × 平均响应时间。再用负载测试验证 P95/P99、连接池等待、429、队列积压和成本。

## 8. 六类高频故障 Runbook

### 8.1 502/503

1. 确认范围、起始时间、版本和单租户/全局；
2. 查 LB/Ingress 状态码，再查 Pod Readiness/重启；
3. `curl` 服务本地端口与 Service；
4. 查启动错误、端口、迁移、Secret 和依赖连接；
5. 若与发布相关，停止扩大并按证据回滚。

### 8.2 P95 突增

用 Trace 分解：Queue → RAG → Model TTFT/Decode → Tool → DB。比较吞吐、错误、输入/输出 Token、重试和连接池等待。不要先把所有超时加倍。

### 8.3 OOMKilled

区分容器 Limit 与节点内存；看请求体/文档大小、并发、上下文、缓存、PDF 解析、连接泄漏。设置输入边界，把 CPU/内存重任务放后台 Worker，并用相同负载复现。

### 8.4 SSE 断开或缓冲

按第 5 节逐层验证；确认代理超时、心跳、客户端取消和 Server 清理。断线不代表模型/Tool 已停止，后台副作用必须独立追踪。

### 8.5 数据库/Redis 连接耗尽

查 Pool 使用/等待、慢查询、未关闭 Session、每请求新建 Client、Worker 总数和依赖连接上限。修复生命周期与容量，不只扩 Pool。

### 8.6 模型供应商 429/5xx

限并发、读取 `Retry-After`、带抖动有限重试、熔断/降级、模型路由；禁止每层同时重试。用任务类型和租户公平调度，防止一个长 Agent 吃掉全局配额。

## 9. 发布、迁移与回滚

发布顺序：

1. 数据库向后兼容 Migration（Expand）；
2. 部署兼容新旧 Schema 的应用；
3. 观察技术 SLI 和 Agent 质量指标；
4. 小流量/内部租户验证；
5. 全量后再清理旧字段（Contract）。

应用回滚不能自动回滚已提交的数据库和外部工单。发布计划必须写：镜像回滚、Feature Flag、Prompt/模型/RAG 版本回滚、数据兼容和人工补偿。

## 10. 智维 Agent 实验

在 CI 或临时环境完成：

1. Build 镜像且以非 root 运行；
2. 运行 `/health/live`、`/health/ready`；
3. 模拟模型 30 秒延迟，验证 Readiness 不反复杀 Pod；
4. 让 SSE 中间静默超过代理默认阈值，修复 Heartbeat/Proxy；
5. 将 DB Pool 调小并并发请求，观察等待而不是猜测；
6. 给进程发送 `SIGTERM`，验证停止接流量、关闭连接和 Job 恢复；
7. 输出 `runbooks/deployment-troubleshooting.md`。

## 11. 面试追问

### 11.1 本地没 Docker，为什么能说掌握容器交付？

可以说“通过 CI 构建、扫描并在临时环境 Smoke Test，理解镜像和运行时边界”；不能说熟练本地/集群运维。能力由构建记录、Dockerfile、部署配置和故障演练证明。

### 11.2 Liveness 和 Readiness 有何区别？

Liveness 判断进程是否需要重启；Readiness 判断是否接收新流量。把外部模型故障直接绑定 Liveness 会导致重启风暴。

### 11.3 为什么 Agent API 和摄取 Worker 分开？

资源与生命周期不同：API 追求低延迟和长连接，摄取消耗 CPU/内存且需要重试/恢复。拆分后可独立扩缩、限流和故障隔离。

## 12. 练习与答案

### 练习 1：发布后所有 SSE 每 60 秒断开，优先检查什么？

**答案：**比较 60 秒是否匹配 Ingress/LB `read/idle timeout`，检查是否有 Heartbeat、代理缓冲和客户端重连；同时确认断线后的服务端任务是否取消。不要先重写 LangGraph。

### 练习 2：Pod CPU 很低但请求排队，可能原因？

**答案：**外部模型限流、连接池耗尽、事件循环被同步 I/O 阻塞、Worker 并发限制、长 SSE 或队列公平性。看 Trace 与 Pool/Queue 指标。

### 练习 3：数据库 Migration 失败能否直接回滚镜像解决？

**答案：**不一定。Migration 已改变数据时，镜像回滚可能与 Schema 不兼容。使用 Expand/Contract、备份验证和独立迁移 Runbook。

### 练习 4：容器内存不断升高，如何建立证据？

**答案：**关联版本、流量、请求大小和任务类型；比较 RSS、对象/连接/文件描述符、Profile 和负载复现；先止损限流/回滚，再定位泄漏或 Cache 无界增长。

## 13. 验收标准

- [ ] CI 成功构建、扫描非 root 镜像，构建上下文无 Secret；
- [ ] 能用只读 Linux 命令确认进程、端口、资源、日志和 FD；
- [ ] 三类 Probe 语义正确，模型调用不在 Liveness；
- [ ] SSE 经过代理仍逐事件到达并可安全断线；
- [ ] SIGTERM 演练能停止接流量并释放资源；
- [ ] 能读懂 Deployment/Service，但不夸大 K8s 运维经验；
- [ ] 六类 Runbook 有“症状—证据—止损—根因—验证”；
- [ ] 发布方案覆盖 Migration、灰度、质量指标和回滚。

## 14. 资料来源

- [FastAPI Deployment Concepts](https://fastapi.tiangolo.com/deployment/concepts/)
- [Docker Build GitHub Actions](https://docs.docker.com/build/ci/github-actions/)
- [Docker Build Best Practices](https://docs.docker.com/build/building/best-practices/)
- [Kubernetes Pods](https://kubernetes.io/docs/concepts/workloads/pods/)
- [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [Kubernetes Probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)
- [NGINX Proxy Module](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
- [Python asyncio Development/Debugging](https://docs.python.org/3/library/asyncio-dev.html)
