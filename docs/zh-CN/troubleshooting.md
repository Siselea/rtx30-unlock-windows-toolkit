# 排查与恢复

本页对应免 U 盘安装方案（见 [`windows-internal-install.md`](windows-internal-install.md)）。
除特别说明外，所有命令都是只读诊断。

> **先跑这两条**
> ```powershell
> # 不需要提权（基准 + 分区 + 睡眠历史）
> powershell -ExecutionPolicy Bypass -File tools\windows\status.ps1
>
> # 提权：额外检查 UEFI 启动项/顺序，并可只读挂载隐藏分区
> powershell -ExecutionPolicy Bypass -File tools\windows\status.ps1 -Deep
> ```
> `status.ps1` 会直接给出结论和下一步。退出码：`0` 已解锁、`1` 未解锁、`2` 无法判断。

## 1. 30 秒判定：解锁现在生效吗

只有一个指标能回答：cuBLAS **FP16 输入 / FP32 累加** 的 4096³ GEMM 速率。
用 PowerShell 版基准（不需要 Python），或 Python 版：

```powershell
tools\bench\fp16_gemm_bench.ps1                  # 自动查找 CUDA / llama.cpp 的 DLL
tools\bench\fp16_gemm_bench.ps1 -DllDir U:\llama # 或指向包含 cudart64_*.dll + cublas64_*.dll 的目录
python tools\bench\fp16_gemm_bench.py U:\llama   # Python 版，同一条 cuBLAS 调用
```

| 读数 | 结论 | 下一步 |
|---|---|---|
| **≤ 28 TFLOPS** | 未解锁 | 第 2 节，判断属于哪种"没解锁" |
| **≥ 34 TFLOPS** | 已解锁 | 正常；建议记下数值留作基线 |
| 28 – 34 | 不确定 | 隔 30 秒再跑；仍在该区间按未解锁处理 |

参考机（RTX 3060 12GB / 170W）读数：未解锁 **21.37 / 22.93 / 24.00 / 24.06**；
已解锁 **37.96 / 40.79 / 41.67 / 44.33**。不要拿某一个历史数字当基准——未解锁
状态本身就会随温度和后台负载漂移约 10%。

**不能**用来判断解锁状态的三件事：

* `nvidia-smi`、GPU-Z、任务管理器——选择器（`SS0`/`SS1`）是 GPU 内部寄存器，
  驱动不报告；
* llama.cpp + Q4_K 权重——MMQ 走 FP16 累加，只涨约 6.7%；
* 游戏 / 3DMark——噪声太大。

## 2. 三种"没解锁"

生产构建失败时不会静默继续：它先打印失败原因，再调用 `Halt()` 停住。所以
"Windows 起来了但卡没解锁"基本只有 A、B 两种，而不是解锁器执行失败。

| 形态 | 开机表现 | 有新 `RUNnn` 吗 | 基准 | 处理 |
|---|---|---|---|---|
| **A 解锁器没跑** | 和平时一样快 | 没有 | ~21–24 | 查启动顺序（第 5 节）|
| **B 跑了但被复位** | 慢几秒 | 有 | ~21–24 | 睡眠/休眠或快速启动（第 3、4 节）|
| **C 跑了但被拒绝** | 停住/黑屏，进不了 Windows | 有，末行 `FINAL status=… stage=…` | 跑不了 | 救援（第 6 节）+ 读日志（第 8 节）|

"开机没有多花几秒"本身就是线索：解锁成功会多花几秒。

## 3. 睡眠 / 休眠唤醒后失效（参考机已复现）

**现象**：唤醒后一切正常——驱动正常、`nvidia-smi` 正常——但 FP16/FP32 GEMM
掉回 21–24 TFLOPS，没有任何报错或事件日志。

**原因**：解锁只存在于本次通电的 GPU 速率选择器里。S3 睡眠/S4 休眠会让 GPU
掉电或重新初始化，选择器回到 `SS0=0x03446101 / SS1=0x00000006`，
而 Windows 不会重跑解锁器，所以它**不会自己恢复**。

