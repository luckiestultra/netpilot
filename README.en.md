<p align="center"><a href="./README.md">简体中文</a> · <strong>English</strong></p>

<p align="center">
  <img src="./assets/readme/hero.en.svg" width="100%" alt="NetPilot: Linux VPS network diagnostics and TCP tuning with Chinese and English menus.">
</p>

NetPilot provides network diagnostics and TCP tuning for Linux VPS servers, with automatic measurements, backups and before/after comparisons.

[Get started](#get-started) · [View results](#view-results) · [Maintenance and recovery](#maintenance-and-recovery) · [Use with AI](#use-with-ai) · [Full reference](#full-reference)

## Get started

Run as root on your Linux server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/luckiestultra/netpilot/main/netpilot.sh) --lang en
```

The script saves itself and opens the English menu. **Choose `9` to tune and `10` to view results.** `L` switches languages; `0` exits.

Tuning measures, backs up, applies, verifies and retests automatically. No manual bandwidth, latency or report names are needed. The default whole-run payload budget is **128MiB**; protocol overhead is additional.

Next time on the same server, run:

```bash
netpilot --lang en
```

## View results

Choose main-menu `10`, or run:

```bash
netpilot --lang en report
```

The summary shows configuration state, measurements and the report's update time. It reads `/tmp/netpilot-reports` by default; system cleanup or a reboot may remove these temporary reports. If the latest attempt has no report yet, this may be an older record. For a custom directory, use `netpilot --lang en report --report-dir DIR`.

| Status | Meaning |
|---|---|
| Completed | The workflow and comparison finished. |
| Partial | Retest or comparison did not finish; verified settings remain. |
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
| `2` | Enable kernel-provided BBR and default FQ. |
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
| `--budget-mib` | `128` | Whole-run payload; integer 1–1024MiB. |
| `--timeout` | `30` | Per-phase timeout; integer 5–120 seconds. |
| `--endpoint` | `https://speed.cloudflare.com` | HTTPS origin with compatible download/upload APIs; HTTP is limited to loopback addresses. |
| `--report-dir` | `/tmp/netpilot-reports` | Private report directory; cannot be inside `/var/lib/netpilot/`. |

Latency is the average of three TCP connection times. Each phase gets half the budget, split between download and upload. Failed requests consume budget, with no automatic retry. Samples shorter than 3 seconds are marked budget-limited and cannot establish peak bandwidth.

Retests reuse the baseline IP, request sizes and timeout; Cloudflare nodes must also match. Reports are saved automatically as `before.json`, `after.json` when available, and `summary.json`.

Baseline failure leaves settings unchanged. Apply or verification failures after this run starts writing attempt to restore the original baseline; retest failures retain verified settings. On cancellation, check configuration and rollback states in the report.

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

`plan` previews; `apply` asks for confirmation. Omitting path inputs retains existing buffers. In the menu, press Enter if bandwidth is unknown. After entering bandwidth, press Enter at the latency prompt and provide a target to measure it. Latency-probe failure stops the operation.

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

View older reports with `netpilot --lang en report --report-dir /var/log/netpilot`. Uninstall also cleans recognized NetPilot reports there, preserving unrelated files.

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
