# Installing the unlocker on the internal disk (no USB stick)

The upstream workflow runs the EFI application from a separate USB stick on every cold
boot. This document describes an alternative that is fully automatic:

* a small hidden FAT32 partition of type **EFI System Partition** is created on the
  internal GPT disk,
* the EFI application, the firmware assets and a validated `PROFILE.BIN` are copied
  there,
* a new UEFI boot entry pointing at `\EFI\BOOT\BOOTX64.EFI` is created and put **first**
  in the firmware boot order.

On every cold boot the firmware runs the unlocker first, it unlocks the card and then
loads `\EFI\Microsoft\Boot\bootmgfw.efi` from the Windows ESP – no reboot, no key press,
no USB stick. The original *Windows Boot Manager* entry is left untouched.

> For diagnosis after the installation (locked, black screen, boot order reset,
> logs, error codes) see [`troubleshooting.md`](troubleshooting.md).

## Requirements

* UEFI boot, **Secure Boot disabled** (the application refuses to run otherwise and
  returns `EFI_SECURITY_VIOLATION`, `0x800000000000001A`).
* Administrator rights for the one-time installation.
* The built `BOOTX64.EFI` plus `RTX-UNLOCK\ASSETS\` from
  `bun run firmware:assets` (the firmware assets are **not** in this repository:
  they are NVIDIA firmware / generated payloads, see the upstream
  `tools/firmware/README.md`).
* A `RTX-UNLOCK\PROFILE.BIN` captured on **this** machine (see the upstream
  `docs/agent/EXTERNAL-PROFILE.md`). Without it the EFI application captures one on
  its first boot; with `DEBUG.ON` present it still asks for `U`, without it the run
  proceeds silently.

### Before you install: three things to check

1. **BitLocker:** the installer shrinks `C:` and changes the boot order. Export the
   recovery key (`manage-bde -status`, `manage-bde -protectors -get C:`), or suspend
   protection for one reboot, before running it.
2. **Free space:** `C:` must have at least `-SizeMB` (default 512 MB) of shrinkable
   space at its end. The installer fails cleanly if it does not.
3. **Elevation + Secure Boot:** run from an elevated PowerShell and keep Secure Boot
   disabled for the whole lifetime of the installation.

## Quick start

Prepare a package folder (the build script produces this layout):

```
package\
  EFI\BOOT\BOOTX64.EFI
  RTX-UNLOCK\
    ASSETS\              (5 firmware payloads + NVIDIA-LICENSE)
    PROFILE.BIN          (captured on this machine)
    DEBUG.ON             (optional, first run only - see "boot flow")
  SHA256SUMS.txt         (written by build-from-upstream.ps1)
```

Then run:

```powershell
# elevated PowerShell

# 0) preview: shows whether an installation already exists, how much would be
#    shrunk, and verifies the package manifest. Changes nothing, works without
#    elevation.
.\tools\windows\install-internal.ps1 -PackageDir C:\path\to\package -DryRun

