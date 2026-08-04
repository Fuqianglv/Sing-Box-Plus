#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 稳定入口：不修改协议配置，不做额外 Reality 自测。
# 仅把 GH_TOKEN / GIST_ID 传给原始 vps-deploy/deploy.sh。

DEPLOY_URL="https://raw.githubusercontent.com/lvfuq/vps-deploy/main/deploy.sh"
DEFAULT_GIST_ID="85a7d7b63d151e78558a4737aca3ce02"

GH_TOKEN="${GH_TOKEN:-${1:-}}"
GIST_ID="${GIST_ID:-${2:-$DEFAULT_GIST_ID}}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "[ERROR] 请用 root 执行" >&2
  exit 1
}

if [[ -z "$GH_TOKEN" ]]; then
  read -rsp "请输入 GitHub Token（需要 Gists 写权限）: " GH_TOKEN </dev/tty
  echo
fi

[[ -n "$GH_TOKEN" ]] || {
  echo "[ERROR] GH_TOKEN 为空" >&2
  exit 1
}

[[ "$GIST_ID" =~ ^[0-9a-fA-F]{20,64}$ ]] || {
  echo "[ERROR] GIST_ID 格式不正确：$GIST_ID" >&2
  exit 1
}

if ! command -v curl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends curl ca-certificates
fi

export GH_TOKEN GIST_ID

TMP="$(mktemp /tmp/vps-deploy.XXXXXX.sh)"
cleanup(){
  rm -f "$TMP"
  unset GH_TOKEN
}
trap cleanup EXIT

curl -fL --retry 3 --connect-timeout 15 "$DEPLOY_URL" -o "$TMP"
bash -n "$TMP"
bash "$TMP"
