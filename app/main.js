const { app, BrowserWindow, ipcMain } = require('electron');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const browserAudit = require('./browser-audit');

function backendPath() {
  const root = app.isPackaged ? path.join(process.resourcesPath, 'backend') : path.join(__dirname, 'backend');
  return process.platform === 'win32' ? path.join(root, 'windows.ps1') : path.join(root, 'macos.py');
}

function run(command, args, timeout = 120000, env = process.env) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { windowsHide: true, env });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => child.kill(), timeout);
    child.stdout.on('data', (data) => { stdout += data.toString(); });
    child.stderr.on('data', (data) => { stderr += data.toString(); });
    child.on('error', (error) => {
      clearTimeout(timer);
      resolve({ ok: false, code: -1, stdout, stderr: `${stderr}${error.message}` });
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ ok: code === 0, code, stdout, stderr });
    });
  });
}

function settingsPath() { return path.join(app.getPath('userData'), 'settings.json'); }

function defaultSettings() {
  return {
    targetCountry: 'US', expectedIp: '',
    proxyUrl: process.platform === 'darwin' ? 'http://127.0.0.1:6152' : '',
    targetTimezone: process.platform === 'win32' ? 'Pacific Standard Time' : 'America/Los_Angeles',
    targetLanguage: 'en-US', targetLocale: 'en_US', safetyPolicy: '02-固定AI出口'
  };
}

function loadSettings() {
  try { return { ...defaultSettings(), ...JSON.parse(fs.readFileSync(settingsPath(), 'utf8')) }; }
  catch (_) { return defaultSettings(); }
}

function saveSettings(value) {
  const clean = {
    targetCountry: String(value?.targetCountry || 'US').trim().toUpperCase().slice(0, 2),
    expectedIp: String(value?.expectedIp || '').trim().slice(0, 64),
    proxyUrl: String(value?.proxyUrl || '').trim().slice(0, 300),
    targetTimezone: String(value?.targetTimezone || defaultSettings().targetTimezone).trim().slice(0, 100),
    targetLanguage: String(value?.targetLanguage || 'en-US').trim().slice(0, 40),
    targetLocale: String(value?.targetLocale || 'en_US').trim().slice(0, 40),
    safetyPolicy: String(value?.safetyPolicy || '02-固定AI出口').trim().slice(0, 100)
  };
  fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
  fs.writeFileSync(settingsPath(), JSON.stringify(clean, null, 2));
  return clean;
}

async function callBackend(action, items = []) {
  const backend = backendPath();
  const settings = loadSettings();
  const env = {
    ...process.env, PYTHONUNBUFFERED: '1', TARGET_COUNTRY: settings.targetCountry,
    EXPECTED_IP: settings.expectedIp, PROXY_URL: settings.proxyUrl,
    TARGET_TIMEZONE: settings.targetTimezone, TARGET_LANGUAGE: settings.targetLanguage,
    TARGET_LOCALE: settings.targetLocale, SAFETY_POLICY: settings.safetyPolicy
  };
  const result = process.platform === 'win32'
    ? await run('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend, '-Action', action, '-Items', items.join(',')], 120000, env)
    : await run('/usr/bin/python3', [backend, action, items.join(',')], 120000, env);
  let data = null;
  try { data = JSON.parse(result.stdout); } catch (_) { /* output stays visible in log */ }
  return { ...result, data, platform: process.platform };
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1080,
    height: 760,
    minWidth: 860,
    minHeight: 620,
    backgroundColor: '#0b1020',
    title: 'AI 环境门禁',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (event) => event.preventDefault());
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  ipcMain.handle('gate:detect', () => callBackend('detect'));
  ipcMain.handle('gate:apply', (_event, items) => callBackend('apply', Array.isArray(items) ? items : []));
  ipcMain.handle('gate:restore', () => callBackend('restore'));
  ipcMain.handle('gate:safety', (_event, enabled) => callBackend(enabled ? 'safety-on' : 'safety-off'));
  ipcMain.handle('gate:get-settings', () => loadSettings());
  ipcMain.handle('gate:save-settings', (_event, value) => saveSettings(value));
  ipcMain.handle('gate:browser-audit', () => browserAudit.audit(loadSettings()));
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
