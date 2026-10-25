# Troubleshooting and recovery

This page is for the "no USB stick" installation described in
[`windows-internal-install.md`](windows-internal-install.md). Everything here is
read-only diagnostics unless a step says otherwise.

> **Start here**
> ```powershell
> # works without elevation (benchmark + partition + sleep history)
> powershell -ExecutionPolicy Bypass -File tools\windows\status.ps1
>
> # elevated: also checks the UEFI boot entry/order and can mount the hidden partition
> powershell -ExecutionPolicy Bypass -File tools\windows\status.ps1 -Deep
> ```
> `status.ps1` prints a verdict and what to do next. Exit code: `0` unlocked,
> `1` locked, `2` unknown.

## 1. 30-second diagnosis: is the unlock active?

Only one metric answers this: the cuBLAS **FP16 input / FP32 accumulate** GEMM
rate. Use the PowerShell benchmark (no Python needed) or the Python twin:

```powershell
tools\bench\fp16_gemm_bench.ps1                  # auto-detects CUDA/llama.cpp DLLs
tools\bench\fp16_gemm_bench.ps1 -DllDir U:\llama # or point it at any folder with cudart64_*.dll + cublas64_*.dll
python tools\bench\fp16_gemm_bench.py U:\llama   # Python variant, same call
```

| Reading | Verdict | Next |
|---|---|---|
| **<= 28 TFLOPS** | locked | section 2 (which kind of "locked") |
| **>= 34 TFLOPS** | unlocked | fine; note the value for later |
| 28 – 34 TFLOPS | inconclusive | wait 30 s and run again; still there -> treat as locked |

Reference values from the reference machine (RTX 3060 12 GB, 170 W):
locked **21.37 / 22.93 / 24.00 / 24.06** TFLOPS; unlocked **37.96 / 40.79 / 41.67 / 44.33**.
Do not use a single historical number as a baseline; the locked state alone drifts
by ~10 % with temperature and background load.

Three things that **cannot** tell you the unlock state:

* `nvidia-smi`, GPU-Z, Task Manager – the selectors (`SS0`/`SS1`) are internal
  GPU registers, not reported by the driver;
* llama.cpp with Q4_K weights – the MMQ kernels use FP16 accumulation and gain
  only ~6.7 %;
* games/3DMark – too noisy.

## 2. Three shapes of "not unlocked"

A production build does not silently continue on failure: it prints the failure
and calls `Halt()`. So "Windows started but the card is locked" is almost always
A or B below, not a failed unlocker.

| Shape | Boot behaviour | New `RUNnn` log? | Bench | What to do |
|---|---|---|---|---|
| **A – unlocker did not run** | boots as fast as usual | no | ~21–24 | check boot order (section 5) |
| **B – ran, selectors later reset** | a few seconds slower | yes | ~21–24 | sleep/hibernate or Fast Startup (sections 3, 4) |
| **C – ran and refused** | stops / black screen, Windows does not start | yes, last line `FINAL status=… stage=…` | n/a | rescue (section 6), logs (section 8) |

"No extra seconds at boot" is itself a useful clue: a successful unlock adds a
few seconds.

## 3. After sleep or hibernation (reproduced on the reference machine)

**Symptom:** everything looks normal after a resume – driver fine, `nvidia-smi`
fine – but the FP16/FP32 GEMM is back to 21–24 TFLOPS. No error, no event log entry.

**Why:** the unlock only lives in the GPU's rate selectors for the current power
cycle. S3 sleep / S4 hibernation re-initialises (or powers off) the GPU, the
selectors fall back to `SS0=0x03446101 / SS1=0x00000006`, and Windows does not
re-run the unlocker. It cannot recover by itself.

**Reference observation (2026-10-25):** cold boot 21:48 (unlocked) -> sleep
22:17 -> resume 22:18 -> 22:25 bench **22.93 TFLOPS** -> 22:56 re-check **21.37**.
The installation, partition and boot entry were untouched the whole time.

**Recovery, cheapest first:**

1. **Restart** (not shutdown). Windows restart always goes through the firmware,
   so the unlocker runs again. Restarting within the same power cycle is safe:
   the source has an "already applied -> skip and hand off" path.
