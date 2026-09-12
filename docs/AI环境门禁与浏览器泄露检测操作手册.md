# AI 环境门禁与浏览器泄露检测操作手册

本文档说明以下四个文件的用途和使用方式：

```text
ai_browser_leak_check_cn.sh
ai_browser_leak_check_cdp.py
ai_preflight_fix_cn.sh
ai_preflight_open_cn.sh
```

这几份脚本配合使用，用于检查 Claude / OpenAI 登录前的系统环境、网络环境、浏览器泄露和最终放行条件。

## 1. 文件分工

| 文件 | 作用 | 是否修改系统 | 是否打开浏览器 |
|---|---|---:|---:|
| `ai_browser_leak_check_cn.sh` | 启动专用 Chrome/Edge profile，并自动读取 IP、DNS、WebRTC、JS 时区/语言泄露 | 不改系统，只写专用 profile 偏好 | 会启动专用浏览器 |
| `ai_browser_leak_check_cdp.py` | 被 `ai_browser_leak_check_cn.sh` 调用，通过 Chrome DevTools Protocol 读取网页结果 | 不改系统 | 自己不启动浏览器 |
| `ai_preflight_fix_cn.sh` | 全面体检 + 可选修复 + 可选恢复原环境 | 可能修改，`--check-only` 不改 | 不打开 Claude/OpenAI |
| `ai_preflight_open_cn.sh` | 登录前最后门禁，判断是否适合打开 Claude/OpenAI | 不改系统 | 普通模式可能打开人工检测页 |

## 2. 推荐执行顺序

进入目录：

```bash
cd ai-gatekeeper/scripts
```

推荐流程：

```bash
./ai_preflight_fix_cn.sh --check-only
./ai_browser_leak_check_cn.sh
./ai_preflight_open_cn.sh --check-only
```

含义：

1. `ai_preflight_fix_cn.sh --check-only`：先全面体检，不修改系统。
2. `ai_browser_leak_check_cn.sh`：检查真实浏览器层面的 DNS / WebRTC / JS 时区语言泄露。
3. `ai_preflight_open_cn.sh --check-only`：做最终门禁判断，但不打开浏览器检测页。

如果第一步发现可修复项，再决定是否运行：

```bash
./ai_preflight_fix_cn.sh
```

## 3. 浏览器泄露检测

入口文件：

```bash
./ai_browser_leak_check_cn.sh
```

它会启动专用 Chrome profile，连接本地 DevTools 端口，然后由 `ai_browser_leak_check_cdp.py` 自动读取这些页面或环境：

```text
ipinfo.io/json
browserleaks.com/webrtc
browserleaks.com/dns
dnsleaktest.com
浏览器 JS timezone / language
```

### 常用命令

默认用 Chrome，后台隐藏窗口：

```bash
./ai_browser_leak_check_cn.sh
```

改用 Edge：

```bash
BROWSER=edge ./ai_browser_leak_check_cn.sh
```

显示浏览器窗口，方便人工看页面：

```bash
BACKGROUND=0 ./ai_browser_leak_check_cn.sh
```

检测后保留浏览器窗口：

```bash
KEEP_BROWSER=1 ./ai_browser_leak_check_cn.sh
```

无窗口模式：

```bash
HEADLESS=1 ./ai_browser_leak_check_cn.sh
```

注意：`HEADLESS=1` 会让 UA 显示 HeadlessChrome，不适合作最终风控判断，只适合快速排查。

### 关键环境变量

| 变量 | 默认值 | 作用 |
|---|---|---|
| `BROWSER` | `chrome` | 选择 `chrome` 或 `edge` |
| `BACKGROUND` | `1` | 是否把真实浏览器隐藏到后台 |
| `HEADLESS` | `0` | 是否无窗口运行 |
| `KEEP_BROWSER` | `0` | 检测后是否保留本次浏览器进程 |
| `REMOTE_PORT` | Chrome `9223` / Edge `9224` | DevTools 调试端口 |
| `PAGE_TIMEOUT` | `20` | 单个检测页超时秒数 |
| `TARGET_TIMEZONE` | `America/Los_Angeles` | 目标 JS 时区 |
| `TARGET_LANGUAGE` | `en-US` | 目标浏览器语言 |

