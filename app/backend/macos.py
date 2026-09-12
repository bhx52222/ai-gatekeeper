#!/usr/bin/env python3
import json
import os
import re
import base64
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

APP_HOME = Path.home() / "Library/Application Support/AI Gatekeeper"
SNAPSHOT_DIR = APP_HOME / "snapshots"
HISTORY_DIR = APP_HOME / "history"
BASELINE_FILE = APP_HOME / "baseline-snapshot.json"
SAFETY_FILE = APP_HOME / "safety-valve.json"
TARGET_TZ = os.environ.get("TARGET_TIMEZONE", "America/Los_Angeles")
TARGET_LANG = os.environ.get("TARGET_LANGUAGE", "en-US")
TARGET_LOCALE = os.environ.get("TARGET_LOCALE", "en_US")
TARGET_COUNTRY = os.environ.get("TARGET_COUNTRY", "US").upper()
EXPECTED_IP = os.environ.get("EXPECTED_IP", "").strip()
PROXY_URL = os.environ.get("PROXY_URL", "http://127.0.0.1:6152").strip()
BASE_DIR = Path(os.environ.get("BASE_DIR", str(Path.home() / "AI-US-Browsers")))
AI_TARGETS = [
    ("Claude", "claude.ai"), ("Claude", "api.anthropic.com"), ("Claude", "console.anthropic.com"),
    ("ChatGPT", "chatgpt.com"), ("ChatGPT", "api.openai.com"), ("ChatGPT", "platform.openai.com"),
    ("ChatGPT", "auth.openai.com"), ("ChatGPT", "ios.chat.openai.com"),
    ("Gemini", "gemini.google.com"), ("Gemini", "aistudio.google.com"),
    ("Gemini", "generativelanguage.googleapis.com"), ("Gemini", "oauth2.googleapis.com"),
    ("Grok", "grok.com"), ("Grok", "x.ai"), ("Grok", "api.x.ai"), ("Grok", "auth.x.ai"),
]
SURGE_CLI = Path("/Applications/Surge.app/Contents/Applications/surge-cli")
SAFETY_POLICY = os.environ.get("SAFETY_POLICY", "02-固定AI出口")
CN_RULESET = "https://cdn.jsdelivr.net/gh/Hackl0us/SS-Rule-Snippet@master/Rulesets/Surge/Basic/CN.list"
SAFETY_RULES = ["RULE-SET,LAN,DIRECT", f"RULE-SET,{CN_RULESET},DIRECT", "GEOIP,CN,DIRECT,no-resolve", f"FINAL,{SAFETY_POLICY},dns-failed"]


def run(args, timeout=20):
    try:
        proc = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, "", str(exc)


def default_value(key):
    code, out, _ = run(["/usr/bin/defaults", "read", "-g", key])
    return out if code == 0 else None


def languages():
    raw = default_value("AppleLanguages") or ""
    return [line.strip().strip('",') for line in raw.splitlines() if line.strip().strip('",()')]


def timezone():
    try:
        target = os.readlink("/etc/localtime")
        return target.split("/zoneinfo/", 1)[-1]
    except OSError:
        return "unknown"


