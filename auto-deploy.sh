#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Debian 13 / Ubuntu：部署 9 个直连节点并强制更新 Gist 订阅。
# 第一个位置参数为 GH_TOKEN，第二个位置参数为可选 GIST_ID。

REPO_RAW="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus/main"
DEFAULT_GIST_ID="85a7d7b63d151e78558a4737aca3ce02"
GH_TOKEN="${GH_TOKEN:-}"
GIST_ID="${GIST_ID:-$DEFAULT_GIST_ID}"
SB_DIR="/opt/sing-box"
BIN="/usr/local/bin/sing-box"
CONF="$SB_DIR/config.json"
SERVICE="sing-box.service"
TMP="$(mktemp -d /tmp/sbp-auto.XXXXXX)"
BACKUP="/root/sing-box-backups/$(date +%Y%m%d-%H%M%S)"
ROTATE=0
USE_IPV6=0
ROLLBACK=0

log(){ printf '\n========== %s ==========\n' "$*"; }
warn(){ echo "[警告] $*" >&2; }
die(){ echo "[错误] $*" >&2; exit 1; }

# 推荐调用：bash <(curl -fsSL URL) GH_TOKEN [GIST_ID] [选项]
if [[ -n "${1:-}" && "${1:-}" != --* ]]; then GH_TOKEN="$1"; shift; fi
if [[ -n "${1:-}" && "${1:-}" != --* ]]; then GIST_ID="$1"; shift; fi
while (($#)); do
  case "$1" in
    --rotate) ROTATE=1 ;;
    --ipv6) USE_IPV6=1 ;;
    --gist-id) shift; GIST_ID="${1:?--gist-id 缺少参数}" ;;
    -h|--help)
      cat <<'HELP'
用法：auto-deploy.sh GH_TOKEN [GIST_ID] [--rotate] [--ipv6]
默认 GIST_ID：85a7d7b63d151e78558a4737aca3ce02
每次执行都会强制更新订阅；默认保留端口和凭据。
HELP
      exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

if [[ -z "$GH_TOKEN" ]]; then
  read -rsp "请输入 GitHub Token（需要 Gists 写权限）: " GH_TOKEN </dev/tty
  echo
fi
[[ -n "$GH_TOKEN" ]] || die "GitHub Token 为空"
[[ "$GIST_ID" =~ ^[0-9a-fA-F]{20,64}$ ]] || die "GIST_ID 格式不正确：$GIST_ID"

cleanup(){
  rc=$?
  set +e
  unset GH_TOKEN
  if ((rc != 0 && ROLLBACK)); then
    echo "部署失败，恢复旧配置……" >&2
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    rm -rf "$SB_DIR"
    rm -f "$BIN" "/etc/systemd/system/$SERVICE"
    [[ -s "$BACKUP/files.tar.gz" ]] && tar -C / -xzpf "$BACKUP/files.tar.gz"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "$SERVICE" >/dev/null 2>&1 || true
    echo "已恢复，备份目录：$BACKUP" >&2
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 执行"
source /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in debian:*|ubuntu:*|*:debian*) ;; *) die "仅支持 Debian/Ubuntu" ;; esac
[[ "$(ps -p 1 -o comm= | xargs)" == systemd ]] || die "需要 systemd"

log "1. 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl jq openssl tar xz-utils unzip iproute2 \
  iptables iptables-persistent netfilter-persistent uuid-runtime util-linux procps
exec 9>/run/sbp-auto.lock
flock -n 9 || die "已有部署任务正在运行"

log "2. 预检 GitHub Token 和 Gist"
GIST_CHECK_CODE="$(curl -sS -o "$TMP/gist-check.json" -w '%{http_code}' \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "https://api.github.com/gists/$GIST_ID")"
[[ "$GIST_CHECK_CODE" == 200 ]] || { cat "$TMP/gist-check.json"; die "读取 Gist 失败，HTTP $GIST_CHECK_CODE"; }
USER_CHECK_CODE="$(curl -sS -o "$TMP/user-check.json" -w '%{http_code}' \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  'https://api.github.com/user')"
[[ "$USER_CHECK_CODE" == 200 ]] || { cat "$TMP/user-check.json"; die "Token 校验失败，HTTP $USER_CHECK_CODE"; }
GIST_OWNER="$(jq -r '.owner.login // empty' "$TMP/gist-check.json")"
TOKEN_OWNER="$(jq -r '.login // empty' "$TMP/user-check.json")"
[[ -n "$GIST_OWNER" && "$GIST_OWNER" == "$TOKEN_OWNER" ]] || die "Token 用户不是该 Gist 所有者"
echo "Token 用户：$TOKEN_OWNER"
echo "Gist ID：$GIST_ID"

