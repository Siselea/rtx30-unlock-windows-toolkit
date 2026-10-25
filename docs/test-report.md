# Test report — reference machine

All measurements below were taken on one real machine while developing this toolkit.
No identifiers beyond the hardware model are included.

## Environment

| | |
|---|---|
| CPU / board | Intel i5-10400F (no iGPU) / ASUS PRIME B460M-K |
| GPU | **GA104-based RTX 3060 12 GB**, PCI `10de:2487`, subsystem `7377:2000`, VBIOS `94.04.71.40.0F` |
| Display | one DisplayPort monitor (1920×1080), single output |
| OS | Windows 11 build 26300, UEFI, **Secure Boot disabled** |
| Driver | NVIDIA 616.56 (KMD 616.56, CUDA UMD 13.4) |
| Upstream | craftingmod/rtx30-unlock `5c076dc` + `patches/0001-gop-single-display-child.patch` |
| Assets | `bun run firmware:assets` (pinned 610.43.03 generation): 5 payloads + `NVIDIA-LICENSE` (6 files), fetched and SHA-256 verified by the upstream tool |

The card is a GA104 die built as an RTX 3060 12 GB SKU (not GA106). `PMC_BOOT_0`
reported `0xb74000a1` (parsed as GA104; field mapping follows the upstream
`docs/agent/GA10X-EXPERIMENTAL.md`) and the profile bound the card to that chip.

## UEFI transaction (single display, no second EDID source)

Excerpt from `RTX-UNLOCK/RUN02/GOP.TXT` and `UNLOCK.TXT` (single DP cable, HDMI removed):

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
pre-FLR selectors: ss0=0x88888888 expected=0x88888888 ss1=0x8 expected=0x8
PCIe FLR returned: result=0
post-FLR SEC2 reset released, GSP halted, BME=0 pending=0 WPR2=1ffffe00:00000000 SS0=88888888 SS1=00000008
PATCH_TRANSACTION result=0 containment=0 started=1 quiesced=1 fault=0 retained=0 maps=0 FLR=1 safe=1
PATCH_STATE phase=before-gop            SS0=88888888 SS1=00000008 PLM=ffffffff matched=1
PATCH_STATE phase=after-gop             ... matched=1
PATCH_STATE phase=after-alternate-mode  ... matched=1
PATCH_STATE phase=after-set-mode        ... matched=1
PATCH_STATE phase=after-blt             ... matched=1
PATCH_STATE phase=after-readback        ... matched=1
PATCH_STATE phase=after-output          ... matched=1
FULL_RESULT status=0 touched=1 detach=0 isolated=0 exclusive=0 close=0 restore=0 verify=0 restored=1
END: patch and display verified; Windows handoff follows if report close succeeds
WINDOWS_START_INTENT reboot=0
```

Cold state before the run (from the same log): `plm=0xffffff8f`, `SS0=0x03446101`,
`SS1=0x00000006`, `GFW=0x8b8f/0x3ff/0x10`, WPR2 high = 0, live PROM hash matched,
all five assets verified.

## Performance

Same machine, same command, cold boot vs unlocked boot. `tools/bench/fp16_gemm_bench.py`
runs cuBLAS `cublasGemmEx` with FP16 inputs, FP32 accumulate, 4096³, 50 iterations.
The PowerShell twin `tools/bench/fp16_gemm_bench.ps1` (no Python needed) makes the same
call; both scripts print a verdict (locked `<= 28`, unlocked `>= 34` TFLOPS).

| measurement | locked | unlocked | gain |
|---|---:|---:|---:|
| FP16 in / FP32 accumulate GEMM | 21.4 – 24.1 TFLOPS (24.00 in this run) | 37.96 – 44.33 TFLOPS | +58 … +85 % |

> The locked baseline drifts with temperature and background load (21.37 / 22.93 /
> 24.00 / 24.06 were all observed). An earlier revision also listed a **TF32** row
> (24.06 → 33.70–45.72 TFLOPS); it is not reproducible with the current tooling
> (the benchmarks measure only the FP16/FP32-accumulate path) and its upper bound
> is above this card's expected TF32 peak, so it was removed - do not use it.

llama.cpp (gemma-4-12b Q4_K_M, `llama-bench -p 512 -n 128 -ngl 99 -r 3`):

| | locked | unlocked | gain |
|---|---:|---:|---:|
| pp512 | 1193.98 t/s | 1273.51 t/s | +6.7 % |
| tg128 | 34.32 t/s | 37.65 t/s | +9.7 % |

**Interpretation.** The unlock doubles the issue rate of FP16/BF16 FMA into FP32
accumulate operations (Tensor Core path). On this 170 W card the measured GEMM gain is
+58…+85 %, in line with the upstream README, which reports card-dependent numbers
(e.g. RTX 3090 Ti: FP16 87.46 → 118.39, BF16 87.50 → 157.41, TF32 42.58 → 82.61
TFLOPS). The direction matches; the absolute numbers differ per card. Quantized
llama.cpp inference (Q4_K) uses FP16-accumulate MMQ kernels and is *not* affected by
the limiter, so it is a bad unlock indicator; use the cuBLAS FP16/FP32 benchmark.

## Internal installation

After validating from a USB stick, the package was installed to a hidden 512 MB
ESP-type FAT32 partition on the internal NVMe disk with
`tools/windows/install-internal.ps1`; the `RTX30 UNLOCK` UEFI boot entry was placed
first in the firmware boot order. On the next cold boot (no USB stick, no HDMI cable,
no key press) the tool ran automatically and produced the same selector states
(`SS0=88888888 SS1=00000008 PLM=ffffffff`, seven phases matched), `restored=1`, and
Windows started; the FP16→FP32-accumulate GEMM measured 41.67 TFLOPS after that boot.

## Notes / limitations

* The single-output path is an experimental extension validated on one card; the
  two-output topology continues to work unchanged.
* No VBIOS or firmware file is written; selectors reset on power loss and are re-set
  on every cold boot. Suspend/hibernate reset them too: reproduced on this machine on
  2026-10-25 (cold boot 21:48 → sleep 22:17 → resume 22:18 → 22:25 only 22.93 TFLOPS,
  22:56 21.37, installation untouched). See [`troubleshooting.md`](troubleshooting.md).
* Long-running single GEMM kernels (>~2 s of continuous GPU work) can hit the WDDM TDR
  timeout; normal inference/training workloads do not. The benchmark is sized to avoid it.
* The exact board profile (`PROFILE.BIN`) and raw run logs are machine-bound and are not
  part of this repository.

## Build reproducibility (checked)

A clean clone of `craftingmod/rtx30-unlock` at the pinned commit
(`5c076dc4ee7fa369639669fa591ac74d8f6dfcd8`) with
`patches/0001-gop-single-display-child.patch` applied was built on the reference
machine with the toolchain described in [`build.md`](build.md):

```
built EFI: 107520 bytes  sha256=48dca8919051bb9d08aeb883a17d3cf3300e0b76e4d6de326b06cbb385e09175
```

which is exactly the binary that was tested above, i.e. the patch + pinned upstream
reproduce the tested build byte-for-byte with the same toolchain. (A different
clang/LLVM version produces the same size but a different hash — treat cross-toolchain
rebuilds as behaviourally, not byte-wise, reproducible.)
