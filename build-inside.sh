#!/bin/bash
set -euo pipefail

REVISION="$1"
PATCH_FILE="${2:-none}"
GN_ARGS_FILE="$3"
OUTPUT_DIR="$4"
MAX_JOBS="${5:-}"

QUICK_MODE="${QUICK_MODE:-false}"

echo "========================================"
echo "  V8 Builder"
if [ "$QUICK_MODE" = "true" ]; then
    echo "  Mode: QUICK REBUILD"
else
    echo "  Revision: $REVISION"
fi
echo "========================================"

# ---- Ensure depot_tools is bootstrapped ----
gclient --version >/dev/null 2>&1 || true

# ---- Quick rebuild mode ----
if [ "$QUICK_MODE" = "true" ]; then
    cd /v8/v8

    # Sync edited source files from output back into build tree
    if [ -d "$OUTPUT_DIR/v8/src" ]; then
        echo "[1/3] Syncing source edits from output into build tree..."
        rsync -a "$OUTPUT_DIR/v8/src/" /v8/v8/src/
        rsync -a "$OUTPUT_DIR/v8/include/" /v8/v8/include/ 2>/dev/null || true
    else
        echo "[1/3] No source edits to sync"
    fi

    # Configure (in case args changed)
    echo "[2/3] Configuring build..."
    GN_ARGS=$(tr '\n' ' ' < "$GN_ARGS_FILE" | sed 's/  */ /g; s/^ //; s/ $//')
    if [[ "$GN_ARGS" != *"cc_wrapper"* ]]; then
        GN_ARGS="$GN_ARGS cc_wrapper=\"ccache\""
    fi
    gn gen out/x64-debug --args="$GN_ARGS"

    # Build
    TOTAL_CORES=$(nproc)
    if [ -n "$MAX_JOBS" ]; then
        JOBS="$MAX_JOBS"
    else
        JOBS=$(( TOTAL_CORES / 2 ))
        [ "$JOBS" -lt 2 ] && JOBS=2
    fi
    echo "[3/3] Rebuilding d8 ($JOBS cores)..."
    ninja -j"$JOBS" -C out/x64-debug d8

    echo "  d8 built: $(file out/x64-debug/d8 | cut -d: -f2)"

    # Copy binaries
    mkdir -p "$OUTPUT_DIR/out"
    cp out/x64-debug/d8 "$OUTPUT_DIR/out/"
    for f in icudtl.dat snapshot_blob.bin; do
        [ -f "out/x64-debug/$f" ] && cp "out/x64-debug/$f" "$OUTPUT_DIR/out/"
    done

    # Sync source back to output (picks up any torque-generated changes)
    rsync -a --delete /v8/v8/src/ "$OUTPUT_DIR/v8/src/"
    rsync -a --delete /v8/v8/include/ "$OUTPUT_DIR/v8/include/"

    echo ""
    echo "========================================"
    echo "  Quick rebuild complete!"
    echo "========================================"
    echo "  d8 binary: $OUTPUT_DIR/out/d8"
    exit 0
fi

# ---- Helper: clear stale lock files left by crashed processes ----
clear_stale_locks() {
    echo "  Clearing stale lock files..."
    find /opt/depot_tools -name "*.locked" -delete 2>/dev/null || true
    find /root/.cache -name "*.locked" -delete 2>/dev/null || true
}

# ---- Helper: gclient sync with retry ----
gclient_sync_retry() {
    local max_attempts=3
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        echo "  gclient sync (attempt $attempt/$max_attempts)..."
        clear_stale_locks
        if gclient sync -D --no-history 2>&1 | tee /tmp/gclient_sync.log | tail -5; then
            if ! grep -q "Subprocess failed" /tmp/gclient_sync.log; then
                return 0
            fi
        fi
        echo "  Sync failed, retrying..."
        attempt=$((attempt + 1))
        sleep 2
    done
    echo "  WARNING: gclient sync failed after $max_attempts attempts"
    echo "  Last output:"
    tail -20 /tmp/gclient_sync.log
    return 1
}

# ---- 1. Fetch or update V8 source ----
clear_stale_locks
if [ ! -f "/v8/.gclient" ]; then
    echo "[1/6] Fetching V8 source (first run — takes ~20-30 min)..."
    cd /v8
    fetch v8
    cd /v8/v8
    echo "[1/6] Installing build dependencies..."
    ./build/install-build-deps.sh --no-prompt --no-chromeos-fonts 2>&1 | tail -5 || true
else
    echo "[1/6] V8 source already fetched"
    cd /v8/v8
fi

