#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DEFAULT_GIST_ID="85a7d7b63d151e78558a4737aca3ce02"
GH_TOKEN="${GH_TOKEN:-}"
GIST_ID="${GIST_ID:-$DEFAULT_GIST_ID}"
ROTATE=0
UPDATE_CORE=0

ROOT_DIR="/opt/hybrid-proxy"
CREDS_FILE="$ROOT_DIR/creds.env"
PORTS_FILE="$ROOT_DIR/ports.env"
SUB_PLAIN="$ROOT_DIR/sub_plain.txt"
SUB_B64="$ROOT_DIR/sub.txt"
CERT_DIR="$ROOT_DIR/cert"

XRAY_BIN="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_SERVICE="/etc/systemd/system/xray.service"

SB_BIN="/usr/local/bin/sing-box"
SB_DIR="/opt/sing-box"
SB_CONFIG="$SB_DIR/config.json"
SB_DATA="$SB_DIR/data"
SB_SERVICE="/etc/systemd/system/sing-box.service"

FW_SCRIPT="/usr/local/sbin/hybrid-proxy-firewall"
FW_SERVICE="/etc/systemd/system/hybrid-proxy-firewall.service"

TMP_DIR="$(mktemp -d /tmp/hybrid-proxy.XXXXXX)"
BACKUP_DIR="/root/hybrid-proxy-backups/$(date +%Y%m%d-%H%M%S)"
ROLLBACK=0
OLD_XRAY_ACTIVE=0
OLD_SB_ACTIVE=0
OLD_XRAY_ENABLED=0
OLD_SB_ENABLED=0

log(){ printf '\n========== %s ==========\n' "$*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

usage(){
  cat <<EOF
用法：
  bash <(curl -fsSL URL) GH_TOKEN [GIST_ID] [--rotate] [--update-core]

默认 Gist ID：$DEFAULT_GIST_ID
默认保留端口、UUID、密码和密钥，并且每次强制更新 Gist 订阅。
--rotate       重新生成所有凭据和端口
--update-core  即使已安装，也重新下载最新版 Xray-core 和 sing-box
EOF
}

if [[ -n "${1:-}" && "${1:-}" != --* ]]; then GH_TOKEN="$1"; shift; fi
if [[ -n "${1:-}" && "${1:-}" != --* ]]; then GIST_ID="$1"; shift; fi
while (($#)); do
  case "$1" in
    --rotate) ROTATE=1 ;;
    --update-core) UPDATE_CORE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

cleanup(){
  rc=$?
  set +e
  unset GH_TOKEN
  if ((rc != 0 && ROLLBACK)); then
    echo "部署失败，正在恢复旧服务……" >&2
    systemctl stop xray.service sing-box.service hybrid-proxy-firewall.service >/dev/null 2>&1 || true
    rm -rf "$ROOT_DIR" "$XRAY_DIR" "$SB_DIR"
    rm -f "$XRAY_BIN" "$SB_BIN" "$XRAY_SERVICE" "$SB_SERVICE" "$FW_SCRIPT" "$FW_SERVICE" /etc/sysctl.d/99-hybrid-proxy-bbr.conf
    if [[ -s "$BACKUP_DIR/files.tar.gz" ]]; then
      tar -C / -xzpf "$BACKUP_DIR/files.tar.gz"
    fi
    [[ -s "$BACKUP_DIR/iptables.v4" ]] && iptables-restore <"$BACKUP_DIR/iptables.v4" || true
    command -v ip6tables-restore >/dev/null 2>&1 && [[ -s "$BACKUP_DIR/iptables.v6" ]] && ip6tables-restore <"$BACKUP_DIR/iptables.v6" || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    ((OLD_XRAY_ENABLED)) && systemctl enable xray.service >/dev/null 2>&1 || true
    ((OLD_SB_ENABLED)) && systemctl enable sing-box.service >/dev/null 2>&1 || true
    ((OLD_XRAY_ACTIVE)) && systemctl restart xray.service >/dev/null 2>&1 || true
    ((OLD_SB_ACTIVE)) && systemctl restart sing-box.service >/dev/null 2>&1 || true
    echo "旧配置已恢复；备份目录：$BACKUP_DIR" >&2
  fi
  rm -rf "$TMP_DIR"
  exit "$rc"
}
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 执行"
[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
source /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in debian:*|ubuntu:*|*:debian*) ;; *) die "仅支持 Debian/Ubuntu" ;; esac
[[ "$(ps -p 1 -o comm= | xargs)" == systemd ]] || die "需要 systemd"
case "$(uname -m)" in x86_64|amd64|aarch64|arm64) ;; *) die "仅支持 amd64/arm64" ;; esac
[[ -n "$GH_TOKEN" ]] || die "命令后必须提供 GH_TOKEN"
[[ "$GIST_ID" =~ ^[0-9a-fA-F]{20,64}$ ]] || die "GIST_ID 格式不正确"

