#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEFAULT_GIST_ID="85a7d7b63d151e78558a4737aca3ce02"
GH_TOKEN="${GH_TOKEN:-${1:-}}"
GIST_ID="${GIST_ID:-${2:-$DEFAULT_GIST_ID}}"

ROOT_DIR="/opt/hybrid-proxy"
CREDS_FILE="$ROOT_DIR/creds.env"
PORTS_FILE="$ROOT_DIR/ports.env"
SUB_PLAIN="$ROOT_DIR/sub_plain.txt"
SUB_B64="$ROOT_DIR/sub.txt"
CERT_FILE="$ROOT_DIR/cert/fullchain.pem"
KEY_FILE="$ROOT_DIR/cert/private.key"
SB_BIN="/usr/local/bin/sing-box"
SB_DIR="/opt/sing-box"
SB_CONFIG="$SB_DIR/config.json"
SB_DATA="$SB_DIR/data"
SB_SERVICE="/etc/systemd/system/sing-box.service"
XRAY_SERVICE="/etc/systemd/system/xray.service"
FW_SCRIPT="/usr/local/sbin/hybrid-proxy-firewall"
FW_SERVICE="/etc/systemd/system/hybrid-proxy-firewall.service"
TMP_DIR="$(mktemp -d /tmp/migrate-anytls.XXXXXX)"
BACKUP_DIR="/root/hybrid-proxy-backups/anytls-$(date +%Y%m%d-%H%M%S)"
ROLLBACK=0
OLD_SB_ACTIVE=0
OLD_SB_ENABLED=0
OLD_XRAY_ACTIVE=0
OLD_XRAY_ENABLED=0

