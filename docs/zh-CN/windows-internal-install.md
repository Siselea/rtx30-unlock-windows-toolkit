# 内置安装：每次冷启动自动解锁（免 U 盘、免按键）

上游的用法是每次冷启动从 U 盘运行 EFI 程序。本工具包提供一种全自动替代方案：

* 在内置 GPT 磁盘上创建一个小的隐藏 FAT32 分区，类型为 **EFI System Partition**；
* 把 EFI 程序、固件资产和在本机验证过的 `PROFILE.BIN` 复制进去；
* 新建一个指向 `\EFI\BOOT\BOOTX64.EFI` 的 UEFI 启动项，并排到固件启动顺序**第一位**。

这样每次冷启动时，固件先运行解锁器，解锁后再加载 Windows ESP 上的
`\EFI\Microsoft\Boot\bootmgfw.efi`——不重启、不按键、不需要 U 盘。原来的
*Windows Boot Manager* 启动项不会被修改。

> 安装后的诊断（未解锁、黑屏、启动顺序被重置、读日志、错误码）见
> [`troubleshooting.md`](troubleshooting.md)。

## 前提条件

* UEFI 启动，**Secure Boot 关闭**（否则解锁器拒绝运行并返回
  `EFI_SECURITY_VIOLATION`，`0x800000000000001A`）。
* 一次性安装需要管理员权限。
* 构建出的 `BOOTX64.EFI` 以及 `bun run firmware:assets` 生成的
  `RTX-UNLOCK\ASSETS\`（资产**不在**本仓库里：它们是 NVIDIA 固件/生成载荷，
  见上游 `tools/firmware/README.md`）。
* 在**这台机器上**采集的 `RTX-UNLOCK\PROFILE.BIN`（见上游
  `docs/agent/EXTERNAL-PROFILE.md`）。没有它时 EFI 会在首次启动自行采集；
  有 `DEBUG.ON` 时仍会要求按 `U`，没有则静默继续。

### 安装前必查三件事

1. **BitLocker：** 安装器会缩 `C:` 并修改启动顺序。先导出恢复密钥
   （`manage-bde -status`、`manage-bde -protectors -get C:`），或临时挂起保护。
2. **可收缩空间：** `C:` 末尾至少有 `-SizeMB`（默认 512 MB）可收缩空间；
   不够时安装器会干净地失败。
3. **提权 + Secure Boot：** 用管理员 PowerShell 运行，并在此期间保持 Secure Boot 关闭。

## 快速开始

准备安装包目录（构建脚本会生成这个结构）：

```
package\
  EFI\BOOT\BOOTX64.EFI
  RTX-UNLOCK\
    ASSETS\              （5 个固件载荷 + NVIDIA-LICENSE）
    PROFILE.BIN          （在本机采集的）
    DEBUG.ON             （可选，仅首次启动用——见"启动流程"）
  SHA256SUMS.txt         （由 build-from-upstream.ps1 生成）
```

然后运行：

```powershell
# 管理员 PowerShell

# 0) 预演：显示是否已有安装、会缩多少空间，并校验包清单。
#    不修改任何东西，不需要提权也能跑。
.\tools\windows\install-internal.ps1 -PackageDir C:\path\to\package -DryRun

