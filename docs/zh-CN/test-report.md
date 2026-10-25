# 实测报告 —— 参考机器

以下数据均来自一台真实机器上的开发测试。除硬件型号外不含任何可识别个人的信息。

## 环境

| | |
|---|---|
| CPU / 主板 | Intel i5-10400F（无核显）/ ASUS PRIME B460M-K |
| 显卡 | **GA104 版 RTX 3060 12GB**，PCI `10de:2487`，subsystem `7377:2000`，VBIOS `94.04.71.40.0F` |
| 显示 | 单台 DisplayPort 显示器（1920×1080），单输出 |
| 系统 | Windows 11 build 26300，UEFI，**Secure Boot 已关闭** |
| 驱动 | NVIDIA 616.56（KMD 616.56，CUDA UMD 13.4） |
| 上游 | craftingmod/rtx30-unlock `5c076dc` + `patches/0001-gop-single-display-child.patch` |
| 资产 | `bun run firmware:assets`（610.43.03 代次）：5 个载荷 + `NVIDIA-LICENSE`（共 6 个文件），由上游工具按 SHA256 校验 |

这张卡是 GA104 核心的 RTX 3060 12GB SKU（不是 GA106）。`PMC_BOOT_0` 读到
`0xb74000a1`（按上游 `docs/agent/GA10X-EXPERIMENTAL.md` 的字段解析为 GA104），
profile 也按该芯片绑定。

## UEFI 事务（单显示器、无第二个 EDID 源）

摘自 `RTX-UNLOCK/RUN02/GOP.TXT` 与 `UNLOCK.TXT`（只接 DP，HDMI 已拔）：

```
FULL_TOPOLOGY children=1 sibling=0
FULL_READY: 1 vendor children; six roles verified; one FLR after full isolation
FULL_STOP_INTENT role=3..0  FULL_STOP_RESULT ... status=0
FULL_ISOLATION_RESULT status=0 interfaces=0
PATCH_INTENT: one real unlock transaction including its own FLR; no extra reset
selector read: SS0=0x03446101 expected_unlock=0x88888888
selector write: SS0=0x88888888
selector read: SS1=0x00000006 expected_unlock=0x8
selector write: SS1=0x8
pre-FLR selectors: ss0=0x88888888 ss1=0x8
PCIe FLR returned: result=0
post-FLR SEC2 reset released, GSP halted, BME=0 pending=0 WPR2=1ffffe00:00000000 SS0=88888888 SS1=00000008
PATCH_TRANSACTION result=0 ... FLR=1 safe=1
PATCH_STATE ×7 matched=1（SS0=88888888 SS1=00000008 PLM=ffffffff）
FULL_RESULT status=0 touched=1 ... restored=1
END: patch and display verified; Windows handoff follows if report close succeeds
WINDOWS_START_INTENT reboot=0
```

运行前冷态：`plm=0xffffff8f`、`SS0=0x03446101`、`SS1=0x00000006`、
`GFW=0x8b8f/0x3ff/0x10`、WPR2 高字为 0、live PROM 哈希匹配、5 个资产校验通过。

## 性能

同一台机器、同一条命令、冷启动 vs 解锁启动。`tools/bench/fp16_gemm_bench.py` 调用
cuBLAS `cublasGemmEx`（FP16 输入、FP32 累加、4096³、50 次迭代）。
PowerShell 版 `tools/bench/fp16_gemm_bench.ps1`（不需要 Python）做同一条调用；
两个脚本都会打印判定（未解锁 `<= 28`、已解锁 `>= 34` TFLOPS）。

| 测量 | 未解锁 | 解锁后 | 提升 |
|---|---:|---:|---:|
| FP16→FP32 累加 GEMM | 21.4 – 24.1 TFLOPS（本次 24.00）| 37.96 – 44.33 TFLOPS | +58 … +85 % |

> 未解锁基线会随温度与后台负载漂移（21.37 / 22.93 / 24.00 / 24.06 都出现过）。
> 早期版本还列过一行 **TF32**（24.06 → 33.70–45.72 TFLOPS）：当前工具测不出这条
> 路径（基准只测 FP16/FP32 累加），且上界超过该卡 TF32 的理论峰值，已删除，
> 请不要使用那些数字。

llama.cpp（gemma-4-12b Q4_K_M，`llama-bench -p 512 -n 128 -ngl 99 -r 3`）：

| | 未解锁 | 解锁后 | 提升 |
|---|---:|---:|---:|
| pp512 | 1193.98 t/s | 1273.51 t/s | +6.7 % |
| tg128 | 34.32 t/s | 37.65 t/s | +9.7 % |

**解读**：解锁翻倍的是 FP16/BF16 到 FP32 累加的指令发射率（Tensor Core 通路）。
这张 170 W 卡实测 GEMM +58…+85%，方向与上游 README 一致（该 README 给的是
按卡不同的数字，例如 RTX 3090 Ti：FP16 87.46 → 118.39、BF16 87.50 → 157.41、
TF32 42.58 → 82.61 TFLOPS）；绝对值随卡不同。
llama.cpp 的 Q4_K 量化权重走 FP16 累加的自定义 MMQ kernel，本来就不吃这个限制，
所以**不适合作为解锁判据**，请用 cuBLAS 的 FP16/FP32 基准。

## 内置安装

USB 验证通过后，用 `tools/windows/install-internal.ps1` 把包安装到内置 NVMe 的
512MB 隐藏 ESP 型 FAT32 分区，并把 `RTX30 UNLOCK` 启动项排到固件启动顺序第一。
下一次冷启动（不插 U 盘、不插 HDMI、不按键）自动运行，选择器状态相同
（`SS0=88888888 SS1=00000008 PLM=ffffffff`，7 个阶段 matched），`restored=1`，
正常进入 Windows；该次启动后 FP16→FP32 累加 GEMM 实测 41.67 TFLOPS。

## 注意事项 / 局限

- 单输出路径是在一张卡上的实验性扩展；双输出拓扑行为完全不变。
- 不写 VBIOS/固件文件；选择器断电即复位，每次冷启动重新解锁；睡眠/休眠同样会复位，
  本机已复现：2026-10-25 21:48 冷启动 → 22:17 睡眠 → 22:18 唤醒 → 22:25 只剩
  22.93 TFLOPS、22:56 21.37，期间安装未动。见 [`troubleshooting.md`](troubleshooting.md)。
- 单次 GEMM 连续运行超过约 2 秒可能触发 WDDM TDR；日常推理/训练负载不会，基准已避开。
- 与本机绑定的 `PROFILE.BIN` 和原始运行日志不包含在本仓库中。

## 构建可复现性（已验证）

在参考机器上，用 [`build.md`](../build.md) 描述的工具链，对固定 commit
（`5c076dc4ee7fa369639669fa591ac74d8f6dfcd8`）的上游源码打上
`patches/0001-gop-single-display-child.patch` 后重新构建：

```
built EFI: 107520 bytes  sha256=48dca8919051bb9d08aeb883a17d3cf3300e0b76e4d6de326b06cbb385e09175
```

与上面实测用的二进制完全一致（同工具链下逐字节可复现）。不同 clang/LLVM 版本会
得到同样大小但不同哈希的产物，跨工具链只能保证行为一致、不保证逐字节一致。
