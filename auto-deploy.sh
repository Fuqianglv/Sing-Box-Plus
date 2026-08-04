#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 默认稳定入口：3 个 AnyTLS + SS AES + SS2022 + Hy2 + Hy2 OBFS + TUIC。
# 已有 hybrid 部署只做原地迁移；新服务器自动完整部署。

FINAL_COMMIT="da3a14a192b96f20ee71f6b09f22d67f851b742f"
FINAL_URL="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus/${FINAL_COMMIT}/hybrid-deploy-v4.sh"
TMP="$(mktemp /tmp/auto-deploy.XXXXXX.sh)"

cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT

curl -fL --retry 3 --retry-all-errors --connect-timeout 15 "$FINAL_URL" -o "$TMP"
bash -n "$TMP"
exec bash "$TMP" "$@"
