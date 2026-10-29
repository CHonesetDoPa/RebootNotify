const https = require('node:https');
const http = require('node:http');
const net = require('node:net');
const tls = require('node:tls');

function requestOptions(token, payload, socket) {
  return {
    hostname: 'api.telegram.org',
    path: `/bot${encodeURIComponent(token)}/sendMessage`,
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
    timeout: 10000,
    ...(socket ? { socket, agent: false, createConnection: () => socket } : {})
  };
}

function performRequest(options, payload) {
  return new Promise((resolve, reject) => {
    const request = https.request(options, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { body += chunk; });
      response.on('end', () => {
        let result = {};
        try { result = JSON.parse(body); } catch {}
        if (response.statusCode < 200 || response.statusCode >= 300 || !result.ok) {
          reject(new Error(result.description || `Telegram 请求失败 (${response.statusCode})`));
          return;
        }
        resolve(result);
      });
    });
    request.on('timeout', () => request.destroy(new Error('Telegram 请求超时')));
    request.on('error', reject);
    request.write(payload);
    request.end();
  });
}

function requestThroughProxy(proxy, token, payload) {
  const proxyUrl = new URL(proxy);
  if (proxyUrl.protocol === 'socks5:' || proxyUrl.protocol === 'socks5h:') {
    return requestThroughSocks5(proxyUrl, token, payload);
  }
  if (proxyUrl.protocol !== 'http:') return Promise.reject(new Error('代理协议仅支持 HTTP、SOCKS5，例如 socks5://127.0.0.1:1080'));
  const authorization = proxyUrl.username || proxyUrl.password ? `Basic ${Buffer.from(`${decodeURIComponent(proxyUrl.username)}:${decodeURIComponent(proxyUrl.password)}`).toString('base64')}` : undefined;
  return new Promise((resolve, reject) => {
    const connect = http.request({
      host: proxyUrl.hostname,
      port: proxyUrl.port || 80,
      method: 'CONNECT',
      path: 'api.telegram.org:443',
      headers: authorization ? { Host: 'api.telegram.org:443', 'Proxy-Authorization': authorization } : { Host: 'api.telegram.org:443' },
      timeout: 10000
    });
    connect.on('connect', (response, socket) => {
      if (response.statusCode !== 200) {
        socket.destroy();
        reject(new Error(`代理连接失败 (${response.statusCode})`));
        return;
      }
      const secureSocket = tls.connect({ socket, servername: 'api.telegram.org' }, () => {
        performRequest(requestOptions(token, payload, secureSocket), payload).then(resolve, reject);
      });
      secureSocket.on('error', reject);
    });
    connect.on('timeout', () => connect.destroy(new Error('代理连接超时')));
    connect.on('error', reject);
    connect.end();
  });
}

function requestThroughSocks5(proxyUrl, token, payload) {
  const username = decodeURIComponent(proxyUrl.username);
  const password = decodeURIComponent(proxyUrl.password);
  const proxyPort = Number(proxyUrl.port || 1080);
  if (!Number.isInteger(proxyPort) || proxyPort < 1 || proxyPort > 65535) {
    return Promise.reject(new Error('SOCKS5 代理端口无效'));
  }
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: proxyUrl.hostname, port: proxyPort });
    let settled = false;
    const fail = error => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(error);
    };
    socket.setTimeout(10000, () => fail(new Error('SOCKS5 代理连接超时')));
    socket.on('error', fail);
    socket.once('connect', () => {
      const methods = username || password ? Buffer.from([0x05, 0x01, 0x02]) : Buffer.from([0x05, 0x01, 0x00]);
      socket.write(methods);
    });
    socket.once('data', methodResponse => {
      if (methodResponse.length < 2 || methodResponse[0] !== 0x05) return fail(new Error('SOCKS5 代理响应无效'));
      if (methodResponse[1] === 0xff) return fail(new Error('SOCKS5 代理拒绝认证方式'));
      if (methodResponse[1] === 0x02) {
        const user = Buffer.from(username);
        const pass = Buffer.from(password);
        if (user.length > 255 || pass.length > 255) return fail(new Error('SOCKS5 用户名或密码过长'));
        socket.write(Buffer.concat([Buffer.from([0x01, user.length]), user, Buffer.from([pass.length]), pass]));
        socket.once('data', authResponse => {
          if (authResponse.length < 2 || authResponse[1] !== 0x00) return fail(new Error('SOCKS5 代理认证失败'));
          requestSocks5Tunnel(socket, proxyUrl, fail);
        });
        return;
      }
      requestSocks5Tunnel(socket, proxyUrl, fail);
    });
    socket.once('close', () => {
      if (!settled) fail(new Error('SOCKS5 代理连接已关闭'));
    });
    socket.once('secureConnect', () => {});
    socket.on('socks-tunnel-ready', () => {
      const secureSocket = tls.connect({ socket, servername: 'api.telegram.org' }, () => {
        settled = true;
        performRequest(requestOptions(token, payload, secureSocket), payload).then(resolve, reject);
      });
      secureSocket.on('error', fail);
    });
  });
}

function requestSocks5Tunnel(socket, proxyUrl, fail) {
  const host = Buffer.from('api.telegram.org');
  const port = Buffer.from([0x01, 0xbb]);
  socket.write(Buffer.concat([Buffer.from([0x05, 0x01, 0x00, 0x03, host.length]), host, port]));
  socket.once('data', response => {
    if (response.length < 2 || response[0] !== 0x05 || response[1] !== 0x00) {
      fail(new Error(`SOCKS5 代理连接 Telegram 失败 (${response[1] ?? 'unknown'})`));
      return;
    }
    socket.emit('socks-tunnel-ready');
  });
}

function sendTelegramMessage(settings, text, proxySettings = {}) {
  const token = String(settings.bot_token || '').trim();
  const chatId = String(settings.chat_id || '').trim();
  if (!settings.enabled || !token || !chatId) return Promise.resolve({ skipped: true });
  const payload = JSON.stringify({ chat_id: chatId, text, parse_mode: 'HTML', disable_web_page_preview: true });
  if (proxySettings.enabled && proxySettings.url) return requestThroughProxy(proxySettings.url, token, payload);
  return performRequest(requestOptions(token, payload), payload);
}

module.exports = { sendTelegramMessage };