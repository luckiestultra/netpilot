<p align="center"><a href="./README.md">简体中文</a> · <strong>English</strong></p>

<p align="center">
  <img src="./assets/readme/hero.en.svg" width="100%" alt="NetPilot: Linux VPS network diagnostics and TCP tuning with Chinese and English menus.">
</p>

NetPilot provides network diagnostics and TCP tuning for Linux VPS servers, with automatic measurements, backups and before/after comparisons.

[Get started](#get-started) · [One-click tuning](#one-click-tuning) · [View results](#view-results) · [Maintenance and recovery](#maintenance-and-recovery) · [Use with AI](#use-with-ai) · [Full reference](#full-reference)

## Get started

Run as root on your Linux server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckiestultra/netpilot/main/netpilot.sh) --lang en
```

The script saves itself and opens the English menu. **Choose `9` to tune and `10` to view results.** `L` switches languages; `0` exits.

Next time on the same server, run:

```bash
netpilot --lang en
```

## One-click tuning

Menu `9` or `netpilot --lang en tune` measures the path, compares algorithms, applies a plan and retests without manual bandwidth, latency or report names. When starting with CUBIC or BBR, it tests the other algorithm. It switches only when upload comparisons meet the decision rules; inconclusive results retain the algorithm present at the start of this run. Other algorithms are retained and reported as unevaluated.

The **whole-run payload cap is 16GiB**, including algorithm comparisons, failed requests and before/after tests. Usage follows the samples needed; protocol overhead is additional. NetPilot captures this run's starting state and checks for external changes before applying. Failures, cancellation, incomparable retests or confirmed regression after application trigger restoration of this run's changes. Menu `2` is a separate, explicit request to enable BBR and default FQ.

## View results

Choose main-menu `10`, or run:

```bash
netpilot --lang en report
```

The summary first shows the retained or selected algorithm and reason, whether this run changed settings, the final retained or restored state, and payload charged to the budget. Missing or invalid metrics are marked unavailable. It reads `/tmp/netpilot-reports` by default; system cleanup or a reboot may remove these temporary reports. If the latest attempt has no report yet, this may be an older record; check its update time. For a custom directory, use `netpilot --lang en report --report-dir DIR`.

| Status | Meaning |
|---|---|
| Completed | The workflow finished; the algorithm may be unchanged. This does not establish a speed gain. |
| Partial | Retest or comparison did not finish; check the reason and restoration state. |
| Failed | Check the stage and reason; restore failures retain backups. |
| Cancelled | Check configuration and rollback states to confirm restoration. |

Verification checks parameter consistency; measurements describe the server-to-test-endpoint path. Use `netpilot --lang en status` or `netpilot --lang en verify` to inspect the current configuration.

## Maintenance and recovery

| Task | Menu | Command |
|---|---|---|
| Update and open the menu | `6` | `netpilot --lang en update` |
| Restore the original baseline | `5` | `netpilot --lang en rollback` |
| Remove the tool and default reports | `7` → `1`, default | `netpilot --lang en uninstall` |
| Roll back, then uninstall | `7` → `2` | `netpilot --lang en uninstall --rollback` |

Rollback restores the **first saved values**. Default uninstall removes the tool and automatic reports in its default locations, keeping tuning settings and recovery backups. Custom report directories remain user-managed. Rollback-and-uninstall requires successful restoration; missing records or restore failures stop removal. Both uninstall modes require `y/N` confirmation.

## Use with AI

Send this [project reference (Chinese)](./docs/for-ai.md) link and your question to the AI:

```text
https://raw.githubusercontent.com/luckiestultra/netpilot/main/docs/for-ai.md
```

You can copy the results from menu `10`. For complete data, run:

```bash
netpilot --lang en report --json
```

Hide IP addresses, domains or other private details in a copy before sharing; keep errors and measurements. If no report exists, provide the command and error output.

## Full reference

### Menus and commands

| Main menu | Function |
|---|---|
| `9` | One-click tuning. |
| `10` | View the latest report. |
| `8` | Diagnostics and separate benchmarks. |
| `5` | Restore the original baseline. |
| `6` | Update NetPilot. |
| `7` | Uninstall; keep settings by default. |
| `1` | Prefer IPv4 by editing `/etc/gai.conf`. |
| `2` | Explicitly enable kernel-provided BBR and default FQ. |
| `3` | Manual tuning with a preview and confirmation. |
| `4` | NIC ring / RPS; skip RPS on a single CPU. |
| `L` / `0` | Switch session language / exit. |

Submenu under main-menu `8`:

| Choice | Command | Function |
|---|---|---|
| `1` | `netpilot --lang en doctor` | Inspect the environment. |
| `2` | `netpilot --lang en plan` | Preview recommendations. |
| `3` | `netpilot --lang en bench --peer HOST` | Run iperf3. |
| `4` | `netpilot --lang en compare BEFORE.json AFTER.json` | Compare iperf3 reports. |
| `5` | `netpilot --lang en verify` | Verify settings. |
| `6` | `netpilot --lang en diagnose --seconds 5` | Observe counter changes. |
| `0` | — | Return to the main menu. |

Without arguments, `diagnose` shows cumulative counters; `--seconds` accepts 1–60. Retransmission counts are not end-to-end loss rates. Submenu operations return to the main menu.

`netpilot menu` opens the menu; `netpilot help` or `netpilot COMMAND --help` shows help; `netpilot install` explicitly installs the script.

### Language settings

Chinese is the default; menu `L` switches the current session. Use `netpilot --lang en doctor` on the command line. `--lang zh|en` precedes the subcommand and overrides the `NETPILOT_LANG` environment variable.

### Automatic tuning options

`netpilot --lang en tune` accepts:

| Option | Default | Purpose |
|---|---|---|
| `--profile` | `balanced` | [Choose a workload](#parameter-recommendations). |
| `--budget-mib` | `auto` | Sample as needed, up to 16GiB for the whole run; an integer 1–1024 sets a fixed cap in MiB. |
| `--timeout` | `30` | Per-phase timeout; integer 5–120 seconds. Measurement phases total at most 9 times this value; local application, restoration and cleanup take additional time. |
| `--endpoint` | `https://speed.cloudflare.com` | HTTPS origin with compatible download/upload APIs; HTTP is limited to loopback addresses. |
| `--report-dir` | `/tmp/netpilot-reports` | Must not allow other users to write; cannot be inside `/var/lib/netpilot/`. |

