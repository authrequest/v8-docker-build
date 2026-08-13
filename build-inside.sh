#!/bin/bash
set -euo pipefail

REVISION="$1"
PATCH_FILE="${2:-none}"
GN_ARGS_FILE="$3"
OUTPUT_DIR="$4"
MAX_JOBS="${5:-}"

QUICK_MODE="${QUICK_MODE:-false}"
BUILD_MODE="${BUILD_MODE:-d8}"

# Set build parameters based on mode
if [ "$BUILD_MODE" = "dasm" ]; then
    BUILD_DIR="out/x64-release"
    NINJA_TARGETS="v8_monolith v8_libplatform"
    OUTPUT_BINARY="v8dasm"
else
    BUILD_DIR="out/x64-debug"
    NINJA_TARGETS="d8"
    OUTPUT_BINARY="d8"
fi

echo "========================================"
echo "  V8 Builder"
if [ "$QUICK_MODE" = "true" ]; then
    echo "  Mode: QUICK REBUILD ($BUILD_MODE)"
else
    echo "  Revision: $REVISION"
    echo "  Build: $BUILD_MODE"
fi
echo "========================================"

# ---- v8dasm compile+link function ----
compile_v8dasm() {
    local V8_DIR="/v8/v8"
    local CLANG="$V8_DIR/third_party/llvm-build/Release+Asserts/bin/clang++"

    cp /tmp/v8dasm.cpp "$V8_DIR/v8dasm.cpp"

    echo "  Compiling v8dasm.cpp..."
    "$CLANG" -std=c++20 -fno-exceptions -O2 \
        -I"$V8_DIR" -I"$V8_DIR/include" \
        -isystem "$V8_DIR/buildtools/third_party/libc++" \
        -isystem "$V8_DIR/third_party/libc++/src/include" \
        -DV8_COMPRESS_POINTERS \
        -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE \
        -D_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS \
        -c "$V8_DIR/v8dasm.cpp" -o "$V8_DIR/v8dasm.o"

    echo "  Linking v8dasm..."

    local MONOLITH="$V8_DIR/$BUILD_DIR/obj/libv8_monolith.a"
    local LIBPLATFORM="$V8_DIR/$BUILD_DIR/obj/libv8_libplatform.a"

    if [ ! -f "$MONOLITH" ]; then
        echo "  ERROR: libv8_monolith.a not found at $MONOLITH"
        echo "  Searching for it..."
        find "$V8_DIR/$BUILD_DIR" -name "*v8_monolith*" -o -name "*monolith*" 2>/dev/null | head -5
        return 1
    fi
    if [ ! -f "$LIBPLATFORM" ]; then
        echo "  ERROR: libv8_libplatform.a not found at $LIBPLATFORM"
        echo "  Searching for it..."
        find "$V8_DIR/$BUILD_DIR" -name "*libplatform*" 2>/dev/null | head -5
        return 1
    fi

    # Find libc++ — try .o files first, then .a archive
    local LIBCXX_OBJS_DIR="$V8_DIR/$BUILD_DIR/obj/buildtools/third_party/libc++/libc++"
    local LIBCXX_LINK_ARGS=()

    if ls "$LIBCXX_OBJS_DIR"/*.o >/dev/null 2>&1; then
        LIBCXX_LINK_ARGS=("$LIBCXX_OBJS_DIR"/*.o)
    elif [ -f "$LIBCXX_OBJS_DIR/libc++.a" ]; then
        LIBCXX_LINK_ARGS=("$LIBCXX_OBJS_DIR/libc++.a")
    fi

    local LIBCXXABI_DIR="$V8_DIR/$BUILD_DIR/obj/buildtools/third_party/libc++abi/libc++abi"
    if ls "$LIBCXXABI_DIR"/*.o >/dev/null 2>&1; then
        LIBCXX_LINK_ARGS+=("$LIBCXXABI_DIR"/*.o)
    elif [ -f "$LIBCXXABI_DIR/libc++abi.a" ]; then
        LIBCXX_LINK_ARGS+=("$LIBCXXABI_DIR/libc++abi.a")
    fi

    if [ ${#LIBCXX_LINK_ARGS[@]} -gt 0 ]; then
        "$CLANG" -nostdlib++ -o "$V8_DIR/v8dasm" \
            "$V8_DIR/v8dasm.o" \
            "$MONOLITH" \
            "$LIBPLATFORM" \
            "${LIBCXX_LINK_ARGS[@]}" \
            -lpthread -ldl -latomic -lrt
    else
        echo "  WARNING: libc++ objects not found, linking without -nostdlib++"
        "$CLANG" -o "$V8_DIR/v8dasm" \
            "$V8_DIR/v8dasm.o" \
            "$MONOLITH" \
            "$LIBPLATFORM" \
            -lpthread -ldl -latomic -lrt
    fi

    echo "  v8dasm built: $(file "$V8_DIR/v8dasm" | cut -d: -f2)"
}

# ---- Ensure depot_tools is bootstrapped ----
gclient --version >/dev/null 2>&1 || true

# ---- Quick rebuild mode ----
if [ "$QUICK_MODE" = "true" ]; then
    cd /v8/v8

    # Sync edited source files from output back into build tree
    if [ -d "$OUTPUT_DIR/v8/src" ]; then
        echo "[1/4] Syncing source edits from output into build tree..."
        rsync -a "$OUTPUT_DIR/v8/src/" /v8/v8/src/
        rsync -a "$OUTPUT_DIR/v8/include/" /v8/v8/include/ 2>/dev/null || true
    else
        echo "[1/4] No source edits to sync"
    fi

    # Configure (in case args changed)
    echo "[2/4] Configuring build..."
    GN_ARGS=$(tr '\n' ' ' < "$GN_ARGS_FILE" | sed 's/  */ /g; s/^ //; s/ $//')
    if [[ "$GN_ARGS" != *"cc_wrapper"* ]]; then
        GN_ARGS="$GN_ARGS cc_wrapper=\"ccache\""
    fi
    gn gen "$BUILD_DIR" --args="$GN_ARGS"

    # Build
    TOTAL_CORES=$(nproc)
    if [ -n "$MAX_JOBS" ]; then
        JOBS="$MAX_JOBS"
    else
        JOBS=$(( TOTAL_CORES / 2 ))
        [ "$JOBS" -lt 2 ] && JOBS=2
    fi
    echo "[3/4] Rebuilding $NINJA_TARGETS ($JOBS cores)..."
    ninja -j"$JOBS" -C "$BUILD_DIR" $NINJA_TARGETS

    # Compile v8dasm if in dasm mode
    if [ "$BUILD_MODE" = "dasm" ]; then
        echo "[4/4] Compiling v8dasm..."
        compile_v8dasm
    else
        echo "  d8 built: $(file "$BUILD_DIR/d8" | cut -d: -f2)"
    fi

    # Copy binaries
    mkdir -p "$OUTPUT_DIR/out"
    if [ "$BUILD_MODE" = "dasm" ]; then
        cp /v8/v8/v8dasm "$OUTPUT_DIR/out/"
    else
        cp "$BUILD_DIR/d8" "$OUTPUT_DIR/out/"
        for f in icudtl.dat snapshot_blob.bin; do
            [ -f "$BUILD_DIR/$f" ] && cp "$BUILD_DIR/$f" "$OUTPUT_DIR/out/"
        done
    fi

    # Sync source back to output (picks up any torque-generated changes)
    rsync -a --delete /v8/v8/src/ "$OUTPUT_DIR/v8/src/"
    rsync -a --delete /v8/v8/include/ "$OUTPUT_DIR/v8/include/"

    echo ""
    echo "========================================"
    echo "  Quick rebuild complete!"
    echo "========================================"
    echo "  $OUTPUT_BINARY binary: $OUTPUT_DIR/out/$OUTPUT_BINARY"
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
    echo "[1/7] Fetching V8 source (first run — takes ~20-30 min)..."
    cd /v8
    fetch v8
    cd /v8/v8
    echo "[1/7] Installing build dependencies..."
    ./build/install-build-deps.sh --no-prompt --no-chromeos-fonts 2>&1 | tail -5 || true
else
    echo "[1/7] V8 source already fetched"
    cd /v8/v8
fi

# ---- 2. Checkout revision ----
echo "[2/7] Checking out revision $REVISION..."
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
    echo "[3/7] Applying patch: $(basename "$PATCH_FILE")"
    git apply "$PATCH_FILE"
    echo "  Patch applied"
else
    echo "[3/7] No patch to apply"
fi

# ---- 4. Configure GN ----
echo "[4/7] Configuring build..."
GN_ARGS=$(tr '\n' ' ' < "$GN_ARGS_FILE" | sed 's/  */ /g; s/^ //; s/ $//')

# Inject ccache if not already specified
if [[ "$GN_ARGS" != *"cc_wrapper"* ]]; then
    GN_ARGS="$GN_ARGS cc_wrapper=\"ccache\""
fi

echo "  Args: $GN_ARGS"
gn gen "$BUILD_DIR" --args="$GN_ARGS"

# ---- 5. Build ----
TOTAL_CORES=$(nproc)
if [ -n "$MAX_JOBS" ]; then
    JOBS="$MAX_JOBS"
else
    JOBS=$(( TOTAL_CORES / 2 ))
    [ "$JOBS" -lt 2 ] && JOBS=2
fi
echo "[5/7] Building $NINJA_TARGETS ($JOBS/$TOTAL_CORES cores — use --jobs to override)..."
ninja -j"$JOBS" -C "$BUILD_DIR" $NINJA_TARGETS

if [ "$BUILD_MODE" = "d8" ]; then
    echo "  d8 built: $(file "$BUILD_DIR/d8" | cut -d: -f2)"
fi

# ---- 6. Compile v8dasm (dasm mode only) ----
if [ "$BUILD_MODE" = "dasm" ]; then
    echo "[6/7] Compiling v8dasm..."
    compile_v8dasm
else
    echo "[6/7] Skipping (d8 mode)"
fi

# ---- 7. Copy artifacts ----
echo "[7/7] Copying artifacts to output..."

mkdir -p "$OUTPUT_DIR/out"

if [ "$BUILD_MODE" = "dasm" ]; then
    cp /v8/v8/v8dasm "$OUTPUT_DIR/out/"
    echo "  Copied v8dasm"
else
    cp "$BUILD_DIR/d8" "$OUTPUT_DIR/out/"
    for f in icudtl.dat snapshot_blob.bin; do
        if [ -f "$BUILD_DIR/$f" ]; then
            cp "$BUILD_DIR/$f" "$OUTPUT_DIR/out/"
            echo "  Copied $f"
        fi
    done
fi

# Source tree for debug reference (src/, include/, tools/)
echo "  Syncing source for reference..."
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

# GDB/pwndbg init helper (d8 mode only)
if [ "$BUILD_MODE" = "d8" ]; then
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
fi

echo ""
echo "========================================"
echo "  Build complete!"
echo "========================================"
echo ""

if [ "$BUILD_MODE" = "dasm" ]; then
    echo "  v8dasm binary: $OUTPUT_DIR/out/v8dasm"
    echo ""
    echo "  Usage:"
    echo "    ./v8dasm <path-to-jsc-file>"
    echo ""
else
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
fi
