<#
.SYNOPSIS
    Shared helpers for the RTX30 unlock Windows installation scripts.

.DESCRIPTION
    Dot-source this file from install-internal.ps1 / remove-internal.ps1:

        . "$PSScriptRoot\rtx30-common.ps1"

    Everything here is plain Windows PowerShell 5.1. Functions that only need
    user rights (volume enumeration, BCD lookup) still require elevation for
    bcdedit itself; callers check Test-Rtx30Admin first.
#>

$script:Rtx30EspTypeGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:Rtx30EfiPath = '\EFI\BOOT\BOOTX64.EFI'
$script:Rtx30EntryDescription = 'RTX30 UNLOCK'
$script:Rtx30LogPath = $null

function Test-Rtx30Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-Rtx30Log([string]$path) {
    $script:Rtx30LogPath = $path
    if ($path) {
        $dir = Split-Path -Parent $path
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Set-Content -Path $path -Value ("RTX30 unlock log - " + (Get-Date).ToString('o')) -Encoding utf8
    }
}

function Write-Rtx30Log([string]$message) {
    $line = ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $message)
    if ($script:Rtx30LogPath) { Add-Content -Path $script:Rtx30LogPath -Value $line -Encoding utf8 }
}

function Write-Rtx30Step([string]$message) {
    Write-Rtx30Log ('STEP  ' + $message)
    Write-Host ('==> ' + $message) -ForegroundColor Cyan
}

function Write-Rtx30Info([string]$message) {
    Write-Rtx30Log ('INFO  ' + $message)
    Write-Host ('    ' + $message)
}

function Write-Rtx30Warn([string]$message) {
    Write-Rtx30Log ('WARN  ' + $message)
    Write-Warning $message
}

function Fail-Rtx30([string]$message) {
    Write-Rtx30Log ('ERROR ' + $message)
    throw $message
}

# ---------------------------------------------------------------------------
# volumes / partitions
# ---------------------------------------------------------------------------

function Get-Rtx30UnlockVolumes([string]$Label = 'RTX30UNLOCK') {
    return @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.Label -eq $Label })
}

function Get-Rtx30VolumePartition($Volume) {
    $m = [regex]::Match([string]$Volume.DeviceID, '\{([0-9a-fA-F-]{36})\}')
    if (-not $m.Success) { return $null }
    $guid = $m.Groups[1].Value
    return (Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.Guid -and ($_.Guid.Trim('{', '}') -eq $guid) } |
        Select-Object -First 1)
}