def network_services():
    code, out, _ = run(["/usr/sbin/networksetup", "-listallnetworkservices"])
    if code != 0:
        return []
    services = [line.strip() for line in out.splitlines()[1:] if line.strip() and not line.startswith("*")]
    _, nwi, _ = run(["/usr/sbin/scutil", "--nwi"])
    physical = []
    for interface in re.findall(r"^\s*(\S+)\s*: flags", nwi, re.MULTILINE):
        if not interface.startswith("utun") and interface not in physical:
            physical.append(interface)
    if physical:
        _, ports, _ = run(["/usr/sbin/networksetup", "-listallhardwareports"])
        for interface in physical:
            for block in ports.split("\n\n"):
                hardware = re.search(r"Hardware Port:\s*(.+)", block)
                device = re.search(r"Device:\s*(\S+)", block)
                if hardware and device and device.group(1) == interface and hardware.group(1) in services:
                    return [hardware.group(1)]
    _, route_out, _ = run(["/sbin/route", "-n", "get", "default"])
    match = re.search(r"interface:\s*(\S+)", route_out)
    default_interface = match.group(1) if match else None
    if default_interface:
        _, ports, _ = run(["/usr/sbin/networksetup", "-listallhardwareports"])
        blocks = ports.split("\n\n")
        for block in blocks:
            hardware = re.search(r"Hardware Port:\s*(.+)", block)
            device = re.search(r"Device:\s*(\S+)", block)
            if hardware and device and device.group(1) == default_interface and hardware.group(1) in services:
                return [hardware.group(1)]
    active = []
    for service in services:
        service = service.strip()
        _, info, _ = run(["/usr/sbin/networksetup", "-getinfo", service])
        match = re.search(r"^IP address:\s*(.+)$", info, re.MULTILINE)
        if match and match.group(1) not in {"none", "0.0.0.0"}:
            active.append(service)
    return active


def service_state(service):
    _, dns, _ = run(["/usr/sbin/networksetup", "-getdnsservers", service])
    dns_values = [] if "aren't any DNS Servers" in dns else [v.strip() for v in dns.splitlines() if v.strip()]
    _, info, _ = run(["/usr/sbin/networksetup", "-getinfo", service])
    ipv6 = "automatic"
    for line in info.splitlines():
        if line.startswith("IPv6:"):
            value = line.split(":", 1)[1].strip().lower()
            ipv6 = "off" if value == "off" else "automatic"
    return {"dns": dns_values, "ipv6": ipv6}


def browser_pref_paths():
    return [
        BASE_DIR / "Chrome-Claude-OpenAI/Default/Preferences",
        BASE_DIR / "Edge-Claude-OpenAI/Default/Preferences",
    ]


def browser_ok(path):
    try:
        data = json.loads(path.read_text())
        rtc = data.get("webrtc", {})
        langs = data.get("intl", {}).get("accept_languages", "")
        return rtc.get("ip_handling_policy") == "disable_non_proxied_udp" and rtc.get("nonproxied_udp_enabled") is False and langs.startswith(TARGET_LANG)
    except Exception:
        return False


def trace_host(target):
    platform, host = target
    code, out, err = run([
        "/usr/bin/curl", "-fsS", "--max-time", "8", "--proxy", PROXY_URL,
        f"https://{host}/cdn-cgi/trace"
    ], timeout=12)
    fields = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
    # Google endpoints do not consistently expose Cloudflare trace. Keep reachability
    # separate from proven egress so the UI never labels an unverified IP as actual.
    if code == 0 and fields.get("ip"):
        return {"platform": platform, "host": host, "ok": True, "confirmed": True, "ip": fields.get("ip", ""), "loc": fields.get("loc", ""), "colo": fields.get("colo", ""), "error": ""}
    probe_code, _, probe_err = run(["/usr/bin/curl", "-sS", "-o", "/dev/null", "--max-time", "8", "--proxy", PROXY_URL, f"https://{host}/"], timeout=12)
    return {"platform": platform, "host": host, "ok": probe_code == 0, "confirmed": False, "ip": "", "loc": "", "colo": "", "error": probe_err or err}


