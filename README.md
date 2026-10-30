# VPS TCP Tune

面向通用 Linux VPS 的 TCP 诊断、参数建议、预算测速与回滚工具。根据当前内核能力、有效内存、CPU 配额和路径输入生成建议，保留 `tcp` 中文菜单与单文件运行方式。

调优不能增加云厂商带宽，也不能保证改善拥塞或代理体验。工具展示读回值和实际测量结果，不把配置成功当作性能提升。

## 环境与权限

- Linux、Bash 4+，基础命令需要 `sysctl`、`awk`。
- 修改系统、安装、回滚、更新和卸载需要 root；修改操作使用 `flock` 防止并发写入。
- 出口和队列诊断使用 `ip`，查看实际队列还需要 `tc`。不支持或缺失的能力会明确提示。
- 测速按需使用 `iperf3`、`python3`、GNU `timeout`；`--latency` 另需 `ping`。工具不自动安装这些测速依赖。
- 网卡高级选项需要 `ethtool`，缺失时提示自行安装并跳过 ring 操作。

小内存、单核、多核、cgroup v1/v2 和 IPv6-only 出口均有相应检测与保守处理；这不意味着所有虚拟化平台都允许修改参数。LXC/OpenVZ、受限容器及特殊内核可能只有部分能力可用。

## 下载、预览和安装

先下载到本地检查，诊断和计划不要求安装：

```bash
curl -fsSL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/liuxr0814/vps-tcp-tune/main/vps-tcp-full-tune.sh \
  -o /tmp/vps-tcp-full-tune.sh

bash -n /tmp/vps-tcp-full-tune.sh
bash /tmp/vps-tcp-full-tune.sh doctor
bash /tmp/vps-tcp-full-tune.sh plan --profile balanced
```

确认需要保留快捷命令后，以 root 执行显式安装：

```bash
bash /tmp/vps-tcp-full-tune.sh install
```

安装位置为 `/usr/local/bin/tcp.sh`，快捷命令为 `/usr/local/bin/tcp`。之后运行 `tcp` 打开菜单。`install` 遇到内容不同的既有安装文件会保护原文件；已有版本使用 `tcp update` 更新。

仍可通过一行命令直接打开菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/liuxr0814/vps-tcp-tune/main/vps-tcp-full-tune.sh)
```

直接打开菜单、运行 `doctor`、`plan` 或 `status` 不再隐式安装脚本。需要一行安装时，在同一命令后加 `install`。

## 推荐流程

```text
只读诊断 → 查看建议 → 确认并应用 → 读回验证 → 同条件测量与对比
                                      ↓
                               必要时恢复首次原值
```

### 诊断与建议

```bash
tcp doctor
tcp plan --profile proxy

# 带宽与 RTT 应来自同一条实际路径；不要直接填写网卡标称速率。
tcp plan --profile proxy --bandwidth 500 --rtt 80
```

`doctor` 查看有效内存、可用 CPU、可用/当前拥塞算法、默认与实际 qdisc，并提示可检测到的 tuned 配置。只读操作不测速、不加载模块或改内核。

`plan` 显示当前值、建议值与理由：

| 配置档 | 用途与策略 |
|---|---|
| `balanced` | 通用用途，默认档；新建议单 socket 上限受有效内存的约 1/24 约束。 |
| `proxy` | 代理、多连接用途；新建议上限更保守，约为有效内存的 1/32。 |
| `bulk` | 少量大流传输；允许较大的新建议上限，约为有效内存的 1/16。 |

所有档位的新建议上限还受 256MiB 限制。给定完整路径输入时，基础候选值采用 `2 × BDP + 256KiB`，其中 `BDP = 带宽(bit/s) × RTT(s) ÷ 8`，再受内存预算约束。这是可解释的保守策略，不是已证明的最优参数。

- `--bandwidth` 使用 Mbps，`--rtt` 使用 ms，支持正小数，必须同时提供。
- 没有完整路径输入时保留现有缓冲区；不会用固定 RTT 伪装实测结果。
- 保守模式只提高不足的缓冲上限，不降低已有更大值，也不抬高每连接初始缓冲。上限不是预分配内存，预算也不是全机内存硬上限。
- 内核已经提供 BBR 时才在计划中建议使用；仅凭 `bbr` 名称不能确定 BBR 代际。
- `default_qdisc=fq` 是默认配置，不代表正在使用的所有网卡队列都已变为 FQ。

### 应用与验证

```bash
# 先显示计划，确认后才写入和持久化。
tcp apply --profile proxy --bandwidth 500 --rtt 80

