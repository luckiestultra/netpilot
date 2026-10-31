<p align="center"><strong>简体中文</strong> · <a href="./README.en.md">English</a></p>

<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="NetPilot：Linux VPS 网络诊断与 TCP 调优，支持中英文菜单。">
</p>

NetPilot 是 Linux VPS 网络诊断与 TCP 调优工具，自动完成测速、备份、调优和前后对比。

[开始使用](#开始使用) · [一键调优](#一键调优) · [查看结果](#查看结果) · [维护与恢复](#维护与恢复) · [交给 AI](#交给-ai) · [完整参考](#完整参考)

## 开始使用

以 root 在 Linux 服务器上运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckiestultra/netpilot/main/netpilot.sh)
```

脚本自动保存并打开中文菜单。**选 `9`，等待自动调优完成，看最终结果即可。** 无需填写参数或继续回答问题。以后选 `10` 可再看结果，`L` 切换中英文，`0` 退出。

以后在同一台服务器直接运行：

```bash
netpilot
```

## 一键调优

菜单 `9` 或 `netpilot tune` 自动测量、逐项判断、备份应用并复测。算法、缓冲区等配置分别判断：某一项没有调整依据就保留该项，其他项继续检查。**保留原值不代表这台机器已最优。**

**整轮测试上限 16GiB**，按需使用，协议开销另计。修改前备份；应用后失败、取消、复测不可比或确认退化时，自动恢复本轮变更。测速源拒绝请求时停止本轮。

## 查看结果

主菜单选 `10`，或运行：

```bash
netpilot report
```

先看结果首行，常见结果如下：

| 结果 | 含义 |
|---|---|
| 已调整并核验 | 本轮修改已通过配置核验；不等于已证明提速。 |
| 保留原配置 | 本轮没有保留新的配置改动；不代表配置已最优。 |
| 已恢复原配置 | 本轮变更已撤回，恢复到本轮开始时的配置。 |
| 未完成 | 查看原因与配置状态；恢复失败时保留备份。 |

取消或旧报告可能显示更具体的配置状态，请按实际提示判断。下方保留算法选择、测试数据和失败原因。测速只反映服务器到测试源的路径与时段，配置核验成功不等于业务提速。

报告默认位于 `/tmp/netpilot-reports`，可能被系统清理或在重启后消失。请核对报告时间：本轮尚未生成报告时，看到的可能是旧记录；损坏或不完整的报告会报错。自定义目录用 `netpilot report --report-dir DIR`。当前配置用 `netpilot status` 或 `netpilot verify` 查看。

## 维护与恢复

| 操作 | 菜单 | 命令 |
|---|---|---|
| 更新并打开菜单 | `6` | `netpilot update` |
| 恢复首次原值 | `5` | `netpilot rollback` |
| 卸载工具并清理报告 | `7` → `1`，默认 | `netpilot uninstall` |
| 回滚后卸载 | `7` → `2` | `netpilot uninstall --rollback` |

回滚恢复**首次保存的原值**。默认卸载清理工具和默认目录中的自动报告，保留调优配置与恢复备份。恢复尚未完成时保留对应恢复目录并提示；自定义报告目录自行管理。回滚后卸载须先恢复成功，无记录或恢复失败时停止。卸载均需 `y/N` 确认。

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
| `2` | 明确启用内核提供的 BBR 与默认 FQ。 |
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

直接运行 `netpilot tune` 即可，以下参数仅供需要自定义时参考：

| 参数 | 默认值 | 用途 |
|---|---|---|
| `--profile` | `balanced` | [选择用途](#参数建议)。 |
| `--budget-mib` | `auto` | 按需采样，整轮最多 16GiB；填写整数 1–1024 则使用固定 MiB 上限。 |
| `--timeout` | `30` | 每阶段超时，整数 5–120 秒；测量阶段累计上限为该值的 9 倍，本地应用、恢复和清理耗时另计。 |
| `--endpoint` | `https://speed.cloudflare.com` | 兼容下载/上传接口的 HTTPS 源；HTTP 仅限回环地址。 |
| `--report-dir` | `/tmp/netpilot-reports` | 报告目录不能向其他用户开放写权限，也不能位于 `/var/lib/netpilot/` 内。 |

