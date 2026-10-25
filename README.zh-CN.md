# rtx30-unlock Windows 工具包（中文版）

这是 [craftingmod/rtx30-unlock](https://github.com/craftingmod/rtx30-unlock)
（Windows/UEFI 移植版，源自 [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)
的 Linux 原版）的**周边工具包**，补齐单显卡单显示器机器需要的东西：

| | |
|---|---|
| **单显示器支持** | 给 v20 "quiet profile" GOP 实验打补丁：接受只有 1 个显示输出，不再需要第二台显示器/显卡欺骗器/第二根线 |
| **免 U 盘安装** | 在内置 GPT 磁盘上建隐藏 ESP 型 FAT32 分区并排到 UEFI 启动第一，每次冷启动自动解锁——不插 U 盘、不按键 |
| **验证** | `tools/windows/status.ps1` 一条命令判断"现在到底解锁了没有"；cuBLAS FP16→FP32 累加 GEMM 基准（解锁真正影响的指标）|
| **恢复手段** | 幂等安装器、修复与卸载脚本、完整的[排查与恢复指南](docs/zh-CN/troubleshooting.md) |
| **构建方案** | 没有 Visual Studio / Windows SDK 时如何构建（便携 clang/lld-link）|
| **实测报告** | GA104 版 RTX 3060 12GB 的真实测量数据 |

> **本仓库不包含上游源码，也不包含 NVIDIA 固件。** 两个上游项目只作为引用源，
> 由脚本按固定 commit 拉取、打补丁；仓库里只有我们自己写的脚本、工具、文档和实测。
> 见 [`SOURCES.md`](SOURCES.md) 与 [`NOTICE.md`](NOTICE.md)。

## 实测结果（参考机器）

GA104 版 **RTX 3060 12GB**（`10de:2487`，subsystem `7377:2000`，VBIOS
`94.04.71.40.0F`），Windows 11 26300，驱动 616.56，单 DP 显示器、无核显、
Secure Boot 关闭：

| cuBLAS GEMM 4096³ | 未解锁（冷启动）| 解锁后 | 提升 |
|---|---:|---:|---:|
| FP16 输入 / **FP32 累加**（被限速通路）| 21.4 – 24.1 TFLOPS | **37.96 – 44.33 TFLOPS** | **+58 … +85 %** |

"未解锁"不是固定值：会随温度和后台负载漂移（参考机上观测到 21.37 / 22.93 /
24.00 / 24.06）。请用下面的阈值判断，不要拿某一个历史数字当基准。完整证据：
[`docs/zh-CN/test-report.md`](docs/zh-CN/test-report.md)。

> llama.cpp 的数字**不适合**判断解锁：Q4_K 量化走 FP16 累加 MMQ kernel，
> 本来就不受限制（实测 pp512 只涨 6.7%）。

## 解锁现在生效吗？

```powershell
# 一条命令，不需要 Python；大部分检查不需要提权
powershell -ExecutionPolicy Bypass -File tools\windows\status.ps1

# 提权：额外检查启动项/启动顺序，并可只读检查隐藏分区里的 EFI 与 RUNnn 日志
powershell -ExecutionPolicy Bypass -File tools\windows\status.ps1 -Deep
```

`status.ps1` 会检查 Secure Boot、隐藏分区、`{fwbootmgr}` 顺序、本次启动后的
睡眠/唤醒历史，并跑一次基准。退出码：`0` 已解锁、`1` 未解锁、`2` 无法判断。
也可以只跑基准：

```powershell
tools\bench\fp16_gemm_bench.ps1                  # 自动查找 cudart64_*.dll / cublas64_*.dll
tools\bench\fp16_gemm_bench.ps1 -DllDir U:\llama # 或指向任意包含这两个 DLL 的目录
python tools\bench\fp16_gemm_bench.py U:\llama   # Python 版（同一条 cuBLAS 调用）
```

| 读数 | 结论 |
|---|---|
| **≤ 28 TFLOPS** | 未解锁 |
| **≥ 34 TFLOPS** | 已解锁 |
| 28 – 34 | 不确定——隔 30 秒再跑；仍在该区间就按未解锁处理 |

**不能**用来判断解锁状态的：`nvidia-smi` / GPU-Z / 任务管理器（选择器是 GPU
内部寄存器）、量化权重下的 llama.cpp（只差 ~6.7%）、游戏/3DMark（噪声太大）。

> **已知行为：** 睡眠或休眠会复位速率选择器，唤醒后回到未解锁状态，直到下一次
> 冷启动。参考机已复现：22:17 睡眠 → 22:18 唤醒 → 22:25 只剩 22.93 TFLOPS。
> 处理见[排查与恢复](docs/zh-CN/troubleshooting.md) §3–4。

## 前提条件

* UEFI 启动、**Secure Boot 关闭**
* NVIDIA RTX 30 系 GA10x 显卡（上游支持 GA102/103/104/106/107）
* Windows；安装步骤需要管理员权限
* 构建工具：`git`、[Bun](https://bun.sh)、`clang` + `lld-link`
  （没有 VS 的方案见 [`docs/build.md`](docs/build.md)）
* 在**你自己机器上**采集的 `PROFILE.BIN`（见上游 `docs/agent/EXTERNAL-PROFILE.md`；
  首次运行时 EFI 也可以自动采集）

## 拿到别人构建好的包时

`PROFILE.BIN` 与本机显卡/主板绑定，`ASSETS/` 里是 NVIDIA 固件（不适合外传）。
所以别人的包只能在你机器上重新采集 profile 后使用：

1. 确认包里有 `EFI\BOOT\BOOTX64.EFI` + `RTX-UNLOCK\ASSETS\`，并用 `SHA256SUMS.txt`
   核对（`Get-FileHash` EFI 文件）。
2. 在本机用 U 盘（或备用 ESP）启动一次这个包；有 `DEBUG.ON` 时会要求按一次 `U`，
   并写出本机的 `PROFILE.BIN`。
3. 把采集到的 `RTX-UNLOCK\PROFILE.BIN` 放进包里。
4. 提权：先 `tools\windows\install-internal.ps1 -PackageDir <包目录> -DryRun` 预演，
   再去掉 `-DryRun` 正式安装。
5. 重启。先跑解锁器，再进 Windows。
6. 提权运行 `tools\windows\status.ps1`，应显示 `UNLOCKED`。
7. 可选：删掉隐藏分区里的 `DEBUG.ON` 让开机全静默（代价是不再写 `RUNnn` 日志，
   排错期间建议保留）。

## 从源码构建并安装

```powershell
# 0) 准备 git / bun / clang+lld-link（PATH 或 LLVM_BIN）
# 1) 按固定 commit 拉取上游、打补丁、构建、生成固件资产、组装包与 SHA256SUMS
.\scripts\build-from-upstream.ps1

# 2) 在本机采集 PROFILE.BIN（U 盘启动；见 docs/build.md 与
#    docs/windows-internal-install.md），放进 build-workspace\package\RTX-UNLOCK\

# 3) 预演后安装（提权）。重复运行会就地更新已有安装，不会再建第二个分区。
.\tools\windows\install-internal.ps1 -PackageDir .\build-workspace\package -DryRun
.\tools\windows\install-internal.ps1 -PackageDir .\build-workspace\package

# 4) 重启后验证
.\tools\windows\status.ps1
```

## 回退与修复

```powershell
# 删除 RTX30 UNLOCK 启动项（自动定位）；Windows Boot Manager 不动
.\tools\windows\remove-internal.ps1

# 连同隐藏分区一起删除，并把空间扩回 C:
.\tools\windows\remove-internal.ps1 -DeletePartition -ExtendSystem

# 只修启动项/顺序，不动文件
.\tools\windows\install-internal.ps1 -Repair
```

任何时候都可以在固件启动菜单里选 **Windows Boot Manager**（ASUS 板开机按
**F8**）临时正常启动一次。启动顺序被重置、黑屏、读日志、错误码等深入步骤见
[`docs/zh-CN/troubleshooting.md`](docs/zh-CN/troubleshooting.md)。

## 仓库结构

```
patches/    对上游的补丁（git format-patch，按固定 commit 应用）
scripts/    build-from-upstream.ps1 —— 拉取 + 打补丁 + 构建 + 组装包 + SHA256SUMS
tools/
  windows/  status.ps1（只读自检）、install-internal.ps1（幂等安装）、
            remove-internal.ps1、rtx30-common.ps1（公共函数）
  bench/    fp16_gemm_bench.ps1 / .py（cuBLAS FP16/FP32 累加验证基准）
  win32/    没有 Windows SDK 时构建用的声明级 libc 头
docs/
  single-display.md            补丁：原因、改法、证据
  windows-internal-install.md  免 U 盘安装细节
  troubleshooting.md           排查、恢复、日志、错误码
  build.md                     没有 Visual Studio 时如何构建
  test-report.md               参考机器实测数据
  zh-CN/                       对应中文版（含中文索引）
SOURCES.md                     固定上游仓库/commit、拉取方式
NOTICE.md                      归属、许可证与再分发规则
LICENSE                        GPL-2.0-only（补丁与本工具包）
```

## 解锁原理（简版）

EFI 程序在 Windows 之前运行，通过 SEC2 引导器加载 GPU 固件，用 V67 ROP 载荷在
重安全态把 `FEAT_OVR_PLM (0x00823804)` 写成 `0xFFFFFFFF`；然后主机写入速率选择器
`SS0 (0x0082381c)=0x88888888`、`SS1 (0x00823820)=0x8`，做一次 PCIe FLR，
**不重启**直接交棒 `bootmgfw.efi`。Windows 随后以满速 FP16/BF16（FP32 累加）
Tensor Core 运行。

显卡上不持久化任何东西：断电复位，所以每次冷启动都要重新解锁——本工具包的
内置安装就是为了让这件事自动完成。

## 安全

* **不写 VBIOS / 固件文件**，所有补丁仅存在于本次通电的 RAM。
* **安装确实会改机器**：缩 C:、新建并格式化 512MB ESP 型分区、写 BCD/NVRAM
  （UEFI 启动项与顺序）、设置 GPT no-automount。运行前请准备 **BitLocker 恢复密钥**。
* 隐藏分区没有盘符、`此电脑` 里看不到；不要格式化/加密/移动/清理它，删掉就无法自动解锁。
* 预检不通过就拒绝、绝不写显卡；清理不确定会停在 `STOP ... POWER OFF`（长按电源键），
  此时**不要**试图继续进 Windows。
* 睡眠/休眠可能复位选择器，重启恢复（已复现，见排查文档 §3）；Secure Boot 必须保持关闭。
* Windows 大版本/BIOS 更新可能重置 UEFI 启动顺序，必要时把 `RTX30 UNLOCK` 放回第一
  （`status.ps1` 会提示）。
* 第三方实验性工具，风险自负。

## 许可证与再分发

**GPL-2.0-only**，与上游一致。补丁的衍生关系与各上游项目许可证见
[`NOTICE.md`](NOTICE.md)。再分发构建出的 `BOOTX64.EFI` 时，GPL 要求同时提供对应
源码（本仓库 + 固定上游 commit）；**不要**外传 `RTX-UNLOCK\ASSETS\`（NVIDIA 固件，
另附许可证）、`PROFILE.BIN` 或 `RUNnn` 日志。

英文版：[`README.md`](README.md) ·
排查与恢复：[`docs/zh-CN/troubleshooting.md`](docs/zh-CN/troubleshooting.md)
