#!/usr/bin/env bash
set -u

TIMEOUT="${TIMEOUT:-15}"
MANUAL_URL_TIMEOUT="${MANUAL_URL_TIMEOUT:-20}"
BROWSER_BACKGROUND="${BROWSER_BACKGROUND:-1}"
TARGET_COUNTRY="${TARGET_COUNTRY:-US}"
TARGET_TIMEZONE="${TARGET_TIMEZONE:-America/Los_Angeles}"
TARGET_LANGUAGE="${TARGET_LANGUAGE:-en-US}"
EXPECTED_IP="${EXPECTED_IP:-}"
MIN_SCORE="${MIN_SCORE:-85}"
BASE_DIR="${BASE_DIR:-$HOME/AI-US-Browsers}"
BROWSER="${BROWSER:-chrome}"
CHECK_ONLY=0
SKIP_MANUAL=0
ALLOW_RISK="${ALLOW_RISK:-0}"

TARGETS=(
  "claude.ai"
  "api.anthropic.com"
  "console.anthropic.com"
  "chatgpt.com"
  "api.openai.com"
  "platform.openai.com"
  "auth.openai.com"
  "ios.chat.openai.com"
)

MANUAL_TEST_URLS=(
  "https://ipinfo.io/"
  "https://browserleaks.com/dns"
  "https://dnsleaktest.com/"
  "https://browserleaks.com/webrtc"
  "https://browserleaks.com/javascript"
)

usage() {
  cat <<'EOF'
用法：
  ./ai_preflight_open_cn.sh
  ./ai_preflight_open_cn.sh --check-only
  EXPECTED_IP=203.0.113.10 ./ai_preflight_open_cn.sh
  ALLOW_RISK=1 ./ai_preflight_open_cn.sh

参数：
  --check-only    只做自动检测，不打开浏览器检测页。
  --skip-manual   跳过浏览器人工确认页。

环境变量：
  EXPECTED_IP       可选，要求 Claude/OpenAI 必须走这个出口 IP。
  MIN_SCORE         默认 85，住宅/移动 ISP 出口通过阈值。
  TARGET_COUNTRY    默认 US。
  TARGET_TIMEZONE   默认 America/Los_Angeles。
  TARGET_LANGUAGE   默认 en-US。
  BROWSER           chrome 或 edge，默认 chrome。
  ALLOW_RISK=1      IP 纯净度不达标时，允许给出“风险接受后可打开”的结论。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --skip-manual) SKIP_MANUAL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1"; usage; exit 2 ;;
  esac
  shift
done

hr() {
  printf '\n%s\n' "------------------------------------------------------------"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少依赖：$1"
    exit 1
  }
}

ask_yes() {
  local prompt="$1"
  printf "%s [y/N]: " "$prompt"
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" || "$reply" == "是" ]]
}

json_get() {
  jq -r "if ($1) == null then empty else ($1 | tostring) end" 2>/dev/null
}

field_from_trace() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k {print $2; exit}'
}

trace_host() {
  local host="$1"
  local trace i
  for i in 1 2 3; do
    trace="$(curl -sS --max-time "$TIMEOUT" "https://${host}/cdn-cgi/trace" 2>/dev/null || true)"
    if printf '%s\n' "$trace" | grep -q '^ip='; then
      printf '%s\n' "$trace"
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "$trace"
}

fetch_url_retry() {
  local url="$1"
  local body i
  for i in 1 2 3; do
    body="$(curl -sS --max-time "$TIMEOUT" "$url" 2>/dev/null || true)"
    if [[ -n "$body" ]]; then
      printf '%s\n' "$body"
      return 0
    fi
    sleep 1
  done
  printf '%s\n' "$body"
}

filter_reachable_manual_urls() {
  local url code reachable=()
  for url in "$@"; do
    printf "检测网页可达性（%ss 超时）：%s ... " "$MANUAL_URL_TIMEOUT" "$url" >&2
    code="$(curl -L -sS -o /dev/null -w '%{http_code}' --max-time "$MANUAL_URL_TIMEOUT" "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^(2|3|4)[0-9][0-9]$ ]]; then
      echo "可打开 HTTP $code" >&2
      reachable+=("$url")
    else
      echo "跳过（无法连接或超时，HTTP=${code:-无}）" >&2
    fi
  done
  printf '%s\n' "${reachable[@]}"
}