log(){ printf '\n========== %s ==========\n' "$*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

show_logs(){
  systemctl --no-pager --full status sing-box.service >&2 || true
  journalctl -u sing-box.service -n 100 --no-pager >&2 || true
}

cleanup(){
  rc=$?
  set +e
  unset GH_TOKEN
  if ((rc != 0 && ROLLBACK)); then
    echo "迁移失败，正在恢复原配置……" >&2
    systemctl stop sing-box.service xray.service hybrid-proxy-firewall.service >/dev/null 2>&1 || true
    rm -rf "$ROOT_DIR" "$SB_DIR"
    rm -f "$SB_SERVICE" "$XRAY_SERVICE" "$FW_SCRIPT" "$FW_SERVICE"
    if [[ -s "$BACKUP_DIR/files.tar.gz" ]]; then
      tar -C / -xzpf "$BACKUP_DIR/files.tar.gz"
    fi
    [[ -s "$BACKUP_DIR/iptables.v4" ]] && iptables-restore <"$BACKUP_DIR/iptables.v4" || true
    command -v ip6tables-restore >/dev/null 2>&1 && [[ -s "$BACKUP_DIR/iptables.v6" ]] && ip6tables-restore <"$BACKUP_DIR/iptables.v6" || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    ((OLD_SB_ENABLED)) && systemctl enable sing-box.service >/dev/null 2>&1 || true
    ((OLD_XRAY_ENABLED)) && systemctl enable xray.service >/dev/null 2>&1 || true
    ((OLD_SB_ACTIVE)) && systemctl restart sing-box.service >/dev/null 2>&1 || true
    ((OLD_XRAY_ACTIVE)) && systemctl restart xray.service >/dev/null 2>&1 || true
    echo "原配置已恢复；备份目录：$BACKUP_DIR" >&2
  fi
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 执行"
[[ -n "$GH_TOKEN" ]] || die "命令后必须提供 GH_TOKEN"
[[ "$GIST_ID" =~ ^[0-9a-fA-F]{20,64}$ ]] || die "GIST_ID 格式不正确"
for f in "$CREDS_FILE" "$PORTS_FILE" "$CERT_FILE" "$KEY_FILE" "$SB_CONFIG"; do
  [[ -s "$f" ]] || die "缺少文件：$f"
done
[[ -x "$SB_BIN" ]] || die "未找到 sing-box"

log "1. 校验 Token 与现有配置"
code="$(curl -sS -o "$TMP_DIR/gist.json" -w '%{http_code}' \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "https://api.github.com/gists/$GIST_ID")"
[[ "$code" == 200 ]] || { cat "$TMP_DIR/gist.json" >&2; die "读取 Gist 失败，HTTP $code"; }
GIST_OWNER="$(jq -r '.owner.login // empty' "$TMP_DIR/gist.json")"
[[ -n "$GIST_OWNER" ]] || die "无法取得 Gist 所有者"

# shellcheck disable=SC1090
source "$CREDS_FILE"
# shellcheck disable=SC1090
source "$PORTS_FILE"
required=(SS_AES_PASSWORD SS2022_PASSWORD HY2_PASSWORD HY2_OBFS_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_SNI SS_AES_PORT SS2022_PORT HY2_PORT HY2_OBFS_PORT TUIC_PORT XRAY_VISION_PORT XRAY_PLAIN_PORT)
for v in "${required[@]}"; do
  [[ -n "${!v:-}" ]] || die "变量 $v 为空"
done

log "2. 备份并停止旧服务"
mkdir -p "$BACKUP_DIR"
systemctl is-active --quiet sing-box.service && OLD_SB_ACTIVE=1 || true
systemctl is-enabled --quiet sing-box.service 2>/dev/null && OLD_SB_ENABLED=1 || true
systemctl is-active --quiet xray.service && OLD_XRAY_ACTIVE=1 || true
systemctl is-enabled --quiet xray.service 2>/dev/null && OLD_XRAY_ENABLED=1 || true
items=()
for path in \
  opt/hybrid-proxy opt/sing-box usr/local/etc/xray \
  etc/systemd/system/sing-box.service etc/systemd/system/xray.service \
  usr/local/sbin/hybrid-proxy-firewall etc/systemd/system/hybrid-proxy-firewall.service; do
  [[ -e "/$path" ]] && items+=("$path")
done
((${#items[@]})) && tar -C / -czpf "$BACKUP_DIR/files.tar.gz" "${items[@]}"
iptables-save >"$BACKUP_DIR/iptables.v4" 2>/dev/null || true
command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save >"$BACKUP_DIR/iptables.v6" 2>/dev/null || true
ROLLBACK=1
systemctl stop xray.service sing-box.service >/dev/null 2>&1 || true

log "3. 生成三个 AnyTLS TCP 入口"
ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"

tcp_free(){ ! ss -H -lnt 2>/dev/null | awk -v p=":$1" '$4 ~ p"$"{found=1} END{exit !found}'; }
declare -A USED=()
choose_port(){
  local var="$1" preferred="$2" fallback="$3" p
  for p in "$preferred" "$fallback"; do
    if [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535)) && [[ -z "${USED[$p]:-}" ]] && tcp_free "$p"; then
      printf -v "$var" '%s' "$p"
      USED[$p]=1
      return
    fi
  done
  while :; do
    p=$((20000 + RANDOM % 40000))
    [[ -z "${USED[$p]:-}" ]] && tcp_free "$p" && { printf -v "$var" '%s' "$p"; USED[$p]=1; return; }
  done
}
choose_port ANYTLS_PRIMARY_PORT "${ANYTLS_PRIMARY_PORT:-443}" 8443
choose_port ANYTLS_BACKUP1_PORT "${ANYTLS_BACKUP1_PORT:-$XRAY_VISION_PORT}" "$XRAY_VISION_PORT"
choose_port ANYTLS_BACKUP2_PORT "${ANYTLS_BACKUP2_PORT:-$XRAY_PLAIN_PORT}" "$XRAY_PLAIN_PORT"

cat >>"$CREDS_FILE" <<EOF
ANYTLS_PASSWORD=$(printf %q "$ANYTLS_PASSWORD")
EOF
awk -F= '!seen[$1]++{order[++n]=$1} {line[$1]=$0} END{for(i=1;i<=n;i++) print line[order[i]]}' "$CREDS_FILE" >"$TMP_DIR/creds.env"
install -m 600 "$TMP_DIR/creds.env" "$CREDS_FILE"

cat >>"$PORTS_FILE" <<EOF
ANYTLS_PRIMARY_PORT=$ANYTLS_PRIMARY_PORT
ANYTLS_BACKUP1_PORT=$ANYTLS_BACKUP1_PORT
ANYTLS_BACKUP2_PORT=$ANYTLS_BACKUP2_PORT
EOF
awk -F= '!seen[$1]++{order[++n]=$1} {line[$1]=$0} END{for(i=1;i<=n;i++) print line[order[i]]}' "$PORTS_FILE" >"$TMP_DIR/ports.env"
install -m 600 "$TMP_DIR/ports.env" "$PORTS_FILE"

log "4. 重建 sing-box 配置"
mkdir -p "$SB_DIR" "$SB_DATA"
jq -n \
  --arg anyp "$ANYTLS_PASSWORD" \
  --arg ssa "$SS_AES_PASSWORD" --arg ss22 "$SS2022_PASSWORD" \
  --arg hy2 "$HY2_PASSWORD" --arg hy2o "$HY2_OBFS_PASSWORD" \
  --arg tu "$TUIC_UUID" --arg tup "$TUIC_PASSWORD" \
  --arg crt "$CERT_FILE" --arg key "$KEY_FILE" \
  --argjson a1 "$ANYTLS_PRIMARY_PORT" --argjson a2 "$ANYTLS_BACKUP1_PORT" --argjson a3 "$ANYTLS_BACKUP2_PORT" \
  --argjson s1 "$SS_AES_PORT" --argjson s2 "$SS2022_PORT" \
  --argjson h1 "$HY2_PORT" --argjson h2 "$HY2_OBFS_PORT" --argjson tp "$TUIC_PORT" '
{
  log:{level:"warn",timestamp:true},
  inbounds:[
    {type:"anytls",tag:"anytls-primary",listen:"0.0.0.0",listen_port:$a1,users:[{name:"main",password:$anyp}],tls:{enabled:true,certificate_path:$crt,key_path:$key}},
    {type:"anytls",tag:"anytls-backup-1",listen:"0.0.0.0",listen_port:$a2,users:[{name:"main",password:$anyp}],tls:{enabled:true,certificate_path:$crt,key_path:$key}},
    {type:"anytls",tag:"anytls-backup-2",listen:"0.0.0.0",listen_port:$a3,users:[{name:"main",password:$anyp}],tls:{enabled:true,certificate_path:$crt,key_path:$key}},
    {type:"shadowsocks",tag:"ss-aes",listen:"0.0.0.0",listen_port:$s1,method:"aes-256-gcm",password:$ssa},
    {type:"shadowsocks",tag:"ss2022",listen:"0.0.0.0",listen_port:$s2,method:"2022-blake3-aes-256-gcm",password:$ss22},
    {type:"hysteria2",tag:"hy2",listen:"0.0.0.0",listen_port:$h1,users:[{name:"hy2",password:$hy2}],tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}},
    {type:"hysteria2",tag:"hy2-obfs",listen:"0.0.0.0",listen_port:$h2,users:[{name:"hy2",password:$hy2}],obfs:{type:"salamander",password:$hy2o},tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}},
    {type:"tuic",tag:"tuic",listen:"0.0.0.0",listen_port:$tp,users:[{uuid:$tu,password:$tup}],congestion_control:"bbr",tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}}
  ],
  outbounds:[{type:"direct",tag:"direct"},{type:"block",tag:"block"}],
  route:{final:"direct"}
}' >"$SB_CONFIG"
"$SB_BIN" check -c "$SB_CONFIG"

cat >"$SB_SERVICE" <<EOF
[Unit]
Description=sing-box Multi-Protocol Service
After=network-online.target hybrid-proxy-firewall.service
Wants=network-online.target hybrid-proxy-firewall.service

[Service]
Type=simple
ExecStart=$SB_BIN run -c $SB_CONFIG -D $SB_DATA
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

log "5. 更新防火墙并启动 sing-box"
cat >"$FW_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
TCP_PORTS=($ANYTLS_PRIMARY_PORT $ANYTLS_BACKUP1_PORT $ANYTLS_BACKUP2_PORT $SS_AES_PORT $SS2022_PORT)
UDP_PORTS=($SS_AES_PORT $SS2022_PORT $HY2_PORT $HY2_OBFS_PORT $TUIC_PORT)
for p in "\${TCP_PORTS[@]}"; do
  iptables -C INPUT -p tcp --dport "\$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "\$p" -j ACCEPT
  command -v ip6tables >/dev/null 2>&1 && { ip6tables -C INPUT -p tcp --dport "\$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "\$p" -j ACCEPT; }
done
for p in "\${UDP_PORTS[@]}"; do
  iptables -C INPUT -p udp --dport "\$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "\$p" -j ACCEPT
  command -v ip6tables >/dev/null 2>&1 && { ip6tables -C INPUT -p udp --dport "\$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "\$p" -j ACCEPT; }
done
EOF
chmod 700 "$FW_SCRIPT"
cat >"$FW_SERVICE" <<EOF
[Unit]
Description=Hybrid Proxy Firewall Rules
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$FW_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable --now xray.service >/dev/null 2>&1 || true
systemctl enable hybrid-proxy-firewall.service sing-box.service >/dev/null
systemctl restart hybrid-proxy-firewall.service
systemctl reset-failed sing-box.service >/dev/null 2>&1 || true
systemctl restart sing-box.service

for i in $(seq 1 30); do
  systemctl is-active --quiet sing-box.service && break
  systemctl is-failed --quiet sing-box.service && { show_logs; die "sing-box 启动失败"; }
  sleep 1
done
systemctl is-active --quiet sing-box.service || { show_logs; die "sing-box 未进入 active 状态"; }

wait_tcp(){ local p="$1" i; for i in $(seq 1 30); do ss -H -lnt | awk -v x=":$p" '$4 ~ x"$"{ok=1} END{exit !ok}' && { echo "TCP $p 已监听"; return; }; sleep 1; done; show_logs; die "TCP $p 未监听"; }
wait_udp(){ local p="$1" i; for i in $(seq 1 30); do ss -H -lnu | awk -v x=":$p" '$4 ~ x"$"{ok=1} END{exit !ok}' && { echo "UDP $p 已监听"; return; }; sleep 1; done; show_logs; die "UDP $p 未监听"; }
for p in "$ANYTLS_PRIMARY_PORT" "$ANYTLS_BACKUP1_PORT" "$ANYTLS_BACKUP2_PORT" "$SS_AES_PORT" "$SS2022_PORT"; do wait_tcp "$p"; done
for p in "$SS_AES_PORT" "$SS2022_PORT" "$HY2_PORT" "$HY2_OBFS_PORT" "$TUIC_PORT"; do wait_udp "$p"; done

log "6. 生成 8 节点订阅并更新 Gist"
SERVER_IP="$(curl -4fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || die "未检测到公网 IPv4"
CERT_SHA="$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr -d '\r\n')"
[[ "$CERT_SHA" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || die "证书 SHA-256 指纹格式异常"

urlenc(){ local s="$1" out="" c i; for ((i=0;i<${#s};i++)); do c="${s:i:1}"; case "$c" in [a-zA-Z0-9.~_-]) out+="$c" ;; *) printf -v out '%s%%%02X' "$out" "'$c" ;; esac; done; printf '%s' "$out"; }
b64url(){ base64 -w 0 2>/dev/null | tr '+/' '-_' | tr -d '='; }
ANY_AUTH="$(urlenc "$ANYTLS_PASSWORD")"
HY2_AUTH="$(urlenc "$HY2_PASSWORD")"
HY2_OBFS_AUTH="$(urlenc "$HY2_OBFS_PASSWORD")"
TUIC_PASS="$(urlenc "$TUIC_PASSWORD")"
CERT_SHA_ENC="$(urlenc "$CERT_SHA")"

{
  echo "anytls://${ANY_AUTH}@${SERVER_IP}:${ANYTLS_PRIMARY_PORT}?security=tls&sni=${REALITY_SNI}&insecure=1#anytls-primary-${ANYTLS_PRIMARY_PORT}"
  echo "anytls://${ANY_AUTH}@${SERVER_IP}:${ANYTLS_BACKUP1_PORT}?security=tls&sni=${REALITY_SNI}&insecure=1#anytls-backup-${ANYTLS_BACKUP1_PORT}"
  echo "anytls://${ANY_AUTH}@${SERVER_IP}:${ANYTLS_BACKUP2_PORT}?security=tls&sni=${REALITY_SNI}&insecure=1#anytls-backup-${ANYTLS_BACKUP2_PORT}"
  echo "ss://$(printf '%s' "aes-256-gcm:${SS_AES_PASSWORD}" | b64url)@${SERVER_IP}:${SS_AES_PORT}#ss-aes256"
  echo "ss://$(printf '%s' "2022-blake3-aes-256-gcm:${SS2022_PASSWORD}" | b64url)@${SERVER_IP}:${SS2022_PORT}#ss2022"
  echo "hysteria2://${HY2_AUTH}@${SERVER_IP}:${HY2_PORT}/?sni=${REALITY_SNI}&pinSHA256=${CERT_SHA_ENC}#hysteria2"
  echo "hysteria2://${HY2_AUTH}@${SERVER_IP}:${HY2_OBFS_PORT}/?sni=${REALITY_SNI}&pinSHA256=${CERT_SHA_ENC}&obfs=salamander&obfs-password=${HY2_OBFS_AUTH}#hysteria2-obfs"
  echo "tuic://${TUIC_UUID}:${TUIC_PASS}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=1&sni=${REALITY_SNI}#tuic-v5"
} >"$SUB_PLAIN"
[[ "$(wc -l <"$SUB_PLAIN")" -eq 8 ]] || die "订阅节点数量错误"
base64 -w 0 "$SUB_PLAIN" >"$SUB_B64"
chmod 600 "$SUB_PLAIN" "$SUB_B64"

jq -n --rawfile plain "$SUB_PLAIN" --rawfile sub "$SUB_B64" '{files:{"sub_plain.txt":{content:$plain},"sub.txt":{content:$sub}}}' >"$TMP_DIR/payload.json"
code="$(curl -sS -o "$TMP_DIR/gist-new.json" -w '%{http_code}' -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H 'Content-Type: application/json' \
  "https://api.github.com/gists/$GIST_ID" --data-binary @"$TMP_DIR/payload.json")"
[[ "$code" == 200 ]] || { cat "$TMP_DIR/gist-new.json" >&2; die "Gist 更新失败，HTTP $code"; }
RAW_PLAIN="$(jq -r '.files["sub_plain.txt"].raw_url // empty' "$TMP_DIR/gist-new.json")"
RAW_B64="$(jq -r '.files["sub.txt"].raw_url // empty' "$TMP_DIR/gist-new.json")"
verify(){ local f="$1" u="$2" name="$3" a b i; a="$(sha256sum "$f"|awk '{print $1}')"; for i in 1 2 3 4 5; do curl -fLsS -H 'Cache-Control: no-cache' "$u?x=$(date +%s%N)" -o "$TMP_DIR/remote" || true; b="$(sha256sum "$TMP_DIR/remote" 2>/dev/null|awk '{print $1}'||true)"; [[ "$a" == "$b" ]] && { echo "$name 校验通过"; return; }; sleep "$i"; done; die "$name 远程校验失败"; }
verify "$SUB_PLAIN" "$RAW_PLAIN" 明文订阅
verify "$SUB_B64" "$RAW_B64" Base64订阅

ROLLBACK=0
log "7. 迁移完成"
cat "$SUB_PLAIN"
echo
echo "已删除订阅中的两个 VLESS Reality；xray.service 已停用。"
echo "AnyTLS TCP：$ANYTLS_PRIMARY_PORT,$ANYTLS_BACKUP1_PORT,$ANYTLS_BACKUP2_PORT"
echo "其他 TCP：$SS_AES_PORT,$SS2022_PORT"
echo "UDP：$SS_AES_PORT,$SS2022_PORT,$HY2_PORT,$HY2_OBFS_PORT,$TUIC_PORT"
echo "请在 Vultr 云防火墙放行 TCP：$ANYTLS_PRIMARY_PORT,$ANYTLS_BACKUP1_PORT,$ANYTLS_BACKUP2_PORT"
echo "Base64 订阅：https://gist.githubusercontent.com/$GIST_OWNER/$GIST_ID/raw/sub.txt"
echo "备份目录：$BACKUP_DIR"
