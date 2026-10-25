# rtx30-unlock Windows 工具包（中文版）

这是 [craftingmod/rtx30-unlock](https://github.com/craftingmod/rtx30-unlock)
（Windows/UEFI 移植版，源自 [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)
的 Linux 原版）的**周边工具包**，补齐单显卡单显示器机器需要的东西：

| | |
|---|---|
| **单显示器支持** | 给 v20 "quiet profile" GOP 实验打补丁：接受只有 1 个显示输出，不再需要第二台显示器/显卡欺骗器/第二根线 |
| **免 U 盘安装** | 在内置 GPT 磁盘上建隐藏 ESP 型 FAT32 分区并排到 UEFI 启动第一，每次冷启动自动解锁——不插 U 盘、不按键 |
| **验证工具** | cuBLAS FP16→FP32 累加 GEMM 基准（解锁真正影响的指标） |
| **构建方案** | 没有 Visual Studio / Windows SDK 时如何构建（便携 clang/lld-link） |
| **实测报告** | GA104 版 RTX 3060 12GB 的真实测量数据 |

> **本仓库不包含上游源码，也不包含 NVIDIA 固件。** 两个上游项目只作为引用源，
> 由脚本按固定 commit 拉取、打补丁；仓库里只有我们自己写的脚本、工具、文档和实测。
> 见 [`SOURCES.md`](SOURCES.md) 与 [`NOTICE.md`](NOTICE.md)。

## 实测结果（参考机器）

GA104 版 **RTX 3060 12GB**（`10de:2487`，subsystem `7377:2000`，VBIOS
`94.04.71.40.0F`），Windows 11 26300，驱动 616.56，单 DP 显示器、无核显、
Secure Boot 关闭：

| cuBLAS GEMM 4096³ | 未解锁（冷启动） | 解锁后 | 提升 |
|---|---:|---:|---:|
| FP16 输入 / **FP32 累加**（被限速通路） | 24.00 TFLOPS | **37.96 – 44.33 TFLOPS** | **+58 … +85 %** |
| TF32 | 24.06 TFLOPS | 33.70 – 45.72 TFLOPS | +40 … +90 % |

完整证据：[`docs/zh-CN/test-report.md`](docs/zh-CN/test-report.md)。

> llama.cpp 的数字**不适合**判断解锁：Q4_K 量化走 FP16 累加 MMQ kernel，
> 本来就不受限制（实测 pp512 只涨 6.7%）。

## 前提条件

* UEFI 启动、**Secure Boot 关闭**
* NVIDIA RTX 30 系 GA10x 显卡（上游支持 GA102/103/104/106/107）
* Windows；安装步骤需要管理员权限
* 构建工具：`git`、[Bun](https://bun.sh)、`clang` + `lld-link`
  （没有 VS 的方案见 [`docs/build.md`](docs/build.md)）
* 在**你自己机器上**采集的 `PROFILE.BIN`（见上游 `docs/agent/EXTERNAL-PROFILE.md`；
  首次运行时 EFI 也可以自动采集）

## 快速开始

```powershell
# 0) 准备 git / bun / clang+lld-link（PATH 或 LLVM_BIN）
# 1) 按固定 commit 拉取上游、打补丁、构建、生成固件资产
.\scripts\build-from-upstream.ps1

# 2) 先用 U 盘（或备用 ESP）启动一次构建出的包，在本机采集 PROFILE.BIN
#    （上游文档说明 DEBUG.ON / U 键流程），然后把 PROFILE.BIN 放进
#    build-workspace\package\RTX-UNLOCK\

# 3) 安装到内置磁盘（管理员 PowerShell）
.\tools\windows\install-internal.ps1 -PackageDir .\build-workspace\package

# 4) 完全关机 → 开机：先跑解锁器，再进 Windows
```

回退：

```powershell
.\tools\windows\remove-internal.ps1 -EntryGuid '{...}'              # 只删启动项
.\tools\windows\remove-internal.ps1 -EntryGuid '{...}' -DeletePartition
```

也可以开机按 **F8** 选 **Windows Boot Manager** 临时正常启动。

## 仓库结构

```
patches/    对上游的补丁（git format-patch，按固定 commit 应用）
scripts/    build-from-upstream.ps1 —— 拉取 + 打补丁 + 构建 + 组装安装包
tools/
  windows/  install-internal.ps1 / remove-internal.ps1（隐藏内部 ESP + 启动项）
  bench/    fp16_gemm_bench.py（cuBLAS FP16/FP32 累加验证基准）
  win32/    没有 Windows SDK 时构建用的声明级 libc 头
docs/
  single-display.md            补丁：原因、改法、证据
  windows-internal-install.md  免 U 盘安装细节
  build.md                     没有 Visual Studio 时如何构建
  test-report.md               参考机器实测数据
  zh-CN/                       对应中文版
SOURCES.md                     固定上游仓库/commit、拉取方式
NOTICE.md                      归属与许可证
LICENSE                        GPL-2.0（补丁与本工具包）
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

* 不写 VBIOS / 固件文件，所有补丁仅存在于本次通电的 RAM。
* 预检不通过就拒绝、绝不写显卡；清理不确定会停在 `STOP ... POWER OFF`（长按电源键）。
* 睡眠/休眠可能复位选择器，需要时重启恢复。
* Secure Boot 必须保持关闭；Windows 大版本/BIOS 更新可能重置 UEFI 启动顺序。
* 第三方实验性工具，风险自负。

## 许可证

**GPL-2.0-only**，与上游一致。补丁的衍生关系与各上游项目许可证见
[`NOTICE.md`](NOTICE.md)。

英文版：[`README.md`](README.md)。
