# AI Agent 应用开发工程师学习教程

一套面向有前端开发经验、正在转型 AI Agent 应用开发工程师的完整中文教程。课程由当前岗位要求反推，以能力门槛和项目证据决定是否完成，不受 24 周范围限制；主线覆盖 Python、LangChain、LangGraph、RAG、LangSmith、MCP、Redis/任务队列、评测、安全、部署和企业业务集成。

## 在线阅读

教程站点：[https://zhanghuaiwei.github.io/ai-agent-learning-tutorial/](https://zhanghuaiwei.github.io/ai-agent-learning-tutorial/)

站点提供分组导航、全文搜索、深色模式以及上一章/下一章切换。

## 核心模块

- LangChain：9 篇，覆盖当前架构、Model/Message/Tool、`create_agent`、Middleware、流式、可靠性、Dify 和主流框架迁移。
- LangGraph：11 篇，覆盖 State/Node/Edge/Reducer、Command、Checkpoint、Memory、Interrupt、幂等恢复、子图、多 Agent、A2A 和 Agent Skills。
- 岗位专项：当前 JD 再审计、Python/SQL/算法基础、Text2SQL、多模态、Spring AI、Agent Runtime、证据矩阵、源码阅读和系统设计。
- 企业项目：“智维 Agent——工业设备维护知识与工单协同平台”。
- 学习路线：默认采用 G0～G10 能力门槛；24 周文件仅为每周约 15 小时情况下的压缩排期参考，目标投递时间仍为 2027 年 2 月底。

教程正文入口：[docs/index.md](docs/index.md)。

## 本地预览

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install --require-hashes -r requirements-docs.txt
mkdocs serve
```

打开 `http://127.0.0.1:8000`。严格构建检查：

```bash
mkdocs build --strict
```

## 参与贡献

所有内容变更都必须通过 Pull Request。PR 需要文档构建检查通过，并由仓库所有者审核；合并到 `main` 后，GitHub Actions 才会自动部署到 GitHub Pages。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## License

[MIT](LICENSE)
