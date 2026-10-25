<#
.SYNOPSIS
    Fetch the pinned upstream source, apply the single-display patch, build the EFI
    application, generate the firmware assets and assemble an installable package.

.DESCRIPTION
    This repository does not contain upstream source code or NVIDIA firmware.
    The script clones https://github.com/craftingmod/rtx30-unlock at the pinned commit,
    applies patches/0001-gop-single-display-child.patch, runs the upstream Bun build
    and the upstream firmware asset generator, then assembles:

        <WorkDir>\package\EFI\BOOT\BOOTX64.EFI
        <WorkDir>\package\RTX-UNLOCK\ASSETS\...            (5 generated payloads + license)
        <WorkDir>\package\RTX-UNLOCK\DEBUG.ON              (optional first-run log switch)
        <WorkDir>\package\RTX-UNLOCK\README-PROFILE.txt    (checklist)
        <WorkDir>\package\SHA256SUMS.txt                   (checked by the installer)

    Put the PROFILE.BIN captured on your machine into
    <WorkDir>\package\RTX-UNLOCK\PROFILE.BIN, then install with
    tools\windows\install-internal.ps1 -PackageDir <WorkDir>\package.

.PARAMETER WorkDir
    Working directory. Default: <repo>\build-workspace

.PARAMETER SkipReference
    Do not clone Zagitta/gpu-unlock (reference checkout only).

.PARAMETER InsecureSsl
    Pass -c http.sslVerify=false to git (only for machines with a TLS-intercepting
    proxy that is already trusted by the local Git installation).

.PARAMETER VerifyOnly
    Check prerequisites, the pinned commit, the patch SHA256 and that the patch
    applies cleanly, then exit without building. Useful in CI or before a long
    build.

.NOTES
    Requirements: git, Bun, clang + lld-link (see docs/build.md).
    Tested on Windows 11 with Bun 1.4.x and LLVM/Clang 17-23.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $PSScriptRoot '..\build-workspace'),
    [switch]$SkipReference,
    [switch]$InsecureSsl,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)

$UpstreamUrl     = 'https://github.com/craftingmod/rtx30-unlock.git'
$UpstreamCommit  = '5c076dc4ee7fa369639669fa591ac74d8f6dfcd8'
$ReferenceUrl    = 'https://github.com/Zagitta/gpu-unlock.git'
$ReferenceCommit = '0ebdb1c6308b6a2072be5bf04513472942541956'
$PatchPath       = Join-Path $repoRoot 'patches\0001-gop-single-display-child.patch'
# The patch is part of this repository; this hash detects local edits/corruption.
$PatchSha256     = 'cdc22b6d8c989a4eb08f14e8eadbf5cc2eebedc3461a938db275362e54eeb35f'

function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Info([string]$m) { Write-Host "    $m" }

# Native commands must not become terminating errors under $ErrorActionPreference
# = 'Stop': git writes progress to stderr even on success, and `git apply --check`
# is expected to fail when the patch is not applied yet.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $output = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousEap
    }
    return [pscustomobject]@{
        ExitCode = $code
        Output   = (($output | Out-String).Trim())
    }
}

# Do NOT name this function "Git": PowerShell resolves commands as
# alias > function > cmdlet > application, so "& git" inside a function named Git
# would recurse forever. $GitArgs also avoids the automatic $Args variable.
function Invoke-Git {
    param([string[]]$GitArgs)
    $prefix = if ($InsecureSsl) { @('-c', 'http.sslVerify=false') } else { @() }
    return Invoke-Native -FilePath 'git.exe' -Arguments @($prefix + $GitArgs)
}

# --- prerequisites -----------------------------------------------------------
Step 'checking prerequisites'
$requiredTools = if ($VerifyOnly) { @('git') } else { @('git', 'bun', 'clang', 'lld-link') }
foreach ($tool in $requiredTools) {
    $command = Get-Command $tool -ErrorAction SilentlyContinue
    if (-not $command) {
        Fail "$tool not found in PATH. See docs/build.md (clang/lld-link must be on PATH; LLVM_BIN is only read by upstream's build.ts)."
    }
    Info ("{0}: {1}" -f $tool, $command.Source)
}
$bunExe = $null
if (-not $VerifyOnly) { $bunExe = (Get-Command bun).Source }

