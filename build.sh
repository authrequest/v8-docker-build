#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="v8-builder"

usage() {
    cat <<EOF
V8 d8 Builder — build d8 for Linux x64 in Docker, output to VM shared folder

Usage:
  $0 --rev <hash> --target <folder> --args <gn_args_file> [--patch <file>]

Required:
  --rev      V8 git revision hash (or branch/tag)
  --target   Full path to output directory
  --args     File containing GN args (one per line)

Optional:
  --patch    Patch file to apply after checkout (omit to skip)
  --jobs     Max parallel compile jobs (default: nproc/2 to avoid OOM)
  --quick    Skip fetch/checkout/sync — just rebuild with current source
             Edit files in <target>/v8/, they get synced back before build
  --rebuild  Force Docker image rebuild

Example:
  $0 --rev 12.1.285.26 --target ~/Documents/vm-shared/cve-2024-1234 --args args/debug.gn --patch exploit.patch

Output structure in <target>/:
  out/d8              — the d8 binary
  out/icudtl.dat      — ICU data
  out/snapshot_blob.bin
  out/.gdbinit        — pwndbg/GDB helper (source path mapping)
  v8/src/             — V8 source for debug reference
  v8/include/         — V8 headers
  v8/tools/           — GDB helpers & V8 tools
  patch.diff          — copy of applied patch (if any)
EOF
    exit 1
}

# ---- Parse arguments ----
REVISION=""
TARGET=""
PATCH_FILE=""
GN_ARGS_FILE=""
MAX_JOBS=""
FORCE_REBUILD=false
QUICK_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --rev)      REVISION="$2";     shift 2;;
        --target)   TARGET="$2";       shift 2;;
        --patch)    PATCH_FILE="$2";   shift 2;;
        --args)     GN_ARGS_FILE="$2"; shift 2;;
        --jobs)     MAX_JOBS="$2";     shift 2;;
        --quick)    QUICK_MODE=true;   shift;;
        --rebuild)  FORCE_REBUILD=true; shift;;
        -h|--help)  usage;;
        *)          echo "Unknown option: $1"; usage;;
    esac
done

if [[ "$QUICK_MODE" == true ]]; then
    [[ -z "$TARGET" ]]        && echo "Error: --target is required" && usage
    [[ -z "$GN_ARGS_FILE" ]] && echo "Error: --args is required"   && usage
else
    [[ -z "$REVISION" ]]     && echo "Error: --rev is required"    && usage
    [[ -z "$TARGET" ]]        && echo "Error: --target is required" && usage
    [[ -z "$GN_ARGS_FILE" ]] && echo "Error: --args is required"   && usage
fi

# Resolve full paths
GN_ARGS_FULL="$(cd "$(dirname "$GN_ARGS_FILE")" && pwd)/$(basename "$GN_ARGS_FILE")"
[[ ! -f "$GN_ARGS_FULL" ]] && echo "Error: GN args file not found: $GN_ARGS_FILE" && exit 1

# Resolve target to absolute path
if [[ "$TARGET" = /* ]]; then
    OUTPUT_DIR="$TARGET"
else
    OUTPUT_DIR="$(pwd)/$TARGET"
fi
mkdir -p "$OUTPUT_DIR"

# ---- Build Docker image ----
IMAGE_EXISTS=$(docker images -q "$IMAGE_NAME" 2>/dev/null)
if [[ -z "$IMAGE_EXISTS" ]] || [[ "$FORCE_REBUILD" == true ]]; then
    echo "[*] Building Docker image ($IMAGE_NAME)..."
    docker build --platform linux/amd64 -t "$IMAGE_NAME" "$SCRIPT_DIR"
else
    echo "[*] Docker image $IMAGE_NAME exists (use --rebuild to force)"
fi

# ---- Create persistent volumes ----
docker volume create v8-src   >/dev/null 2>&1 || true
docker volume create ccache-vol >/dev/null 2>&1 || true

# ---- Prepare mounts ----
DOCKER_ARGS=(
    --platform linux/amd64
    --rm
    -v v8-src:/v8
    -v ccache-vol:/root/.ccache
    -v "$OUTPUT_DIR:/output"
    -v "$SCRIPT_DIR/build-inside.sh:/usr/local/bin/build-inside.sh:ro"
    -v "$GN_ARGS_FULL:/tmp/gn_args.txt:ro"
    -e CCACHE_DIR=/root/.ccache
    -e QUICK_MODE="$QUICK_MODE"
)

# Patch mount (optional)
PATCH_ARG="none"
if [[ -n "$PATCH_FILE" ]]; then
    PATCH_FULL="$(cd "$(dirname "$PATCH_FILE")" && pwd)/$(basename "$PATCH_FILE")"
    if [[ ! -f "$PATCH_FULL" ]]; then
        echo "Error: Patch file not found: $PATCH_FILE"
        exit 1
    fi
    DOCKER_ARGS+=(-v "$PATCH_FULL:/tmp/patch.diff:ro")
    PATCH_ARG="/tmp/patch.diff"
fi

# ---- Run build ----
echo "[*] Starting build container..."
[[ "$QUICK_MODE" == true ]] && echo "    Mode:     QUICK (rebuild only)"
[[ -n "$REVISION" ]]  && echo "    Revision: $REVISION"
echo "    Target:   $OUTPUT_DIR"
echo "    GN args:  $GN_ARGS_FILE"
[[ -n "$PATCH_FILE" ]] && echo "    Patch:    $PATCH_FILE"
[[ -n "$MAX_JOBS" ]]  && echo "    Jobs:     $MAX_JOBS"
echo ""

docker run "${DOCKER_ARGS[@]}" \
    "$IMAGE_NAME" \
    "${REVISION:-none}" "$PATCH_ARG" "/tmp/gn_args.txt" "/output" "$MAX_JOBS"

echo ""
echo "[*] Output ready at: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR/out/d8" 2>/dev/null || echo "Warning: d8 not found in output"
