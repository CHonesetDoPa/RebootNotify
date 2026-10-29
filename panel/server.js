const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { URL } = require('node:url');
const { sendTelegramMessage } = require('./telegram');

const PORT = Number(process.env.PORT || 3980);
const HOST = process.env.HOST || '0.0.0.0';
const TOKEN = process.env.PANEL_TOKEN || 'change-me';
const DATA_DIR = path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'state.json');
const PUBLIC_DIR = path.join(__dirname, 'public');
const MAX_COMPLETED_COMMANDS = 500;
const COMMAND_LEASE_MS = 5 * 60 * 1000;

fs.mkdirSync(DATA_DIR, { recursive: true });

function loadState() {
  try {
    const state = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
    return {
      agents: state.agents && typeof state.agents === 'object' ? state.agents : {},
      commands: Array.isArray(state.commands) ? state.commands : [],
      settings: {
        telegram: {
          enabled: Boolean(state.settings?.telegram?.enabled),
          bot_token: String(state.settings?.telegram?.bot_token || ''),
          chat_id: String(state.settings?.telegram?.chat_id || ''),
          notify_reboot: state.settings?.telegram?.notify_reboot !== false,
          notify_offline: state.settings?.telegram?.notify_offline !== false,
          notify_upgrade: state.settings?.telegram?.notify_upgrade !== false,
          notify_command: state.settings?.telegram?.notify_command !== false,
          notify_error: state.settings?.telegram?.notify_error !== false
        },
        proxy: {
          enabled: Boolean(state.settings?.proxy?.enabled),
          url: String(state.settings?.proxy?.url || '')
        }
      }
    };
  } catch {
    return { agents: {}, commands: [], settings: { telegram: defaultTelegramSettings(), proxy: defaultProxySettings() } };
  }
}

function defaultTelegramSettings() {
  return { enabled: false, bot_token: '', chat_id: '', notify_reboot: true, notify_offline: true, notify_upgrade: true, notify_command: true, notify_error: true };
}

function defaultProxySettings() {
  return { enabled: false, url: '' };
}

let state = loadState();

function notifyTelegram(text) {
  sendTelegramMessage(state.settings.telegram, text, state.settings.proxy).catch(error => console.error(`Telegram 推送失败: ${error.message}`));
}

function agentIdentifier(agent) {
  return agent.agent_id || agent.hostname;
}

function findAgent(identifier) {
  return Object.values(state.agents).find(agent => agent.hostname === identifier || agentIdentifier(agent) === identifier);
}

function compactCommandHistory(commands) {
  const active = commands.filter(command => ['pending', 'leased', 'running'].includes(command.status));
  const completed = commands
    .filter(command => command.status !== 'pending' && command.status !== 'delivered')
    .slice(-MAX_COMPLETED_COMMANDS);
  return [...active, ...completed];
}

function saveState() {
  const tempFile = `${DATA_FILE}.tmp`;
  state.commands = compactCommandHistory(state.commands);
  fs.writeFileSync(tempFile, JSON.stringify(state, null, 2));
  fs.renameSync(tempFile, DATA_FILE);
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store'
  });
  res.end(body);
}

function authorized(req) {
  const value = req.headers.authorization || '';
  return value === `Bearer ${TOKEN}`;
}

function requireAuth(req, res) {
  if (authorized(req)) return true;
  sendJson(res, 401, { error: 'unauthorized' });
  return false;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', chunk => {
      body += chunk;
      if (body.length > 1024 * 1024) reject(new Error('payload too large'));
    });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new Error('invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function agentView(agent) {
  const pendingCount = state.commands.filter(command => command.hostname === agent.hostname &&
    ['pending', 'leased', 'running'].includes(command.status)).length;
  return { ...agent, pending_commands: pendingCount };
}

