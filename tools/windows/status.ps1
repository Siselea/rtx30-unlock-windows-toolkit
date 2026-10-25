<#
.SYNOPSIS
    Check the RTX30 unlock installation and whether the unlock is active right now.

.DESCRIPTION
    Answers the two questions that matter after installing the toolkit:

      1. Is the unlocker installed and first in the UEFI boot order?
      2. Is the GPU actually unlocked on this boot?

    It inspects the hidden RTX30UNLOCK FAT32 volume, the firmware boot entry
    (elevated only), the sleep/resume history since boot and runs the cuBLAS
    FP16 -> FP32-accumulate benchmark (tools/bench/fp16_gemm_bench.ps1) to tell
    "unlocked" from "locked".

    Known behaviour this check exists for: sleep/hibernate can reset the rate
    selectors even though the installation is fine, so after a resume the card
    is locked again until the next cold boot. The script detects that case and
    says so instead of blaming the installation.

    Most checks work without administrator rights; boot-entry inspection and
    verification of the hidden partition report "unknown" and print the exact
    elevated commands when they are needed. Nothing is modified unless
    -FixBootOrder is passed.

.PARAMETER Json
    Emit one JSON object instead of the human-readable report.

.PARAMETER NoBench
    Skip the cuBLAS benchmark (fast structural check only).

.PARAMETER DllDir
    Passed to the benchmark: folder containing cudart64_*.dll / cublas64_*.dll.

.PARAMETER Size
    GEMM size for the benchmark (default 4096).

.PARAMETER Iters
    Timed iterations (default 30; the Python benchmark defaults to 50).

.PARAMETER UnlockedMin
    TFLOPS threshold for "unlocked" (default 34, RTX 3060 12 GB calibration).

.PARAMETER LockedMax
    TFLOPS threshold for "locked" (default 28, RTX 3060 12 GB calibration).

.PARAMETER ExpectedEfiSha256
    Expected SHA256 of the installed EFI\BOOT\BOOTX64.EFI. Only used by
    -Deep; when it does not match, the warning says the hidden partition holds
    a different build than expected.

.PARAMETER Deep
    Elevated only: also mount the hidden partition read-only, hash its
    EFI\BOOT\BOOTX64.EFI and report the newest RUNnn probe log (if DEBUG.ON
    was present during a boot). Nothing is modified; the temporary drive
    letter is removed again.

.PARAMETER FixBootOrder
    Elevated only: if the RTX30 UNLOCK entry exists but is not first, move it
    back to the top with `bcdedit /set {fwbootmgr} displayorder <GUID> /addfirst`.

.EXAMPLE
    .\status.ps1
    .\status.ps1 -Json
    .\status.ps1 -NoBench
    .\status.ps1 -FixBootOrder        # elevated

.NOTES
    Exit codes: 0 = unlocked, 1 = locked (see recommendations), 2 = unknown
    (no benchmark result / installation missing / failed to run).
    Requires Windows PowerShell 5.1+ (or PowerShell 7).
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$NoBench,
    [string]$DllDir,
    [int]$Size = 4096,
    [int]$Iters = 30,
    [double]$UnlockedMin = 34.0,
    [double]$LockedMax = 28.0,
    [string]$ExpectedEfiSha256,
    [switch]$Deep,
    [switch]$FixBootOrder
)

$ErrorActionPreference = 'Stop'

$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Recommendations = New-Object System.Collections.Generic.List[string]
function Add-Warning([string]$m) { $script:Warnings.Add($m) }
function Add-Recommendation([string]$m) { $script:Recommendations.Add($m) }

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-GpuInfo {
    $info = [ordered]@{
        name    = $null
        driver  = $null
        vbios   = $null
        pci_bus = $null
        memory  = $null
    }
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        $out = & nvidia-smi --query-gpu=name,driver_version,vbios_version,pci.bus_id,memory.total --format=csv,noheader 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $parts = ($out | Select-Object -First 1) -split '\s*,\s*'
            if ($parts.Count -ge 5) {
                $info.name = $parts[0]
                $info.driver = $parts[1]
                $info.vbios = $parts[2]
                $info.pci_bus = $parts[3]
                $info.memory = $parts[4]
                return [pscustomobject]$info
            }
        }
    }
    $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if ($vc) {
        $info.name = $vc.Name
        $info.driver = $vc.DriverVersion
        $info.memory = if ($vc.AdapterRAM -gt 0) { ('{0:N0} MiB' -f ($vc.AdapterRAM / 1MB)) } else { $null }
    }
    return [pscustomobject]$info
}

