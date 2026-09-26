# shellcheck shell=bash
# programs.zcode activation 沙箱干跑:真实 HM 求值渲染出的四个 activation
# 脚本,打在临时 HOME 的仿真 GUI 状态上,断言四条性质 ——
#   1) agents/commands:拷贝落位 + sidecar 记名
#   2) sidecar GC:旧 nix 部署回收,GUI 自建文件零接触
#   3) providers/mcp:upsert 带 nixManaged 标记 + builtin/GUI 条目零接触
#   4) 幂等:二跑不改文件(对账无漂移)
# 用法: activation-dryrun.sh <agentsScript> <providersScript> <mcpScript> <pruneScript> <validator> <skillOut>
# 背景:2026-08-20 曾交付一个 bash `local a=x b=$a` 同语句引用坑(set -u 下
# unbound)导致 activation 静默失败 —— 本测试在 bash -euo pipefail 下执行渲染
# 后脚本,同族问题在 flake check 期即暴露。
set -euo pipefail

agents_script=$1
providers_script=$2
mcp_script=$3
prune_script=$4
validator=$5
skill_out=$6

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
  "custom:legacy-nix": {"name": "旧方案死信条目", "nixManaged": true}
}}
EOF
cat > "$HOME/.zcode/cli/config.json" <<'EOF'
{"mcp": {"servers": {
  "gui-server": {"command": "x"},
  "stale-server": {"command": "y", "nixManaged": true}
}}}
EOF
# providers 真源夹具:custom:gui 是 GUI 自建条目(零接触);
# custom:stale 是旧 nix 部署(sidecar 记名,GC 目标:规则+order+模型规则)
cat > "$HOME/.zcode/v2/provider_config.json" <<'EOF'
{"schemaVersion": 1, "config": {
  "modelConfigRules": {"providerModelRules": [
    {"providerId": "custom:gui", "modelId": "g1",
     "config": {"properties": {"contextWindow": 300000}}},
    {"providerId": "custom:stale", "modelId": "old",
     "config": {"properties": {"contextWindow": 100}}}
  ], "manualProviderModelRules": []},
  "providerConfigRules": {"providerRules": [
    {"providerId": "custom:gui", "providerName": "gui", "enabled": false,
     "config": {"group": "standard-personal",
                "access": {"type": "api-key", "apiKey": "gui-key"},
                "api": {"type": "anthropic-messages", "baseUrl": "https://gui.test"},
                "personalModelIds": ["g1"], "modelOrder": ["g1"]}},
    {"providerId": "custom:stale", "providerName": "stale",
     "config": {"group": "standard-personal",
                "access": {"type": "api-key"},
                "api": {"type": "openai-chat-completions", "baseUrl": "https://stale.test"}}}
  ]},
  "providerOrder": ["custom:gui", "custom:stale"]
}}
EOF
printf 'P custom:stale\nM custom:stale|old\n' > "$HOME/.zcode/v2/provider_config.nix-managed"

# 自写 desktop 文件双 fixture:死链(Exec 指向不存在的 store 路径,GC 目标)
# 与活链(Exec 指向真实存在的文件,零接触)
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/zcode.desktop" <<EOF
[Desktop Entry]
Exec="/nix/store/0000000000000000000000000000000-zcode-3.8.1/bin/zcode" %U
EOF
live_exec=$validator
cat > "$HOME/.local/share/applications/other.desktop" <<EOF
[Desktop Entry]
Exec="$live_exec" %U
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
bash -euo pipefail "$prune_script"

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

# ── 断言 3:providers 对账(真源 provider_config.json)──
pc="$HOME/.zcode/v2/provider_config.json"
demo=$(jq -c '.config.providerConfigRules.providerRules[] | select(.providerId=="custom:demo")' "$pc")
[[ "$(jq -r '.config.group' <<<"$demo")" == "standard-personal" ]] \
  || fail "custom:demo 缺 standard-personal 分组(GUI 不显示)"
[[ "$(jq -r '.config.access.apiKey' <<<"$demo")" == "k3y-xyz" ]] \
  || fail "custom:demo 未注入/secret 未渲染"
[[ "$(jq -r '.config.api.type' <<<"$demo")" == "anthropic-messages" ]] \
  || fail "kind→api.type 映射错误"
[[ "$(jq -r '.config.api.baseUrl' <<<"$demo")" == "https://example.test/v1" ]] \
  || fail "custom:demo baseUrl 未注入"
[[ "$(jq -c '.config.personalModelIds' <<<"$demo")" == '["m1"]' ]] \
  || fail "custom:demo personalModelIds 未注入"
[[ "$(jq -c '.config.providerOrder' "$pc")" == '["custom:gui","custom:demo"]' ]] \
  || fail "providerOrder 语义错误(stale 应摘除,demo 应 append 末尾)"
gui=$(jq -c '.config.providerConfigRules.providerRules[] | select(.providerId=="custom:gui")' "$pc")
[[ "$(jq -r '.config.access.apiKey' <<<"$gui")" == "gui-key" && "$(jq -r '.enabled' <<<"$gui")" == "false" ]] \
  || fail "GUI 条目或其停用意图被动了"
[[ "$(jq '[.config.providerConfigRules.providerRules[] | select(.providerId=="custom:stale")] | length' "$pc")" == "0" ]] \
  || fail "stale providerRule 未被 GC"
[[ "$(jq '[.config.modelConfigRules.providerModelRules[] | select(.providerId=="custom:stale")] | length' "$pc")" == "0" ]] \
  || fail "stale 模型规则未被 GC"