**参考机观测（2026-10-25）**：21:48 冷启动（解锁）→ 22:17 睡眠 → 22:18 唤醒 →
22:25 实测 **22.93 TFLOPS** → 22:56 复测 **21.37 TFLOPS**。期间安装、分区、
启动项都没有变化。

**恢复（从便宜到贵）**：

1. **重启**（不是关机）。Windows 重启一定会走固件，解锁器会重新运行；
   同一次通电内重启是安全的——源码里有"已应用则跳过并交棒"的逻辑。
2. 重启后仍低 → **完全断电再开机**（注意第 4 节的快速启动，开始菜单的"关机"
   可能只是休眠恢复）。
3. 仍低 → 按第 5 节检查启动顺序。

**预防**：跑长任务时把电源计划的睡眠设为"从不"
（`powercfg /change standby-timeout-ac 0`），并关闭快速启动。

## 4. 快速启动：你的"关机"可能不是冷启动

Windows 默认开启快速启动（`HiberbootEnabled=1`）。此时"关机"= 注销 + 休眠内核，
下次开机是从休眠恢复。解锁器仍会被固件调用，但恢复路径可能把选择器带回
未解锁状态，表现就是"关机再开还是 22 TFLOPS"。

```powershell
# 查看（不需要提权）
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled

# 关闭（提权）——也可以用辅助脚本
tools\windows\disable-fast-startup.ps1 -DryRun
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
```

`tools\windows\disable-fast-startup.ps1`（提权）做同样的修改，`-Enable` 可恢复
Windows 默认值。

不想改设置时，真正的冷启动是 **开始 → 电源 → 重启**，或 `shutdown /s /full /t 0`。

## 5. 启动顺序被重置（Windows 功能更新 / BIOS 更新 / Secure Boot）

会破坏自动启动的事件：Windows 功能更新（可能重排固件启动项）、BIOS/CMOS 重置、
换硬盘或换 NVMe 口（启动项丢失）、重新打开 Secure Boot（解锁器直接拒绝）。

**自检（提权）**：

```powershell
bcdedit /enum {fwbootmgr}                  # 第一项必须是我们那个 GUID
bcdedit /enum all | findstr /i "RTX30"     # 条目本身：device + path
Confirm-SecureBootUEFI                     # 必须是 False
```

**磁盘侧（不需要提权）**：

```powershell
Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
    Format-Table DiskNumber, PartitionNumber, Size, Offset
```

应该能看到一个 **536870912 字节（512MB）** 的分区；没有说明分区被删或硬盘换了。

**修复（从便宜到贵）**：

1. 开机按 **F8**（ASUS）选一次 `RTX30 UNLOCK`。能解锁就只是顺序问题。
2. 提权：`bcdedit /set {fwbootmgr} displayorder {GUID} /addfirst`
   （GUID 从上面第二条命令拿），或运行 `tools\windows\install-internal.ps1 -Repair`
   （提权；它会把启动项重新指向现有隐藏分区并排第一）。
3. 进固件设置（ASUS 开机按 Del）→ Boot → 把 `RTX30 UNLOCK` 移到第 1。
4. 启动项彻底没了才考虑重装。当前版 `install-internal.ps1` 会识别已有的
   `RTX30UNLOCK` 卷并就地更新，不会再建第二个分区；旧版本会。
5. Secure Boot 被打开了 → 在固件设置里关闭（`Other OS` 或 Disable），保存重启。

## 6. 开机停住 / 黑屏

解锁器在**真正写显卡之前**的每一步失败都会打印原因（单 DP 机器可能因为 GOP 已
释放而全黑）并调用 `Halt()` 永久停住，不会自动进 Windows。所以"卡住"表示
"它拒绝执行"，不是 Windows 坏了。

