#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq
# shellcheck shell=bash
#
# 重写 source.json 的版本与 hash。
# 上游 CDN 没有 "latest 指针"文件(latest.yml 必须按已知版本号访问),且实测:
#   - 官网 HTML 版本列表滞后(3.8.1 发布当天仍只列到 3.7.7)→ 不能作数据源
#   - 版本会跳号(3.8.0 不存在)→ 不能从当前版本 +1 递推
# 策略:以当前版本为锚,探测 minor 当前..+2 × patch 0..30 的 linux-x64
# latest.yml(升序扫描,最后命中即最大),再校验双架构 .deb 存在并 prefetch。
# major 跳版(如 4.0.0)超出探测范围,需手动改 source.json 锚点。

set -o errexit
set -o nounset
set -o pipefail

BASE_URL="https://cdn-zcode.z.ai/zcode/electron/releases"

SOURCE_JSON=${SOURCE_JSON:-"$(dirname "${BASH_SOURCE[0]}")/source.json"}

CURRENT_VERSION=$(jq -r '."x86_64-linux".version' "$SOURCE_JSON")
IFS='.' read -r MAJOR MINOR _PATCH <<< "$CURRENT_VERSION"

LATEST_VERSION=""
for ((m = MINOR; m <= MINOR + 2; m++)); do
  for ((p = 0; p <= 30; p++)); do
    v="$MAJOR.$m.$p"
    if curl --silent --fail --head --location \
      --output /dev/null "$BASE_URL/$v/linux-x64/latest.yml"; then
      LATEST_VERSION=$v
    fi
  done
done

[[ -n "$LATEST_VERSION" ]] || { echo "ERROR: no candidate version found" >&2; exit 1; }

# 目录版本须与 latest.yml 声明版本一致(3.7.7/3.8.1 实测一致,防 CDN 异常)
YML_VERSION=$(
  curl --fail --location --silent --show-error "$BASE_URL/$LATEST_VERSION/linux-x64/latest.yml" \
    | sed -n 's/^version: //p'
)
[[ "$YML_VERSION" == "$LATEST_VERSION" ]] || {
  echo "ERROR: latest.yml version '$YML_VERSION' != dir '$LATEST_VERSION'" >&2
  exit 1
}

if jq -e --arg v "$LATEST_VERSION" \
  '.["x86_64-linux"].version == $v and .["aarch64-linux"].version == $v' \
  "$SOURCE_JSON" >/dev/null; then
  echo "zcode is already up to date ($LATEST_VERSION)" >&2
  exit 0
fi

X64_URL="$BASE_URL/$LATEST_VERSION/linux-x64/ZCode-$LATEST_VERSION-linux-x64.deb"
ARM64_URL="$BASE_URL/$LATEST_VERSION/linux-arm64/ZCode-$LATEST_VERSION-linux-arm64.deb"

for url in "$X64_URL" "$ARM64_URL"; do
  curl --silent --fail --head --location --output /dev/null "$url" \
    || { echo "ERROR: missing asset: $url" >&2; exit 1; }
done

X64_HASH=$(nix store prefetch-file --json "$X64_URL" | jq -r .hash)
ARM64_HASH=$(nix store prefetch-file --json "$ARM64_URL" | jq -r .hash)

jq -n \
  --arg v "$LATEST_VERSION" \
  --arg x64_url "$X64_URL" \
  --arg x64_hash "$X64_HASH" \
  --arg arm64_url "$ARM64_URL" \
  --arg arm64_hash "$ARM64_HASH" \
  '{
    "aarch64-linux": {
      "version": $v,
      "src": { "url": $arm64_url, "hash": $arm64_hash }
    },
    "x86_64-linux": {
      "version": $v,
      "src": { "url": $x64_url, "hash": $x64_hash }
    }
  }' > "$SOURCE_JSON"

echo "zcode updated to $LATEST_VERSION" >&2