# 1) install (or update an existing installation in place)
.\tools\windows\install-internal.ps1 -PackageDir C:\path\to\package
```

The script

1. verifies the package (`SHA256SUMS.txt`, EFI hash, assets) and exports the current
   BCD to `%ProgramData%\rtx30-unlock\bcd-backup-<timestamp>.bcd`,
2. **if no installation exists:** shrinks `C:` by `-SizeMB` (default 512) and creates
   an ESP-type FAT32 partition; **if the volume `RTX30UNLOCK` already exists:** mounts
   it and updates the files in place (no second partition, `RUNnn` logs and
   `PROFILE.BIN` are preserved),
3. copies the package, verifies the copy, creates or reuses the `RTX30 UNLOCK` boot
   entry and puts it first,
4. removes the drive letter and sets the GPT no-automount attribute so the partition
   is hidden like the Windows ESP.

Useful parameters: `-SizeMB`, `-Label`, `-SkipHide` (keep the drive letter, debugging),
`-Repair` (only fix the boot entry/order, do not touch files), `-Force`,
`-ExpectedEfiSha256`, `-BackupDir`, `-LogPath`. On failure the installer rolls back
the partition, the log and the boot entry it created and prints the BCD backup path.

## Verify the installation

```powershell
# elevated: boot entry, order, partition, EFI hash, latest RUN log, benchmark
.\tools\windows\status.ps1 -Deep
```

Expected: `RESULT: UNLOCKED`, exit code 0. Without elevation `status.ps1` still checks
the partition, sleep history and runs the benchmark; the boot-entry part is skipped.

Three independent checks:

1. `status.ps1` says `UNLOCKED` (or the GEMM benchmark is >= 34 TFLOPS);
2. `bcdedit /enum {fwbootmgr}` lists the `RTX30 UNLOCK` GUID first;
3. the 512 MB ESP-type partition is still there (`Get-Partition`).

## Boot flow / behaviour

* **Cold boot, success:** firmware → unlocker (a few seconds) → Windows, unlocked.
* **Restart within the same power cycle:** the unlocker prints
  `SS0 already 88888888. Unlock skipped.` and hands off; safe.
* **`DEBUG.ON` present:** the tool asks for `U` once (30 s timeout), writes
  `RUNnn` probe logs and captures data; removing it makes boot silent **and stops
  the `RUNnn` logs** – keep it while troubleshooting, remove it for daily use.
* **Failure before writing the GPU:** the tool prints the reason and calls `Halt()`
  (a single-DP screen can be black because GOP was released). It does not fall
  through to Windows. Power-cycle and boot Windows Boot Manager via F8, then read
  the log (see [`troubleshooting.md`](troubleshooting.md) §6–8).
* Power loss resets the unlocked rate selectors, so **every cold boot** has to unlock
  again – that is by design, nothing is persisted on the card.
* **Suspend/hibernate reset the selectors** even though the installation is fine:
  after a resume the card is locked until the next cold boot (reproduced on the
  reference machine). See [`troubleshooting.md`](troubleshooting.md) §3.
* Windows feature updates or BIOS updates can reorder UEFI boot entries. If the
  unlocker stops running, `status.ps1` reports it; `install-internal.ps1 -Repair`
  or `bcdedit /set {fwbootmgr} displayorder {GUID} /addfirst` puts it back first.

## Updating, repairing, uninstalling

```powershell
# update the files in place (idempotent, no new partition)
.\tools\windows\install-internal.ps1 -PackageDir C:\path\to\package

# repair only the boot entry/order
.\tools\windows\install-internal.ps1 -Repair

# remove the boot entry only (auto-detected)
.\tools\windows\remove-internal.ps1

# remove the entry, delete the partition and grow C: back
.\tools\windows\remove-internal.ps1 -DeletePartition -ExtendSystem
```

A one-off normal boot is always possible by picking **Windows Boot Manager** in the
firmware boot menu (F8 on ASUS boards). If Windows still starts fine but the card is
locked, see [`troubleshooting.md`](troubleshooting.md). Replacing the GPU requires a
new `PROFILE.BIN` captured on this machine.

## Notes on the partition

| | |
|---|---|
| size | 512 MB by default (`-SizeMB`) |
| filesystem | FAT32 |
| GPT type | `c12a7328-f81f-11d2-ba4b-00a0c93ec93b` (EFI System Partition) |
| drive letter | removed after installation |
| GPT attributes | `0x8000000000000000` (no automount) |
| boot entry | `RTX30 UNLOCK`, device = that partition, path = `\EFI\BOOT\BOOTX64.EFI` |

The partition is hidden from Explorer (no drive letter) but visible in Disk Management
as a 512 MB "EFI System Partition". To inspect it, mount it temporarily from an
elevated shell and unmount afterwards:

```powershell
mountvol X: \\?\Volume{YOUR-GUID}\
dir X:\RTX-UNLOCK\RUN*
mountvol X: /P
```

The application accepts a boot volume if it is a USB device **or** a GPT ESP
(`GU_SSD_EXPERIMENT` build flag), which is why the partition uses the ESP type GUID.
