<#
.SYNOPSIS
    Remove the "RTX30 UNLOCK" UEFI boot entry created by install-internal.ps1.

.DESCRIPTION
    Deletes the firmware boot entry. With -DeletePartition it also deletes the
    hidden ESP-type FAT32 partition that holds the unlocker; the freed space is
    left unallocated unless -ExtendSystem is given. With -ExtendSystem the system
    volume is grown back over that free space when it is adjacent.

    The entry is located automatically by its description when -EntryGuid is
    omitted. Only entries whose description contains "RTX30 UNLOCK" are deleted
    automatically; a GUID passed explicitly is checked against
    {bootmgr}/{current} and refused.

    The Windows ESP, the Windows Boot Manager entry and the C: volume's data
    are never touched.

.PARAMETER EntryGuid
    GUID of the boot entry to delete (as printed by install-internal.ps1).
    When omitted the entry is looked up by description "RTX30 UNLOCK".

.PARAMETER DeletePartition
    Also delete the package partition (found by volume label).

.PARAMETER VolumeLabel
    FAT32 label of the partition to delete. Default RTX30UNLOCK.

.PARAMETER ExtendSystem
    After deleting the partition, grow the system volume back over the free
    space (only works when the free space is adjacent to C:).

.PARAMETER DryRun
    Print what would be done and exit. Works without elevation.

.PARAMETER BackupDir
    Where the BCD export is stored. Default: %ProgramData%\rtx30-unlock

.PARAMETER LogPath
    Transcript of this run. Default: %TEMP%\rtx30-remove-<timestamp>.log

.EXAMPLE
    .\remove-internal.ps1 -DryRun
    .\remove-internal.ps1
    .\remove-internal.ps1 -DeletePartition -ExtendSystem

.NOTES
    Requires an elevated PowerShell for anything except -DryRun.
#>
[CmdletBinding()]
param(
    [string]$EntryGuid,
    [switch]$DeletePartition,
    [string]$VolumeLabel = 'RTX30UNLOCK',
    [switch]$ExtendSystem,
    [switch]$DryRun,
    [string]$BackupDir,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rtx30-common.ps1')

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $BackupDir) { $BackupDir = Join-Path $env:ProgramData 'rtx30-unlock' }
if (-not $LogPath) { $LogPath = Join-Path $env:TEMP ('rtx30-remove-' + $timestamp + '.log') }
Initialize-Rtx30Log $LogPath
Write-Rtx30Info ('log: ' + $LogPath)

$isAdmin = Test-Rtx30Admin
$volumes = @(Get-Rtx30UnlockVolumes $VolumeLabel)
$volume = if ($volumes.Count -eq 1) { $volumes[0] } else { $null }
$partition = if ($volume) { Get-Rtx30VolumePartition $volume } else { $null }

# Describe what will happen (also used by -DryRun).
$targetGuid = $EntryGuid
$entry = $null
if ($isAdmin) {
    $entry = Get-Rtx30BootEntry
    if (-not $targetGuid -and $entry.found) { $targetGuid = $entry.guid }
}

$plan = New-Object System.Collections.Generic.List[string]
if ($targetGuid) {
    $plan.Add('delete firmware boot entry ' + $targetGuid)
} elseif ($isAdmin) {
    $plan.Add('no "RTX30 UNLOCK" boot entry found - nothing to delete')
} else {
    $plan.Add('boot entry: needs elevation to inspect')
}
if ($DeletePartition) {
    if ($volumes.Count -gt 1) {
        $plan.Add(('ERROR: {0} volumes labelled {1} exist - resolve manually' -f $volumes.Count, $VolumeLabel))
    } elseif ($volume) {
        $plan.Add(('delete volume {0} (disk {1} partition {2}, {3:N0} MB) labelled {4}' -f $volume.DeviceID, $partition.DiskNumber, $partition.PartitionNumber, ($volume.Capacity / 1MB), $VolumeLabel))
        if ($ExtendSystem) { $plan.Add('extend ' + $env:SystemDrive + ' over the freed space (if adjacent)') }
    } else {
        $plan.Add(('no volume labelled ' + $VolumeLabel + ' found - nothing to delete'))
    }
} elseif ($ExtendSystem) {
    $plan.Add('-ExtendSystem requires -DeletePartition; ignored')
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN - nothing will be changed.' -ForegroundColor Cyan
    foreach ($line in $plan) { Write-Host ('  * ' + $line) }
    Write-Host ('  BCD backup directory: ' + $BackupDir)
    Write-Host ''
    exit 0
}

