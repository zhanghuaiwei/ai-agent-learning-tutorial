# Structured Output 与 Schema 校验

> 预计 5 小时｜产出：告警分析结果、工单草稿与路由决策的结构化输出。

## 1. 三层约束

1. Provider 原生结构化输出：供应商按 JSON Schema 约束生成，优先使用。
2. Tool Calling：把结构作为工具参数，适合动作选择。
3. 文本 JSON + 本地解析：兼容性最好，但最脆弱，只作降级。

无论使用哪层，都要本地 Pydantic 验证。语法正确不代表业务正确：`severity="high"` 可能合法，却与证据矛盾。第 2 阶段第 2 章已把"LLM 输出的校验与修复"的分界留给本章——`schemas.py` 里的契约就是这里的第一批验证对象。

```python
class Diagnosis(BaseModel):
    summary: str = Field(max_length=300)
    severity: Literal["low", "medium", "high", "unknown"]
    evidence_ids: list[str] = Field(max_length=8)
    requires_human: bool
```

## 2. 修复策略

验证失败时记录错误类型，把精简后的字段错误反馈给模型，最多修复一次；仍失败则返回受控错误或人工处理。不要用正则“抢救”任意 JSON，也不要把含敏感内部字段的异常原样给用户。

业务校验包括：引用 ID 必须来自本轮证据；设备 ID 必须与请求一致；高风险结论强制 `requires_human=true`。

## 3. 项目任务

复用第 2 阶段 `schemas.py` 已有的 `WorkOrderDraft` 契约，新建 `Diagnosis` 与 `RouteDecision`；为缺字段、额外字段、错误枚举、伪造引用、超长文本写测试；统计首轮与修复后有效率。

## 4. 练习与答案

### 练习 1：为什么 `json.loads` 成功还不能使用？

**答案：**它只证明语法是 JSON，不证明字段、类型、范围、权限和跨字段业务规则正确。

### 练习 2：模型连续两次校验失败怎么办？

**答案：**停止修复，进入明确降级或人工路径；无限修复会增加费用和不可预测性。

## 5. 验收与资料

非法输出不进入业务层；修复有上限；结构版本被记录。参考 [Pydantic JSON Schema](https://docs.pydantic.dev/latest/concepts/json_schema/)、[LangChain Structured Output](https://docs.langchain.com/oss/python/langchain/structured-output)。

