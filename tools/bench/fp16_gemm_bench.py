#!/usr/bin/env python3
"""cuBLAS FP16 -> FP32-accumulate GEMM benchmark.

This is the metric that the gpu-unlock project reports: the artificially
rate-limited Tensor Core path doubles when the SS0/SS1 selectors are unlocked.

The script also prints a verdict ("locked" / "unlocked") using thresholds that
are calibrated for the RTX 3060 12 GB (GA104); override them for other cards.

Usage:
    python fp16_gemm_bench.py [DLL_DIR] [SIZE] [options]

    DLL_DIR  directory containing cudart64_*.dll and cublas64_*.dll
             (default: search CUDA_PATH\\bin, this folder, the folder of
             llama-server.exe on PATH, common llama.cpp folders and
             C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\*\\bin)
    SIZE     square matrix size (default 4096)

Options:
    --iters N        timed iterations (default 50)
    --warmup N       warm-up iterations (default 10)
    --unlocked-min F TFLOPS threshold for "unlocked" (default 34)
    --locked-max F   TFLOPS threshold for "locked" (default 28)
    --json           print one JSON object instead of the human report

Notes:
    * One GEMM at 4096**3 takes a few milliseconds on a 3060; the Windows WDDM TDR
      timeout (~2 s) applies to a single kernel launch, so avoid very large sizes.
    * Expect roughly 24 TFLOPS locked and 38-45 TFLOPS unlocked on an RTX 3060
      12 GB (170 W power limit).
    * The PowerShell twin tools/bench/fp16_gemm_bench.ps1 makes the same call
      and works without Python.

Exit codes: 0 = measured, 2 = DLLs not found or benchmark failed.
"""

import argparse
import ctypes
import glob
import json
import os
import sys


def find_dlls(hint):
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = []
    if hint:
        candidates.append(hint)
    if os.environ.get("RTX30_CUDA_DIR"):
        candidates.append(os.environ["RTX30_CUDA_DIR"])
    if os.environ.get("CUDA_PATH"):
        candidates.append(os.path.join(os.environ["CUDA_PATH"], "bin"))
        candidates.append(os.environ["CUDA_PATH"])
    candidates.append(here)
    candidates.append(os.getcwd())
    for tool in ("llama-server", "llama-cli", "llama-bench"):
        for ext in (".exe", ""):
            path = os.environ.get("PATH", "")
            for folder in path.split(os.pathsep):
                if folder and os.path.isfile(os.path.join(folder, tool + ext)):
                    candidates.append(folder)
    candidates += [r"U:\llama", r"C:\llama", r"D:\llama", r"C:\llama.cpp", r"C:\AI\llama"]
    candidates += glob.glob(r"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\*\bin")
    for d in candidates:
        if not d or not os.path.isdir(d):
            continue
        cudart = glob.glob(os.path.join(d, "cudart64_*.dll"))
        cublas = glob.glob(os.path.join(d, "cublas64_*.dll"))
        if cudart and cublas:
            return d, cudart[0], cublas[0]
    raise SystemExit(
        "cudart64_*.dll / cublas64_*.dll not found.\n"
        "Pass the directory as the first argument, e.g.\n"
        r"  python fp16_gemm_bench.py U:\llama"
    )


def parse_args():
    parser = argparse.ArgumentParser(description="cuBLAS FP16 -> FP32-accumulate GEMM benchmark")
    parser.add_argument("dll_dir", nargs="?", default=None, help="folder with cudart64_*.dll / cublas64_*.dll")
    parser.add_argument("size", nargs="?", type=int, default=4096, help="square matrix size (default 4096)")
    parser.add_argument("--iters", type=int, default=50, help="timed iterations (default 50)")
    parser.add_argument("--warmup", type=int, default=10, help="warm-up iterations (default 10)")
    parser.add_argument("--unlocked-min", type=float, default=34.0, help="unlocked threshold in TFLOPS")
    parser.add_argument("--locked-max", type=float, default=28.0, help="locked threshold in TFLOPS")
    parser.add_argument("--json", action="store_true", help="print one JSON object")
    return parser.parse_args()


def main():
    args = parse_args()
    try:
        dll_dir, cudart_path, cublas_path = find_dlls(args.dll_dir)
        result = run(dll_dir, cudart_path, cublas_path, args.size, args.iters, args.warmup)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - report all failures uniformly
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}))
        else:
            print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    tflops = result["tflops"]
    if tflops >= args.unlocked_min:
        verdict = "unlocked"
    elif tflops <= args.locked_max:
        verdict = "locked"
    else:
        verdict = "inconclusive"
    payload = {
        "ok": True,
        "dll_dir": dll_dir,
        "size": args.size,
        "iters": args.iters,
        "ms_per_iter": round(result["ms_per_iter"], 3),
        "tflops": round(tflops, 2),
        "verdict": verdict,
        "unlocked_min": args.unlocked_min,
        "locked_max": args.locked_max,
    }
    if args.json:
        print(json.dumps(payload))
        return 0

    print(f"cuBLAS/cudart from: {dll_dir}")
    print("---")
    print(
        f"FP16 in / FP32 accum {args.size}x{args.size}x{args.size}"
        f"  {result['ms_per_iter']:8.2f} ms/iter  {tflops:8.2f} TFLOPS"
    )
    print(f"verdict: {verdict.upper()}")
    print(
        f"thresholds: locked <= {args.locked_max:.1f}, unlocked >= {args.unlocked_min:.1f} TFLOPS"
        " (RTX 3060 12 GB calibration)"
    )
    return 0


