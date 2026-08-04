#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Hotfix launcher for the full hybrid deployer.
# The base deployer used Type=simple services and checked sockets immediately
# after systemctl restart. systemd can report active before Xray/sing-box have
# finished opening their sockets, causing a false "port not listening" rollback.

BASE_COMMIT="1a16035bd9aceb9ba126cdeca523209e9955b9e6"
BASE_URL="https://raw.githubusercontent.com/Fuqianglv/Sing-Box-Plus/${BASE_COMMIT}/hybrid-deploy.sh"
TMP="$(mktemp /tmp/hybrid-deploy-fixed.XXXXXX.sh)"

cleanup(){
  rm -f "$TMP"
}
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 --retry-all-errors --connect-timeout 15 "$BASE_URL" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$TMP" "$BASE_URL"
else
  echo "[ERROR] 系统缺少 curl/wget" >&2
  exit 1
fi

# Type=simple: restart 返回时，服务进程可能尚未完成监听。
# 在端口验证前等待 5 秒，避免把正常启动误判为失败。
sed -i '/^systemctl restart xray\.service sing-box\.service$/a sleep 5' "$TMP"

# 如果端口检查仍失败，先打印服务状态和日志再触发原有回滚。
sed -i '/^for p in "\$XRAY_VISION_PORT"/i\
echo "等待服务套接字就绪完成"\
systemctl --no-pager --full status xray.service sing-box.service || true\
ss -lntup || true' "$TMP"

bash -n "$TMP"
exec bash "$TMP" "$@"
