<#
.SYNOPSIS
    cuBLAS FP16 -> FP32-accumulate GEMM benchmark (Windows PowerShell, no Python).

.DESCRIPTION
    Measures exactly the path that the RTX30 unlock changes: half-precision
    inputs with FP32 accumulation. On a stock GA104-based RTX 3060 12 GB the
    limited path is ~24 TFLOPS; after the unlock it is ~38-45 TFLOPS.

    This is a PowerShell port of tools/bench/fp16_gemm_bench.py so that the
    check also works on machines without Python. Both scripts use the same
    cuBLAS call (CUBLAS_COMPUTE_32F, tensor-op default algorithm, 4096^3,
    FP16 in / FP32 out) and should agree within noise.

.PARAMETER DllDir
    Directory that contains cudart64_*.dll and cublas64_*.dll. When omitted the
    script searches CUDA_PATH\bin, the script folder, the folder of
    llama-server.exe on PATH, common llama.cpp/CUDA folders and
    C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\*\bin.

.PARAMETER Size
    Square matrix size (default 4096). Keep it small: very large sizes can trip
    the WDDM TDR timeout (~2 s of continuous GPU work).

.PARAMETER Iters
    Timed iterations (default 50).

.PARAMETER Warmup
    Untimed warm-up iterations (default 10). Absorbs cuBLAS handle creation.

.PARAMETER UnlockedMin
    TFLOPS at or above which the card is considered unlocked (default 34).
    Calibrated for the RTX 3060 12 GB (GA104); pass explicit values for other
    GA10x cards.

.PARAMETER LockedMax
    TFLOPS at or below which the card is considered locked (default 28).

.PARAMETER Json
    Emit one line of JSON instead of the human-readable report.

.EXAMPLE
    .\fp16_gemm_bench.ps1
    .\fp16_gemm_bench.ps1 -DllDir U:\llama -Iters 20
    $r = .\fp16_gemm_bench.ps1 -Json | ConvertFrom-Json; $r.verdict

.NOTES
    Exit codes: 0 = measured, 2 = CUDA DLLs not found or benchmark failed.
    The verdict is informational; inspect `tflops` when scripting.
#>
[CmdletBinding()]
param(
    [string]$DllDir,
    [int]$Size = 4096,
    [int]$Iters = 50,
    [int]$Warmup = 10,
    [double]$UnlockedMin = 34.0,
    [double]$LockedMax = 28.0,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Stop-Bench([string]$message) {
    if ($Json) {
        [pscustomobject]@{ ok = $false; error = $message } | ConvertTo-Json -Compress
    } else {
        Write-Host "ERROR: $message" -ForegroundColor Red
    }
    exit 2
}

function Find-CudaDllDir([string]$hint) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($hint) { $candidates.Add($hint) }
    if ($env:RTX30_CUDA_DIR) { $candidates.Add($env:RTX30_CUDA_DIR) }
    if ($env:CUDA_PATH) {
        $candidates.Add((Join-Path $env:CUDA_PATH 'bin'))
        $candidates.Add($env:CUDA_PATH)
    }
    if ($PSCommandPath) { $candidates.Add((Split-Path -Parent $PSCommandPath)) }
    $candidates.Add((Get-Location).Path)
    foreach ($tool in @('llama-server', 'llama-cli', 'llama-bench')) {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidates.Add((Split-Path -Parent $cmd.Source)) }
    }
    foreach ($d in @('U:\llama', 'C:\llama', 'D:\llama', 'C:\llama.cpp', 'C:\AI\llama')) {
        $candidates.Add($d)
    }
    $toolkitRoot = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
    if (Test-Path $toolkitRoot) {
        Get-ChildItem $toolkitRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates.Add((Join-Path $_.FullName 'bin')) }
    }
    foreach ($dir in $candidates) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $cudart = Get-ChildItem -LiteralPath $dir -Filter 'cudart64_*.dll' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $cublas = Get-ChildItem -LiteralPath $dir -Filter 'cublas64_*.dll' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cudart -and $cublas) {
            return [pscustomobject]@{
                Dir        = (Resolve-Path -LiteralPath $dir).Path
                CudartName = $cudart.Name
                CublasName = $cublas.Name
                CudartPath = $cudart.FullName
                CublasPath = $cublas.FullName
            }
        }
    }
    return $null
}

$found = Find-CudaDllDir $DllDir
if (-not $found) {
    Stop-Bench ('cudart64_*.dll / cublas64_*.dll not found. Pass -DllDir <folder> ' +
        '(for llama.cpp builds the folder that contains llama-server.exe usually has both).')
}

