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

# 深度章节必须有阅读前置声明（各阶段第 1 章为起点，豁免）。
for file in docs/0[2-9]-*/*.md docs/1[0-1]-*/*.md; do
  base=$(basename "$file")
  if [[ "$base" == 01-* ]]; then
    continue
  fi
  line_count=$(wc -l < "$file" | tr -d ' ')
  if (( line_count >= 120 )); then
    if ! head -n 50 "$file" | grep -Eq '阅读前置|本章从哪里开始'; then
      printf '深度章节缺少阅读前置声明：%s\n' "$file"
      missing=1
    fi
  fi
done

# 章节自述所属阶段（"本章是第 N 阶段"）必须与其所在目录编号一致，
# 防止里程碑/专题章节错标阶段（跨章节引用其他阶段不受此规则限制）。
for file in docs/0[2-9]-*/*.md docs/1[0-1]-*/*.md; do
  dir_num=$(printf '%s' "$file" | sed -E 's|^docs/([0-9]+)-.*|\1|')
  dir_num=$((10#$dir_num))
  while IFS= read -r line; do
    stage_num=$(printf '%s\n' "$line" | sed -E 's/.*本章是第 ([0-9]+) 阶段.*/\1/')
    if [[ "$stage_num" =~ ^[0-9]+$ ]] && (( stage_num != dir_num )); then
      printf '阶段编号与目录不一致：%s（自述第 %s 阶段，目录编号 %s）\n' "$file" "$stage_num" "$dir_num"
      missing=1
    fi
  done < <(grep -E '本章是第 [0-9]+ 阶段' "$file" || true)
done

# 目录状态标记与实际深度一致性：
# 目录中标记为 已完成/里程碑 的章节，正文深度不得低于 120 行（大纲章节不受限）。
catalog="docs/01-总览与使用方式/04-完整教程目录.md"

while IFS= read -r line; do
  fname=$(printf '%s\n' "$line" | sed -E 's/^[0-9]+\. `([^`]+\.md)`.*/\1/')
  if printf '%s\n' "$line" | grep -qE '`(已完成|里程碑)`'; then
    file=$(find docs -name "$fname" -print -quit)
    if [[ -z "$file" ]]; then
      printf '目录标记为完成，但找不到文件：%s\n' "$fname"
      missing=1
      continue
    fi
    line_count=$(wc -l < "$file" | tr -d ' ')
    if (( line_count < 120 )); then
      printf '目录标记为已完成/里程碑但深度不足（%s 行 < 120）：%s\n' "$line_count" "$file"
      missing=1
    fi
  fi
done < <(grep -E '^[0-9]+\. `[^`]+\.md`' "$catalog")

job_audit_chapters=(
  "docs/01-总览与使用方式/08-岗位能力再审计.md"
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

mastery_and_job_chapters=(
  "docs/01-总览与使用方式/09-无固定周期的能力门槛学习路线.md"
  "docs/04-LangChain与单Agent/09-主流Agent框架横向迁移实验.md"
  "docs/05-RAG与知识系统/10-Text2SQL数据Agent与数据库安全.md"
  "docs/05-RAG与知识系统/11-多模态文档图片与语音Agent.md"
  "docs/06-LangGraph有状态工作流/08-子图与多Agent模式.md"
  "docs/06-LangGraph有状态工作流/11-A2A-Agent-Skills与跨Agent协作.md"
  "docs/07-LangSmith评测与可观测性/07-平台无关评测体系与数据飞轮.md"
  "docs/08-MCP安全与工程化/12-Agent运行时模型网关沙箱与平台化.md"
  "docs/09-Java业务服务集成/06-Spring-AI与Java-Agent生态岗位适配.md"
  "docs/11-面试准备/04-Agent系统设计题.md"
  "docs/11-面试准备/09-英文官方文档源码阅读与陌生技术学习.md"
)

for file in "${mastery_and_job_chapters[@]}"; do
  if [[ ! -f "$file" ]]; then
    printf '能力门槛或岗位适配章节缺失：%s\n' "$file"
    missing=1
    continue
  fi

  line_count=$(wc -l < "$file" | tr -d ' ')
  if (( line_count < 160 )); then
    printf '能力门槛或岗位适配章节深度不足（少于 160 行）：%s，当前=%s\n' "$file" "$line_count"
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

# MCP 规范课程基线固定为 2025-11-25（见附录“版本迁移与过时 API”），
# 禁止正文链接旧版 2025-06-18 规范，防止跨版本示例混用。
if grep -REn --include='*.md' 'specification/2025-06-18' docs; then
  printf '发现指向旧版 MCP 规范（2025-06-18）的链接，课程基线为 2025-11-25。\n'
  exit 1
fi

for milestone in M0 M1 M2 M3 M4 M5 M6; do
  if ! grep -REq --include="*.md" "$milestone" docs; then
    printf '能力里程碑缺失：%s\n' "$milestone"
    exit 1
  fi
done

if ! grep -q '无固定周期的能力门槛学习路线' docs/index.md; then
  printf '教程首页未将能力门槛路线设为默认入口。\n'
  exit 1
fi

if ! grep -q '压缩排期参考' docs/01-总览与使用方式/02-24周学习计划.md; then
  printf '24 周文件未明确标注为压缩排期参考。\n'
  exit 1
fi

markdown_count=$(find docs -name '*.md' -type f | wc -l | tr -d ' ')
langchain_count=$(find docs/04-LangChain与单Agent -name '*.md' -type f | wc -l | tr -d ' ')
langgraph_count=$(find docs/06-LangGraph有状态工作流 -name '*.md' -type f | wc -l | tr -d ' ')

printf '内容检查通过：Markdown=%s，LangChain=%s，LangGraph=%s\n' \
  "$markdown_count" "$langchain_count" "$langgraph_count"
