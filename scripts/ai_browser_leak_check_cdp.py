#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import re
import signal
import socket
import struct
import sys
import time
import urllib.parse
import urllib.request

try:
    sys.stdout.reconfigure(line_buffering=True)
except Exception:
    pass


class CDPError(RuntimeError):
    pass


class WebSocket:
    def __init__(self, ws_url: str, timeout: int = 30):
        parsed = urllib.parse.urlparse(ws_url)
        if parsed.scheme != "ws":
            raise CDPError(f"只支持 ws:// URL: {ws_url}")
        self.host = parsed.hostname or "127.0.0.1"
        self.port = parsed.port or 80
        self.path = parsed.path
        if parsed.query:
            self.path += "?" + parsed.query
        self.sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self.sock.settimeout(timeout)
        self._handshake()

    def _handshake(self):
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            data += chunk
        if b" 101 " not in data.split(b"\r\n", 1)[0]:
            raise CDPError("Chrome DevTools WebSocket 握手失败")

        accept_src = (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        expected = base64.b64encode(hashlib.sha1(accept_src).digest()).decode()
        if expected.encode() not in data:
            raise CDPError("Chrome DevTools WebSocket 握手校验失败")

    def send_json(self, payload):
        data = json.dumps(payload, separators=(",", ":")).encode()
        header = bytearray([0x81])
        length = len(data)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header += struct.pack("!H", length)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", length)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(header + masked)

    def recv_json(self):
        while True:
            first = self.sock.recv(2)
            if len(first) < 2:
                raise CDPError("WebSocket 连接中断")
            opcode = first[0] & 0x0F
            length = first[1] & 0x7F
            masked = bool(first[1] & 0x80)
            if length == 126:
                length = struct.unpack("!H", self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv_exact(8))[0]
            mask = self._recv_exact(4) if masked else b""
            data = self._recv_exact(length)
            if masked:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 8:
                raise CDPError("WebSocket 已关闭")
            if opcode == 9:
                self._send_pong(data)
                continue
            if opcode in (1, 2):
                return json.loads(data.decode("utf-8", errors="replace"))

    def _recv_exact(self, length: int) -> bytes:
        chunks = []
        got = 0
        while got < length:
            chunk = self.sock.recv(length - got)
            if not chunk:
                raise CDPError("WebSocket 连接中断")
            chunks.append(chunk)
            got += len(chunk)
        return b"".join(chunks)

    def _send_pong(self, data: bytes):
        header = bytearray([0x8A, 0x80 | len(data)])
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        self.sock.sendall(header + masked)

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


class CDP:
    def __init__(self, ws_url: str, timeout: int):
        self.ws = WebSocket(ws_url, timeout=timeout)
        self.next_id = 1

    def call(self, method, params=None, timeout=30):
        msg_id = self.next_id
        self.next_id += 1
        self.ws.send_json({"id": msg_id, "method": method, "params": params or {}})
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self.ws.recv_json()
            if msg.get("id") == msg_id:
                if "error" in msg:
                    raise CDPError(f"{method} 失败: {msg['error']}")
                return msg.get("result", {})
        raise CDPError(f"{method} 超时")

    def close(self):
        self.ws.close()


def http_json(url, timeout=10):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def wait_for_cdp(port, timeout):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            return http_json(f"http://127.0.0.1:{port}/json/version", timeout=2)
        except Exception as exc:
            last = exc
            time.sleep(0.3)
    raise CDPError(f"无法连接 Chrome DevTools 端口 127.0.0.1:{port}: {last}")


def new_target(port):
    urls = [
        f"http://127.0.0.1:{port}/json/new?about:blank",
        f"http://127.0.0.1:{port}/json/list",
    ]
    try:
        return http_json(urls[0], timeout=5)
    except Exception:
        targets = http_json(urls[1], timeout=5)
        pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
        if not pages:
            raise
        return pages[0]


def js_string(value: str) -> str:
    return json.dumps(value)


def eval_js(cdp, expression, timeout=30, await_promise=False):
    result = cdp.call(
        "Runtime.evaluate",
        {
            "expression": expression,
            "returnByValue": True,
            "awaitPromise": await_promise,
        },
        timeout=timeout,
    )
    remote = result.get("result", {})
    if "value" in remote:
        return remote["value"]
    if "description" in remote:
        return remote["description"]
    return None


def navigate(cdp, url, wait=6, timeout=20):
    cdp.call("Page.navigate", {"url": url}, timeout=min(10, timeout))
    deadline = time.time() + max(0, timeout)
    while time.time() < deadline:
        try:
            state = eval_js(cdp, "document.readyState", timeout=2)
            if state in ("interactive", "complete"):
                break
        except Exception:
            pass
        time.sleep(0.5)
    time.sleep(min(wait, max(0, deadline - time.time())))


def page_text(cdp, max_len=12000):
    text = eval_js(cdp, "(document.body && document.body.innerText) || (document.documentElement && document.documentElement.innerText) || ''", timeout=10)
    if not isinstance(text, str):
        return ""
    text = re.sub(r"\n{3,}", "\n\n", text.strip())
    return text[:max_len]


def lines_matching(text, patterns, limit=40):
    out = []
    for line in text.splitlines():
        clean = re.sub(r"\s+", " ", line).strip()
        if not clean:
            continue
        if any(re.search(p, clean, re.I) for p in patterns):
            out.append(clean)
        if len(out) >= limit:
            break
    return out


def webrtc_probe(cdp):
    script = r"""
new Promise(async (resolve) => {
  const out = {supported: !!window.RTCPeerConnection, candidates: [], error: null};
  if (!out.supported) { resolve(out); return; }
  try {
    const pc = new RTCPeerConnection({iceServers: [{urls: 'stun:stun.l.google.com:19302'}]});
    pc.createDataChannel('probe');
    pc.onicecandidate = (ev) => {
      if (ev.candidate && ev.candidate.candidate) out.candidates.push(ev.candidate.candidate);
    };
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    setTimeout(() => {
      try { pc.close(); } catch(e) {}
      resolve(out);
    }, 5000);
  } catch (e) {
    out.error = String(e && e.message || e);
    resolve(out);
  }
})
"""
    return eval_js(cdp, script, timeout=12, await_promise=True)


def js_environment(cdp):
    script = r"""
(() => ({
  href: location.href,
  timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  language: navigator.language,
  languages: navigator.languages,
  platform: navigator.platform,
  userAgent: navigator.userAgent,
  screen: {width: screen.width, height: screen.height, colorDepth: screen.colorDepth},
  date: new Date().toString()
}))()
"""
    return eval_js(cdp, script, timeout=10)


def dnsleaktest_click_standard(cdp):
    script = r"""
(() => {
  const texts = ['Standard test', '标准测试'];
  const nodes = [...document.querySelectorAll('a,button,input')];
  for (const el of nodes) {
    const label = ((el.innerText || el.value || el.getAttribute('aria-label') || '') + '').trim();
    if (texts.some(t => label.toLowerCase().includes(t.toLowerCase()))) {
      el.click();
      return label;
    }
  }
  return '';
})()
"""
    return eval_js(cdp, script, timeout=10)


def summarize_public_ip(text):
    patterns = [
        r"\b(?:\d{1,3}\.){3}\d{1,3}\b",
        r"\b(?:US|United States|HK|Hong Kong|SG|Singapore|China|CN)\b",
        r"\b(?:ASN|ISP|Organization|Hostname|City|Region|Country)\b",
    ]
    return lines_matching(text, patterns, limit=35)


def summarize_dns(text):
    patterns = [
        r"\b(?:\d{1,3}\.){3}\d{1,3}\b",
        r"\b(?:DNS|ISP|Provider|Country|Leak|Server|Cloudflare|Google|China|Tencent|Alibaba|114|Hong Kong|Singapore|United States)\b",
    ]
    return lines_matching(text, patterns, limit=45)


def summarize_webrtc_page(text):
    patterns = [
        r"\b(?:WebRTC|Public IP|Local IP|IPv6|IPv4|mDNS|candidate|leak|STUN|Host|srflx)\b",
        r"\b(?:\d{1,3}\.){3}\d{1,3}\b",
    ]
    return lines_matching(text, patterns, limit=45)


def print_section(title):
    print()
    print("-" * 60)
    print(title)


def print_lines(lines, empty_msg="未读取到明确结果。"):
    if not lines:
        print(empty_msg)
        return
    for line in lines:
        print(f"  {line}")


class StepTimeout(RuntimeError):
    pass


def _alarm_handler(signum, frame):
    raise StepTimeout("单项检测超时")


def run_step(title, fn, manual, timeout):
    print_section(title)
    old_handler = signal.getsignal(signal.SIGALRM)
    signal.signal(signal.SIGALRM, _alarm_handler)
    signal.alarm(timeout)
    try:
        fn()
        return True
    except StepTimeout:
        msg = f"{title} 超过 {timeout} 秒未完成，已跳过。"
        print(msg)
        manual.append(msg)
        return False
    except Exception as exc:
        msg = f"{title} 自动读取失败：{exc}"
        print(msg)
        manual.append(msg)
        return False
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=int, default=45)
    parser.add_argument("--page-timeout", type=int, default=20)
    parser.add_argument("--target-timezone", default="America/Los_Angeles")
    parser.add_argument("--target-language", default="en-US")
    args = parser.parse_args()

    wait_for_cdp(args.port, args.timeout)
    target = new_target(args.port)
    ws_url = target.get("webSocketDebuggerUrl")
    if not ws_url:
        raise CDPError("没有拿到 page WebSocketDebuggerUrl")

    cdp = CDP(ws_url, timeout=args.timeout)
    findings = []
    manual = []
    try:
        cdp.call("Page.enable")
        cdp.call("Runtime.enable")

        def step_ip():
            navigate(cdp, "https://ipinfo.io/json", wait=2, timeout=args.page_timeout)
            ip_text = page_text(cdp)
            print_lines(summarize_public_ip(ip_text), "ipinfo 页面未读到明确 IP/地区文本。")

        def step_webrtc():
            navigate(cdp, "https://browserleaks.com/webrtc", wait=4, timeout=args.page_timeout)
            webrtc_text = page_text(cdp)
            print("页面可见关键信息：")
            print_lines(summarize_webrtc_page(webrtc_text), "browserleaks WebRTC 页面未读到明确文本。")
            probe = webrtc_probe(cdp)
            print("浏览器内 RTCPeerConnection 候选：")
            print(json.dumps(probe, ensure_ascii=False, indent=2))
            candidates = probe.get("candidates", []) if isinstance(probe, dict) else []
            raw_candidates = "\n".join(candidates)
            public_ipv4 = sorted(set(re.findall(r"\b(?!0\.0\.0\.0)(?!127\.)(?!10\.)(?!172\.(?:1[6-9]|2\d|3[01])\.)(?!192\.168\.)(?:\d{1,3}\.){3}\d{1,3}\b", raw_candidates)))
            if public_ipv4:
                findings.append("WebRTC 候选里出现公网 IPv4：" + ", ".join(public_ipv4))
            else:
                print("判定：本地 RTCPeerConnection 未读到公网 IPv4 候选。")

        def step_browserleaks_dns():
            navigate(cdp, "https://browserleaks.com/dns", wait=8, timeout=args.page_timeout)
            dns_text = page_text(cdp)
            print_lines(summarize_dns(dns_text), "browserleaks DNS 页面未读到明确 DNS 结果。")
            if re.search(r"\b(114\.|223\.5\.|223\.6\.|119\.29\.|Tencent|Alibaba|AliDNS|China|CN)\b", dns_text, re.I):
                findings.append("browserleaks DNS 页面文本疑似出现中国大陆/运营商 DNS 关键词。")
            else:
                manual.append("browserleaks DNS 页面未发现常见中国 DNS 关键词，但仍建议人工看一眼完整表格。")

        def step_dnsleaktest():
            navigate(cdp, "https://dnsleaktest.com/", wait=2, timeout=args.page_timeout)
            clicked = dnsleaktest_click_standard(cdp)
            if clicked:
                print(f"已点击：{clicked}")
                time.sleep(min(12, max(1, args.page_timeout - 5)))
            else:
                print("未找到 Standard test 按钮，只读取首页可见文本。")
            dlt_text = page_text(cdp)
            print_lines(summarize_dns(dlt_text), "dnsleaktest 页面未读到明确 DNS 结果。")
            if re.search(r"\b(114\.|223\.5\.|223\.6\.|119\.29\.|Tencent|Alibaba|AliDNS|China|CN)\b", dlt_text, re.I):
                findings.append("dnsleaktest 页面文本疑似出现中国大陆/运营商 DNS 关键词。")
            else:
                manual.append("dnsleaktest 页面未发现常见中国 DNS 关键词；若页面没跑完，需要人工点 Standard test 复核。")

        def step_js_env():
            env = js_environment(cdp)
            print(json.dumps(env, ensure_ascii=False, indent=2))
            if isinstance(env, dict):
                if env.get("timezone") != args.target_timezone:
                    findings.append(f"JS 时区为 {env.get('timezone')}，不是 {args.target_timezone}。")
                langs = env.get("languages") or []
                lang = env.get("language") or ""
                if args.target_language not in [lang, *langs]:
                    findings.append(f"JS 语言为 language={lang}, languages={langs}，未包含 {args.target_language}。")

        run_step("1/5 IP 页面自动读取：ipinfo.io/json", step_ip, manual, args.page_timeout)
        run_step("2/5 WebRTC 自动读取：browserleaks.com/webrtc + 本地 RTCPeerConnection", step_webrtc, manual, args.page_timeout)
        run_step("3/5 DNS 泄露页面自动读取：browserleaks.com/dns", step_browserleaks_dns, manual, args.page_timeout)
        run_step("4/5 DNS 泄露页面自动读取：dnsleaktest.com", step_dnsleaktest, manual, args.page_timeout)
        run_step("5/5 JS 时区/语言自动读取：浏览器运行环境", step_js_env, manual, args.page_timeout)

        print_section("自动化读取结论")
        if findings:
            print("发现问题：")
            for i, item in enumerate(findings, 1):
                print(f"[{i}] {item}")
        else:
            print("未从自动读取结果中发现明确泄露。")

        print()
        print("仍需人工复核：")
        if manual:
            for i, item in enumerate(manual, 1):
                print(f"[{i}] {item}")
        print("[*] 页面结构可能变化，自动读取失败或表格不完整时，以浏览器页面人工结果为准。")
        print("[*] 本脚本没有打开 Claude/OpenAI 网页或 App。")

        return 2 if findings else 0
    finally:
        cdp.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"错误：{exc}", file=sys.stderr)
        raise SystemExit(1)
