const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

function candidates() {
  if (process.platform === 'darwin') return [
    ['Microsoft Edge', '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'],
    ['Google Chrome', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome']
  ];
  return [
    ['Microsoft Edge', path.join(process.env['PROGRAMFILES(X86)'] || '', 'Microsoft/Edge/Application/msedge.exe')],
    ['Microsoft Edge', path.join(process.env.PROGRAMFILES || '', 'Microsoft/Edge/Application/msedge.exe')],
    ['Google Chrome', path.join(process.env.PROGRAMFILES || '', 'Google/Chrome/Application/chrome.exe')],
    ['Google Chrome', path.join(process.env['PROGRAMFILES(X86)'] || '', 'Google/Chrome/Application/chrome.exe')]
  ];
}

function browserRoot(name) {
  const base = process.env.BASE_DIR || (process.platform === 'darwin'
    ? path.join(os.homedir(), 'AI-US-Browsers')
    : path.join(process.env.LOCALAPPDATA || os.homedir(), 'AI-Gatekeeper/Browsers'));
  return path.join(base, name.includes('Edge') ? 'Edge-Claude-OpenAI' : 'Chrome-Claude-OpenAI');
}

async function waitJson(url, timeoutMs = 15000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    try { const response = await fetch(url); if (response.ok) return await response.json(); } catch (_) {}
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('无法连接浏览器调试端口；专用浏览器档案可能正在使用。');
}

function cdp(wsUrl) {
  const socket = new WebSocket(wsUrl);
  let seq = 0;
  const pending = new Map();
  const ready = new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', () => reject(new Error('浏览器调试连接失败')), { once: true });
  });
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(String(event.data));
    if (!message.id || !pending.has(message.id)) return;
    const { resolve, reject, timer } = pending.get(message.id);
    pending.delete(message.id); clearTimeout(timer);
    if (message.error) reject(new Error(message.error.message)); else resolve(message.result || {});
  });
  return {
    async call(method, params = {}, timeout = 12000) {
      await ready; const id = ++seq;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} 超时`)); }, timeout);
        pending.set(id, { resolve, reject, timer });
        socket.send(JSON.stringify({ id, method, params }));
      });
    },
    close() { socket.close(); }
  };
}

async function evaluate(client, expression, awaitPromise = false) {
  const result = await client.call('Runtime.evaluate', { expression, awaitPromise, returnByValue: true }, 15000);
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || '浏览器脚本执行失败');
  return result.result?.value;
}

function publicIps(candidatesText) {
  const found = String(candidatesText || '').match(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g) || [];
  return [...new Set(found.filter((ip) => !/^(0\.|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(ip)))];
}

async function audit(settings = {}) {
  const found = candidates().find(([, file]) => file && fs.existsSync(file));
  if (!found) return { ok: false, message: '没有找到 Microsoft Edge 或 Google Chrome。' };
  const [name, executable] = found;
  const port = 19000 + Math.floor(Math.random() * 1000);
  const profile = browserRoot(name);
  fs.mkdirSync(profile, { recursive: true });
  const args = [
    `--user-data-dir=${profile}`, '--profile-directory=Default', '--no-first-run', '--no-default-browser-check',
    `--lang=${settings.targetLanguage || 'en-US'}`, '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
    '--disable-background-networking', `--remote-debugging-port=${port}`, '--new-window', 'about:blank'
  ];
  if (settings.proxyUrl) args.unshift(`--proxy-server=${settings.proxyUrl}`);
  const child = spawn(executable, args, { stdio: 'ignore', windowsHide: true });
  let client;
  try {
    const pages = await waitJson(`http://127.0.0.1:${port}/json`);
    const page = pages.find((item) => item.type === 'page' && item.webSocketDebuggerUrl);
    if (!page) throw new Error('没有取得浏览器页面调试连接。');
    client = cdp(page.webSocketDebuggerUrl);
    await client.call('Runtime.enable'); await client.call('Page.enable');
    const environment = await evaluate(client, `(() => ({timezone:Intl.DateTimeFormat().resolvedOptions().timeZone,language:navigator.language,languages:navigator.languages,userAgent:navigator.userAgent}))()`);
    const webrtc = await evaluate(client, `new Promise(async resolve => { const out={supported:!!window.RTCPeerConnection,candidates:[],error:null}; if(!out.supported)return resolve(out); try{const pc=new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'}]});pc.createDataChannel('probe');pc.onicecandidate=e=>{if(e.candidate)out.candidates.push(e.candidate.candidate)};await pc.setLocalDescription(await pc.createOffer());setTimeout(()=>{pc.close();resolve(out)},5000)}catch(e){out.error=String(e);resolve(out)}})`, true);
    await client.call('Page.navigate', { url: 'https://ipinfo.io/json' });
    await new Promise((resolve) => setTimeout(resolve, 3500));
    const ipText = await evaluate(client, 'document.body ? document.body.innerText : ""');
    let ipInfo = {}; try { ipInfo = JSON.parse(ipText); } catch (_) {}
    const leaked = publicIps((webrtc?.candidates || []).join('\n'));
    const targetLanguage = settings.targetLanguage || 'en-US';
    const targetTimezone = settings.targetTimezone || (process.platform === 'win32' ? 'America/Los_Angeles' : 'America/Los_Angeles');
    const targetCountry = settings.targetCountry || 'US';
    const expectedIp = settings.expectedIp || '';
    const checks = {
      language: String(environment?.language || '').startsWith(targetLanguage),
      timezone: environment?.timezone === targetTimezone || (process.platform === 'win32' && environment?.timezone === 'America/Los_Angeles'),
      webrtc: leaked.length === 0,
      country: Boolean(ipInfo.ip && ipInfo.country === targetCountry),
      expectedIp: !expectedIp || ipInfo.ip === expectedIp
    };
    const ok = Object.values(checks).every(Boolean);
    return { ok, message: `${name}\n档案：${profile}\n浏览器出口：${ipInfo.ip || '无法读取'} ${ipInfo.country || ''} ${ipInfo.city || ''}\nJS 环境：${environment?.timezone || '?'} / ${environment?.language || '?'}\nWebRTC 公网候选：${leaked.length ? leaked.join(', ') : '未发现'}\n结论：${ok ? '深度检测通过' : '存在不一致，详见以上项目'}`, details: { environment, webrtc, ipInfo, checks } };
  } catch (error) {
    return { ok: false, message: `浏览器深度检测失败：${error.message}` };
  } finally {
    if (client) client.close();
    if (process.platform === 'win32' && child.pid) spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true });
    else child.kill('SIGTERM');
  }
}

module.exports = { audit };