### 结果怎么看

重点看：

- WebRTC 候选里是否出现真实公网 IPv4。
- DNS 页面是否出现中国大陆、运营商、114、阿里、腾讯 DNS。
- JS timezone 是否为 `America/Los_Angeles`。
- JS language / languages 是否包含 `en-US`。
- IP 页面是否与 AI 分流出口一致。

如果自动读取提示“仍需人工复核”，以浏览器页面真实显示为准。

## 4. CDP 读取器

文件：

```text
ai_browser_leak_check_cdp.py
```

这个文件不是日常直接运行的入口。它由 `ai_browser_leak_check_cn.sh` 调用。

它负责：

- 连接 Chrome / Edge 的 DevTools WebSocket。
- 打开检测页面。
- 读取页面文本。
- 执行本地 JS 检测 WebRTC、timezone、language。
- 输出自动判断和人工复核项。

除非你在调试脚本本身，否则不要单独运行它。

## 5. 全面体检与可选修复

入口文件：

```bash
./ai_preflight_fix_cn.sh
```

它检查六类问题：

```text
1. 专用 Chrome/Edge profile 的 WebRTC 防泄露配置
2. macOS 系统时区、语言、地区、单位
3. IPv6 直连泄露
4. 系统 DNS
5. Claude/OpenAI 分流出口和 IP 纯净度
6. 浏览器人工确认项
```

### 只检测，不修改

推荐先运行：

```bash
./ai_preflight_fix_cn.sh --check-only
```

这会输出问题列表、可自动修复项、必须人工确认项，但不会修改系统。

### 检测后确认修复

```bash
./ai_preflight_fix_cn.sh
```

如果发现可自动修复项，会弹窗确认。确认后可能执行：

- 写入专用 Chrome/Edge profile 的 WebRTC 防泄露配置。
- 设置 macOS 时区、语言、地区、单位为美国英文环境。
- 对活跃网络服务关闭 IPv6。
- 把活跃网络服务 DNS 改为 `DNS_SERVERS` 指定值，默认 `1.1.1.1 1.0.0.1`。

### 跳过确认直接修复

```bash
./ai_preflight_fix_cn.sh --yes
```

这个命令会跳过弹窗确认，直接执行可自动修复项。一般不建议日常使用，除非你已经看过 `--check-only` 输出。

### 恢复原环境

这个脚本也有逆向恢复入口：

```bash
./ai_preflight_fix_cn.sh --restore
```

只预览恢复目标，不修改：

```bash
./ai_preflight_fix_cn.sh --restore --check-only
```

跳过确认直接恢复：

```bash
./ai_preflight_fix_cn.sh --restore --yes
```

默认恢复目标：

```text
时区：Asia/Shanghai
语言：zh-Hans-CN
地区：zh_CN
单位：Metric / Centimeters / Celsius
IPv6：Automatic
DNS：Empty，即 DHCP/路由器自动下发
```

恢复模式不会删除专用 Chrome/Edge profile，也不会修改 Clash/Surge 配置文件。

### 常用环境变量

| 变量 | 默认值 | 作用 |
|---|---|---|
| `TARGET_TIMEZONE` | `America/Los_Angeles` | 修复时目标时区 |
| `TARGET_LANGUAGE` | `en-US` | 修复时目标语言 |
| `TARGET_LOCALE` | `en_US` | 修复时目标地区 |
| `DNS_SERVERS` | `1.1.1.1 1.0.0.1` | 修复 DNS 时写入的 DNS |
| `BASE_DIR` | `~/AI-US-Browsers` | 专用浏览器 profile 根目录 |
| `RESTORE_TIMEZONE` | `Asia/Shanghai` | 恢复模式目标时区 |
| `RESTORE_LANGUAGE` | `zh-Hans-CN` | 恢复模式目标语言 |
| `RESTORE_LOCALE` | `zh_CN` | 恢复模式目标地区 |

