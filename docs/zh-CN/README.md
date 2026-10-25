# 中文文档索引

本仓库是 [craftingmod/rtx30-unlock](https://github.com/craftingmod/rtx30-unlock)
（Windows/UEFI 移植版）与 [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)
（Linux 原版/原理）的**周边工具包**：不含上游源码、不含 NVIDIA 固件，只通过
`scripts/build-from-upstream.ps1` 按固定 commit 拉取上游并打补丁。

- [单显示器支持（补丁说明与实测）](single-display.md)
  —— `full.c` 原本要求"恰好 2 个显示子设备"，单显示器会被安全拒绝；
  补丁改为 1 或 2 个都接受，附实测日志与 cuBLAS GEMM 对比。
- [内置安装：免 U 盘、免按键](windows-internal-install.md)
  —— 隐藏内部 ESP 分区 + 排第一的 UEFI 启动项，开机自动解锁进 Windows，含回退。
- [实测报告](test-report.md)
  —— 参考机器环境、事务日志摘要、解锁前后性能（24.00 → 37.96~44.33 TFLOPS）。
- [构建说明](../build.md)（英文）
  —— 包含"没有 Visual Studio/Windows SDK 也能构建"的完整方法。

英文文档：`../../README.md`、`../../SOURCES.md`、`../../NOTICE.md`、`../*.md`。

许可证：**GPL-2.0-only**（补丁是 GPL 代码的衍生作品；本仓库自有文件同样采用
GPL-2.0-only 以保持单一兼容许可）。归属与出处见 `../../NOTICE.md`。
