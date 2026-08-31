# Docker、CI 与部署设计

> 预计 8 小时｜说明：本机不安装 Docker；在 CI 构建镜像并验证部署资产。

## 1. 容器设计

Dockerfile 使用固定 Python 基础镜像、非 root 用户、锁定依赖、多阶段构建、只复制必要文件、健康检查；密钥在运行时注入，不写进镜像层。`.dockerignore` 排除 `.git/.env/tests-cache/本地数据`。

本地用 `uv run` 启动；CI 中执行 lint/type/test、安全扫描和 `docker build`。这样学习部署标准，又不占用低配置电脑资源。

## 2. CI 流水线

```text
checkout -> setup Python/uv -> lock 校验 -> lint/type -> unit
-> integration(Fake) -> eval smoke -> secret/dependency scan
-> docker build -> 生成制品清单 -> 人工发布门禁
```

CI 默认无真实模型 Key。发布环境使用托管平台，至少区分 dev/staging/prod；数据库迁移先向后兼容，应用发布后再清理旧字段。

## 3. 运行时

进程无状态不等于系统无状态：Checkpoint、业务库、缓存和文档索引外置。优雅停机停止接收新请求、等待短任务、让长任务依靠 Checkpoint 恢复。`live` 只看进程，`ready` 检查关键依赖但避免昂贵模型调用。

## 4. 项目任务

编写 Dockerfile 与 GitHub Actions；在远程 CI 证明构建通过。输出环境变量清单、迁移顺序、回滚步骤、备份/恢复目标和容量估算。

## 5. 练习与答案

### 练习 1：为什么不能把 `.env` COPY 进镜像再删除？

**答案：**密钥可能仍存在于镜像历史层和缓存；应从未进入构建上下文，运行时用 Secret 注入。

### 练习 2：Readiness 调模型做健康检查好吗？

**答案：**通常不好，会产生费用、限流和误判；检查本服务配置与关键连接，模型质量另用合成监控。

## 6. 验收与资料

CI 可复现且不花模型费，镜像非 root、无密钥。参考 [Docker Build CI](https://docs.docker.com/build/ci/github-actions/)、[GitHub Actions Python](https://docs.github.com/en/actions/tutorials/build-and-test-code/python)。