Tests start with **64KiB**, then increase in batches up to **4 connections and 4MiB per request**. These are client policies. One ledger covers the baseline, algorithm comparisons, post-test and one regression confirmation. Each batch is charged before sending; failures, partial transfers and cancellation receive no refund. HTTP rejection stops new batches without switching sources and restarting. Comparisons leave two baseline-sized allowances for the normal post-test and a possible confirmation; settings cannot be applied after spending that allowance.

Algorithm comparisons fix the endpoint, IP, verifiable node, connection count, request batches and timeout, alternating algorithm order. Only uploads sent by the VPS count. Selection needs 3 valid pairs: candidate throughput is at least 110% of the original in every pair, both elapsed and actual TCP sender busy time reach 3 seconds for each sample, and the median paired upload TCP SRTT increase is no more than `max(1ms, 20% of the original median)`. Each test socket's algorithm is set and read back; comparisons leave the global default and persistent files unchanged. Missing data, unsupported options, short samples or insufficient budget retain the starting algorithm. These are conservative product rules, not proof of statistical significance.

Rates are total bytes divided by elapsed time, representing observed HTTP throughput. Buffer estimates require both baseline directions to reach 3 seconds; otherwise existing buffers remain. Path latency is the average of three TCP connection times; algorithm selection separately uses upload TCP SRTT. Downloads cannot establish a benefit from the local sender algorithm, and sample duration alone cannot establish peak bandwidth.

Retests reuse the baseline IP, node, parallelism, batch plan and timeout, without adding payload to reach a duration target. Faster retests lasting less than 3 seconds are marked short. A throughput loss above 10% in either direction triggers one same-condition confirmation within the reserved budget. Two losses in the same direction, or no available confirmation, restore this run's changes and report that benefit was not confirmed.

Baseline failure leaves settings unchanged. After writes begin, apply, verification or retest failures, cancellation and incomparable conditions attempt to restore the parameters and files present at this run's start, preserving the existing first-ever backup. External changes produce a conflict report and retained recovery materials; restoration failure is explicit. An unchanged run triggers no restoration. Reports retain before/after samples, algorithm decisions and the budget ledger; menu `10` shows the reasons again. Older reports remain readable.

### Parameter recommendations

| Profile | Workload |
|---|---|
| `balanced` | General use, default. |
| `proxy` | Proxies or many connections, with more conservative buffers. |
| `bulk` | A few large transfers, with a larger buffer budget. |

NetPilot estimates send and receive ceilings separately from path bandwidth, latency and effective memory. Only insufficient ceilings are raised; larger existing values and initial buffers are retained, without allocating the ceiling upfront.

**Optional manual mode:** menu `3`, or `plan` / `apply`. One-click tuning does not need the manual path inputs below.

| Option | Usage |
|---|---|
| `--profile` | A profile from the table above. |
| `--bandwidth` | Same-path Mbps; positive, ≤1000000. |
| `--rtt` | Same-path milliseconds; positive, ≤60000, supplied with bandwidth. |
| `--rtt-target HOST` | Measure latency with ping; requires bandwidth and excludes `--rtt`. |
| `--yes` | Skip confirmation for `apply`. |

