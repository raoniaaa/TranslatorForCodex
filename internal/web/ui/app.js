'use strict';
const $ = (id) => document.getElementById(id);
const root = new URL('./', location.href);
let state, initialized = false, polling = false, toastTimer, previewController, previewVersion = 0, composing = false;
const labels = {
 idle: ['准备连接你的翻译服务', '未开启', '↔'], paused: ['翻译已暂停', '已暂停', 'Ⅱ'],
 'waiting-focus': ['翻译模式已开启，等待输入框', '开关开启', '↔'],
 ready: ['已开启，等待中文输入', '已连接', '↔'], waiting: ['等待输入停顿', '监听中', '···'],
 composing: ['等待中文选词完成', '选词保护', '⌨'], translating: ['正在翻译', '处理中', '↻'],
 applying: ['正在填入英文', '处理中', '↗'], success: ['英文已填入', '已完成', '✓'],
 restored: ['中文原文已恢复', '已撤销', '↶'], editing: ['等待编辑完成', '编辑中', '⌁'],
 unsupported: ['当前输入状态暂不支持', '已保护', '!'], permission: ['需要辅助功能权限', '待授权', '!'],
 error: ['翻译未完成，草稿已保留', '需处理', '!']
};
async function api(path, options = {}) {
 const response = await fetch(new URL('api/' + path, root), {
  ...options, headers: { 'Content-Type': 'application/json', ...options.headers }
 });
 let value;
 try { value = await response.json(); } catch { throw new Error('服务连接异常，请重新打开 Translator。'); }
 if (!response.ok) throw new Error(value.error || '操作失败，请重试。');
 return value;
}
const post = (path, value = {}) => api(path, { method: 'POST', body: JSON.stringify(value) });
function toast(message) {
 $('toast').textContent = message; $('toast').hidden = false;
 clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('toast').hidden = true; }, 4200);
}
function render(data) {
 state = data;
 if (!initialized) {
  $('base-url').value = data.config.baseUrl || ''; $('model').value = data.config.model || '';
  $('delay').value = Math.min(data.config.delayMs || 2000, 3000); $('delay-value').textContent = $('delay').value + ' ms';
  initialized = true;
 }
 $('key-state').textContent = data.storageError ? data.storageError : data.keyStored ? '已保存到本地文件（仅当前账户可读写）' : data.hasKey ? '尚未持久保存，请点保存设置' : '保存在本地文件，重启自动恢复';
 $('clear-key').disabled = !data.hasKey && !data.keyStored;
 $('api-key').placeholder = data.hasKey ? '已设置；留空保留，填写可更新' : '填写密钥，本地服务可留空';
 $('connection').dataset.online = 'true';
 $('connection').replaceChildren(Object.assign(document.createElement('i'), {}), document.createTextNode(data.native ? '桌面已连接' : '试译模式'));
 const s = data.state, phase = s.phase || 'idle';
 const [title, tag, symbol] = labels[phase] || labels.idle;
 $('status-card').dataset.phase = phase;
 $('status-title').textContent = title; $('status-tag').textContent = tag; $('status-symbol').textContent = symbol;
 $('status-detail').textContent = s.status;
 $('connect').textContent = s.armed ? '关闭翻译模式 Ⅱ' : '开启翻译模式 ↗';
 $('connect').setAttribute('aria-pressed', String(s.armed));
 $('permission-title').textContent = data.trusted ? '辅助功能已授权' : data.native ? '需要辅助功能权限' : '桌面功能未连接';
 $('permission-detail').textContent = data.trusted ? '允许读取和替换 Codex 草稿。' : data.native ? '已勾选仍无效：移除旧 Translator，再添加当前版本。' : '使用 Mac 应用体验浮窗与自动替换。';
 $('permission-dot').classList.toggle('ok', data.trusted);
 $('permission').hidden = data.trusted || !data.native;
 $('permission-actions').hidden = data.trusted || !data.native;
 $('live-source').textContent = s.original || '连接 Codex 后，最近一次翻译的原文会出现在这里。';
 $('live-result').textContent = s.translation || '尚无翻译记录';
 $('live-source').classList.toggle('muted', !s.original); $('live-result').classList.toggle('muted', !s.translation);
 $('live-latency').textContent = s.latencyMs ? '最近翻译耗时 ' + (s.latencyMs / 1000).toFixed(1) + ' 秒' : s.armed ? '翻译模式保持开启，返回输入框自动继续' : '点击宠物一次，开启持续翻译模式';
 if (data.configured && $('preview-status').textContent === '配置服务后即可试译') $('preview-status').textContent = '准备好时，点击试译';
}
async function poll() {
 if (polling) return;
 polling = true;
 try { render(await api('state')); }
 catch { $('connection').textContent = '连接已断开'; $('connection').dataset.online = 'false'; }
 finally { polling = false; }
}
$('delay').addEventListener('input', () => { $('delay-value').textContent = $('delay').value + ' ms'; });
$('show-key').addEventListener('click', () => {
 const showing = $('api-key').type === 'password';
 $('api-key').type = showing ? 'text' : 'password'; $('show-key').textContent = showing ? '隐藏' : '显示';
 $('show-key').setAttribute('aria-label', showing ? '隐藏密钥' : '显示密钥');
});
$('config-form').addEventListener('submit', async (event) => {
 event.preventDefault(); $('save').disabled = true; $('save').textContent = '正在保存…';
 const feedback = $('config-feedback'); feedback.classList.remove('error'); feedback.textContent = '';
 previewController?.abort(); previewVersion++; finishPreview();
 $('result').textContent = '设置更新后，请重新试译。'; $('result').className = 'result placeholder'; $('copy').disabled = true; $('latency').textContent = '保留代码、链接和技术术语';
 try {
  const result = await post('config', { baseUrl: $('base-url').value.trim(), model: $('model').value.trim(), apiKey: $('api-key').value.trim(), delayMs: Number($('delay').value) });
  $('api-key').value = ''; $('api-key').type = 'password'; $('show-key').textContent = '显示'; $('show-key').setAttribute('aria-label', '显示密钥');
  feedback.textContent = result.hasKey ? '地址、模型与密钥已保存在本机，重启自动恢复。' : '设置已保存，当前未设置密钥。';
  await poll();
 } catch (error) { feedback.classList.add('error'); feedback.textContent = error.message; }
 finally { $('save').disabled = false; $('save').textContent = '保存设置'; }
});
$('clear-key').addEventListener('click', async () => {
 if (!state?.configured) return;
 $('clear-key').disabled = true;
 try {
  await post('config', { ...state.config, apiKey: '', clearKey: true });
  $('api-key').value = '';
  $('config-feedback').classList.remove('error');
  $('config-feedback').textContent = '已删除本机保存的密钥。';
  await poll();
 } catch (error) { toast(error.message); $('clear-key').disabled = false; }
});
$('connect').addEventListener('click', async () => {
 try {
  await post(state?.state.armed ? 'pause' : 'connect');
  if (!state?.state.armed) toast('翻译模式已开启；点击 Codex 输入框即可，切换窗口后会自动继续。');
  await poll();
 } catch (error) { toast(error.message); }
});
$('permission').addEventListener('click', async () => { try { await post('permission'); } catch (error) { toast(error.message); } });
$('permission-recheck').addEventListener('click', async () => {
 try { await post('recheck-permission'); await poll(); toast(state?.trusted ? '辅助功能权限已生效。' : '当前进程仍未获得权限。请移除旧条目，再添加「定位当前应用」找到的 Translator。'); }
 catch (error) { toast(error.message); }
});
$('reveal-app').addEventListener('click', async () => { try { await post('reveal-app'); } catch (error) { toast(error.message); } });
function tab(live) {
 $('try-panel').hidden = live; $('live-panel').hidden = !live;
 $('tab-try').setAttribute('aria-pressed', String(!live)); $('tab-live').setAttribute('aria-pressed', String(live));
}
$('tab-try').addEventListener('click', () => tab(false)); $('tab-live').addEventListener('click', () => tab(true));
function finishPreview() { $('translate').disabled = false; $('translate').textContent = '试译 ↗'; $('preview-status').classList.remove('busy-symbol'); }
$('source').addEventListener('compositionstart', () => { composing = true; });
$('source').addEventListener('compositionend', () => { composing = false; });
$('source').addEventListener('input', () => {
 previewVersion++; previewController?.abort(); finishPreview();
 $('preview-status').textContent = '原文已更新，点击试译'; $('copy').disabled = true;
 $('result').textContent = '译文会出现在这里。'; $('result').className = 'result placeholder'; $('latency').textContent = '保留代码、链接和技术术语';
});
$('translate').addEventListener('click', async () => {
 if (composing) { toast('请先完成中文选词。'); return; }
 if (!state?.configured) { toast('请先保存 API 地址和模型。'); $('base-url').focus(); return; }
 const text = $('source').value.trim(); if (!text) { $('source').focus(); return; }
 previewController?.abort(); const controller = new AbortController(); previewController = controller;
 const version = ++previewVersion;
 $('translate').disabled = true; $('translate').textContent = '翻译中…';
 $('preview-status').textContent = '正在调用 ' + state.config.model; $('preview-status').classList.add('busy-symbol');
 $('result').textContent = '正在翻译，请稍候…'; $('result').className = 'result placeholder'; $('copy').disabled = true;
 try {
  const result = await api('preview', { method: 'POST', body: JSON.stringify({ text }), signal: controller.signal });
  if (version !== previewVersion) return;
  $('result').textContent = result.text; $('result').className = 'result';
  $('preview-status').textContent = '翻译完成'; $('latency').textContent = (result.durationMs / 1000).toFixed(1) + ' 秒 · ' + state.config.model;
  $('copy').disabled = false;
 } catch (error) {
  if (error.name === 'AbortError' || version !== previewVersion) return;
  $('preview-status').textContent = '试译未完成'; $('result').className = 'result error'; $('result').textContent = error.message;
 } finally { if (version === previewVersion) finishPreview(); }
});
$('copy').addEventListener('click', async () => {
 try {
  if (navigator.clipboard?.writeText) await navigator.clipboard.writeText($('result').textContent);
  else {
   const area = document.createElement('textarea'); area.className = 'clipboard-copy'; area.value = $('result').textContent;
   document.body.append(area); area.select(); const copied = document.execCommand('copy'); area.remove();
   if (!copied) throw new Error();
  }
  toast('译文已复制。');
 } catch { toast('复制失败，请选中译文后按 ⌘C。'); }
});
$('demo').addEventListener('click', async () => {
 $('demo').disabled = true;
 try {
  if (state?.native) await post('demo');
  else {
   const frames = [['⌨', '演示 · 等待选词', '候选窗出现时暂停翻译'], ['↻', '演示 · 正在翻译', '这里会显示模型与等待时间'], ['✓', '演示 · 英文已填入', '本次仅演示浮窗，没有调用 API']];
   frames.forEach((frame, i) => setTimeout(() => {
    $('demo-hud').hidden = false; $('demo-symbol').textContent = frame[0]; $('demo-title').textContent = frame[1]; $('demo-detail').textContent = frame[2];
    $('demo-symbol').classList.toggle('busy-symbol', i === 1);
   }, [0, 1400, 3600][i]));
   setTimeout(() => { $('demo-hud').hidden = true; }, 5500);
  }
 } catch (error) { toast(error.message); }
 finally { setTimeout(() => { $('demo').disabled = false; }, 5600); }
});
void poll(); setInterval(poll, 750);
