# NOTICE — attribution and licensing

This repository is **not a fork**. It contains only original work (scripts, tools,
documentation, measurement report) plus **git patches** that modify the upstream
project. The upstream source code and the NVIDIA firmware assets are **not
redistributed here**; they are fetched at pinned commits by
[`scripts/build-from-upstream.ps1`](scripts/build-from-upstream.ps1).

## Upstream projects used as sources

### 1. craftingmod/rtx30-unlock

* URL: https://github.com/craftingmod/rtx30-unlock
* Pinned commit: `5c076dc4ee7fa369639669fa591ac74d8f6dfcd8`
* Role: Windows/UEFI port this toolkit patches. The files in `patches/` apply to this
  commit tree.
* License: **GPL-2.0-only** (see the upstream `LICENSE`; a copy is included in this
  repository as `LICENSE`).
* Copyright: respective upstream authors/contributors.

Because the patch in `patches/` is a derivative work of GPL-2.0-only code, the patch
itself is distributed under **GPL-2.0-only**.

### 2. Zagitta/gpu-unlock

* URL: https://github.com/Zagitta/gpu-unlock
* Pinned commit: `0ebdb1c6308b6a2072be5bf04513472942541956`
* Role: original technique / Linux kernel module (V67 + PLM + SS0/SS1 + FLR) that the
  craftingmod port is based on. Referenced for provenance and documentation; useful as
  a reference checkout while working on the port.
* License: **GPL-2.0-only**.

### 3. Additional upstream references (transitively required by the sources above)

* `WildFlash1st/cmp90hx-unlock` — reference for the V67 "rejoin15" payload used by the
  upstream firmware tooling (see upstream
  `tools/firmware/artifacts-610.43.03.json`). GPL-2.0-only.
* **EDK2** `MdePkg` headers (BSD-2-Clause) — fetched with the upstream source; not
  redistributed here.
* **NVIDIA** GPU firmware (GSP/booter binaries) — fetched by the upstream
  `bun run firmware:assets` tooling from NVIDIA/CachyOS under their own terms; **not
  redistributed here**.
* **cuBLAS / CUDA runtime** — used at runtime by `tools/bench/fp16_gemm_bench.py` from
  the user's own NVIDIA driver installation; not redistributed.

## This repository's own work

Unless stated otherwise, the following files are original work by the contributors of
this repository and are licensed **GPL-2.0-only** (to keep a single, compatible license
across the derivative patch and the surrounding tooling):

* `README.md`, `README.zh-CN.md`, `SOURCES.md`, `NOTICE.md`
* `docs/**`
* `patches/README.md`
* `scripts/**`
* `tools/**`
* `.gitattributes`, `.gitignore`

Copyright (C) 2026 Siselea and contributors.

## Redistribution

* **Source:** this repository plus the pinned upstream commit and the patch are
  everything needed to rebuild `BOOTX64.EFI`. Distributing a built binary implies the
  GPL-2.0-only obligation to make the corresponding source available.
* **Do not redistribute `RTX-UNLOCK\ASSETS\`** (NVIDIA GPU firmware, under NVIDIA's
  own terms, fetched by the upstream tooling - not covered by this repository's
  license).
* **Do not redistribute `PROFILE.BIN` or `RUNnn`/probe logs.** The profile is bound to
  a specific card/board (PCI ID, subsystem, chip) and the logs contain machine
  identifiers; share them only when reporting an issue, ideally trimmed.
* The scripts and docs in this repository may be redistributed under GPL-2.0-only with
  attribution to the upstream projects listed above.

## Trademarks

NVIDIA, GeForce and RTX are trademarks of NVIDIA Corporation. This project is not
affiliated with or endorsed by NVIDIA.
