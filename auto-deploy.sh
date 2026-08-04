#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 默认入口：每次都执行完整重装。
# - 强制重新下载/安装 Xray-core 与 sing-box
# - 强制重新生成端口、UUID、密码、证书和密钥
# - 重建基础服务后，将不可用的 Reality 节点替换为 3 个 AnyTLS
# - 最终覆盖更新 Gist 订阅

FINAL_COMMIT="da3a14a192b96f20ee71f6b09f22d67f851b742f"
FINAL_URL="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus/${FINAL_COMMIT}/hybrid-deploy-v4.sh"
TMP="$(mktemp /tmp/auto-deploy.XXXXXX.sh)"

cleanup(){
  rm -f "$TMP"
}
trap cleanup EXIT

curl -fL --retry 3 --retry-all-errors --connect-timeout 15 "$FINAL_URL" -o "$TMP"
bash -n "$TMP"

# 无论服务器是否已有配置，都强制走完整安装并轮换全部凭据。
exec bash "$TMP" "$@" --rotate --update-core
