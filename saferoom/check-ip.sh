#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
exec docker compose run --rm claude-code ai-ip-purity-container

