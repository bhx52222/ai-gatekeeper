const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

test('macOS backend emits the UI contract', { skip: process.platform !== 'darwin' }, () => {
  const backend = path.join(__dirname, '..', 'app', 'backend', 'macos.py');
  const result = spawnSync('/usr/bin/python3', [backend, 'detect'], { encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  const payload = JSON.parse(result.stdout);
  assert.equal(payload.platformLabel, 'macOS');
  assert.ok(Array.isArray(payload.items));
  assert.deepEqual(payload.items.map((item) => item.id), ['system_locale', 'dns', 'ipv6', 'proxy', 'route', 'safety_valve', 'ip_quality', 'browser_profile', 'saferoom']);
  assert.equal(payload.items.find((item) => item.id === 'route').routeDetails.length, 16);
  for (const item of payload.items) {
    assert.equal(typeof item.title, 'string');
    assert.ok(['pass', 'warn', 'fail', 'info'].includes(item.status));
    assert.equal(typeof item.fixable, 'boolean');
  }
});

test('Windows backend emits the UI contract', { skip: process.platform !== 'win32' }, () => {
  const backend = path.join(__dirname, '..', 'app', 'backend', 'windows.ps1');
  const result = spawnSync('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', backend, '-Action', 'detect'], { encoding: 'utf8', timeout: 60000 });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  const payload = JSON.parse(result.stdout.trim());
  assert.equal(payload.platformLabel, 'Windows');
  assert.deepEqual(payload.items.map((item) => item.id), ['system_locale', 'dns', 'ipv6', 'proxy', 'route', 'safety_valve', 'ip_quality', 'browser_profile', 'saferoom']);
});

test('macOS snapshots keep one immutable baseline across repeated updates', { skip: process.platform !== 'darwin' }, () => {
  const backend = path.join(__dirname, '..', 'app', 'backend', 'macos.py');
  const script = `
import importlib.util, json, pathlib, sys, tempfile
spec=importlib.util.spec_from_file_location('gate', sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root=pathlib.Path(tempfile.mkdtemp()); m.APP_HOME=root; m.SNAPSHOT_DIR=root/'snapshots'; m.HISTORY_DIR=root/'history'; m.BASELINE_FILE=root/'baseline.json'
m.create_snapshot(['system_locale']); first=json.loads(m.BASELINE_FILE.read_text())
m.create_snapshot(['browser_profile']); second=json.loads(m.BASELINE_FILE.read_text())
assert first['timezone']==second['timezone']; assert set(second['modifiedItems'])=={'system_locale','browser_profile'}
print('ok')`
  const result = spawnSync('/usr/bin/python3', ['-c', script, backend], { encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, `${result.stderr}\n${result.stdout}`);
  assert.match(result.stdout, /ok/);
});

test('packaging metadata includes macOS and Windows installers', () => {
  const pkg = require('../package.json');
  assert.match(pkg.scripts['dist:mac'], /electron-builder --mac/);
  assert.match(pkg.scripts['dist:win'], /electron-builder --win/);
  assert.deepEqual(pkg.build.win.target, ['nsis', 'portable']);
});
