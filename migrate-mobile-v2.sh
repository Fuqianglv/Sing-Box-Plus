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
TMP_DIR="$(mktemp -d /tmp/migrate-mobile-v2.XXXXXX)"
BACKUP_DIR="/root/hybrid-proxy-backups/mobile-v2-$(date +%Y%m%d-%H%M%S)"
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
required=(SS2022_PASSWORD HY2_PASSWORD TUIC_UUID TUIC_PASSWORD REALITY_SNI)
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

log "3. 生成 4 TCP + 2 UDP 节点"
ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
TROJAN_PASSWORD="${TROJAN_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
if [[ -n "${VLESS_UUID:-}" ]]; then
  VLESS_UUID="$VLESS_UUID"
elif command -v uuidgen >/dev/null 2>&1; then
  VLESS_UUID="$(uuidgen | tr 'A-F' 'a-f')"
else
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
fi

tcp_free(){ ! ss -H -lnt 2>/dev/null | awk -v p=":$1" '$4 ~ p"$"{found=1} END{exit !found}'; }
udp_free(){ ! ss -H -lnu 2>/dev/null | awk -v p=":$1" '$4 ~ p"$"{found=1} END{exit !found}'; }
declare -A USED_TCP=()
declare -A USED_UDP=()

choose_tcp_port(){
  local var="$1" preferred="$2" fallback="$3" p
  for p in "$preferred" "$fallback"; do
    if [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535)) && [[ -z "${USED_TCP[$p]:-}" ]] && tcp_free "$p"; then
      printf -v "$var" '%s' "$p"
      USED_TCP[$p]=1
      return
    fi
  done
  while :; do
    p=$((20000 + RANDOM % 40000))
    [[ -z "${USED_TCP[$p]:-}" ]] && tcp_free "$p" && { printf -v "$var" '%s' "$p"; USED_TCP[$p]=1; return; }
  done
}

choose_udp_port(){
  local var="$1" preferred="$2" fallback="$3" p
  for p in "$preferred" "$fallback"; do
    if [[ "$p" =~ ^[0-9]+$ ]] && ((p >= 1 && p <= 65535)) && [[ -z "${USED_UDP[$p]:-}" ]] && udp_free "$p"; then
      printf -v "$var" '%s' "$p"
      USED_UDP[$p]=1
      return
    fi
  done
  while :; do
    p=$((20000 + RANDOM % 40000))
    [[ -z "${USED_UDP[$p]:-}" ]] && udp_free "$p" && { printf -v "$var" '%s' "$p"; USED_UDP[$p]=1; return; }
  done
}

# TCP 与 UDP 端口空间独立，因此 TCP/443 与 UDP/443 可以同时存在。
choose_tcp_port ANYTLS_PORT 443 9443
choose_tcp_port TROJAN_PORT 8443 9444
choose_tcp_port VLESS_PORT 2053 9445
choose_tcp_port SS2022_TCP_PORT 2083 9446
choose_udp_port HY2_PORT_NEW 443 9443
choose_udp_port TUIC_PORT_NEW 8443 9444

cat >>"$CREDS_FILE" <<EOF_CREDS
ANYTLS_PASSWORD=$(printf %q "$ANYTLS_PASSWORD")
TROJAN_PASSWORD=$(printf %q "$TROJAN_PASSWORD")
VLESS_UUID=$(printf %q "$VLESS_UUID")
EOF_CREDS
awk -F= '!seen[$1]++{order[++n]=$1} {line[$1]=$0} END{for(i=1;i<=n;i++) print line[order[i]]}' "$CREDS_FILE" >"$TMP_DIR/creds.env"
install -m 600 "$TMP_DIR/creds.env" "$CREDS_FILE"

cat >>"$PORTS_FILE" <<EOF_PORTS
ANYTLS_PORT=$ANYTLS_PORT
TROJAN_PORT=$TROJAN_PORT
VLESS_PORT=$VLESS_PORT
SS2022_TCP_PORT=$SS2022_TCP_PORT
HY2_PORT=$HY2_PORT_NEW
TUIC_PORT=$TUIC_PORT_NEW
EOF_PORTS
awk -F= '!seen[$1]++{order[++n]=$1} {line[$1]=$0} END{for(i=1;i<=n;i++) print line[order[i]]}' "$PORTS_FILE" >"$TMP_DIR/ports.env"
install -m 600 "$TMP_DIR/ports.env" "$PORTS_FILE"