def route_status():
    with ThreadPoolExecutor(max_workers=8) as pool:
        routes = list(pool.map(trace_host, AI_TARGETS))
    good = [r for r in routes if r["confirmed"]]
    ips = sorted({r["ip"] for r in good})
    failures = [r["host"] for r in routes if not r["ok"]]
    unconfirmed = [r["host"] for r in routes if r["ok"] and not r["confirmed"]]
    wrong_country = [r["host"] for r in good if r["loc"] != TARGET_COUNTRY]
    wrong_ip = [r["host"] for r in good if EXPECTED_IP and r["ip"] != EXPECTED_IP]
    passed = not failures and bool(good) and len(ips) == 1 and not wrong_country and not wrong_ip
    lines = [f"{r['platform']} | {r['host']} | " + (f"{r['ip']} {r['loc'] or '-'} {r['colo'] or '-'}" if r['confirmed'] else ("可连接，出口未确认" if r['ok'] else "无法连接")) for r in routes]
    if len(ips) > 1:
        lines.append("发现多个出口 IP：" + ", ".join(ips))
    if failures:
        lines.append("无法连接：" + ", ".join(failures))
    if unconfirmed:
        lines.append("出口未确认：" + ", ".join(unconfirmed))
    if wrong_country:
        lines.append("国家不符：" + ", ".join(wrong_country))
    if wrong_ip:
        lines.append(f"不是指定出口 {EXPECTED_IP}：" + ", ".join(wrong_ip))
    status = "pass" if passed and not unconfirmed else "warn" if passed else "fail"
    return status, "\n".join(lines), (ips[0] if len(ips) == 1 else ""), routes


def ip_quality(ip):
    if not ip:
        return "warn", "出口不唯一，暂不能进行 IP 质量判断。"
    code, out, _ = run(["/usr/bin/curl", "-fsS", "--max-time", "10", "--proxy", PROXY_URL, f"https://api.ipapi.is/?q={ip}"], timeout=14)
    if code != 0:
        return "warn", "IP 情报源暂时不可用；线路检测结果不受影响。"
    try:
        data = json.loads(out)
        loc = data.get("location") or {}
        asn = data.get("asn") or {}
        company = data.get("company") or {}
        flags = {"机房": data.get("is_datacenter"), "代理": data.get("is_proxy"), "VPN": data.get("is_vpn"), "Tor": data.get("is_tor"), "滥用": data.get("is_abuser")}
        risks = [name for name, value in flags.items() if value is True]
        status = "warn" if risks else "pass"
        detail = f"{ip}；{loc.get('country_code', '?')} {loc.get('city', '')}；AS{asn.get('asn', '?')} {asn.get('org', '')}；类型 {asn.get('type') or company.get('type') or 'unknown'}"
        if risks:
            detail += "；风险标记：" + "、".join(risks)
        else:
            detail += "；未发现明显机房/代理/VPN/Tor/滥用标记"
        return status, detail
    except Exception:
        return "warn", "IP 情报返回格式异常；线路检测结果不受影响。"


def recoverable_snapshot():
    if BASELINE_FILE.exists():
        return BASELINE_FILE
    legacy = APP_HOME / "latest-snapshot.json"
    if legacy.exists():
        return legacy
    files = sorted(SNAPSHOT_DIR.glob("*.json")) if SNAPSHOT_DIR.exists() else []
    for path in files:
        try:
            if int(json.loads(path.read_text()).get("version", 1)) < 3:
                return path
        except Exception:
            return path
    return None


def surge(args, timeout=15):
    if not SURGE_CLI.exists():
        return 1, "", "未找到 Surge CLI"
    return run([str(SURGE_CLI), *args], timeout=timeout)


def safety_status():
    desired = SAFETY_FILE.exists()
    code, output, error = surge(["rule", "temp", "list"])
    active = code == 0 and all(rule in output for rule in SAFETY_RULES)
    if not SURGE_CLI.exists():
        return "warn", "当前未安装 Surge，无法启用境外流量安全阀。", False, False
    if active:
        code, out, err = run(["/usr/bin/curl", "-fsS", "--max-time", "10", "--proxy", PROXY_URL, "https://www.cloudflare.com/cdn-cgi/trace"], timeout=14)
        fields = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
        ip, country, colo = fields.get("ip", ""), fields.get("loc", ""), fields.get("colo", "")
        healthy = code == 0 and bool(ip) and country == TARGET_COUNTRY and (not EXPECTED_IP or ip == EXPECTED_IP)
        if healthy:
            return "pass", f"已开启：LAN/中国大陆直连；其余流量强制走 {SAFETY_POLICY}。实测出口 {ip} / {country} / {colo or '-'}。", True, True
        reason = err or f"实测出口 {ip or '无法读取'} / {country or '-'}，不符合目标 {TARGET_COUNTRY}{' / ' + EXPECTED_IP if EXPECTED_IP else ''}"
        return "fail", f"规则已开启，但固定出口健康检查失败：{reason}", True, True
    if desired:
        return "fail", f"安全阀原本已开启，但 Surge 临时规则已丢失（可能重启过 Surge）：{error or '需要重新启用'}", True, False
    return "info", f"未开启。开启后 LAN/中国大陆直连，其余流量强制走 {SAFETY_POLICY}。", False, False