2. Still low after a restart -> **full power off and on again** (see Fast Startup
   in section 4: the Start menu's "shut down" may be a resume).
3. Still low -> check the boot order (section 5).

**Prevention:** for long GPU jobs set the power plan's sleep timeout to Never
(`powercfg /change standby-timeout-ac 0`), and disable Fast Startup. If you need
to leave, prefer a cold boot when you come back.

## 4. Fast Startup: "shut down" may not be a cold boot

Windows enables Fast Startup by default (`HiberbootEnabled=1`). "Shut down" then
means log off + hibernate the kernel; the next power-on resumes it. The unlocker
is still invoked by the firmware, but the resume path can bring the selectors
back in the locked state, which looks like "shutdown and power-on did not help".

```powershell
# check (no elevation needed)
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled

# disable (elevated)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
```

Without changing the setting, a true cold boot is **Start -> Power -> Restart**,
or `shutdown /s /full /t 0`.

## 5. Boot order was reset (Windows feature update, BIOS update, Secure Boot)

Events that can break the automatic boot: Windows feature updates (may reorder
the firmware entries), BIOS/CMOS reset, a new disk or a changed NVMe port (entry
lost), and re-enabling Secure Boot (the application refuses to start).

**Self-check (elevated):**

```powershell
bcdedit /enum {fwbootmgr}                  # first entry must be the RTX30 UNLOCK GUID
bcdedit /enum all | findstr /i "RTX30"     # entry itself: device + path
Confirm-SecureBootUEFI                     # must be False
```

**Disk side (no elevation):**

```powershell
Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
    Format-Table DiskNumber, PartitionNumber, Size, Offset
```

There must be a **536870912-byte (512 MB)** partition. If it is gone, the disk was
replaced or the partition was deleted – reinstall (section 9).

**Repair, cheapest first:**

1. Boot with **F8** (ASUS boards) and pick `RTX30 UNLOCK` once. If that unlocks,
   it is only an order problem.
2. Elevated: `bcdedit /set {fwbootmgr} displayorder {GUID} /addfirst`
   (GUID from the second command above), or run
   `tools\windows\install-internal.ps1 -Repair` (elevated) which does the same
   after re-pointing the entry at the existing partition.
3. Enter the firmware setup (Del on ASUS) -> Boot -> move `RTX30 UNLOCK` to the top.
4. Only if the entry is really gone: re-run the installer. The current
   `install-internal.ps1` detects an existing `RTX30UNLOCK` volume and updates it
   in place; older versions would have created a second partition.
5. Secure Boot was re-enabled -> disable it in the firmware setup (`Other OS`
   or Secure Boot Disable), save and reboot.

## 6. Boot hangs or black screen

Every failure **before** writing the GPU prints a reason (on a single-DP machine
the screen can be black because GOP was already released) and calls `Halt()`,
so it never falls through to Windows. "Hangs" therefore means "the unlocker
refused", not "Windows is broken".

1. Hold the power button for ~5 seconds.
2. At the next boot press **F8** (ASUS) and choose **Windows Boot Manager** to
   boot normally without unlocking.
3. Run `status.ps1 -Deep` and read the newest `RUNnn` log (section 8) to find
   `stage=` and `FINAL status=`.
4. If the log says `STOP: cleanup cannot be proven. Resources remain reserved.`,
   do **not** try to continue into Windows: power off, cold boot, F8 -> Windows
   Boot Manager.

Common `stage=` values (from the source and the reference logs):

| `stage=` / symptom | Meaning | Fix |
|---|---|---|
| `secure-boot` (`0x800000000000001A`) | Secure Boot is on | disable it in the firmware |
| `target`, `config-recheck`, `bar0` | GPU not found/recognised (different card, Above 4G off, PCIe issue) | check card/BIOS settings |
| `cold-state`, `prom` | GPU not in a cold state or PROM hash mismatch (profile from another machine) | full power cycle; re-capture `PROFILE.BIN` on this machine |
| `assets` | `RTX-UNLOCK\ASSETS\` missing/modified | copy the five payloads again |
| `arming` (`EFI_TIMEOUT`) | `DEBUG.ON` present but `U` was not pressed within ~30 s | press `U`, or remove `DEBUG.ON` |
| `display`, `armed-display` | display topology check failed (multi-monitor, iGPU, port) | one output only, use the primary output |
| `ownership`, `driver-release` | firmware driver not released | cold boot and retry |

## 7. "Windows started but the card is locked" checklist

1. Did you just resume from sleep? -> section 3.
2. Was that "shutdown" actually Fast Startup? -> section 4.
3. Is `RTX30 UNLOCK` still first in `{fwbootmgr}`? -> section 5.
4. Is Secure Boot still off? -> section 5.
5. Is the 512 MB ESP partition still there? -> section 5.
6. Is there a new `RUNnn` directory? No = the unlocker did not run (shape A).
7. New `RUNnn` but low bench -> read `FINAL status=`/`END:` in that log (section 8).
8. Everything looks right and the bench is still below 28 -> capture three
   readings plus the `RUNnn` log and open an issue (template in the repository).

## 8. Logs: where `RUNnn` lives and how to read it

Logs are only written when `RTX-UNLOCK\DEBUG.ON` exists at boot. Removing
`DEBUG.ON` makes boot fully automatic **but also disables logging** – put it back
while troubleshooting (boot then asks for `U` once).

The partition has no drive letter and does not appear in Explorer. Mount it
temporarily from an elevated PowerShell:

```powershell
# 1) find the volume GUID (no drive letter needed)
Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -and $_.Size -eq 512MB } |
    ForEach-Object { $_.AccessPaths }

