# shellcheck shell=bash
# SKILL.md frontmatter 校验(build 期):Agent Skills 规范要求 frontmatter 带
# name + description。缺失时客户端静默拒载(codex 实证:git-workflow 事件),
# 运行时排障代价高 —— 在 build 期拦住,坏 skill 进不了系统。
# 用法: skill-frontmatter-check.sh <SKILL.md 路径>
# 模块内 normalizeSkillSource 与 flake check 的负例测试共用本脚本(单一真源)。
set -euo pipefail

sk=$1
[[ -f "$sk" ]] || { echo "ERROR: skill 目录缺 SKILL.md: $sk" >&2; exit 1; }

fm=$(
  awk '
    NR == 1 { if ($0 != "---") exit 1; infm = 1; next }
    infm    { if ($0 == "---") { closed = 1; exit }
              print }
    END     { if (!closed) exit 1 }
  ' "$sk"
) || { echo "ERROR: $sk: 缺 --- ... --- frontmatter 块" >&2; exit 1; }

printf '%s\n' "$fm" | grep -qE '^name:[[:space:]]*[^[:space:]]+' \
  || { echo "ERROR: $sk: frontmatter 缺 name" >&2; exit 1; }
printf '%s\n' "$fm" | grep -qE '^description:[[:space:]]*[^[:space:]]+' \
  || { echo "ERROR: $sk: frontmatter 缺 description" >&2; exit 1; }
