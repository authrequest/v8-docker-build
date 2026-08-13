# v8-builder

Build V8's `d8` binary or `v8dasm` bytecode disassembler for Linux x64 using Docker. Designed for CTF/exploit dev and reverse engineering workflows.

## Prerequisites

- Docker Desktop with Rosetta enabled (Settings > General > "Use Rosetta for x86_64/amd64 emulation")
- At least 16 GB RAM allocated to Docker (Settings > Resources > Memory)

## Usage

```bash
# Linux / macOS / Git Bash
./build.sh --rev <commit_hash> --target <output_path> --args <gn_args_file> [options]

# Windows PowerShell
.\build.ps1 -Rev <commit_hash> -Target <output_path> -Args <gn_args_file> [options]
```

**Flags:**

| Flag | Required | Description |
|------|----------|-------------|
| `--rev` | yes | V8 git revision, tag, or branch |
| `--target` | yes | Full path to output directory |
| `--args` | yes | File with GN build args (see `args/`) |
| `--mode` | no | `d8` (default) or `dasm` (bytecode disassembler) |
| `--patch` | no | Patch file to apply after checkout |
| `--jobs` | no | Parallel compile jobs (default: half of available cores) |
| `--quick` | no | Skip fetch/checkout/sync — just rebuild with current source |
| `--rebuild` | no | Force Docker image rebuild |

## Build Modes

### d8 (default) — Debug shell for exploit dev

```bash
./build.sh --rev 12.1.285.26 --target ~/vm-shared/cve-2024-1234 --args args/debug.gn --patch exploit.patch

# PowerShell
.\build.ps1 -Rev 12.1.285.26 -Target .\output\cve-2024-1234 -Args args\debug.gn -Patch exploit.patch
```

Output:
```
out/d8                  # the binary
out/icudtl.dat          # required runtime data
out/snapshot_blob.bin   # required runtime data
out/.gdbinit            # source path mapping for pwndbg/GDB
v8/src/                 # C++ source for debug reference
v8/include/             # headers
```

### dasm — V8 bytecode disassembler

Builds `v8dasm`, a standalone tool that loads V8 bytecode cache files (`.jsc`) and prints their disassembled bytecode. Uses a patched V8 monolith build.

```bash
./build.sh --mode dasm --rev 2b2f6915852 --target ~/vm-shared/dasm --args args/dasm.gn --patch patches/dasm.patch

# PowerShell
.\build.ps1 -Mode dasm -Rev 2b2f6915852 -Target .\output\dasm -Args args\dasm.gn -Patch patches\dasm.patch
```

Output:
```
out/v8dasm              # the disassembler binary
v8/src/                 # patched V8 source for reference
v8/include/             # headers
```

Usage:
```bash
./v8dasm path/to/code.jsc
```

The patch (`patches/dasm.patch`) modifies V8 to:
- Dump `SharedFunctionInfo` and `BytecodeArray` during code cache deserialization
- Remove string truncation so full strings are printed
- Bypass `SanityCheck` and magic number validation to accept arbitrary `.jsc` files

## Quick Rebuild

After the initial build, edit source files in `<target>/v8/src/`, then rebuild without re-fetching:

```bash
./build.sh --quick --target ~/vm-shared/cve-2024-1234 --args args/debug.gn
./build.sh --quick --mode dasm --target ~/vm-shared/dasm --args args/dasm.gn

# PowerShell
.\build.ps1 -Quick -Target .\output\cve-2024-1234 -Args args\debug.gn
.\build.ps1 -Quick -Mode dasm -Target .\output\dasm -Args args\dasm.gn
```

## GN Args

Included configs in `args/`:

- `debug.gn` — Full debug d8 build (disassembler, object print, verify heap, slow dchecks)
- `dasm.gn` — Release monolith build for v8dasm (no sandbox, no temporal, static library)

Create your own file for different profiles.

## Notes

- First run fetches the entire V8 source (~20-30 min). Subsequent runs reuse a persistent Docker volume.
- ccache is persisted across builds — incremental rebuilds are fast.
- If the build OOMs (compiler killed with no error message), reduce `--jobs` or increase Docker memory.
- The dasm patch is tested against V8 15.0.1240245 (commit `2b2f6915852`). It may need updates for other versions.
