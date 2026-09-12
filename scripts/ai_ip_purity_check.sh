#!/usr/bin/env bash
set -u

TIMEOUT="${TIMEOUT:-15}"
TARGET_COUNTRY="${TARGET_COUNTRY:-US}"
EXPECTED_IP="${EXPECTED_IP:-}"
MIN_SCORE="${MIN_SCORE:-85}"
JSON_OUTPUT=0
OUTPUT_FILE=""

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
  "YouTube|流媒体|https://www.youtube.com/"
  "TikTok|流媒体|https://www.tiktok.com/"
  "Netflix|流媒体|https://www.netflix.com/"
  "Disney+|流媒体|https://www.disneyplus.com/"
  "Amazon Prime Video|流媒体|https://www.primevideo.com/"
  "Reddit|平台|https://www.reddit.com/"
  "GitHub|平台|https://github.com/"
  "Google Search|平台|https://www.google.com/generate_204"
  "X/Twitter|平台|https://x.com/"
)

usage() {
  cat <<'EOF'
用法：
  ./ai_ip_purity_check.sh
  ./ai_ip_purity_check.sh --json
  ./ai_ip_purity_check.sh --output ai-ip-purity-current.json
  EXPECTED_IP=203.0.113.10 ./ai_ip_purity_check.sh

参数：
  -j, --json             在文本报告后输出 JSON 报告。
  -o, --output FILE      保存 JSON 报告到 FILE。
  --expected-ip IP       要求所有 Claude/OpenAI 目标都走这个 IP。
  --country CODE         目标国家，默认 US。
  --min-score SCORE      PASS 阈值，默认 85。
  --timeout SECONDS      单次请求超时，默认 15 秒。
  -h, --help             显示帮助。

环境变量：
  EXPECTED_IP            等同 --expected-ip。
  TARGET_COUNTRY         等同 --country。
  MIN_SCORE              等同 --min-score。
  TIMEOUT                等同 --timeout。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--json) JSON_OUTPUT=1 ;;
    -o|--output)
      shift
      [[ $# -gt 0 ]] || { echo "--output 需要文件路径" >&2; exit 2; }
      OUTPUT_FILE="$1"
      ;;
    --expected-ip)
      shift
      [[ $# -gt 0 ]] || { echo "--expected-ip 需要 IP" >&2; exit 2; }
      EXPECTED_IP="$1"
      ;;
    --country)
      shift
      [[ $# -gt 0 ]] || { echo "--country 需要国家代码" >&2; exit 2; }
      TARGET_COUNTRY="$1"
      ;;
    --min-score)
      shift
      [[ $# -gt 0 ]] || { echo "--min-score 需要分数" >&2; exit 2; }
      MIN_SCORE="$1"
      ;;
    --timeout)
      shift
      [[ $# -gt 0 ]] || { echo "--timeout 需要秒数" >&2; exit 2; }
      TIMEOUT="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage; exit 2 ;;
  esac
  shift
done

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少依赖：$1" >&2
    exit 1
  }
}

hr() {
  printf '\n%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

json_get() {
  jq -r "if ($1) == null then empty else ($1 | tostring) end" 2>/dev/null
}

fetch() {
  local url="$1"
  curl -sS --max-time "$TIMEOUT" "$url" 2>/dev/null || true
}

trace_host() {
  local host="$1"
  fetch "https://${host}/cdn-cgi/trace"
}

field_from_trace() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k {print $2; exit}'
}

bool_flag() {
  case "$1" in
    true|yes|1) echo true ;;
    false|no|0) echo false ;;
    *) echo null ;;
  esac
}

num_or_zero() {
  [[ "$1" =~ ^[0-9]+$ ]] && echo "$1" || echo 0
}

append_reason() {
  REASONS+=("$1")
}

json_route_line() {
  local name="$1" host="$2" ip="$3" loc="$4" colo="$5" http="$6" tls="$7" status="$8"
  jq -n \
    --arg name "$name" \
    --arg host "$host" \
    --arg ip "$ip" \
    --arg loc "$loc" \
    --arg colo "$colo" \
    --arg http "$http" \
    --arg tls "$tls" \
    --arg status "$status" \
    '{
      name:$name,
      host:$host,
      ip:(if $ip | length > 0 then $ip else null end),
      country:(if $loc | length > 0 then $loc else null end),
      colo:(if $colo | length > 0 then $colo else null end),
      http:(if $http | length > 0 then $http else null end),
      tls:(if $tls | length > 0 then $tls else null end),
      status:$status
    }' >> "$ROUTE_JSONL"
}

