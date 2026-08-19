# shellcheck shell=bash
# programs.zcode activation 沙箱干跑:真实 HM 求值渲染出的三个 activation
# 脚本,打在临时 HOME 的仿真 GUI 状态上,断言四条性质 ——
#   1) agents/commands:拷贝落位 + sidecar 记名
#   2) sidecar GC:旧 nix 部署回收,GUI 自建文件零接触
#   3) providers/mcp:upsert 带 nixManaged 标记 + builtin/GUI 条目零接触
#   4) 幂等:二跑不改文件(对账无漂移)
# 用法: activation-dryrun.sh <agentsScript> <providersScript> <mcpScript> <validator> <skillOut>
# 背景:2026-08-20 曾交付一个 bash `local a=x b=$a` 同语句引用坑(set -u 下
# unbound)导致 activation 静默失败 —— 本测试在 bash -euo pipefail 下执行渲染
# 后脚本,同族问题在 flake check 期即暴露。
set -euo pipefail

agents_script=$1
providers_script=$2
mcp_script=$3
validator=$4
skill_out=$5

fail() { echo "FAIL: $*" >&2; exit 1; }

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
export HOME=$home
mkdir -p "$HOME/.zcode/agents" "$HOME/.zcode/commands" "$HOME/.zcode/v2" "$HOME/.zcode/cli"

# ── 预置仿真 GUI 状态 ──
echo stale-body > "$HOME/.zcode/agents/stale.md"       # 旧 nix 部署(GC 目标)
echo gui-body > "$HOME/.zcode/agents/gui-made.md"      # GUI 自建(零接触)
echo old-version > "$HOME/.zcode/agents/robot.md"      # 旧版本(对账覆盖)
printf 'stale.md\n' > "$HOME/.zcode/agents/.nix-managed"
cat > "$HOME/.zcode/v2/config.json" <<'EOF'
{"provider": {
  "builtin:zhipu": {"name": "GLM Coding", "apiKey": "oauth-token"},
  "custom:gui": {"name": "gui-owned"},
  "custom:stale": {"name": "old nix entry", "nixManaged": true}
}}
EOF
cat > "$HOME/.zcode/cli/config.json" <<'EOF'
{"mcp": {"servers": {
  "gui-server": {"command": "x"},
  "stale-server": {"command": "y", "nixManaged": true}
}}}
EOF

# ── 校验器正/负例(缺 description / 无 frontmatter 必须被拒)──
bash "$validator" "$skill_out/SKILL.md" || fail "validator 拒绝了合法 fixture"
bad=$(mktemp)
printf -- '---\nname: x\n---\nbody\n' > "$bad"
if bash "$validator" "$bad" 2>/dev/null; then fail "validator 放行了缺 description"; fi
printf 'no frontmatter here\n' > "$bad"
if bash "$validator" "$bad" 2>/dev/null; then fail "validator 放行了无 frontmatter"; fi

# ── 按 DAG 顺序执行渲染后的 activation 脚本 ──
bash -euo pipefail "$agents_script"
bash -euo pipefail "$providers_script"
bash -euo pipefail "$mcp_script"

# ── 断言 1:agents/commands 拷贝落位(普通文件,非 symlink)──
[[ -f "$HOME/.zcode/agents/robot.md" && ! -L "$HOME/.zcode/agents/robot.md" ]] \
  || fail "robot.md 不是普通文件"
grep -q 'dry-run fixture agent' "$HOME/.zcode/agents/robot.md" \
  || fail "robot.md 未更新为新版本"
grep -q '^model:' "$HOME/.zcode/agents/robot.md" || fail "robot.md 缺 frontmatter"
grep -q 'say hi' "$HOME/.zcode/commands/hi.md" || fail "commands/hi.md 未落位"
grep -qx 'robot.md' "$HOME/.zcode/agents/.nix-managed" || fail "sidecar 未记 robot.md"

# ── 断言 2:GC + GUI 零接触 ──
[[ ! -e "$HOME/.zcode/agents/stale.md" ]] || fail "stale.md 未被 GC"
grep -q 'gui-body' "$HOME/.zcode/agents/gui-made.md" || fail "GUI 自建 agent 被动了"
! grep -qx 'stale.md' "$HOME/.zcode/agents/.nix-managed" || fail "sidecar 仍记 stale.md"

# ── 断言 3:providers 对账 ──
[[ "$(jq -r '.provider["custom:demo"].options.apiKey' "$HOME/.zcode/v2/config.json")" == "k3y-xyz" ]] \
  || fail "custom:demo 未注入/secret 未渲染"
[[ "$(jq -r '.provider["custom:demo"].nixManaged' "$HOME/.zcode/v2/config.json")" == "true" ]] \
  || fail "custom:demo 缺 nixManaged 标记"
[[ "$(jq -r '.provider["builtin:zhipu"].apiKey' "$HOME/.zcode/v2/config.json")" == "oauth-token" ]] \
  || fail "builtin 槽位被碰(oauth 领地)"
[[ "$(jq -r '.provider["custom:gui"].nixManaged // "none"' "$HOME/.zcode/v2/config.json")" == "none" ]] \
  || fail "GUI 条目被动了"
[[ "$(jq -r '.provider["custom:stale"] // "gone"' "$HOME/.zcode/v2/config.json")" == "gone" ]] \
  || fail "stale provider 未被 GC"

# ── 断言 3b:mcp 对账 ──
[[ "$(jq -r '.mcp.servers.echo.env.TOKEN' "$HOME/.zcode/cli/config.json")" == "k3y-xyz" ]] \
  || fail "mcp echo 未注入/secret 未渲染"
[[ "$(jq -r '.mcp.servers["gui-server"].nixManaged // "none"' "$HOME/.zcode/cli/config.json")" == "none" ]] \
  || fail "GUI mcp 条目被动了"
[[ "$(jq -r '.mcp.servers["stale-server"] // "gone"' "$HOME/.zcode/cli/config.json")" == "gone" ]] \
  || fail "stale mcp 未被 GC"
[[ "$(stat -c %a "$HOME/.zcode/cli/config.json")" == "600" ]] || fail "cli/config.json 未收紧 600"

# ── 断言 4:幂等(二跑零漂移)──
p1=$(md5sum "$HOME/.zcode/v2/config.json" | cut -d' ' -f1)
m1=$(md5sum "$HOME/.zcode/cli/config.json" | cut -d' ' -f1)
bash -euo pipefail "$agents_script"
bash -euo pipefail "$providers_script"
bash -euo pipefail "$mcp_script"
p2=$(md5sum "$HOME/.zcode/v2/config.json" | cut -d' ' -f1)
m2=$(md5sum "$HOME/.zcode/cli/config.json" | cut -d' ' -f1)
[[ "$p1" == "$p2" ]] || fail "providers 二跑漂移"
[[ "$m1" == "$m2" ]] || fail "mcp 二跑漂移"
grep -q 'gui-body' "$HOME/.zcode/agents/gui-made.md" || fail "二跑动了 GUI 文件"

echo "activation dry-run: all assertions passed"