browser_binary() {
  case "$BROWSER" in
    chrome) echo "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ;;
    edge) echo "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" ;;
    *) echo "不支持的浏览器：$BROWSER" >&2; return 1 ;;
  esac
}

browser_dir() {
  case "$BROWSER" in
    chrome) echo "$BASE_DIR/Chrome-Claude-OpenAI" ;;
    edge) echo "$BASE_DIR/Edge-Claude-OpenAI" ;;
    *) return 1 ;;
  esac
}

write_browser_preferences() {
  local user_data_dir="$1"
  local prefs="$user_data_dir/Default/Preferences"
  mkdir -p "$user_data_dir/Default"
  [[ -f "$prefs" ]] || printf '{}\n' > "$prefs"

  /usr/bin/python3 - "$prefs" "$TARGET_LANGUAGE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
lang = sys.argv[2]
try:
    data = json.loads(path.read_text() or "{}")
except json.JSONDecodeError:
    data = {}

data.setdefault("intl", {})["accept_languages"] = f"{lang},en"
data.setdefault("webkit", {}).setdefault("webprefs", {})["default_encoding"] = "UTF-8"
data["webrtc"] = {
    "ip_handling_policy": "disable_non_proxied_udp",
    "multiple_routes_enabled": False,
    "nonproxied_udp_enabled": False,
}

path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
}

open_browser_urls() {
  local bin user_data_dir
  bin="$(browser_binary)" || return 1
  user_data_dir="$(browser_dir)" || return 1
  if [[ ! -x "$bin" ]]; then
    echo "找不到浏览器：$bin"
    return 1
  fi

  write_browser_preferences "$user_data_dir"
  "$bin" \
    --user-data-dir="$user_data_dir" \
    --profile-directory=Default \
    --no-first-run \
    --no-default-browser-check \
    --lang="$TARGET_LANGUAGE" \
    --force-webrtc-ip-handling-policy=disable_non_proxied_udp \
    --new-window \
    "$@" >/dev/null 2>&1 &

  if [[ "$BROWSER_BACKGROUND" == "1" ]]; then
    (
      sleep 2
      case "$BROWSER" in
        chrome) osascript -e 'tell application "System Events" to set visible of process "Google Chrome" to false' >/dev/null 2>&1 || true ;;
        edge) osascript -e 'tell application "System Events" to set visible of process "Microsoft Edge" to false' >/dev/null 2>&1 || true ;;
      esac
    ) &
  fi
}

check_route() {
  local tmp trace host ip loc colo http tls ip_count
  tmp="$(mktemp)"
  ROUTE_OK=1

  hr
  echo "第 1/6 步：检测 Claude/OpenAI 实际分流出口"
  for host in "${TARGETS[@]}"; do
    trace="$(trace_host "$host")"
    ip="$(printf '%s\n' "$trace" | field_from_trace ip)"
    loc="$(printf '%s\n' "$trace" | field_from_trace loc)"
    colo="$(printf '%s\n' "$trace" | field_from_trace colo)"
    http="$(printf '%s\n' "$trace" | field_from_trace http)"
    tls="$(printf '%s\n' "$trace" | field_from_trace tls)"

    if [[ -z "$ip" ]]; then
      printf "%-24s 无法获取 trace\n" "$host"
      ROUTE_OK=0
      continue
    fi

    printf "%-24s ip=%-15s 国家=%-3s 机房=%-5s http=%-7s tls=%s" "$host" "$ip" "$loc" "$colo" "$http" "$tls"
    if [[ "$loc" != "$TARGET_COUNTRY" ]]; then
      printf "  失败：国家不符"
      ROUTE_OK=0
    fi
    if [[ -n "$EXPECTED_IP" && "$ip" != "$EXPECTED_IP" ]]; then
      printf "  失败：不是指定 IP %s" "$EXPECTED_IP"
      ROUTE_OK=0
    fi
    printf "\n"
    echo "$ip" >> "$tmp"
  done

  UNIQUE_IPS="$(sort -u "$tmp")"
  rm -f "$tmp"

  if [[ -z "$UNIQUE_IPS" ]]; then
    ROUTE_OK=0
  fi

  ip_count="$(printf '%s\n' "$UNIQUE_IPS" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$ip_count" != "1" ]]; then
    echo "失败：Claude/OpenAI 相关域名没有使用同一个稳定出口 IP。"
    printf '%s\n' "$UNIQUE_IPS"
    ROUTE_OK=0
  fi
}

