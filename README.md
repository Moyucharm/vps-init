# vps-init

一键初始化 Linux 服务器的交互式脚本。支持 Ubuntu/Debian（apt）和 CentOS/Rocky/Alma（dnf/yum）。

## 功能

- 创建普通用户，设置密码和/或 SSH 公钥，加入 sudo/wheel 管理员组
- 修改主机名并同步更新 `/etc/hosts`
- 修改系统时区
- 可选：创建 swap 文件
- 可选：安装 Docker
- 切换 SSH 端口，锁定 root 直接登录
- 启用防火墙（ufw / firewalld），放行新 SSH 端口及 80/443
- **安全两步确认**：SSH/防火墙变更在后台执行，需用新账号重新登录后手动 confirm，超时自动回退

## 执行流程

```
阶段一（前台）          阶段二（后台）             阶段三（确认）
─────────────────      ────────────────────────   ──────────────────────
交互收集配置       →   启用防火墙 + 切换 SSH 端口  →  sudo server-init-confirm
创建用户/密码/公钥      等待 confirm（最多 10 分钟）    显示结果摘要，清理残留
改主机名/时区           超时未 confirm → 自动回退
可选 swap / Docker
```

## 快速开始

```bash
# 下载脚本
curl -O https://raw.githubusercontent.com/Moyucharm/vps-init/refs/heads/main/init-linux-server.sh

# 执行（需要 root）
sudo bash init-linux-server.sh
```

按提示依次输入：

| 提示 | 说明 |
|------|------|
| 普通用户名 | 不能为 root，只允许小写字母/数字/`_`/`-` |
| 密码 | 二次确认输入，可跳过（但密码和公钥至少选一个） |
| SSH 公钥 | 粘贴完整公钥内容，可跳过 |
| 主机名 | 回车保持当前值 |
| 时区 | 例如 `Asia/Shanghai`，回车保持当前值 |
| SSH 端口 | 1–65535，回车保持当前端口 |
| 密码登录 | 是否允许普通用户通过密码 SSH 登录 |
| swap 大小 | 可选，单位 MB |
| 安装 Docker | 可选 |

基础初始化完成后，脚本会再次确认是否进入 **SSH/防火墙危险阶段**。确认后后台任务自动启动，当前 SSH 会话可能断开，这是正常现象。

### 确认步骤

用新用户和新 SSH 端口重新登录后执行：

```bash
sudo server-init-confirm
```

脚本会等待后台任务完成，输出最终结果摘要，并自动清理所有临时文件。

## 参数

```
sudo bash init-linux-server.sh [选项]

选项：
  --dry-run       模拟执行，打印所有将执行的命令，不修改系统
  -h, --help      显示帮助
```

## 自动回退机制

进入 SSH/防火墙阶段后，若 **10 分钟内**未收到 `server-init-confirm`，后台任务会自动执行回退：

- SSH 端口恢复为原端口
- 重新允许 root 密码登录
- 关闭防火墙（ufw disable / firewalld stop）

## 兼容性

| 发行版 | 包管理器 | 防火墙 |
|--------|----------|--------|
| Ubuntu / Debian | apt | ufw |
| CentOS / Rocky / AlmaLinux | dnf / yum | firewalld |

## 状态文件

运行期间临时文件存放于 `/var/lib/server-init/`，`confirm` 完成后自动删除。

| 文件 | 说明 |
|------|------|
| `worker.log` | 后台任务完整日志 |
| `summary.txt` | 最终结果摘要 |
| `phase` | 当前阶段标记 |
| `worker.pid` | 后台进程 PID |

若脚本异常中断导致目录残留，手动清理后重新运行：

```bash
sudo rm -rf /var/lib/server-init
sudo rm -f /usr/local/sbin/server-init-confirm
```