1. 长按电源键约 5 秒关机。
2. 下次开机 1–2 秒内连按 **F8**（ASUS），选 **Windows Boot Manager** 正常进系统。
3. 运行 `status.ps1 -Deep`，按第 8 节读最新的 `RUNnn` 日志，找 `stage=` 与
   `FINAL status=`。
4. 若日志出现 `STOP: cleanup cannot be proven. Resources remain reserved.`，
   **不要**试图继续进 Windows：断电、冷启动、F8 → Windows Boot Manager。

常见 `stage=`（来自源码与参考机日志）：

| `stage=` / 现象 | 含义 | 处理 |
|---|---|---|
| `secure-boot`（`0x800000000000001A`）| Secure Boot 开着 | 固件里关闭 |
| `target`、`config-recheck`、`bar0` | 找不到/认不出显卡（换卡、Above 4G 关闭、PCIe 异常）| 检查显卡与 BIOS 设置 |
| `cold-state`、`prom` | 显卡不是冷态，或 PROM 哈希不匹配（profile 来自别的机器）| 完全断电冷启动；在本机重新采集 `PROFILE.BIN` |
| `assets` | `RTX-UNLOCK\ASSETS\` 缺文件/被改 | 重新复制 5 个载荷 |
| `arming`（`EFI_TIMEOUT`）| 有 `DEBUG.ON` 但 30 秒内没按 `U` | 按 `U`，或删掉 `DEBUG.ON` |
| `display`、`armed-display` | 显示拓扑检查失败（多屏、核显、接口）| 只接一个输出，用主输出口 |
| `ownership`、`driver-release` | 固件驱动占用没释放 | 冷启动重试 |

## 7. "进了 Windows 但没解锁"清单

1. 刚才是睡眠唤醒吗？→ 第 3 节
2. 刚才的"关机"是不是快速启动？→ 第 4 节
3. `bcdedit /enum {fwbootmgr}` 第一项还是 `RTX30 UNLOCK` 吗？→ 第 5 节
4. Secure Boot 还是关的吗？→ 第 5 节
5. 512MB 的 ESP 分区还在吗？→ 第 5 节
6. `RUNnn` 有没有新目录？没有 = 解锁器没跑（形态 A）
7. 有新 `RUNnn` 但基准仍低 → 看该目录最后几行的 `FINAL status=` / `END:`（第 8 节）
8. 都正常、基准仍 ≤28 → 记录三次读数 + `RUNnn` 日志，按 issue 模板反馈

## 8. 日志：`RUNnn` 在哪、怎么看

只有启动时存在 `RTX-UNLOCK\DEBUG.ON` 才会写日志。删掉 `DEBUG.ON` 可以让开机
全自动，但**同时关闭日志**——排错期间把它放回去（开机需要按一次 `U`）。

分区没有盘符，`此电脑` 里看不到。用管理员 PowerShell 临时挂载：

```powershell
# 1) 找卷 GUID（不需要盘符）
Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -and $_.Size -eq 512MB } |
    ForEach-Object { $_.AccessPaths }

# 2) 挂成 X:
mountvol X: \\?\Volume{你的-GUID}\

# 3) 查看
Get-ChildItem X:\RTX-UNLOCK\RUN* | Sort-Object LastWriteTime -Descending | Select-Object -First 3
notepad X:\RTX-UNLOCK\RUN02\UNLOCK.TXT