# 2) mount it as X:
mountvol X: \\?\Volume{YOUR-GUID}\

# 3) inspect
Get-ChildItem X:\RTX-UNLOCK\RUN* | Sort-Object LastWriteTime -Descending | Select-Object -First 3
notepad X:\RTX-UNLOCK\RUN02\UNLOCK.TXT

# 4) unmount (does not affect boot)
mountvol X: /P
```

The newest `RUNnn` directory's last-write time should match this boot. Success
fingerprints in `UNLOCK.TXT` / `GOP.TXT`:

```text
FULL_TOPOLOGY children=1 sibling=0
FULL_READY: 1 vendor children; six roles verified; one FLR after full isolation
selector write: SS0=0x88888888
selector write: SS1=0x8
PCIe FLR returned: result=0
PATCH_TRANSACTION result=0 ... FLR=1 safe=1
PATCH_STATE phase=after-output ... matched=1          (all seven phases matched=1)
FULL_RESULT status=0 touched=1 ... restored=1
END: patch and display verified; Windows handoff follows if report close succeeds
WINDOWS_START_INTENT reboot=0
```

Restart within the same power cycle:

```text
SS0 already 88888888. Unlock skipped.
END: already applied; Windows handoff follows
```

Failure fingerprint (last line):

```text
FINAL status=0x800000000000001a stage=secure-boot attempted=0 driver_release=0 clean=1
CANCELLED_OR_REFUSED stage=full-prepare status=0x8000000000000003 touched=0
```

## 9. Updating, reinstalling, replacing the card

**Do not** re-run an *old* installer just to "fix" something: it had no
"already installed" detection and created another 512 MB partition each run.

Current `install-internal.ps1` is idempotent: it finds the `RTX30UNLOCK` volume,
mounts it, replaces `EFI`/`RTX-UNLOCK` files, verifies the package manifest and
the boot entry, and hides the partition again. `RUNnn` logs and `PROFILE.BIN` are
preserved. Preview with `-DryRun`, then run it elevated.

Replacing only the EFI/build (manual fallback):

```powershell
# elevated
mountvol X: \\?\Volume{YOUR-GUID}\
Copy-Item <new-package>\EFI\BOOT\BOOTX64.EFI X:\EFI\BOOT\BOOTX64.EFI -Force
Copy-Item <new-package>\RTX-UNLOCK\ASSETS\* X:\RTX-UNLOCK\ASSETS\ -Force
mountvol X: /P
```

A full rebuild of the partition:

1. Make sure no second 512 MB ESP-type partition exists (`Get-Partition`);
2. `tools\windows\remove-internal.ps1 -DeletePartition -ExtendSystem` (current
   version; it locates the volume by label, deletes the entry and the partition
   and grows C: back);
3. reinstall and verify.

**Replacing the GPU or moving to another machine:** `PROFILE.BIN` is bound to the
card (PCI ID, subsystem, chip). Re-capture it on the target machine with a USB
boot (keep `DEBUG.ON`, press `U`) and replace the file on the hidden partition.
Never copy someone else's `PROFILE.BIN`.

## 10. Uninstall

```powershell
# elevated: delete the boot entry only
tools\windows\remove-internal.ps1

# delete the entry, the partition, and give the space back to C:
tools\windows\remove-internal.ps1 -DeletePartition -ExtendSystem
```

The BCD export is written next to the installer's `-BackupDir`
(default `%ProgramData%\rtx30-unlock`, `bcd-backup-*.bcd`). Restore it with
`bcdedit /import <file>` from an elevated shell only if the boot store is broken.

Windows Boot Manager itself is never modified; picking it once in the firmware
boot menu (F8) is always a safe one-off.

## 11. Error codes

| Code | Name | Typical cause |
|---|---|---|
| `0x800000000000001A` | `EFI_SECURITY_VIOLATION` | Secure Boot enabled |
| `0x8000000000000003` | `EFI_UNSUPPORTED` | topology / asset / display check refused |
| `0x800000000000000E` | `EFI_TIMEOUT` | `DEBUG.ON` present, `U` not pressed in time |
| `0x800000000000000F` | `EFI_NOT_FOUND` | profile, assets or vendor child not found |
| `EFI_ABORTED` | aborted | Esc pressed during the capture prompt |

## 12. When to stop and ask

* Do not format, encrypt or move the hidden partition.
* Do not patch `src/gop/full.c` to bypass topology checks on your own.
* Do not flash a VBIOS.
* Do not continue after `STOP: cleanup cannot be proven`.
* Do not install while BitLocker is on and you have no recovery key.

Otherwise open an issue with `status.ps1 -Json` output, the newest `RUNnn` log
(`UNLOCK.TXT`, `GOP.TXT`) and the three bench readings.
