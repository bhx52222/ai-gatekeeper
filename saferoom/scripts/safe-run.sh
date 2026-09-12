#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "已创建 .env，请先检查代理、DNS、EXPECTED_IP 后重新运行。"
  exit 2
fi

echo "步骤 1/4: 主机层门禁"
"$ROOT/scripts/host-gate.sh"
echo

echo "步骤 2/4: Docker Compose 配置检查"
docker compose config >/dev/null
echo "docker compose config: OK"
echo

echo "步骤 3/4: 容器环境检测"
"$ROOT/check-env.sh"
echo

echo "步骤 4/4: 容器内 AI 出口快检"
"$ROOT/check-ip.sh"
echo

echo "全部门禁完成。现在可以运行: $ROOT/claude-code.sh"

