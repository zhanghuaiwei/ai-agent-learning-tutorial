# AI Agent 应用开发工程师学习教程

一套面向有前端开发经验、正在转型 AI Agent 应用开发工程师的 24 周中文教程。主线覆盖 Python、LangChain、LangGraph、RAG、LangSmith、MCP、评测、安全、工程化和企业业务集成。

## 在线阅读

教程站点：[https://zhanghuaiwei.github.io/ai-agent-learning-tutorial/](https://zhanghuaiwei.github.io/ai-agent-learning-tutorial/)

站点提供分组导航、全文搜索、深色模式以及上一章/下一章切换。

## 核心模块

- LangChain：7 篇，覆盖当前 1.x 架构、Model/Message/Tool、`create_agent`、Middleware、流式与可靠性。
- LangGraph：10 篇，覆盖 State/Node/Edge/Reducer、Command、Checkpoint、Memory、Interrupt、幂等恢复、子图和 Time Travel。
- 企业项目：“智维 Agent——工业设备维护知识与工单协同平台”。
- 学习周期：24 周，每周约 15 小时，目标投递时间为 2027 年 2 月底。

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