Replace the example 500Mbps and 80ms with actual path data:

```bash
netpilot --lang en plan --profile proxy --bandwidth 500 --rtt 80
netpilot --lang en apply --profile proxy --bandwidth 500 --rtt 80
```

`plan` previews; `apply` asks for confirmation. Both retain the current congestion algorithm and do not load modules implicitly. Omitting path inputs retains existing buffers. In the menu, press Enter if bandwidth is unknown. After entering bandwidth, press Enter at the latency prompt and provide a target to measure it. Latency-probe failure stops the operation.

### Benchmarks and comparisons

Use the separate `bench` workflow when you have your own iperf3 server. It uses a different report format from automatic tuning.

| Option | Default and range |
|---|---|
| `--peer HOST` | Required: hostname, IPv4 or IPv6. |
| `--port` | 5201; 1–65535. |
| `--budget-mib` | 1024MiB; 1–1048576, covering all directions and streams. |
| `--direction` | `both`; `send` means VPS → peer, `receive` is the reverse. |
| `--streams` | 1; 1–32. |
| `--timeout` | 30 seconds; 2–600, per direction. |
| `--latency` | Optional idle/loaded ping latency sampling. |
| `--output FILE` | Automatic filename by default; no overwrite. |
| `--yes` | Skip confirmation; required for noninteractive runs. |

Replace `iperf.example.net` with your server. Apply the chosen tuning and verify between measurements:

```bash
netpilot --lang en bench --peer iperf.example.net --budget-mib 256 --output before.json
# After tuning and verification, repeat under the same conditions
netpilot --lang en bench --peer iperf.example.net --budget-mib 256 --output after.json
netpilot --lang en compare before.json after.json
```

`compare` accepts regular iperf3 JSON files up to 1MiB. Test conditions and actual peers must match; failed or older reports without `remote_endpoints` are rejected. Automatic tuning already compares its results and does not need this command.

Budgets exclude protocol overhead, retransmissions and optional ICMP. Short samples cannot establish peak bandwidth, and ICMP is not application latency. Failed runs are not retried; cancellation or timeout cleans up test processes.

### Configuration files and backups

Original values and files are saved before their first change; repeated runs preserve that baseline. Successful rollback clears recovery records, and the next change creates a new baseline. Measurement reports are stored separately.

Automatic tuning uses a separate snapshot to restore only this run's changes. Menu `5` / `rollback` always restores the first saved values. A new default algorithm mainly affects subsequent connections; NetPilot does not restart proxy services or existing business connections. Selecting BBR sets default FQ; the current interface queue is displayed separately.

| Path | Content |
|---|---|
| `/usr/local/bin/netpilot.sh`, `/usr/local/bin/netpilot` | Program and shortcut. |
| `/var/lib/netpilot/` | Original values, backups and recovery state. |
| `/tmp/netpilot-reports/` | Temporary automatic reports; cleaned on uninstall. |
| `/etc/sysctl.d/99-netpilot.conf`, `/etc/sysctl.d/10-netpilot-bbr.conf` | Tuning and BBR settings. |
| `/etc/modules-load.d/netpilot.conf` | BBR module loading. |
| `/etc/gai.conf` | IPv4 preference. |
| `/run/netpilot.lock` | Write-operation lock. |

Restore failures retain backups. After program-only removal, run the online command again and choose `5` to restore from retained records. Rollback covers changes managed by NetPilot.

View older reports with `netpilot --lang en report --report-dir /var/log/netpilot`. Uninstall also cleans recognized NetPilot reports there; run directories containing other files are kept with a warning.

### Requirements

| Function | Dependencies |
|---|---|
| Basic operation | Linux, Bash 4+, `sysctl`, `awk`; online startup needs `curl`. |
| Configuration changes and maintenance | root, `flock`; cleaning existing reports needs `python3`. |
| Automatic tuning | `python3`, GNU `timeout`. |
| Diagnostics / NIC settings | `ip`, `tc` / `ethtool`. |
| Manual latency probes | `ping`, GNU `timeout`. |
| View reports | `python3` and read permission. |
| Separate benchmarks / comparison | `iperf3` (measurement), `python3`, GNU `timeout` (measurement); latency sampling needs `ping`. |

Install dependencies for the selected function; missing ones are reported. Restricted containers or special kernels may support only some functions.

### Development and tests

Run as root in a disposable Linux container:

```bash
bash -n netpilot.sh
bash tests/run.sh
```

The suite needs `iperf3`, `python3`, `ping`, `timeout`, `ss` and `shellcheck`. Run `tests/*_cli_integration.sh` and `tests/linux_apply_integration.sh` separately; the latter needs writable network-namespace sysctls and appropriate permissions. Verify reboot persistence separately.

[Changelog](./CHANGELOG.md)