log "1. 安装基础依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl jq openssl tar unzip xz-utils iproute2 iptables uuid-runtime util-linux
exec 9>/run/hybrid-proxy.lock
flock -n 9 || die "已有部署任务正在运行"

log "2. 校验 GitHub Token 和 Gist"
code="$(curl -sS -o "$TMP_DIR/gist-old.json" -w '%{http_code}' \
  -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' "https://api.github.com/gists/$GIST_ID")"
[[ "$code" == 200 ]] || { cat "$TMP_DIR/gist-old.json"; die "读取 Gist 失败，HTTP $code"; }
code="$(curl -sS -o "$TMP_DIR/user.json" -w '%{http_code}' \
  -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' https://api.github.com/user)"
[[ "$code" == 200 ]] || { cat "$TMP_DIR/user.json"; die "Token 无效，HTTP $code"; }
GIST_OWNER="$(jq -r '.owner.login // empty' "$TMP_DIR/gist-old.json")"
TOKEN_OWNER="$(jq -r '.login // empty' "$TMP_DIR/user.json")"
[[ -n "$GIST_OWNER" && "$GIST_OWNER" == "$TOKEN_OWNER" ]] || die "Token 用户不是 Gist 所有者"
echo "GitHub 用户：$TOKEN_OWNER"

log "3. 备份现有部署"
mkdir -p "$BACKUP_DIR"
systemctl is-active --quiet xray.service && OLD_XRAY_ACTIVE=1 || true
systemctl is-active --quiet sing-box.service && OLD_SB_ACTIVE=1 || true
systemctl is-enabled --quiet xray.service 2>/dev/null && OLD_XRAY_ENABLED=1 || true
systemctl is-enabled --quiet sing-box.service 2>/dev/null && OLD_SB_ENABLED=1 || true
items=()
for path in \
  opt/hybrid-proxy opt/sing-box usr/local/etc/xray \
  usr/local/bin/xray usr/local/bin/sing-box \
  etc/systemd/system/xray.service etc/systemd/system/sing-box.service \
  usr/local/sbin/hybrid-proxy-firewall etc/systemd/system/hybrid-proxy-firewall.service \
  etc/sysctl.d/99-hybrid-proxy-bbr.conf; do
  [[ -e "/$path" ]] && items+=("$path")
done
((${#items[@]})) && tar -C / -czpf "$BACKUP_DIR/files.tar.gz" "${items[@]}" || : >"$BACKUP_DIR/empty"
iptables-save >"$BACKUP_DIR/iptables.v4" 2>/dev/null || true
command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save >"$BACKUP_DIR/iptables.v6" 2>/dev/null || true
ROLLBACK=1
systemctl stop xray.service sing-box.service >/dev/null 2>&1 || true

singbox_arch(){
  case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; esac
}
xray_arch(){
  case "$(uname -m)" in x86_64|amd64) echo 64 ;; aarch64|arm64) echo arm64-v8a ;; esac
}
install_release(){
  local repo="$1" regex="$2" target="$3" name="$4"
  if [[ -x "$target" && "$UPDATE_CORE" -eq 0 ]]; then
    echo "$name 已安装：$($target version 2>/dev/null | head -n1 || true)"
    return
  fi
  local url pkg dir bin
  url="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r --arg re "$regex" '.assets[] | select(.name|test($re)) | .browser_download_url' | head -n1)"
  [[ -n "$url" && "$url" != null ]] || die "找不到 $name 的发行包"
  dir="$(mktemp -d "$TMP_DIR/release.XXXX")"; pkg="$dir/pkg"
  curl -fL --retry 3 --retry-all-errors "$url" -o "$pkg"
  case "$url" in
    *.zip) unzip -q "$pkg" -d "$dir" ;;
    *.tar.gz|*.tgz) tar -xzf "$pkg" -C "$dir" ;;
    *.tar.xz) tar -xJf "$pkg" -C "$dir" ;;
    *) die "$name 发行包格式未知" ;;
  esac
  bin="$(find "$dir" -type f -iname "$name" | head -n1)"
  [[ -n "$bin" ]] || die "$name 发行包内未找到可执行文件"
  install -m 0755 "$bin" "$target"
  rm -rf "$dir"
}

