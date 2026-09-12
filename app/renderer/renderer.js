const $ = (id) => document.getElementById(id);
let currentItems = [];
let snapshotAvailable = false;

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[char]);
}

function stamp(message) {
  const log = $('log');
  const time = new Date().toLocaleTimeString('zh-CN', { hour12: false });
  log.textContent = log.textContent === '等待操作…' ? `[${time}] ${message}` : `${log.textContent}\n[${time}] ${message}`;
  log.scrollTop = log.scrollHeight;
}

function setBusy(busy) {
  for (const id of ['detect', 'browserAudit', 'fix', 'fixAll', 'restore']) $(id).disabled = busy;
  document.querySelectorAll('.safety-toggle').forEach((button) => { button.disabled = busy; });
  if (!busy) updateButtons();
}

function updateButtons() {
  const fixable = currentItems.filter((item) => item.fixable);
  $('fix').disabled = !fixable.some((item) => document.querySelector(`[data-id="${item.id}"]`)?.checked);
  $('fixAll').disabled = fixable.length === 0;
  $('restore').disabled = !snapshotAvailable;
}

function render(data) {
  currentItems = data.items || [];
  snapshotAvailable = Boolean(data.snapshotAvailable);
  $('platform').textContent = data.platformLabel || '';
  $('empty').classList.add('hidden');
  $('results').classList.remove('hidden');
  const titles = { system_locale: '时区与语言地区', dns: '系统 DNS', ipv6: 'IPv6 直连', proxy: '本地代理状态', route: 'AI 多域名实际出口', safety_valve: '境外流量代理安全阀', ip_quality: '出口 IP 质量', browser_profile: '专用浏览器防泄露', saferoom: 'Claude SafeRoom' };
  $('results').innerHTML = currentItems.map((item) => `
    <article class="card ${item.id === 'route' ? 'route-card' : ''}">
      <input type="checkbox" data-id="${escapeHtml(item.id)}" ${item.fixable && item.status !== 'pass' && item.recommendedFix !== false ? 'checked' : ''} ${item.fixable ? '' : 'disabled'} aria-label="选择 ${escapeHtml(titles[item.id] || item.title)}">
      <div><h3>${escapeHtml(titles[item.id] || item.title)}</h3>${item.id === 'route' ? `<div class="route-scroll">${escapeHtml(item.detail)}</div>` : `<p>${escapeHtml(item.detail)}</p>`}${item.toggleable ? `<button class="safety-toggle ${item.enabled ? 'danger' : 'primary'}" data-enable="${item.enabled ? 'false' : 'true'}">${item.enabled ? '关闭安全阀' : '开启安全阀'}</button>` : ''}</div>
      <span class="badge ${escapeHtml(item.status)}">${escapeHtml(({ pass: '通过', warn: '注意', fail: '未通过', info: '信息' })[item.status] || item.status)}</span>
    </article>`).join('');
  document.querySelectorAll('input[type=checkbox]').forEach((box) => box.addEventListener('change', updateButtons));
  document.querySelectorAll('.safety-toggle').forEach((button) => button.addEventListener('click', async () => {
    setBusy(true);
    const enabling = button.dataset.enable === 'true';
    stamp(enabling ? '正在开启：LAN/中国大陆直连，其余流量固定走 Claude 出口…' : '正在关闭境外流量安全阀…');
    const result = await window.gatekeeper.setSafety(enabling);
    stamp((result.data?.message || result.stderr || result.stdout || `退出代码 ${result.code}`).trim());
    setBusy(false);
    await detect();
  }));
  const failed = currentItems.filter((item) => item.status === 'fail').length;
  const warned = currentItems.filter((item) => item.status === 'warn').length;
  const overall = $('overall');
  overall.className = `overall ${failed ? 'fail' : warned ? 'warn' : 'pass'}`;
  overall.lastElementChild.textContent = failed ? `${failed} 项未通过` : warned ? `${warned} 项需注意` : '门禁通过';
  updateButtons();
}

async function detect() {
  setBusy(true); stamp('开始读取真实环境…');
  const result = await window.gatekeeper.detect();
  if (result.data) { render(result.data); stamp('检测完成。'); }
  else stamp(`检测失败（代码 ${result.code}）\n${result.stderr || result.stdout}`);
  setBusy(false);
}

async function apply(items) {
  if (!items.length) return;
  setBusy(true); stamp(`准备修改：${items.join(', ')}。先保存恢复快照。`);
  const result = await window.gatekeeper.apply(items);
  const message = result.data?.message || result.stderr || result.stdout || `退出代码 ${result.code}`;
  stamp(message.trim());
  setBusy(false);
  await detect();
}

$('detect').addEventListener('click', detect);
$('browserAudit').addEventListener('click', async () => {
  setBusy(true); stamp('启动专用 Edge/Chrome，检测浏览器实际出口、JS 时区、语言和 WebRTC…');
  const result = await window.gatekeeper.browserAudit();
  stamp(result.message || '浏览器深度检测没有返回结果。');
  setBusy(false);
});
$('fix').addEventListener('click', () => apply([...document.querySelectorAll('input[type=checkbox]:checked')].map((box) => box.dataset.id)));
$('fixAll').addEventListener('click', () => apply(currentItems.filter((item) => item.fixable && item.status !== 'pass' && item.recommendedFix !== false).map((item) => item.id)));
$('restore').addEventListener('click', async () => {
  setBusy(true); stamp('开始按最近一次修改前的快照恢复…');
  const result = await window.gatekeeper.restore();
  stamp((result.data?.message || result.stderr || result.stdout || `退出代码 ${result.code}`).trim());
  setBusy(false);
  await detect();
});
$('clear').addEventListener('click', () => { $('log').textContent = '等待操作…'; });

async function loadSettings() {
  const settings = await window.gatekeeper.getSettings();
  for (const [key, value] of Object.entries(settings)) if ($(key)) $(key).value = value;
}

$('saveSettings').addEventListener('click', async () => {
  const value = {};
  for (const key of ['targetCountry','expectedIp','proxyUrl','targetTimezone','targetLanguage','targetLocale','safetyPolicy']) value[key] = $(key).value;
  await window.gatekeeper.saveSettings(value);
  stamp('检测设置已保存。');
  await detect();
});

loadSettings().then(detect);
