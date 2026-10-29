# RebootNotify

RebootNotify 是一个“一主多从”的 Linux 主机维护系统：

- **Panel**：统一接收 Agent 状态、下发维护命令、保存审计记录并发送 Telegram 通知。
- **Agent**：部署在被管理主机上，检查重启需求和可升级软件包，并执行 Panel 下发的升级/重启命令。
- **一主多从**：一个 Panel 可以管理多台 Agent；每台 Agent 使用独立的 `agent_id`。

## 工作方式

Agent 按 `controller.interval` 秒向 Panel 发送 pulse，内容包括：

- 在线心跳、主机名、Agent ID 和版本；
- 是否需要重启；
- 可升级软件包及数量；
- 升级检查错误；
- 当前正在执行的命令。

Panel 在 pulse 响应中返回一个待执行命令。命令拥有 5 分钟租约；Agent 异常退出或超时后，命令会重新进入队列。

## 快速部署

### 1. 启动 Panel

Panel 需要 Node.js 18 或更高版本。详细配置见 [panel/README.md](panel/README.md)。

```bash
cd panel
PANEL_TOKEN='替换为随机长令牌' npm start
```

默认监听 `0.0.0.0:3980`，浏览器访问：

```text
http://Panel主机地址:3980
```

Panel 的 `PANEL_TOKEN` 必须与 Agent 的 `controller.token` 完全一致。

### 2. 安装 Agent

在每台被管理主机执行：

```bash
sudo bash install.sh install \
  --controller-url "http://panel.example.com:3980" \
  --controller-token "替换为随机长令牌"
```

也可以远程执行：

```bash
curl -fsSL https://raw.githubusercontent.com/CHonesetDoPa/RebootNotify/refs/heads/main/install.sh \
  | sudo bash -s -- install \
  --controller-url "http://panel.example.com:3980" \
  --controller-token "替换为随机长令牌"
```

安装脚本会自动：

1. 识别 `amd64` 或 `arm64`；
2. 下载对应 Release 二进制；
3. 生成配置和稳定的 `agent_id`；
4. 创建并启动 `rebootnotify.service`。

重复执行 `install` 不会更换 `agent_id`，适合重新配置或升级。

## 安装、升级与卸载

### 安装或重新配置

```bash
sudo bash install.sh install \
  --controller-url "http://panel.example.com:3980" \
  --controller-token "token"
```

传入的配置参数会覆盖现有值；未传入的参数会沿用已有配置。

### 升级 Agent

```bash
sudo bash install.sh upgrade
```

指定版本：

```bash
sudo bash install.sh upgrade --version v1.2.3
```

强制从 Release 下载，忽略脚本目录中的本地二进制：

```bash
sudo bash install.sh upgrade --force-download
```

只写入文件、不重启服务：

```bash
sudo bash install.sh upgrade --no-start
```

### 查看状态

```bash
sudo bash install.sh status
```

### 卸载

```bash
sudo bash install.sh uninstall
```

卸载会停止服务并将安装目录移动为带时间戳的备份目录，不会立即删除配置。确认不需要备份后再手动删除。

## 安装脚本参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `--repo` | `CHonesetDoPa/RebootNotify` | GitHub 仓库 |
| `--version` | `latest` | Release 标签 |
| `--install-dir` | `/opt/RebootNotify` | 安装目录 |
| `--controller-url` | 无 | Panel 地址；首次安装必填 |
| `--controller-token` | 无 | Panel Token；首次安装必填 |
| `--controller-interval` | `60` | 心跳和命令拉取间隔，单位秒 |
| `--reboot-file` | `/var/run/reboot-required` | 重启标记文件 |
| `--reboot-interval` | `3600` | 重启检查间隔，单位秒 |
| `--initial-delay` | `0` | 首次检查前等待时间，单位秒 |
| `--upgrade-enabled` | `true` | 是否检查软件升级 |
| `--upgrade-interval` | `86400` | 软件升级检查间隔，单位秒 |
| `--proxy-enabled` | `false` | 是否为 Release 下载启用代理 |
| `--proxy-server` | `http://127.0.0.1:7890` | Release 下载代理 |
| `--force-download` | 关闭 | 忽略本地二进制并重新下载 |
| `--no-start` | 关闭 | 不启动或重启 systemd 服务 |

`--proxy-enabled` 只影响 Agent 二进制下载。Telegram 代理必须在 Panel 设置中配置，二者互不影响。

## 文件位置

默认 Agent 安装目录：

```text
/opt/RebootNotify/RebootNotify
/opt/RebootNotify/config.yaml
/etc/systemd/system/rebootnotify.service
```

Panel 数据文件：

```text
panel/data/state.json
```

该文件包含 Agent 状态、命令记录和通知设置，应限制文件权限并纳入备份策略。

## 服务管理

```bash
sudo systemctl status rebootnotify
sudo systemctl restart rebootnotify
sudo systemctl stop rebootnotify
sudo journalctl -u rebootnotify -f
```

## 常见问题

### Panel 页面提示未授权

确认浏览器输入的 Panel Token 与 Panel 启动环境中的 `PANEL_TOKEN` 一致。

### Agent 没有出现在面板

依次检查：

1. Agent 服务是否运行：`sudo systemctl status rebootnotify`；
2. `controller.url` 是否能从 Agent 主机访问；
3. `controller.token` 是否与 `PANEL_TOKEN` 一致；
4. 查看日志：`sudo journalctl -u rebootnotify -n 100 --no-pager`。

### Telegram 无法发送

在 Panel“设置”中检查 Bot Token、Chat ID 和代理地址。支持：

```text
http://127.0.0.1:7890
socks5://127.0.0.1:1080
socks5h://127.0.0.1:1080
```

SOCKS5 支持 `socks5://用户名:密码@主机:端口` 形式。

## 安全建议

- 使用随机、足够长的 Panel Token；
- 不要把 Token 写入公开仓库或命令历史；
- Panel 建议放在 HTTPS 反向代理后；
- 只允许受信任的 Agent 访问 Panel API；
- Agent 以 root 运行，因为升级和重启需要系统权限。
