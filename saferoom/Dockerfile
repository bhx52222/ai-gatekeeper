ARG BASE_IMAGE=local/claude-code-docker:latest
ARG CLAUDE_CODE_VERSION=latest

FROM ${BASE_IMAGE}

ENV TZ=America/Los_Angeles \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CONFIG_DIR=/home/node/.claude

USER root

COPY docker/managed-settings.json /etc/claude-code/managed-settings.json
COPY docker/entrypoint.sh /usr/local/bin/saferoom-entrypoint
COPY docker/check-env.sh /usr/local/bin/saferoom-check-env
COPY scripts/ai-ip-purity-container.sh /usr/local/bin/ai-ip-purity-container

RUN chmod +x /usr/local/bin/saferoom-entrypoint /usr/local/bin/saferoom-check-env /usr/local/bin/ai-ip-purity-container \
    && mkdir -p /workspace /home/node/.claude /home/node/.zsh_history_store \
    && chown -R node:node /workspace /home/node/.claude /home/node/.zsh_history_store /etc/claude-code

USER node
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/saferoom-entrypoint"]
CMD ["zsh"]
