#!/usr/bin/env bash
set -u

BROWSER="${BROWSER:-chrome}"
BASE_DIR="${BASE_DIR:-$HOME/AI-US-Browsers}"
CHROME_DIR="${CHROME_DIR:-$BASE_DIR/Chrome-Claude-OpenAI}"
EDGE_DIR="${EDGE_DIR:-$BASE_DIR/Edge-Claude-OpenAI}"
TARGET_TIMEZONE="${TARGET_TIMEZONE:-America/Los_Angeles}"
TARGET_LANGUAGE="${TARGET_LANGUAGE:-en-US}"
REMOTE_PORT="${REMOTE_PORT:-}"
KEEP_BROWSER="${KEEP_BROWSER:-0}"
TIMEOUT="${TIMEOUT:-45}"
PAGE_TIMEOUT="${PAGE_TIMEOUT:-20}"
HEADLESS="${HEADLESS:-0}"
BACKGROUND="${BACKGROUND:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_HELPER="$SCRIPT_DIR/ai_browser_leak_check_cdp.py"

usage() {
  cat <<'EOF'
用法：
  ./ai_browser_leak_check_cn.sh
  BROWSER=edge ./ai_browser_leak_check_cn.sh
  KEEP_BROWSER=0 ./ai_browser_leak_check_cn.sh
  BACKGROUND=0 ./ai_browser_leak_check_cn.sh
  HEADLESS=1 ./ai_browser_leak_check_cn.sh

环境变量：
  BROWSER          chrome 或 edge，默认 chrome。
  BACKGROUND       默认 1，启动真实浏览器后隐藏到后台；设为 0 则显示窗口。
  HEADLESS         默认 0。设为 1 会无窗口运行，但 UA 会显示 HeadlessChrome，不建议做最终指纹判断。
  KEEP_BROWSER     默认 0，检测后关闭本次启动的专用浏览器进程。
  REMOTE_PORT      默认 chrome=9223，edge=9224。
  PAGE_TIMEOUT     默认 20，单个检测页超过秒数则跳过。
  TARGET_TIMEZONE  默认 America/Los_Angeles。
  TARGET_LANGUAGE  默认 en-US。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$1"; usage; exit 2 ;;
  esac
done

browser_binary() {
  case "$BROWSER" in
    chrome) echo "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ;;
    edge) echo "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" ;;
    *) echo "不支持 BROWSER=$BROWSER，只支持 chrome 或 edge。" >&2; return 1 ;;
  esac
}

browser_dir() {
  case "$BROWSER" in
    chrome) echo "$CHROME_DIR" ;;
    edge) echo "$EDGE_DIR" ;;
    *) return 1 ;;
  esac
}

default_port() {
  case "$BROWSER" in
    chrome) echo 9223 ;;
    edge) echo 9224 ;;
  esac
}

browser_app_name() {
  case "$BROWSER" in
    chrome) echo "Google Chrome" ;;
    edge) echo "Microsoft Edge" ;;
  esac
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少依赖：$1"
    exit 1
  }
}

write_browser_preferences() {
  local prefs="$1/Default/Preferences"
  mkdir -p "$1/Default"
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
data.setdefault("intl", {})["selected_languages"] = f"{lang},en"
data.setdefault("webkit", {}).setdefault("webprefs", {})["default_encoding"] = "UTF-8"
data["webrtc"] = {
    "ip_handling_policy": "disable_non_proxied_udp",
    "multiple_routes_enabled": False,
    "nonproxied_udp_enabled": False,
}
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY
}

main() {
  need curl
  need python3

  local bin user_data_dir port pid
  local chrome_args
  local app_name
  bin="$(browser_binary)" || exit 2
  user_data_dir="$(browser_dir)" || exit 2
  app_name="$(browser_app_name)" || exit 2
  port="${REMOTE_PORT:-$(default_port)}"

  if [[ ! -x "$bin" ]]; then
    echo "找不到浏览器可执行文件：$bin"
    exit 1
  fi
  if [[ ! -f "$PY_HELPER" ]]; then
    echo "找不到 Python 读取器：$PY_HELPER"
    exit 1
  fi

  mkdir -p "$user_data_dir"
  write_browser_preferences "$user_data_dir"

  echo "启动专用 $BROWSER profile 做浏览器泄露自动读取"
  echo "profile: $user_data_dir"
  echo "remote debugging: 127.0.0.1:$port"
  echo "background: $BACKGROUND"
  echo "headless: $HEADLESS"
  echo "single page timeout: ${PAGE_TIMEOUT}s"
  echo "注意：不会打开 Claude/OpenAI 网页或 App。"

  chrome_args=(
    --user-data-dir="$user_data_dir"
    --profile-directory=Default
    --no-first-run
    --no-default-browser-check
    --lang="$TARGET_LANGUAGE"
    --accept-lang="$TARGET_LANGUAGE,en"
    --force-webrtc-ip-handling-policy=disable_non_proxied_udp
    --remote-debugging-address=127.0.0.1
    --remote-debugging-port="$port"
    --window-size=1600,900
  )
  if [[ "$HEADLESS" == "1" ]]; then
    chrome_args+=(--headless=new --disable-gpu)
  else
    chrome_args+=(--new-window)
  fi

  "$bin" "${chrome_args[@]}" about:blank >/dev/null 2>&1 &
  pid="$!"

  if [[ "$BACKGROUND" == "1" && "$HEADLESS" != "1" ]] && command -v osascript >/dev/null 2>&1; then
    sleep 1
    osascript -e "tell application \"$app_name\" to set visible to false" >/dev/null 2>&1 || true
  fi

  python3 "$PY_HELPER" \
    --port "$port" \
    --timeout "$TIMEOUT" \
    --page-timeout "$PAGE_TIMEOUT" \
    --target-timezone "$TARGET_TIMEZONE" \
    --target-language "$TARGET_LANGUAGE"
  local rc=$?

  if [[ "$KEEP_BROWSER" == "0" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    pkill -TERM -f "$user_data_dir" >/dev/null 2>&1 || true
  else
    echo
    echo "浏览器窗口已保留，便于你人工复核检测页。需要自动关闭可用：KEEP_BROWSER=0 ./ai_browser_leak_check_cn.sh"
  fi

  exit "$rc"
}

main "$@"
