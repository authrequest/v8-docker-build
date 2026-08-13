#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="v8-builder"

usage() {
    cat <<EOF
V8 Builder — build d8 or v8dasm for Linux x64 in Docker

Usage:
  $0 --rev <hash> --target <folder> --args <gn_args_file> [options]

Required:
  --rev      V8 git revision hash (or branch/tag)
  --target   Full path to output directory
  --args     File containing GN args (one per line)

Optional:
  --mode     Build mode: "d8" (default) or "dasm" (v8 bytecode disassembler)
  --patch    Patch file to apply after checkout (omit to skip)
  --jobs     Max parallel compile jobs (default: nproc/2 to avoid OOM)
  --quick    Skip fetch/checkout/sync — just rebuild with current source
  --rebuild  Force Docker image rebuild

Examples:
  # Build d8 for exploit dev
  $0 --rev 12.1.285.26 --target ~/vm-shared/cve-2024-1234 --args args/debug.gn --patch exploit.patch

  # Build v8dasm bytecode disassembler
  $0 --mode dasm --rev 2b2f6915852 --target ~/vm-shared/dasm --args args/dasm.gn --patch patches/dasm.patch

Output structure (<target>/):
  d8 mode:   out/d8, out/icudtl.dat, out/snapshot_blob.bin, out/.gdbinit, v8/src/, v8/include/
  dasm mode: out/v8dasm, v8/src/, v8/include/
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
BUILD_MODE="d8"

while [[ $# -gt 0 ]]; do
    case $1 in
        --rev)      REVISION="$2";     shift 2;;
        --target)   TARGET="$2";       shift 2;;
        --patch)    PATCH_FILE="$2";   shift 2;;
        --args)     GN_ARGS_FILE="$2"; shift 2;;
        --jobs)     MAX_JOBS="$2";     shift 2;;
        --mode)     BUILD_MODE="$2";   shift 2;;
        --quick)    QUICK_MODE=true;   shift;;
        --rebuild)  FORCE_REBUILD=true; shift;;
        -h|--help)  usage;;
        *)          echo "Unknown option: $1"; usage;;
    esac
done

# Validate mode
if [[ "$BUILD_MODE" != "d8" && "$BUILD_MODE" != "dasm" ]]; then
    echo "Error: --mode must be 'd8' or 'dasm'"
    exit 1
fi

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
    -e BUILD_MODE="$BUILD_MODE"
)

# Mount v8dasm.cpp for dasm mode
if [[ "$BUILD_MODE" == "dasm" ]]; then
    V8DASM_SRC="$SCRIPT_DIR/v8dasm.cpp"
    if [[ ! -f "$V8DASM_SRC" ]]; then
        echo "Error: v8dasm.cpp not found at $V8DASM_SRC"
        exit 1
    fi
    DOCKER_ARGS+=(-v "$V8DASM_SRC:/tmp/v8dasm.cpp:ro")
fi

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
echo "    Build:    $BUILD_MODE"
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
if [[ "$BUILD_MODE" == "dasm" ]]; then
    ls -lh "$OUTPUT_DIR/out/v8dasm" 2>/dev/null || echo "Warning: v8dasm not found in output"
else
    ls -lh "$OUTPUT_DIR/out/d8" 2>/dev/null || echo "Warning: d8 not found in output"
fi
