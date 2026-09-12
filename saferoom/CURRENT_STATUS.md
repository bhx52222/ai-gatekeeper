# 当前状态

检查时间：2026-09-11 Asia/Shanghai

> 本文件记录 SafeRoom 工程能力，不再保存某次网络现场的 IP、地区或失败结论。实时状态以桌面版“开始检测”和 `scripts/safe-run.sh` 输出为准。

## 已完成

- 已在 `ai-gatekeeper/saferoom` 创建 SafeRoom 工程。
- 已生成 `.env`，默认复用 `../scripts` 的主机门禁脚本。
- 已构建镜像 `local/claude-code-saferoom:latest`。
- `./claude-code.sh --version` 可运行，返回 `2.1.141 (Claude Code)`。
- 容器时区、语言、Claude 配置目录隔离正常：
  - `TZ=America/Los_Angeles`
  - `LANG=en_US.UTF-8`
  - `CLAUDE_CONFIG_DIR=/home/node/.claude`

## 实时验收边界

- 桌面版会显示 Docker daemon 是否可用，但不会把 Docker 未运行判定为主机门禁失败。
- `scripts/safe-run.sh` 负责完整容器验收：主机门禁、Compose 配置、容器环境和容器内 AI 出口。
- `.env` 只保存在本机；仓库只提交 `.env.example`。
- 出口 IP、DNS、IPv6、时区和语言都必须按当前运行态重新检测，不能沿用本文件的历史结果。

## 下一步

1. 先用桌面版检查多域名出口和浏览器真实运行态；需要时再修改明确失败的项目。
2. 在 `../scripts` 里先跑：

```bash
./ai_preflight_fix_cn.sh --check-only
./ai_browser_leak_check_cn.sh
./ai_preflight_open_cn.sh --check-only
```

3. 主机层通过后回到 SafeRoom：

```bash
cd ai-gatekeeper/saferoom
./scripts/safe-run.sh
```

4. 只有 `safe-run.sh` 通过后，再运行：

```bash
./claude-code.sh
```