log "3. 备份旧配置"
mkdir -p "$BACKUP"
items=()
[[ -e "$SB_DIR" ]] && items+=(opt/sing-box)
[[ -e "$BIN" ]] && items+=(usr/local/bin/sing-box)
[[ -e "/etc/systemd/system/$SERVICE" ]] && items+=("etc/systemd/system/$SERVICE")
[[ -e /etc/sysctl.d/99-bbr.conf ]] && items+=(etc/sysctl.d/99-bbr.conf)
((${#items[@]})) && tar -C / -czpf "$BACKUP/files.tar.gz" "${items[@]}" || : >"$BACKUP/empty"
ROLLBACK=1
systemctl stop "$SERVICE" >/dev/null 2>&1 || true

log "4. 下载部署库并选择网络"
curl -fL --retry 3 "$REPO_RAW/sing-box-plus.sh" -o "$TMP/library.sh"
sed -e 's/^stty erase.*/stty erase ^H 2>\/dev\/null || true/' \
    -e 's/^menu$/# menu disabled for auto deploy/' \
    "$TMP/library.sh" >"$TMP/library-source.sh"
# shellcheck disable=SC1090
source "$TMP/library-source.sh"

IP4="$(curl -4fsS --connect-timeout 6 https://api.ipify.org 2>/dev/null || true)"
IP6="$(curl -6fsS --connect-timeout 6 https://api64.ipify.org 2>/dev/null || true)"
[[ "$IP6" == *:* ]] || IP6=""
if ((USE_IPV6)); then
  [[ -n "$IP6" ]] || die "未检测到公网 IPv6"
  LINK_MODE=6; LISTEN_ADDR="::"; SERVER_IP="$IP6"
elif [[ -n "$IP4" ]]; then
  LINK_MODE=4; LISTEN_ADDR="0.0.0.0"; SERVER_IP="$IP4"
elif [[ -n "$IP6" ]]; then
  LINK_MODE=6; LISTEN_ADDR="::"; SERVER_IP="$IP6"
else
  die "未检测到公网 IPv4/IPv6"
fi

test_sni(){
  local n="$1" flag=-4
  ((LINK_MODE==6)) && flag=-6
  curl "$flag" -sS --connect-timeout 6 --max-time 10 -o /dev/null "https://$n" >/dev/null 2>&1
}
OLD_SNI="$(sed -n 's/^REALITY_SERVER=//p' "$SB_DIR/env.conf" 2>/dev/null | head -n1 || true)"
REALITY_SERVER=""
for n in "$OLD_SNI" www.microsoft.com www.apple.com www.amazon.com www.cloudflare.com; do
  [[ -n "$n" ]] || continue
  test_sni "$n" && { REALITY_SERVER="$n"; break; }
done
[[ -n "$REALITY_SERVER" ]] || die "找不到可用 Reality 握手目标"
export REALITY_SERVER ENABLE_WARP=false
[[ -n "$OLD_SNI" && "$OLD_SNI" != "$REALITY_SERVER" ]] && rm -rf "$SB_DIR/cert"
printf '使用 IPv%s：%s\nReality 目标：%s\n' "$LINK_MODE" "$SERVER_IP" "$REALITY_SERVER"

log "5. 生成 9 个协议节点"
if ((ROTATE)); then
  rm -f "$SB_DIR/creds.env" "$SB_DIR/ports.env" "$SB_DIR/env.conf"
  rm -rf "$SB_DIR/cert"
fi
mkdir -p "$SB_DIR"
if ((ROTATE)) || [[ ! -s "$SB_DIR/ports.env" ]]; then
  found=""
  for _ in {1..200}; do
    base=$((20000 + RANDOM % 30000)); busy=0
    for ((p=base;p<=base+8;p++)); do
      ss -H -lntup 2>/dev/null | grep -qE ":${p}([[:space:]]|$)" && { busy=1; break; }
    done
    ((busy==0)) && { found="$base"; break; }
  done
  [[ -n "$found" ]] || die "找不到连续 9 个空闲端口"
  PORT_VLESSR=$((found+0)); PORT_VLESS_GRPCR=$((found+1)); PORT_TROJANR=$((found+2))
  PORT_HY2=$((found+3)); PORT_VMESS_WS=$((found+4)); PORT_HY2_OBFS=$((found+5))
  PORT_SS2022=$((found+6)); PORT_SS=$((found+7)); PORT_TUIC=$((found+8))
fi

rm -f "$BIN"
sbp_bootstrap
install_singbox
ENABLE_WARP=false
rm -f "$SB_DIR/env.conf"
write_config
jq --arg listen "$LISTEN_ADDR" --arg strategy "$( ((LINK_MODE==6)) && echo prefer_ipv6 || echo prefer_ipv4 )" '
  .dns = {servers:[{type:"local",tag:"local"}],strategy:$strategy}
  | .inbounds = (.inbounds[:9] | map(.listen=$listen))
  | .outbounds = [{type:"direct",tag:"direct"},{type:"block",tag:"block"}]
  | .route = {default_domain_resolver:"local",final:"direct"}
' "$CONF" >"$TMP/config.json"
mv "$TMP/config.json" "$CONF"
"$BIN" check -c "$CONF"
write_systemd
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE" || die "sing-box 启动失败"
enable_bbr

load_ports
TCP_PORTS=("$PORT_VLESSR" "$PORT_VLESS_GRPCR" "$PORT_TROJANR" "$PORT_VMESS_WS" "$PORT_SS2022" "$PORT_SS")
UDP_PORTS=("$PORT_HY2" "$PORT_HY2_OBFS" "$PORT_TUIC" "$PORT_SS2022" "$PORT_SS")
for p in "${TCP_PORTS[@]}"; do
  iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
  command -v ip6tables >/dev/null && { ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT; }
done
for p in "${UDP_PORTS[@]}"; do
  iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
  command -v ip6tables >/dev/null && { ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT; }
done
netfilter-persistent save >/dev/null 2>&1 || true
for p in "${TCP_PORTS[@]}"; do ss -H -lnt | awk -v p=":$p" '$4 ~ p"$"{ok=1} END{exit !ok}' || die "TCP 端口 $p 未监听"; done
for p in "${UDP_PORTS[@]}"; do ss -H -lnu | awk -v p=":$p" '$4 ~ p"$"{ok=1} END{exit !ok}' || die "UDP 端口 $p 未监听"; done

log "6. 使用 Xray Core 验证 Reality"
load_creds
XRAY_ARCH=""
case "$(uname -m)" in
  x86_64|amd64) XRAY_ARCH='Xray-linux-64\.zip$' ;;
  aarch64|arm64) XRAY_ARCH='Xray-linux-arm64-v8a\.zip$' ;;
esac
XRAY_BIN=""
if [[ -n "$XRAY_ARCH" ]]; then
  XRAY_URL="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | jq -r --arg re "$XRAY_ARCH" '.assets[] | select(.name|test($re)) | .browser_download_url' | head -n1 || true)"
  if [[ -n "$XRAY_URL" && "$XRAY_URL" != null ]]; then
    mkdir -p "$TMP/xray"
    if curl -fL --retry 3 "$XRAY_URL" -o "$TMP/xray.zip" && unzip -q "$TMP/xray.zip" -d "$TMP/xray"; then
      XRAY_BIN="$(find "$TMP/xray" -type f -iname xray | head -n1)"
      [[ -n "$XRAY_BIN" ]] && chmod 700 "$XRAY_BIN"
    fi
  fi
fi

if [[ -z "$XRAY_BIN" ]]; then
  warn "Xray 测试核心下载失败，跳过 Reality 协议握手测试；服务和端口检查已通过"
else
  TEST_SERVER="127.0.0.1"; ((LINK_MODE==6)) && TEST_SERVER="::1"
  TEST_PORT=10998
  while ss -H -lnt | grep -qE ":${TEST_PORT}([[:space:]]|$)"; do TEST_PORT=$((TEST_PORT+1)); done
  jq -n --arg u "$UUID" --arg s "$REALITY_SERVER" --arg p "$REALITY_PUB" --arg i "$REALITY_SID" --arg ts "$TEST_SERVER" \
    --argjson rp "$PORT_VLESSR" --argjson lp "$TEST_PORT" '
    {
      log:{loglevel:"error"},
      inbounds:[{listen:"127.0.0.1",port:$lp,protocol:"socks",settings:{udp:false}}],
      outbounds:[{
        tag:"proxy",protocol:"vless",
        settings:{vnext:[{address:$ts,port:$rp,users:[{id:$u,encryption:"none",flow:"xtls-rprx-vision"}]}]},
        streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,fingerprint:"chrome",serverName:$s,publicKey:$p,shortId:$i,spiderX:"/"}}
      }]
    }' >"$TMP/xray-test.json"
  "$XRAY_BIN" run -c "$TMP/xray-test.json" >"$TMP/xray-test.log" 2>&1 & xpid=$!
  sleep 1
  if ! kill -0 "$xpid" 2>/dev/null; then
    cat "$TMP/xray-test.log" >&2
    die "Xray 测试核心启动失败"
  fi
  if ! curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:$TEST_PORT" https://www.cloudflare.com/cdn-cgi/trace >/dev/null; then
    echo "----- Xray 客户端日志 -----" >&2
    cat "$TMP/xray-test.log" >&2 || true
    echo "----- sing-box 服务日志 -----" >&2
    journalctl -u "$SERVICE" -n 80 --no-pager >&2 || true
    kill "$xpid" >/dev/null 2>&1 || true
    wait "$xpid" 2>/dev/null || true
    die "Reality 的 Xray 兼容性测试失败"
  fi
  kill "$xpid" >/dev/null 2>&1 || true
  wait "$xpid" 2>/dev/null || true
  echo "Reality 的 Xray 兼容性测试通过"
