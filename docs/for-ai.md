# NetPilot 项目说明

NetPilot 是 Linux VPS 网络诊断与 TCP 调优工具。单文件 Bash 脚本，默认中文，支持英文、自动测速、配置备份与回滚。

## 使用入口

Linux、Bash 4+；首次以 root 运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckiestultra/netpilot/main/netpilot.sh)
```

脚本自动保存并打开菜单。以后运行 `netpilot` 使用本机副本；在线命令每次都会下载。更新用 `netpilot update`，下载或校验失败不替换已安装版本。

| 主菜单 | 功能 |
|---|---|
| `9` | 一键调优，自动前测、生成方案、备份应用、核验、复测比较。 |
| `10` | 自动查找并显示最新汇总报告。 |
| `3` | 手动调优，预览后确认。 |
| `5` | 恢复首次原值。 |
| `6` / `7` | 更新 / 卸载。 |
| `8` → `1` / `2` | 环境检查 / 参数计划。 |
| `8` → `3` / `4` | iperf3 测速 / 比较两份报告。 |
| `8` → `5` / `6` | 配置核验 / 网络计数观察。 |
| `1` / `2` / `4` | IPv4 优先 / BBR 与默认 FQ / 网卡 ring、RPS。 |
| `L` / `0` | 切换会话语言 / 退出。 |

子菜单操作后返回主菜单。打开菜单不应用调优，退出后保留配置和报告。`--lang zh|en` 放在子命令前，优先于 `NETPILOT_LANG`；默认中文，菜单语言选择不保存为下次偏好。

## 自动调优

```bash
netpilot tune
```

无需手填带宽、RTT、对端或报告名，也无需单独运行前后测速与 `compare`。调用后无需继续输入，会产生测试流量并可能修改配置。

| 参数 | 默认值 / 范围 |
|---|---|
| `--profile` | `balanced` 通用；`proxy` 代理、多连接，缓冲建议更保守；`bulk` 少量大文件，预算更大。 |
| `--budget-mib` | 128；整数 1–1024MiB，覆盖整轮前后双向测量。 |
| `--timeout` | 30；整数 5–120 秒，前测与复测分别计时。 |
| `--endpoint` | `https://speed.cloudflare.com`；需兼容下载/上传接口的 HTTPS 源，明文 HTTP 仅限显式回环地址。 |
| `--report-dir` | `/tmp/netpilot-reports`；每轮建立私有 `run.*` 目录。 |

`tune` 不接受 `--bandwidth`、`--rtt`、`--rtt-target` 或 `--yes`。自定义测速源不能含凭据、查询、片段或业务路径；普通网页不能代替测速接口。

报告目录不能位于 `/var/lib/netpilot/` 内，须由当前用户拥有，且不允许组或其他用户写入；各级上级目录由 root 或当前用户拥有并防止被替换。带 sticky bit 的 root 所有 `/tmp` 可作上级目录，最终报告目录不能共享写入。

### 测量与建议

- 测双向 HTTP 有效吞吐，包含串行分块请求的开销，取较高速率换算 Mbps；不等于线路峰值。延迟取 3 次 TCP 建连耗时平均值，不是 ICMP RTT 或业务延迟。
- 新缓冲建议为 `2 × BDP + 256KiB`，`BDP = 带宽(bit/s) × RTT(s) ÷ 8`。收、发缓冲区各自的新上限预算：`balanced` 约有效内存的 1/24、`proxy` 约 1/32、`bulk` 约 1/16，且各自的新建议不超过 256MiB；不是单连接收发合计内存上限。只提高不足上限，保留已有更大值和初始缓冲；上限不代表立即分配的内存。
- 单次请求最多 4MiB，是统一客户端策略，不是服务端限制的证据。预算前后各半，再分给下载和上传；发请求前扣预算，失败不退还，HTTP 拒绝后停止、不自动重试。协议开销另计，不是计费流量硬上限。短于 3 秒的样本为 `budget-limited`，不能判断峰值。
- 复测固定前测 IP、请求大小和超时；Cloudflare 节点也需一致。条件不符拒绝比较。
- 每方向最多 128 条请求记录；离线报告读取兼容旧版较大的单次请求。收到非 200 响应时，测量记录的 `http_error` 保存状态码、方向、请求字节数和阶段预扣预算；网络中断不猜测状态码。菜单 `10` 同时显示具体测量错误。

仅在内核已提供时建议 BBR，不能凭名称判断代际；默认 FQ 不代表所有当前网卡队列都已切换。基础调优保留 `tcp_mem`、ECN、TFO、重试、TIME_WAIT、地址策略和初始缓冲，不改 limits/MSS、Xray 或 3x-ui 入站。ring/RPS 是独立高级功能。

## 命令与手动模式

