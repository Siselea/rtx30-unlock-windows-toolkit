# Building on Windows (with or without Visual Studio)

`build-from-upstream.ps1` needs **git**, **Bun**, **clang** and **lld-link**. This page
covers the general case and a no-Visual-Studio setup that was used to produce the
measurements in [`test-report.md`](test-report.md).

## Requirements

| tool | notes |
|---|---|
| [Bun](https://bun.sh) 1.4+ | upstream build scripts are Bun scripts |
| LLVM `clang` + `lld-link` 17+ | building; `bun run format` additionally needs `clang-format` **19+** (optional) |
| Python 3.9+ | only for upstream's optional profile/packaging helpers and `bun run test` |
| EDK2 `MdePkg` headers | already vendored in the upstream repository |

`build.ts` looks up `clang` and `lld-link` through `PATH` or `LLVM_BIN`.

## Option A — normal LLVM install

Install LLVM (for example the official LLVM Windows release) and run:

```powershell
$env:PATH = "C:\Program Files\LLVM\bin;" + $env:PATH
.\scripts\build-from-upstream.ps1
```

## Option B — portable LLVM without Visual Studio / Windows SDK

Any clang distribution works. The LLVM bundled with the **Android NDK**
(`<ndk>/toolchains/llvm/prebuilt/windows-x86_64`) was used here:

1. Create a small shim directory:

```
toolchain\llvm-shim\
  clang.exe      (copy of <ndk>\bin\clang.exe)
  lld-link.exe   (copy of <ndk>\bin\ld.lld.exe)
```

   lld dispatches on `argv[0]`, so a copy of `ld.lld.exe` named `lld-link.exe` behaves
   exactly like `lld-link`. `clang.exe` needs the NDK DLLs (`libwinpthread.dll`, …).
   Note that upstream's `tools/build.ts` **replaces** the child `PATH` with `LLVM_BIN`
   (it does not append), so copies of those DLLs must live next to `clang.exe` in the
   shim directory (or in a directory included in `LLVM_BIN` itself).

2. clang's built-in headers live relative to the executable; either copy
   `<ndk>\lib\clang\<ver>\include` into
   `toolchain\llvm-shim\lib\clang\<ver>\include`, or create a directory junction.

3. The EFI sources include `<string.h>` and `<errno.h>`, which normally come from the
   MSVC/UCRT headers when a Windows SDK is present. This repository ships
   declaration-only shims for them in [`tools/win32/headers`](../tools/win32/headers);
   point `CPATH` at that directory:

```powershell
$env:PATH     = "<bun>\bin;<repo>\toolchain\llvm-shim;" + $env:PATH
$env:LLVM_BIN = "<repo>\toolchain\llvm-shim"
$env:CPATH    = "<repo>\tools\win32\headers"
# build-from-upstream.ps1 finds clang/lld-link via PATH (LLVM_BIN is only read by
# upstream's build.ts), so the shim directory has to be on PATH as well.
```

   The implementations (`memcpy`, `memset`, …) are in the upstream sources
   (`src/unlock/runtime.c`, `src/unlock/compat.c`), so linking resolves them.

4. Then run the builder:

```powershell
# optional: check the toolchain, pinned commit and patch applicability without building
.\scripts\build-from-upstream.ps1 -VerifyOnly

.\scripts\build-from-upstream.ps1
```

## What the builder does

1. clones `craftingmod/rtx30-unlock` at `5c076dc` (pinned in
   [`../SOURCES.md`](../SOURCES.md)),
2. applies [`../patches/0001-gop-single-display-child.patch`](../patches/0001-gop-single-display-child.patch),
3. runs `bun install`, `bun run build` → `build/efi/BOOTX64.EFI`,
4. runs `bun run firmware:assets` → 5 firmware payloads + `NVIDIA-LICENSE`
   (downloads NVIDIA/CachyOS pinned inputs, needs network),
5. assembles `build-workspace/package/` for
   [`../tools/windows/install-internal.ps1`](../tools/windows/install-internal.ps1),
   writes `SHA256SUMS.txt`, `RTX-UNLOCK/README-PROFILE.txt` and an (optional) `DEBUG.ON`.

> Re-running the builder deletes `build-workspace/package/` first, including a
> `PROFILE.BIN` you already copied there. Copy it somewhere safe or re-add it after
> a rebuild.

## Reproducibility note

The verified build from the pinned source + patch is 107 520 bytes,
sha256 `48dca8919051bb9d08aeb883a17d3cf3300e0b76e4d6de326b06cbb385e09175`
(see [`test-report.md`](test-report.md#build-reproducibility-checked)). A different
clang/LLVM version produces the same size but a different `.text` layout — treat
cross-toolchain rebuilds as behaviourally, not byte-wise, reproducible.

## Running the upstream test suite

`bun run test` builds host mock tests that must link and run as Windows executables, so
it needs a host C compiler that ships a Windows CRT (`CC`). The NDK clang cannot do
that; a portable MSYS2 mingw-w64 clang does:

```powershell
$env:CC = "<msys2>\mingw64\bin\clang.exe"
bun run test
```
