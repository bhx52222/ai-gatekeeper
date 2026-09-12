#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

CLAUDE_APP="/Applications/Claude.app"
[[ -d "$CLAUDE_APP" ]] || { echo "找不到 Claude 桌面版：$CLAUDE_APP" >&2; exit 1; }

export HTTP_PROXY="${HOST_HTTP_PROXY:-http://127.0.0.1:6152}"
export HTTPS_PROXY="${HOST_HTTPS_PROXY:-http://127.0.0.1:6152}"
export ALL_PROXY="${HOST_ALL_PROXY:-socks5h://127.0.0.1:6153}"

"$ROOT/scripts/web-gate.sh"
exec open -na "$CLAUDE_APP" --args \
  --proxy-server="http=127.0.0.1:6152;https=127.0.0.1:6152;socks5=127.0.0.1:6153" \
  --force-webrtc-ip-handling-policy=disable_non_proxied_udp
