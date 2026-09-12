# AI IP 纯净度检测操作手册

本文档用于说明 `ai-gatekeeper/scripts/ai_ip_purity_check.sh` 的用途、运行方式和结果解读。

## 1. 这个脚本做什么

`ai_ip_purity_check.sh` 是中文 IP 质量体检脚本，带 Claude / OpenAI / Anthropic 增强检测。

它主要检查三件事：

1. Claude / OpenAI 相关域名是否都走同一个目标出口 IP。
2. 这个出口 IP 是否像干净的美国住宅 / 移动 ISP，而不是机房、代理、VPN、Tor 或高风险 IP。
3. 常见 AI、流媒体和平台网站是否能在后台 HTTP 层面访问。

它不会修改系统设置，不会打开浏览器，也不会登录任何账号。

## 2. 它会检测哪些内容

### 2.1 AI 域名分流检测

脚本会逐个检测以下 AI 域名的实际出口：

```text
claude.ai
api.anthropic.com
console.anthropic.com
chatgpt.com
api.openai.com
platform.openai.com
auth.openai.com
ios.chat.openai.com
```

理想状态是这些域名都显示同一个出口 IP，并且国家为 `US`。

### 2.2 平台连通检测

脚本还会用后台 HTTP 请求检测这些平台：

```text
Claude
Anthropic API
Anthropic Console
ChatGPT
OpenAI API
OpenAI Platform
YouTube
TikTok
Netflix
Disney+
Amazon Prime Video
Reddit
GitHub
Google Search
X/Twitter
```

这部分对齐 `IPQuality` 的思路：不只看 Claude / OpenAI，也看流媒体和常见外网平台。

注意：Claude、ChatGPT、OpenAI Platform 这类网页经常会对命令行 `curl` 返回 `403`，这通常表示“需要真实浏览器复核”，不等于账号一定不可用。

## 3. 依赖

脚本需要这些命令：

```bash
curl
jq
awk
sort
uniq
```

如果缺少 `jq`，可以安装：

```bash
brew install jq
```

## 4. 基本用法

进入目录：

```bash
cd ai-gatekeeper/scripts
```

直接检测：

```bash
./ai_ip_purity_check.sh
```

这会输出：

- AI 域名实际出口 IP
- Cloudflare 国家和机房代码
- 类似 IPQuality 的分区报告
- 多数据源 IP 情报
- 风险因子投票
- AI / 流媒体 / 常见平台连通状态
- 最终分数和判断

## 5. 指定必须使用某个 IP

如果你已经知道目标美国住宅 IP，例如 `203.0.113.10`，可以强制检查所有 AI 域名是否都走这个 IP：

```bash
EXPECTED_IP=203.0.113.10 ./ai_ip_purity_check.sh
```

也可以用参数：

```bash
./ai_ip_purity_check.sh --expected-ip 203.0.113.10
```

如果某个域名没有走这个 IP，会显示：

```text
EXPECTED_IP_MISMATCH
```

## 6. 修改目标国家

默认目标国家是美国：

```text
US
```

如果以后要检测日本出口：

```bash
./ai_ip_purity_check.sh --country JP
```

或者：

```bash
TARGET_COUNTRY=JP ./ai_ip_purity_check.sh
```

## 7. 保存 JSON 报告

输出 JSON 到终端：

```bash
./ai_ip_purity_check.sh --json
```

保存 JSON 到文件：

```bash
./ai_ip_purity_check.sh --output ai-ip-purity-current.json
```

推荐保存到当前目录：

```bash
./ai_ip_purity_check.sh --output ai-gatekeeper/scripts/ai-ip-purity-current.json
```

JSON 报告适合做历史对比，例如比较不同节点、不同机场、不同住宅 IP 的结果。

## 8. 调整超时

如果网络较慢，可以把单次请求超时调大：

```bash
./ai_ip_purity_check.sh --timeout 30
```

或者：

```bash
TIMEOUT=30 ./ai_ip_purity_check.sh
```

## 9. 调整 PASS 阈值

默认 `PASS` 阈值是 `85` 分：

```bash
./ai_ip_purity_check.sh --min-score 85
```

如果你想更严格：

```bash
./ai_ip_purity_check.sh --min-score 90
```

不建议为了让结果好看而降低阈值。分数偏低时，应优先看具体原因。

## 10. 结果怎么看

### 10.1 AI 域名分流检测

示例：

```text
Claude Web           claude.ai                203.0.113.10   US   LAX   正常
OpenAI API           api.openai.com           203.0.113.10   US   LAX   正常
```

重点看：

- `ip`：是否都是同一个目标 IP
- `loc`：是否为 `US`
- 是否出现 `无法检测`
- 是否出现 `国家不符`
- 是否出现 `IP不符`

