#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Debian 13/Ubuntu 自动部署：9 个直连节点并更新 Gist 订阅。
# 配置生成函数复用同仓库 sing-box-plus.sh，避免维护两套协议实现。

REPO_RAW="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus/main"
GIST_ID="${GIST_ID:-85a7d7b63d151e78558a4737aca3ce02}"
SB_DIR="/opt/sing-box"
BIN="/usr/local/bin/sing-box"
CONF="$SB_DIR/config.json"
SERVICE="sing-box.service"
TMP="$(mktemp -d /tmp/sbp-auto.XXXXXX)"
BACKUP="/root/sing-box-backups/$(date +%Y%m%d-%H%M%S)"
ROTATE=0
NO_GIST=0
USE_IPV6=0
ROLLBACK=0

log(){ printf '\n========== %s ==========\n' "$*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --rotate) ROTATE=1 ;;
    --no-gist) NO_GIST=1 ;;
    --ipv6) USE_IPV6=1 ;;
    --gist-id) shift; GIST_ID="${1:?--gist-id 缺少参数}" ;;
    -h|--help)
      cat <<'HELP'
用法：auto-deploy.sh [--rotate] [--no-gist] [--ipv6] [--gist-id ID]
默认优先生成 IPv4 订阅，并保留已有凭据和端口。
HELP
      exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

cleanup(){
  rc=$?
  set +e
  unset GH_TOKEN
  if ((rc != 0 && ROLLBACK)); then
    echo "部署失败，恢复旧配置……" >&2
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    rm -rf "$SB_DIR"; rm -f "$BIN" "/etc/systemd/system/$SERVICE"
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
[[ "$(ps -p 1 -o comm= | xargs)" == systemd ]] || die "需要 systemd；不支持普通 Docker 容器"

log "1. 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl jq openssl tar xz-utils unzip iproute2 \
  iptables iptables-persistent netfilter-persistent uuid-runtime util-linux procps
exec 9>/run/sbp-auto.lock
flock -n 9 || die "已有部署任务正在运行"

log "2. 备份旧配置"
mkdir -p "$BACKUP"
items=()
[[ -e "$SB_DIR" ]] && items+=(opt/sing-box)
[[ -e "$BIN" ]] && items+=(usr/local/bin/sing-box)
[[ -e "/etc/systemd/system/$SERVICE" ]] && items+=("etc/systemd/system/$SERVICE")
[[ -e /etc/sysctl.d/99-bbr.conf ]] && items+=(etc/sysctl.d/99-bbr.conf)
((${#items[@]})) && tar -C / -czpf "$BACKUP/files.tar.gz" "${items[@]}" || : >"$BACKUP/empty"
ROLLBACK=1
systemctl stop "$SERVICE" >/dev/null 2>&1 || true

log "3. 下载部署库并选择网络"
curl -fL --retry 3 "$REPO_RAW/sing-box-plus.sh" -o "$TMP/library.sh"
# 去掉文件最后的 menu 调用，只加载函数。
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
  curl "$flag" -sS --connect-timeout 6 --max-time 10 \
    -o /dev/null "https://$n" >/dev/null 2>&1
}
OLD_SNI="$(sed -n 's/^REALITY_SERVER=//p' "$SB_DIR/env.conf" 2>/dev/null | head -n1 || true)"
REALITY_SERVER=""
for n in "$OLD_SNI" www.microsoft.com www.apple.com www.cloudflare.com www.amazon.com; do
  [[ -n "$n" ]] || continue
  test_sni "$n" && { REALITY_SERVER="$n"; break; }
done
[[ -n "$REALITY_SERVER" ]] || die "找不到可用 Reality 握手目标"
export REALITY_SERVER ENABLE_WARP=false
[[ -n "$OLD_SNI" && "$OLD_SNI" != "$REALITY_SERVER" ]] && rm -rf "$SB_DIR/cert"
printf '使用 IPv%s：%s\nReality 目标：%s\n' "$LINK_MODE" "$SERVER_IP" "$REALITY_SERVER"

log "4. 生成 9 个协议节点"
if ((ROTATE)); then
  rm -f "$SB_DIR/creds.env" "$SB_DIR/ports.env" "$SB_DIR/env.conf"
  rm -rf "$SB_DIR/cert"
fi
mkdir -p "$SB_DIR"

# 新部署/换端口时，将 9 个端口设为连续区间，方便云防火墙一次放行。
if ((ROTATE)) || [[ ! -s "$SB_DIR/ports.env" ]]; then
  found=""
  for _ in {1..200}; do
    base=$((20000 + RANDOM % 30000))
    busy=0
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

# 强制下载当前最新稳定版核心；配置/凭据仍由库函数复用。
rm -f "$BIN"
sbp_bootstrap
install_singbox
ENABLE_WARP=false
# 避免旧 env.conf 覆盖本次自动选择的 SNI/WARP 设置。
rm -f "$SB_DIR/env.conf"
write_config

# 仅保留前 9 个直连入站，并明确使用所选地址族监听。
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

# 重新加载实际端口。
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
for p in "${TCP_PORTS[@]}"; do
  ss -H -lnt | awk -v p=":$p" '$4 ~ p"$"{ok=1} END{exit !ok}' || die "TCP 端口 $p 未监听"
done
for p in "${UDP_PORTS[@]}"; do
  ss -H -lnu | awk -v p=":$p" '$4 ~ p"$"{ok=1} END{exit !ok}' || die "UDP 端口 $p 未监听"
done

log "5. Reality 本机回环自测"
load_creds
TEST_SERVER="127.0.0.1"; ((LINK_MODE==6)) && TEST_SERVER="::1"
TEST_PORT=10998
while ss -H -lnt | grep -q ":$TEST_PORT "; do TEST_PORT=$((TEST_PORT+1)); done
jq -n --arg u "$UUID" --arg s "$REALITY_SERVER" --arg p "$REALITY_PUB" --arg i "$REALITY_SID" --arg ts "$TEST_SERVER" \
  --argjson rp "$PORT_VLESSR" --argjson lp "$TEST_PORT" '
 {log:{level:"error"},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$lp}],
  outbounds:[{type:"vless",tag:"p",server:$ts,server_port:$rp,uuid:$u,flow:"xtls-rprx-vision",
   tls:{enabled:true,server_name:$s,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$p,short_id:$i}}}],
  route:{final:"p"}}' >"$TMP/test.json"