if (-not (Test-Path $PatchPath)) { Fail "patch not found: $PatchPath" }
$patchHash = (Get-FileHash $PatchPath -Algorithm SHA256).Hash.ToLower()
if ($patchHash -ne $PatchSha256) {
    Fail ("patch sha256 is $patchHash, expected $PatchSha256 - the patch file was modified or corrupted.")
}
Info "patch sha256: $patchHash"

# --- clone upstream ----------------------------------------------------------
$src = Join-Path $WorkDir 'rtx30-unlock'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
if (Test-Path $src) {
    Step "reusing existing checkout $src"
} else {
    Step "cloning $UpstreamUrl"
    $result = Invoke-Git @('clone', '--quiet', $UpstreamUrl, $src)
    if ($result.ExitCode -ne 0 -or -not (Test-Path $src)) {
        Fail ("git clone failed: " + $result.Output)
    }
}
Step "checking out $UpstreamCommit"
$result = Invoke-Git @('-C', $src, 'checkout', '--quiet', $UpstreamCommit)
if ($result.ExitCode -ne 0) { Fail ("git checkout failed: " + $result.Output) }
$result = Invoke-Git @('-C', $src, 'rev-parse', 'HEAD')
if ($result.ExitCode -ne 0) { Fail ("git rev-parse failed: " + $result.Output) }
$head = $result.Output.Trim()
if ($head -ne $UpstreamCommit) { Fail "unexpected commit $head" }
Info "upstream at $head"

# --- apply patch -------------------------------------------------------------
Step 'checking patches/0001-gop-single-display-child.patch'
$result = Invoke-Git @('-C', $src, 'apply', '--check', '--reverse', $PatchPath)
if ($result.ExitCode -eq 0) {
    Info 'patch already applied'
} else {
    $result = Invoke-Git @('-C', $src, 'apply', '--check', $PatchPath)
    if ($result.ExitCode -ne 0) {
        Fail ('the patch does not apply cleanly to the pinned commit (delete build-workspace and retry): ' + $result.Output)
    }
    if ($VerifyOnly) {
        Write-Host ''
        Write-Host 'VerifyOnly: prerequisites, pinned commit and patch applicability are OK.' -ForegroundColor Green
        exit 0
    }
    $result = Invoke-Git @('-C', $src, 'apply', '--index', $PatchPath)
    if ($result.ExitCode -ne 0) { Fail ('git apply failed: ' + $result.Output) }
    Info 'patch applied'
}

if ($VerifyOnly) {
    Write-Host ''
    Write-Host 'VerifyOnly: prerequisites, pinned commit and patch are OK.' -ForegroundColor Green
    exit 0
}

# --- build -------------------------------------------------------------------
Step 'bun install'
Push-Location $src
try {
    $result = Invoke-Native -FilePath $bunExe -Arguments @('install')
    if ($result.ExitCode -ne 0) { Fail ('bun install failed: ' + $result.Output) }

    Step 'bun run build'
    $result = Invoke-Native -FilePath $bunExe -Arguments @('run', 'build')
    if ($result.ExitCode -ne 0) { Fail ('bun run build failed: ' + $result.Output) }
    $efi = Join-Path $src 'build\efi\BOOTX64.EFI'
    if (-not (Test-Path $efi)) { Fail 'build did not produce build\efi\BOOTX64.EFI' }

    Step 'bun run firmware:assets  (downloads NVIDIA/CachyOS pinned inputs; needs network)'
    $result = Invoke-Native -FilePath $bunExe -Arguments @('run', 'firmware:assets')
    if ($result.ExitCode -ne 0) { Fail ('firmware asset generation failed: ' + $result.Output) }
} finally {
    Pop-Location
}

# --- reference checkout ------------------------------------------------------
if (-not $SkipReference) {
    $ref = Join-Path $WorkDir 'gpu-unlock'
    if (-not (Test-Path $ref)) {
        Step "cloning $ReferenceUrl (reference only)"
        $result = Invoke-Git @('clone', '--quiet', $ReferenceUrl, $ref)
        if ($result.ExitCode -ne 0) { Write-Warning ('reference clone failed (ignored): ' + $result.Output) }
    }
    if (Test-Path $ref) {
        $result = Invoke-Git @('-C', $ref, 'checkout', '--quiet', $ReferenceCommit)
        if ($result.ExitCode -ne 0) {
            Write-Warning ('reference checkout failed (ignored): ' + $result.Output)
        } else {
            $refHead = Invoke-Git @('-C', $ref, 'rev-parse', 'HEAD')
            Info ("reference at " + $refHead.Output.Trim())
        }
    }
}

