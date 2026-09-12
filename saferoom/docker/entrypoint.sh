#!/usr/bin/env bash
set -euo pipefail

mkdir -p /home/node/.claude /home/node/.zsh_history_store /workspace

if [[ ! -f /home/node/.zshrc ]]; then
  cat > /home/node/.zshrc <<'ZSHRC'
export HISTFILE=/home/node/.zsh_history_store/.zsh_history
export SAVEHIST=10000
export HISTSIZE=10000
export CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-/home/node/.claude}
alias ll='ls -lah'
alias check='saferoom-check-env'
alias ipcheck='ai-ip-purity-container'
ZSHRC
fi

exec "$@"

