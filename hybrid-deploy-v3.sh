#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Stable composition:
# 1) run the pinned robust hybrid deployer;
# 2) regenerate subscription links with Hysteria2 pinSHA256 and no allowInsecure.

DEPLOY_COMMIT="4816ae7d4daa60eae5343d37f611f25c4a6d19f4"
REPAIR_COMMIT="fe06fcd47896edacb334afc605147c9866e961ff"
REPO_RAW="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus"
DEFAULT_GIST_ID="85a7d7b63d151e78558a4737aca3ce02"
TMP_DIR="$(mktemp -d /tmp/hybrid-deploy-v3.XXXXXX)"

cleanup(){
  rm -rf "$TMP_DIR"
  unset GH_TOKEN || true
}
trap cleanup EXIT

GH_TOKEN="${GH_TOKEN:-}"
GIST_ID="${GIST_ID:-$DEFAULT_GIST_ID}"

# Preserve all original arguments for the deployer while resolving token/Gist
# for the post-deployment subscription repair.
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

curl -fL --retry 3 --retry-all-errors \
  "$REPO_RAW/$DEPLOY_COMMIT/hybrid-deploy-v2.sh" \
  -o "$TMP_DIR/deploy.sh"
curl -fL --retry 3 --retry-all-errors \
  "$REPO_RAW/$REPAIR_COMMIT/repair-subscription-v2.sh" \
  -o "$TMP_DIR/repair.sh"

bash -n "$TMP_DIR/deploy.sh"
bash -n "$TMP_DIR/repair.sh"

bash "$TMP_DIR/deploy.sh" "$@"
GH_TOKEN="$GH_TOKEN" GIST_ID="$GIST_ID" bash "$TMP_DIR/repair.sh"