log "4. 重建 sing-box 配置"
mkdir -p "$SB_DIR" "$SB_DATA"
jq -n \
  --arg anyp "$ANYTLS_PASSWORD" \
  --arg trp "$TROJAN_PASSWORD" \
  --arg vu "$VLESS_UUID" \
  --arg ss22 "$SS2022_PASSWORD" \
  --arg hy2 "$HY2_PASSWORD" \
  --arg tu "$TUIC_UUID" --arg tup "$TUIC_PASSWORD" \
  --arg crt "$CERT_FILE" --arg key "$KEY_FILE" \
  --argjson ap "$ANYTLS_PORT" --argjson tr "$TROJAN_PORT" \
  --argjson vp "$VLESS_PORT" --argjson sp "$SS2022_TCP_PORT" \
  --argjson hp "$HY2_PORT_NEW" --argjson tp "$TUIC_PORT_NEW" '
{
  log:{level:"warn",timestamp:true},
  inbounds:[
    {type:"anytls",tag:"01-5g-anytls",listen:"0.0.0.0",listen_port:$ap,users:[{name:"main",password:$anyp}],tls:{enabled:true,certificate_path:$crt,key_path:$key}},
    {type:"trojan",tag:"02-5g-trojan",listen:"0.0.0.0",listen_port:$tr,users:[{name:"main",password:$trp}],tls:{enabled:true,certificate_path:$crt,key_path:$key}},
    {type:"vless",tag:"03-5g-vless",listen:"0.0.0.0",listen_port:$vp,users:[{name:"main",uuid:$vu}],tls:{enabled:true,certificate_path:$crt,key_path:$key}},
    {type:"shadowsocks",tag:"04-5g-ss2022",listen:"0.0.0.0",listen_port:$sp,network:"tcp",method:"2022-blake3-aes-256-gcm",password:$ss22},
    {type:"hysteria2",tag:"05-wifi-hy2",listen:"0.0.0.0",listen_port:$hp,users:[{name:"hy2",password:$hy2}],tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}},
    {type:"tuic",tag:"06-wifi-tuic",listen:"0.0.0.0",listen_port:$tp,users:[{uuid:$tu,password:$tup}],congestion_control:"bbr",tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}}
  ],
  outbounds:[{type:"direct",tag:"direct"},{type:"block",tag:"block"}],
  route:{final:"direct"}
}' >"$SB_CONFIG"
"$SB_BIN" check -c "$SB_CONFIG"

cat >"$SB_SERVICE" <<EOF_SERVICE
[Unit]
Description=sing-box Mobile-First Multi-Protocol Service
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
EOF_SERVICE

