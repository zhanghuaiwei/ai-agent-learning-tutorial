# 类型系统、Pydantic 与 Agent 数据契约

> 预计 5 小时｜产出：可验证、可演进的请求、工具和结果模型。

## 1. 为什么 Agent 更需要契约

LLM 输出具有概率性，外部工具也可能返回脏数据。类型标注帮助开发期发现问题，Pydantic 在运行时验证边界数据。数据经过 HTTP 请求 → Agent State → Tool 参数/结果 → HTTP 响应；边界模型与内部领域对象应分开。

```python
from datetime import datetime
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field

class AlarmQuery(BaseModel):
    model_config = ConfigDict(extra="forbid")
    equipment_id: str = Field(min_length=1, max_length=64)
    severity: Literal["low", "medium", "high"] | None = None

class ToolResult(BaseModel):
    ok: bool
    code: str
    data: dict = Field(default_factory=dict)
    retryable: bool = False
    observed_at: datetime
```

`extra="forbid"` 阻止模型悄悄传入未知字段。`code` 用稳定机器码，中文文案由上层映射。金额用整数“分”或 `Decimal`。

## 2. 契约演进

- 新增可选字段通常兼容；删除、改名、收紧取值通常不兼容。
- Tool 入参与出参都定义 Schema，日志记录 Schema 版本。
- `dict[str, Any]` 只用于真正开放的扩展区。
- LLM 输出校验失败可有限修复，但不能无限重试。

## 3. 项目任务

为设备、告警、工单、引用来源建模；为 `search_manual`、`get_alarm`、`create_work_order_draft` 建独立输入/输出模型，并写 8 个非法输入测试。

## 4. 练习与答案

### 练习 1：为何不能只靠 Prompt 要求正确 JSON？

**答案：**Prompt 是软约束；Schema 验证是可测试的运行时硬边界。

### 练习 2：给 Tool 结果加入必填字段会怎样？

**答案：**旧生产者会验证失败，通常是破坏性变更。先加可选字段、升级生产者，再收紧。

## 5. 验收与资料

所有外部边界有模型，未知 Tool 参数被拒绝且不泄露堆栈。参考 [Python typing](https://docs.python.org/3/library/typing.html)、[Pydantic Models](https://docs.pydantic.dev/latest/concepts/models/)、[Validators](https://docs.pydantic.dev/latest/concepts/validators/)。