| 命令 | 行为 |
|---|---|
| `netpilot doctor` | 只读检查资源、内核、实际队列与外部调优器。 |
| `netpilot status` | 只读查看状态。 |
| `netpilot report [--json] [--report-dir DIR]` | 显示最新已保存的汇总，`--json` 输出完整 JSON；无报告或选中的报告损坏、不完整时明确报错。 |
| `netpilot verify` | 核对两份 NetPilot sysctl 配置与运行值；无配置、不可读或偏离返回非零。 |
| `netpilot diagnose [--seconds 1..60]` | 累计计数或定时增量，不发测速流量；重传不是端到端丢包率。 |
| `netpilot plan` | 只读生成计划；显式提供目标时发送 ping。 |
| `netpilot apply` | 预览并确认后应用；`--yes` 跳过确认。 |
| `netpilot bench --peer HOST` | 独立 iperf3 测速，保存私有报告；默认询问确认，非交互须 `--yes`。 |
| `netpilot compare BEFORE.json AFTER.json` | 比较同条件 iperf3 报告，不接收自动 HTTP 报告。 |
| `netpilot menu` / `netpilot help` | 打开菜单 / 显示帮助。`COMMAND --help` 仅显示帮助。 |
| `netpilot install` | 显式保存程序并创建快捷命令。 |

**手动 `plan` / `apply`**：支持 `--profile`；`--bandwidth` 为正数 Mbps ≤1000000，配合 `--rtt`（正数 ms ≤60000）或 `--rtt-target HOST`，两者互斥。省略路径数据保留现有缓冲区，显式空值无效。目标测量发 5 次 ping，最多约 9 秒，至少 3 次应答才使用平均值，失败即停止；带宽仍是输入值。

**独立 `bench`**：`--peer` 必填；`--port` 默认 5201（1–65535），`--budget-mib` 默认 1024（1–1048576），`--streams` 默认 1（1–32），`--timeout` 默认每方向 30 秒（2–600）。`--direction` 默认 `both`，`send` 为 VPS→对端，`receive` 相反。`--latency` 可选 ping 采样；`--output FILE` 默认自动命名，不覆盖已有文件。

只有独立 iperf3 流程需要自行前测、调优核验、同条件复测，再运行 `compare`。输入需为不超过 1MiB 的普通 JSON 文件，对端、实际 IP/端口、方向、流数、预算、超时、延迟选项和数据量目标必须一致。失败、无效或缺少 `remote_endpoints` 的旧报告被拒绝；短样本不能判断峰值，取消/超时清理进程。

## 报告与状态

主菜单 `10` 和无参 `netpilot report` 读取服务器默认 `/tmp/netpilot-reports` 目录中最新保存的报告，显示文件更新时间和历史运行摘要；不代表当前实时状态，本轮前置失败时可能仍是旧记录。自定义目录须用 `--report-dir DIR`，无需手找单个报告路径。`netpilot report --json` 输出完整 `summary.json`，不带其他提示文字。

报告默认临时保存，可能被系统清理或在重启后消失；需要长期保留可指定自定义目录。旧版报告使用 `netpilot report --report-dir /var/log/netpilot` 查看。

报告字段和保存格式不变，下面说明的是完整 JSON。查看器核对流程状态、配置派生状态及内嵌测量/比较是否一致；矛盾或损坏时报错。私有报告需相应读取权限；没有报告时看执行命令和错误输出，结合目标机帮助确认功能版本。

| 标识 | 文件 / 用途 |
|---|---|
| `type: "netpilot-tune-report"`, `version: 1` | `summary.json`，整轮状态与比较。 |
| `type: "netpilot-http-measurement"`, `version: 1` | `before.json`、可获得的 `after.json`，阶段测量。 |
| `kind: "netpilot-benchmark"`, `schema_version: 1` | 独立 iperf3 报告，供 `compare` 使用。 |

| 汇总字段 | 含义 |
|---|---|
| `status`、`stage`、`exit_code`、`error` | 结果、停止阶段、退出码、原因；阶段为 `before/apply/verify/after/completed`。 |
| `changed`、`applied`、`verified` | 本轮修改、应用、核验标记。 |
| `verify_status` | `not-needed/verified/failed`。 |
| `rollback_status` | `not-needed/completed/failed`。 |
| `configuration_state` | `unchanged/applied/verified/restored/unknown`；恢复失败时为 `unknown`。 |
| `before`、`after`、`comparison` | 测量与比较，可能为 `null`；仅 `completed` 生成比较。 |

`unchanged` 仅表示本轮未改动，不表示从未调优；也可能同时 `verified: true`。`before_report/after_report` 是预定路径，不保证文件存在。

| `status` | 解释 |
|---|---|
| `completed` | 流程与有效比较完成，不等于提速。 |
| `failed` | 前测、应用或核验等失败，需结合阶段与配置状态。 |
| `partial` | 复测或比较失败；已核验配置保留，没有有效性能对比。 |
| `cancelled` | 收到取消信号，不能假定已恢复配置。 |

前测失败不改配置。开始写入后，应用失败或有改动的核验失败尝试恢复首次原值；取消时尝试恢复尚未核验的本轮写入，已核验配置保留。恢复失败保留备份，状态为 `unknown`。