def detect():
    tz = timezone()
    langs = languages()
    locale = default_value("AppleLocale") or "unknown"
    services = network_services()
    states = {name: service_state(name) for name in services}
    dns = sorted({value for state in states.values() for value in state["dns"]})
    risky_dns = [value for value in dns if value.startswith(("114.", "223.5.", "223.6.", "119.29."))]
    _, ipv6_out, _ = run([
        "/usr/bin/env", "-u", "HTTP_PROXY", "-u", "HTTPS_PROXY", "-u", "ALL_PROXY",
        "-u", "http_proxy", "-u", "https_proxy", "-u", "all_proxy",
        "/usr/bin/curl", "--noproxy", "*", "-6", "-fsS", "--max-time", "4", "https://ifconfig.co"
    ], timeout=6)
    route_state, route_detail, route_ip, routes = route_status()
    quality_state, quality_detail = ip_quality(route_ip)
    ports = []
    for port in (6152, 6153):
        code, _, _ = run(["/usr/bin/nc", "-z", "127.0.0.1", str(port)], timeout=3)
        if code == 0:
            ports.append(str(port))
    browser_paths = browser_pref_paths()
    browser_ready = all(browser_ok(path) for path in browser_paths)
    docker_path = shutil.which("docker")
    docker_ready = bool(docker_path and run([docker_path, "info"], timeout=8)[0] == 0)
    safety_state, safety_detail, safety_desired, safety_active = safety_status()
    items = [
        {"id": "system_locale", "title": "时区与语言地区", "status": "pass" if tz == TARGET_TZ and langs[:1] == [TARGET_LANG] and locale.startswith(TARGET_LOCALE) else "fail", "detail": f"当前 {tz} / {langs[0] if langs else 'unknown'} / {locale}；目标 {TARGET_TZ} / {TARGET_LANG} / {TARGET_LOCALE}", "fixable": True},
        {"id": "dns", "title": "系统 DNS", "status": "fail" if risky_dns else ("pass" if dns else "warn"), "detail": f"活跃服务：{', '.join(services) or '未识别'}；DNS：{', '.join(dns) or '自动获取'}", "fixable": True, "recommendedFix": bool(risky_dns)},
        {"id": "ipv6", "title": "IPv6 直连", "status": "fail" if ":" in ipv6_out else "pass", "detail": f"公网 IPv6：{ipv6_out if ':' in ipv6_out else '未检测到直连'}", "fixable": True},
        {"id": "proxy", "title": "本地代理端口", "status": "pass" if len(ports) == 2 else "fail", "detail": f"Surge 可用端口：{', '.join(ports) or '无'}；需要 6152 和 6153", "fixable": False},
        {"id": "route", "title": "AI 多域名实际出口", "status": route_state, "detail": route_detail, "routeDetails": routes, "fixable": False},
        {"id": "safety_valve", "title": "境外流量代理安全阀", "status": safety_state, "detail": safety_detail, "fixable": False, "toggleable": True, "enabled": safety_desired, "active": safety_active},
        {"id": "ip_quality", "title": "出口 IP 质量", "status": quality_state, "detail": quality_detail, "fixable": False},
        {"id": "browser_profile", "title": "专用浏览器防泄露", "status": "pass" if browser_ready else "fail", "detail": f"Chrome/Edge 独立档案：{BASE_DIR}", "fixable": True},
        {"id": "saferoom", "title": "Claude SafeRoom", "status": "pass" if docker_ready else "warn", "detail": "Docker daemon 可用，可继续运行容器门禁" if docker_ready else "Docker 未安装或 daemon 未运行；不影响主机门禁", "fixable": False},
    ]
    return {"platformLabel": "macOS", "items": items, "snapshotAvailable": recoverable_snapshot() is not None}