# 明确授权的非交互用法。
tcp apply --profile proxy --bandwidth 500 --rtt 80 --yes

tcp status
tcp verify
```

原有 `tcp apply` 命令仍保留，采用 `balanced` 档。基础调优默认保留 `tcp_mem`、socket 初始缓冲、ECN、TFO、重试次数、TIME_WAIT、IPv4/IPv6 地址策略；不再一并修改 limits/MSS，也不重启 Xray 或改动 3x-ui 入站。

`verify` 对比本工具两个 sysctl 配置路径中的期望值与运行值；没有可验证配置、参数不可读或存在偏离时返回非零。它验证参数一致性，不验证吞吐，也不核验所有外部配置文件或服务限制。其他调优器仍可能在稍后覆盖相同参数，应先解决管理冲突。

### 网络计数诊断

```bash
tcp diagnose
tcp diagnose --seconds 5
```

查看接收 softnet 丢弃/处理预算耗尽、监听队列溢出和 TCP 重传等累计计数；指定 `--seconds 1..60` 时观察增量，不发送测速流量。计数可能包含其他业务；TCP 重传不等于直接测量的端到端丢包率，单个计数也不能独自确定瓶颈。

## 有预算测速和前后对比

使用你有权测试、能够连接的 iperf3 服务端：

```bash
tcp bench --peer iperf.example.net --port 5201 \
  --budget-mib 256 --direction both --streams 1 \
  --timeout 30 --output before.json

# 应用计划后，用相同对端与选项重新测量。
tcp bench --peer iperf.example.net --port 5201 \
  --budget-mib 256 --direction both --streams 1 \
  --timeout 30 --output after.json