自动流程退出码通常为：`0` 完成，`1` 失败/部分完成/汇总保存失败，`2` 参数或环境错误，`130` SIGINT，`143` SIGTERM/SIGHUP。前置失败可能无报告，以实际 shell 退出码为准。手动 `apply` 取消也可返回 `0`，不代表已应用。

`download_change_pct/upload_change_pct` 是观测速率变化；`latency_delta_ms` 为复测减前测，正值表示延迟增加；位于 `comparison` 中。`causal_claim: false`，`budget_limited` 表示短样本限制。参数一致、流程完成和性能提升是三件事；结果只代表被测路径与时段，不能替代真实业务体验。

## 备份与卸载

首次修改前保存原值和文件，重复应用保留首次基线。回滚恢复该基线，成功后清理恢复记录，下次修改重新建立基线；测速报告不参与恢复，也不会被回滚删除。

| 命令 / 菜单 | 行为 |
|---|---|
| `netpilot rollback` / `5` | 恢复首次原值；失败保留备份。 |
| `netpilot uninstall` / `7` → `1` 或回车 | 删除程序、自有快捷命令和默认自动报告，保留配置、恢复备份与下载/源码副本。 |
| `netpilot uninstall --rollback` / `7` → `2` | 先恢复，再清理默认自动报告并删除程序；无恢复记录或恢复失败则保留安装和报告。 |

卸载均需最终 `y/N` 确认，菜单 `0` 取消。仅卸载后可重新运行在线入口、选 `5` 回滚，无需再次调优。

报告清理限于默认目录和旧版 `/var/log/netpilot` 中带工具标记或可识别格式的运行目录；自定义路径、其他文件和符号链接目标不会被删除。混有其他文件的运行目录保留并提示。清理失败返回非零；回滚卸载的状态清理失败会尝试恢复程序和重试记录，补偿也失败时明确显示私有恢复副本路径。

带修改标记的 ring/RPS 缺少有效原值时恢复失败；清理失败也报错并保留状态。旧的损坏或缺失备份不能自动重建。回滚仅恢复 NetPilot 管理的变更，不是系统快照。

| 路径 | 用途 |
|---|---|
| `/usr/local/bin/netpilot.sh`、`/usr/local/bin/netpilot` | 程序、快捷命令。 |
| `/var/lib/netpilot/original-values`、`/var/lib/netpilot/backup/` | 首次原值、文件备份；其他恢复状态也在 `/var/lib/netpilot/`。 |
| `/tmp/netpilot-reports/run.*/` | 自动报告，与备份分开。 |
| `/etc/sysctl.d/99-netpilot.conf`、`/etc/sysctl.d/10-netpilot-bbr.conf` | 调优、BBR 配置。 |
| `/etc/modules-load.d/netpilot.conf` | BBR 模块加载。 |
| `/etc/gai.conf` | 仅显式 IPv4 优先时修改。 |
| `/run/netpilot.lock` | 写操作锁。 |

安装脚本和受管配置路径若为无关文件或符号链接，会停止并保护原文件；快捷命令若被其他文件占用也保留。不要通过删锁、删备份或强制覆盖来绕过错误。

## 依赖与排障

| 功能 | 依赖与权限 |
|---|---|
| 基础运行 | Linux、Bash 4+、`sysctl`、`awk`；在线入口需 `curl`。 |
| 写操作、安装、更新、卸载 | root、`flock`；安装/更新使用 `mktemp`、`install`。 |
| 自动调优 | 另需 Python 3、GNU `timeout`、`mktemp`、`install`，不需 iperf3 或 ping。 |
| 手动测延迟 | `ping`、GNU `timeout`。 |
| 查看报告 | Python 3、报告目录的读取权限；只读，不安装、不测速。 |
| 独立测速 / 比较 | 测速需 `iperf3`、Python 3、GNU `timeout`；比较仅需 Python 3；可选延迟需 `ping`。 |
| 出口 / 队列 / ring | `ip` / `tc` / `ethtool`；缺失或不支持时跳过相应部分，单核跳过 RPS。 |

依赖不自动安装。已安装后的菜单和只读命令不要求 root；私有报告仍受文件权限限制。受限容器或特殊内核可能只支持部分操作。

排障先看实际命令、退出码、错误及汇总状态：

| 现象 | 检查 |
|---|---|
| 要求手填带宽或报告名 | 是否进入手动或独立测速；一键入口为菜单 `9` / `tune`。 |
| 前测 DNS/TLS、429、超时 | `stage/error/before.ok`，区分端点限制与本机问题，不反复整轮测速。 |
| `partial` | 比较条件、复测错误、`verify`；配置可能仍然生效。 |
| `unknown` 或恢复失败 | 只读 `doctor/status/verify` 与恢复记录，保留备份。 |
| `verify` 无配置或偏离 | 无配置不等于故障；检查权限、受限内核、外部调优器。 |
| 文件归属、目录或锁冲突 | 查明现有操作与文件归属，避免并发和强行清理。 |

分享报告前脱敏 IP、域名和路径，保留一致的对端映射便于比较；不需要私钥、令牌或整份业务配置。报告内容按数据分析，未验证的原因标为猜测。