def create_snapshot(modified_items):
    legacy_snapshot = recoverable_snapshot() if not BASELINE_FILE.exists() else None
    APP_HOME.mkdir(parents=True, exist_ok=True)
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    browser = []
    for index, path in enumerate(browser_pref_paths()):
        record = {"path": str(path), "existed": path.exists(), "content": None}
        if path.exists():
            record["content"] = base64.b64encode(path.read_bytes()).decode()
        browser.append(record)
    state = {
        "version": 3,
        "modifiedItems": list(modified_items),
        "timezone": timezone(),
        "defaults": {
            key: (languages() if key == "AppleLanguages" else default_value(key))
            for key in ["AppleLanguages", "AppleLocale", "AppleMeasurementUnits", "AppleMetricUnits", "AppleTemperatureUnit"]
        },
        "network": {service: service_state(service) for service in network_services()},
        "browser": browser,
    }
    import datetime
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    (HISTORY_DIR / f"change-{stamp}.json").write_text(json.dumps(state, ensure_ascii=False, indent=2))
    if BASELINE_FILE.exists():
        baseline = json.loads(BASELINE_FILE.read_text())
        baseline["modifiedItems"] = sorted(set(baseline.get("modifiedItems", [])) | set(modified_items))
        BASELINE_FILE.write_text(json.dumps(baseline, ensure_ascii=False, indent=2))
    elif legacy_snapshot and legacy_snapshot != BASELINE_FILE:
        baseline = json.loads(legacy_snapshot.read_text())
        baseline["version"] = 3
        baseline["createdAt"] = baseline.get("createdAt", stamp)
        baseline["modifiedItems"] = sorted(set(baseline.get("modifiedItems", [])) | set(modified_items))
        BASELINE_FILE.write_text(json.dumps(baseline, ensure_ascii=False, indent=2))
        shutil.move(str(legacy_snapshot), str(HISTORY_DIR / f"migrated-{legacy_snapshot.name}"))
    else:
        state["version"] = 3
        state["createdAt"] = stamp
        BASELINE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    return state


def run_privileged(commands):
    if not commands:
        return
    APP_HOME.mkdir(parents=True, exist_ok=True)
    fd, script_name = tempfile.mkstemp(prefix="admin-", suffix=".sh", dir=APP_HOME)
    os.close(fd)
    script = Path(script_name)
    script.write_text("#!/bin/bash\nset -e\n" + "\n".join(commands) + "\n")
    script.chmod(0o700)
    applescript = 'on run argv\n do shell script "/bin/bash " & quoted form of item 1 of argv with administrator privileges\nend run'
    try:
        code, _, err = run(["/usr/bin/osascript", "-e", applescript, str(script)], timeout=180)
        if code != 0:
            raise RuntimeError(err or "管理员授权被取消")
    finally:
        script.unlink(missing_ok=True)


