<#
.SYNOPSIS
    Install (or update / repair) the RTX30-unlock UEFI application on a hidden
    internal ESP-type partition and make it the first UEFI boot entry.

.DESCRIPTION
    Creates a small FAT32 partition of type EFI System Partition on the internal
    GPT system disk, copies the unlocker package to it, registers a UEFI boot
    entry pointing at \EFI\BOOT\BOOTX64.EFI and puts that entry first in the
    firmware boot order. The partition is hidden afterwards (no drive letter,
    GPT no-automount attribute), like the Windows ESP.

    The script is idempotent: when a volume labelled RTX30UNLOCK already exists
    it updates the files in place instead of shrinking the disk again, and it
    reuses an existing "RTX30 UNLOCK" boot entry. RUNnn probe logs and a
    previously captured PROFILE.BIN on that partition are preserved.

    The original "Windows Boot Manager" entry is not modified. Secure Boot must
    be disabled.

.PARAMETER PackageDir
    Folder that contains EFI\BOOT\BOOTX64.EFI and RTX-UNLOCK\ASSETS\.
    Required unless -Repair is used.

.PARAMETER SizeMB
    Size of the new partition in MB. Default 512. Ignored when updating an
    existing installation.

.PARAMETER Label
    FAT32 volume label used to recognise the installation. Default RTX30UNLOCK.

.PARAMETER SkipHide
    Keep the drive letter instead of hiding the partition (debugging).
    The boot entry still works; re-run without -SkipHide to hide it.

.PARAMETER Repair
    Do not copy files. Only make sure a boot entry exists, points at the
    hidden partition's \EFI\BOOT\BOOTX64.EFI and is first in the boot order.

.PARAMETER DryRun
    Print the plan (existing installation? shrink size? package hash?) and exit
    without changing anything. Works without administrator rights.

.PARAMETER Force
    Continue when -ExpectedEfiSha256 does not match (not recommended).

.PARAMETER ExpectedEfiSha256
    Optional expected SHA256 of the package's EFI\BOOT\BOOTX64.EFI
    (compare with the hash printed by build-from-upstream.ps1).

.PARAMETER BackupDir
    Where the BCD export and the previous EFI are stored.
    Default: %ProgramData%\rtx30-unlock

.PARAMETER LogPath
    Transcript of this run. Default: %TEMP%\rtx30-install-<timestamp>.log

.EXAMPLE
    .\install-internal.ps1 -PackageDir C:\rtx30-package -DryRun
    .\install-internal.ps1 -PackageDir C:\rtx30-package
    .\install-internal.ps1 -Repair
    .\install-internal.ps1 -PackageDir C:\rtx30-package -ExpectedEfiSha256 48dca891...

.NOTES
    Requires an elevated PowerShell for anything except -DryRun.
    Reversible with remove-internal.ps1. Tested on Windows 11 26300.
#>
[CmdletBinding()]
param(
    [string]$PackageDir,
    [int]$SizeMB = 512,
    [string]$Label = 'RTX30UNLOCK',
    [switch]$SkipHide,
    [switch]$Repair,
    [switch]$DryRun,
    [switch]$Force,
    [string]$ExpectedEfiSha256,
    [string]$BackupDir,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rtx30-common.ps1')

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $BackupDir) { $BackupDir = Join-Path $env:ProgramData 'rtx30-unlock' }
if (-not $LogPath) { $LogPath = Join-Path $env:TEMP ('rtx30-install-' + $timestamp + '.log') }
Initialize-Rtx30Log $LogPath
Write-Rtx30Info ('log: ' + $LogPath)

if ($SizeMB -lt 64) { Fail-Rtx30 '-SizeMB must be at least 64' }

