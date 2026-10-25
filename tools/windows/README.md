# tools/windows

PowerShell helpers for the alternative "no USB stick" installation described in
[`docs/windows-internal-install.md`](../../docs/windows-internal-install.md).
All scripts are Windows PowerShell 5.1 compatible; only `-DryRun` works without
elevation (everything else needs an elevated shell).

| script | purpose | elevation |
|---|---|---|
| `status.ps1` | read-only check: Secure Boot, hidden partition, `{fwbootmgr}` order, sleep/resume history, benchmark verdict (`-Deep` also hashes the installed EFI and reads the newest `RUNnn` log) | boot-entry checks and `-Deep` need it |
| `install-internal.ps1` | verify package → (create or update) hidden ESP-type FAT32 partition → copy + verify → `RTX30 UNLOCK` boot entry first → hide. Idempotent: an existing `RTX30UNLOCK` volume is updated in place, no second partition | yes |
| `remove-internal.ps1` | delete the boot entry (auto-detected) and optionally the partition; `-ExtendSystem` grows `C:` back over the freed space | yes |
| `rtx30-common.ps1` | shared helpers (volumes, BCD parsing, SHA256SUMS verification, Secure Boot, logging) - dot-sourced by the scripts above, not meant to be run directly | - |
| `disable-fast-startup.ps1` | turn Windows Fast Startup off (or back on with `-Enable`), so "shut down" is a real cold boot and re-runs the unlocker; `-DryRun` works unelevated | yes |

`install-internal.ps1` parameters:

| parameter | meaning |
|---|---|
| `-PackageDir <dir>` | folder with `EFI\BOOT\BOOTX64.EFI` and `RTX-UNLOCK\ASSETS\` (required unless `-Repair`) |
| `-SizeMB` | new partition size, default 512 (ignored for updates) |
| `-Label` | volume label used to recognise the installation, default `RTX30UNLOCK` |
| `-SkipHide` | keep the drive letter (debugging) |
| `-Repair` | only fix the boot entry/order, do not copy files |
| `-DryRun` | print the plan and exit; no changes, no elevation needed |
| `-Force` | continue on `-ExpectedEfiSha256` mismatch |
| `-ExpectedEfiSha256` | expected EFI hash (see the build output) |
| `-BackupDir` | BCD export + previous-EFI backup location (default `%ProgramData%\rtx30-unlock`) |
| `-LogPath` | run log (default `%TEMP%\rtx30-install-<timestamp>.log`) |

`remove-internal.ps1` parameters: `-EntryGuid` (optional; auto-detected by the
`RTX30 UNLOCK` description), `-DeletePartition`, `-VolumeLabel`, `-ExtendSystem`,
`-DryRun`, `-BackupDir`, `-LogPath`.

`status.ps1` parameters: `-Json`, `-NoBench`, `-DllDir`, `-Size`, `-Iters`,
`-UnlockedMin` (default 34), `-LockedMax` (default 28), `-ExpectedEfiSha256`,
`-Deep`, `-FixBootOrder` (writes NVRAM: moves the entry back to first).
Exit codes: `0` unlocked, `1` locked, `2` unknown.

Example package layout (`-PackageDir`):

```
package\
  EFI\BOOT\BOOTX64.EFI          <- bun run build
  RTX-UNLOCK\
    ASSETS\                     <- bun run firmware:assets (5 payloads + NVIDIA-LICENSE)
    PROFILE.BIN                 <- captured on this machine (never reuse another one)
    DEBUG.ON                    <- optional; deleting it also disables RUNnn logging
  SHA256SUMS.txt                <- written by build-from-upstream.ps1
```

Diagnosis, recovery and error codes: [`docs/troubleshooting.md`](../../docs/troubleshooting.md).
