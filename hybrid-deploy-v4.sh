#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Final entry: working SS/Hy2/TUIC + three AnyTLS TCP nodes.
# Existing hybrid deployments are migrated in place; fresh/rotate deployments
# first run the pinned v3 installer and then replace Reality with AnyTLS.

DEFAULT_GIST_ID="85a7d7b63d151e78558a4737aca3ce02"
BASE_V3_COMMIT="585e73deddae7eb4adda91fb2540bc95d447efc8"
MIGRATE_COMMIT="30c9122ad89f4388f968f5f913ed29fba91a8d44"
RAW="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus"
TMP_DIR="$(mktemp -d /tmp/hybrid-deploy-v4.XXXXXX)"

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
[[ -n "$GH_TOKEN" ]] || { echo "[ERROR] 命令后必须提供 GH_TOKEN" >&2; exit 1; }
[[ "$GIST_ID" =~ ^[0-9a-fA-F]{20,64}$ ]] || { echo "[ERROR] GIST_ID 格式不正确" >&2; exit 1; }

curl -fL --retry 3 --retry-all-errors "$RAW/$MIGRATE_COMMIT/migrate-anytls-v1.sh" -o "$TMP_DIR/migrate.sh"
bash -n "$TMP_DIR/migrate.sh"

NEED_BASE=0
[[ -s /opt/hybrid-proxy/creds.env && -s /opt/hybrid-proxy/ports.env && -s /opt/sing-box/config.json ]] || NEED_BASE=1
for a in "${args[@]}"; do
  [[ "$a" == --rotate || "$a" == --update-core ]] && NEED_BASE=1
done

if ((NEED_BASE)); then
  curl -fL --retry 3 --retry-all-errors "$RAW/$BASE_V3_COMMIT/hybrid-deploy-v3.sh" -o "$TMP_DIR/base.sh"
  bash -n "$TMP_DIR/base.sh"
  bash "$TMP_DIR/base.sh" "$@"
fi

GH_TOKEN="$GH_TOKEN" GIST_ID="$GIST_ID" bash "$TMP_DIR/migrate.sh"
