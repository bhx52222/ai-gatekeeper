#!/usr/bin/env bash
set -u

TIMEOUT="${TIMEOUT:-15}"
TARGET_COUNTRY="${TARGET_COUNTRY:-US}"
TARGET_TIMEZONE="${TARGET_TIMEZONE:-America/Los_Angeles}"
TARGET_LANGUAGE="${TARGET_LANGUAGE:-en-US}"
TARGET_LOCALE="${TARGET_LOCALE:-en_US}"
MIN_SCORE="${MIN_SCORE:-85}"
BASE_DIR="${BASE_DIR:-$HOME/AI-US-Browsers}"
CHROME_DIR="${CHROME_DIR:-$BASE_DIR/Chrome-Claude-OpenAI}"
EDGE_DIR="${EDGE_DIR:-$BASE_DIR/Edge-Claude-OpenAI}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1 1.0.0.1}"
RESTORE_TIMEZONE="${RESTORE_TIMEZONE:-Asia/Shanghai}"
RESTORE_LANGUAGE="${RESTORE_LANGUAGE:-zh-Hans-CN}"
RESTORE_LOCALE="${RESTORE_LOCALE:-zh_CN}"
RESTORE_MEASUREMENT_UNITS="${RESTORE_MEASUREMENT_UNITS:-Centimeters}"
RESTORE_TEMPERATURE_UNIT="${RESTORE_TEMPERATURE_UNIT:-Celsius}"
CHECK_ONLY=0
YES=0
RESTORE_MODE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_CN="$SCRIPT_DIR/ai_preflight_open_cn.sh"

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

ISSUES=()
MANUAL_ITEMS=()
FIX_KEYS=()
FIX_LABELS=()
UNIQUE_IPS=""
ACTIVE_SERVICES=""
DNS_RISKY=""
IPV6_VALUE=""

usage() {
  cat <<'EOF'
用法：
  ./ai_preflight_fix_cn.sh
  ./ai_preflight_fix_cn.sh --check-only
  ./ai_preflight_fix_cn.sh --yes
  ./ai_preflight_fix_cn.sh --restore
  ./ai_preflight_fix_cn.sh --restore --yes

参数：
  --check-only   只做全面检测和问题列表，不弹窗确认，不修改系统。
  --yes          跳过弹窗确认，直接执行可自动修复项。
  --restore      一键恢复原本中文/中国区/常规网络环境。

环境变量：
  TARGET_TIMEZONE   默认 America/Los_Angeles
  TARGET_LANGUAGE   默认 en-US
  TARGET_LOCALE     默认 en_US
  BASE_DIR          默认 ~/AI-US-Browsers
  DNS_SERVERS       默认 "1.1.1.1 1.0.0.1"
  RESTORE_TIMEZONE          恢复时区，默认 Asia/Shanghai
  RESTORE_LANGUAGE          恢复语言，默认 zh-Hans-CN
  RESTORE_LOCALE            恢复地区，默认 zh_CN
  RESTORE_MEASUREMENT_UNITS 恢复长度单位，默认 Centimeters
  RESTORE_TEMPERATURE_UNIT  恢复温度单位，默认 Celsius
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --yes) YES=1 ;;
    --restore) RESTORE_MODE=1 ;;
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

add_issue() {
  ISSUES+=("$1")
}

add_manual() {
  MANUAL_ITEMS+=("$1")
}

add_fix() {
  local key="$1"
  local label="$2"
  FIX_KEYS+=("$key")
  FIX_LABELS+=("$label")
}

json_get() {
  jq -r "if ($1) == null then empty else ($1 | tostring) end" 2>/dev/null
}

field_from_trace() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k {print $2; exit}'
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

trace_host() {
  local host="$1"
  fetch_url_retry "https://${host}/cdn-cgi/trace"
}

active_network_services() {
  local service info
  networksetup -listallnetworkservices 2>/dev/null | sed '1d' | grep -v '^\*' | while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    info="$(networksetup -getinfo "$service" 2>/dev/null || true)"
    if printf '%s\n' "$info" | grep -Eq 'IP address: ([0-9]{1,3}\.){3}[0-9]{1,3}|IPv6 IP address: [0-9a-fA-F:]+'; then
      printf '%s\n' "$service"
    fi
  done
}