如果 AI 域名分散到多个 IP，说明分流规则不稳定，不建议登录核心账号。

### 10.2 IP 质量检查

示例：

```text
综合分数     82/100
结论           谨慎：可用但不够理想
扣分原因：
  - 部分数据源标记为机房/托管/server
```

常见结论：

`PASS`：

表示国家一致，并且没有明显 proxy / VPN / Tor / hosting / abuse 风险。比较接近干净住宅或移动 ISP。

`谨慎`：

表示可能可用，但不是理想住宅 IP。常见原因是部分数据库把它标成 hosting、business 或 datacenter。

`失败`：

表示不建议用于 Claude / OpenAI 核心账号。常见原因是国家不符、proxy/VPN/Tor 标记、高风险、明显机房 IP。

### 10.3 平台连通检测

示例：

```text
Claude                 AI       可达-浏览器复核 403
OpenAI API             AI       可达-需认证     401
YouTube                流媒体   可达           200
Netflix                流媒体   可达           200
```

常见状态：

`可达`：后台 HTTP 请求成功。

`可达-需认证`：接口通路可达，但需要账号或 API key。

`可达-浏览器复核`：后台命令行被网站拦截，需要用真实浏览器确认。

`受限` / `地区屏蔽`：可能存在平台限制，需要结合真实浏览器再确认。

`失败`：后台请求没有成功，可能是网络、DNS、代理或平台策略问题。

## 11. 风险因子说明

脚本会输出类似：

```text
投票：country=3/3 server=2 proxy=0 vpn=0 tor=0 abuse=0
```

含义：

```text
country_confirmed=3/3
```

三个数据源都确认国家符合目标国家。

```text
server
```

有多少信号认为这个 IP 接近机房、hosting、server、商业网络。

```text
proxy
```

是否被标记为代理。

```text
vpn
```

是否被标记为 VPN。

```text
tor
```

是否被标记为 Tor。

```text
abuse
```

是否有滥用或高风险信号。

对 Claude / OpenAI 来说，最理想的是：

```text
country_confirmed=3/3 server=0 proxy=0 vpn=0 tor=0 abuse=0
```

## 12. 和 IPQuality 的关系

`IPQuality` 是通用 IP 体检工具，检测范围更广，包括流媒体、邮件、黑名单、多平台解锁等。

`ai_ip_purity_check.sh` 是 AI 增强版中文检测脚本，优势是：

- 专门检测 Claude / OpenAI / Anthropic 域名。
- 能确认这些域名是否真的走同一个出口。
- 支持 `EXPECTED_IP`，适合验证美国住宅专线。
- 增加 Claude、ChatGPT、OpenAI、YouTube、TikTok、Netflix、Reddit 等后台连通检测。
- 输出更贴合 AI 登录前判断。

推荐关系：

```text
ai_ip_purity_check.sh
用于确认 AI 域名分流和基础纯净度。

IPQuality/ip.sh
用于对同一个出口 IP 做更广泛的第三方体检。
```

## 13. 推荐日常流程

### 只想快速确认 AI 出口

```bash
cd ai-gatekeeper/scripts
./ai_ip_purity_check.sh
```

### 已知目标 IP，严格确认

```bash
cd ai-gatekeeper/scripts
EXPECTED_IP=203.0.113.10 ./ai_ip_purity_check.sh
```

### 保存一份检测报告

```bash
cd ai-gatekeeper/scripts
./ai_ip_purity_check.sh --output ai-ip-purity-current.json
```

### 配合 IPQuality 做完整 IP 体检

```bash
cd scripts/IPQuality
bash ip.sh -4 -f -p
```

## 14. 在整套门禁流程里的位置

推荐顺序：

```bash
cd ai-gatekeeper/scripts

./ai_preflight_fix_cn.sh --check-only
./ai_ip_purity_check.sh
./ai_browser_leak_check_cn.sh
./ai_preflight_open_cn.sh --check-only
```

含义：

```text
ai_preflight_fix_cn.sh --check-only
检查系统、DNS、IPv6、浏览器 profile，不修改系统。

ai_ip_purity_check.sh
检查 AI 域名出口是否一致，IP 是否像干净住宅。

ai_browser_leak_check_cn.sh
检查真实浏览器 DNS / WebRTC / JS 时区语言泄露。

ai_preflight_open_cn.sh --check-only
做最后登录前门禁判断。
```

## 15. 注意事项

- 这个脚本不会替代 DNS 泄露检测。
- 这个脚本不会替代 WebRTC 检测。
- 这个脚本不会判断浏览器 Cookie、账号历史、手机号、支付地区等账号因素。
- 如果结果是 `CAUTION`，不要只看分数，要看 `Reasons`。
- 如果结果是 `FAIL`，不建议登录核心账号。
- 如果 AI 域名没有走同一个 IP，应先修复分流规则。