service_verdict() {
  local code="$1" url="$2" category="$3"
  if [[ "$code" == "000" || -z "$code" ]]; then
    echo "失败"
  elif [[ "$code" =~ ^(200|204|301|302|303|307|308)$ ]]; then
    echo "可达"
  elif [[ "$category" == "AI" && "$code" == "403" ]]; then
    echo "可达-浏览器复核"
  elif [[ "$category" == "AI" && "$code" == "404" ]]; then
    echo "可达-端点复核"
  elif [[ "$code" =~ ^(401|403)$ && "$url" == *"api.openai.com"* ]]; then
    echo "可达-需认证"
  elif [[ "$code" =~ ^(401|403)$ && "$url" == *"api.anthropic.com"* ]]; then
    echo "可达-需认证"
  elif [[ "$code" == "403" ]]; then
    echo "受限"
  elif [[ "$code" == "451" ]]; then
    echo "地区屏蔽"
  elif [[ "$code" =~ ^[245][0-9][0-9]$ ]]; then
    echo "可达-需复核"
  else
    echo "异常"
  fi
}

check_services() {
  local item name category url code remote verdict
  hr
  echo "平台连通检测（后台 HTTP，不调用浏览器）"
  printf "%-22s %-8s %-8s %s\n" "平台" "类别" "状态" "HTTP"
  printf "%-22s %-8s %-8s %s\n" "----------------------" "--------" "--------" "----"

  : > "$SERVICE_JSONL"
  for item in "${SERVICE_CHECKS[@]}"; do
    IFS='|' read -r name category url <<< "$item"
    remote="$(curl -L -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>/dev/null || true)"
    code="${remote:-000}"
    verdict="$(service_verdict "$code" "$url" "$category")"
    printf "%-22s %-8s %-8s %s\n" "$name" "$category" "$verdict" "$code"
    jq -n \
      --arg name "$name" \
      --arg category "$category" \
      --arg url "$url" \
      --arg status "$verdict" \
      --arg http_code "$code" \
      '{name:$name, category:$category, url:$url, status:$status, http_code:$http_code}' >> "$SERVICE_JSONL"
  done
  jq -s '.' "$SERVICE_JSONL" > "$SERVICE_ARRAY"
}

