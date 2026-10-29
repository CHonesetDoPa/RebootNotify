const token = localStorage.getItem('rebootnotify-token') || window.prompt('请输入 Panel Token', 'change-me') || '';
localStorage.setItem('rebootnotify-token', token);
const headers = { Authorization: `Bearer ${token}` };
const $ = selector => document.querySelector(selector);

function escapeHtml(value) { return String(value).replace(/[&<>"']/g, char => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#039;' }[char])); }
function formatTime(value) { if (!value) return '--'; return new Date(value).toLocaleString('zh-CN', { hour12:false }); }
function showToast(message) { const toast = $('#toast'); toast.textContent = message; toast.classList.add('show'); setTimeout(() => toast.classList.remove('show'), 2800); }

function renderUpgradeablePackages(agent) {
  const packages = Array.isArray(agent.upgradeable_packages) ? agent.upgradeable_packages : [];
  if (!packages.length) return '<span class="mono">暂无可升级包</span>';
  return `<details class="package-details"><summary class="package-summary"><span class="package-count">${packages.length}</span><span><strong>可升级软件包</strong><small>点击查看明细</small></span><span class="package-toggle">查看列表</span></summary><ul class="package-list">${packages.map(packageInfo => `<li><span class="package-bullet"></span><span>${escapeHtml(packageInfo)}</span></li>`).join('')}</ul></details>`;
}

async function request(url, options = {}) {
  const response = await fetch(url, { ...options, headers: { ...headers, ...(options.headers || {}) } });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `请求失败 (${response.status})`);
  return data;
}

let latestAgents = [];
let latestCommands = [];

function renderAgents(agents = latestAgents) {
  latestAgents = agents;
  const query = $('#agent-search').value.trim().toLowerCase();
  const filter = $('#agent-filter').value;
  const visible = agents.filter(agent => {
    const matchesText = !query || `${agent.hostname} ${agent.agent_id}`.toLowerCase().includes(query);
    const matchesFilter = filter === 'all' ||
      (filter === 'online' && agent.online) ||
      (filter === 'offline' && !agent.online) ||
      (filter === 'attention' && (agent.reboot_required || agent.upgradeable_packages_count > 0 || agent.last_error));
    return matchesText && matchesFilter;
  });
  $('#agent-count').textContent = `${visible.length}/${agents.length} 台`;
  $('#agent-list').innerHTML = visible.length ? visible.map(agent => `
    <div class="agent-row">
        <div class="agent-status"><span class="agent-dot ${agent.online ? 'online' : ''}"></span><span>${agent.online ? '在线' : '离线'}</span></div>
        <div class="agent-name">${escapeHtml(agent.hostname)}</div>
      <div><span class="badge ${agent.reboot_required ? 'warn' : 'good'}">${agent.reboot_required ? '需要重启' : '运行正常'}</span></div>
      <div>${renderUpgradeablePackages(agent)}</div>
      <div class="mono">${agent.last_error ? `<span class="error-text" title="${escapeHtml(agent.last_error)}">上报异常</span>` : formatTime(agent.last_seen_at)}</div>
      <div class="actions"><button class="action" data-action="upgrade" data-host="${escapeHtml(agent.hostname)}">升级软件</button><button class="action danger" data-action="reboot" data-host="${escapeHtml(agent.hostname)}">安排重启</button></div>
    </div>`).join('') : '<div class="empty">没有匹配的 Agent。</div>';
}

function renderCommands(commands = latestCommands) {
  latestCommands = commands;
  const filter = $('#command-filter').value;
  const visible = commands.filter(command => filter === 'all' ||
    (filter === 'active' && ['pending', 'leased', 'running'].includes(command.status)) ||
    command.status === filter);
  const labels = { pending:'等待 Agent', leased:'已领取', running:'执行中', succeeded:'已完成', failed:'失败' };
  $('#command-list').innerHTML = visible.length ? visible.map(command => `
    <div class="command-row"><div><strong>${escapeHtml(command.hostname)}</strong><div class="mono">${formatTime(command.created_at)}</div></div><div class="command-action">${command.action === 'reboot' ? '重启' : '升级'}</div><div class="status ${command.status}">${labels[command.status] || command.status}</div><div class="mono">${command.result?.error ? escapeHtml(command.result.error) : command.result?.output ? '已收到执行输出' : '--'}</div></div>`).join('') : '<div class="empty">暂无匹配的操作记录</div>';
}

function setView(view) {
  const settings = view === 'settings';
  document.querySelectorAll('.dashboard-view').forEach(element => { element.hidden = settings; });
  $('#settings-view').hidden = !settings;
  document.querySelectorAll('[data-view]').forEach(button => button.classList.toggle('active', button.dataset.view === view));
  if (settings) loadSettings();
}

async function loadSettings() {
  try {
    const data = await request('/api/panel/settings');
    const telegram = data.telegram;
    $('#telegram-enabled').checked = telegram.enabled;
    $('#telegram-token').value = '';
    $('#telegram-token-state').textContent = telegram.bot_token ? 'Token 已配置，留空则保持不变' : '尚未配置 Token';
    $('#telegram-chat-id').value = telegram.chat_id || '';
    $('#notify-reboot').checked = telegram.notify_reboot;
    $('#notify-offline').checked = telegram.notify_offline;
    $('#notify-upgrade').checked = telegram.notify_upgrade;
    $('#notify-command').checked = telegram.notify_command;
    $('#notify-error').checked = telegram.notify_error;
    $('#proxy-enabled').checked = Boolean(data.proxy?.enabled);
    $('#proxy-url').value = data.proxy?.url || '';
  } catch (error) { showToast(error.message); }
}

async function refresh() {
  try {
    const data = await request('/api/panel/state');
    $('#total').textContent = data.stats.total;
    $('#online').textContent = data.stats.online;
    $('#reboot-required').textContent = data.stats.reboot_required;
    $('#upgrades').textContent = data.stats.upgrades;
    $('#last-sync').textContent = new Date().toLocaleTimeString('zh-CN', { hour12:false });
    $('#connection-label').textContent = '服务已连接';
    $('.pulse').classList.remove('offline');
    renderAgents(data.agents); renderCommands(data.commands);
  } catch (error) {
    $('#connection-label').textContent = '连接失败'; $('.pulse').classList.add('offline'); showToast(error.message);
  }
}

$('#agent-list').addEventListener('click', async event => {
  const button = event.target.closest('button[data-action]');
  if (!button) return;
  const actionText = button.dataset.action === 'reboot' ? '重启' : '升级';
  if (!window.confirm(`确认向 ${button.dataset.host} 下发${actionText}命令？`)) return;
  button.disabled = true;
  try { await request(`/api/panel/agents/${encodeURIComponent(button.dataset.host)}/commands`, { method:'POST', headers:{ 'Content-Type':'application/json' }, body:JSON.stringify({ action:button.dataset.action }) }); showToast(`${actionText}命令已排队，等待 Agent 拉取`); await refresh(); }
  catch (error) { showToast(error.message); button.disabled = false; }
});
$('#refresh').addEventListener('click', refresh);
$('#agent-search').addEventListener('input', () => renderAgents());
$('#agent-filter').addEventListener('change', () => renderAgents());
$('#command-filter').addEventListener('change', () => renderCommands());
document.querySelectorAll('[data-view]').forEach(button => button.addEventListener('click', () => {
  window.location.hash = button.dataset.view;
  setView(button.dataset.view);
}));
window.addEventListener('hashchange', () => setView(window.location.hash === '#settings' ? 'settings' : 'dashboard'));
$('#settings-form').addEventListener('submit', async event => {
  event.preventDefault();
  try {
    await request('/api/panel/settings', { method:'PUT', headers:{ 'Content-Type':'application/json' }, body:JSON.stringify({ telegram: {
      enabled: $('#telegram-enabled').checked, bot_token: $('#telegram-token').value, chat_id: $('#telegram-chat-id').value,
      notify_reboot: $('#notify-reboot').checked, notify_offline: $('#notify-offline').checked, notify_upgrade: $('#notify-upgrade').checked, notify_command: $('#notify-command').checked, notify_error: $('#notify-error').checked
    }, proxy: { enabled: $('#proxy-enabled').checked, url: $('#proxy-url').value } }) });
    showToast('设置已保存');
    await loadSettings();
  } catch (error) { showToast(error.message); }
});
$('#telegram-test').addEventListener('click', async event => {
  event.currentTarget.disabled = true;
  try { await request('/api/panel/settings/telegram/test', { method:'POST' }); showToast('测试消息已发送'); }
  catch (error) { showToast(error.message); }
  finally { event.currentTarget.disabled = false; }
});
setView(window.location.hash === '#settings' ? 'settings' : 'dashboard');
refresh();
setInterval(refresh, 30000);
