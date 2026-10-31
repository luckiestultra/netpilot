<p align="center"><strong>简体中文</strong> · <a href="./README.en.md">English</a></p>

<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="NetPilot：Linux VPS 网络诊断与 TCP 调优，支持中英文菜单。">
</p>

NetPilot 是 Linux VPS 网络诊断与 TCP 调优工具，自动完成测速、备份、调优和前后对比。

[开始使用](#开始使用) · [查看结果](#查看结果) · [维护与恢复](#维护与恢复) · [交给 AI](#交给-ai) · [完整参考](#完整参考)

## 开始使用

以 root 在 Linux 服务器上运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckiestultra/netpilot/main/netpilot.sh)
```

脚本自动保存并打开中文菜单。**选 `9` 一键调优，选 `10` 看结果。** `L` 切换中英文，`0` 退出。

调优会依次完成前测、备份应用、参数核验和复测对比，无需手填带宽、延迟、流量或报告名。先小流量探测，再使用最多 4 个连接并发测量；高速线路自动增加测试数据，达到采样时长即停。**整轮上限 16GiB**，不是每次必耗，协议开销另计。

以后在同一台服务器直接运行：

```bash
netpilot
```

## 查看结果

主菜单选 `10`，或运行：

```bash
netpilot report
```

摘要显示配置状态、前后测量、预算模式、已完成测试数据量和报告更新时间。默认读取 `/tmp/netpilot-reports`，系统清理或重启后可能消失；若本轮尚未生成报告，可能显示旧记录，请核对时间。自定义目录使用 `netpilot report --report-dir DIR`。

| 状态 | 含义 |
|---|---|
| 完成 | 流程与比较完成。 |
| 部分完成 | 复测或比较未完成，已核验配置保留。 |
| 失败 | 查看阶段与原因；恢复失败时保留备份。 |
| 已取消 | 查看配置和回滚状态，确认是否已恢复。 |

核验检查参数是否一致；测速反映服务器到测试源的路径。需要查看当前配置时，用 `netpilot status` 或 `netpilot verify`。

## 维护与恢复

| 操作 | 菜单 | 命令 |
|---|---|---|
| 更新并打开菜单 | `6` | `netpilot update` |
| 恢复首次原值 | `5` | `netpilot rollback` |
| 卸载工具并清理报告 | `7` → `1`，默认 | `netpilot uninstall` |
| 回滚后卸载 | `7` → `2` | `netpilot uninstall --rollback` |

回滚恢复**首次保存的原值**。默认卸载清理工具和默认目录中的自动报告，保留调优配置与恢复备份；自定义报告目录自行管理。回滚后卸载须先恢复成功，无记录或恢复失败时停止。卸载均需 `y/N` 确认。

## 交给 AI

把[项目说明](./docs/for-ai.md)链接和你的问题发给 AI：

```text
https://raw.githubusercontent.com/luckiestultra/netpilot/main/docs/for-ai.md
```

可复制菜单 `10` 的结果；需要完整数据时运行：

```bash
netpilot report --json
```

分享前在副本中隐藏 IP、域名等私人信息，保留报错和测速数字。没有报告时，提供执行命令和错误输出即可。

## 完整参考

### 菜单与命令

| 主菜单 | 功能 |
|---|---|
| `9` | 一键调优。 |
| `10` | 查看最新报告。 |
| `8` | 诊断与独立测速。 |
| `5` | 恢复首次原值。 |
| `6` | 更新 NetPilot。 |
| `7` | 卸载，默认保留配置。 |
| `1` | IPv4 优先，修改 `/etc/gai.conf`。 |
| `2` | 启用内核提供的 BBR 与默认 FQ。 |
| `3` | 手动调优，预览后确认。 |
| `4` | 网卡 ring / RPS；单核跳过 RPS。 |
| `L` / `0` | 切换会话语言 / 退出。 |

主菜单 `8` 的子菜单：

| 选择 | 命令 | 功能 |
|---|---|---|
| `1` | `netpilot doctor` | 检查环境。 |
| `2` | `netpilot plan` | 预览建议。 |
| `3` | `netpilot bench --peer HOST` | iperf3 测速。 |
| `4` | `netpilot compare BEFORE.json AFTER.json` | 比较 iperf3 报告。 |
| `5` | `netpilot verify` | 核验参数。 |
| `6` | `netpilot diagnose --seconds 5` | 观察计数增量。 |
| `0` | — | 返回主菜单。 |

`diagnose` 不带参数看累计值，`--seconds` 范围 1–60；重传计数不是端到端丢包率。子菜单操作后返回主菜单。

`netpilot menu` 打开菜单，`netpilot help` 或 `netpilot COMMAND --help` 查看帮助，`netpilot install` 显式安装。

### 语言设置

默认中文，菜单 `L` 切换本次会话语言。命令行使用 `netpilot --lang en doctor`；`--lang zh|en` 放在子命令前，优先于环境变量 `NETPILOT_LANG`。

### 自动调优参数

`netpilot tune` 支持以下参数：

| 参数 | 默认值 | 用途 |
|---|---|---|
| `--profile` | `balanced` | [选择用途](#参数建议)。 |
| `--budget-mib` | `auto` | 按需采样，整轮最多 16GiB；填写整数 1–1024 则使用固定 MiB 上限。 |
| `--timeout` | `30` | 每阶段超时，整数 5–120 秒。 |
| `--endpoint` | `https://speed.cloudflare.com` | 兼容下载/上传接口的 HTTPS 源；HTTP 仅限回环地址。 |
| `--report-dir` | `/tmp/netpilot-reports` | 报告目录不能向其他用户开放写权限，也不能位于 `/var/lib/netpilot/` 内。 |

