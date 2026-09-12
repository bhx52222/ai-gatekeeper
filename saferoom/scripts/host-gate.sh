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

PRIVACY_DIR="${PRIVACY_DIR:-../scripts}"

export HTTP_PROXY="${HOST_HTTP_PROXY:-${HTTP_PROXY:-}}"
export HTTPS_PROXY="${HOST_HTTPS_PROXY:-${HTTPS_PROXY:-}}"
export ALL_PROXY="${HOST_ALL_PROXY:-${ALL_PROXY:-}}"
export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1,host.docker.internal}"

echo "主机层 AI 环境门禁"
echo "PRIVACY_DIR=${PRIVACY_DIR}"
echo "HOST_HTTP_PROXY=${HTTP_PROXY:-}"
echo "HOST_ALL_PROXY=${ALL_PROXY:-}"
echo

if [[ ! -d "$PRIVACY_DIR" ]]; then
  echo "找不到完美隐私目录: ${PRIVACY_DIR}" >&2
  exit 1
fi

cd "$PRIVACY_DIR"

echo "1/3 系统预检（只读）"
./ai_preflight_fix_cn.sh --check-only
echo

echo "2/3 后端 IP 纯净度检测（只读）"
ip_args=(--country "${TARGET_COUNTRY:-US}" --min-score "${MIN_SCORE:-85}" --timeout "${TIMEOUT:-20}")
if [[ -n "${EXPECTED_IP:-}" ]]; then
  ip_args+=(--expected-ip "$EXPECTED_IP")
fi
./ai_ip_purity_check.sh "${ip_args[@]}"
echo

echo "3/3 最终打开前门禁（只读）"
./ai_preflight_open_cn.sh --check-only
