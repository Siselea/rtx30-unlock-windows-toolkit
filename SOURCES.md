# Sources — the two upstream repositories

This project only *references* the two upstream repositories below. Their code is not
copied into this repository; `scripts/build-from-upstream.ps1` clones them at the
pinned commits, applies the patch in `patches/`, and builds locally.

## Pinned sources

| source | commit | used for |
|---|---|---|
| https://github.com/craftingmod/rtx30-unlock | `5c076dc4ee7fa369639669fa591ac74d8f6dfcd8` | Windows/UEFI port; base tree for the patch; build via `bun run build`; firmware assets via `bun run firmware:assets` |
| https://github.com/Zagitta/gpu-unlock | `0ebdb1c6308b6a2072be5bf04513472942541956` | original technique (Linux kernel module V67 + PLM + SS0/SS1 + FLR); provenance/reference checkout |

Transitively referenced by those sources (not fetched by this toolkit):

* `WildFlash1st/cmp90hx-unlock` — V67 "rejoin15" reference payload, GPL-2.0-only
* EDK2 `MdePkg` headers — BSD-2-Clause
* NVIDIA GPU firmware artifacts (GSP/booter) — fetched by the upstream
  `bun run firmware:assets` from NVIDIA/CachyOS pinned by SHA-256; **not redistributed**
* cuBLAS / CUDA runtime — from the user's NVIDIA driver installation

## Our patch

| file | sha256 |
|---|---|
| `patches/0001-gop-single-display-child.patch` | `cdc22b6d8c989a4eb08f14e8eadbf5cc2eebedc3461a938db275362e54eeb35f` |

It applies to `src/gop/full.c` at the pinned craftingmod commit with
`git apply` / `git am`. The patch is GPL-2.0-only (derivative work of GPL-2.0-only
code), see [`NOTICE.md`](NOTICE.md).

## Reproducing the build

```powershell
.\scripts\build-from-upstream.ps1
```

The script:

1. checks that `git`, `bun`, `clang` and `lld-link` are available,
2. clones `craftingmod/rtx30-unlock` at the pinned commit and verifies the commit hash,
3. applies `patches/0001-gop-single-display-child.patch`,
4. runs `bun install`, `bun run build` and `bun run firmware:assets`,
5. assembles `build-workspace/package/` (`EFI/BOOT/BOOTX64.EFI` + `RTX-UNLOCK/ASSETS/`),
6. optionally clones `Zagitta/gpu-unlock` at the pinned commit for reference.

Everything else in this repository — installation scripts, benchmark, build
documentation, test report — is our own work and was produced while testing on a real
machine (see [`docs/test-report.md`](docs/test-report.md)).

## Verified build

Applying this patch to the pinned upstream commit and building with the toolchain
described in [`docs/build.md`](docs/build.md) reproduces the exact binary that was
tested on the reference machine:

```
107520 bytes  sha256=48dca8919051bb9d08aeb883a17d3cf3300e0b76e4d6de326b06cbb385e09175
```

(`bun run build` also runs the PE verification and records the same hash in
`build/efi/pe-verification.json`.)