[[ "$(jq -c '.config.modelConfigRules.providerModelRules[] | select(.providerId=="custom:gui") | .config.properties.contextWindow' "$pc")" == "300000" ]] \
  || fail "GUI 模型规则被碰"

# ── 断言 3b:模型规则(context/output/reasoning 一条龙)──
m1=$(jq -c '.config.modelConfigRules.providerModelRules[] | select(.providerId=="custom:demo" and .modelId=="m1")' "$pc")
[[ "$(jq -r '.config.properties.contextWindow' <<<"$m1")" == "1000" ]] \
  || fail "contextWindow 未注入"
[[ "$(jq -r '.config.optionSpecs.maxOutputTokens.max' <<<"$m1")" == "100" ]] \
  || fail "maxOutputTokens 未注入"
[[ "$(jq -r '.config.optionSpecs.reasoningLevel.values | join(",")' <<<"$m1")" == "low,high" ]] \
  || fail "reasoningLevel.values 未注入"
[[ "$(jq -r '.config.optionSpecs.reasoningLevel.map' <<<"$m1")" == *reasoning_effort* ]] \
  || fail "reasoningLevel.map 未注入"
grep -qxF 'P custom:demo' "$HOME/.zcode/v2/provider_config.nix-managed" \
  || fail "sidecar 未记 provider 名"
grep -qxF 'M custom:demo|m1' "$HOME/.zcode/v2/provider_config.nix-managed" \
  || fail "sidecar 未记模型规则名"

# ── 断言 3c:死信层回收(config.json)──
[[ "$(jq -r '.provider["custom:legacy-nix"] // "gone"' "$HOME/.zcode/v2/config.json")" == "gone" ]] \
  || fail "config.json 旧 nixManaged 条目未回收"
[[ "$(jq -r '.provider["builtin:zhipu"].apiKey' "$HOME/.zcode/v2/config.json")" == "oauth-token" ]] \
  || fail "config.json builtin 槽位被碰"
[[ "$(jq -r '.provider["custom:gui"].name' "$HOME/.zcode/v2/config.json")" == "gui-owned" ]] \
  || fail "config.json GUI 条目被碰"

# ── 断言 3b:mcp 对账 ──
[[ "$(jq -r '.mcp.servers.echo.env.TOKEN' "$HOME/.zcode/cli/config.json")" == "k3y-xyz" ]] \
  || fail "mcp echo 未注入/secret 未渲染"
[[ "$(jq -r '.mcp.servers["gui-server"].nixManaged // "none"' "$HOME/.zcode/cli/config.json")" == "none" ]] \
  || fail "GUI mcp 条目被动了"
[[ "$(jq -r '.mcp.servers["stale-server"] // "gone"' "$HOME/.zcode/cli/config.json")" == "gone" ]] \
  || fail "stale mcp 未被 GC"
[[ "$(stat -c %a "$HOME/.zcode/cli/config.json")" == "600" ]] || fail "cli/config.json 未收紧 600"

# ── 断言 3c:自写 desktop 死链清理 ──
[[ ! -e "$HOME/.local/share/applications/zcode.desktop" ]] \
  || fail "死链 zcode.desktop 未被清理"
grep -q "^Exec=\"$live_exec\"" "$HOME/.local/share/applications/other.desktop" \
  || fail "非 zcode 的 desktop 文件被动了(清理必须只点名 zcode.desktop)"

# ── 断言 4:幂等(二跑零漂移)──
# 同时覆盖正例:app 刚自注册的活链 zcode.desktop(Exec 指向真实路径),
# 二跑必须零接触 —— 清理只杀死链,不与 app 的自管拉锯
p1=$(md5sum "$HOME/.zcode/v2/config.json" | cut -d' ' -f1)
m1=$(md5sum "$HOME/.zcode/cli/config.json" | cut -d' ' -f1)
r1=$(md5sum "$HOME/.zcode/v2/provider_config.json" | cut -d' ' -f1)
cat > "$HOME/.local/share/applications/zcode.desktop" <<EOF
[Desktop Entry]
Exec="$validator" "--enable-features=WaylandWindowDecorations" %U
EOF
d1=$(md5sum "$HOME/.local/share/applications/zcode.desktop" | cut -d' ' -f1)
bash -euo pipefail "$agents_script"
bash -euo pipefail "$providers_script"
bash -euo pipefail "$mcp_script"
bash -euo pipefail "$prune_script"
p2=$(md5sum "$HOME/.zcode/v2/config.json" | cut -d' ' -f1)
m2=$(md5sum "$HOME/.zcode/cli/config.json" | cut -d' ' -f1)
r2=$(md5sum "$HOME/.zcode/v2/provider_config.json" | cut -d' ' -f1)
[[ "$p1" == "$p2" ]] || fail "providers 二跑漂移"
[[ "$m1" == "$m2" ]] || fail "mcp 二跑漂移"
[[ "$r1" == "$r2" ]] || fail "reasoning 二跑漂移"
grep -q 'gui-body' "$HOME/.zcode/agents/gui-made.md" || fail "二跑动了 GUI 文件"
d2=$(md5sum "$HOME/.local/share/applications/zcode.desktop" | cut -d' ' -f1)
[[ "$d1" == "$d2" ]] || fail "活链 zcode.desktop 二跑被动了(只该清理死链)"

echo "activation dry-run: all assertions passed"