function reportAgent(report) {
  if (!report.hostname || typeof report.hostname !== 'string') return null;
  const now = new Date().toISOString();
  const existing = state.agents[report.hostname] || { first_seen_at: now };
  const wasNew = !state.agents[report.hostname];
  const rebootChanged = !wasNew && Boolean(existing.reboot_required) !== Boolean(report.reboot_required);
  const upgradeChanged = !wasNew && Number(existing.upgradeable_packages_count || 0) !== Number(report.upgradeable_packages_count || 0);
  const previousError = existing.last_error || '';
  const agent = {
    ...existing,
    hostname: report.hostname,
    agent_id: report.agent_id || report.hostname,
    version: report.version || 'unknown',
    reboot_required: Boolean(report.reboot_required),
    upgradeable_packages: Array.isArray(report.upgradeable_packages) ? report.upgradeable_packages : [],
    upgradeable_packages_count: Number(report.upgradeable_packages_count || 0),
    reported_at: report.reported_at || now,
    last_seen_at: now,
    heartbeat_interval: Math.max(10, Number(report.heartbeat_interval) || 60),
    last_error: null,
    online: true
  };
  if (typeof report.last_error === 'string' && report.last_error.trim()) {
    agent.last_error = report.last_error.trim().slice(0, 500);
  }
  state.agents[report.hostname] = agent;
  saveState();
  if (state.settings.telegram.enabled) {
    if (state.settings.telegram.notify_reboot && rebootChanged && agent.reboot_required) {
      notifyTelegram(`⚠️ <b>需要重启</b>\n主机：<code>${escapeTelegram(agent.hostname)}</code>`);
    }
    if (state.settings.telegram.notify_upgrade && upgradeChanged && agent.upgradeable_packages_count > 0) {
      notifyTelegram(`📦 <b>发现软件升级</b>\n主机：<code>${escapeTelegram(agent.hostname)}</code>\n数量：${agent.upgradeable_packages_count}`);
    }
    if (state.settings.telegram.notify_error && agent.last_error && agent.last_error !== previousError) {
      notifyTelegram(`🟠 <b>Agent 检查异常</b>\n主机：<code>${escapeTelegram(agent.hostname)}</code>\n错误：<code>${escapeTelegram(agent.last_error).slice(0, 600)}</code>`);
    }
  }
  return agent;
}

function markOfflineAgents() {
  for (const agent of Object.values(state.agents)) {
    const wasOnline = agent.online;
    const interval = Math.max(10, Number(agent.heartbeat_interval) || 60);
    const cutoff = Date.now() - interval * 3 * 1000;
    agent.online = new Date(agent.last_seen_at).getTime() >= cutoff;
    if (state.settings.telegram.enabled && state.settings.telegram.notify_offline && wasOnline && !agent.online) {
      notifyTelegram(`🔴 <b>Agent 已离线</b>\n主机：<code>${escapeTelegram(agent.hostname)}</code>\n最后上报：${agent.last_seen_at}`);
    }
  }
}

