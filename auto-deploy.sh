#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 固定读取上一版完整部署器，并在执行前应用 Xray REALITY 新版字段兼容修复。
# Xray 新版客户端 realitySettings 使用 password 保存服务端公钥，
# 旧字段 publicKey 可能导致服务端记录 processed invalid connection。

BASE_COMMIT="9a275359cf5fe29d8349f6f66b1bca6df92d574f"
BASE_URL="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus/${BASE_COMMIT}/auto-deploy.sh"
TMP="$(mktemp /tmp/auto-deploy-fixed.XXXXXX)"

cleanup(){
  rm -f "$TMP"
}
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --connect-timeout 15 "$BASE_URL" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP" "$BASE_URL"
else
  echo "[ERROR] 系统缺少 curl/wget" >&2
  exit 1
fi

# Xray 当前 REALITY 客户端字段：password = 服务端公钥。
sed -i 's/publicKey:\$p/password:\$p/g' "$TMP"

bash -n "$TMP"
bash "$TMP" "$@"