def write_browser_prefs():
    for path in browser_pref_paths():
        path.parent.mkdir(parents=True, exist_ok=True)
        try:
            data = json.loads(path.read_text()) if path.exists() else {}
        except json.JSONDecodeError:
            data = {}
        data.setdefault("intl", {})["accept_languages"] = f"{TARGET_LANG},en"
        data["webrtc"] = {"ip_handling_policy": "disable_non_proxied_udp", "multiple_routes_enabled": False, "nonproxied_udp_enabled": False}
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def apply(items):
    allowed = {"system_locale", "dns", "ipv6", "browser_profile"}
    selected = [item for item in items if item in allowed]
    if not selected:
        return {"message": "没有选择可修改项目。"}
    create_snapshot(selected)
    admin = []
    if "system_locale" in selected:
        admin.append(f"/usr/sbin/systemsetup -settimezone {shlex.quote(TARGET_TZ)} >/dev/null")
    services = network_services()
    if "dns" in selected:
        admin.extend(f"/usr/sbin/networksetup -setdnsservers {shlex.quote(service)} 1.1.1.1 1.0.0.1" for service in services)
    if "ipv6" in selected:
        admin.extend(f"/usr/sbin/networksetup -setv6off {shlex.quote(service)}" for service in services)
    run_privileged(admin)
    if "system_locale" in selected:
        run(["/usr/bin/defaults", "write", "-g", "AppleLanguages", "-array", TARGET_LANG, "en"])
        run(["/usr/bin/defaults", "write", "-g", "AppleLocale", TARGET_LOCALE])
        run(["/usr/bin/defaults", "write", "-g", "AppleMeasurementUnits", "-string", "Inches"])
        run(["/usr/bin/defaults", "write", "-g", "AppleMetricUnits", "-bool", "false"])
        run(["/usr/bin/defaults", "write", "-g", "AppleTemperatureUnit", "-string", "Fahrenheit"])
    if "browser_profile" in selected:
        write_browser_prefs()
    return {"message": f"已完成：{', '.join(selected)}。本次修改前快照已保存。"}


def restore():
    snapshot = recoverable_snapshot()
    if snapshot is None:
        return {"message": "没有可用的修改前快照，未执行恢复。"}
    state = json.loads(snapshot.read_text())
    modified = set(state.get("modifiedItems") or ["system_locale", "dns", "ipv6", "browser_profile"])
    admin = []
    if "system_locale" in modified:
        admin.append(f"/usr/sbin/systemsetup -settimezone {shlex.quote(state.get('timezone', 'Asia/Shanghai'))} >/dev/null")
    for service, values in state.get("network", {}).items():
        if "dns" in modified:
            dns = values.get("dns", [])
            dns_args = " ".join(shlex.quote(value) for value in dns) if dns else "Empty"
            admin.append(f"/usr/sbin/networksetup -setdnsservers {shlex.quote(service)} {dns_args}")
        if "ipv6" in modified:
            mode = "-setv6off" if values.get("ipv6") == "off" else "-setv6automatic"
            admin.append(f"/usr/sbin/networksetup {mode} {shlex.quote(service)}")
    run_privileged(admin)
    defaults = state.get("defaults", {})
    for key, value in (defaults.items() if "system_locale" in modified else []):
        if value is None:
            run(["/usr/bin/defaults", "delete", "-g", key])
        elif key == "AppleLanguages":
            run(["/usr/bin/defaults", "write", "-g", key, "-array", *value])
        elif key == "AppleMetricUnits":
            run(["/usr/bin/defaults", "write", "-g", key, "-bool", "true" if str(value) == "1" else "false"])
        else:
            run(["/usr/bin/defaults", "write", "-g", key, "-string", str(value)])
    for record in (state.get("browser", []) if "browser_profile" in modified else []):
        path = Path(record["path"])
        if record.get("existed") and record.get("content"):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(base64.b64decode(record["content"]))
        elif not record.get("existed"):
            path.unlink(missing_ok=True)
    verification = []
    if "system_locale" in modified:
        expected_tz = state.get("timezone", "Asia/Shanghai")
        expected_defaults = state.get("defaults", {})
        actual_langs = languages()
        for label, ok in [
            ("时区", timezone() == expected_tz),
            ("语言", actual_langs == (expected_defaults.get("AppleLanguages") or [])),
            ("地区", default_value("AppleLocale") == expected_defaults.get("AppleLocale")),
        ]:
            verification.append({"item": label, "ok": ok})
    if snapshot == BASELINE_FILE:
        HISTORY_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copy2(snapshot, HISTORY_DIR / f"restored-{state.get('createdAt', 'baseline')}.json")
    snapshot.unlink(missing_ok=True)
    if snapshot != BASELINE_FILE:
        HISTORY_DIR.mkdir(parents=True, exist_ok=True)
        legacy_paths = list(SNAPSHOT_DIR.glob("*.json")) if SNAPSHOT_DIR.exists() else []
        legacy_paths.append(APP_HOME / "latest-snapshot.json")
        for legacy_path in legacy_paths:
            if legacy_path.exists():
                shutil.move(str(legacy_path), str(HISTORY_DIR / f"legacy-{legacy_path.name}"))
    failed = [entry["item"] for entry in verification if not entry["ok"]]
    if failed:
        message = "恢复命令已执行，但复核未通过：" + "、".join(failed)
    else:
        message = "已恢复到本轮第一次修改前的基线，并完成逐项复核。语言或菜单显示可能需要退出登录后刷新，无需重启电脑。"
    return {"message": message, "verification": verification}