if (-not $isAdmin) { Fail-Rtx30 'run this script from an elevated PowerShell (Administrator). -DryRun works without elevation.' }

# Refuse obviously wrong targets.
if ($targetGuid -and -not $entry.found) {
    # An explicit GUID that is not one of ours: only allow it if the caller really means it.
    $all = & bcdedit /enum all 2>&1 | Out-String
    foreach ($block in ($all -split '(?:\r?\n){2,}')) {
        if ($block -notmatch [regex]::Escape($targetGuid)) { continue }
        if ($block -match 'bootmgfw\.efi' -or $block -match '\{bootmgr\}') {
            Fail-Rtx30 ('refusing to delete ' + $targetGuid + ' because it looks like the Windows Boot Manager entry.')
        }
        if ($block -notmatch 'RTX30 UNLOCK') {
            Fail-Rtx30 ('refusing to delete ' + $targetGuid + ': its description does not contain "RTX30 UNLOCK".')
        }
        break
    }
}
if (-not $targetGuid -and -not ($DeletePartition -and $volume)) {
    Write-Rtx30Info 'nothing to do (no RTX30 UNLOCK boot entry and no partition selected).'
    exit 0
}

# BCD backup before changing anything.
if ($targetGuid) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $bcdBackup = Join-Path $BackupDir ('bcd-backup-before-remove-' + $timestamp + '.bcd')
    & bcdedit /export "$bcdBackup" | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail-Rtx30 'bcdedit /export failed; refusing to modify the boot configuration.' }
    Write-Rtx30Info ('BCD backup: ' + $bcdBackup)

    Write-Rtx30Step ('deleting boot entry ' + $targetGuid)
    if (-not (Remove-Rtx30BootEntry $targetGuid)) {
        Fail-Rtx30 ('bcdedit /delete ' + $targetGuid + ' failed.')
    }
    $verify = Get-Rtx30BootEntry
    if ($verify.found -and $verify.guid -eq $targetGuid) {
        Fail-Rtx30 'the boot entry still exists after bcdedit /delete.'
    }
    Write-Rtx30Info 'boot entry deleted and verified'
}

if ($DeletePartition) {
    if ($volumes.Count -ne 1) {
        Fail-Rtx30 ('expected exactly one volume labelled ' + $VolumeLabel + ', found ' + $volumes.Count + '.')
    }
    $partition = Get-Rtx30VolumePartition $volume
    if (-not $partition) { Fail-Rtx30 'cannot map the volume to a partition.' }
    $fresh = Get-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -ErrorAction Stop
    if ($fresh.IsBoot) { Fail-Rtx30 'the partition is marked as the boot partition; refusing to delete it.' }

    Write-Rtx30Step ('deleting disk {0} partition {1} ({2:N0} MB, label {3})' -f $partition.DiskNumber, $partition.PartitionNumber, ($fresh.Size / 1MB), $VolumeLabel)
    Remove-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 1
    if (Get-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -ErrorAction SilentlyContinue) {
        Fail-Rtx30 'the partition still exists after Remove-Partition.'
    }
    Write-Rtx30Info 'partition deleted'

    if ($ExtendSystem) {
        Write-Rtx30Step ('extending ' + $env:SystemDrive + ' over the freed space')
        try {
            $supported = Get-PartitionSupportedSize -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
            Resize-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -Size $supported.SizeMax -ErrorAction Stop
            $sys = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
            Write-Rtx30Info ('system volume is now {0:N0} MB' -f ($sys.Size / 1MB))
        } catch {
            Write-Rtx30Warn ('could not extend the system volume automatically: ' + $_.Exception.Message)
            Write-Rtx30Warn 'open Disk Management and extend C: manually (the space is unallocated).'
        }
    } else {
        Write-Rtx30Info 'the freed space is unallocated; use -ExtendSystem next time or extend C: in Disk Management.'
    }
}

Write-Host ''
Write-Host 'Removed.' -ForegroundColor Green
foreach ($line in $plan) { Write-Host ('  * ' + $line) }
Write-Host ('  log: ' + $LogPath)
Write-Host ''
Write-Host 'Windows now boots directly through Windows Boot Manager again.'
Write-Host ''
Write-Rtx30Log 'DONE OK'
exit 0
