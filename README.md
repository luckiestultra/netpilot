# VPS TCP Tune

这是自有的 VPS TCP/网卡调优脚本，按原调优脚本的功能范围重新实现，并增加了逐项备份和回退。

## 功能

- IPv4 优先解析
- BBR + fq
- TCP/UDP 缓冲区、队列、ECN、MTU 探测、Fast Open 等参数
- limits 文件句柄和进程限制
- POSTROUTING MSS 自适应
- ethtool ring、RPS 和 socket flow 参数
- 菜单操作、状态查看、完整回退、卸载本脚本

## 使用

```bash
bash vps-tcp-full-tune.sh
```

菜单中选择 `3` 可一次性应用完整调优，选择 `5` 可回退本脚本的全部修改。

脚本安装后可直接输入 `tcp` 打开调优菜单。

脚本会把原值保存在 `/var/lib/vps-tcp-full-tune/`，不会删除 3x-ui 或 Xray。

选项 `4` 在系统缺少 `ethtool` 时会使用系统包管理器安装它；这是原调优功能的依赖。