测试从 **64KiB** 小请求起步，逐批增加至最多 **4 个连接、每次 4MiB**；这是客户端策略。整轮账本覆盖前测、算法比较、复测与一次退化复核。每批发出前扣预算，失败、部分传输和取消不退款；HTTP 拒绝后停止本轮，不再发起新批次或切源重跑；应用前遇到拒绝时不改配置。比较前为正常复测和可能追加的复核各预留一份基线工作量，不能因比较耗尽预算后再应用配置。

当前为 CUBIC 或 BBR 时，算法项比较另一种算法；其他算法保留并说明未评价。比较的固定上传工作量根据前测实际 TCP 发送忙碌时间与经过时间确定，至少为前测上传字节数的两倍，并以 3.5 秒为规划目标；这不保证样本一定有效。先检查整轮预算及后续复测预留。双方固定端点、IP、可验证节点、连接数、请求批次和超时，交替安排顺序，只使用 VPS 发送的上传样本。需要 3 对有效比较：每对候选吞吐均至少为原算法的 110%，双方经过时间与 TCP 实际发送忙碌时间均至少 3 秒，上传 TCP SRTT 的成对差异中位数恶化不超过 `max(1ms, 原算法中位数的20%)`。测试连接逐条设置并读回算法，比较时不切全局默认值、不写持久配置。数据缺失、不支持、短样本或预算不足均只保留原算法项，其他参数继续分别判断；若无法保障后续复测则不应用配置。这不保证所有线路都能完成算法比较，也不增加公网测速源；阈值是保守产品规则，不是统计显著性证明。

速率按总字节数除以实际经过时间计算，表示 HTTP 观测吞吐。前测双向达到 3 秒才用于估算缓冲区；不足时保留现有缓冲区。路径延迟采用 3 次 TCP 建连耗时平均值，算法判定另用上传 TCP SRTT。下载不能证明本机发送算法更好，短样本或采样到时均不能证明线路峰值。

复测沿用前测 IP、节点、并发数、分批请求计划和超时，不为凑时长补量；更快而不足 3 秒时如实标明。任一方向吞吐下降超过 10%，在预留预算内追加一次同条件复核；两次同方向退化，或无法复核时，恢复本轮变更并说明未确认收益。

前测失败不改配置。本轮写入后的应用、核验、复测失败，取消或条件不可比，均尝试恢复本轮开始时的参数和文件，保留既有首次备份。发现外部改动时报告冲突并保留恢复材料；恢复失败明确报错。没有改配置就不触发恢复。报告保存前后样本、算法判定和预算账本；菜单 `10` 可再次查看具体原因，旧报告仍可读取。

### 参数建议

| 配置档 | 用途 |
|---|---|
| `balanced` | 通用，默认。 |
| `proxy` | 代理、多连接，缓冲建议更保守。 |
| `bulk` | 少量大文件传输，缓冲预算更大。 |

工具按路径带宽、延迟和有效内存，分别估算收、发缓冲上限。只提高不足值，保留已有更大值和初始缓冲，不预先分配等量内存。某项已达到建议值，只说明该项无需按当前建议提高，不能据此判断整机最优。

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

`plan` 只预览，`apply` 确认后应用；两者保留当前拥塞算法，不隐式加载模块。省略路径数据保留现有缓冲区。菜单中不知道带宽可直接回车；已填带宽但不知道延迟，可回车后输入目标自动测量。延迟测量失败则停止。

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

一键调优的自动恢复另用本轮快照，只撤回本轮变更；菜单 `5` / `rollback` 始终恢复首次保存的原值。新默认算法主要影响后续连接，工具不自动重启代理服务或已有业务连接。选择 BBR 时设置默认 FQ，当前网卡实际队列单独展示。

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