log "4. 安装 Xray-core 和 sing-box"
XRAY_ARCH="$(xray_arch)"
SB_ARCH="$(singbox_arch)"
install_release "XTLS/Xray-core" "^Xray-linux-${XRAY_ARCH}\\.zip$" "$XRAY_BIN" xray
install_release "SagerNet/sing-box" "^sing-box-.*-linux-${SB_ARCH}\\.(tar\\.(gz|xz)|zip)$" "$SB_BIN" sing-box
"$XRAY_BIN" version | head -n1
"$SB_BIN" version | head -n1

mkdir -p "$ROOT_DIR" "$CERT_DIR" "$XRAY_DIR" "$SB_DIR" "$SB_DATA"
if ((ROTATE)); then rm -f "$CREDS_FILE" "$PORTS_FILE"; rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR"; fi

# 首次迁移时复用原 5 节点的 UUID、SS1 凭据和常用端口；Reality 密钥由 Xray 重新生成。
if ((ROTATE == 0)) && [[ ! -s "$CREDS_FILE" && -s "$SB_DIR/creds.env" ]]; then
  set +u
  source "$SB_DIR/creds.env" || true
  set -u
  OLD_UUID="${UUID:-}"; OLD_SS1_PASSWORD="${SS1_PASSWORD:-}"
  OLD_SS1_PORT="${SS1_PORT:-}"; OLD_SS2_PORT="${SS2_PORT:-}"
  OLD_VISION_PORT="${VLESS_VISION_PORT:-}"; OLD_PLAIN_PORT="${VLESS_PLAIN_PORT:-}"
  OLD_SNI="${REALITY_SNI:-}"
  unset UUID SS1_PASSWORD SS2_PASSWORD SS1_PORT SS2_PORT VLESS_VISION_PORT VLESS_PLAIN_PORT REALITY_SNI REALITY_PRIV REALITY_PUB REALITY_SID TROJAN_PORT || true
fi

safe_source(){
  if [[ -s "$1" ]]; then
    set +u
    source "$1"
    set -u
  fi
  return 0
}
safe_source "$CREDS_FILE"
safe_source "$PORTS_FILE"

UUID="${UUID:-${OLD_UUID:-$(uuidgen)}}"
SS_AES_PASSWORD="${SS_AES_PASSWORD:-${OLD_SS1_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}}"
SS2022_PASSWORD="${SS2022_PASSWORD:-$(openssl rand -base64 32 | tr -d '\n')}"
HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-$(openssl rand -base64 18 | tr -d '\n')}"
TUIC_UUID="${TUIC_UUID:-$UUID}"
TUIC_PASSWORD="${TUIC_PASSWORD:-$(openssl rand -base64 24 | tr -d '\n')}"
REALITY_SNI="${REALITY_SNI:-${OLD_SNI:-www.microsoft.com}}"
REALITY_SID="${REALITY_SID:-$(openssl rand -hex 8)}"

if [[ -z "${REALITY_PRIVATE:-}" || -z "${REALITY_PUBLIC:-}" ]]; then
  KEY_OUT="$($XRAY_BIN x25519)"
  REALITY_PRIVATE="$(awk -F': ' '/^PrivateKey:/{print $2}' <<<"$KEY_OUT")"
  REALITY_PUBLIC="$(awk -F': ' '/^Password \(PublicKey\):/{print $2}' <<<"$KEY_OUT")"
