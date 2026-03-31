# v8-builder

Build V8's `d8` binary for Linux x64 from macOS using Docker. Designed for CTF/exploit dev workflows where you need to checkout a specific V8 revision, apply a patch, and get a debuggable `d8` binary into a Linux VM.

## Why

Building V8 natively on macOS for a Linux target is painful. This wraps the entire V8 build toolchain (depot_tools, clang, gn, ninja) in a Docker container running linux/amd64 via Rosetta. You provide a revision + patch + GN args, and get back a ready-to-debug `d8` binary plus source files — all dropped into a shared folder your VM can access.

## Prerequisites

- Docker Desktop with Rosetta enabled (Settings > General > "Use Rosetta for x86_64/amd64 emulation")
- At least 16 GB RAM allocated to Docker (Settings > Resources > Memory)

## Usage

```bash
./build.sh --rev <commit_hash> --target <output_path> --args <gn_args_file> [--patch <file>] [--jobs <n>]
```

**Example:**

```bash
./build.sh \
  --rev 12.1.285.26 \
  --target ~/Documents/vm-shared/cve-2024-1234 \
  --args args/debug.gn \
  --patch challenge/oob.patch \
  --jobs 4
```

**Flags:**

| Flag | Required | Description |
|------|----------|-------------|
| `--rev` | yes | V8 git revision, tag, or branch |
| `--target` | yes | Full path to output directory |
| `--args` | yes | File with GN build args (see `args/debug.gn` for example) |
| `--patch` | no | Patch file to apply after checkout |
| `--jobs` | no | Parallel compile jobs (default: half of available cores) |
| `--rebuild` | no | Force Docker image rebuild |

## Output

Everything lands in `<target>/`:

```
out/
  d8                  # the binary
  icudtl.dat          # required runtime data
  snapshot_blob.bin   # required runtime data
  .gdbinit            # source path mapping for pwndbg/GDB
v8/
  src/                # C++ source for debug reference
  include/            # headers
  tools/              # GDB helpers
patch.diff            # copy of applied patch
```

## Debugging in VM

```bash
cd ~/Documents/vm-shared/<target>/out
./d8 --allow-natives-syntax exploit.js
```

With pwndbg:

```bash
cd ~/Documents/vm-shared/<target>/out
gdb -x .gdbinit ./d8
```

The `.gdbinit` maps container build paths to the local source copy so GDB can resolve source lines automatically.

## GN Args

The included `args/debug.gn` is a full-debug config. Create your own file for different build profiles:

```
# args/release.gn
is_debug=false
target_cpu="x64"
v8_enable_disassembler=true
v8_enable_object_print=true
```

## Notes

- First run fetches the entire V8 source (~20-30 min). Subsequent runs reuse a persistent Docker volume.
- ccache is persisted across builds — incremental rebuilds are fast.
- If the build OOMs (compiler killed with no error message), reduce `--jobs` or increase Docker memory.
