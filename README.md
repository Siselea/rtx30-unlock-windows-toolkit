# rtx30-unlock Windows toolkit

Companion toolkit for **[craftingmod/rtx30-unlock](https://github.com/craftingmod/rtx30-unlock)**
(the Windows/UEFI port of **[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)**),
adding what a single-GPU, single-display Windows machine needs:

| | |
|---|---|
| **Single-display support** | patch for the v20 "quiet profile" GOP experiment: one display output is accepted, no second monitor / dummy plug / second cable required |
| **No-USB installation** | a hidden ESP-type FAT32 partition on the internal GPT disk becomes the first UEFI boot entry, so every cold boot unlocks automatically – no stick, no key press |
| **Verification** | cuBLAS FP16 → FP32-accumulate GEMM benchmark (the metric the unlock actually changes) |
| **Build recipes** | upstream build on Windows with portable clang/lld-link (no Visual Studio / Windows SDK required) |
| **Test report** | real measurements from a GA104-based RTX 3060 12 GB |

> **This repository intentionally contains no upstream source code and no NVIDIA
> firmware.** The two upstream projects are referenced and fetched at pinned commits;
> this applies our patch and ships only original scripts, docs and measurements.
> See [`SOURCES.md`](SOURCES.md) and [`NOTICE.md`](NOTICE.md).

## Tested result

Stock GA104-based **RTX 3060 12 GB** (`10de:2487`, subsystem `7377:2000`,
VBIOS `94.04.71.40.0F`), Windows 11 26300, NVIDIA 616.56, single DisplayPort monitor,
no iGPU, Secure Boot off:

| cuBLAS GEMM 4096³ | locked (cold boot) | unlocked | gain |
|---|---:|---:|---:|
| FP16 in / **FP32 accumulate** (rate-limited path) | 24.00 TFLOPS | **37.96 – 44.33 TFLOPS** | **+58 … +85 %** |
| TF32 | 24.06 TFLOPS | 33.70 – 45.72 TFLOPS | +40 … +90 % |

Full evidence: [`docs/test-report.md`](docs/test-report.md).

> llama.cpp numbers are *not* a good unlock check: Q4_K quantized weights run through
> FP16-accumulate MMQ kernels which are not affected by the limiter
> (`pp512` moved only +6.7 %).

## Requirements

* UEFI boot, **Secure Boot disabled**
* NVIDIA RTX 30 series GA10x card (upstream supports GA102/103/104/106/107)
* Windows; administrator rights for the installation step
* Build tooling: `git`, [Bun](https://bun.sh), `clang` + `lld-link`
  (see [`docs/build.md`](docs/build.md) for a no-Visual-Studio setup)
* A **`PROFILE.BIN` captured on your own machine** – see upstream
  `docs/agent/EXTERNAL-PROFILE.md`; the EFI app can also capture it on first run

## Quick start

```powershell
# 0) prerequisites: git, bun, clang+lld-link in PATH or LLVM_BIN
# 1) fetch upstream at the pinned commit, apply the patch, build, generate firmware assets
.\scripts\build-from-upstream.ps1

# 2) boot the produced package once from a USB stick (or a spare ESP) to capture
#    PROFILE.BIN on your machine; the upstream docs explain the DEBUG.ON / U flow.
#    Put the captured PROFILE.BIN into build-workspace\package\RTX-UNLOCK\.

# 3) install it on the internal disk (elevated PowerShell)
.\tools\windows\install-internal.ps1 -PackageDir .\build-workspace\package

# 4) full shutdown, power on - the unlocker runs first, then Windows
```

Rollback:

```powershell
.\tools\windows\remove-internal.ps1 -EntryGuid '{...}'              # boot entry only
.\tools\windows\remove-internal.ps1 -EntryGuid '{...}' -DeletePartition
```

or pick **Windows Boot Manager** in the firmware boot menu (F8 on ASUS boards) for a
one-off normal boot.

## Repository layout

```
patches/    our patch against upstream (git format-patch, apply on the pinned commit)
scripts/    build-from-upstream.ps1 - fetch + patch + build + package
tools/
  windows/  install-internal.ps1 / remove-internal.ps1 (hidden internal ESP + boot entry)
  bench/    fp16_gemm_bench.py  (cuBLAS FP16/FP32-accumulate verification)
  win32/    declaration-only libc headers for building without the Windows SDK
docs/
  single-display.md            the patch: why, what, evidence
  windows-internal-install.md  no-USB installation details
  build.md                     build on Windows without Visual Studio
  test-report.md               measurements from the reference machine
  zh-CN/                       same documents in Chinese
SOURCES.md                     pinned upstream repos/commits, what is fetched
NOTICE.md                      attribution and licensing
LICENSE                        GPL-2.0 (derived patch + this toolkit)
```

## How the unlock works (short version)

The EFI application runs before Windows, boots the GPU firmware through the SEC2
boot ROM and uses the V67 ROP payload to set `FEAT_OVR_PLM (0x00823804)` to
`0xFFFFFFFF` in heavy-secure mode. The host can then write the rate selectors
`SS0 (0x0082381c) = 0x88888888` and `SS1 (0x00823820) = 0x8`, performs one PCIe FLR and
hands control to `bootmgfw.efi` without rebooting. Windows then runs with the full
FP16/BF16 (FP32-accumulate) Tensor Core issue rate.

Nothing is persisted on the card: power loss resets the selectors, so every cold boot
re-runs the unlock. The toolkit's internal-install option makes that automatic.

## Safety

* No VBIOS / firmware file is written; all patching happens in RAM for the current
  power cycle.
* Preflight failures refuse and never write to the GPU; uncertain cleanup halts with
  `STOP ... POWER OFF` – hold the power button.
* Suspend/hibernate may reset the selectors; reboot to restore.
* Secure Boot must stay disabled. Windows feature updates or BIOS updates can reorder
  UEFI boot entries – put `RTX30 UNLOCK` back first if needed.
* This is experimental third-party tooling. Use at your own risk.

## License

**GPL-2.0-only**, matching upstream. See [`NOTICE.md`](NOTICE.md) for the exact
provenance of the patch and the list of upstream projects and their licenses.

Chinese version: [`README.zh-CN.md`](README.zh-CN.md).
