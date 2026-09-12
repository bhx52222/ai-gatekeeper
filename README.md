# ai-gatekeeper · AI 环境门禁与隐私检测

> 在使用 Claude / OpenAI 等海外 AI 服务前，检测本机网络出口纯净度、浏览器指纹/语言/WebRTC 泄露风险，
> 并提供一键修复。Docker 隔离层（SafeRoom）为**可选优化**，不装 Docker 也能用全部核心功能。

## 桌面版 App

桌面版提供统一的 macOS / Windows 图形界面：

- 一键检测时区、语言地区、DNS、IPv6、代理出口和专用浏览器配置；
- 同时核对 Claude、Anthropic、ChatGPT、OpenAI、Gemini、Grok 的 16 个入口；支持 Cloudflare trace 的入口显示实际出口，Google 等不支持该接口的入口明确标为“出口未确认”；
- 可指定目标国家、固定出口 IP、代理地址、时区和语言，不再写死单一环境；
- 查询出口 ASN、网络类型及机房/代理/VPN/Tor/滥用风险标记；
- 可实际启动专用 Edge/Chrome，读取浏览器出口、JavaScript 时区、语言和 WebRTC 候选；
- 每个可修复项目都能单独勾选；
- “一键修改”只处理明确建议修改的项目；自动 DNS 等待真实泄露检测后再决定；
- macOS 可开启境外流量代理安全阀：LAN 与中国大陆目标直连，其余连接强制走指定 Claude 固定出口，并实时复核出口国家/IP；
- 本轮第一次修改前保存不可变基线，“一键恢复”直接回到该基线并逐项复核；历史记录单独保留；
- macOS 输出 DMG/ZIP，Windows 输出 NSIS EXE 安装包和便携 EXE。

本地开发与打包：

```bash
npm install
npm start
npm run dist:mac
```

Windows 安装程序由 `.github/workflows/build-installers.yml` 在 Windows runner 上构建，也可以在 Windows 本机运行 `npm run dist:win`。

### 使用顺序

1. 展开“检测目标与代理设置”，填写实际代理；macOS 默认使用 Surge `http://127.0.0.1:6152`，Windows 留空时按系统当前链路检测。
2. 如需固定住宅出口，在“指定出口 IP”填写实际 IP。留空时仍会比较能够确认出口的域名。
3. 点击“开始检测”。系统配置检测不会打开账号页面。
4. 点击“浏览器深度检测”，程序会使用仓库外的专用 Edge/Chrome 档案访问 IP 检测页，读取真实浏览器运行态，然后关闭本次启动的进程。
5. 修改系统项后点击“一键恢复”，直接回到本轮第一次修改前的状态。原始值会立即写回；系统菜单或已打开应用的显示语言可能需要退出登录后刷新，通常无需重启电脑。
6. macOS 的“境外流量代理安全阀”依赖 Surge 和指定策略组。开启时会加入最高优先级临时规则，关闭时只撤销本应用加入的规则。Surge 重启后 App 会显示规则已丢失，需重新开启。Windows 版在配置兼容的规则代理控制器前会明确显示不可用。

“出口 IP 质量”来自第三方情报库，只作为风险提示；最终应结合实际分流、浏览器泄露和账号使用历史判断。

## 项目结构

```
ai-gatekeeper/
├── scripts/                          # ★ 核心：主机层门禁脚本（必须，无需 Docker）
│   ├── ai_ip_purity_check.sh         #   IP 纯净度检测（出口 IP / 落地国家 / 评分）
│   ├── ai_preflight_open_cn.sh       #   使用 AI 前的整体预检（一键）
│   ├── ai_preflight_fix_cn.sh        #   预检发现问题后的一键修复
│   ├── ai_browser_leak_check_cn.sh   #   浏览器泄露检测（语言/时区/WebRTC）
│   └── ai_browser_leak_check_cdp.py  #   CDP 深度版泄露检测（配合 9222 端口）
│
├── docs/                             # 操作手册（含结果解读与排障）
│   ├── AI-IP纯净度检测操作手册.md
│   └── AI环境门禁与浏览器泄露检测操作手册.md
│
└── saferoom/                         # ◇ 可选优化：Docker 隔离运行环境
    ├── Dockerfile  docker-compose.yml  .env.example
    ├── claude-code.sh  shell.sh          # 容器内启动器
    ├── scripts/host-gate.sh              # 调用 ../scripts 主机门禁后再进容器
    └── CURRENT_STATUS.md                 # 工程状态记录
```

## 快速开始（不需要 Docker）

```bash
cd ai-gatekeeper/scripts

# 1. 检测 IP 纯净度
./ai_ip_purity_check.sh

# 2. 整体预检（IP + 系统环境 + 浏览器泄露）
./ai_preflight_open_cn.sh --check-only

# 3. 有问题就一键修复
./ai_preflight_fix_cn.sh
```

如果你已知自己的目标出口 IP，可以强制校验（把占位 IP 换成你自己的）：

```bash
EXPECTED_IP=203.0.113.10 ./ai_ip_purity_check.sh
```

## 可选：SafeRoom Docker 隔离层

在主机门禁通过后，把 AI CLI 放进时区/语言/DNS 均已伪装对齐的容器里运行，
进一步隔离本机指纹。**这是优化项，不是必需品**——核心检测与修复全部在 `scripts/` 完成。

```bash
cd saferoom
cp .env.example .env     # 按需填写（代理、目标国家、期望 IP 等）
docker compose build
./claude-code.sh         # 容器内启动 Claude Code
```

## 占位符说明（其他用户按需替换）

| 占位符 | 含义 | 填什么 |
|---|---|---|
| `203.0.113.10` | 示例出口 IP | 你自己的代理落地 IP |
| `.env` 中 `EXPECTED_IP=` | 期望出口 IP | 留空=不校验，或填你的 IP |
| `.env` 中 `HTTP_PROXY=` 等 | 代理地址 | 按你的代理软件端口填 |
| 浏览器 profile 路径 | 脚本运行时自动探测 | 一般无需手填 |

## 安全红线

- 任何浏览器 profile、cookie、登录态目录**永不入库**（.gitignore 已强制屏蔽）
- `.env` 不入库，只提交 `.env.example`
- 本仓库不含任何真实 IP / 账号 / 凭据，全部为占位符