# ---------------------------------------------------------------------------
# package
# ---------------------------------------------------------------------------
$pkg = $null
$pkgEfi = $null
$pkgEfiHash = $null
$pkgAssetFiles = @()
if ($PackageDir) {
    $pkg = (Resolve-Path -LiteralPath $PackageDir).Path
    $pkgEfi = Join-Path $pkg 'EFI\BOOT\BOOTX64.EFI'
    if (-not (Test-Path -LiteralPath $pkgEfi)) {
        Fail-Rtx30 "package is missing EFI\BOOT\BOOTX64.EFI: $pkg"
    }
    $assetsDir = Join-Path $pkg 'RTX-UNLOCK\ASSETS'
    if (-not (Test-Path -LiteralPath $assetsDir)) {
        Fail-Rtx30 "package is missing RTX-UNLOCK\ASSETS: $pkg"
    }
    $pkgAssetFiles = @(Get-ChildItem -LiteralPath $assetsDir -File -Recurse -ErrorAction SilentlyContinue)
    if ($pkgAssetFiles.Count -eq 0) { Fail-Rtx30 "RTX-UNLOCK\ASSETS is empty: $pkg" }
    $pkgEfiHash = (Get-FileHash -LiteralPath $pkgEfi -Algorithm SHA256).Hash.ToLower()
    if ($ExpectedEfiSha256 -and ($pkgEfiHash -ne $ExpectedEfiSha256.Trim().ToLower())) {
        if ($Force) {
            Write-Rtx30Warn ('EFI hash mismatch (expected ' + $ExpectedEfiSha256 + ', got ' + $pkgEfiHash + '); continuing because -Force was given.')
        } else {
            Fail-Rtx30 ('EFI hash mismatch: expected ' + $ExpectedEfiSha256 + ', got ' + $pkgEfiHash + '. Use -Force to override.')
        }
    }
    Write-Rtx30Info ('package    : ' + $pkg)
    Write-Rtx30Info ('EFI sha256 : ' + $pkgEfiHash)
    Write-Rtx30Info ('assets     : ' + $pkgAssetFiles.Count + ' file(s)')
    $manifest = Read-Rtx30Manifest $pkg
    if ($manifest) { Test-Rtx30Manifest $pkg $manifest 'package' }
} elseif (-not $Repair) {
    Fail-Rtx30 '-PackageDir is required unless -Repair is used.'
}

# ---------------------------------------------------------------------------
# system disk
# ---------------------------------------------------------------------------
$sysLetter = $env:SystemDrive.TrimEnd(':')
$sysPart = Get-Partition -DriveLetter $sysLetter -ErrorAction Stop
$disk = Get-Disk -Number $sysPart.DiskNumber -ErrorAction Stop
if ($disk.PartitionStyle -ne 'GPT') { Fail-Rtx30 'the system disk is not GPT; UEFI boot needs a GPT disk.' }
Write-Rtx30Info ('system disk: #{0} {1} ({2:N0} GB, {3})' -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB), $disk.PartitionStyle)

$wantBytes = [uint64]$SizeMB * 1MB
$shrinkableMB = $null
try {
    $sup = Get-PartitionSupportedSize -DriveLetter $sysLetter -ErrorAction Stop
    $shrinkableMB = [math]::Round(($sysPart.Size - $sup.SizeMin) / 1MB, 0)
} catch {
    Write-Rtx30Info 'shrinkable size: unknown (needs elevation or the Storage provider is unavailable)'
}

# ---------------------------------------------------------------------------
# existing installation?
# ---------------------------------------------------------------------------
$volumes = @(Get-Rtx30UnlockVolumes $Label)
$existingVolume = $null
$existingPartition = $null
if ($volumes.Count -gt 1) {
    Fail-Rtx30 ('found {0} volumes labelled {1}; resolve this manually (remove-internal.ps1 -DeletePartition, or rename the stale one).' -f $volumes.Count, $Label)
} elseif ($volumes.Count -eq 1) {
    $existingVolume = $volumes[0]
    $existingPartition = Get-Rtx30VolumePartition $existingVolume
    if (-not $existingPartition) {
        Fail-Rtx30 ('volume ' + $existingVolume.DeviceID + ' is labelled ' + $Label + ' but does not map to a partition.')
    }
    Write-Rtx30Info ('existing install: volume {0} ({1:N0} MB), disk {2} partition {3}' -f $existingVolume.DeviceID, ($existingVolume.Capacity / 1MB), $existingPartition.DiskNumber, $existingPartition.PartitionNumber)
}

