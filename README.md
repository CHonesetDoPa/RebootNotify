# RebootNotify

一个用于检测系统重启需求并通过 Telegram 通知的轻量工具。

## 安装脚本

项目提供了一键安装脚本 [install.sh](install.sh)，支持：

- 自动安装 `supervisor`
- 自动识别 `x86_64/arm64` 架构并下载对应二进制
- 交互式填写配置（基于远程 `config.example.yaml` 模板）
- 写入并启用 Supervisor 服务

## 快速使用

### 1) 本地执行安装

```bash
sudo bash install.sh install
```

### 2) 远程执行安装（curl | bash）

```bash
curl -fsSL https://raw.githubusercontent.com/CHonesetDoPa/RebootNotify/refs/heads/main/install.sh | sudo bash -s -- install
```

说明：
- 即使通过 `curl | bash` 执行，也会进入交互式提问。
- 交互内容来自远程模板：
  `https://raw.githubusercontent.com/CHonesetDoPa/RebootNotify/refs/heads/main/config.example.yaml`

### 3) 卸载

本地卸载：

```bash
sudo bash install.sh uninstall
```

远程卸载：

```bash
curl -fsSL https://raw.githubusercontent.com/CHonesetDoPa/RebootNotify/refs/heads/main/install.sh | sudo bash -s -- uninstall
```

## 常用参数

```bash
sudo bash install.sh install \
  --repo CHonesetDoPa/RebootNotify \
  --version latest \
  --install-dir /opt/RebootNotify
```

参数说明：
- `--repo`：GitHub 仓库（默认 `CHonesetDoPa/RebootNotify`）
- `--version`：Release 标签，默认 `latest`
- `--install-dir`：安装目录，默认 `/opt/RebootNotify`

## 环境变量（可选）

安装脚本支持以下环境变量（可覆盖交互默认值）：

- `GITHUB_REPO`
- `VERSION`
- `INSTALL_DIR`
- `TOKEN`
- `CHAT_ID`
- `PROXY_ENABLED`
- `PROXY_SERVER`
- `REBOOT_FILE`
- `REBOOT_INTERVAL`
- `INITIAL_DELAY`
- `UPGRADE_ENABLED`
- `UPGRADE_INTERVAL`
- `REMOTE_CONFIG_TEMPLATE_URL`

示例：

```bash
TOKEN="your_bot_token" CHAT_ID="your_chat_id" \
curl -fsSL https://raw.githubusercontent.com/CHonesetDoPa/RebootNotify/refs/heads/main/install.sh | \
sudo bash -s -- install
```

## 安装后的文件位置

默认安装目录：`/opt/RebootNotify`

- 二进制：`/opt/RebootNotify/RebootNotify`
- 配置：`/opt/RebootNotify/config.yaml`
- Supervisor 配置：`/etc/supervisor/conf.d/rebootnotify.conf`

## 服务管理

```bash
sudo supervisorctl status rebootnotify
sudo supervisorctl restart rebootnotify
sudo supervisorctl stop rebootnotify
```