fi

log "7. 生成并强制更新订阅"
print_links_grouped "$LINK_MODE" | awk '
 /【直连节点（9）】/{on=1;next}
 /【WARP 节点（9）】/{on=0}
 on && $0 ~ /^[[:space:]]*(vless|trojan|hy2|vmess|ss|tuic):\/\// {sub(/^[[:space:]]+/,"");print}
' >"$SB_DIR/sub_plain.txt"
[[ "$(wc -l <"$SB_DIR/sub_plain.txt")" -eq 9 ]] || die "订阅不是 9 个节点"
base64 -w 0 "$SB_DIR/sub_plain.txt" >"$SB_DIR/sub.txt"
chmod 600 "$SB_DIR/sub_plain.txt" "$SB_DIR/sub.txt"

jq -n --rawfile p "$SB_DIR/sub_plain.txt" --rawfile b "$SB_DIR/sub.txt" \
  '{files:{"sub_plain.txt":{content:$p},"sub.txt":{content:$b}}}' >"$TMP/payload.json"
code="$(curl -sS -o "$TMP/gist.json" -w '%{http_code}' -X PATCH \
  -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' -H 'Content-Type: application/json' \
  "https://api.github.com/gists/$GIST_ID" --data-binary @"$TMP/payload.json")"
[[ "$code" == 200 ]] || { cat "$TMP/gist.json"; die "Gist 更新失败，HTTP $code"; }
GIST_OWNER="$(jq -r '.owner.login // empty' "$TMP/gist.json")"
RAW_SUB="$(jq -r '.files["sub.txt"].raw_url // empty' "$TMP/gist.json")"
RAW_PLAIN="$(jq -r '.files["sub_plain.txt"].raw_url // empty' "$TMP/gist.json")"
[[ -n "$RAW_SUB" && -n "$RAW_PLAIN" ]] || die "GitHub 返回结果缺少 raw_url"

