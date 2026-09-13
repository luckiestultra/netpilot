# VPS TCP Tune

用于 Linux VPS 的 TCP、BBR/FQ、内核队列和网卡队列调优脚本。脚本会在修改前备份它自己管理的文件和值，并提供精确回退。

它不会删除或修改 3x-ui、Xray 面板和入站配置，也不会因为执行 TCP 调优而重启 Xray。

> 调优只能改变 VPS 的内核参数和队列行为，不能增加云厂商提供的带宽，也不能保证解决跨网/跨境线路拥塞。

## 环境要求

- Linux VPS，使用 `root` 执行
- Bash、`sysctl`、`awk`、`ip`、`mktemp`、`install`
- 通过 GitHub 下载或更新时需要 `curl`
- 选项 `4` 如果发现没有 `ethtool`，会尝试使用 `apt-get`、`yum` 或 `dnf` 安装

## 快速开始

### 在线启动菜单

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/liuxr0814/vps-tcp-tune/main/vps-tcp-full-tune.sh)
```

脚本安装后会创建：

```text
/usr/local/bin/tcp.sh   实际脚本
/usr/local/bin/tcp      快捷命令
```

之后直接执行：

```bash
tcp
```

### 固定版本下载

如果 GitHub Raw 的 `main` 地址暂时返回旧缓存，使用提交地址可以保证下载指定版本。当前已验证版本为 `869827d973b398b51275049616795858766a962c`：

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/liuxr0814/vps-tcp-tune/869827d973b398b51275049616795858766a962c/vps-tcp-full-tune.sh \
  -o /tmp/vps-tcp-full-tune.sh

bash -n /tmp/vps-tcp-full-tune.sh
install -m 0755 /tmp/vps-tcp-full-tune.sh /usr/local/bin/tcp.sh
ln -sfn /usr/local/bin/tcp.sh /usr/local/bin/tcp
/usr/local/bin/tcp.sh
```

下载后先执行 `bash -n` 是可选的语法检查；检查失败时不要安装该文件。

如果菜单显示 `8. 退出脚本`，但输入提示是 `请选择数字 [0-7]`，说明拿到的是旧版本。当前版本应显示 `0. 退出脚本`，此时输入 `0` 退出。

## 菜单选项

| 选项 | 作用 | 是否包含其他选项 |
|---|---|---|
| `1` | 设置 IPv4 优先解析，修改 `/etc/gai.conf` | 仅执行 IPv4 优先 |
| `2` | 开启 BBR + FQ | 仅执行 BBR/FQ |
| `3` | 应用完整 TCP/UDP 内核调优、limits、MSS | 不执行 IPv4 优先，不执行网卡 ring/RPS |
| `4` | 调整网卡 ring、RPS 和 socket flow | 仅执行网卡队列调优 |
| `5` | 回退本脚本已经应用的全部修改 | 不删除脚本 |
| `6` | 从自有 GitHub 仓库下载并检查更新 | 更新前进行 Bash 语法检查 |
| `7` | 回退并卸载本调优脚本 | 不卸载 3x-ui/Xray |
| `0` | 退出菜单 | 不做修改 |

选项 `3` 和 `4` 是有意分开的：执行 `3` 不会自动开启 `4`。

## 命令行用法

```bash
tcp                 # 打开交互式菜单
tcp status          # 只读查看当前值和脚本目标值
tcp apply           # 等同于菜单选项 3
tcp rollback        # 回退本脚本的修改
tcp update          # 从 GitHub 更新脚本
tcp uninstall       # 回退并卸载本脚本
```

也可以直接使用实际脚本路径：

```bash
/usr/local/bin/tcp.sh status
```

## 如何验证调优是否生效

### 1. 查看脚本状态

```bash
tcp status
```

完整调优成功时应看到：

```text
状态：已应用；可执行 rollback
```

并且主要项目的 `current` 应与 `target` 一致，例如：

```text
net.core.default_qdisc              current=fq   target=fq
net.ipv4.tcp_congestion_control     current=bbr  target=bbr
```

### 2. 验证文件句柄

完整调优会写入 `1048576` 的 `nofile` 限制。已有 SSH/Termius 会话不会自动继承新限制，因此需要断开并重新登录后执行：

```bash
ulimit -n
```

完整调优成功的新会话通常应显示：

```text
1048576
```

在还没有执行选项 `3`，或尚未重新登录时看到 `1024`，不等于 TCP 调优失败。

### 3. 单独验证 BBR/FQ

```bash
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
```

目标值为：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

### 4. 验证网卡队列调优

网卡是否支持 ring/RPS 取决于云厂商虚拟网卡。选项 `4` 会对不支持的项目自动跳过；跳过不代表脚本失败。

```bash
sysctl net.core.rps_sock_flow_entries
```

如果该内核和网卡支持 RPS，目标值通常为 `32768`。

## 修改和回退范围

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

执行 `tcp rollback` 会恢复脚本修改前的文件和值，并删除脚本自己添加的 MSS/RPS 状态；不会删除其他程序添加的防火墙规则。

执行 `tcp uninstall` 会先回退，再删除调优脚本和 `tcp` 快捷命令；不会删除 3x-ui、Xray 或入站配置。

## 安全提示

在线执行 `bash <(curl ... )` 会直接运行下载内容。使用前应确认下载地址是自己的仓库；对生产 VPS 更稳妥的方式是使用固定提交地址下载、执行 `bash -n` 检查后，再安装到 `/usr/local/bin/tcp.sh`。

脚本不会自动从第三方地址下载“更新脚本”，更新来源固定为本仓库。选项 `4` 仅在缺少 `ethtool` 时调用系统包管理器安装该依赖。

## 许可证

本项目当前未单独声明许可证。使用、修改和发布前请按仓库所有者的要求处理。
