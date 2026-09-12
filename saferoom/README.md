# Claude Code SafeRoom

这套工程把两个已有方案合在一起：

- Docker Claude Code 独立环境：Claude Code、Node、DNS、时区、语言、认证目录都在容器内。
- `../scripts` 门禁脚本：主机层先检查 IP 纯净度、Claude/OpenAI 分流、系统环境和浏览器泄露风险。

目标是降低异常环境、DNS 泄露、出口漂移、语言时区不一致、主机配置混用带来的账号风险。它不能保证账号不被封；平台风控还会看付款地区、账号历史、使用行为、频率、设备变化和服务条款。

## 文件分工

| 文件 | 作用 |
|---|---|
| `Dockerfile` / `docker-compose.yml` | 构建并运行隔离的 Claude Code 容器 |
| `.env.example` / `.env` | 配置代理、DNS、目标国家、预期出口 IP |
| `scripts/host-gate.sh` | 调用“完美隐私”脚本做主机层只读门禁 |
| `check-env.sh` | 检查容器内 Claude Code、DNS、出口 IP、配置目录 |
| `check-ip.sh` | 检查容器内 Claude/OpenAI 目标是否走稳定美国出口 |
| `claude-code.sh` | 通过容器运行 Claude Code |
| `shell.sh` | 进入容器 zsh |
| `scripts/safe-run.sh` | 主机门禁、compose 校验、容器检测、容器 IP 快检一键串联 |

## 第一次安装

```bash
cd ai-gatekeeper/saferoom
cp .env.example .env
```

编辑 `.env`，至少确认：

```text
BASE_IMAGE=local/claude-code-docker:latest
WORKSPACE_DIR=./workspace
DOCKER_TZ=America/Los_Angeles
DOCKER_LANG=en_US.UTF-8
DOCKER_DNS_1=1.1.1.1
DOCKER_DNS_2=8.8.8.8
PRIVACY_DIR=../scripts
```

如果 macOS 上的代理在 `7890`：

```text
HTTP_PROXY=http://host.docker.internal:7890
HTTPS_PROXY=http://host.docker.internal:7890
ALL_PROXY=socks5h://host.docker.internal:7890
```

如果已经确认 AI 专用出口 IP，把它写入：

```text
EXPECTED_IP=你的美国出口IP
```

构建镜像：

```bash
docker compose build
```

当前机器已经有上一轮验证过的 `local/claude-code-docker:latest`，所以本工程默认在它上面覆盖 SafeRoom 检测脚本。如果以后要从干净基础镜像全量重建，需要先确保 Docker Hub / npm 拉取链路可用，再把 `BASE_IMAGE` 改成 `node:22-bookworm-slim` 并恢复安装步骤。

## 每次登录 Claude Code 前

先跑完整门禁：

```bash
./scripts/safe-run.sh
```

通过后再启动 Claude Code：

```bash
./claude-code.sh
```

第一次运行会在 Docker volume `claude-code-home` 中保存 Claude Code 登录状态。这个目录独立于 macOS 浏览器 profile。

## 分层排查

只查主机层：

```bash
./scripts/host-gate.sh
```

只查容器环境：

```bash
./check-env.sh
```

只查容器内 AI 出口：

```bash
./check-ip.sh
```

进入容器手工排查：

```bash
./shell.sh
```

## 使用规则

1. 不要在出口 IP、国家、时区、语言不一致时登录核心账号。
2. 不要把日常浏览器 profile、Cookie、SSH 私钥直接挂进容器。
3. 不要频繁切换不同国家、不同 IP 类型、不同代理链路登录同一个账号。
4. `403` 的后台 HTTP 结果不等于真实浏览器不可用，但需要浏览器复核。
5. 主机层需要恢复原设置时，用“完美隐私”里的恢复入口：

```bash
cd ../scripts
./ai_preflight_fix_cn.sh --restore --check-only
./ai_preflight_fix_cn.sh --restore
```

## 推荐闭环

```bash
cd ai-gatekeeper/saferoom
./scripts/safe-run.sh
./claude-code.sh
```

如果门禁失败，先修复主机层或代理链路，再重新运行，不要跳过检测直接登录。