verify_remote(){
  local local_file="$1" raw_url="$2" name="$3" local_hash remote_hash try
  local_hash="$(sha256sum "$local_file" | awk '{print $1}')"
  for try in 1 2 3 4 5; do
    curl -fLsS -H 'Cache-Control: no-cache' "${raw_url}?nocache=$(date +%s%N)" -o "$TMP/remote-$name" || true
    remote_hash="$(sha256sum "$TMP/remote-$name" 2>/dev/null | awk '{print $1}' || true)"
    [[ "$local_hash" == "$remote_hash" ]] && { echo "$name 远程校验通过：$local_hash"; return 0; }
    sleep "$try"
  done
  die "$name 的 Gist 内容与本地不一致"
}
verify_remote "$SB_DIR/sub.txt" "$RAW_SUB" sub
verify_remote "$SB_DIR/sub_plain.txt" "$RAW_PLAIN" plain

log "8. 完成"
cat "$SB_DIR/sub_plain.txt"
echo
printf '云防火墙 TCP：%s\n' "$(IFS=,; echo "${TCP_PORTS[*]}")"
printf '云防火墙 UDP：%s\n' "$(IFS=,; echo "${UDP_PORTS[*]}")"
echo "Base64 订阅：https://gist.githubusercontent.com/$GIST_OWNER/$GIST_ID/raw/sub.txt"
echo "明文订阅：https://gist.githubusercontent.com/$GIST_OWNER/$GIST_ID/raw/sub_plain.txt"
echo "服务状态：systemctl status sing-box --no-pager"
echo "备份目录：$BACKUP"
ROLLBACK=0
unset GH_TOKEN || true
