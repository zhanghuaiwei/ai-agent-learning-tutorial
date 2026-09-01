#!/usr/bin/env bash

set -euo pipefail

missing=0

for file in docs/0[2-9]-*/*.md docs/10-*/*.md docs/11-*/*.md; do
  if ! grep -Eq '^#{1,6} .*练习' "$file"; then
    printf '缺少练习：%s\n' "$file"
    missing=1
  fi

  if ! grep -Eq '^#{1,6} .*(资料|参考)' "$file"; then
    printf '缺少资料来源：%s\n' "$file"
    missing=1
  fi
done

job_audit_chapters=(
  "docs/01-总览与使用方式/08-面向2027招聘的岗位能力再审计.md"
  "docs/02-Python-Agent后端基础/07-Redis任务队列与后台作业可靠性.md"
  "docs/03-LLM应用与原生Agent/07-Transformer模型推理微调与选型边界.md"
  "docs/04-LangChain与单Agent/08-Dify工作流与代码框架选型.md"
  "docs/08-MCP安全与工程化/06-Docker-CI与部署设计.md"
  "docs/10-企业级实战项目/09-从需求澄清到上线的交付评审.md"
  "docs/11-面试准备/05-Python后端与计算机基础题.md"
  "docs/11-面试准备/08-岗位证据矩阵简历筛选与投递门槛.md"
)

for file in "${job_audit_chapters[@]}"; do
  if [[ ! -f "$file" ]]; then
    printf '岗位再审计必需章节缺失：%s\n' "$file"
    missing=1
    continue
  fi

  line_count=$(wc -l < "$file" | tr -d ' ')
  if (( line_count < 120 )); then
    printf '岗位再审计章节深度不足（少于 120 行）：%s，当前=%s\n' "$file" "$line_count"
    missing=1
  fi
done

if (( missing != 0 )); then
  exit 1
fi

if grep -REn --include='*.md' \
  '50 ?元|50元|40 ?元|40元|MONTHLY_BUDGET_CNY|budget_remaining|费用上限|成本上限' \
  docs; then
  printf '发现与“无固定 API 金额上限”冲突的内容。\n'
  exit 1
fi

check_milestone() {
  milestone="$1"
  expected="$2"
  if ! grep -REq --include="*${milestone}*.md" "$expected" docs; then
    printf '%s 的里程碑周数缺失或错误，应为：%s\n' "$milestone" "$expected"
    exit 1
  fi
}

check_milestone M0 '第 4 周里程碑'
check_milestone M1 '第 7 周里程碑'
check_milestone M2 '第 10 周里程碑'
check_milestone M3 '第 14 周里程碑'
check_milestone M4 '第 18 周里程碑'
check_milestone M5 '第 19 周里程碑'
check_milestone M6 '第 22 周里程碑'

markdown_count=$(find docs -name '*.md' -type f | wc -l | tr -d ' ')
langchain_count=$(find docs/04-LangChain与单Agent -name '*.md' -type f | wc -l | tr -d ' ')
langgraph_count=$(find docs/06-LangGraph有状态工作流 -name '*.md' -type f | wc -l | tr -d ' ')

printf '内容检查通过：Markdown=%s，LangChain=%s，LangGraph=%s\n' \
  "$markdown_count" "$langchain_count" "$langgraph_count"
