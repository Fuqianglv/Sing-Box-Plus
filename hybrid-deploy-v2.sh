#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Robust launcher for the full hybrid deployer.
# It downloads a pinned, known full deployer and replaces the immediate
# systemd/socket checks with bounded wait loops plus diagnostic logs.

BASE_COMMIT="1a16035bd9aceb9ba126cdeca523209e9955b9e6"
BASE_URL="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus/${BASE_COMMIT}/hybrid-deploy.sh"
WORK_DIR="$(mktemp -d /tmp/hybrid-deploy-v2.XXXXXX)"
BASE_FILE="$WORK_DIR/base.sh"
PATCHED_FILE="$WORK_DIR/patched.sh"

cleanup(){
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --retry-all-errors --connect-timeout 15 "$BASE_URL" -o "$BASE_FILE"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$BASE_FILE" "$BASE_URL"
else
  echo "[ERROR] 系统缺少 curl/wget" >&2
  exit 1
fi

start_line="$(grep -n '^systemctl daemon-reload$' "$BASE_FILE" | sed -n '1p' | cut -d: -f1)"
end_line="$(grep -n '^# 本地服务已验证；之后 Gist 失败不再回滚可用服务。$' "$BASE_FILE" | sed -n '1p' | cut -d: -f1)"

if [[ -z "$start_line" || -z "$end_line" || "$start_line" -ge "$end_line" ]]; then
  echo "[ERROR] 无法定位基础脚本中的服务启动检查区块" >&2
  exit 1
fi

head -n $((start_line - 1)) "$BASE_FILE" >"$PATCHED_FILE"
cat >>"$PATCHED_FILE" <<'PATCH'
systemctl daemon-reload
systemctl enable hybrid-proxy-firewall.service xray.service sing-box.service >/dev/null
systemctl restart hybrid-proxy-firewall.service
systemctl reset-failed xray.service sing-box.service >/dev/null 2>&1 || true
systemctl restart xray.service
systemctl restart sing-box.service

show_service_diagnostics(){
  local service="$1"
  echo "----- $service 状态 -----" >&2
  systemctl --no-pager --full status "$service" >&2 || true
  echo "----- $service 最近日志 -----" >&2
  journalctl -u "$service" -n 100 --no-pager >&2 || true
}

wait_service_active(){
  local service="$1" i
  for i in $(seq 1 30); do
    if systemctl is-active --quiet "$service"; then
      return 0
    fi
    if systemctl is-failed --quiet "$service"; then
      show_service_diagnostics "$service"
      die "$service 启动失败"
    fi
    sleep 1
  done
  show_service_diagnostics "$service"
  die "$service 在 30 秒内未进入 active 状态"
}

wait_tcp_port(){
  local port="$1" service="$2" i
  for i in $(seq 1 30); do
    if ss -H -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$"{ok=1} END{exit !ok}'; then
      echo "TCP 端口 $port 已监听"
      return 0
    fi
    if ! systemctl is-active --quiet "$service"; then
      show_service_diagnostics "$service"
      die "$service 已退出，TCP 端口 $port 未监听"
    fi
    sleep 1
  done
  echo "----- 当前 TCP/UDP 监听 -----" >&2
  ss -lntup >&2 || true
  show_service_diagnostics "$service"
  die "TCP 端口 $port 在 30 秒内未监听"
}

wait_udp_port(){
  local port="$1" service="$2" i
  for i in $(seq 1 30); do
    if ss -H -lnu 2>/dev/null | awk -v p=":$port" '$4 ~ p"$"{ok=1} END{exit !ok}'; then
      echo "UDP 端口 $port 已监听"
      return 0
    fi
    if ! systemctl is-active --quiet "$service"; then
      show_service_diagnostics "$service"
      die "$service 已退出，UDP 端口 $port 未监听"
    fi
    sleep 1
  done
  echo "----- 当前 TCP/UDP 监听 -----" >&2
  ss -lntup >&2 || true
  show_service_diagnostics "$service"
  die "UDP 端口 $port 在 30 秒内未监听"
}

wait_service_active xray.service
wait_service_active sing-box.service

wait_tcp_port "$XRAY_VISION_PORT" xray.service
wait_tcp_port "$XRAY_PLAIN_PORT" xray.service
wait_tcp_port "$SS_AES_PORT" sing-box.service
wait_tcp_port "$SS2022_PORT" sing-box.service

wait_udp_port "$SS_AES_PORT" sing-box.service
wait_udp_port "$SS2022_PORT" sing-box.service
wait_udp_port "$HY2_PORT" sing-box.service
wait_udp_port "$HY2_OBFS_PORT" sing-box.service
wait_udp_port "$TUIC_PORT" sing-box.service

PATCH

tail -n +"$end_line" "$BASE_FILE" >>"$PATCHED_FILE"

# With pipefail enabled, `command | head -n1` may return 141 when the producer
# receives SIGPIPE after head exits. sed reads the full stream and avoids that.
sed -i 's/| head -n1/| sed -n "1p"/g; s/| head -n 1/| sed -n "1p"/g' "$PATCHED_FILE"

chmod 700 "$PATCHED_FILE"
bash -n "$PATCHED_FILE"
exec bash "$PATCHED_FILE" "$@"