测试先从 **64KiB** 小请求开始，再逐批增加至最多 **4 个连接、每次 4MiB**；这是客户端策略，不代表服务端限制。前测、复测各占一半预算，再平分给下载和上传。每批发出前扣预算，失败不退款；HTTP 拒绝后不再发送新批次，不自动重试。

默认自动模式在同一轮逐步增加数据，前测每个方向达到 3 秒或用完该方向的上限后停止，不重新测速。整轮上限包含前后双向，实际用量取决于被测路径；显式数字预算始终按固定上限执行。

速率按总字节数除以实际经过时间计算，表示多连接 HTTP 观测吞吐。只有前测双向均达到 3 秒才据此估算缓冲区；达到上限仍为短样本时，仅做基础调优并保留缓冲区。采样时长足够也不代表跑满线路。延迟采用 3 次 TCP 建连耗时的平均值。

复测沿用前测的 IP、节点、并发数、分批请求计划和超时，不额外补量；复测更快而不足 3 秒时也如实标明。报告自动保存为 `before.json`、可获得的 `after.json` 和 `summary.json`；旧串行报告仍可查看，与并发报告不能混合比较。

前测失败不改配置。本轮写入后应用或核验失败会尝试恢复首次原值；复测失败保留已核验配置。HTTP 错误会显示状态码、下载或上传方向、单次请求大小和已扣预算；菜单 `10` 可再次查看。取消时以报告中的配置和回滚状态为准。

### 参数建议

| 配置档 | 用途 |
|---|---|
| `balanced` | 通用，默认。 |
| `proxy` | 代理、多连接，缓冲建议更保守。 |
| `bulk` | 少量大文件传输，缓冲预算更大。 |

工具按路径带宽、延迟和有效内存，分别估算收、发缓冲上限。只提高不足值，保留已有更大值和初始缓冲，不预先分配等量内存。

**手动模式可选**：菜单 `3` 或 `plan` / `apply`；一键调优无需填写以下路径数据。

| 参数 | 用法 |
|---|---|
| `--profile` | 上表中的配置档。 |
| `--bandwidth` | 同一路径的 Mbps，正数 ≤1000000。 |
| `--rtt` | 同一路径的 ms，正数 ≤60000，须与带宽一起提供。 |
| `--rtt-target HOST` | 用 ping 测延迟；须提供带宽，与 `--rtt` 互斥。 |
| `--yes` | `apply` 跳过确认。 |

将示例中的 500Mbps、80ms 换成实际路径数据：

```bash
netpilot plan --profile proxy --bandwidth 500 --rtt 80
netpilot apply --profile proxy --bandwidth 500 --rtt 80
```

