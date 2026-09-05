#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 默认入口：每次完整重装代理环境。
# 1) 重新下载核心，重新生成端口、凭据、证书和密钥；
# 2) 使用最多 30 秒的服务/端口等待检查；
# 3) 迁移为移动网络优先的 4 TCP + 2 UDP 节点；
# 4) 覆盖更新 Gist 订阅。

DEFAULT_GIST_ID="85a7d7b63d151e78558a4737aca3ce02"
BASE_COMMIT="0b24993f611d982a1f4fe9c6fd640a57f46b3552"
MIGRATE_COMMIT="86d34b3129c8601fc76aadfefa1e116362d00efe"
RAW="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus"
TMP_DIR="$(mktemp -d /tmp/auto-deploy-full.XXXXXX)"

cleanup(){
  rm -rf "$TMP_DIR"
  unset GH_TOKEN || true
}
trap cleanup EXIT

GH_TOKEN="${GH_TOKEN:-}"
GIST_ID="${GIST_ID:-$DEFAULT_GIST_ID}"
args=("$@")
idx=0

if [[ -n "${args[0]:-}" && "${args[0]}" != --* ]]; then
  GH_TOKEN="${args[0]}"
  idx=1
fi
if [[ -n "${args[$idx]:-}" && "${args[$idx]}" != --* ]]; then
  GIST_ID="${args[$idx]}"
fi

[[ -n "$GH_TOKEN" ]] || {
  echo "[ERROR] 命令后必须提供 GH_TOKEN" >&2
  exit 1
}
[[ "$GIST_ID" =~ ^[0-9a-fA-F]{20,64}$ ]] || {
  echo "[ERROR] GIST_ID 格式不正确" >&2
  exit 1
}

curl -fL --retry 3 --retry-all-errors --connect-timeout 15 \
  "$RAW/$BASE_COMMIT/hybrid-deploy-v2.sh" \
  -o "$TMP_DIR/base.sh"
curl -fL --retry 3 --retry-all-errors --connect-timeout 15 \
  "$RAW/$MIGRATE_COMMIT/migrate-mobile-v2.sh" \
  -o "$TMP_DIR/migrate.sh"

bash -n "$TMP_DIR/base.sh"
bash -n "$TMP_DIR/migrate.sh"

# 每次都强制下载核心并轮换基础凭据/端口。
bash "$TMP_DIR/base.sh" "$@" --rotate --update-core

# 基础服务成功后，重建为 4 TCP + 2 UDP 的 mobile-first 节点结构。
GH_TOKEN="$GH_TOKEN" GIST_ID="$GIST_ID" \
  bash "$TMP_DIR/migrate.sh"