# ---- 2. Checkout revision ----
echo "[2/6] Checking out revision $REVISION..."
git checkout -- . 2>/dev/null || true
git clean -fd 2>/dev/null || true
git fetch origin
git checkout "$REVISION" 2>/dev/null || {
    # If the revision is not a branch/tag, fetch it directly
    git fetch origin "$REVISION"
    git checkout "$REVISION"
}
echo "  Running gclient sync..."
gclient_sync_retry

# Re-run build deps in case the revision needs different packages
./build/install-build-deps.sh --no-prompt --no-chromeos-fonts 2>&1 | tail -3 || true

# ---- 3. Apply patch ----
if [ "$PATCH_FILE" != "none" ] && [ -f "$PATCH_FILE" ]; then
    echo "[3/6] Applying patch: $(basename "$PATCH_FILE")"
    git apply "$PATCH_FILE"
    echo "  Patch applied"
else
    echo "[3/6] No patch to apply"
fi

# ---- 4. Configure GN ----
echo "[4/6] Configuring build..."
GN_ARGS=$(tr '\n' ' ' < "$GN_ARGS_FILE" | sed 's/  */ /g; s/^ //; s/ $//')

# Inject ccache if not already specified
if [[ "$GN_ARGS" != *"cc_wrapper"* ]]; then
    GN_ARGS="$GN_ARGS cc_wrapper=\"ccache\""
fi

echo "  Args: $GN_ARGS"
gn gen out/x64-debug --args="$GN_ARGS"

# ---- 5. Build d8 ----
# Default to half of available cores to avoid OOM under Rosetta emulation.
# Each clang++ can use 1-2GB+ RAM with -O3, and Rosetta adds overhead.
TOTAL_CORES=$(nproc)
if [ -n "$MAX_JOBS" ]; then
    JOBS="$MAX_JOBS"
else
    JOBS=$(( TOTAL_CORES / 2 ))
    [ "$JOBS" -lt 2 ] && JOBS=2
fi
echo "[5/6] Building d8 ($JOBS/$TOTAL_CORES cores — use --jobs to override)..."
ninja -j"$JOBS" -C out/x64-debug d8

echo "  d8 built: $(file out/x64-debug/d8 | cut -d: -f2)"

# ---- 6. Copy artifacts ----
echo "[6/6] Copying artifacts to output..."

# Binaries
mkdir -p "$OUTPUT_DIR/out"
cp out/x64-debug/d8 "$OUTPUT_DIR/out/"
for f in icudtl.dat snapshot_blob.bin; do
    if [ -f "out/x64-debug/$f" ]; then
        cp "out/x64-debug/$f" "$OUTPUT_DIR/out/"
        echo "  Copied $f"
    fi
done

# Source tree for debug reference (src/, include/, tools/)
echo "  Syncing source for debug reference..."
for dir in src include; do
    mkdir -p "$OUTPUT_DIR/v8/$dir"
    rsync -a --delete "/v8/v8/$dir/" "$OUTPUT_DIR/v8/$dir/"
done
mkdir -p "$OUTPUT_DIR/v8/tools"
rsync -a "/v8/v8/tools/" "$OUTPUT_DIR/v8/tools/" 2>/dev/null || true

# Save applied patch for reference
if [ "$PATCH_FILE" != "none" ] && [ -f "$PATCH_FILE" ]; then
    cp "$PATCH_FILE" "$OUTPUT_DIR/patch.diff"
fi

# GDB/pwndbg init helper
cat > "$OUTPUT_DIR/out/.gdbinit" << 'GDBEOF'
# V8 source path mapping for pwndbg/GDB
# Build was done at /v8/v8/ — map to local source copy
set substitute-path /v8/v8 ../v8

# V8 GDB pretty-printers (if available)
python
import sys, os
v8_tools = os.path.expanduser("../v8/tools")
if os.path.isdir(v8_tools):
    sys.path.insert(0, v8_tools)
end
source ../v8/tools/gdbinit
source ../v8/tools/gdb/gdb_v8.py
GDBEOF

echo ""
echo "========================================"
echo "  Build complete!"
echo "========================================"
echo ""
echo "  d8 binary:  $OUTPUT_DIR/out/d8"
echo "  source ref:  $OUTPUT_DIR/v8/"
echo ""
echo "  In your VM:"
echo "    cd ~/Documents/vm-shared/$(basename "$OUTPUT_DIR")/out"
echo "    ./d8 --allow-natives-syntax exploit.js"
echo ""
echo "  Debug with pwndbg:"
echo "    cd ~/Documents/vm-shared/$(basename "$OUTPUT_DIR")/out"
echo "    gdb -x .gdbinit ./d8"
echo ""