def run(dll_dir, cudart_path, cublas_path, size, iters, warmup):
    _dll_dir_handle = None
    if hasattr(os, "add_dll_directory"):
        # keep the handle alive until the process exits; closing it removes the path
        _dll_dir_handle = os.add_dll_directory(dll_dir)
    cudart = ctypes.WinDLL(cudart_path)
    cublas = ctypes.WinDLL(cublas_path)

    cudart.cudaSetDevice.argtypes = [ctypes.c_int]
    cudart.cudaMalloc.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t]
    cudart.cudaMemset.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_size_t]
    cudart.cudaFree.argtypes = [ctypes.c_void_p]
    cudart.cudaDeviceSynchronize.restype = ctypes.c_int
    cudart.cudaEventCreate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    cudart.cudaEventRecord.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    cudart.cudaEventElapsedTime.argtypes = [ctypes.POINTER(ctypes.c_float), ctypes.c_void_p, ctypes.c_void_p]
    cudart.cudaEventSynchronize.argtypes = [ctypes.c_void_p]
    cudart.cudaEventDestroy.argtypes = [ctypes.c_void_p]
    cudart.cudaGetErrorString.argtypes = [ctypes.c_int]
    cudart.cudaGetErrorString.restype = ctypes.c_char_p

    cublas.cublasCreate_v2.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    cublas.cublasDestroy_v2.argtypes = [ctypes.c_void_p]
    cublas.cublasSetMathMode.argtypes = [ctypes.c_void_p, ctypes.c_int]
    cublas.cublasGemmEx.argtypes = [
        ctypes.c_void_p,                              # handle
        ctypes.c_int, ctypes.c_int,                   # transa, transb
        ctypes.c_int, ctypes.c_int, ctypes.c_int,     # m, n, k
        ctypes.c_void_p,                              # alpha
        ctypes.c_void_p, ctypes.c_int, ctypes.c_int,  # A, Atype, lda
        ctypes.c_void_p, ctypes.c_int, ctypes.c_int,  # B, Btype, ldb
        ctypes.c_void_p,                              # beta
        ctypes.c_void_p, ctypes.c_int, ctypes.c_int,  # C, Ctype, ldc
        ctypes.c_int,                                 # computeType
        ctypes.c_int,                                 # algo
    ]

    CUDA_R_32F = 0
    CUDA_R_16F = 2
    CUBLAS_COMPUTE_32F = 68
    CUBLAS_GEMM_DEFAULT_TENSOR_OP = 99
    CUBLAS_OP_N = 0

    def check(rc, what):
        if rc != 0:
            err = cudart.cudaGetErrorString(rc) if rc < 1000 else b""
            raise RuntimeError(f"{what} failed: rc={rc} {err}")

    a = ctypes.c_void_p()
    b = ctypes.c_void_p()
    c = ctypes.c_void_p()
    handle = ctypes.c_void_p()
    e0 = ctypes.c_void_p()
    e1 = ctypes.c_void_p()
    try:
        check(cudart.cudaSetDevice(0), "cudaSetDevice")
        check(cudart.cudaMalloc(ctypes.byref(a), size * size * 2), "cudaMalloc A")
        check(cudart.cudaMalloc(ctypes.byref(b), size * size * 2), "cudaMalloc B")
        check(cudart.cudaMalloc(ctypes.byref(c), size * size * 4), "cudaMalloc C")
        check(cudart.cudaMemset(a, 0, size * size * 2), "memset A")
        check(cudart.cudaMemset(b, 0, size * size * 2), "memset B")
        check(cudart.cudaMemset(c, 0, size * size * 4), "memset C")
        check(cublas.cublasCreate_v2(ctypes.byref(handle)), "cublasCreate")
        cublas.cublasSetMathMode(handle, 1)
        alpha = ctypes.c_float(1.0)
        beta = ctypes.c_float(0.0)
        gemm_args = [handle, CUBLAS_OP_N, CUBLAS_OP_N, size, size, size,
                     ctypes.byref(alpha),
                     a, CUDA_R_16F, size,
                     b, CUDA_R_16F, size,
                     ctypes.byref(beta),
                     c, CUDA_R_32F, size,
                     CUBLAS_COMPUTE_32F, CUBLAS_GEMM_DEFAULT_TENSOR_OP]

        def once():
            rc = cublas.cublasGemmEx(*gemm_args)
            if rc != 0:
                raise RuntimeError(f"cublasGemmEx rc={rc}")
            check(cudart.cudaDeviceSynchronize(), "sync")

        for _ in range(warmup):
            once()
        check(cudart.cudaEventCreate(ctypes.byref(e0)), "event0")
        check(cudart.cudaEventCreate(ctypes.byref(e1)), "event1")
        check(cudart.cudaEventRecord(e0, None), "record0")
        for _ in range(iters):
            once()
        check(cudart.cudaEventRecord(e1, None), "record1")
        check(cudart.cudaEventSynchronize(e1), "event sync")
        ms = ctypes.c_float(0.0)
        check(cudart.cudaEventElapsedTime(ctypes.byref(ms), e0, e1), "elapsed")
        return {
            "ms_per_iter": ms.value / iters,
            "tflops": 2.0 * size * size * size * iters / (ms.value / 1000.0) / 1e12,
        }
    finally:
        for h in (a, b, c):
            if h.value:
                cudart.cudaFree(h)
        for ev in (e0, e1):
            if ev.value:
                cudart.cudaEventDestroy(ev)
        if handle.value:
            cublas.cublasDestroy_v2(handle)


if __name__ == "__main__":
    sys.exit(main())