"$BIN" run -c "$TMP/test.json" >"$TMP/test.log" 2>&1 & pid=$!
sleep 1
curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:$TEST_PORT" \
  https://www.cloudflare.com/cdn-cgi/trace >/dev/null || { cat "$TMP/test.log" >&2; kill "$pid" || true; die "Reality 自测失败"; }
kill "$pid" >/dev/null 2>&1 || true; wait "$pid" 2>/dev/null || true
echo "Reality 自测通过"

log "6. 生成并更新订阅"
# 仅截取 print_links_grouped 输出中的直连 9 个链接。
print_links_grouped "$LINK_MODE" | awk '
 /【直连节点（9）】/{on=1;next}
 /【WARP 节点（9）】/{on=0}
 on && $0 ~ /^[[:space:]]*(vless|trojan|hy2|vmess|ss|tuic):\/\// {sub(/^[[:space:]]+/,"");print}
' >"$SB_DIR/sub_plain.txt"
[[ "$(wc -l <"$SB_DIR/sub_plain.txt")" -eq 9 ]] || die "订阅不是 9 个节点"
base64 -w 0 "$SB_DIR/sub_plain.txt" >"$SB_DIR/sub.txt"
chmod 600 "$SB_DIR/sub_plain.txt" "$SB_DIR/sub.txt"

if ((NO_GIST==0)); then
  [[ -n "${GH_TOKEN:-}" ]] || { read -rsp "请输入 GitHub Token（需要 Gists 写权限）: " GH_TOKEN </dev/tty; echo; }
  [[ -n "$GH_TOKEN" ]] || die "Token 为空"
  jq -n --rawfile p "$SB_DIR/sub_plain.txt" --rawfile b "$SB_DIR/sub.txt" \
    '{files:{"sub_plain.txt":{content:$p},"sub.txt":{content:$b}}}' >"$TMP/payload.json"
  code="$(curl -sS -o "$TMP/gist.json" -w '%{http_code}' -X PATCH \
    -H "Authorization: Bearer $GH_TOKEN" -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' -H 'Content-Type: application/json' \
    "https://api.github.com/gists/$GIST_ID" --data-binary @"$TMP/payload.json")"
  [[ "$code" == 200 ]] || { cat "$TMP/gist.json"; die "Gist 更新失败，HTTP $code"; }
  owner="$(jq -r '.owner.login' "$TMP/gist.json")"
fi

log "7. 完成"
cat "$SB_DIR/sub_plain.txt"
echo
printf '云防火墙 TCP：%s\n' "$(IFS=,; echo "${TCP_PORTS[*]}")"
printf '云防火墙 UDP：%s\n' "$(IFS=,; echo "${UDP_PORTS[*]}")"
if ((NO_GIST==0)); then
  echo "Base64 订阅：https://gist.githubusercontent.com/$owner/$GIST_ID/raw/sub.txt"
  echo "明文订阅：https://gist.githubusercontent.com/$owner/$GIST_ID/raw/sub_plain.txt"
fi
echo "服务状态：systemctl status sing-box --no-pager"
echo "备份目录：$BACKUP"
ROLLBACK=0
unset GH_TOKEN || true