def set_safety(enable):
    if not SURGE_CLI.exists():
        return {"message": "未找到 Surge，无法启用境外流量安全阀。"}
    if enable:
        current_status, current_detail, desired, active = safety_status()
        if active and current_status == "pass":
            return {"message": current_detail, "enabled": True, "status": current_status}
        mode_code, mode_out, mode_err = surge(["mode", "get"])
        policy_code, _, policy_err = surge(["policy-group", "get", SAFETY_POLICY])
        if mode_code != 0 or policy_code != 0:
            raise RuntimeError(mode_err or policy_err or f"找不到策略 {SAFETY_POLICY}")
        saved = {}
        if desired:
            try:
                saved = json.loads(SAFETY_FILE.read_text())
            except Exception:
                saved = {}
        previous_mode = saved.get("previousMode", "rule")
        match = re.search(r"Mode:\s*(\S+)", mode_out)
        if match and not saved:
            previous_mode = match.group(1)
        SAFETY_FILE.parent.mkdir(parents=True, exist_ok=True)
        SAFETY_FILE.write_text(json.dumps({"version": 1, "previousMode": previous_mode, "rules": SAFETY_RULES}, ensure_ascii=False, indent=2))
        if previous_mode != "rule":
            code, _, err = surge(["mode", "set", "rule"])
            if code != 0:
                raise RuntimeError(err or "无法切换 Surge 规则模式")
        # Surge inserts each new temporary rule at #0, so add in reverse order.
        for rule in reversed(SAFETY_RULES):
            code, output, err = surge(["rule", "temp", "add", rule])
            if code != 0 and "already" not in (output + err).lower():
                set_safety(False)
                raise RuntimeError(err or output or f"无法加入规则：{rule}")
        status, detail, _, active = safety_status()
        if not active or status != "pass":
            set_safety(False)
            raise RuntimeError(detail)
        return {"message": detail, "enabled": True, "status": status}
    state = {}
    if SAFETY_FILE.exists():
        try:
            state = json.loads(SAFETY_FILE.read_text())
        except Exception:
            state = {}
    for rule in state.get("rules", SAFETY_RULES):
        surge(["rule", "temp", "remove", rule])
    previous_mode = state.get("previousMode")
    if previous_mode and previous_mode != "rule":
        surge(["mode", "set", previous_mode])
    SAFETY_FILE.unlink(missing_ok=True)
    return {"message": "境外流量安全阀已关闭，已撤销本应用加入的临时规则并恢复原模式。", "enabled": False}


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "detect"
    items = [item for item in (sys.argv[2].split(",") if len(sys.argv) > 2 else []) if item]
    try:
        payload = detect() if action == "detect" else apply(items) if action == "apply" else restore() if action == "restore" else set_safety(True) if action == "safety-on" else set_safety(False) if action == "safety-off" else {"message": "未知操作"}
        print(json.dumps(payload, ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"message": f"操作失败：{exc}"}, ensure_ascii=False))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