`plan` 只预览，`apply` 确认后应用。省略路径数据保留现有缓冲区。菜单中不知道带宽可直接回车；已填带宽但不知道延迟，可回车后输入目标自动测量。延迟测量失败则停止。

### 测速与对比

已有自己的 iperf3 服务端时，可使用独立 `bench`；它与一键调优的自动测量分别使用不同报告格式。

| 参数 | 默认值与范围 |
|---|---|
| `--peer HOST` | 必填，主机名、IPv4 或 IPv6。 |
| `--port` | 5201；1–65535。 |
| `--budget-mib` | 1024MiB；1–1048576，覆盖全部方向和流。 |
| `--direction` | `both`；`send` 为 VPS → 对端，`receive` 相反。 |
| `--streams` | 1；1–32。 |
| `--timeout` | 30 秒；2–600，每方向分别计时。 |
| `--latency` | 可选 ping 空闲/负载延迟采样。 |
| `--output FILE` | 默认自动命名，不覆盖已有文件。 |
| `--yes` | 跳过确认，非交互运行时必需。 |

将 `iperf.example.net` 换成实际服务端，两次测速之间完成所选调优与核验：

```bash
netpilot bench --peer iperf.example.net --budget-mib 256 --output before.json
# 调优并核验后，以相同条件复测
netpilot bench --peer iperf.example.net --budget-mib 256 --output after.json
netpilot compare before.json after.json
```

`compare` 仅接受不超过 1MiB 的普通 iperf3 JSON 报告；测试条件和实际对端须一致，失败或缺少 `remote_endpoints` 的旧报告会被拒绝。自动调优已完成比较，无需另跑此命令。

预算不含协议开销、重传及可选 ICMP；短样本不能判断峰值，ICMP 也不等于业务延迟。失败不自动重试，取消或超时清理测试进程。

### 配置文件与备份

首次修改前保存原值和文件，重复应用不覆盖首次基线。回滚成功后清理恢复记录，下次修改建立新基线；测速报告独立保存。

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/netpilot.sh`、`/usr/local/bin/netpilot` | 程序、快捷命令。 |
| `/var/lib/netpilot/` | 原值、备份、恢复状态。 |
| `/tmp/netpilot-reports/` | 临时自动报告，卸载时清理。 |
| `/etc/sysctl.d/99-netpilot.conf`、`/etc/sysctl.d/10-netpilot-bbr.conf` | 调优与 BBR 参数。 |
| `/etc/modules-load.d/netpilot.conf` | BBR 模块加载。 |
| `/etc/gai.conf` | IPv4 优先配置。 |
| `/run/netpilot.lock` | 写操作锁。 |

恢复失败会保留备份。仅卸载后，重新运行在线命令并选 `5`，可用保留的备份恢复；回滚范围为 NetPilot 管理的变更。

旧版报告可用 `netpilot report --report-dir /var/log/netpilot` 查看，卸载时也清理可识别的工具报告；混有其他文件的运行目录会保留并提示。

### 环境要求

| 功能 | 依赖 |
|---|---|
| 基础运行 | Linux、Bash 4+、`sysctl`、`awk`；在线入口需 `curl`。 |
| 修改配置与程序维护 | root、`flock`；清理已有报告需 `python3`。 |
| 自动调优 | `python3`、GNU `timeout`。 |
| 诊断 / 网卡设置 | `ip`、`tc` / `ethtool`。 |
| 手动测延迟 | `ping`、GNU `timeout`。 |
| 查看报告 | `python3`、相应读取权限。 |
| 独立测速 / 比较 | `iperf3`（测速）、`python3`、GNU `timeout`（测速）；延迟采样另需 `ping`。 |

依赖按所选功能安装，缺项会提示。受限容器或特殊内核可能只支持部分功能。

### 开发与测试

在可丢弃 Linux 容器中以 root 运行：

```bash
bash -n netpilot.sh
bash tests/run.sh
```

套件需 `iperf3`、`python3`、`ping`、`timeout`、`ss`、`shellcheck`。`tests/*_cli_integration.sh` 和 `tests/linux_apply_integration.sh` 单独运行；后者需可写的网络命名空间 sysctl 与相应权限，重启持久化另行验证。

[更新记录](./CHANGELOG.md)