function escapeTelegram(value) {
  return String(value).replace(/[&<>"]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[character]));
}

function reclaimExpiredCommands() {
  const now = Date.now();
  let changed = false;
  for (const command of state.commands) {
    if ((command.status === 'leased' || command.status === 'running') &&
        command.lease_until && new Date(command.lease_until).getTime() <= now) {
      command.status = 'pending';
      command.lease_until = null;
      command.retry_count = (command.retry_count || 0) + 1;
      changed = true;
    }
  }
  if (changed) saveState();
}

function claimCommands(hostname, runningCommandId) {
  reclaimExpiredCommands();
  const now = new Date();
  const active = state.commands.find(command => command.hostname === hostname &&
    (command.status === 'leased' || command.status === 'running'));
  if (active && active.id === runningCommandId) {
    active.status = 'running';
    active.started_at = active.started_at || now.toISOString();
    active.lease_until = new Date(now.getTime() + COMMAND_LEASE_MS).toISOString();
    saveState();
    return [];
  }
  if (active) return [];
  const command = state.commands.find(item => item.hostname === hostname && item.status === 'pending');
  if (!command) return [];
  command.status = 'leased';
  command.leased_at = now.toISOString();
  command.started_at = null;
  command.lease_until = new Date(now.getTime() + COMMAND_LEASE_MS).toISOString();
  command.retry_count = command.retry_count || 0;
  saveState();
  return [{ id: command.id, action: command.action, lease_until: command.lease_until }];
}

function dashboardState() {
  markOfflineAgents();
  const agents = Object.values(state.agents).map(agentView).sort((a, b) => a.hostname.localeCompare(b.hostname));
  const commands = [...state.commands].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
  return {
    agents,
    commands: commands.slice(0, 100),
    stats: {
      total: agents.length,
      online: agents.filter(agent => agent.online).length,
      reboot_required: agents.filter(agent => agent.reboot_required).length,
      upgrades: agents.reduce((sum, agent) => sum + agent.upgradeable_packages_count, 0)
    }
  };
}

function serveStatic(req, res, pathname) {
  const requested = pathname === '/' ? '/index.html' : pathname;
  const filePath = path.resolve(PUBLIC_DIR, `.${requested}`);
  if (!filePath.startsWith(`${PUBLIC_DIR}${path.sep}`)) {
    res.writeHead(403); res.end('Forbidden'); return;
  }
  fs.readFile(filePath, (error, content) => {
    if (error) { res.writeHead(404); res.end('Not found'); return; }
    const type = path.extname(filePath) === '.html' ? 'text/html; charset=utf-8' :
      path.extname(filePath) === '.css' ? 'text/css; charset=utf-8' : 'application/javascript; charset=utf-8';
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-cache' });
    res.end(content);
  });
}

const server = http.createServer(async (req, res) => {
  const requestUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const { pathname } = requestUrl;

  if (pathname.startsWith('/api/')) {
    if (!requireAuth(req, res)) return;
    try {
      if (req.method === 'POST' && pathname === '/api/v1/agents/report') {
        const report = await readBody(req);
        const agent = reportAgent(report);
        if (!agent) return sendJson(res, 400, { error: 'hostname is required' });
        return sendJson(res, 202, { accepted: true });
      }

      if (req.method === 'POST' && pathname === '/api/v1/agents/pulse') {
        const pulse = await readBody(req);
        const agent = reportAgent(pulse);
        if (!agent) return sendJson(res, 400, { error: 'hostname is required' });
        const commands = claimCommands(agent.hostname, pulse.running_command_id || '');
        return sendJson(res, 200, { server_time: new Date().toISOString(), commands });
      }

      const commandsMatch = pathname.match(/^\/api\/v1\/agents\/([^/]+)\/commands$/);
      if (req.method === 'GET' && commandsMatch) {
        const hostname = decodeURIComponent(commandsMatch[1]);
        return sendJson(res, 410, { error: 'use POST /api/v1/agents/pulse' });
      }

      const resultMatch = pathname.match(/^\/api\/v1\/agents\/([^/]+)\/commands\/([^/]+)\/result$/);
      if (req.method === 'POST' && resultMatch) {
        const identifier = decodeURIComponent(resultMatch[1]);
        const agent = findAgent(identifier);
        const hostname = agent?.hostname || identifier;
        const command = state.commands.find(item => item.hostname === hostname && item.id === resultMatch[2]);
        if (!command) return sendJson(res, 404, { error: 'command not found' });
        const result = await readBody(req);
        if (result.agent_id && (!agent || result.agent_id !== agent.agent_id)) {
          return sendJson(res, 403, { error: 'agent identity mismatch' });
        }
        if (!['leased', 'running'].includes(command.status)) {
          return sendJson(res, 409, { error: `command is not active (${command.status})` });
        }
        if (command.status === 'succeeded' || command.status === 'failed') {
          return sendJson(res, 200, { accepted: true, duplicate: true });
        }
        command.status = result.success ? 'succeeded' : 'failed';
        command.result = { success: Boolean(result.success), output: result.output || '', error: result.error || '' };
        command.completed_at = new Date().toISOString();
        command.lease_until = null;
        saveState();
        if (state.settings.telegram.enabled && state.settings.telegram.notify_command) {
          notifyTelegram(`${result.success ? '✅' : '❌'} <b>维护命令${result.success ? '完成' : '失败'}</b>\n主机：<code>${escapeTelegram(hostname)}</code>\n操作：${command.action === 'reboot' ? '重启' : '升级'}${result.error ? `\n错误：<code>${escapeTelegram(result.error).slice(0, 600)}</code>` : ''}`);
        }
        return sendJson(res, 200, { accepted: true });
      }

      if (req.method === 'GET' && pathname === '/api/panel/state') return sendJson(res, 200, dashboardState());

      if (req.method === 'GET' && pathname === '/api/panel/settings') {
        const telegram = state.settings.telegram;
        return sendJson(res, 200, { telegram: { ...telegram, bot_token: Boolean(telegram.bot_token), configured: Boolean(telegram.bot_token && telegram.chat_id) }, proxy: state.settings.proxy });
      }

      if (req.method === 'PUT' && pathname === '/api/panel/settings') {
        const body = await readBody(req);
        const incoming = body.telegram || {};
        const current = state.settings.telegram;
        const incomingProxy = body.proxy || {};
        state.settings.telegram = {
          enabled: Boolean(incoming.enabled),
          bot_token: String(incoming.bot_token || '').trim() || current.bot_token,
          chat_id: String(incoming.chat_id || '').trim(),
          notify_reboot: incoming.notify_reboot !== false,
          notify_offline: incoming.notify_offline !== false,
          notify_upgrade: incoming.notify_upgrade !== false,
          notify_command: incoming.notify_command !== false,
          notify_error: incoming.notify_error !== false
        };
        const nextProxy = {
          enabled: Boolean(incomingProxy.enabled),
          url: String(incomingProxy.url || '').trim()
        };
        if (nextProxy.enabled && !nextProxy.url) return sendJson(res, 400, { error: '启用代理时必须填写代理地址' });
        if (nextProxy.enabled) {
          let proxyUrl;
          try {
            proxyUrl = new URL(nextProxy.url);
          } catch {
            return sendJson(res, 400, { error: '代理地址格式无效' });
          }
          if (!['http:', 'socks5:', 'socks5h:'].includes(proxyUrl.protocol)) {
            return sendJson(res, 400, { error: '代理仅支持 HTTP、SOCKS5 或 SOCKS5H' });
          }
        }
        state.settings.proxy = nextProxy;
        saveState();
        return sendJson(res, 200, { saved: true });
      }

      if (req.method === 'POST' && pathname === '/api/panel/settings/telegram/test') {
        const telegram = state.settings.telegram;
        if (!telegram.bot_token || !telegram.chat_id) return sendJson(res, 400, { error: '请先填写 Bot Token 和 Chat ID' });
        await sendTelegramMessage({ ...telegram, enabled: true }, '✅ RebootNotify\nTelegram 通知测试成功。', state.settings.proxy);
        return sendJson(res, 200, { sent: true });
      }

      const queueMatch = pathname.match(/^\/api\/panel\/agents\/([^/]+)\/commands$/);
      if (req.method === 'POST' && queueMatch) {
        const identifier = decodeURIComponent(queueMatch[1]);
        const agent = findAgent(identifier);
        if (!agent) return sendJson(res, 404, { error: 'agent not found' });
        const body = await readBody(req);
        if (!['upgrade', 'reboot'].includes(body.action)) return sendJson(res, 400, { error: 'unsupported action' });
        const command = { id: crypto.randomUUID(), hostname: agent.hostname, agent_id: agent.agent_id, action: body.action, status: 'pending', created_at: new Date().toISOString() };
        state.commands.push(command);
        saveState();
        return sendJson(res, 201, command);
      }

      return sendJson(res, 404, { error: 'not found' });
    } catch (error) {
      return sendJson(res, 400, { error: error.message });
    }
  }

  serveStatic(req, res, pathname);
});

server.listen(PORT, HOST, () => {
  console.log(`RebootNotify Panel listening on http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${PORT}`);
});

setInterval(() => {
  markOfflineAgents();
  reclaimExpiredCommands();
}, 30000).unref();