score_single_ip() {
  local ip="$1"
  local ipapi proxycheck ipapi_ok proxycheck_ok
  local country city tz is_dc is_proxy is_vpn is_tor is_abuser company company_type company_abuse asn asn_org asn_type asn_abuse
  local pc_proxy pc_type pc_risk reasons score verdict

  ipapi="$(fetch_url_retry "https://api.ipapi.is/?q=${ip}")"
  proxycheck="$(fetch_url_retry "https://proxycheck.io/v2/${ip}?vpn=1&asn=1&risk=1&seen=1&days=30&tag=ai-preflight-cn")"
  ipapi_ok="$(printf '%s' "$ipapi" | jq -e '.ip? != null' >/dev/null 2>&1; echo $?)"
  proxycheck_ok="$(printf '%s' "$proxycheck" | jq -e '.status? == "ok"' >/dev/null 2>&1; echo $?)"

  if [[ "$ipapi_ok" != "0" ]]; then
    echo "失败：无法查询 IP 情报：$ip"
    IP_QUALITY_OK=0
    return
  fi

  country="$(printf '%s' "$ipapi" | json_get '.location.country_code')"
  city="$(printf '%s' "$ipapi" | json_get '.location.city')"
  tz="$(printf '%s' "$ipapi" | json_get '.location.timezone')"
  is_dc="$(printf '%s' "$ipapi" | json_get '.is_datacenter')"
  is_proxy="$(printf '%s' "$ipapi" | json_get '.is_proxy')"
  is_vpn="$(printf '%s' "$ipapi" | json_get '.is_vpn')"
  is_tor="$(printf '%s' "$ipapi" | json_get '.is_tor')"
  is_abuser="$(printf '%s' "$ipapi" | json_get '.is_abuser')"
  company="$(printf '%s' "$ipapi" | json_get '.company.name')"
  company_type="$(printf '%s' "$ipapi" | json_get '.company.type')"
  company_abuse="$(printf '%s' "$ipapi" | json_get '.company.abuser_score')"
  asn="$(printf '%s' "$ipapi" | json_get '.asn.asn')"
  asn_org="$(printf '%s' "$ipapi" | json_get '.asn.org')"
  asn_type="$(printf '%s' "$ipapi" | json_get '.asn.type')"
  asn_abuse="$(printf '%s' "$ipapi" | json_get '.asn.abuser_score')"

  pc_proxy=""
  pc_type=""
  pc_risk=""
  if [[ "$proxycheck_ok" == "0" ]]; then
    pc_proxy="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].proxy // empty')"
    pc_type="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].type // empty')"
    pc_risk="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].risk // empty')"
  fi

  score=100
  reasons=()
  if [[ "$country" != "$TARGET_COUNTRY" ]]; then score=$((score - 35)); reasons+=("国家=${country:-未知}"); fi
  if [[ "$is_dc" == "true" ]]; then score=$((score - 30)); reasons+=("数据中心=true"); fi
  if [[ "$asn_type" == "hosting" || "$company_type" == "hosting" ]]; then score=$((score - 20)); reasons+=("hosting/asn_type=${asn_type:-未知}, company_type=${company_type:-未知}"); fi
  if [[ "$is_proxy" == "true" || "$pc_proxy" == "yes" ]]; then score=$((score - 35)); reasons+=("代理=true"); fi
  if [[ "$is_vpn" == "true" ]]; then score=$((score - 35)); reasons+=("VPN=true"); fi
  if [[ "$is_tor" == "true" ]]; then score=$((score - 50)); reasons+=("Tor=true"); fi
  if [[ "$is_abuser" == "true" ]]; then score=$((score - 25)); reasons+=("滥用标记=true"); fi
  if (( score < 0 )); then score=0; fi

  if (( score >= MIN_SCORE )) && [[ "$is_dc" != "true" && "$asn_type" != "hosting" && "$company_type" != "hosting" ]]; then
    verdict="通过"
  elif (( score >= 65 )); then
    verdict="谨慎可用"
  else
    verdict="失败"
  fi

  echo "IP：$ip"
  echo "  位置：${country:-未知} / ${city:-未知} / ${tz:-未知}"
  echo "  ASN：AS${asn:-未知} ${asn_org:-未知} 类型=${asn_type:-未知} 滥用分=${asn_abuse:-未知}"
  echo "  公司：${company:-未知} 类型=${company_type:-未知} 滥用分=${company_abuse:-未知}"
  echo "  风险标记：数据中心=${is_dc:-未知} 代理=${is_proxy:-未知} VPN=${is_vpn:-未知} Tor=${is_tor:-未知} 滥用=${is_abuser:-未知}"
  echo "  ProxyCheck：代理=${pc_proxy:-未知} 类型=${pc_type:-未知} 风险=${pc_risk:-未知}"
  echo "  评分：$score/100  结论：$verdict"
  if ((${#reasons[@]})); then
    local IFS="，"
    echo "  扣分原因：${reasons[*]}"
  fi

  if [[ "$verdict" == "通过" ]]; then
    IP_QUALITY_OK=1
  else
    IP_QUALITY_OK=0
  fi
}

check_ip_quality() {
  IP_QUALITY_OK=1
  hr
  echo "第 2/6 步：检测出口 IP 纯净度"
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    score_single_ip "$ip"
  done <<< "$UNIQUE_IPS"
}

check_dns() {
  DNS_OK=1
  hr
  echo "第 3/6 步：检测系统 DNS"
  local dns nameservers risky
  dns="$(scutil --dns 2>/dev/null || true)"
  nameservers="$(printf '%s\n' "$dns" | awk '/nameserver\[[0-9]+\]/ {print $3}' | sort -u)"
  echo "系统 DNS："
  printf '%s\n' "$nameservers" | sed 's/^/  /'

  risky="$(printf '%s\n' "$nameservers" | grep -E '^(114\.|223\.5\.|223\.6\.|119\.29\.|180\.76\.|1\.12\.|101\.226\.|202\.96\.|218\.|219\.|221\.)' || true)"
  if [[ -n "$risky" ]]; then
    echo "失败：检测到中国大陆或运营商 DNS："
    printf '%s\n' "$risky" | sed 's/^/  /'
    DNS_OK=0
  fi

  if printf '%s\n' "$nameservers" | grep -q '^198\.18\.'; then
    echo "通过：检测到 198.18.0.0/15 的 TUN/分流 DNS。"
  fi
  echo "提示：浏览器 DNS 泄露仍需在网页检测页人工确认。"
}

check_system_locale() {
  LOCALE_OK=1
  hr
  echo "第 4/6 步：检测系统时区和语言"
  local tz langs locale
  tz="$(readlink /etc/localtime 2>/dev/null | sed 's#^/var/db/timezone/zoneinfo/##' || true)"
  langs="$(defaults read -g AppleLanguages 2>/dev/null | tr -d '()", ' | sed '/^$/d' | head -n 1 || true)"
  locale="$(defaults read -g AppleLocale 2>/dev/null || true)"

  echo "时区：${tz:-未知}"
  echo "主语言：${langs:-未知}"
  echo "地区：${locale:-未知}"

  if [[ "$tz" != "$TARGET_TIMEZONE" ]]; then
    echo "失败：时区应为 $TARGET_TIMEZONE"
    LOCALE_OK=0
  fi
  if [[ "$langs" != "$TARGET_LANGUAGE" ]]; then
    echo "失败：主语言应为 $TARGET_LANGUAGE"
    LOCALE_OK=0
  fi
  if [[ "$locale" != en_US* ]]; then
    echo "失败：地区应为 en_US"
    LOCALE_OK=0
  fi
}

check_ipv6() {
  IPV6_OK=1
  hr
  echo "第 5/6 步：检测 IPv6 直连泄露"
  local v6
  v6="$(curl -6 -sS --max-time "$TIMEOUT" https://ifconfig.co 2>/dev/null || true)"
  if [[ -n "$v6" && "$v6" == *:* ]]; then
    echo "失败：检测到 IPv6 可直连：$v6"
    IPV6_OK=0
  else
    echo "通过：curl -6 没有拿到直连 IPv6。"
  fi
}

manual_browser_gate() {
  MANUAL_OK=1
  if [[ "$CHECK_ONLY" == "1" || "$SKIP_MANUAL" == "1" ]]; then
    return
  fi

  hr
  echo "第 6/6 步：浏览器人工确认"
  echo "将使用专用浏览器 profile 打开这些检测页："
  printf '  %s\n' "${MANUAL_TEST_URLS[@]}"
  echo
  echo "请在浏览器里逐条确认："
  echo "  [1] IP 页面显示的出口 IP 与第 1 步一致。"
  echo "  [2] DNS 检测页没有中国大陆、运营商、114、阿里、腾讯 DNS。"
  echo "  [3] WebRTC 没有暴露真实公网 IP、中国 IP 或异常 IPv6。"
  echo "  [4] JavaScript 显示时区 ${TARGET_TIMEZONE}，语言为 ${TARGET_LANGUAGE}/en。"

  if ! ask_yes "现在打开浏览器检测页吗"; then
    MANUAL_OK=0
    return
  fi

  local reachable_urls=() url
  while IFS= read -r url; do
    [[ -n "$url" ]] && reachable_urls+=("$url")
  done < <(filter_reachable_manual_urls "${MANUAL_TEST_URLS[@]}")
  if ((${#reachable_urls[@]} == 0)); then
    echo "所有检测网页都无法在 ${MANUAL_URL_TIMEOUT}s 内连接，已自动跳过浏览器人工确认页。"
    MANUAL_OK=0
    return
  fi

  open_browser_urls "${reachable_urls[@]}" || {
    MANUAL_OK=0
    return
  }

  echo
  if ask_yes "以上四项浏览器检查是否全部通过"; then
    MANUAL_OK=1
  else
    MANUAL_OK=0
  fi
}

main() {
  need curl
  need jq
  need awk
  need sort
  need uniq

  echo "Claude/OpenAI 打开前强制检测"
  echo "目标国家：$TARGET_COUNTRY"
  echo "目标时区：$TARGET_TIMEZONE"
  echo "目标语言：$TARGET_LANGUAGE"
  [[ -n "$EXPECTED_IP" ]] && echo "指定出口 IP：$EXPECTED_IP"
  echo "最低纯净度分数：$MIN_SCORE"

  check_route
  check_ip_quality
  check_dns
  check_system_locale
  check_ipv6
  manual_browser_gate

  hr
  echo "最终结论"
  echo "分流出口：  $([[ "$ROUTE_OK" == "1" ]] && echo 通过 || echo 失败)"
  echo "IP 纯净度： $([[ "$IP_QUALITY_OK" == "1" ]] && echo 通过 || echo 失败)"
  echo "DNS：       $([[ "$DNS_OK" == "1" ]] && echo 通过 || echo 失败)"
  echo "时区语言：  $([[ "$LOCALE_OK" == "1" ]] && echo 通过 || echo 失败)"
  echo "IPv6：      $([[ "$IPV6_OK" == "1" ]] && echo 通过 || echo 失败)"
  echo "浏览器：    $([[ "${MANUAL_OK:-1}" == "1" ]] && echo 通过 || echo 失败)"

  if [[ "$ROUTE_OK" == "1" && "$IP_QUALITY_OK" == "1" && "$DNS_OK" == "1" && "$LOCALE_OK" == "1" && "$IPV6_OK" == "1" && "${MANUAL_OK:-1}" == "1" ]]; then
    echo "通过：现在可以手动打开 Claude/OpenAI 网页或 App。"
    exit 0
  fi

  if [[ "$ALLOW_RISK" == "1" && "$ROUTE_OK" == "1" && "$DNS_OK" == "1" && "$LOCALE_OK" == "1" && "$IPV6_OK" == "1" && "${MANUAL_OK:-1}" == "1" ]]; then
    echo "谨慎通过：IP 纯净度未达标，但你设置了 ALLOW_RISK=1。现在可以在接受风险的前提下手动打开 Claude/OpenAI 网页或 App。"
    exit 0
  fi

  echo "阻止：检测未通过。暂时不要打开 Claude/OpenAI 网页或 App。"
  echo "只有在你明确接受非住宅/不完美 IP 风险时，才使用 ALLOW_RISK=1。"
  exit 3
}

main "$@"