$isAdmin = Test-Rtx30Admin

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN - nothing will be changed.' -ForegroundColor Cyan
    if ($existingPartition) {
        Write-Host ('plan: update files in place on disk {0} partition {1} (no shrink).' -f $existingPartition.DiskNumber, $existingPartition.PartitionNumber)
    } elseif ($Repair) {
        Write-Host 'plan: -Repair requested but no RTX30UNLOCK volume exists - nothing to repair.'
    } else {
        Write-Host ('plan: shrink {0}: by {1} MB, create ESP-type FAT32 partition, copy package, add boot entry first.' -f $sysLetter, $SizeMB)
        if ($shrinkableMB -ne $null) {
            Write-Host ('      shrinkable: {0:N0} MB (need {1} MB)' -f $shrinkableMB, $SizeMB)
            if ($shrinkableMB -lt $SizeMB) { Write-Host '      WARNING: not enough shrinkable space.' -ForegroundColor Yellow }
        }
    }
    Write-Host ('plan: boot entry "RTX30 UNLOCK" (create or reuse), displayorder first; partition hidden unless -SkipHide.')
    Write-Host ('plan: BCD backup directory: ' + $BackupDir)
    Write-Host ('plan: elevation required: ' + (-not $isAdmin))
    Write-Host ''
    exit 0
}

