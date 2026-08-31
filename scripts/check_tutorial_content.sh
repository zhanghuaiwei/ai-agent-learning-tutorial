#!/usr/bin/env bash

set -euo pipefail

missing=0

for file in docs/0[2-9]-*/*.md docs/10-*/*.md docs/11-*/*.md; do
  if ! rg -q '^#{1,6} .*练习' "$file"; then
    printf '缺少练习：%s\n' "$file"
    missing=1
  fi

  if ! rg -q '^#{1,6} .*资料|^#{1,6} .*参考' "$file"; then
    printf '缺少资料来源：%s\n' "$file"
    missing=1
  fi
done

if (( missing != 0 )); then
  exit 1
fi

if rg -n \
  '50 ?元|50元|40 ?元|40元|MONTHLY_BUDGET_CNY|budget_remaining|费用上限|成本上限' \
  docs -g '*.md'; then
  printf '发现与“无固定 API 金额上限”冲突的内容。\n'
  exit 1
fi

check_milestone() {
  milestone="$1"
  expected="$2"
  if ! rg -q "$expected" docs -g "*${milestone}*.md"; then
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
