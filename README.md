# rtx30-unlock Windows toolkit

Companion toolkit for **[craftingmod/rtx30-unlock](https://github.com/craftingmod/rtx30-unlock)**
(the Windows/UEFI port of **[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)**),
adding what a single-GPU, single-display Windows machine needs:

| | |
|---|---|
| **Single-display support** | patch for the v20 "quiet profile" GOP experiment: one display output is accepted, no second monitor / dummy plug / second cable required |
| **No-USB installation** | a hidden ESP-type FAT32 partition on the internal GPT disk becomes the first UEFI boot entry, so every cold boot unlocks automatically – no stick, no key press |
| **Verification** | `tools/windows/status.ps1` says whether the unlock is active right now; cuBLAS FP16 → FP32-accumulate GEMM benchmark (the metric the unlock actually changes) |
| **Recovery** | idempotent installer, repair and uninstall scripts, a full [`troubleshooting guide`](docs/troubleshooting.md) |
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
| FP16 in / **FP32 accumulate** (rate-limited path) | 21.4 – 24.1 TFLOPS | **37.96 – 44.33 TFLOPS** | **+58 … +85 %** |

The locked number is not a single constant: it drifts with temperature and
background load (21.37 / 22.93 / 24.00 / 24.06 were all observed on the reference
machine). Use the thresholds below, not a historical exact value. Full evidence:
[`docs/test-report.md`](docs/test-report.md).

> llama.cpp numbers are *not* a good unlock check: Q4_K quantized weights run through
> FP16-accumulate MMQ kernels which are not affected by the limiter
> (`pp512` moved only +6.7 %).

## Is the unlock active?

```powershell
# one command, no Python needed, most checks work without elevation
powershell -ExecutionPolicy Bypass -File tools\windows\status.ps1

# elevated: also verifies the boot entry/order and can inspect the hidden partition
powershell -ExecutionPolicy Bypass -File tools\windows\status.ps1 -Deep
```

`status.ps1` reports Secure Boot, the hidden partition, the `{fwbootmgr}` order,
sleep/resume history since boot, and runs the benchmark. Exit codes: `0` unlocked,
`1` locked, `2` unknown. The benchmark alone can also be run directly:

```powershell
tools\bench\fp16_gemm_bench.ps1                  # auto-detects cudart64_*.dll / cublas64_*.dll
tools\bench\fp16_gemm_bench.ps1 -DllDir U:\llama # or point it at any folder that has them
python tools\bench\fp16_gemm_bench.py U:\llama   # Python variant (same call)
```

| Reading | Verdict |
|---|---|
| **≤ 28 TFLOPS** | locked |
| **≥ 34 TFLOPS** | unlocked |
| 28 – 34 | inconclusive – retry; treat as locked if it stays there |

Things that can **not** tell you the unlock state: `nvidia-smi` / GPU-Z / Task
Manager (the selectors are internal GPU registers), llama.cpp with quantized
weights (~+6.7 %), games/3DMark (too noisy).

> **Known behaviour:** sleep or hibernation resets the rate selectors, so the card
> is locked again after a resume until the next cold boot. This is reproduced on
> the reference machine (22:17 sleep → 22:18 resume → 22:25 only 22.93 TFLOPS).
> See [`docs/troubleshooting.md`](docs/troubleshooting.md) §3–4.

## Requirements

* UEFI boot, **Secure Boot disabled**
* NVIDIA RTX 30 series GA10x card (upstream supports GA102/103/104/106/107)
* Windows; administrator rights for the installation step
* Build tooling: `git`, [Bun](https://bun.sh), `clang` + `lld-link`
  (see [`docs/build.md`](docs/build.md) for a no-Visual-Studio setup)
* A **`PROFILE.BIN` captured on your own machine** – see upstream
  `docs/agent/EXTERNAL-PROFILE.md`; the EFI app can also capture it on first run

## If you received a prebuilt package

`PROFILE.BIN` is bound to the card/board it was captured on, and `ASSETS/` contains
NVIDIA firmware that should not be redistributed. So a package from someone else
is usable only after capturing a profile on **your** machine:

1. Check the package has `EFI\BOOT\BOOTX64.EFI` + `RTX-UNLOCK\ASSETS\` and a
   matching `SHA256SUMS.txt` (`Get-FileHash` the EFI file).
2. Boot the package once from a USB stick or a spare ESP on your machine; with
   `DEBUG.ON` present the tool asks for `U` once and captures `PROFILE.BIN`.
3. Put the captured `RTX-UNLOCK\PROFILE.BIN` into the package.
4. Elevated: `tools\windows\install-internal.ps1 -PackageDir <package> -DryRun`,
   then run it without `-DryRun`.
5. Reboot. The unlocker runs first, then Windows.
6. Elevated: `tools\windows\status.ps1` → expect `UNLOCKED`.
7. Optional: delete `DEBUG.ON` from the hidden partition for fully silent boots
   (this also stops `RUNnn` logging, which you want while debugging).

## Build from source and install

```powershell
# 0) prerequisites: git, bun, clang+lld-link in PATH or LLVM_BIN
# 1) fetch upstream at the pinned commit, apply the patch, build, generate firmware assets
.\scripts\build-from-upstream.ps1

# 2) capture PROFILE.BIN on your machine (USB boot; see docs/build.md and
#    docs/windows-internal-install.md), put it into build-workspace\package\RTX-UNLOCK\

# 3) preview, then install (elevated). Re-running updates the existing install
#    in place - it does not create a second partition.
.\tools\windows\install-internal.ps1 -PackageDir .\build-workspace\package -DryRun
.\tools\windows\install-internal.ps1 -PackageDir .\build-workspace\package

# 4) reboot, then verify
.\tools\windows\status.ps1
```

## Rollback and repair

```powershell
# delete the RTX30 UNLOCK boot entry (auto-detected); Windows Boot Manager is untouched
.\tools\windows\remove-internal.ps1

# also delete the hidden partition and grow C: back
.\tools\windows\remove-internal.ps1 -DeletePartition -ExtendSystem

# boot-entry repair without touching files (elevated)
.\tools\windows\install-internal.ps1 -Repair
```

A one-off normal boot is always possible by picking **Windows Boot Manager** in the
firmware boot menu (**F8** on ASUS boards). Deeper recovery steps (boot order reset,
black screen, logs, error codes) are in [`docs/troubleshooting.md`](docs/troubleshooting.md).

## Repository layout

```
patches/    our patch against upstream (git format-patch, apply on the pinned commit)
scripts/    build-from-upstream.ps1 - fetch + patch + build + package + SHA256SUMS
tools/
  windows/  status.ps1 (read-only check), install-internal.ps1 (idempotent),
            remove-internal.ps1, rtx30-common.ps1 (shared helpers)
  bench/    fp16_gemm_bench.ps1 / .py  (cuBLAS FP16/FP32-accumulate verification)
  win32/    declaration-only libc headers for building without the Windows SDK
docs/
  single-display.md            the patch: why, what, evidence
  windows-internal-install.md  no-USB installation details
  troubleshooting.md           diagnosis, recovery, logs, error codes
  build.md                     build on Windows without Visual Studio
  test-report.md               measurements from the reference machine
  zh-CN/                       same documents in Chinese
SOURCES.md                     pinned upstream repos/commits, what is fetched
NOTICE.md                      attribution, licensing and redistribution rules
LICENSE                        GPL-2.0-only (derived patch + this toolkit)
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

* **No VBIOS / firmware file is written**; all patching happens in RAM for the current
  power cycle.
* **The installer does change the machine:** it shrinks `C:`, creates and formats a
  512 MB ESP-type partition, writes BCD/NVRAM (UEFI boot entry + order) and sets the
  GPT no-automount attribute. Keep a **BitLocker recovery key** ready before running it.
* The hidden partition has no drive letter and is not visible in Explorer. Do not
  format, encrypt, move or "clean up" it; removing it disables the automatic unlock.
* Preflight failures refuse and never write to the GPU; an uncertain cleanup halts
  with `STOP ... POWER OFF` – hold the power button. Do not try to continue into
  Windows from that state.
* Suspend/hibernate may reset the selectors; restart to restore (reproduced, see
  troubleshooting §3). Secure Boot must stay disabled.
* Windows feature updates or BIOS updates can reorder UEFI boot entries – put
  `RTX30 UNLOCK` back first if needed (`status.ps1` says when).
* This is experimental third-party tooling. Use at your own risk.

## License and redistribution

**GPL-2.0-only**, matching upstream. See [`NOTICE.md`](NOTICE.md) for the exact
provenance of the patch and the upstream projects. If you redistribute a built
`BOOTX64.EFI`, the GPL requires providing the corresponding source (this repository
plus the pinned upstream commits); do **not** redistribute `RTX-UNLOCK\ASSETS\`
(NVIDIA firmware, separate license), `PROFILE.BIN` or `RUNnn` logs.

Chinese version: [`README.zh-CN.md`](README.zh-CN.md) ·
Troubleshooting: [`docs/troubleshooting.md`](docs/troubleshooting.md)