log "5. 更新防火墙并启动 sing-box"
cat >"$FW_SCRIPT" <<EOF_FW
#!/usr/bin/env bash
set -u
TCP_PORTS=($ANYTLS_PORT $TROJAN_PORT $VLESS_PORT $SS2022_TCP_PORT)
UDP_PORTS=($HY2_PORT_NEW $TUIC_PORT_NEW)
for p in "\${TCP_PORTS[@]}"; do
  iptables -C INPUT -p tcp --dport "\$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "\$p" -j ACCEPT
  command -v ip6tables >/dev/null 2>&1 && { ip6tables -C INPUT -p tcp --dport "\$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "\$p" -j ACCEPT; }
done
for p in "\${UDP_PORTS[@]}"; do
  iptables -C INPUT -p udp --dport "\$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "\$p" -j ACCEPT
  command -v ip6tables >/dev/null 2>&1 && { ip6tables -C INPUT -p udp --dport "\$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "\$p" -j ACCEPT; }
done
EOF_FW
chmod 700 "$FW_SCRIPT"

cat >"$FW_SERVICE" <<EOF_FW_SERVICE
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
EOF_FW_SERVICE

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

wait_tcp(){
  local p="$1" i
  for i in $(seq 1 30); do
    ss -H -lnt | awk -v x=":$p" '$4 ~ x"$"{ok=1} END{exit !ok}' && { echo "TCP $p 已监听"; return; }
    sleep 1
  done
  show_logs
  die "TCP $p 未监听"
}
wait_udp(){
  local p="$1" i
  for i in $(seq 1 30); do
    ss -H -lnu | awk -v x=":$p" '$4 ~ x"$"{ok=1} END{exit !ok}' && { echo "UDP $p 已监听"; return; }
    sleep 1
  done
  show_logs
  die "UDP $p 未监听"
}
for p in "$ANYTLS_PORT" "$TROJAN_PORT" "$VLESS_PORT" "$SS2022_TCP_PORT"; do wait_tcp "$p"; done
for p in "$HY2_PORT_NEW" "$TUIC_PORT_NEW"; do wait_udp "$p"; done

log "6. 生成 6 节点订阅并更新 Gist"
SERVER_IP="$(curl -4fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || die "未检测到公网 IPv4"
CERT_SHA="$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr -d '\r\n')"
[[ "$CERT_SHA" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] || die "证书 SHA-256 指纹格式异常"

urlenc(){
  local s="$1" out="" c i
  for ((i=0;i<${#s};i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  printf '%s' "$out"
}
b64url(){ base64 -w 0 2>/dev/null | tr '+/' '-_' | tr -d '='; }

ANY_AUTH="$(urlenc "$ANYTLS_PASSWORD")"
TROJAN_AUTH="$(urlenc "$TROJAN_PASSWORD")"
SS2022_AUTH="$(printf '%s' "2022-blake3-aes-256-gcm:${SS2022_PASSWORD}" | b64url)"
HY2_AUTH="$(urlenc "$HY2_PASSWORD")"
TUIC_PASS="$(urlenc "$TUIC_PASSWORD")"
CERT_SHA_ENC="$(urlenc "$CERT_SHA")"
SNI_ENC="$(urlenc "$REALITY_SNI")"

{
  echo "anytls://${ANY_AUTH}@${SERVER_IP}:${ANYTLS_PORT}?security=tls&sni=${SNI_ENC}&insecure=1#01-5G-AnyTLS-${ANYTLS_PORT}"
  echo "trojan://${TROJAN_AUTH}@${SERVER_IP}:${TROJAN_PORT}?security=tls&sni=${SNI_ENC}&allowInsecure=1#02-5G-Trojan-${TROJAN_PORT}"
  echo "vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&security=tls&type=tcp&sni=${SNI_ENC}&allowInsecure=1#03-5G-VLESS-TLS-${VLESS_PORT}"
  echo "ss://${SS2022_AUTH}@${SERVER_IP}:${SS2022_TCP_PORT}#04-5G-SS2022-TCP-${SS2022_TCP_PORT}"
  echo "hysteria2://${HY2_AUTH}@${SERVER_IP}:${HY2_PORT_NEW}/?sni=${SNI_ENC}&pinSHA256=${CERT_SHA_ENC}#05-WIFI-HY2-${HY2_PORT_NEW}"
  echo "tuic://${TUIC_UUID}:${TUIC_PASS}@${SERVER_IP}:${TUIC_PORT_NEW}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=1&sni=${SNI_ENC}#06-WIFI-TUIC-${TUIC_PORT_NEW}"
} >"$SUB_PLAIN"
[[ "$(wc -l <"$SUB_PLAIN")" -eq 6 ]] || die "订阅节点数量错误"
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

verify(){
  local f="$1" u="$2" name="$3" a b i
  a="$(sha256sum "$f" | awk '{print $1}')"
  for i in 1 2 3 4 5; do
    curl -fLsS -H 'Cache-Control: no-cache' "$u?x=$(date +%s%N)" -o "$TMP_DIR/remote" || true
    b="$(sha256sum "$TMP_DIR/remote" 2>/dev/null | awk '{print $1}' || true)"
    [[ "$a" == "$b" ]] && { echo "$name 校验通过"; return; }
    sleep "$i"
  done
  die "$name 远程校验失败"
}
verify "$SUB_PLAIN" "$RAW_PLAIN" 明文订阅
verify "$SUB_B64" "$RAW_B64" Base64订阅

ROLLBACK=0
log "7. 迁移完成"
cat "$SUB_PLAIN"
echo
echo "节点结构：4 TCP + 2 UDP"
echo "5G/TCP：AnyTLS=$ANYTLS_PORT, Trojan=$TROJAN_PORT, VLESS-TLS=$VLESS_PORT, SS2022=$SS2022_TCP_PORT"
echo "Wi-Fi/UDP：Hysteria2=$HY2_PORT_NEW, TUIC=$TUIC_PORT_NEW"
echo "xray.service 已停用；最终节点全部由 sing-box 提供。"
echo "如 VPS 有云防火墙，请放行 TCP：$ANYTLS_PORT,$TROJAN_PORT,$VLESS_PORT,$SS2022_TCP_PORT"
echo "如 VPS 有云防火墙，请放行 UDP：$HY2_PORT_NEW,$TUIC_PORT_NEW"
echo "Base64 订阅：https://gist.githubusercontent.com/$GIST_OWNER/$GIST_ID/raw/sub.txt"
echo "备份目录：$BACKUP_DIR"