function Get-InstallState {
    $state = [ordered]@{
        partition_found   = $false
        volume_label      = $null
        volume_guid       = $null
        partition_number  = $null
        disk_number       = $null
        size_mb           = $null
        boot_entry_found  = $null   # $null = unknown (needs admin)
        boot_entry_guid   = $null
        boot_entry_first  = $null
        boot_entry_device = $null
        boot_entry_path   = $null
    }

    # The hidden partition is not mounted, but Win32_Volume still enumerates it.
    $volumes = Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.Label -eq 'RTX30UNLOCK' }
    if ($volumes) {
        $v = @($volumes)[0]
        $state.partition_found = $true
        $state.volume_label = $v.Label
        $state.volume_guid = $v.DeviceID
        $state.size_mb = [math]::Round($v.Capacity / 1MB, 0)
        $m = [regex]::Match([string]$v.DeviceID, '\{([0-9a-fA-F-]{36})\}')
        if ($m.Success) {
            $volumeGuid = $m.Groups[1].Value
            $part = Get-Partition -ErrorAction SilentlyContinue |
                Where-Object { $_.Guid -and ($_.Guid.Trim('{', '}') -eq $volumeGuid) } |
                Select-Object -First 1
            if ($part) {
                $state.partition_number = $part.PartitionNumber
                $state.disk_number = $part.DiskNumber
            }
        }
    }

    if (-not (Test-Admin)) { return [pscustomobject]$state }

    $all = & bcdedit /enum all 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Add-Warning 'bcdedit /enum all failed even though the shell is elevated.'
        $state.boot_entry_found = $null
        return [pscustomobject]$state
    }
    $guidPattern = '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
    foreach ($block in ($all -split '(?:\r?\n){2,}')) {
        if ($block -notmatch 'RTX30 UNLOCK') { continue }
        $g = [regex]::Match($block, $guidPattern)
        if (-not $g.Success) { continue }
        $state.boot_entry_found = $true
        $state.boot_entry_guid = $g.Value
        $dev = [regex]::Match($block, 'partition=([^\s]+)')
        if ($dev.Success) { $state.boot_entry_device = $dev.Groups[1].Value }
        $path = [regex]::Match($block, '(\\EFI\\[^\s]+)')
        if ($path.Success) { $state.boot_entry_path = $path.Groups[1].Value }
        break
    }
    if (-not $state.boot_entry_found) { $state.boot_entry_found = $false }

    $fw = & bcdedit /enum '{fwbootmgr}' 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $state.boot_entry_guid) {
        $tokens = [regex]::Matches($fw, '\{[^{}]+\}') | ForEach-Object { $_.Value }
        $order = @($tokens | Where-Object { $_ -ne '{fwbootmgr}' })
        if ($order.Count -gt 0) {
            $state.boot_entry_first = ($order[0] -eq $state.boot_entry_guid)
        }
    }
    return [pscustomobject]$state
}

function Get-PowerHistory([datetime]$bootTime) {
    $result = [ordered]@{ slept_since_boot = $false; events = @() }
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            Id        = 42, 107, 506, 507
            StartTime = $bootTime
        } -ErrorAction SilentlyContinue)
    } catch { }
    try {
        $events += @(Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = 'Microsoft-Windows-Power-Troubleshooter'
            StartTime    = $bootTime
        } -ErrorAction SilentlyContinue)
    } catch { }
    foreach ($e in @($events)) {
        if ($e.Id -in 42, 506, 107, 507) { $result.slept_since_boot = $true }
        $result.events += ('{0:yyyy-MM-dd HH:mm:ss} {1} {2}' -f $e.TimeCreated, $e.ProviderName, $e.Id)
    }
    return [pscustomobject]$result
}