tcp compare before.json after.json
```

`iperf.example.net` 是占位符，需换成实际服务端。默认预算为 1024MiB，包含全部测试方向和并行流的 payload 目标；默认单流、双向、每方向最多 30 秒：

- `send`：VPS → 对端；`receive`：对端 → VPS；`both`：依次测试两个方向并分配预算。
- `--streams 1..32` 调整并行流，`--timeout 2..600` 设置每方向超时。
- `--latency` 使用 `ping` 额外采样空闲/负载时 ICMP RTT，输出 p95 与变化；ICMP 不可用或样本不足会明确提示。这不是完整的 Flent RRUL 测试。
- 测试前需要确认；非交互运行须显式加 `--yes`。失败对端不自动重试整轮测速，取消/超时会清理测试进程。
- payload 预算不等于商家计费硬上限，协议开销、重传、ACK 与可选 ICMP 流量另计。10Gbps 连跑 10 秒约为 12.5GB 单方向 payload，应按套餐选择预算。
- 高速链路可能在很短时间用完预算；短于 3 秒的样本会标记为不足以确定峰值，不会自动扩大预算。

JSON 报告记录测试条件、吞吐、重传、CPU 与可选延迟信息，以私有权限保存，包含对端地址和可能的错误详情；分享前自行脱敏。默认报告写在当前目录，`--output` 不覆盖已有文件。

`compare` 要求对端、端口、方向、流数、预算、超时和延迟采样选项一致，并拒绝失败或格式不匹配的报告。结果只代表该对端、方向和时段；VPS 与近端的测速不能代替用户到节点的真实代理体验，线路波动也可能造成前后差异。

## 中文菜单与兼容命令

原有菜单数字保留，新功能从选项 `8` 进入：

| 选项 | 作用 |
|---|---|
| `1` | 按需设置 IPv4 优先解析，修改 `/etc/gai.conf`。 |
| `2` | 尝试加载内核提供的 BBR，切换 BBR 和默认 FQ，并读回验证。 |
| `3` | 生成并确认保守自适应参数计划；用途和路径输入由菜单询问。 |
| `4` | 网卡 ring/RPS 高级操作；单核默认跳过 RPS，不支持的项目提示跳过。 |
| `5` | 恢复本工具首次记录的原值。 |
| `6` | 从本仓库下载、语法检查并更新脚本。 |
| `7` | 回滚并卸载本工具。 |
| `8` | 诊断、计划、预算测速、对比、验证和网络计数观察。 |
| `0` | 退出。 |

保留 `status/apply/rollback/update/uninstall`，新增 `doctor/plan/bench/compare/verify/diagnose/install`。`tcp help` 查看完整参数。

选项 `4` 可能提升设备 ring 至允许上限并设置 RPS，属于独立高级操作；硬件支持不等于一定有收益，使用前后应观察延迟、吞吐和 CPU。工具不安装替代内核，不自动开启 swap，也不提供深度限速器扫描、HTB 接管或命名配置存档。

## 备份、回滚和卸载

```bash
tcp rollback
tcp uninstall
```

本工具管理的主要路径：

```text
/etc/sysctl.d/10-bbr.conf
/etc/sysctl.d/99-network-performance.conf
/etc/modules-load.d/vps-tcp-full-tune.conf
/etc/gai.conf                         # 仅显式选择 IPv4 优先时
/var/lib/vps-tcp-full-tune/            # 原值、备份与状态
/usr/local/bin/tcp.sh
/usr/local/bin/tcp
```

旧版遗留的 limits/MSS 状态和已备份网卡项目仍参与回滚。首次原值不会因重复应用而被更新值覆盖；`rollback` 恢复首次记录的运行值和受管文件，成功后清理记录。恢复失败返回非零、保留备份并报告失败项，修复原因后可重试；此时卸载也会停止。

回滚不等于恢复任意时刻的完整系统快照，不删除其他程序的防火墙规则，也不能还原在工具之外发生的所有配置变化。对已运行服务，脚本自身的 `ulimit` 不等于该服务的实际句柄限制。

## 开发与测试

```bash
bash -n vps-tcp-full-tune.sh
bash tests/run.sh
```

完整测试包含建议边界、重复应用、失败注入、报告与真实本机回环测速；需要 Linux/Bash 4+，以及 `iperf3`、`python3`、`ping`、`timeout`、`ss` 和 `shellcheck`。缺少依赖会报错，不会当作通过。

`tests/test_bench_live.sh` 使用真实 `iperf3`，也可单独运行，不需要公网测速对端。真实内核写入集成测试另在 `tests/linux_apply_integration.sh`，仅允许在具有可写网络命名空间 sysctl 和相应权限的可丢弃 Docker 容器中运行，不包含在默认套件里。重启持久化效果仍需另行验证，不能只靠模拟测试宣布生产效果。

## 参考与取舍

实现参考多类上游思路，并结合本工具的单文件接口独立实现：

- [Kylin010/tcpfit](https://github.com/Kylin010/tcpfit)：参数推导、测试预算与清晰的结果状态；保留不确定性，不直接引入其遥测或深度整形逻辑。
- [redhat-performance/tuned](https://github.com/redhat-performance/tuned)：配置档、推荐与验证的工作流；不引入后台调优服务，不与外部管理器默认抢写。
- [tohojo/flent](https://github.com/tohojo/flent)：吞吐之外也关注负载时延迟；本工具只实现轻量 ICMP 辅助采样，不声称等同完整 Flent 测试套件。
- [leandromoreira/linux-network-performance-parameters](https://github.com/leandromoreira/linux-network-performance-parameters)：基于计数定位问题，而非堆叠参数。
- [Linux TCP 参数文档](https://docs.kernel.org/networking/ip-sysctl.html)、[网络扩展/RPS](https://docs.kernel.org/networking/scaling.html)、[default_qdisc](https://docs.kernel.org/admin-guide/sysctl/net.html#default-qdisc) 与 [iperf3 官方文档](https://software.es.net/iperf/invoking.html)：参数语义和测量边界。

本轮独立实现相关思路，没有直接合入上述项目的代码，也未改变本仓库既有代码的许可声明。
