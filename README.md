# VPS TCP Tune

Linux VPS TCP、BBR/FQ、内核队列和网卡队列调优脚本。脚本会在修改前备份自己管理的文件和值，并提供精确回退。

脚本不会删除或修改 3x-ui、Xray、面板和入站配置，也不会因为执行调优而重启 Xray。

> 调优只能改变 VPS 的内核参数和队列行为，不能增加云厂商提供的带宽，也不能保证解决线路拥塞。

## 环境要求

- Linux VPS，使用 `root` 执行
- Bash、`sysctl`、`awk`、`ip`、`mktemp`、`install`
- 下载或更新脚本需要 `curl`
- 选项 `4` 在缺少 `ethtool` 时，会尝试使用 `apt-get`、`yum` 或 `dnf` 安装

## 下载和安装

### 一行启动

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/liuxr0814/vps-tcp-tune/main/vps-tcp-full-tune.sh)
```

这条命令会直接下载并运行脚本；需要先检查时，使用下面的“下载后检查再安装”流程。

### 下载后检查再安装

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/liuxr0814/vps-tcp-tune/main/vps-tcp-full-tune.sh \
  -o /tmp/vps-tcp-full-tune.sh

bash -n /tmp/vps-tcp-full-tune.sh
install -m 0755 /tmp/vps-tcp-full-tune.sh /usr/local/bin/tcp.sh
ln -sfn /usr/local/bin/tcp.sh /usr/local/bin/tcp
/usr/local/bin/tcp.sh
```

安装完成后：

```text
/usr/local/bin/tcp.sh   实际脚本
/usr/local/bin/tcp      快捷命令
```

之后直接执行：

```bash
tcp
```

## 菜单

| 选项 | 作用 |
|---|---|
| `1` | 设置 IPv4 优先解析，修改 `/etc/gai.conf` |
| `2` | 开启 BBR + FQ |
| `3` | 应用完整 TCP/UDP 内核调优、limits 和 MSS |
| `4` | 调整网卡 ring、RPS 和 socket flow |
| `5` | 回退本脚本已经应用的全部修改 |
| `6` | 从本仓库下载并检查更新 |
| `7` | 回退并卸载本调优脚本 |
| `0` | 退出菜单 |

## 命令行用法

```bash
tcp                 # 打开菜单
tcp status          # 只读查看当前值和目标值
tcp apply           # 应用完整 TCP 调优，等同于菜单 3
tcp rollback        # 回退本脚本的修改
tcp update          # 从 GitHub 更新脚本
tcp uninstall       # 回退并卸载本脚本
```

也可以使用实际脚本路径：

```bash
/usr/local/bin/tcp.sh status
```

## 验证是否生效

### 查看脚本状态

```bash
tcp status
```

完整调优成功时应看到：

```text
状态：已应用；可执行 rollback
```

主要项目的 `current` 应与 `target` 一致，例如：

```text
net.core.default_qdisc              current=fq   target=fq
net.ipv4.tcp_congestion_control     current=bbr  target=bbr
```

### 查看 BBR/FQ

```bash
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
```

目标值：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

### 查看文件句柄

完整 TCP 调优会设置 `1048576` 的 `nofile` 限制。重新连接 SSH/Termius 后执行：

```bash
ulimit -n
```

目标值：

```text
1048576
```

### 查看 RPS

网卡是否支持 ring/RPS 取决于云厂商虚拟网卡；不支持的项目会自动跳过。

```bash
sysctl net.core.rps_sock_flow_entries
```

支持 RPS 时目标值通常为 `32768`。

## 修改范围

脚本可能管理以下内容：

- `/etc/sysctl.d/10-bbr.conf`
- `/etc/sysctl.d/99-network-performance.conf`
- `/etc/security/limits.d/99-network-performance.conf`
- `/etc/gai.conf`
- IPv4 `POSTROUTING` MSS 自适应规则
- 网卡 ring、RPS 和 `net.core.rps_sock_flow_entries`

备份和状态目录：

```text
/var/lib/vps-tcp-full-tune/
```

## 回退和卸载

回退本脚本的修改：

```bash
tcp rollback
```

脚本会恢复执行前备份的文件和值，并删除自己添加的 MSS/RPS 状态；不会删除其他程序添加的防火墙规则。

卸载本脚本：

```bash
tcp uninstall
```

卸载会先回退脚本修改，再删除调优脚本和 `tcp` 快捷命令，不会删除 3x-ui、Xray 或入站配置。
