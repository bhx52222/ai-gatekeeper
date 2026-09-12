#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

HOST_HTTP_PROXY="${HOST_HTTP_PROXY:-http://127.0.0.1:6152}"
TARGET_COUNTRY="${TARGET_COUNTRY:-US}"
TIMEOUT="${TIMEOUT:-20}"

echo "网页 / 桌面版 Surge 出口门禁"
echo "HOST_HTTP_PROXY=$HOST_HTTP_PROXY"
echo

for port in 6152 6153; do
  if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    echo "失败：Surge 端口 127.0.0.1:$port 不可连接。" >&2
    exit 1
  fi
done

targets=(
  "Claude Web|claude.ai"
  "Anthropic API|api.anthropic.com"
  "Anthropic Console|console.anthropic.com"
  "ChatGPT Web|chatgpt.com"
  "OpenAI API|api.openai.com"
  "OpenAI Platform|platform.openai.com"
)

fail=0
seen_ips=""
printf "%-20s %-28s %-16s %-4s %-6s %s\n" "目标" "域名" "出口IP" "国家" "机房" "状态"
for item in "${targets[@]}"; do
  IFS='|' read -r name host <<< "$item"
  trace=""
  for attempt in 1 2; do
    trace="$(curl --proxy "$HOST_HTTP_PROXY" -fsS --max-time "$TIMEOUT" "https://${host}/cdn-cgi/trace" 2>/dev/null || true)"
    [[ -n "$trace" ]] && break
    sleep 1
  done
  ip="$(printf '%s\n' "$trace" | awk -F= '$1=="ip"{print $2; exit}')"
  loc="$(printf '%s\n' "$trace" | awk -F= '$1=="loc"{print $2; exit}')"
  colo="$(printf '%s\n' "$trace" | awk -F= '$1=="colo"{print $2; exit}')"
  status="正常"
  if [[ -z "$ip" ]]; then status="无法检测"; fail=1
  elif [[ "$loc" != "$TARGET_COUNTRY" ]]; then status="国家不符"; fail=1
  fi
  [[ -n "$ip" ]] && seen_ips="${seen_ips}${ip}"$'\n'
  printf "%-20s %-28s %-16s %-4s %-6s %s\n" "$name" "$host" "${ip:-unknown}" "${loc:-?}" "${colo:-?}" "$status"
done

unique_count="$(printf '%s' "$seen_ips" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
[[ "$unique_count" == "1" ]] || { echo "警告：AI 目标没有全部落到同一个出口 IP。"; fail=1; }

if [[ "$fail" == "0" ]]; then
  echo "网页 / 桌面版显式代理出口门禁通过。"
else
  echo "网页 / 桌面版显式代理出口门禁失败。"
  exit 1
fi