dns_nameservers() {
  scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ {print $3}' | sort -u
}

detect_proxy_clients() {
  ps aux 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /Surge|Clash|ClashX|Clash Mi|mihomo|clash-meta/ && !/awk/ {print $0}' | sed 's/^/  /' || true
}

run_cmd() {
  printf "执行："
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

show_restore_snapshot() {
  hr
  echo "当前系统与网络状态"
  echo "系统时区：$(readlink /etc/localtime 2>/dev/null | sed 's#^/var/db/timezone/zoneinfo/##' || true)"
  echo "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
  echo "AppleLanguages："
  defaults read -g AppleLanguages 2>/dev/null || true
  echo "AppleLocale：$(defaults read -g AppleLocale 2>/dev/null || true)"
  echo "AppleMeasurementUnits：$(defaults read -g AppleMeasurementUnits 2>/dev/null || true)"
  echo "AppleMetricUnits：$(defaults read -g AppleMetricUnits 2>/dev/null || true)"
  echo "AppleTemperatureUnit：$(defaults read -g AppleTemperatureUnit 2>/dev/null || true)"
  echo
  echo "活跃网络服务："
  active_network_services | sed 's/^/  /' || true
  echo
  echo "当前 DNS："
  dns_nameservers | sed 's/^/  /' || true
}

confirm_restore() {
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo
    echo "当前为 --check-only，只显示恢复目标，不执行修改。"
    return 1
  fi
  if [[ "$YES" == "1" ]]; then
    echo
    echo "--yes 已启用，直接执行恢复。"
    return 0
  fi

  local text
  text="确认恢复原本中文/中国区/常规网络环境吗？

将执行：
- 时区：${RESTORE_TIMEZONE}
- 语言：${RESTORE_LANGUAGE}
- 地区：${RESTORE_LOCALE}
- 单位：Metric / ${RESTORE_MEASUREMENT_UNITS} / ${RESTORE_TEMPERATURE_UNIT}
- 活跃网络服务 IPv6：恢复 Automatic
- 活跃网络服务 DNS：恢复 Empty，即 DHCP/路由器自动分配

不会删除专用 Chrome/Edge profile，也不会修改 Clash/Surge 配置文件。"

  if command -v osascript >/dev/null 2>&1; then
    if osascript -e 'display dialog "'"$(printf '%s' "$text" | sed 's/"/\\"/g')"' " buttons {"取消", "确认恢复"} default button "确认恢复" cancel button "取消" with title "恢复系统与网络环境"' >/dev/null 2>&1; then
      return 0
    fi
    echo "用户取消，未执行恢复。"
    return 1
  fi

  printf "%s [y/N]: " "$text"
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" || "$reply" == "是" ]]
}

restore_locale() {
  hr
  echo "恢复：系统时区、语言、地区和单位"
  run_cmd sudo systemsetup -settimezone "$RESTORE_TIMEZONE"
  run_cmd defaults write -g AppleLanguages -array "$RESTORE_LANGUAGE"
  run_cmd defaults write -g AppleLocale "$RESTORE_LOCALE"
  run_cmd defaults write -g AppleMeasurementUnits -string "$RESTORE_MEASUREMENT_UNITS"
  run_cmd defaults write -g AppleMetricUnits -bool true
  run_cmd defaults write -g AppleTemperatureUnit -string "$RESTORE_TEMPERATURE_UNIT"
  echo "提示：语言、地区、单位完整生效通常需要退出登录或重启。"
}

restore_network() {
  hr
  echo "恢复：活跃网络服务 DNS 和 IPv6"
  local service services
  services="$(active_network_services)"
  if [[ -z "$services" ]]; then
    echo "没有找到活跃网络服务。未修改 DNS/IPv6。"
    return 0
  fi
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    run_cmd sudo networksetup -setv6automatic "$service"
    run_cmd sudo networksetup -setdnsservers "$service" Empty
  done <<< "$services"
  echo "提示：DNS 已恢复为 Empty，表示使用 DHCP/路由器/当前网络自动下发 DNS。"
}

restore_environment() {
  need networksetup
  need systemsetup
  need defaults
  need sed

  echo "Claude/OpenAI 环境改动的逆向恢复"
  echo "目标：恢复中文/中国区/常规网络环境。"
  echo "不会自动打开网页或 App。"
  show_restore_snapshot
  hr
  echo "恢复目标"
  echo "时区：$RESTORE_TIMEZONE"
  echo "语言：$RESTORE_LANGUAGE"
  echo "地区：$RESTORE_LOCALE"
  echo "单位：Metric / $RESTORE_MEASUREMENT_UNITS / $RESTORE_TEMPERATURE_UNIT"
  echo "网络：IPv6 Automatic，DNS Empty"

  if confirm_restore; then
    restore_locale
    restore_network
    hr
    echo "恢复后状态复查"
    show_restore_snapshot
  fi

  hr
  echo "完成。若恢复了语言/地区，请退出登录或重启后再确认菜单语言和地区格式。"
}

show_current_snapshot() {
  hr
  echo "当前状态快照"
  echo "模式：$([[ "$CHECK_ONLY" == "1" ]] && echo 只检测 || echo 检测后确认修复)"
  echo "目标时区：$TARGET_TIMEZONE"
  echo "目标语言：$TARGET_LANGUAGE"
  echo "目标地区：$TARGET_LOCALE"
  echo "专用 Chrome profile：$CHROME_DIR"
  echo "专用 Edge profile：$EDGE_DIR"
  echo
  echo "系统时区：$(readlink /etc/localtime 2>/dev/null | sed 's#^/var/db/timezone/zoneinfo/##' || true)"
  echo "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
  echo "AppleLanguages："
  defaults read -g AppleLanguages 2>/dev/null || true
  echo "AppleLocale：$(defaults read -g AppleLocale 2>/dev/null || true)"
  echo "AppleMeasurementUnits：$(defaults read -g AppleMeasurementUnits 2>/dev/null || true)"
  echo "AppleMetricUnits：$(defaults read -g AppleMetricUnits 2>/dev/null || true)"
  echo "AppleTemperatureUnit：$(defaults read -g AppleTemperatureUnit 2>/dev/null || true)"
}

browser_profile_ok() {
  local prefs="$1"
  [[ -f "$prefs" ]] || return 1
  /usr/bin/python3 - "$prefs" "$TARGET_LANGUAGE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
lang = sys.argv[2]
try:
    data = json.loads(path.read_text() or "{}")
except Exception:
    sys.exit(1)

webrtc = data.get("webrtc", {})
langs = data.get("intl", {}).get("accept_languages", "")
ok = (
    webrtc.get("ip_handling_policy") == "disable_non_proxied_udp"
    and webrtc.get("multiple_routes_enabled") is False
    and webrtc.get("nonproxied_udp_enabled") is False
    and langs.startswith(lang)
)
sys.exit(0 if ok else 1)
PY
}

detect_browser_profiles() {
  hr
  echo "检测 1/6：专用浏览器 WebRTC 防泄露配置"
  local chrome_prefs edge_prefs bad
  chrome_prefs="$CHROME_DIR/Default/Preferences"
  edge_prefs="$EDGE_DIR/Default/Preferences"
  bad=0

  if browser_profile_ok "$chrome_prefs"; then
    echo "Chrome profile：已写入 WebRTC/语言防泄露配置。"
  else
    echo "Chrome profile：缺失或配置不完整。"
    bad=1
  fi

  if browser_profile_ok "$edge_prefs"; then
    echo "Edge profile：已写入 WebRTC/语言防泄露配置。"
  else
    echo "Edge profile：缺失或配置不完整。"
    bad=1
  fi

  if [[ "$bad" == "1" ]]; then
    add_issue "专用 Chrome/Edge profile 的 WebRTC 防泄露配置缺失或不完整。"
    add_fix "browser" "写入专用 Chrome/Edge profile 的 WebRTC 防泄露配置并生成启动脚本"
  fi
  add_manual "WebRTC 不能只靠本地文件判定，修复后仍必须到 browserleaks.com/webrtc 人工确认。"
}

detect_system_locale() {
  hr
  echo "检测 2/6：系统时区、语言、地区和单位"
  local tz lang locale measurement metric temperature bad
  tz="$(readlink /etc/localtime 2>/dev/null | sed 's#^/var/db/timezone/zoneinfo/##' || true)"
  lang="$(defaults read -g AppleLanguages 2>/dev/null | tr -d '()", ' | sed '/^$/d' | head -n 1 || true)"
  locale="$(defaults read -g AppleLocale 2>/dev/null || true)"
  measurement="$(defaults read -g AppleMeasurementUnits 2>/dev/null || true)"
  metric="$(defaults read -g AppleMetricUnits 2>/dev/null || true)"
  temperature="$(defaults read -g AppleTemperatureUnit 2>/dev/null || true)"
  bad=0

  echo "当前：tz=${tz:-未知} language=${lang:-未知} locale=${locale:-未知} units=${measurement:-未知} metric=${metric:-未知} temp=${temperature:-未知}"
  [[ "$tz" != "$TARGET_TIMEZONE" ]] && bad=1
  [[ "$lang" != "$TARGET_LANGUAGE" ]] && bad=1
  [[ "$locale" != "$TARGET_LOCALE"* ]] && bad=1
  [[ "$measurement" != "Inches" ]] && bad=1
  [[ "$metric" != "0" ]] && bad=1
  [[ "$temperature" != "Fahrenheit" ]] && bad=1

  if [[ "$bad" == "1" ]]; then
    add_issue "系统时区/语言/地区/单位与目标美国英文环境不一致。"
    add_fix "locale" "设置 macOS 时区、语言、地区、计量单位和温度单位"
  else
    echo "通过：系统环境已符合目标。"
  fi
}

detect_ipv6() {
  hr
  echo "检测 3/6：IPv6 直连泄露"
  IPV6_VALUE="$(curl -6 -sS --max-time "$TIMEOUT" https://ifconfig.co 2>/dev/null || true)"
  if [[ -n "$IPV6_VALUE" && "$IPV6_VALUE" == *:* ]]; then
    echo "失败：检测到 IPv6 可直连：$IPV6_VALUE"
    ACTIVE_SERVICES="$(active_network_services)"
    add_issue "检测到 IPv6 直连：$IPV6_VALUE"
    if [[ -n "$ACTIVE_SERVICES" ]]; then
      add_fix "ipv6" "对当前活跃网络服务执行 networksetup -setv6off"
    else
      add_manual "未找到可自动处理的活跃网络服务，请在系统设置、路由器或代理/VPN 客户端里关闭 IPv6。"
    fi
  else
    echo "通过：curl -6 没有拿到直连 IPv6。"
  fi
}

detect_dns() {
  hr
  echo "检测 4/6：系统 DNS"
  local nameservers tun_dns
  nameservers="$(dns_nameservers)"
  echo "当前系统 DNS："
  if [[ -n "$nameservers" ]]; then
    printf '%s\n' "$nameservers" | sed 's/^/  /'
  else
    echo "  未读取到 nameserver"
  fi

  tun_dns="$(printf '%s\n' "$nameservers" | grep -E '^198\.18\.' || true)"
  DNS_RISKY="$(printf '%s\n' "$nameservers" | grep -E '^(114\.|223\.5\.|223\.6\.|119\.29\.|180\.76\.|1\.12\.|101\.226\.|202\.96\.|218\.|219\.|221\.)' || true)"

  if [[ -n "$tun_dns" ]]; then
    echo "通过：检测到 198.18.0.0/15 TUN/分流 DNS，不自动改写。"
    add_manual "系统 DNS 有 TUN DNS，但浏览器 DNS 泄露仍需到 browserleaks.com/dns 或 dnsleaktest.com 人工确认。"
    return 0
  fi

  if [[ -n "$DNS_RISKY" ]]; then
    echo "失败：检测到大陆/运营商 DNS："
    printf '%s\n' "$DNS_RISKY" | sed 's/^/  /'
    ACTIVE_SERVICES="${ACTIVE_SERVICES:-$(active_network_services)}"
    add_issue "系统 DNS 使用大陆/运营商 DNS。"
    if [[ -n "$ACTIVE_SERVICES" ]]; then
      add_fix "dns" "将当前活跃网络服务 DNS 改为 $DNS_SERVERS"
    else
      add_manual "未找到可自动改 DNS 的活跃网络服务，请从 Surge/Clash/Clash Mi 的 DNS/TUN 设置修复。"
    fi
  else
    echo "通过：未检测到 114、阿里、腾讯或常见大陆运营商 DNS。"
    add_manual "系统 DNS 通过不等于浏览器 DNS 泄露通过，仍需网页人工确认。"
  fi
}

score_single_ip() {
  local ip="$1"
  local ipapi proxycheck ipapi_ok proxycheck_ok
  local country city tz is_dc is_proxy is_vpn is_tor is_abuser company company_type company_abuse asn asn_org asn_type asn_abuse
  local pc_proxy pc_type pc_risk score verdict reasons

  ipapi="$(fetch_url_retry "https://api.ipapi.is/?q=${ip}")"
  proxycheck="$(fetch_url_retry "https://proxycheck.io/v2/${ip}?vpn=1&asn=1&risk=1&seen=1&days=30&tag=ai-preflight-fix-cn")"
  ipapi_ok="$(printf '%s' "$ipapi" | jq -e '.ip? != null' >/dev/null 2>&1; echo $?)"
  proxycheck_ok="$(printf '%s' "$proxycheck" | jq -e '.status? == "ok"' >/dev/null 2>&1; echo $?)"

  if [[ "$ipapi_ok" != "0" ]]; then
    echo "无法查询 IP 情报：$ip"
    add_manual "无法查询 IP 情报：${ip}。请稍后重跑门禁脚本。"
    return 0
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
  if [[ "$verdict" != "通过" ]]; then
    add_issue "出口 IP ${ip} 纯净度不达标：${verdict}，评分 ${score}/100。"
    add_manual "IP 纯净度不能自动修复。需要切换节点/出口，优先真实美国住宅宽带、美国移动网络、独享住宅代理；切换后重新运行门禁脚本验证。"
  fi
}

detect_route_and_ip_quality() {
  hr
  echo "检测 5/6：Claude/OpenAI 分流出口和 IP 纯净度"
  local tmp trace host ip loc colo http tls ip_count
  tmp="$(mktemp)"

  for host in "${TARGETS[@]}"; do
    trace="$(trace_host "$host")"
    ip="$(printf '%s\n' "$trace" | field_from_trace ip)"
    loc="$(printf '%s\n' "$trace" | field_from_trace loc)"
    colo="$(printf '%s\n' "$trace" | field_from_trace colo)"
    http="$(printf '%s\n' "$trace" | field_from_trace http)"
    tls="$(printf '%s\n' "$trace" | field_from_trace tls)"
    if [[ -z "$ip" ]]; then
      printf "%-24s 无法获取 trace\n" "$host"
      add_issue "无法获取 $host 的实际出口 trace。"
      continue
    fi
    printf "%-24s ip=%-15s 国家=%-3s 机房=%-5s http=%-7s tls=%s\n" "$host" "$ip" "$loc" "$colo" "$http" "$tls"
    if [[ "$loc" != "$TARGET_COUNTRY" ]]; then
      add_issue "$host 出口国家为 ${loc:-未知}，不是 ${TARGET_COUNTRY}。"
    fi
    echo "$ip" >> "$tmp"
  done

  UNIQUE_IPS="$(sort -u "$tmp")"
  rm -f "$tmp"
  ip_count="$(printf '%s\n' "$UNIQUE_IPS" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ -z "$UNIQUE_IPS" ]]; then
    add_manual "没有拿到 Claude/OpenAI 域名出口 IP。请先检查代理/TUN/DNS 是否正常。"
    return 0
  fi

  if [[ "$ip_count" != "1" ]]; then
    add_issue "Claude/OpenAI 域名没有都走同一个稳定出口 IP。"
    add_manual "分流规则未完成。建议加入或核对域名：claude.ai, api.anthropic.com, console.anthropic.com, chatgpt.com, api.openai.com, platform.openai.com, auth.openai.com, ios.chat.openai.com。"
    echo "当前疑似代理/VPN 客户端进程："
    detect_proxy_clients
  fi

  echo
  echo "出口 IP 情报："
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    score_single_ip "$ip"
  done <<< "$UNIQUE_IPS"
}

detect_browser_manual_gate() {
  hr
  echo "检测 6/6：浏览器人工确认项"
  echo "脚本不会自动打开 Claude/OpenAI，也不会自动打开检测网页。"
  echo "需要你手动确认："
  echo "  [1] browserleaks.com/webrtc 没有暴露真实公网 IP、中国 IP 或异常 IPv6。"
  echo "  [2] browserleaks.com/dns / dnsleaktest.com 没有中国大陆、运营商、114、阿里、腾讯 DNS。"
  echo "  [3] browserleaks.com/javascript 显示时区 ${TARGET_TIMEZONE}，语言为 ${TARGET_LANGUAGE}/en。"
  echo "  [4] IP 页面显示的出口 IP 与分流检测一致。"
  echo "可用自动读取辅助脚本：$SCRIPT_DIR/ai_browser_leak_check_cn.sh"
}

print_summary() {
  hr
  echo "检测问题汇总"
  if ((${#ISSUES[@]} == 0)); then
    echo "未发现可由脚本判定的硬性问题。"
  else
    local i=1
    for item in "${ISSUES[@]}"; do
      echo "[$i] $item"
      i=$((i + 1))
    done
  fi

  echo
  echo "可自动/半自动修复项："
  if ((${#FIX_LABELS[@]} == 0)); then
    echo "  无"
  else
    local i=1
    for item in "${FIX_LABELS[@]}"; do
      echo "  [$i] $item"
      i=$((i + 1))
    done
  fi

  echo
  echo "不能可靠自动修复或必须人工确认："
  if ((${#MANUAL_ITEMS[@]} == 0)); then
    echo "  无"
  else
    local i=1
    for item in "${MANUAL_ITEMS[@]}"; do
      echo "  [$i] $item"
      i=$((i + 1))
    done
  fi
}

confirm_fixes() {
  if [[ "$CHECK_ONLY" == "1" ]]; then
    echo
    echo "当前为 --check-only，只检测不修改。"
    return 1
  fi
  if ((${#FIX_KEYS[@]} == 0)); then
    echo
    echo "没有可自动修复项，不弹出修改确认。"
    return 1
  fi
  if [[ "$YES" == "1" ]]; then
    echo
    echo "--yes 已启用，直接执行可自动修复项。"
    return 0
  fi

  local text item
  text="检测完成。是否对以下项目进行修改？"
  for item in "${FIX_LABELS[@]}"; do
    text="${text}
- ${item}"
  done
  text="${text}

不会自动打开 Claude/OpenAI 网页或 App。"

  if command -v osascript >/dev/null 2>&1; then
    if osascript -e 'display dialog "'"$(printf '%s' "$text" | sed 's/"/\\"/g')"' " buttons {"取消", "确认修改"} default button "确认修改" cancel button "取消" with title "AI 打开前环境修复"' >/dev/null 2>&1; then
      return 0
    fi
    echo "用户取消，未执行修改。"
    return 1
  fi

  printf "%s [y/N]: " "$text"
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" || "$reply" == "是" ]]
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

write_browser_launchers() {
  local bin_dir="$BASE_DIR/bin"
  mkdir -p "$bin_dir"
  /usr/bin/python3 - "$bin_dir" "$CHROME_DIR" "$EDGE_DIR" "$TARGET_LANGUAGE" <<'PY'
import stat
import sys
from pathlib import Path

bin_dir = Path(sys.argv[1])
chrome_dir = sys.argv[2]
edge_dir = sys.argv[3]
lang = sys.argv[4]

scripts = {
    "start-ai-chrome-profile.zsh": (
        '#!/usr/bin/env zsh\n'
        'nohup "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \\\n'
        f'  --user-data-dir="{chrome_dir}" \\\n'
        '  --profile-directory=Default \\\n'
        '  --no-first-run \\\n'
        '  --no-default-browser-check \\\n'
        f'  --lang="{lang}" \\\n'
        '  --force-webrtc-ip-handling-policy=disable_non_proxied_udp \\\n'
        '  --new-window >/tmp/ai-chrome-profile.log 2>&1 &\n'
        'sleep 2\n'
        'osascript -e \'tell application "System Events" to set visible of process "Google Chrome" to false\' >/dev/null 2>&1 || true\n'
    ),
    "start-ai-edge-profile.zsh": (
        '#!/usr/bin/env zsh\n'
        'nohup "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \\\n'
        f'  --user-data-dir="{edge_dir}" \\\n'
        '  --profile-directory=Default \\\n'
        '  --no-first-run \\\n'
        '  --no-default-browser-check \\\n'
        f'  --lang="{lang}" \\\n'
        '  --force-webrtc-ip-handling-policy=disable_non_proxied_udp \\\n'
        '  --new-window >/tmp/ai-edge-profile.log 2>&1 &\n'
        'sleep 2\n'
        'osascript -e \'tell application "System Events" to set visible of process "Microsoft Edge" to false\' >/dev/null 2>&1 || true\n'
    ),
}

for name, content in scripts.items():
    path = bin_dir / name
    path.write_text(content)
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
PY
}

fix_browser() {
  hr
  echo "执行修复：专用浏览器 WebRTC 配置"
  write_browser_preferences "$CHROME_DIR"
  write_browser_preferences "$EDGE_DIR"
  write_browser_launchers
  echo "已写入：$CHROME_DIR/Default/Preferences"
  echo "已写入：$EDGE_DIR/Default/Preferences"
  echo "已生成：$BASE_DIR/bin/start-ai-chrome-profile.zsh"
  echo "已生成：$BASE_DIR/bin/start-ai-edge-profile.zsh"
}

fix_locale() {
  hr
  echo "执行修复：系统时区、语言、地区和单位"
  run_cmd sudo systemsetup -settimezone "$TARGET_TIMEZONE"
  run_cmd defaults write -g AppleLanguages -array "$TARGET_LANGUAGE"
  run_cmd defaults write -g AppleLocale "$TARGET_LOCALE"
  run_cmd defaults write -g AppleMeasurementUnits -string "Inches"
  run_cmd defaults write -g AppleMetricUnits -bool false
  run_cmd defaults write -g AppleTemperatureUnit -string "Fahrenheit"
  echo "提示：语言、地区、单位完整生效可能需要退出登录或重启。"
}

fix_ipv6() {
  hr
  echo "执行修复：关闭活跃网络服务 IPv6"
  local service
  ACTIVE_SERVICES="${ACTIVE_SERVICES:-$(active_network_services)}"
  if [[ -z "$ACTIVE_SERVICES" ]]; then
    echo "没有可自动处理的活跃网络服务。"
    return 0
  fi
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    run_cmd sudo networksetup -setv6off "$service"
  done <<< "$ACTIVE_SERVICES"
}

fix_dns() {
  hr
  echo "执行修复：改写活跃网络服务 DNS"
  local service
  local dns_array
  ACTIVE_SERVICES="${ACTIVE_SERVICES:-$(active_network_services)}"
  if [[ -z "$ACTIVE_SERVICES" ]]; then
    echo "没有可自动改 DNS 的活跃网络服务。"
    return 0
  fi
  read -r -a dns_array <<< "$DNS_SERVERS"
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    run_cmd sudo networksetup -setdnsservers "$service" "${dns_array[@]}"
  done <<< "$ACTIVE_SERVICES"
}

apply_selected_fixes() {
  local key
  for key in "${FIX_KEYS[@]}"; do
    case "$key" in
      browser) fix_browser ;;
      locale) fix_locale ;;
      ipv6) fix_ipv6 ;;
      dns) fix_dns ;;
    esac
  done
}

rerun_preflight() {
  hr
  echo "修改后重新运行中文门禁脚本（只检测，不打开网页或 App）"
  if [[ ! -x "$PREFLIGHT_CN" ]]; then
    echo "找不到或不可执行：$PREFLIGHT_CN"
    return 0
  fi
  "$PREFLIGHT_CN" --check-only
}

main() {
  if [[ "$RESTORE_MODE" == "1" ]]; then
    restore_environment
    return 0
  fi

  need curl
  need jq
  need awk
  need sort
  need sed
  need networksetup
  need scutil
  need defaults

  echo "Claude/OpenAI 打开前环境全面检测 + 人工确认修复"
  echo "不会自动打开 Claude/OpenAI 网页或 App。"
  show_current_snapshot
  detect_browser_profiles
  detect_system_locale
  detect_ipv6
  detect_dns
  detect_route_and_ip_quality
  detect_browser_manual_gate
  print_summary

  if confirm_fixes; then
    apply_selected_fixes
    rerun_preflight
  fi

  hr
  echo "完成。最终仍需人工确认：browserleaks.com/webrtc、browserleaks.com/dns、dnsleaktest.com、browserleaks.com/javascript。"
}

main "$@"