fi
[[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || die "生成 Reality 密钥失败"
[[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式无效"
[[ "$REALITY_SID" =~ ^[0-9a-fA-F]{2,16}$ && $((${#REALITY_SID} % 2)) -eq 0 ]] || die "Reality short ID 格式无效"
curl -4fsSI --connect-timeout 8 --max-time 15 "https://$REALITY_SNI" >/dev/null || die "Reality 目标 $REALITY_SNI 无法通过 IPv4 访问"

cat >"$CREDS_FILE" <<EOF
UUID=$(printf %q "$UUID")
SS_AES_PASSWORD=$(printf %q "$SS_AES_PASSWORD")
SS2022_PASSWORD=$(printf %q "$SS2022_PASSWORD")
HY2_PASSWORD=$(printf %q "$HY2_PASSWORD")
HY2_OBFS_PASSWORD=$(printf %q "$HY2_OBFS_PASSWORD")
TUIC_UUID=$(printf %q "$TUIC_UUID")
TUIC_PASSWORD=$(printf %q "$TUIC_PASSWORD")
REALITY_SNI=$(printf %q "$REALITY_SNI")
REALITY_PRIVATE=$(printf %q "$REALITY_PRIVATE")
REALITY_PUBLIC=$(printf %q "$REALITY_PUBLIC")
REALITY_SID=$(printf %q "$REALITY_SID")
EOF

port_free(){ ! ss -H -lntup 2>/dev/null | grep -qE ":$1([[:space:]]|$)"; }
declare -A SEEN_PORTS=()
allocate_port(){
  local var="$1" preferred="${2:-}" p
  if [[ "$preferred" =~ ^[0-9]+$ ]] && ((preferred >= 1024 && preferred <= 65535)) \
     && [[ -z "${SEEN_PORTS[$preferred]:-}" ]] && port_free "$preferred"; then
    p="$preferred"
  else
    while :; do
      p=$((20000 + RANDOM % 40000))
      [[ -z "${SEEN_PORTS[$p]:-}" ]] && port_free "$p" && break
    done
  fi
  printf -v "$var" '%s' "$p"
  SEEN_PORTS[$p]=1
}
allocate_port XRAY_VISION_PORT "${XRAY_VISION_PORT:-${OLD_VISION_PORT:-}}"
allocate_port XRAY_PLAIN_PORT  "${XRAY_PLAIN_PORT:-${OLD_PLAIN_PORT:-}}"
allocate_port SS_AES_PORT      "${SS_AES_PORT:-${OLD_SS1_PORT:-}}"
allocate_port SS2022_PORT      "${SS2022_PORT:-${OLD_SS2_PORT:-}}"
allocate_port HY2_PORT         "${HY2_PORT:-}"
allocate_port HY2_OBFS_PORT    "${HY2_OBFS_PORT:-}"
allocate_port TUIC_PORT        "${TUIC_PORT:-}"
cat >"$PORTS_FILE" <<EOF
XRAY_VISION_PORT=$XRAY_VISION_PORT
XRAY_PLAIN_PORT=$XRAY_PLAIN_PORT
SS_AES_PORT=$SS_AES_PORT
SS2022_PORT=$SS2022_PORT
HY2_PORT=$HY2_PORT
HY2_OBFS_PORT=$HY2_OBFS_PORT
TUIC_PORT=$TUIC_PORT
EOF
chmod 700 "$ROOT_DIR" "$CERT_DIR" "$XRAY_DIR" "$SB_DIR"
chmod 600 "$CREDS_FILE" "$PORTS_FILE"

mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-hybrid-proxy-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null 2>&1 || true

log "5. 生成 Xray Reality 配置"
jq -n \
  --arg uuid "$UUID" --arg sni "$REALITY_SNI" --arg priv "$REALITY_PRIVATE" --arg sid "$REALITY_SID" \
  --argjson p1 "$XRAY_VISION_PORT" --argjson p2 "$XRAY_PLAIN_PORT" '
{
 log:{loglevel:"warning"},
 inbounds:[
  {tag:"vless-reality-vision",listen:"0.0.0.0",port:$p1,protocol:"vless",
   settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},
   streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$priv,shortIds:[$sid]}},
   sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}},
  {tag:"vless-reality",listen:"0.0.0.0",port:$p2,protocol:"vless",
   settings:{clients:[{id:$uuid}],decryption:"none"},
   streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$priv,shortIds:[$sid]}},
   sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}}
 ],
 outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]
}' >"$XRAY_CONFIG"
"$XRAY_BIN" run -test -config "$XRAY_CONFIG"

cat >"$XRAY_SERVICE" <<EOF
[Unit]
Description=Xray Reality Service
After=network-online.target hybrid-proxy-firewall.service
Wants=network-online.target hybrid-proxy-firewall.service

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

log "6. 生成 sing-box 辅助协议配置"
if [[ ! -s "$CERT_DIR/fullchain.pem" || ! -s "$CERT_DIR/private.key" ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -keyout "$CERT_DIR/private.key" -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=$REALITY_SNI" -addext "subjectAltName=DNS:$REALITY_SNI" >/dev/null 2>&1
fi
chmod 600 "$CERT_DIR/private.key"

jq -n \
 --arg ssa "$SS_AES_PASSWORD" --arg ss22 "$SS2022_PASSWORD" \
 --arg hy2 "$HY2_PASSWORD" --arg hy2o "$HY2_OBFS_PASSWORD" \
 --arg tu "$TUIC_UUID" --arg tup "$TUIC_PASSWORD" \
 --arg crt "$CERT_DIR/fullchain.pem" --arg key "$CERT_DIR/private.key" \
 --argjson p1 "$SS_AES_PORT" --argjson p2 "$SS2022_PORT" --argjson p3 "$HY2_PORT" --argjson p4 "$HY2_OBFS_PORT" --argjson p5 "$TUIC_PORT" '
{
 log:{level:"warn",timestamp:true},
 inbounds:[
  {type:"shadowsocks",tag:"ss-aes",listen:"0.0.0.0",listen_port:$p1,method:"aes-256-gcm",password:$ssa},
  {type:"shadowsocks",tag:"ss2022",listen:"0.0.0.0",listen_port:$p2,method:"2022-blake3-aes-256-gcm",password:$ss22},
  {type:"hysteria2",tag:"hy2",listen:"0.0.0.0",listen_port:$p3,users:[{name:"hy2",password:$hy2}],tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}},
  {type:"hysteria2",tag:"hy2-obfs",listen:"0.0.0.0",listen_port:$p4,users:[{name:"hy2",password:$hy2}],obfs:{type:"salamander",password:$hy2o},tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}},
  {type:"tuic",tag:"tuic",listen:"0.0.0.0",listen_port:$p5,users:[{uuid:$tu,password:$tup}],congestion_control:"bbr",tls:{enabled:true,certificate_path:$crt,key_path:$key,alpn:["h3"]}}
 ],
 outbounds:[{type:"direct",tag:"direct"},{type:"block",tag:"block"}],
 route:{final:"direct"}
}' >"$SB_CONFIG"
"$SB_BIN" check -c "$SB_CONFIG"
cat >"$SB_SERVICE" <<EOF
[Unit]
Description=sing-box Auxiliary Protocols
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

log "7. 配置防火墙并启动服务"
cat >"$FW_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
TCP_PORTS=($XRAY_VISION_PORT $XRAY_PLAIN_PORT $SS_AES_PORT $SS2022_PORT)
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
systemctl enable hybrid-proxy-firewall.service xray.service sing-box.service >/dev/null
systemctl restart hybrid-proxy-firewall.service
systemctl restart xray.service sing-box.service
systemctl is-active --quiet xray.service || { journalctl -u xray.service -n 50 --no-pager; die "Xray 启动失败"; }
systemctl is-active --quiet sing-box.service || { journalctl -u sing-box.service -n 50 --no-pager; die "sing-box 启动失败"; }

for p in "$XRAY_VISION_PORT" "$XRAY_PLAIN_PORT" "$SS_AES_PORT" "$SS2022_PORT"; do
  ss -H -lnt | awk -v p=":$p" '$4 ~ p"$"{ok=1} END{exit !ok}' || die "TCP 端口 $p 未监听"
done
for p in "$SS_AES_PORT" "$SS2022_PORT" "$HY2_PORT" "$HY2_OBFS_PORT" "$TUIC_PORT"; do
  ss -H -lnu | awk -v p=":$p" '$4 ~ p"$"{ok=1} END{exit !ok}' || die "UDP 端口 $p 未监听"
done

# 本地服务已验证；之后 Gist 失败不再回滚可用服务。
ROLLBACK=0

log "8. 生成并更新订阅"
SERVER_IP="$(curl -4fsS --connect-timeout 8 https://api.ipify.org 2>/dev/null || true)"
[[ -n "$SERVER_IP" ]] || die "未检测到公网 IPv4"
URI_HOST="$SERVER_IP"
urlenc(){ local s="$1" out="" c i; for ((i=0;i<${#s};i++)); do c="${s:i:1}"; case "$c" in [a-zA-Z0-9.~_-]) out+="$c" ;; *) printf -v out '%s%%%02X' "$out" "'$c" ;; esac; done; printf '%s' "$out"; }
b64url(){ base64 -w 0 2>/dev/null | tr '+/' '-_' | tr -d '='; }
{
 echo "vless://${UUID}@${URI_HOST}:${XRAY_VISION_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&spx=%2F&type=tcp#xray-vless-reality-vision"
 echo "vless://${UUID}@${URI_HOST}:${XRAY_PLAIN_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${REALITY_SID}&spx=%2F&type=tcp#xray-vless-reality"
 echo "ss://$(printf '%s' "aes-256-gcm:${SS_AES_PASSWORD}" | b64url)@${URI_HOST}:${SS_AES_PORT}#ss-aes256"
 echo "ss://$(printf '%s' "2022-blake3-aes-256-gcm:${SS2022_PASSWORD}" | b64url)@${URI_HOST}:${SS2022_PORT}#ss2022"
 echo "hy2://$(urlenc "$HY2_PASSWORD")@${URI_HOST}:${HY2_PORT}?insecure=1&allowInsecure=1&sni=${REALITY_SNI}&alpn=h3#hysteria2"
 echo "hy2://$(urlenc "$HY2_PASSWORD")@${URI_HOST}:${HY2_OBFS_PORT}?insecure=1&allowInsecure=1&sni=${REALITY_SNI}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "$HY2_OBFS_PASSWORD")#hysteria2-obfs"
 echo "tuic://${TUIC_UUID}:$(urlenc "$TUIC_PASSWORD")@${URI_HOST}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=1&allowInsecure=1&sni=${REALITY_SNI}#tuic-v5"
} >"$SUB_PLAIN"
[[ "$(wc -l <"$SUB_PLAIN")" -eq 7 ]] || die "订阅节点数量错误"
base64 -w 0 "$SUB_PLAIN" >"$SUB_B64"
chmod 600 "$SUB_PLAIN" "$SUB_B64"

jq -n --rawfile plain "$SUB_PLAIN" --rawfile sub "$SUB_B64" \
  '{files:{"sub_plain.txt":{content:$plain},"sub.txt":{content:$sub}}}' >"$TMP_DIR/payload.json"
code="$(curl -sS -o "$TMP_DIR/gist-new.json" -w '%{http_code}' -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' -H 'Content-Type: application/json' \
  "https://api.github.com/gists/$GIST_ID" --data-binary @"$TMP_DIR/payload.json")"
[[ "$code" == 200 ]] || { cat "$TMP_DIR/gist-new.json"; die "Gist 更新失败，HTTP $code；本地服务仍保持运行"; }
RAW_PLAIN="$(jq -r '.files["sub_plain.txt"].raw_url // empty' "$TMP_DIR/gist-new.json")"
RAW_B64="$(jq -r '.files["sub.txt"].raw_url // empty' "$TMP_DIR/gist-new.json")"
verify(){ local f="$1" u="$2" n="$3" a b i; a="$(sha256sum "$f"|awk '{print $1}')"; for i in 1 2 3 4 5; do curl -fLsS -H 'Cache-Control: no-cache' "$u?x=$(date +%s%N)" -o "$TMP_DIR/r" || true; b="$(sha256sum "$TMP_DIR/r" 2>/dev/null|awk '{print $1}'||true)"; [[ "$a" == "$b" ]] && { echo "$n 校验通过"; return; }; sleep "$i"; done; die "$n 远程校验失败；本地服务仍保持运行"; }
verify "$SUB_PLAIN" "$RAW_PLAIN" 明文订阅
verify "$SUB_B64" "$RAW_B64" Base64订阅

log "9. 部署完成"
cat "$SUB_PLAIN"
echo
echo "云防火墙 TCP：$XRAY_VISION_PORT,$XRAY_PLAIN_PORT,$SS_AES_PORT,$SS2022_PORT"
echo "云防火墙 UDP：$SS_AES_PORT,$SS2022_PORT,$HY2_PORT,$HY2_OBFS_PORT,$TUIC_PORT"
echo "Base64 订阅：https://gist.githubusercontent.com/$GIST_OWNER/$GIST_ID/raw/sub.txt"
echo "明文订阅：https://gist.githubusercontent.com/$GIST_OWNER/$GIST_ID/raw/sub_plain.txt"
echo "Xray 状态：systemctl status xray --no-pager"
echo "sing-box 状态：systemctl status sing-box --no-pager"
echo "备份目录：$BACKUP_DIR"
unset GH_TOKEN || true
