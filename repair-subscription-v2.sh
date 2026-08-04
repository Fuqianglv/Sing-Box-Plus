#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEFAULT_GIST_ID="85a7d7b63d151e78558a4737aca3ce02"
GH_TOKEN="${GH_TOKEN:-${1:-}}"
GIST_ID="${GIST_ID:-${2:-$DEFAULT_GIST_ID}}"
ROOT_DIR="/opt/hybrid-proxy"
CREDS_FILE="$ROOT_DIR/creds.env"
PORTS_FILE="$ROOT_DIR/ports.env"
CERT_FILE="$ROOT_DIR/cert/fullchain.pem"
SUB_PLAIN="$ROOT_DIR/sub_plain.txt"
SUB_B64="$ROOT_DIR/sub.txt"
TMP_DIR="$(mktemp -d /tmp/repair-subscription.XXXXXX)"

cleanup(){
  rm -rf "$TMP_DIR"
  unset GH_TOKEN || true
}
trap cleanup EXIT

die(){ echo "[ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 执行"
[[ -n "$GH_TOKEN" ]] || die "命令后必须提供 GH_TOKEN"
[[ "$GIST_ID" =~ ^[0-9a-fA-F]{20,64}$ ]] || die "GIST_ID 格式不正确"
[[ -s "$CREDS_FILE" ]] || die "缺少 $CREDS_FILE"
[[ -s "$PORTS_FILE" ]] || die "缺少 $PORTS_FILE"
[[ -s "$CERT_FILE" ]] || die "缺少 $CERT_FILE"

# shellcheck disable=SC1090
source "$CREDS_FILE"
# shellcheck disable=SC1090
source "$PORTS_FILE"

required=(UUID SS_AES_PASSWORD SS2022_PASSWORD HY2_PASSWORD HY2_OBFS_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_SNI REALITY_PUBLIC REALITY_SID XRAY_VISION_PORT XRAY_PLAIN_PORT SS_AES_PORT SS2022_PORT HY2_PORT HY2_OBFS_PORT TUIC_PORT)
for v in "${required[@]}"; do
  [[ -n "${!v:-}" ]] || die "变量 $v 为空"
done

SERVER_IP="$(curl -4fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || die "未检测到公网 IPv4"

# Hysteria2 官方 pinSHA256 使用证书 SHA-256 指纹。
CERT_SHA="$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr -d '\r\n')"
[[ "$CERT_SHA" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || die "证书 SHA-256 指纹格式异常"

urlenc(){
  local s="$1" out="" c i
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  printf '%s' "$out"
}

b64url(){ base64 -w 0 2>/dev/null | tr '+/' '-_' | tr -d '='; }

HY2_AUTH="$(urlenc "$HY2_PASSWORD")"
HY2_OBFS_AUTH="$(urlenc "$HY2_OBFS_PASSWORD")"
CERT_SHA_ENC="$(urlenc "$CERT_SHA")"
TUIC_PASS_ENC="$(urlenc "$TUIC_PASSWORD")"

{
  echo "vless://${UUID}@${SERVER_IP}:${XRAY_VISION_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&spx=%2F&type=tcp#xray-vless-reality-vision"
  echo "vless://${UUID}@${SERVER_IP}:${XRAY_PLAIN_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&spx=%2F&type=tcp#xray-vless-reality"
  echo "ss://$(printf '%s' "aes-256-gcm:${SS_AES_PASSWORD}" | b64url)@${SERVER_IP}:${SS_AES_PORT}#ss-aes256"
  echo "ss://$(printf '%s' "2022-blake3-aes-256-gcm:${SS2022_PASSWORD}" | b64url)@${SERVER_IP}:${SS2022_PORT}#ss2022"
  echo "hysteria2://${HY2_AUTH}@${SERVER_IP}:${HY2_PORT}/?sni=${REALITY_SNI}&pinSHA256=${CERT_SHA_ENC}#hysteria2"
  echo "hysteria2://${HY2_AUTH}@${SERVER_IP}:${HY2_OBFS_PORT}/?sni=${REALITY_SNI}&pinSHA256=${CERT_SHA_ENC}&obfs=salamander&obfs-password=${HY2_OBFS_AUTH}#hysteria2-obfs"
  echo "tuic://${TUIC_UUID}:${TUIC_PASS_ENC}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=1&allowInsecure=1&sni=${REALITY_SNI}#tuic-v5"
} >"$SUB_PLAIN"

[[ "$(wc -l <"$SUB_PLAIN")" -eq 7 ]] || die "订阅节点数量错误"
base64 -w 0 "$SUB_PLAIN" >"$SUB_B64"
chmod 600 "$SUB_PLAIN" "$SUB_B64"

jq -n --rawfile plain "$SUB_PLAIN" --rawfile sub "$SUB_B64" \
  '{files:{"sub_plain.txt":{content:$plain},"sub.txt":{content:$sub}}}' >"$TMP_DIR/payload.json"

code="$(curl -sS -o "$TMP_DIR/gist.json" -w '%{http_code}' -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H 'Content-Type: application/json' \
  "https://api.github.com/gists/$GIST_ID" \
  --data-binary @"$TMP_DIR/payload.json")"
[[ "$code" == 200 ]] || { cat "$TMP_DIR/gist.json" >&2; die "Gist 更新失败，HTTP $code"; }

OWNER="$(jq -r '.owner.login // empty' "$TMP_DIR/gist.json")"
[[ -n "$OWNER" ]] || die "GitHub 返回中缺少 Gist 所有者"

echo "订阅已更新，不需要重启 Xray 或 sing-box。"
echo "Hysteria2 已删除 insecure/allowInsecure，改用 pinSHA256：$CERT_SHA"
echo "Base64 订阅：https://gist.githubusercontent.com/$OWNER/$GIST_ID/raw/sub.txt"
echo "明文订阅：https://gist.githubusercontent.com/$OWNER/$GIST_ID/raw/sub_plain.txt"