# --- assemble package --------------------------------------------------------
Step 'assembling package'
$pkg = Join-Path $WorkDir 'package'
$savedProfile = $null
if (Test-Path $pkg) {
    $existingProfile = Join-Path $pkg 'RTX-UNLOCK\PROFILE.BIN'
    if (Test-Path $existingProfile) {
        $savedProfile = Join-Path $WorkDir 'PROFILE.BIN.keep'
        Copy-Item -LiteralPath $existingProfile -Destination $savedProfile -Force
        Info 'keeping the existing PROFILE.BIN across the rebuild'
    }
    Remove-Item $pkg -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'EFI\BOOT'), (Join-Path $pkg 'RTX-UNLOCK') | Out-Null
Copy-Item $efi (Join-Path $pkg 'EFI\BOOT\BOOTX64.EFI')
Copy-Item (Join-Path $src 'build\firmware-assets') (Join-Path $pkg 'RTX-UNLOCK\ASSETS') -Recurse
if ($savedProfile) {
    Copy-Item -LiteralPath $savedProfile -Destination (Join-Path $pkg 'RTX-UNLOCK\PROFILE.BIN') -Force
}
New-Item -ItemType File -Force -Path (Join-Path $pkg 'RTX-UNLOCK\DEBUG.ON') | Out-Null
@(
    'Checklist before installing:',
    '',
    '  1. Boot this package once from a USB stick or a spare ESP and let the tool capture',
    '     PROFILE.BIN on THIS machine (upstream docs/agent/EXTERNAL-PROFILE.md,',
    '     docs/agent/USB-BOOT.md). With DEBUG.ON present the tool asks for U once.',
    '  2. Copy the captured RTX-UNLOCK\PROFILE.BIN into this folder',
    '     (replace this README-PROFILE.txt if you like).',
    '  3. Install:',
    '       tools\windows\install-internal.ps1 -PackageDir <this package folder>',
    '  4. Full shutdown, power on: the unlocker runs first, then Windows.',
    '  5. Optionally delete DEBUG.ON for fully automatic boots.',
    '',
    'Verification: tools\windows\status.ps1 runs the cuBLAS check and explains the result.',
    'Locked ~21-24 TFLOPS vs unlocked ~38-45 TFLOPS on an RTX 3060 12 GB',
    '(4096^3, FP16 in / FP32 accumulate). The check also works without Python.',
    '',
    'This package folder contains SHA256SUMS.txt; install-internal.ps1 verifies it',
    'before and after copying. PROFILE.BIN must be captured on THIS machine.'
) | Set-Content -Path (Join-Path $pkg 'RTX-UNLOCK\README-PROFILE.txt') -Encoding utf8

$efiHash = (Get-FileHash (Join-Path $pkg 'EFI\BOOT\BOOTX64.EFI') -Algorithm SHA256).Hash.ToLower()

# Integrity manifest so install-internal.ps1 can verify the package and the copy.
$sumsPath = Join-Path $pkg 'SHA256SUMS.txt'
$sumLines = @()
foreach ($file in (Get-ChildItem $pkg -Recurse -File | Sort-Object FullName)) {
    if ($file.FullName -eq $sumsPath) { continue }
    $hash = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLower()
    $relative = $file.FullName.Substring($pkg.Length + 1).Replace('\', '/')
    $sumLines += ('{0}  {1}' -f $hash, $relative)
}
[System.IO.File]::WriteAllLines($sumsPath, $sumLines, (New-Object System.Text.UTF8Encoding($false)))

Step 'done'
Write-Host ''
Write-Host ("  package      : " + $pkg)
Write-Host ("  EFI sha256   : " + $efiHash)
Write-Host ("  assets       : " + ((Get-ChildItem (Join-Path $pkg 'RTX-UNLOCK\ASSETS') -File).Count) + ' files')
Write-Host ("  manifest     : " + $sumsPath + ' (' + $sumLines.Count + ' files)')
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Put the PROFILE.BIN captured on this machine into RTX-UNLOCK\ (README-PROFILE.txt).'
Write-Host '  2. Elevated: tools\windows\install-internal.ps1 -PackageDir <package> -DryRun'
Write-Host '     then:     tools\windows\install-internal.ps1 -PackageDir <package>'
Write-Host '  3. Reboot, then: tools\windows\status.ps1    (expect "UNLOCKED")'
Write-Host ''