# 1) 安装（已有安装则就地更新）
.\tools\windows\install-internal.ps1 -PackageDir C:\path\to\package
```

脚本会：

1. 校验安装包（`SHA256SUMS.txt`、EFI 哈希、资产），并把当前 BCD 导出到
   `%ProgramData%\rtx30-unlock\bcd-backup-<时间戳>.bcd`；
2. **没有安装时：** 把 `C:` 缩小 `-SizeMB`（默认 512）并创建 ESP 型 FAT32 分区；
   **已存在 `RTX30UNLOCK` 卷时：** 直接挂载并就地更新文件（不建第二个分区，
   `RUNnn` 日志和 `PROFILE.BIN` 保留）；
3. 复制安装包、校验复制结果、创建或复用 `RTX30 UNLOCK` 启动项并排到第一；
4. 移除盘符并设置 GPT no-automount，使其像 Windows ESP 一样隐藏。

常用参数：`-SizeMB`、`-Label`、`-SkipHide`（保留盘符，调试用）、
`-Repair`（只修启动项/顺序，不动文件）、`-Force`、`-ExpectedEfiSha256`、
`-BackupDir`、`-LogPath`。失败时会回滚本次创建的分区、启动项，并打印 BCD 备份路径。

## 验证安装

```powershell
# 提权：启动项、顺序、分区、EFI 哈希、最新 RUN 日志、基准
.\tools\windows\status.ps1 -Deep
```

预期：`RESULT: UNLOCKED`，退出码 0。不提权时 `status.ps1` 仍会检查分区、
睡眠历史并跑基准，只是跳过启动项部分。

三条独立验证：

1. `status.ps1` 显示 `UNLOCKED`（或 GEMM 基准 ≥ 34 TFLOPS）；
2. `bcdedit /enum {fwbootmgr}` 里 `RTX30 UNLOCK` 的 GUID 排第一；
3. 512 MB 的 ESP 型分区仍然存在（`Get-Partition`）。

## 启动流程 / 行为

* **冷启动成功：** 固件 → 解锁器（多花几秒）→ Windows，已解锁。
* **同一次通电内重启：** 解锁器打印 `SS0 already 88888888. Unlock skipped.`
  后交棒，安全。
* **有 `DEBUG.ON`：** 会要求按一次 `U`（30 秒超时），写 `RUNnn` 日志并采集数据；
  删掉它开机就全静默，**但也不再写 `RUNnn` 日志**——排错期间保留，日常可删。
* **写显卡之前失败：** 打印原因并调用 `Halt()` 停住（单 DP 机器可能因 GOP 已释放
  而全黑），不会自动进 Windows。请断电，用 F8 进 Windows Boot Manager，再读日志
  （见 [`troubleshooting.md`](troubleshooting.md) §6–8）。
* 断电会复位解锁选择器，所以**每次冷启动**都要重新解锁——这是设计如此，卡上不
  持久化任何东西。
* **睡眠/休眠会复位选择器**（即使安装本身没问题）：唤醒后回到未解锁状态，直到
  下次冷启动。参考机已复现，见 [`troubleshooting.md`](troubleshooting.md) §3。
* Windows 功能更新或 BIOS 更新可能重排 UEFI 启动项。解锁器不再运行时
  `status.ps1` 会报告；用 `install-internal.ps1 -Repair` 或
  `bcdedit /set {fwbootmgr} displayorder {GUID} /addfirst` 放回第一。

## 更新、修复、卸载

```powershell
# 就地更新文件（幂等，不新建分区）
.\tools\windows\install-internal.ps1 -PackageDir C:\path\to\package

# 只修启动项/顺序
.\tools\windows\install-internal.ps1 -Repair

# 只删启动项（自动定位）
.\tools\windows\remove-internal.ps1

# 删启动项 + 删分区 + 把空间扩回 C:
.\tools\windows\remove-internal.ps1 -DeletePartition -ExtendSystem
```

任何时候都可以在固件启动菜单里选 **Windows Boot Manager**（ASUS 板开机按 F8）
临时正常启动一次。如果 Windows 正常但显卡没解锁，见
[`troubleshooting.md`](troubleshooting.md)。更换显卡后必须在**本机**重新采集
`PROFILE.BIN`。

## 关于这个分区

| | |
|---|---|
| 大小 | 默认 512 MB（`-SizeMB`）|
| 文件系统 | FAT32 |
| GPT 类型 | `c12a7328-f81f-11d2-ba4b-00a0c93ec93b`（EFI System Partition）|
| 盘符 | 安装后移除 |
| GPT 属性 | `0x8000000000000000`（no automount）|
| 启动项 | `RTX30 UNLOCK`，device = 该分区，path = `\EFI\BOOT\BOOTX64.EFI` |

分区在资源管理器里看不到（无盘符），但在"磁盘管理"里是一个 512 MB 的
"EFI 系统分区"。需要检查内容时，用管理员 shell 临时挂载、用完卸载：

```powershell
mountvol X: \\?\Volume{你的-GUID}\
dir X:\RTX-UNLOCK\RUN*
mountvol X: /P
```

解锁器接受 USB 设备**或** GPT ESP 卷（`GU_SSD_EXPERIMENT` 构建开关），
所以该分区使用 ESP 类型 GUID。