## 6. 登录前最后门禁

入口文件：

```bash
./ai_preflight_open_cn.sh
```

它的作用不是修复系统，而是判断当前是否适合继续打开 Claude / OpenAI。

它会检查：

- Claude / OpenAI / Anthropic 域名是否走目标国家出口。
- AI 域名是否使用稳定一致的出口 IP。
- 出口 IP 纯净度是否达到阈值。
- DNS、IPv6、时区、语言等关键环境是否符合目标。
- 是否需要人工打开检测页面确认。

### 只检测，不打开检测页

推荐日常使用：

```bash
./ai_preflight_open_cn.sh --check-only
```

### 普通模式

```bash
./ai_preflight_open_cn.sh
```

普通模式会在通过自动检查后，按脚本逻辑打开人工检测页，但不会自动登录 Claude/OpenAI 账号。

### 指定必须使用某个 IP

```bash
EXPECTED_IP=203.0.113.10 ./ai_preflight_open_cn.sh --check-only
```

如果 AI 域名没有全部走这个 IP，会判定不通过。

### 跳过人工检测页

```bash
./ai_preflight_open_cn.sh --skip-manual
```

这只跳过打开人工检测页，不代表 DNS / WebRTC / 指纹已经通过。

### 接受 IP 风险后继续

```bash
ALLOW_RISK=1 ./ai_preflight_open_cn.sh
```

只有在你明确接受“IP 不是完美住宅 / 纯净度不达标”的风险时才使用。它不能解决 DNS、WebRTC、时区、语言、账号历史等问题。

### 常用环境变量

| 变量 | 默认值 | 作用 |
|---|---|---|
| `EXPECTED_IP` | 空 | 要求 Claude/OpenAI 必须走这个出口 IP |
| `MIN_SCORE` | `85` | 住宅/移动 ISP 出口通过阈值 |
| `TARGET_COUNTRY` | `US` | 目标国家 |
| `TARGET_TIMEZONE` | `America/Los_Angeles` | 目标时区 |
| `TARGET_LANGUAGE` | `en-US` | 目标语言 |
| `BROWSER` | `chrome` | 人工检测页使用 Chrome 或 Edge |
| `ALLOW_RISK` | `0` | 是否接受 IP 纯净度不达标风险 |

## 7. 推荐场景命令

### 完整检查，不修改

```bash
cd ai-gatekeeper/scripts
./ai_preflight_fix_cn.sh --check-only
./ai_browser_leak_check_cn.sh
./ai_preflight_open_cn.sh --check-only
```

### 发现环境问题后修复

```bash
cd ai-gatekeeper/scripts
./ai_preflight_fix_cn.sh
```

### 确认固定美国住宅 IP

```bash
cd ai-gatekeeper/scripts
EXPECTED_IP=203.0.113.10 ./ai_preflight_open_cn.sh --check-only
```

### 用 Edge 做浏览器泄露检测

```bash
cd ai-gatekeeper/scripts
BROWSER=edge BACKGROUND=0 KEEP_BROWSER=1 ./ai_browser_leak_check_cn.sh
```

### 恢复中文中国区常规环境

```bash
cd ai-gatekeeper/scripts
./ai_preflight_fix_cn.sh --restore
```

## 8. 判断标准

适合打开 Claude / OpenAI 前，应同时满足：

- AI 域名出口国家符合目标国家。
- AI 域名出口 IP 稳定一致。
- 出口 IP 没有明显 proxy / VPN / Tor / hosting / abuse 高风险。
- DNS 没有中国大陆或运营商泄露。
- WebRTC 没有真实公网 IP 或异常 IPv6 泄露。
- JS timezone、系统时区、浏览器语言与目标环境一致。
- 专用浏览器 profile 没有混用原来的 Cookie、扩展、账号历史。

如果任何一项不确定，先不要登录核心账号，先用 `--check-only` 和浏览器泄露检测把问题定位清楚。