# 4) 卸掉盘符（不影响启动）
mountvol X: /P
```

最新 `RUNnn` 目录的修改时间应该等于本次开机时间。`UNLOCK.TXT` / `GOP.TXT`
里的成功指纹：

```text
FULL_TOPOLOGY children=1 sibling=0
FULL_READY: 1 vendor children; six roles verified; one FLR after full isolation
selector write: SS0=0x88888888
selector write: SS1=0x8
PCIe FLR returned: result=0
PATCH_TRANSACTION result=0 ... FLR=1 safe=1
PATCH_STATE phase=after-output ... matched=1          （七个阶段全部 matched=1）
FULL_RESULT status=0 touched=1 ... restored=1
END: patch and display verified; Windows handoff follows if report close succeeds
WINDOWS_START_INTENT reboot=0
```

同一次通电内重启：

```text
SS0 already 88888888. Unlock skipped.
END: already applied; Windows handoff follows
```

失败指纹（最后一行）：

```text
FINAL status=0x800000000000001a stage=secure-boot attempted=0 driver_release=0 clean=1
CANCELLED_OR_REFUSED stage=full-prepare status=0x8000000000000003 touched=0
```

## 9. 升级、重装、换卡

**不要**为了"修一下"直接重跑**旧版**安装脚本：旧版没有"已安装"检测，每跑一次
就再缩 512MB、再建一个分区。

当前版 `install-internal.ps1` 是幂等的：找到 `RTX30UNLOCK` 卷 → 挂载 → 替换
`EFI` / `RTX-UNLOCK` 文件 → 核对包清单和启动项 → 重新隐藏。`RUNnn` 日志与
`PROFILE.BIN` 会保留。先用 `-DryRun` 预演，再提权正式运行。

只替换 EFI/构建（手工兜底）：

```powershell
# 提权
mountvol X: \\?\Volume{你的-GUID}\
Copy-Item <新包>\EFI\BOOT\BOOTX64.EFI X:\EFI\BOOT\BOOTX64.EFI -Force
Copy-Item <新包>\RTX-UNLOCK\ASSETS\* X:\RTX-UNLOCK\ASSETS\ -Force
mountvol X: /P
```

彻底重建分区：

1. 确认没有第二个 512MB ESP 型分区（`Get-Partition`）；
2. `tools\windows\remove-internal.ps1 -DeletePartition -ExtendSystem`（当前版：
   按卷标定位、删启动项与分区、把空间扩回 C:）；
3. 重新安装并验证。

**换显卡 / 换机器**：`PROFILE.BIN` 绑定显卡（PCI ID、subsystem、芯片）。在目标
机器上用 U 盘启动采集新的（保留 `DEBUG.ON`、按 `U`），替换隐藏分区里的旧文件。
不要把别人的 `PROFILE.BIN` 拿来用。

## 10. 卸载

```powershell
# 提权：只删启动项
tools\windows\remove-internal.ps1

# 删启动项 + 分区 + 把空间还给 C:
tools\windows\remove-internal.ps1 -DeletePartition -ExtendSystem
```

BCD 备份写在安装器 `-BackupDir` 下（默认 `%ProgramData%\rtx30-unlock`，
文件名 `bcd-backup-*.bcd`）。只有启动配置真坏了才在提权 shell 里
`bcdedit /import <文件>` 恢复。

Windows Boot Manager 本身从未被修改；在固件启动菜单里选它（F8）永远是安全的
一次性回退。

## 11. 错误码

| 错误码 | 名称 | 常见原因 |
|---|---|---|
| `0x800000000000001A` | `EFI_SECURITY_VIOLATION` | Secure Boot 开着 |
| `0x8000000000000003` | `EFI_UNSUPPORTED` | 拓扑/资产/显示检查拒绝 |
| `0x800000000000000E` | `EFI_TIMEOUT` | 有 `DEBUG.ON`，超时没按 `U` |
| `0x800000000000000F` | `EFI_NOT_FOUND` | 找不到 profile、资产或显示子设备 |
| `EFI_ABORTED` | 中止 | 采集提示时按了 Esc |

## 12. 什么时候必须停手

* 不要格式化、加密或移动隐藏分区。
* 不要自己改 `src/gop/full.c` 绕过拓扑检查。
* 不要刷 VBIOS。
* 出现 `STOP: cleanup cannot be proven` 时不要继续。
* BitLocker 开着且没有恢复密钥时不要安装。

否则请附 `status.ps1 -Json` 输出、最新 `RUNnn` 日志（`UNLOCK.TXT`、`GOP.TXT`）
和三次基准读数开 issue。
