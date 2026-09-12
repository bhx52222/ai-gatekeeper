#!/usr/bin/env bash
set -euo pipefail

TIMEOUT="${TIMEOUT:-20}"
TARGET_COUNTRY="${TARGET_COUNTRY:-US}"
EXPECTED_IP="${EXPECTED_IP:-}"
MIN_SCORE="${MIN_SCORE:-85}"

AI_TRACE_TARGETS=(
  "Claude Web|claude.ai"
  "Anthropic API|api.anthropic.com"
  "Anthropic Console|console.anthropic.com"
  "ChatGPT Web|chatgpt.com"
  "OpenAI API|api.openai.com"
  "OpenAI Platform|platform.openai.com"
  "OpenAI Auth|auth.openai.com"
  "ChatGPT iOS|ios.chat.openai.com"
)

SERVICE_CHECKS=(
  "Claude|AI|https://claude.ai/"
  "Anthropic API|AI|https://api.anthropic.com/"
  "Anthropic Console|AI|https://console.anthropic.com/"
  "ChatGPT|AI|https://chatgpt.com/"
  "OpenAI API|AI|https://api.openai.com/v1/models"
  "OpenAI Platform|AI|https://platform.openai.com/"
  "GitHub|平台|https://github.com/"
  "Google Search|平台|https://www.google.com/generate_204"
)

service_verdict() {
  local code="$1" url="$2" category="$3"
  if [[ "$code" == "000" || -z "$code" ]]; then
    echo "失败"
  elif [[ "$code" =~ ^(200|204|301|302|303|307|308)$ ]]; then
    echo "可达"
  elif [[ "$category" == "AI" && "$code" == "403" ]]; then
    echo "可达-浏览器复核"
  elif [[ "$code" =~ ^(401|403)$ && "$url" == *"api.openai.com"* ]]; then
    echo "可达-需认证"
  elif [[ "$code" =~ ^(401|403)$ && "$url" == *"api.anthropic.com"* ]]; then
    echo "可达-需认证"
  elif [[ "$code" == "451" ]]; then
    echo "地区屏蔽"
  else
    echo "异常"
  fi
}

echo "容器内 AI IP 纯净度快检"
echo "目标国家: ${TARGET_COUNTRY}"
[[ -n "$EXPECTED_IP" ]] && echo "预期出口: ${EXPECTED_IP}"
echo

route_fail=0
seen_ips=""
printf "%-20s %-28s %-16s %-4s %-6s %s\n" "目标" "域名" "出口IP" "国家" "机房" "状态"
for item in "${AI_TRACE_TARGETS[@]}"; do
  IFS='|' read -r name host <<< "$item"
  trace="$(curl -fsS --max-time "$TIMEOUT" "https://${host}/cdn-cgi/trace" 2>/dev/null || true)"
  ip="$(printf '%s\n' "$trace" | awk -F= '$1=="ip"{print $2; exit}')"
  loc="$(printf '%s\n' "$trace" | awk -F= '$1=="loc"{print $2; exit}')"
  colo="$(printf '%s\n' "$trace" | awk -F= '$1=="colo"{print $2; exit}')"
  status="正常"
  if [[ -z "$ip" ]]; then
    status="无法检测"
    route_fail=1
  elif [[ "$loc" != "$TARGET_COUNTRY" ]]; then
    status="国家不符"
    route_fail=1
  elif [[ -n "$EXPECTED_IP" && "$ip" != "$EXPECTED_IP" ]]; then
    status="IP不符"
    route_fail=1
  fi
  [[ -n "$ip" ]] && seen_ips="${seen_ips}${ip}"$'\n'
  printf "%-20s %-28s %-16s %-4s %-6s %s\n" "$name" "$host" "${ip:-unknown}" "${loc:-?}" "${colo:-?}" "$status"
done

unique_count="$(printf '%s' "$seen_ips" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
if [[ "$unique_count" != "1" ]]; then
  echo
  echo "警告: AI 目标没有全部落到同一个出口 IP。"
  route_fail=1
fi

echo
echo "平台连通检测（后台 HTTP，不等于真实浏览器登录结果）"
printf "%-20s %-8s %-14s %s\n" "平台" "类别" "状态" "HTTP"
for item in "${SERVICE_CHECKS[@]}"; do
  IFS='|' read -r name category url <<< "$item"
  code="$(curl -L -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>/dev/null || true)"
  verdict="$(service_verdict "${code:-000}" "$url" "$category")"
  printf "%-20s %-8s %-14s %s\n" "$name" "$category" "$verdict" "${code:-000}"
done

echo
if [[ "$route_fail" == "0" ]]; then
  echo "结论: 容器内 AI 出口快检通过。仍需结合主机浏览器泄露检测和账号行为一致性判断。"
else
  echo "结论: 容器内 AI 出口存在风险，不建议直接登录核心账号。"
  exit 1
fi

