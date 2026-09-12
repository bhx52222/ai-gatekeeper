const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('gatekeeper', {
  detect: () => ipcRenderer.invoke('gate:detect'),
  apply: (items) => ipcRenderer.invoke('gate:apply', items),
  restore: () => ipcRenderer.invoke('gate:restore'),
  setSafety: (enabled) => ipcRenderer.invoke('gate:safety', Boolean(enabled)),
  getSettings: () => ipcRenderer.invoke('gate:get-settings'),
  saveSettings: (value) => ipcRenderer.invoke('gate:save-settings', value),
  browserAudit: () => ipcRenderer.invoke('gate:browser-audit')
});