if (-not $isAdmin) { Fail-Rtx30 'run this script from an elevated PowerShell (Administrator). -DryRun works without elevation.' }
if ($Repair -and -not $existingPartition) {
    Fail-Rtx30 ('-Repair was requested but no volume labelled ' + $Label + ' exists; run a normal install instead.')
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
$secureBoot = Test-Rtx30SecureBoot
if ($secureBoot -eq $true) {
    Fail-Rtx30 'Secure Boot is enabled. The unlocker refuses to run with Secure Boot on; disable it in the firmware setup first.'
} elseif ($null -eq $secureBoot) {
    Write-Rtx30Warn 'could not read the Secure Boot state; make sure Secure Boot is disabled.'
}
$bitlocker = Get-Rtx30BitLockerState $sysLetter
if ($bitlocker -eq 'On') {
    Write-Rtx30Warn ('BitLocker protection is ON for ' + $sysLetter + ':. Shrinking a BitLocker volume normally works, but keep the recovery key at hand.')
}
$pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                 (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($pendingReboot) { Write-Rtx30Warn 'Windows has a pending reboot; reboot first so the new boot entry is applied cleanly.' }

# ---------------------------------------------------------------------------
# BCD backup
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$bcdBackup = Join-Path $BackupDir ('bcd-backup-' + $timestamp + '.bcd')
& bcdedit /export "$bcdBackup" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail-Rtx30 'bcdedit /export failed; refusing to modify the boot configuration.' }
Write-Rtx30Info ('BCD backup : ' + $bcdBackup)

# ---------------------------------------------------------------------------
# install / update
# ---------------------------------------------------------------------------
$state = @{
    shrunk            = $false
    oldSysSize        = $sysPart.Size
    createdPartition  = $null
    mountLetter       = $null
    createdEntry      = $null
    reusedEntry       = $false
    efiBackupPath     = $null
}
$partition = $null
$letter = $null

try {
    if (-not $existingPartition) {
        if ($shrinkableMB -ne $null -and $shrinkableMB -lt $SizeMB) {
            Fail-Rtx30 ('not enough shrinkable space at the end of {0}: {1} MB available, {2} MB requested.' -f $sysLetter, $shrinkableMB, $SizeMB)
        }
        Write-Rtx30Step ('shrinking {0}: by {1} MB' -f $sysLetter, $SizeMB)
        Resize-Partition -DriveLetter $sysLetter -Size ($state.oldSysSize - $wantBytes) -ErrorAction Stop
        $state.shrunk = $true
        Start-Sleep -Seconds 1

        Write-Rtx30Step 'creating the ESP-type partition'
        $partition = New-Partition -DiskNumber $disk.Number -Size $wantBytes -GptType $script:Rtx30EspTypeGuid -ErrorAction Stop
        $state.createdPartition = $partition
        Start-Sleep -Seconds 1

        $letter = Mount-Rtx30Partition $partition
        $state.mountLetter = $letter
        Write-Rtx30Info ('temporary drive letter: ' + $letter + ':')

        Write-Rtx30Step 'formatting FAT32'
        Format-Volume -DriveLetter $letter -FileSystem FAT32 -NewFileSystemLabel $Label -Confirm:$false -Force -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1
    } else {
        $partition = $existingPartition
        $letter = Mount-Rtx30Partition $partition
        $state.mountLetter = $letter
        $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
        if ($vol.FileSystem -ne 'FAT32') {
            Fail-Rtx30 ('existing ' + $Label + ' partition is ' + $vol.FileSystem + ', expected FAT32.')
        }
        Write-Rtx30Info ('updating the existing installation in place (no shrink, no new partition), letter ' + $letter + ':')
    }

    $root = $letter + ':\'

    if (-not $Repair) {
        # keep a copy of the previous EFI for rollback
        $oldEfi = Join-Path $root 'EFI\BOOT\BOOTX64.EFI'
        if (Test-Path -LiteralPath $oldEfi) {
            $state.efiBackupPath = Join-Path $BackupDir ('efi-backup-' + $timestamp + '.EFI')
            Copy-Item -LiteralPath $oldEfi -Destination $state.efiBackupPath -Force
            Write-Rtx30Info ('previous EFI saved: ' + $state.efiBackupPath)
        }

        Write-Rtx30Step 'copying EFI and package files'
        $efiDir = Join-Path $root 'EFI'
        if (Test-Path -LiteralPath $efiDir) { Remove-Item -LiteralPath $efiDir -Recurse -Force -ErrorAction Stop }
        Copy-Item -LiteralPath (Join-Path $pkg 'EFI') -Destination $root -Recurse -Force -ErrorAction Stop
        $unlockDir = Join-Path $root 'RTX-UNLOCK'
        New-Item -ItemType Directory -Force -Path $unlockDir | Out-Null
        Copy-Item -Path (Join-Path $pkg 'RTX-UNLOCK\*') -Destination $unlockDir -Recurse -Force -ErrorAction Stop

        $writtenEfi = Join-Path $root 'EFI\BOOT\BOOTX64.EFI'
        if (-not (Test-Path -LiteralPath $writtenEfi)) { Fail-Rtx30 'EFI\BOOT\BOOTX64.EFI was not copied.' }
        $writtenHash = (Get-FileHash -LiteralPath $writtenEfi -Algorithm SHA256).Hash.ToLower()
        if ($writtenHash -ne $pkgEfiHash) { Fail-Rtx30 ('copied EFI hash mismatch: ' + $writtenHash + ' != ' + $pkgEfiHash) }

        $copiedAssets = @(Get-ChildItem -LiteralPath (Join-Path $unlockDir 'ASSETS') -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { '{0}|{1}' -f $_.Name, $_.Length } | Sort-Object)
        $expectedAssets = @($pkgAssetFiles | ForEach-Object { '{0}|{1}' -f $_.Name, $_.Length } | Sort-Object)
        $diff = @(Compare-Object -ReferenceObject $expectedAssets -DifferenceObject $copiedAssets)
        if ($diff.Count -gt 0) {
            Fail-Rtx30 ('asset copy mismatch: ' + (($diff | ForEach-Object { $_.InputObject }) -join ', '))
        }
        if (-not (Test-Path -LiteralPath (Join-Path $unlockDir 'PROFILE.BIN'))) {
            Write-Rtx30Warn 'RTX-UNLOCK\PROFILE.BIN not present. The first unlocked boot will capture one; with DEBUG.ON present the tool asks for U once.'
        } else {
            Write-Rtx30Info 'PROFILE.BIN present'
        }
        if ($manifest) { Test-Rtx30Manifest $root $manifest 'copied files' }
        Write-Rtx30Info 'package copied and verified'
    } else {
        Write-Rtx30Step 'repair mode: package files left untouched'
    }

    # --- boot entry ---------------------------------------------------------
    $entry = Get-Rtx30BootEntry
    if ($entry.multiple) {
        Fail-Rtx30 ('multiple "RTX30 UNLOCK" boot entries exist ({0}); clean them up first: tools\windows\remove-internal.ps1 -EntryGuid <guid>' -f (($entry.entries | ForEach-Object { $_.guid }) -join ', '))
    }
    if ($entry.found) {
        $guid = $entry.guid
        $state.reusedEntry = $true
        Write-Rtx30Info ('reusing existing boot entry ' + $guid)
    } else {
        $guid = New-Rtx30BootEntry
        $state.createdEntry = $guid
        Write-Rtx30Info ('created boot entry ' + $guid)
    }
    Write-Rtx30Step 'writing the boot entry and putting it first'
    Set-Rtx30BootEntry -Guid $guid -DriveLetter $letter

    $check = Get-Rtx30BootEntry
    if (-not $check.found) { Fail-Rtx30 'the RTX30 UNLOCK boot entry disappeared after it was written.' }
    if ($check.path -and $check.path -ne $script:Rtx30EfiPath) {
        Fail-Rtx30 ('boot entry path is ' + $check.path + ', expected ' + $script:Rtx30EfiPath)
    }
    if ($check.first -ne $true) { Fail-Rtx30 'the RTX30 UNLOCK entry is not first in the firmware boot order.' }
    Write-Rtx30Info ('boot entry verified: ' + $guid + ' (first, ' + $script:Rtx30EfiPath + ')')

    # --- hide ---------------------------------------------------------------
    if (-not $SkipHide) {
        Write-Rtx30Step 'hiding the partition'
        Dismount-Rtx30Volume $partition $letter
        $state.mountLetter = $null
        Hide-Rtx30Partition $partition
        if (-not (Test-Rtx30PartitionHidden $partition)) {
            Write-Rtx30Warn 'hiding could not be verified; the partition may still be visible in Disk Management.'
        } else {
            Write-Rtx30Info 'partition hidden (no drive letter, GPT no-automount)'
        }
    } else {
        Write-Rtx30Warn ('partition keeps drive letter ' + $letter + ': (-SkipHide).')
    }

    # --- summary ------------------------------------------------------------
    Write-Host ''
    Write-Host 'Installed.' -ForegroundColor Green
    Write-Host ('  boot entry : RTX30 UNLOCK  ' + $guid + '  (first in boot order)')
    Write-Host ('  partition  : disk {0} partition {1} ({2:N0} MB, ESP-type FAT32)' -f $partition.DiskNumber, $partition.PartitionNumber, ($partition.Size / 1MB))
    if ($existingPartition) { Write-Host '  mode       : updated the existing installation in place' }
    Write-Host ('  EFI sha256 : ' + $(if ($pkgEfiHash) { $pkgEfiHash } else { '(repair only - files untouched)' }))
    Write-Host ('  BCD backup : ' + $bcdBackup)
    Write-Host ('  log        : ' + $LogPath)
    Write-Host ''
    Write-Host 'Next steps:'
    Write-Host '  1. Reboot. The unlocker runs first, then Windows.'
    Write-Host '  2. After the reboot run:  .\status.ps1'
    Write-Host '     (elevated for the boot-entry check) and confirm "UNLOCKED".'
    Write-Host ('  3. Rollback if needed:    .\remove-internal.ps1 -EntryGuid ' + $guid)
    Write-Host ''
    Write-Rtx30Log 'DONE OK'
    exit 0
} catch {
    $errorMessage = $_.Exception.Message
    Write-Rtx30Warn ('installation failed: ' + $errorMessage)
    Write-Rtx30Warn 'rolling back...'

    if ($state.mountLetter -and $partition -and $state.efiBackupPath) {
        try {
            Copy-Item -LiteralPath $state.efiBackupPath -Destination (Join-Path ($state.mountLetter + ':\') 'EFI\BOOT\BOOTX64.EFI') -Force -ErrorAction Stop
            Write-Rtx30Warn 'restored the previous EFI on the partition'
        } catch {
            Write-Rtx30Warn ('could not restore the previous EFI: ' + $_.Exception.Message)
        }
    }
    if ($state.mountLetter -and $partition) {
        try { Dismount-Rtx30Volume $partition $state.mountLetter } catch { }
    }
    if ($state.createdEntry) {
        [void](Remove-Rtx30BootEntry $state.createdEntry)
        Write-Rtx30Warn ('removed the boot entry created by this run: ' + $state.createdEntry)
    }
    if ($state.createdPartition) {
        try {
            Remove-Partition -DiskNumber $state.createdPartition.DiskNumber -PartitionNumber $state.createdPartition.PartitionNumber -Confirm:$false -ErrorAction Stop
            Write-Rtx30Warn 'removed the partition created by this run'
        } catch {
            Write-Rtx30Warn ('could not remove the new partition: ' + $_.Exception.Message)
        }
        if ($state.shrunk) {
            try {
                $max = (Get-PartitionSupportedSize -DriveLetter $sysLetter).SizeMax
                Resize-Partition -DriveLetter $sysLetter -Size $max -ErrorAction Stop
                Write-Rtx30Warn ('extended ' + $sysLetter + ': back to its original size')
            } catch {
                Write-Rtx30Warn ('could not extend ' + $sysLetter + ': back: ' + $_.Exception.Message)
            }
        }
    }
    Write-Rtx30Warn ('BCD backup kept at: ' + $bcdBackup)
    Write-Rtx30Warn ('log: ' + $LogPath)
    exit 1
}
