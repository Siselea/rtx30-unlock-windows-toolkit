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
        <WorkDir>\package\RTX-UNLOCK\ASSETS\...            (5 generated assets)
        <WorkDir>\package\RTX-UNLOCK\DEBUG.ON              (optional first-run log switch)
        <WorkDir>\package\RTX-UNLOCK\README-PROFILE.txt    (checklist)

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

.NOTES
    Requirements: git, Bun, clang + lld-link (see docs/build.md).
    Tested on Windows 11 with Bun 1.4.x and LLVM/Clang 17-23.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Join-Path $PSScriptRoot '..\build-workspace'),
    [switch]$SkipReference,
    [switch]$InsecureSsl
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)

$UpstreamUrl    = 'https://github.com/craftingmod/rtx30-unlock.git'
$UpstreamCommit = '5c076dc4ee7fa369639669fa591ac74d8f6dfcd8'
$ReferenceUrl   = 'https://github.com/Zagitta/gpu-unlock.git'
$ReferenceCommit = '0ebdb1c6308b6a2072be5bf04513472942541956'
$PatchPath      = Join-Path $repoRoot 'patches\0001-gop-single-display-child.patch'

function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Info([string]$m) { Write-Host "    $m" }
function Git { param([string[]]$Args) & git @($(if ($InsecureSsl) { @('-c', 'http.sslVerify=false') } else { @() }) + $Args) }

# --- prerequisites -----------------------------------------------------------
Step 'checking prerequisites'
foreach ($tool in @('git', 'bun', 'clang', 'lld-link')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "$tool not found in PATH. See docs/build.md (LLVM_BIN is honoured for clang/lld-link)."
    }
    Info ("{0}: {1}" -f $tool, (Get-Command $tool).Source)
}
if (-not (Test-Path $PatchPath)) { Fail "patch not found: $PatchPath" }

# --- clone upstream ----------------------------------------------------------
$src = Join-Path $WorkDir 'rtx30-unlock'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
if (Test-Path $src) {
    Step "reusing existing checkout $src"
} else {
    Step "cloning $UpstreamUrl"
    Git @('clone', $UpstreamUrl, $src)
}
Step "checking out $UpstreamCommit"
Git @('-C', $src, 'checkout', '--quiet', $UpstreamCommit)
$head = (& git -C $src rev-parse HEAD).Trim()
if ($head -ne $UpstreamCommit) { Fail "unexpected commit $head" }
Info "upstream at $head"

# --- apply patch -------------------------------------------------------------
Step 'applying patches/0001-gop-single-display-child.patch'
Git @('-C', $src, 'check', '--quiet', '--reverse', $PatchPath)
$applied = $true
try { Git @('-C', $src, 'apply', '--check', $PatchPath); $applied = $false } catch { $applied = $true }
if ($applied) {
    Info 'patch already applied'
} else {
    Git @('-C', $src, 'apply', '--index', $PatchPath)
    Info 'patch applied'
}

# --- build -------------------------------------------------------------------
Step 'bun install'
Push-Location $src
try {
    & bun install
    if ($LASTEXITCODE -ne 0) { Fail 'bun install failed' }

    Step 'bun run build'
    & bun run build
    if ($LASTEXITCODE -ne 0) { Fail 'bun run build failed' }
    $efi = Join-Path $src 'build\efi\BOOTX64.EFI'
    if (-not (Test-Path $efi)) { Fail 'build did not produce build\efi\BOOTX64.EFI' }

    Step 'bun run firmware:assets  (downloads NVIDIA/CachyOS pinned inputs; needs network)'
    & bun run firmware:assets
    if ($LASTEXITCODE -ne 0) { Fail 'firmware asset generation failed' }
} finally {
    Pop-Location
}

# --- reference checkout ------------------------------------------------------
if (-not $SkipReference) {
    $ref = Join-Path $WorkDir 'gpu-unlock'
    if (-not (Test-Path $ref)) {
        Step "cloning $ReferenceUrl (reference only)"
        Git @('clone', '--quiet', $ReferenceUrl, $ref)
    }
    Git @('-C', $ref, 'checkout', '--quiet', $ReferenceCommit)
    Info "reference at $((& git -C $ref rev-parse HEAD).Trim())"
}

# --- assemble package --------------------------------------------------------
Step 'assembling package'
$pkg = Join-Path $WorkDir 'package'
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'EFI\BOOT'), (Join-Path $pkg 'RTX-UNLOCK') | Out-Null
Copy-Item $efi (Join-Path $pkg 'EFI\BOOT\BOOTX64.EFI')
Copy-Item (Join-Path $src 'build\firmware-assets') (Join-Path $pkg 'RTX-UNLOCK\ASSETS') -Recurse
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
    'Verification: tools\bench\fp16_gemm_bench.py (locked ~24 TFLOPS vs unlocked ~38-45',
    'on an RTX 3060 12 GB, 4096^3, FP16 in / FP32 accumulate).'
) | Set-Content -Path (Join-Path $pkg 'RTX-UNLOCK\README-PROFILE.txt') -Encoding utf8

$efiHash = (Get-FileHash (Join-Path $pkg 'EFI\BOOT\BOOTX64.EFI') -Algorithm SHA256).Hash.ToLower()
Step 'done'
Write-Host ''
Write-Host ("  package      : " + $pkg)
Write-Host ("  EFI sha256   : " + $efiHash)
Write-Host ("  assets       : " + ((Get-ChildItem (Join-Path $pkg 'RTX-UNLOCK\ASSETS') -File).Count) + ' files')
Write-Host ''
Write-Host 'Next: put PROFILE.BIN into RTX-UNLOCK, then run tools\windows\install-internal.ps1'
Write-Host ''


