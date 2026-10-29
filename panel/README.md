# RebootNotify Panel

Panel 是 RebootNotify 的主控服务，负责管理多台 Linux Agent。

## 功能

- 接收 Agent pulse 并维护在线状态；
- 查看重启需求和可升级软件包；
- 向指定 Agent 下发 `upgrade`、`reboot` 命令；
- 记录命令状态、执行结果和失败原因；
- 通过 Telegram 推送状态变化、离线、检查异常和命令结果；
- 支持 HTTP、SOCKS5、SOCKS5H Telegram 代理。

## 安装与启动

要求 Node.js 18 或更高版本。

```bash
cd panel
npm start
```

默认配置：

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `3980` | HTTP 端口 |
| `HOST` | `0.0.0.0` | 监听地址 |
| `PANEL_TOKEN` | `change-me` | API 认证 Token，生产环境必须修改 |

生产环境示例：

```ini
[Unit]
Description=RebootNotify Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/RebootNotify/panel
ExecStart=/usr/bin/node server.js
Environment=NODE_ENV=production
Environment=PANEL_TOKEN=replace-with-a-random-token
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

保存为 `/etc/systemd/system/rebootnotify-panel.service` 后执行：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rebootnotify-panel
sudo systemctl status rebootnotify-panel
```

浏览器访问：

```text
http://Panel主机地址:3980
```

所有 Agent 的 `controller.url` 指向同一个地址即可实现一主多从。

## Agent 配置

Agent 配置示例：

```yaml
agent_id: "每台主机唯一的稳定 ID"
controller:
  enabled: true
  url: "http://panel.example.com:3980"
  token: "与 PANEL_TOKEN 相同"
  interval: 60
```

Agent 每个 pulse 最多领取一个命令。命令执行期间，Agent 会在后续 pulse 中续租；超过 5 分钟没有续租时，Panel 将命令重新放回 `pending`。

## 面板操作

概览页面提供：

- Agent 总数、在线数、需要重启数和升级包总数；
- 按主机名或 Agent ID 搜索；
- 按在线、离线、需要处理筛选；
- 查看软件包明细；
- 下发升级或重启；
- 按命令状态筛选操作记录。

Agent 状态在超过自身心跳间隔 3 倍没有上报后显示为离线。

## Telegram 通知

打开面板“设置”，填写：

- Bot Token；
- Chat ID；
- 通知开关。

通知类型：

- 检测到需要重启；
- Agent 离线；
- 发现可升级软件；
- Agent 检查异常；
- 维护命令完成或失败。

消息使用 HTML 格式，包含主机名、操作、数量和错误上下文。Bot Token 只保存在 Panel 的 `data/state.json`，不会返回给浏览器。

### Telegram 代理

代理只用于 Panel 访问 Telegram，不影响 Agent 下载或运行：

```text
http://127.0.0.1:7890
socks5://127.0.0.1:1080
socks5h://127.0.0.1:1080
```

支持带认证的 SOCKS5：

```text
socks5://username:password@127.0.0.1:1080
```

配置保存后使用“发送测试消息”验证。

## API

所有 `/api/` 请求都需要：

```http
Authorization: Bearer <PANEL_TOKEN>
```

### Agent API

| 方法 | 路径 | 用途 |
|---|---|---|
| `POST` | `/api/v1/agents/pulse` | 上报状态并领取/续租命令 |
| `POST` | `/api/v1/agents/:hostname/commands/:id/result` | 回报命令结果 |

### Panel API

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/api/panel/state` | 获取 Agent、统计和命令记录 |
| `POST` | `/api/panel/agents/:hostname/commands` | 创建升级或重启命令 |
| `GET` | `/api/panel/settings` | 获取脱敏设置 |
| `PUT` | `/api/panel/settings` | 保存 Telegram 和代理设置 |
| `POST` | `/api/panel/settings/telegram/test` | 发送测试消息 |

## 数据与备份

状态保存在：

```text
panel/data/state.json
```

文件包含主机状态、命令输出和 Telegram 配置。建议：

```bash
chmod 600 panel/data/state.json
```

备份前停止 Panel 或确保文件写入已完成。不要将包含 Bot Token 的状态文件提交到 Git。

## 故障排查

查看 Panel 日志：

```bash
sudo journalctl -u rebootnotify-panel -f
```

检查端口：

```bash
curl -i http://127.0.0.1:3980/
```

检查 API 认证：

```bash
curl -H "Authorization: Bearer $PANEL_TOKEN" \
  http://127.0.0.1:3980/api/panel/state
```

常见原因：

- Agent 不在线：检查 URL、Token、网络和 Agent systemd 日志；
- 命令一直 pending：Agent 未成功发送 pulse，或网络不可达；
- Telegram 失败：检查 Token、Chat ID、代理协议和代理认证信息；
- 页面 401：浏览器保存的 Token 与 `PANEL_TOKEN` 不一致。
