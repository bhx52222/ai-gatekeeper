#!/usr/bin/env bash
set -u

echo "Claude Code SafeRoom 容器检测"
echo "user=$(id -un) uid=$(id -u)"
echo "pwd=$(pwd)"
echo "date=$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "LANG=${LANG:-}"
echo "LC_ALL=${LC_ALL:-}"
echo "TZ=${TZ:-}"
echo "HTTP_PROXY=${HTTP_PROXY:-}"
echo "HTTPS_PROXY=${HTTPS_PROXY:-}"
echo "ALL_PROXY=${ALL_PROXY:-}"
echo "NO_PROXY=${NO_PROXY:-}"
echo

echo "工具版本"
node --version 2>/dev/null || true
npm --version 2>/dev/null || true
git --version 2>/dev/null || true
claude --version 2>/dev/null || echo "claude command not available"
echo

echo "DNS"
cat /etc/resolv.conf
echo

echo "出口 IP"
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time "${TIMEOUT:-20}" https://ipinfo.io/json || true
else
  echo "curl not available"
fi
echo

echo "AI 域名出口快速检测"
for host in claude.ai api.anthropic.com chatgpt.com api.openai.com platform.openai.com; do
  trace="$(curl -fsS --max-time "${TIMEOUT:-20}" "https://${host}/cdn-cgi/trace" 2>/dev/null || true)"
  ip="$(printf '%s\n' "$trace" | awk -F= '$1=="ip"{print $2; exit}')"
  loc="$(printf '%s\n' "$trace" | awk -F= '$1=="loc"{print $2; exit}')"
  colo="$(printf '%s\n' "$trace" | awk -F= '$1=="colo"{print $2; exit}')"
  printf "%-22s %-16s %-4s %s\n" "$host" "${ip:-unknown}" "${loc:-?}" "${colo:-?}"
done
echo

echo "Claude 配置目录"
echo "${CLAUDE_CONFIG_DIR:-/home/node/.claude}"
ls -la "${CLAUDE_CONFIG_DIR:-/home/node/.claude}" 2>/dev/null || true