# cublas64_*.dll depends on cudart64_*.dll / cublasLt64_*.dll from the same folder,
# so make that folder part of the process DLL search path before loading anything.
if (-not ('Rtx30BenchNative' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Rtx30BenchNative
{
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string lpPathName);
}
"@
}
[Rtx30BenchNative]::SetDllDirectory($found.Dir) | Out-Null

$className = 'Rtx30CuBench' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
$source = @"
using System;
using System.Runtime.InteropServices;
public static class $className
{
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaSetDevice(int device);
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaMalloc(out IntPtr devPtr, UIntPtr size);
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaMemset(IntPtr devPtr, int value, UIntPtr count);
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaDeviceSynchronize();
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaEventCreate(out IntPtr ev);
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaEventRecord(IntPtr ev, IntPtr stream);
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaEventSynchronize(IntPtr ev);
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaEventElapsedTime(out float ms, IntPtr start, IntPtr end);
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaEventDestroy(IntPtr ev);
    [DllImport(@"$($found.CudartPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cudaFree(IntPtr devPtr);
    [DllImport(@"$($found.CublasPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cublasCreate_v2(out IntPtr handle);
    [DllImport(@"$($found.CublasPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cublasDestroy_v2(IntPtr handle);
    [DllImport(@"$($found.CublasPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cublasSetMathMode(IntPtr handle, int mode);
    [DllImport(@"$($found.CublasPath)", CallingConvention = CallingConvention.Cdecl)]
    public static extern int cublasGemmEx(IntPtr handle, int transa, int transb,
        int m, int n, int k, IntPtr alpha, IntPtr A, int Atype, int lda,
        IntPtr B, int Btype, int ldb, IntPtr beta, IntPtr C, int Ctype, int ldc,
        int computeType, int algo);
}
"@

try {
    $cuda = Add-Type -TypeDefinition $source -PassThru | Select-Object -First 1
} catch {
    Stop-Bench "compiling the CUDA interop helper failed: $($_.Exception.Message)"
}

$CUDA_R_32F = 0
$CUDA_R_16F = 2
$CUBLAS_COMPUTE_32F = 68
$CUBLAS_GEMM_DEFAULT_TENSOR_OP = 99
$CUBLAS_OP_N = 0

function Assert-Cu([int]$rc, [string]$what) {
    if ($rc -ne 0) { throw "$what failed (CUDA/cuBLAS error code $rc)" }
}

$a = [IntPtr]::Zero
$b = [IntPtr]::Zero
$c = [IntPtr]::Zero
$handle = [IntPtr]::Zero
$evStart = [IntPtr]::Zero
$evEnd = [IntPtr]::Zero
$alphaPtr = [IntPtr]::Zero
$betaPtr = [IntPtr]::Zero
$tflops = 0.0
$msPerIter = 0.0

try {
    Assert-Cu $cuda::cudaSetDevice(0) 'cudaSetDevice'
    Assert-Cu $cuda::cudaMalloc([ref]$a, [UIntPtr]([uint64]$Size * $Size * 2)) 'cudaMalloc A'
    Assert-Cu $cuda::cudaMalloc([ref]$b, [UIntPtr]([uint64]$Size * $Size * 2)) 'cudaMalloc B'
    Assert-Cu $cuda::cudaMalloc([ref]$c, [UIntPtr]([uint64]$Size * $Size * 4)) 'cudaMalloc C'
    Assert-Cu $cuda::cudaMemset($a, 0, [UIntPtr]([uint64]$Size * $Size * 2)) 'cudaMemset A'
    Assert-Cu $cuda::cudaMemset($b, 0, [UIntPtr]([uint64]$Size * $Size * 2)) 'cudaMemset B'
    Assert-Cu $cuda::cudaMemset($c, 0, [UIntPtr]([uint64]$Size * $Size * 4)) 'cudaMemset C'
    Assert-Cu $cuda::cublasCreate_v2([ref]$handle) 'cublasCreate'
    [void]$cuda::cublasSetMathMode($handle, 1)

    $alphaPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    $betaPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    [System.Runtime.InteropServices.Marshal]::Copy([BitConverter]::GetBytes([single]1.0), 0, $alphaPtr, 4)
    [System.Runtime.InteropServices.Marshal]::Copy([BitConverter]::GetBytes([single]0.0), 0, $betaPtr, 4)

    $gemm = {
        $rc = $cuda::cublasGemmEx($handle, $CUBLAS_OP_N, $CUBLAS_OP_N, $Size, $Size, $Size,
            $alphaPtr, $a, $CUDA_R_16F, $Size, $b, $CUDA_R_16F, $Size,
            $betaPtr, $c, $CUDA_R_32F, $Size, $CUBLAS_COMPUTE_32F,
            $CUBLAS_GEMM_DEFAULT_TENSOR_OP)
        if ($rc -ne 0) { throw "cublasGemmEx failed (error code $rc)" }
        $rc = $cuda::cudaDeviceSynchronize()
        if ($rc -ne 0) { throw "cudaDeviceSynchronize failed (error code $rc)" }
    }

    for ($i = 0; $i -lt $Warmup; $i++) { & $gemm }

    Assert-Cu $cuda::cudaEventCreate([ref]$evStart) 'cudaEventCreate start'
    Assert-Cu $cuda::cudaEventCreate([ref]$evEnd) 'cudaEventCreate end'
    Assert-Cu $cuda::cudaEventRecord($evStart, [IntPtr]::Zero) 'cudaEventRecord start'
    for ($i = 0; $i -lt $Iters; $i++) { & $gemm }
    Assert-Cu $cuda::cudaEventRecord($evEnd, [IntPtr]::Zero) 'cudaEventRecord end'
    Assert-Cu $cuda::cudaEventSynchronize($evEnd) 'cudaEventSynchronize end'
    $ms = [single]0
    Assert-Cu $cuda::cudaEventElapsedTime([ref]$ms, $evStart, $evEnd) 'cudaEventElapsedTime'

    $msPerIter = [double]$ms / $Iters
    $tflops = 2.0 * $Size * $Size * $Size * $Iters / ($ms / 1000.0) / 1e12
} catch {
    $message = $_.Exception.Message
    if ($a -ne [IntPtr]::Zero) { [void]$cuda::cudaFree($a) }
    if ($b -ne [IntPtr]::Zero) { [void]$cuda::cudaFree($b) }
    if ($c -ne [IntPtr]::Zero) { [void]$cuda::cudaFree($c) }
    if ($handle -ne [IntPtr]::Zero) { [void]$cuda::cublasDestroy_v2($handle) }
    Stop-Bench $message
}

if ($alphaPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($alphaPtr) }
if ($betaPtr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($betaPtr) }
if ($evStart -ne [IntPtr]::Zero) { [void]$cuda::cudaEventDestroy($evStart) }
if ($evEnd -ne [IntPtr]::Zero) { [void]$cuda::cudaEventDestroy($evEnd) }
if ($a -ne [IntPtr]::Zero) { [void]$cuda::cudaFree($a) }
if ($b -ne [IntPtr]::Zero) { [void]$cuda::cudaFree($b) }
if ($c -ne [IntPtr]::Zero) { [void]$cuda::cudaFree($c) }
if ($handle -ne [IntPtr]::Zero) { [void]$cuda::cublasDestroy_v2($handle) }

$verdict = if ($tflops -ge $UnlockedMin) { 'unlocked' }
           elseif ($tflops -le $LockedMax) { 'locked' }
           else { 'inconclusive' }

if ($Json) {
    [pscustomobject]@{
        ok           = $true
        dll_dir      = $found.Dir
        size         = $Size
        iters        = $Iters
        ms_per_iter  = [math]::Round($msPerIter, 3)
        tflops       = [math]::Round($tflops, 2)
        verdict      = $verdict
        unlocked_min = $UnlockedMin
        locked_max   = $LockedMax
    } | ConvertTo-Json -Compress
} else {
    Write-Host ("cuBLAS/cudart from: {0}" -f $found.Dir)
    Write-Host '---'
    Write-Host ("FP16 in / FP32 accum {0}x{0}x{0}  {1,8:F2} ms/iter  {2,8:F2} TFLOPS" -f $Size, $msPerIter, $tflops)
    switch ($verdict) {
        'unlocked'     { Write-Host ("verdict: UNLOCKED (>= {0:N1} TFLOPS)" -f $UnlockedMin) -ForegroundColor Green }
        'locked'       { Write-Host ("verdict: LOCKED (<= {0:N1} TFLOPS)" -f $LockedMax) -ForegroundColor Yellow }
        'inconclusive' { Write-Host ("verdict: INCONCLUSIVE (between {0:N1} and {1:N1} TFLOPS)" -f $LockedMax, $UnlockedMin) -ForegroundColor Yellow }
    }
    Write-Host ("thresholds: locked <= {0:N1}, unlocked >= {1:N1} TFLOPS (RTX 3060 12 GB calibration)" -f $LockedMax, $UnlockedMin)
}

exit 0