function Get-Rtx30FreeDriveLetter {
    $candidates = @('W', 'X', 'Y', 'V', 'T', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K')
    $mapped = @()
    try { $mapped = @(Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalPath.Substring(0, 1).ToUpper() }) } catch { }
    foreach ($letter in $candidates) {
        if ($mapped -contains $letter) { continue }
        if (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue) { continue }
        if (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue) { continue }
        if (Test-Path -LiteralPath ($letter + ':\')) { continue }
        return $letter
    }
    return $null
}

function Mount-Rtx30Partition($Partition) {
    $current = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -ErrorAction Stop
    if ($current.DriveLetter) { return [string]$current.DriveLetter }
    try {
        Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AssignDriveLetter -ErrorAction Stop
    } catch {
        $fallback = Get-Rtx30FreeDriveLetter
        if (-not $fallback) { Fail-Rtx30 ('could not assign a drive letter: ' + $_.Exception.Message) }
        Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath ($fallback + ':\') -ErrorAction Stop
    }
    for ($i = 0; $i -lt 40; $i++) {
        $current = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -ErrorAction SilentlyContinue
        if ($current -and $current.DriveLetter) { return [string]$current.DriveLetter }
        Start-Sleep -Milliseconds 250
    }
    Fail-Rtx30 'Windows did not assign a drive letter to the partition'
}

function Dismount-Rtx30Volume($Partition, [string]$Letter) {
    if (-not $Letter) { return }
    try {
        Remove-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath ($Letter + ':\') -ErrorAction SilentlyContinue
    } catch {
        Write-Rtx30Warn ('could not remove the temporary drive letter ' + $Letter + ': ' + $_.Exception.Message)
    }
}

function Hide-Rtx30Partition($Partition) {
    $dp = Join-Path $env:TEMP ('rtx30-hide-' + [guid]::NewGuid().ToString('N') + '.dp')
    try {
        @(
            'select disk ' + $Partition.DiskNumber,
            'select partition ' + $Partition.PartitionNumber,
            'gpt attributes=0x8000000000000000',
            'exit'
        ) -join "`r`n" | Set-Content -Path $dp -Encoding ascii
        $out = & diskpart /s $dp 2>&1 | Out-String
        Write-Rtx30Log ('diskpart hide: ' + ($out -replace '\s+', ' '))
        if ($LASTEXITCODE -ne 0) { Fail-Rtx30 'diskpart failed while hiding the partition' }
    } finally {
        Remove-Item $dp -Force -ErrorAction SilentlyContinue
    }
}

function Test-Rtx30PartitionHidden($Partition) {
    $again = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -ErrorAction SilentlyContinue
    if (-not $again) { return $false }
    return (-not $again.DriveLetter -or $again.DriveLetter -eq [char]0) -and [bool]$again.IsHidden
}

# ---------------------------------------------------------------------------
# BCD
# ---------------------------------------------------------------------------

function Get-Rtx30BootEntry([string]$Description = 'RTX30 UNLOCK') {
    $result = [ordered]@{
        found   = $false
        guid    = $null
        device  = $null
        path    = $null
        first   = $null
        raw_all = $null
        raw_fw  = $null
    }
    $all = & bcdedit /enum all 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail-Rtx30 'bcdedit /enum all failed (elevated PowerShell required)' }
    $result.raw_all = $all
    $guidPattern = '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
    foreach ($block in ($all -split '(?:\r?\n){2,}')) {
        if ($block -notmatch [regex]::Escape($Description)) { continue }
        $g = [regex]::Match($block, $guidPattern)
        if (-not $g.Success) { continue }
        $result.found = $true
        $result.guid = $g.Value
        $dev = [regex]::Match($block, 'partition=([^\s]+)')
        if ($dev.Success) { $result.device = $dev.Groups[1].Value }
        $path = [regex]::Match($block, '(\\EFI\\[^\s]+)')
        if ($path.Success) { $result.path = $path.Groups[1].Value }
        break
    }
    $fw = & bcdedit /enum '{fwbootmgr}' 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        $result.raw_fw = $fw
        if ($result.guid) {
            $tokens = @([regex]::Matches($fw, '\{[^{}]+\}') | ForEach-Object { $_.Value } | Where-Object { $_ -ne '{fwbootmgr}' })
            if ($tokens.Count -gt 0) { $result.first = ($tokens[0] -eq $result.guid) }
        }
    }
    return [pscustomobject]$result
}

function New-Rtx30BootEntry([string]$Description = 'RTX30 UNLOCK') {
    $out = & bcdedit /copy '{bootmgr}' /d $Description 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail-Rtx30 ('bcdedit /copy failed: ' + ($out -replace '\s+', ' ')) }
    $m = [regex]::Match($out, '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}')
    if (-not $m.Success) { Fail-Rtx30 ('cannot parse the new boot entry GUID from: ' + ($out -replace '\s+', ' ')) }
    return $m.Value
}

function Set-Rtx30BootEntry([string]$Guid, [string]$DriveLetter, [string]$Description = 'RTX30 UNLOCK') {
    $commands = @(
        @('/set', $Guid, 'device', ('partition=' + $DriveLetter + ':')),
        @('/set', $Guid, 'path', $script:Rtx30EfiPath),
        @('/set', $Guid, 'description', $Description),
        @('/set', '{fwbootmgr}', 'displayorder', $Guid, '/addfirst')
    )
    foreach ($cmd in $commands) {
        $out = & bcdedit @cmd 2>&1 | Out-String
        Write-Rtx30Log ('bcdedit ' + ($cmd -join ' ') + ' -> ' + ($out -replace '\s+', ' ').Trim())
        if ($LASTEXITCODE -ne 0) { Fail-Rtx30 ('bcdedit failed: ' + ($cmd -join ' ')) }
    }
}

function Remove-Rtx30BootEntry([string]$Guid) {
    $out = & bcdedit /delete "$Guid" /f 2>&1 | Out-String
    Write-Rtx30Log ('bcdedit /delete ' + $Guid + ' -> ' + ($out -replace '\s+', ' ').Trim())
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# package integrity (SHA256SUMS.txt written by build-from-upstream.ps1)
# ---------------------------------------------------------------------------

function Read-Rtx30Manifest([string]$PackageDir) {
    $path = Join-Path $PackageDir 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $entries = @{}
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
            $entries[$Matches[2].Trim()] = $Matches[1].ToLower()
        }
    }
    if ($entries.Count -eq 0) { Fail-Rtx30 'SHA256SUMS.txt is present but empty or malformed.' }
    return $entries
}

function Test-Rtx30Manifest([string]$Root, [hashtable]$Manifest, [string]$Label = 'package') {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($relative in $Manifest.Keys) {
        $path = Join-Path $Root ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) {
            $errors.Add('missing: ' + $relative)
            continue
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $Manifest[$relative]) { $errors.Add('hash mismatch: ' + $relative) }
    }
    if ($errors.Count -gt 0) {
        Fail-Rtx30 ($Label + ' integrity check failed: ' + ($errors -join '; '))
    }
    Write-Rtx30Info ($Label + ' manifest verified (' + $Manifest.Count + ' file(s))')
}

function Test-Rtx30SecureBoot {    try {
        if (-not (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue)) { return $null }
        return [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Get-Rtx30BitLockerState([string]$DriveLetter = $null) {
    try {
        if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) { return $null }
        if (-not $DriveLetter) { $DriveLetter = $env:SystemDrive.TrimEnd(':') }
        $vol = Get-BitLockerVolume -MountPoint ($DriveLetter + ':') -ErrorAction Stop
        return [string]$vol.ProtectionStatus
    } catch {
        return $null
    }
}