function Get-InstalledFilesState([string]$ExpectedSha256) {
    $result = [ordered]@{
        available           = $false
        reason              = $null
        efi_sha256          = $null
        efi_matches_expected = $null
        run_count           = 0
        latest_run          = $null
        latest_run_time     = $null
        ran_this_boot       = $null
    }
    if (-not (Test-Admin)) {
        $result.reason = 'needs elevation (-Deep mounts the hidden partition)'
        return [pscustomobject]$result
    }
    $vols = @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.Label -eq 'RTX30UNLOCK' })
    if ($vols.Count -ne 1) {
        $result.reason = ('expected one RTX30UNLOCK volume, found {0}' -f $vols.Count)
        return [pscustomobject]$result
    }
    $volumeGuid = ([regex]::Match([string]$vols[0].DeviceID, '\{([0-9a-fA-F-]{36})\}')).Groups[1].Value
    $part = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.Guid -and ($_.Guid.Trim('{', '}') -eq $volumeGuid) } |
        Select-Object -First 1
    if (-not $part) {
        $result.reason = 'cannot map the RTX30UNLOCK volume to a partition'
        return [pscustomobject]$result
    }
    $letter = $null
    $added = $false
    try {
        $current = Get-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber
        if ($current.DriveLetter) {
            $letter = [string]$current.DriveLetter
        } else {
            Add-PartitionAccessPath -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -AssignDriveLetter -ErrorAction Stop
            $added = $true
            for ($i = 0; $i -lt 40; $i++) {
                $current = Get-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -ErrorAction SilentlyContinue
                if ($current -and $current.DriveLetter) { $letter = [string]$current.DriveLetter; break }
                Start-Sleep -Milliseconds 250
            }
        }
        if (-not $letter) { $result.reason = 'could not mount the hidden partition'; return [pscustomobject]$result }
        $root = $letter + ':\'
        $efi = Join-Path $root 'EFI\BOOT\BOOTX64.EFI'
        if (Test-Path -LiteralPath $efi) {
            $result.efi_sha256 = (Get-FileHash -LiteralPath $efi -Algorithm SHA256).Hash.ToLower()
            if ($ExpectedSha256) {
                $result.efi_matches_expected = ($result.efi_sha256 -eq $ExpectedSha256.Trim().ToLower())
            }
        }
        $unlockDir = Join-Path $root 'RTX-UNLOCK'
        if (Test-Path -LiteralPath $unlockDir) {
            $runs = @(Get-ChildItem -LiteralPath $unlockDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^RUN\d\d$' } | Sort-Object Name)
            $result.run_count = $runs.Count
            if ($runs.Count -gt 0) {
                $latest = $runs[-1]
                $result.latest_run = $latest.Name
                $result.latest_run_time = $latest.LastWriteTime.ToString('o')
                if ($bootTime) {
                    $result.ran_this_boot = ($latest.LastWriteTime -ge $bootTime.AddMinutes(-2))
                }
            }
        }
        $result.available = $true
    } catch {
        $result.reason = $_.Exception.Message
    } finally {
        if ($added -and $letter) {
            try {
                Remove-PartitionAccessPath -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -AccessPath ($letter + ':\') -ErrorAction SilentlyContinue
            } catch { }
        }
    }
    return [pscustomobject]$result
}

function Invoke-Bench {
    $bench = Join-Path (Split-Path -Parent $PSScriptRoot) 'bench\fp16_gemm_bench.ps1'
    if (-not (Test-Path -LiteralPath $bench)) {
        return [pscustomobject]@{ ok = $false; error = "benchmark script not found: $bench" }
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bench, '-Json',
        '-Size', $Size, '-Iters', $Iters,
        '-UnlockedMin', $UnlockedMin, '-LockedMax', $LockedMax)
    if ($DllDir) { $argList += @('-DllDir', $DllDir) }
    $raw = & powershell.exe @argList 2>&1 | Out-String
    $line = ($raw -split '\r?\n' | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1)
    if (-not $line) {
        return [pscustomobject]@{ ok = $false; error = ($raw.Trim() -replace '\s+', ' ') }
    }
    try { return ($line | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ ok = $false; error = "cannot parse benchmark output: $line" } }
}

function Get-SecureBootState {
    if (-not (Test-Admin)) { return $null }
    try {
        if (Get-Command Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) {
            return [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
        }
    } catch { }
    return $null
}

# --- collect -----------------------------------------------------------------
$isAdmin = Test-Admin
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$bootTime = if ($os) { $os.LastBootUpTime } else { $null }
$uptimeMin = if ($bootTime) { [math]::Round(((Get-Date) - $bootTime).TotalMinutes, 1) } else { $null }
$gpu = Get-GpuInfo
$install = Get-InstallState
$installedFiles = if ($Deep) { Get-InstalledFilesState $ExpectedEfiSha256 } else { $null }
$power = if ($bootTime) { Get-PowerHistory $bootTime } else { [pscustomobject]@{ slept_since_boot = $false; events = @() } }
$secureBoot = Get-SecureBootState
$bench = if ($NoBench) { [pscustomobject]@{ ok = $false; error = 'skipped (-NoBench)' } } else { Invoke-Bench }

# --- diagnose ----------------------------------------------------------------
$verdict = 'unknown'
if ($bench.ok) { $verdict = $bench.verdict }
$status = 'unknown'

if ($verdict -eq 'unlocked') {
    $status = 'unlocked'
} elseif ($verdict -eq 'locked') {
    $status = 'locked'
}

if ($install.partition_found -eq $false) {
    Add-Warning 'The hidden RTX30UNLOCK FAT32 volume was not found on this machine.'
    Add-Recommendation 'Install the unlocker first: tools\windows\install-internal.ps1 -PackageDir <package> (elevated).'
} else {
    if ($install.size_mb -and $install.size_mb -lt 200) {
        Add-Warning ("The RTX30UNLOCK volume is only {0} MB - the package may not fit." -f $install.size_mb)
    }
    if ($isAdmin) {
        if ($install.boot_entry_found -eq $false) {
            Add-Warning 'No "RTX30 UNLOCK" firmware boot entry exists.'
            Add-Recommendation 'Re-create it: tools\windows\install-internal.ps1 -PackageDir <package> -Repair (elevated).'
        } elseif ($install.boot_entry_found -eq $true) {
            if ($install.boot_entry_path -and $install.boot_entry_path -ne '\EFI\BOOT\BOOTX64.EFI') {
                Add-Warning ("The boot entry points at {0} instead of \EFI\BOOT\BOOTX64.EFI." -f $install.boot_entry_path)
            }
            if ($install.boot_entry_first -eq $false) {
                Add-Warning 'The RTX30 UNLOCK entry is not first in the firmware boot order.'
                Add-Recommendation ("Move it back to the top: bcdedit /set {fwbootmgr} displayorder {0} /addfirst" -f $install.boot_entry_guid)
            }
        }
    } else {
        Add-Recommendation 'Run this script elevated to verify the UEFI boot entry and boot order.'
    }
}

if ($secureBoot -eq $true) {
    Add-Warning 'Secure Boot is enabled - the unlocker refuses to run with Secure Boot on.'
    Add-Recommendation 'Disable Secure Boot in the firmware setup (and keep it disabled).'
}

if ($Deep -and $installedFiles) {
    if (-not $installedFiles.available) {
        Add-Warning ('deep inspection of the hidden partition failed: ' + $installedFiles.reason)
    } else {
        if ($ExpectedEfiSha256 -and $installedFiles.efi_matches_expected -eq $false) {
            Add-Warning 'the installed BOOTX64.EFI does not match the expected SHA256 (another build may have been copied).'
        }
        if ($installedFiles.ran_this_boot -eq $false) {
            Add-Warning 'no RUNnn probe log from this boot: either DEBUG.ON is absent (logging is off) or the unlocker did not run.'
        }
    }
}

if ($verdict -eq 'locked') {
    if ($power.slept_since_boot) {
        Add-Recommendation (('Sleep/hibernate happened after the last cold boot ({0} power event(s)). ' +
            'That resets the rate selectors: reboot to restore the unlock, and avoid sleep while the unlocked rate matters.') -f $power.events.Count)
    } else {
        Add-Recommendation 'This boot did not go through the unlocker. Check the firmware boot order (F2/DEL at POST), or run status.ps1 elevated to inspect the boot entry.'
    }
} elseif ($verdict -eq 'unlocked') {
    if ($power.slept_since_boot) {
        Add-Warning 'The card is unlocked now, but sleep/resume happened after boot - the selectors usually reset. Re-check if performance drops.'
    }
} elseif ($NoBench) {
    Add-Recommendation 'Benchmark skipped (-NoBench); rerun without -NoBench for the unlock verdict.'
} elseif ($bench.ok -eq $false) {
    Add-Warning ("Benchmark did not run: {0}" -f $bench.error)
    Add-Recommendation 'Run tools\bench\fp16_gemm_bench.ps1 -DllDir <folder with cudart64_*.dll and cublas64_*.dll> manually.'
} else {
    Add-Recommendation ('TFLOPS is between the locked and unlocked thresholds. Run the 50-iteration benchmark ' +
        '(fp16_gemm_bench.ps1 with -Iters 50) or set -UnlockedMin/-LockedMax for this GPU model.')
}

if ($FixBootOrder -and $isAdmin -and $install.boot_entry_found -eq $true -and $install.boot_entry_first -eq $false) {
    & bcdedit /set '{fwbootmgr}' displayorder $install.boot_entry_guid /addfirst | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-Recommendation ("Boot order repaired: RTX30 UNLOCK ({0}) is first again." -f $install.boot_entry_guid)
        $install.boot_entry_first = $true
    } else {
        Add-Warning 'bcdedit /addfirst failed.'
    }
} elseif ($FixBootOrder) {
    Add-Warning '-FixBootOrder had nothing to do (not elevated, entry missing, or already first).'
}

$exitCode = switch ($verdict) {
    'unlocked' { 0 }
    'locked'   { 1 }
    default    { 2 }
}

# --- output ------------------------------------------------------------------
if ($Json) {
    [pscustomobject]@{
        ok              = ($verdict -ne 'unknown')
        status          = $status
        admin           = $isAdmin
        timestamp       = (Get-Date).ToString('o')
        last_boot       = if ($bootTime) { $bootTime.ToString('o') } else { $null }
        uptime_minutes  = $uptimeMin
        gpu             = $gpu
        install         = $install
        installed_files = $installedFiles
        power           = $power
        secure_boot     = $secureBoot
        bench           = $bench
        warnings        = @($script:Warnings)
        recommendations = @($script:Recommendations)
        exit_code       = $exitCode
    } | ConvertTo-Json -Depth 6 -Compress
    exit $exitCode
}

Write-Host ''
Write-Host '=== RTX30 unlock status ===' -ForegroundColor Cyan
Write-Host ('shell        : ' + $(if ($isAdmin) { 'elevated' } else { 'user (boot-entry checks need elevation)' }))
if ($gpu.name) {
    Write-Host ("GPU          : {0}" -f $gpu.name)
    Write-Host ("               driver {0}, VBIOS {1}, {2}, {3}" -f $gpu.driver, $gpu.vbios, $gpu.pci_bus, $gpu.memory)
}
if ($bootTime) {
    Write-Host ("last boot    : {0:yyyy-MM-dd HH:mm:ss}  (up {1:N1} min)" -f $bootTime, $uptimeMin)
}
if ($secureBoot -ne $null) {
    Write-Host ("Secure Boot  : " + $(if ($secureBoot) { 'ENABLED (problem)' } else { 'disabled (ok)' }))
}

Write-Host ''
Write-Host 'installation'
if ($install.partition_found) {
    Write-Host ("  hidden ESP : found  {0}  {1} MB  disk {2} partition {3}" -f $install.volume_label, $install.size_mb, $install.disk_number, $install.partition_number)
    Write-Host ("  volume     : {0}" -f $install.volume_guid)
} else {
    Write-Host '  hidden ESP : NOT FOUND' -ForegroundColor Red
}
if ($install.boot_entry_found -eq $true) {
    Write-Host ("  boot entry : {0}  first={1}  path={2}" -f $install.boot_entry_guid, $install.boot_entry_first, $install.boot_entry_path)
} elseif ($install.boot_entry_found -eq $false) {
    Write-Host '  boot entry : NOT FOUND' -ForegroundColor Red
} else {
    Write-Host '  boot entry : unknown (run elevated)'
}

if ($installedFiles) {
    Write-Host ''
    Write-Host 'installed files (-Deep)'
    if ($installedFiles.available) {
        Write-Host ('  EFI sha256 : ' + $installedFiles.efi_sha256)
        if ($installedFiles.efi_matches_expected -ne $null) {
            Write-Host ('  expected   : ' + $(if ($installedFiles.efi_matches_expected) { 'match' } else { 'MISMATCH' }))
        }
        if ($installedFiles.latest_run) {
            Write-Host ('  RUN logs   : {0}, newest {1} (this boot: {2})' -f $installedFiles.run_count, $installedFiles.latest_run_time, $installedFiles.ran_this_boot)
        } else {
            Write-Host ('  RUN logs   : none (DEBUG.ON absent or never logged)')
        }
    } else {
        Write-Host ('  unavailable: ' + $installedFiles.reason) -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'current boot'
if ($power.slept_since_boot) {
    Write-Host '  sleep/resume happened after this boot -> unlock selectors are very likely reset.' -ForegroundColor Yellow
    foreach ($ev in $power.events) { Write-Host ("    " + $ev) }
} else {
    Write-Host '  no sleep/resume since boot.'
}

Write-Host ''
Write-Host 'benchmark (FP16 in / FP32 accumulate, 4096^3)'
if ($bench.ok) {
    $color = switch ($verdict) { 'unlocked' { 'Green' } 'locked' { 'Yellow' } default { 'Yellow' } }
    Write-Host ("  {0:N2} TFLOPS  ->  {1}" -f $bench.tflops, $verdict.ToUpper()) -ForegroundColor $color
    Write-Host ("  thresholds: locked <= {0:N1}, unlocked >= {1:N1} TFLOPS (RTX 3060 calibration)" -f $bench.locked_max, $bench.unlocked_min)
} else {
    Write-Host ("  not available: {0}" -f $bench.error) -ForegroundColor Yellow
}

if ($script:Warnings.Count -gt 0) {
    Write-Host ''
    Write-Host 'warnings' -ForegroundColor Yellow
    foreach ($w in $script:Warnings) { Write-Host ('  ! ' + $w) -ForegroundColor Yellow }
}
if ($script:Recommendations.Count -gt 0) {
    Write-Host ''
    Write-Host 'what to do next' -ForegroundColor Cyan
    foreach ($r in $script:Recommendations) { Write-Host ('  * ' + $r) }
}

Write-Host ''
switch ($status) {
    'unlocked' { Write-Host 'RESULT: UNLOCKED - everything looks right.' -ForegroundColor Green }
    'locked'   { Write-Host 'RESULT: LOCKED - see "what to do next".' -ForegroundColor Yellow }
    default    { Write-Host 'RESULT: UNKNOWN - could not determine the unlock state.' -ForegroundColor Yellow }
}
Write-Host ''
exit $exitCode
