<#
.SYNOPSIS
    Turn Windows Fast Startup off (or back on) so that "shut down" is a real
    cold boot - which re-runs the RTX30 unlocker.

.DESCRIPTION
    With Fast Startup enabled (HiberbootEnabled=1, the Windows default) the Start
    menu's "Shut down" hibernates the kernel and the next power-on resumes it. The
    firmware still runs the unlocker, but the resume path can restore the GPU rate
    selectors in the locked state, which looks like "shutting down and powering on
    did not help". See docs/troubleshooting.md section 4.

    Disabling Fast Startup makes every "shut down" a cold boot. It costs a little
    boot time; Windows Update/restart behaviour is unaffected.

.PARAMETER Enable
    Re-enable Fast Startup (value 1, the Windows default).

.PARAMETER DryRun
    Print the planned change and the current value without modifying anything.
    Works without elevation.

.EXAMPLE
    .\disable-fast-startup.ps1 -DryRun
    .\disable-fast-startup.ps1
    .\disable-fast-startup.ps1 -Enable

.NOTES
    Requires an elevated PowerShell (except -DryRun). Reboot for the change to
    take effect.
#>
[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$valueName = 'HiberbootEnabled'
$targetValue = if ($Enable) { 1 } else { 0 }
$targetText = if ($Enable) { 'enable Fast Startup (Windows default)' } else { 'disable Fast Startup (real cold boots)' }

$current = $null
try {
    $current = (Get-ItemProperty -Path $keyPath -Name $valueName -ErrorAction Stop).$valueName
} catch {
    $current = $null
}

Write-Host ''
Write-Host '=== Fast Startup (HiberbootEnabled) ==='
Write-Host ('  current value : ' + $(if ($null -eq $current) { 'not set (Windows default = 1, enabled)' } else { $current }))
Write-Host ('  planned value : ' + $targetValue + '  (' + $targetText + ')')

if ($DryRun) {
    Write-Host ''
    Write-Host 'DRY RUN - nothing will be changed.' -ForegroundColor Cyan
    Write-Host ''
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host 'ERROR: run this script from an elevated PowerShell (Administrator). -DryRun works without elevation.' -ForegroundColor Red
    exit 1
}

New-Item -Path $keyPath -Force | Out-Null
Set-ItemProperty -Path $keyPath -Name $valueName -Value $targetValue -Type DWord
$verify = (Get-ItemProperty -Path $keyPath -Name $valueName).$valueName
Write-Host ('  new value     : ' + $verify)

if ($verify -eq $targetValue) {
    Write-Host ''
    Write-Host 'Done. Reboot for the change to take effect.' -ForegroundColor Green
    Write-Host 'With Fast Startup off, every "Shut down" is a cold boot and re-runs the unlocker.'
    exit 0
}

Write-Host 'ERROR: the registry value did not change as expected.' -ForegroundColor Red
exit 1
