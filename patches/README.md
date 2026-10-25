# patches/

`0001-gop-single-display-child.patch` is a `git format-patch` of our change against
**craftingmod/rtx30-unlock** at commit
`5c076dc4ee7fa369639669fa591ac74d8f6dfcd8` (see [`../SOURCES.md`](../SOURCES.md)).

It changes `src/gop/full.c` only: `full-prepare` accepts one display child as well as
the original two, so a single-monitor machine does not need a second EDID source.

## Apply

```sh
git clone https://github.com/craftingmod/rtx30-unlock
cd rtx30-unlock
git checkout 5c076dc4ee7fa369639669fa591ac74d8f6dfcd8
git am /path/to/0001-gop-single-display-child.patch
# or: git apply /path/to/0001-gop-single-display-child.patch
bun install && bun run build
```

Windows (PowerShell):

```powershell
git clone https://github.com/craftingmod/rtx30-unlock
Set-Location rtx30-unlock
git checkout 5c076dc4ee7fa369639669fa591ac74d8f6dfcd8
git am ..\patches\0001-gop-single-display-child.patch
bun install; bun run build
```

`scripts/build-from-upstream.ps1` does this automatically. The patch is already
applied in a reused `build-workspace\rtx30-unlock` checkout; the script detects that
and skips `git apply`, but do not expect to apply the patch twice by hand.

## License

The patch is a derivative work of GPL-2.0-only code and is distributed under
**GPL-2.0-only**. See [`../NOTICE.md`](../NOTICE.md).