score_ip() {
  local ip="$1"
  local ipapi proxycheck ipinfo
  local ipapi_ok proxycheck_ok ipinfo_ok
  local country city tz is_dc is_proxy is_vpn is_tor is_abuser company company_type company_abuse asn asn_org asn_type asn_abuse
  local pc_proxy pc_type pc_risk pc_country pc_provider pc_asn
  local ii_country ii_asn ii_asn_type ii_org ii_company_type ii_company ii_proxy ii_vpn ii_tor ii_hosting
  local proxy_votes vpn_votes tor_votes server_votes abuser_votes country_votes score verdict cn_verdict
  local ipapi_proxy_bool ipapi_vpn_bool ipapi_tor_bool ipapi_dc_bool ipapi_abuser_bool
  local pc_proxy_bool pc_risk_num ii_proxy_bool ii_vpn_bool ii_tor_bool ii_hosting_bool

  REASONS=()
  ipapi="$(fetch "https://api.ipapi.is/?q=${ip}")"
  proxycheck="$(fetch "https://proxycheck.io/v2/${ip}?vpn=1&asn=1&risk=1&seen=1&days=30&tag=ai-ip-purity-check")"
  ipinfo="$(fetch "https://ipinfo.io/widget/demo/${ip}")"

  ipapi_ok="$(printf '%s' "$ipapi" | jq -e '.ip? != null' >/dev/null 2>&1; echo $?)"
  proxycheck_ok="$(printf '%s' "$proxycheck" | jq -e '.status? == "ok"' >/dev/null 2>&1; echo $?)"
  ipinfo_ok="$(printf '%s' "$ipinfo" | jq -e '.data.ip? != null or .data.country? != null' >/dev/null 2>&1; echo $?)"

  if [[ "$ipapi_ok" != "0" && "$proxycheck_ok" != "0" && "$ipinfo_ok" != "0" ]]; then
    echo "IP: $ip"
    echo "  所有 IP 情报源查询失败。"
    jq -n --arg ip "$ip" '{ip:$ip, error:"all intelligence lookups failed"}' > "$RESULT_DIR/ip-${ip}.json"
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
  pc_country=""
  pc_provider=""
  pc_asn=""
  if [[ "$proxycheck_ok" == "0" ]]; then
    pc_proxy="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].proxy // empty')"
    pc_type="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].type // empty')"
    pc_risk="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].risk // empty')"
    pc_country="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].isocode // empty')"
    pc_provider="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].provider // empty')"
    pc_asn="$(printf '%s' "$proxycheck" | jq -r --arg ip "$ip" '.[$ip].asn // empty')"
  fi

  ii_country=""
  ii_asn=""
  ii_asn_type=""
  ii_org=""
  ii_company=""
  ii_company_type=""
  ii_proxy=""
  ii_vpn=""
  ii_tor=""
  ii_hosting=""
  if [[ "$ipinfo_ok" == "0" ]]; then
    ii_country="$(printf '%s' "$ipinfo" | json_get '.data.country')"
    ii_asn="$(printf '%s' "$ipinfo" | json_get '.data.asn.asn')"
    ii_asn_type="$(printf '%s' "$ipinfo" | json_get '.data.asn.type')"
    ii_org="$(printf '%s' "$ipinfo" | json_get '.data.asn.name')"
    ii_company="$(printf '%s' "$ipinfo" | json_get '.data.company.name')"
    ii_company_type="$(printf '%s' "$ipinfo" | json_get '.data.company.type')"
    ii_proxy="$(printf '%s' "$ipinfo" | json_get '.data.privacy.proxy')"
    ii_vpn="$(printf '%s' "$ipinfo" | json_get '.data.privacy.vpn')"
    ii_tor="$(printf '%s' "$ipinfo" | json_get '.data.privacy.tor')"
    ii_hosting="$(printf '%s' "$ipinfo" | json_get '.data.privacy.hosting')"
  fi

  ipapi_proxy_bool="$(bool_flag "$is_proxy")"
  ipapi_vpn_bool="$(bool_flag "$is_vpn")"
  ipapi_tor_bool="$(bool_flag "$is_tor")"
  ipapi_dc_bool="$(bool_flag "$is_dc")"
  ipapi_abuser_bool="$(bool_flag "$is_abuser")"
  pc_proxy_bool="$(bool_flag "$pc_proxy")"
  ii_proxy_bool="$(bool_flag "$ii_proxy")"
  ii_vpn_bool="$(bool_flag "$ii_vpn")"
  ii_tor_bool="$(bool_flag "$ii_tor")"
  ii_hosting_bool="$(bool_flag "$ii_hosting")"
  pc_risk_num="$(num_or_zero "$pc_risk")"

  proxy_votes=0
  [[ "$ipapi_proxy_bool" == "true" ]] && proxy_votes=$((proxy_votes + 1))
  [[ "$pc_proxy_bool" == "true" ]] && proxy_votes=$((proxy_votes + 1))
  [[ "$ii_proxy_bool" == "true" ]] && proxy_votes=$((proxy_votes + 1))

  vpn_votes=0
  [[ "$ipapi_vpn_bool" == "true" ]] && vpn_votes=$((vpn_votes + 1))
  [[ "$ii_vpn_bool" == "true" ]] && vpn_votes=$((vpn_votes + 1))

  tor_votes=0
  [[ "$ipapi_tor_bool" == "true" ]] && tor_votes=$((tor_votes + 1))
  [[ "$ii_tor_bool" == "true" ]] && tor_votes=$((tor_votes + 1))

  server_votes=0
  [[ "$ipapi_dc_bool" == "true" ]] && server_votes=$((server_votes + 1))
  [[ "$ii_hosting_bool" == "true" ]] && server_votes=$((server_votes + 1))
  [[ "$asn_type" == "hosting" || "$company_type" == "hosting" ]] && server_votes=$((server_votes + 1))
  [[ "$ii_asn_type" == "hosting" || "$ii_company_type" == "hosting" ]] && server_votes=$((server_votes + 1))
  [[ "$pc_type" =~ ^(Hosting|VPN|Proxy|Tor)$ ]] && server_votes=$((server_votes + 1))

  abuser_votes=0
  [[ "$ipapi_abuser_bool" == "true" ]] && abuser_votes=$((abuser_votes + 1))
  (( pc_risk_num >= 66 )) && abuser_votes=$((abuser_votes + 1))

  country_votes=0
  [[ "$country" == "$TARGET_COUNTRY" ]] && country_votes=$((country_votes + 1))
  [[ "$pc_country" == "$TARGET_COUNTRY" ]] && country_votes=$((country_votes + 1))
  [[ "$ii_country" == "$TARGET_COUNTRY" ]] && country_votes=$((country_votes + 1))

  score=100
  if (( country_votes == 0 )); then
    score=$((score - 35))
    append_reason "国家不符：ipapi=${country:-unknown}, proxycheck=${pc_country:-unknown}, IPinfo=${ii_country:-unknown}, 目标=$TARGET_COUNTRY"
  elif (( country_votes < 2 )); then
    score=$((score - 10))
    append_reason "只有部分数据源确认目标国家"
  fi
  if (( server_votes >= 3 )); then
    score=$((score - 35))
    append_reason "多个数据源标记为机房/托管/server"
  elif (( server_votes > 0 )); then
    score=$((score - 18))
    append_reason "部分数据源标记为机房/托管/server"
  fi
  if (( proxy_votes > 0 )); then
    score=$((score - 35))
    append_reason "存在 proxy 标记"
  fi
  if (( vpn_votes > 0 )); then
    score=$((score - 35))
    append_reason "存在 VPN 标记"
  fi
  if (( tor_votes > 0 )); then
    score=$((score - 50))
    append_reason "存在 Tor 标记"
  fi
  if (( abuser_votes > 0 )); then
    score=$((score - 25))
    append_reason "存在滥用/高风险标记"
  elif (( pc_risk_num >= 33 )); then
    score=$((score - 10))
    append_reason "proxycheck 中等风险=$pc_risk_num"
  fi
  if (( score < 0 )); then score=0; fi

  if (( score >= MIN_SCORE )) && (( server_votes == 0 && proxy_votes == 0 && vpn_votes == 0 && tor_votes == 0 )); then
    verdict="PASS"
    cn_verdict="通过：接近干净住宅/移动 ISP"
  elif (( score >= 65 )); then
    verdict="CAUTION"
    cn_verdict="谨慎：可用但不够理想"
  else
    verdict="FAIL"
    cn_verdict="失败：不建议用于核心账号"
  fi

  hr
  echo "基础信息"
  printf "%-14s %s\n" "IP" "$ip"
  printf "%-14s %s / %s / %s\n" "位置" "${country:-unknown}" "${city:-unknown}" "${tz:-unknown}"
  printf "%-14s AS%s %s\n" "ASN" "${asn:-unknown}" "${asn_org:-unknown}"
  printf "%-14s %s\n" "公司" "${company:-unknown}"

  hr
  echo "IP 类型识别"
  printf "%-14s %-16s %-16s\n" "数据库" "Usage/ASN" "Company"
  printf "%-14s %-16s %-16s\n" "ipapi" "${asn_type:-unknown}" "${company_type:-unknown}"
  printf "%-14s %-16s %-16s\n" "IPinfo" "${ii_asn_type:-unknown}" "${ii_company_type:-unknown}"
  printf "%-14s %-16s %-16s\n" "proxycheck" "${pc_type:-unknown}" "${pc_provider:-unknown}"

  hr
  echo "风险评分"
  printf "%-16s %s\n" "综合分数" "$score/100"
  printf "%-16s %s\n" "结论" "$cn_verdict"
  printf "%-16s %s\n" "proxycheck" "risk=${pc_risk:-unknown}"
  printf "%-16s %s\n" "ASN abuse" "${asn_abuse:-unknown}"
  printf "%-16s %s\n" "Company abuse" "${company_abuse:-unknown}"
  if ((${#REASONS[@]})); then
    echo "扣分原因："
    local item
    for item in "${REASONS[@]}"; do
      echo "  - $item"
    done
  fi

  hr
  echo "风险因子"
  printf "%-14s %-8s %-8s %-8s\n" "因子" "ipapi" "IPinfo" "proxycheck"
  printf "%-14s %-8s %-8s %-8s\n" "国家" "${country:-unknown}" "${ii_country:-unknown}" "${pc_country:-unknown}"
  printf "%-14s %-8s %-8s %-8s\n" "Proxy" "${is_proxy:-unknown}" "${ii_proxy:-unknown}" "${pc_proxy:-unknown}"
  printf "%-14s %-8s %-8s %-8s\n" "VPN" "${is_vpn:-unknown}" "${ii_vpn:-unknown}" "-"
  printf "%-14s %-8s %-8s %-8s\n" "Tor" "${is_tor:-unknown}" "${ii_tor:-unknown}" "-"
  printf "%-14s %-8s %-8s %-8s\n" "Server" "${is_dc:-unknown}" "${ii_hosting:-unknown}" "${pc_type:-unknown}"
  printf "%-14s %-8s %-8s %-8s\n" "Abuse" "${is_abuser:-unknown}" "-" "${pc_risk:-unknown}"
  echo "投票：country=${country_votes}/3 server=${server_votes} proxy=${proxy_votes} vpn=${vpn_votes} tor=${tor_votes} abuse=${abuser_votes}"

  local reasons_json
  reasons_json="$(printf '%s\n' "${REASONS[@]:-}" | jq -R . | jq -s .)"
  jq -n \
    --arg ip "$ip" \
    --arg target_country "$TARGET_COUNTRY" \
    --arg country "$country" \
    --arg city "$city" \
    --arg timezone "$tz" \
    --arg asn "$asn" \
    --arg asn_org "$asn_org" \
    --arg asn_type "$asn_type" \
    --arg company "$company" \
    --arg company_type "$company_type" \
    --arg pc_country "$pc_country" \
    --arg pc_provider "$pc_provider" \
    --arg pc_asn "$pc_asn" \
    --arg pc_type "$pc_type" \
    --arg pc_risk "$pc_risk" \
    --arg ii_country "$ii_country" \
    --arg ii_asn "$ii_asn" \
    --arg ii_org "$ii_org" \
    --arg ii_asn_type "$ii_asn_type" \
    --argjson ipapi_datacenter "$ipapi_dc_bool" \
    --argjson ipapi_proxy "$ipapi_proxy_bool" \
    --argjson ipapi_vpn "$ipapi_vpn_bool" \
    --argjson ipapi_tor "$ipapi_tor_bool" \
    --argjson ipapi_abuser "$ipapi_abuser_bool" \
    --argjson pc_proxy "$pc_proxy_bool" \
    --argjson ii_proxy "$ii_proxy_bool" \
    --argjson ii_vpn "$ii_vpn_bool" \
    --argjson ii_tor "$ii_tor_bool" \
    --argjson ii_hosting "$ii_hosting_bool" \
    --argjson score "$score" \
    --arg verdict "$verdict" \
    --arg cn_verdict "$cn_verdict" \
    --argjson country_votes "$country_votes" \
    --argjson server_votes "$server_votes" \
    --argjson proxy_votes "$proxy_votes" \
    --argjson vpn_votes "$vpn_votes" \
    --argjson tor_votes "$tor_votes" \
    --argjson abuser_votes "$abuser_votes" \
    --argjson reasons "$reasons_json" \
    '{
      ip:$ip,
      target_country:$target_country,
      sources:{
        ipapi:{
          country:$country, city:$city, timezone:$timezone,
          asn:{number:$asn, org:$asn_org, type:$asn_type},
          company:{name:$company, type:$company_type},
          flags:{datacenter:$ipapi_datacenter, proxy:$ipapi_proxy, vpn:$ipapi_vpn, tor:$ipapi_tor, abuser:$ipapi_abuser}
        },
        proxycheck:{
          country:$pc_country, provider:$pc_provider, asn:$pc_asn, type:$pc_type, risk:$pc_risk, proxy:$pc_proxy
        },
        ipinfo:{
          country:$ii_country, asn:$ii_asn, org:$ii_org, asn_type:$ii_asn_type,
          flags:{hosting:$ii_hosting, proxy:$ii_proxy, vpn:$ii_vpn, tor:$ii_tor}
        }
      },
      votes:{country_confirmed:$country_votes, server:$server_votes, proxy:$proxy_votes, vpn:$vpn_votes, tor:$tor_votes, abuse:$abuser_votes},
      score:$score,
      verdict:$verdict,
      verdict_cn:$cn_verdict,
      reasons:$reasons
    }' > "$RESULT_DIR/ip-${ip}.json"
}

route_check() {
  local item name host trace ip loc colo http tls status
  local tmp
  tmp="$(mktemp)"

  hr
  echo "AI 域名分流检测（Cloudflare Trace）"
  printf "%-20s %-24s %-15s %-4s %-5s %s\n" "服务" "域名" "出口IP" "国家" "机房" "状态"
  printf "%-20s %-24s %-15s %-4s %-5s %s\n" "--------------------" "------------------------" "---------------" "----" "-----" "------"

  : > "$ROUTE_JSONL"
  for item in "${AI_TRACE_TARGETS[@]}"; do
    IFS='|' read -r name host <<< "$item"
    trace="$(trace_host "$host")"
    ip="$(printf '%s\n' "$trace" | field_from_trace ip)"
    loc="$(printf '%s\n' "$trace" | field_from_trace loc)"
    colo="$(printf '%s\n' "$trace" | field_from_trace colo)"
    http="$(printf '%s\n' "$trace" | field_from_trace http)"
    tls="$(printf '%s\n' "$trace" | field_from_trace tls)"

    if [[ -z "$ip" ]]; then
      status="无法检测"
      printf "%-20s %-24s %-15s %-4s %-5s %s\n" "$name" "$host" "-" "-" "-" "$status"
      json_route_line "$name" "$host" "" "" "" "" "" "NO_TRACE"
      continue
    fi

    status="正常"
    if [[ "$loc" != "$TARGET_COUNTRY" ]]; then
      status="国家不符"
    fi
    if [[ -n "$EXPECTED_IP" && "$ip" != "$EXPECTED_IP" ]]; then
      status="IP不符"
    fi

    printf "%-20s %-24s %-15s %-4s %-5s %s\n" "$name" "$host" "$ip" "$loc" "$colo" "$status"
    echo "$ip" >> "$tmp"
    json_route_line "$name" "$host" "$ip" "$loc" "$colo" "$http" "$tls" "$status"
  done

  UNIQUE_IPS="$(sort -u "$tmp")"
  rm -f "$tmp"
  jq -s '.' "$ROUTE_JSONL" > "$ROUTE_ARRAY"
}

write_final_json() {
  local final_json
  final_json="$(jq -n \
    --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg target_country "$TARGET_COUNTRY" \
    --arg expected_ip "$EXPECTED_IP" \
    --argjson min_score "$MIN_SCORE" \
    --slurpfile routes "$ROUTE_ARRAY" \
    --slurpfile ips "$IP_ARRAY" \
    --slurpfile services "$SERVICE_ARRAY" \
    '{
      generated_at:$generated_at,
      target_country:$target_country,
      expected_ip:(if $expected_ip | length > 0 then $expected_ip else null end),
      min_score:$min_score,
      route_check:$routes[0],
      ip_quality:$ips[0],
      service_check:$services[0]
    }')"

  if [[ -n "$OUTPUT_FILE" ]]; then
    printf '%s\n' "$final_json" > "$OUTPUT_FILE"
    echo "JSON 报告已保存：$OUTPUT_FILE"
  fi
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    hr
    echo "JSON 报告"
    printf '%s\n' "$final_json"
  fi
}

main() {
  need curl
  need jq
  need awk
  need sort
  need uniq

  RESULT_DIR="$(mktemp -d)"
  ROUTE_JSONL="$RESULT_DIR/routes.jsonl"
  ROUTE_ARRAY="$RESULT_DIR/routes.json"
  SERVICE_JSONL="$RESULT_DIR/services.jsonl"
  SERVICE_ARRAY="$RESULT_DIR/services.json"
  IP_ARRAY="$RESULT_DIR/ips.json"
  trap 'rm -rf "$RESULT_DIR"' EXIT

  echo "IP 质量体检脚本 - AI 增强中文版"
  echo "目标国家：$TARGET_COUNTRY"
  echo "PASS 阈值：$MIN_SCORE"
  [[ -n "$EXPECTED_IP" ]] && echo "指定出口 IP：$EXPECTED_IP"

  route_check

  if [[ -z "$UNIQUE_IPS" ]]; then
    hr
    echo "没有检测到 AI 域名出口 IP。请先检查代理、DNS 或分流规则。"
    jq -n '[]' > "$IP_ARRAY"
    check_services
    write_final_json
    exit 2
  fi

  local ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    score_ip "$ip"
  done <<< "$UNIQUE_IPS"
  jq -s '.' "$RESULT_DIR"/ip-*.json > "$IP_ARRAY"

  check_services

  hr
  echo "结论说明"
  echo "PASS：国家一致，且没有明显 proxy / VPN / Tor / hosting / abuse 风险。"
  echo "谨慎：可用但不是理想住宅 IP，应结合浏览器泄露、DNS、账号历史继续判断。"
  echo "失败：不建议用于 Claude / OpenAI 核心账号。"
  echo "本脚本为后台检测，不替代 WebRTC、浏览器语言、JS 时区和 DNS 泄露检测。"

  write_final_json
}

main "$@"
