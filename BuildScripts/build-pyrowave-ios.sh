#!/bin/bash
# Build Granite + PyroWave + MoltenVK for iOS arm64
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
LIBS_DIR="$PROJECT_DIR/libs"

# Versions / revisions
MOLTENVK_VERSION="1.2.9"
GRANITE_REV="094adec89cbdb4f29ecaf858ed944a53ebe9d18a"
PYROWAVE_REV="217366d4d772eb800150fa57e703da295605d63f"
PYROWAVE_REPO="https://github.com/Themaister/pyrowave.git"
GRANITE_REPO="https://github.com/Themaister/Granite.git"
IOS_CMAKE_REPO="https://github.com/leetal/ios-cmake.git"

BUILD_DIR="/tmp/pyrowave-ios-build"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# ── ios-cmake toolchain ──────────────────────────────────────────
if [ ! -f "ios.toolchain.cmake" ]; then
    echo "=== Downloading ios-cmake ==="
    git clone --depth 1 -q "$IOS_CMAKE_REPO" ios-cmake
    cp ios-cmake/ios.toolchain.cmake .
fi

# ── MoltenVK ─────────────────────────────────────────────────────
if [ ! -d "moltenvk-extract" ]; then
    echo "=== Fetching MoltenVK ${MOLTENVK_VERSION} ==="
    curl -L "https://github.com/KhronosGroup/MoltenVK/releases/download/v${MOLTENVK_VERSION}/MoltenVK-ios.tar" -o moltenvk.tar
    mkdir -p moltenvk-extract
    tar xf moltenvk.tar -C moltenvk-extract
fi
mkdir -p "$LIBS_DIR/MoltenVK/include"
# Find MoltenVK.framework for ios-arm64 regardless of archive structure
FW="$(find "$BUILD_DIR/moltenvk-extract" -path "*/ios-arm64/MoltenVK.framework" -type d | head -1)"
if [ -z "$FW" ]; then
    echo "ERROR: MoltenVK.framework for ios-arm64 not found in archive"
    exit 1
fi
cp -R "$FW" "$LIBS_DIR/MoltenVK/"
# Copy Include directory if present
if [ -d "$BUILD_DIR/moltenvk-extract/Include" ]; then
    cp -R "$BUILD_DIR/moltenvk-extract/Include/" "$LIBS_DIR/MoltenVK/include/"
fi

# ── Granite ──────────────────────────────────────────────────────
if [ ! -d "Granite" ]; then
    echo "=== Fetching Granite ==="
    mkdir Granite
    cd Granite
    git init -q
    git remote add origin "$GRANITE_REPO"
    git fetch --depth 1 origin "$GRANITE_REV"
    git checkout FETCH_HEAD -q
    git submodule update --init --recursive --depth 1

    # Patch util/timer.cpp for iOS compatibility
    python3 << 'PYEOF'
old = '''#else
\tconstexpr auto timebase = CLOCK_MONOTONIC;
\tstruct timespec ts = {};
\tts.tv_sec = timepoint / 1000000000ll;
\tts.tv_nsec = timepoint % 1000000000ll;
\t// Linux does not support clock_nanosleep with MONOTONIC_RAW :(
\tint ret;
\twhile ((ret = clock_nanosleep(timebase, TIMER_ABSTIME, &ts, nullptr)) == EINTR) {}
#endif'''
new = '''#elif defined(__APPLE__)
\tint64_t d = timepoint - get_current_time_nsecs();
\tif (d > 0)
\t{
\t\tstruct timespec ts = {};
\t\tts.tv_sec = d / 1000000000ll;
\t\tts.tv_nsec = d % 1000000000ll;
\t\twhile (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
\t}
#else
\tconstexpr auto timebase = CLOCK_MONOTONIC;
\tstruct timespec ts = {};
\tts.tv_sec = timepoint / 1000000000ll;
\tts.tv_nsec = timepoint % 1000000000ll;
\t// Linux does not support clock_nanosleep with MONOTONIC_RAW :(
\tint ret;
\twhile ((ret = clock_nanosleep(timebase, TIMER_ABSTIME, &ts, nullptr)) == EINTR) {}
#endif'''
import sys
with open('util/timer.cpp') as f:
    content = f.read()
if old not in content:
    print('ERROR: Pattern not found in util/timer.cpp', file=sys.stderr)
    sys.exit(1)
content = content.replace(old, new, 1)
with open('util/timer.cpp', 'w') as f:
    f.write(content)
print('Patched util/timer.cpp for iOS')
PYEOF
    cd "$BUILD_DIR"
fi

# ── PyroWave ─────────────────────────────────────────────────────
if [ ! -d "pyrowave" ]; then
    echo "=== Fetching PyroWave ==="
    mkdir pyrowave
    cd pyrowave
    git init -q
    git remote add origin "$PYROWAVE_REPO"
    git fetch --depth 1 origin "$PYROWAVE_REV"
    git checkout FETCH_HEAD -q

    # Patch: 4:2:0 fragment iDWT horizontal pass needs 3 color attachments.
    # The horizontal shader (idwt_fs[2], CHROMA_CONFIG=2) has 3 outputs
    # (oY at loc 0, oCb at loc 1, oCr at loc 2) but the render pass only
    # had 2 attachments, so oCr was discarded (Cr plane never written).
    python3 << 'PYEOF'
old = '''			rp_info.store_attachments = 0x3;
			rp_info.num_color_attachments = 2;'''
new = '''			rp_info.store_attachments = 0x3;
			// HORIZONTAL pass needs 3 attachments for 4:2:0 (Y + Cb + Cr separate)
			// VERTICAL pass uses 2 attachments (Y + CbCr interleaved)
			rp_info.num_color_attachments = 3;'''
import sys
with open('pyrowave_decoder.cpp') as f:
    content = f.read()
if old not in content:
    print('ERROR: Pattern not found in pyrowave_decoder.cpp', file=sys.stderr)
    sys.exit(1)
content = content.replace(old, new, 1)
with open('pyrowave_decoder.cpp', 'w') as f:
    f.write(content)
print('Patched pyrowave_decoder.cpp: 3 color attachments for chroma iDWT')
PYEOF
    cd "$BUILD_DIR"
fi

# ── CMake build ──────────────────────────────────────────────────
# Only run cmake if build system doesn't exist (cache miss or first build)
if [ ! -f "build-ios/build.ninja" ]; then
    echo "=== Configuring Granite + PyroWave for iOS arm64 ==="
    mkdir -p build-ios
    cd build-ios

    # Write wrapper CMakeLists.txt so PyroWave is NOT a top-level project.
    # This avoids building test executables (which fail on iOS) and install targets.
    cat > CMakeLists.txt << 'WRAPPER'
cmake_minimum_required(VERSION 3.20)
project(pyrowave-ios LANGUAGES CXX C)

set(GRANITE_RENDERER OFF CACHE BOOL "" FORCE)
set(GRANITE_VULKAN_SPIRV_CROSS ON CACHE BOOL "" FORCE)
set(GRANITE_VULKAN_SYSTEM_HANDLES ON CACHE BOOL "" FORCE)
set(GRANITE_POSITION_INDEPENDENT ON CACHE BOOL "" FORCE)
set(GRANITE_VULKAN_FOSSILIZE OFF CACHE BOOL "" FORCE)
set(GRANITE_SHIPPING ON CACHE BOOL "" FORCE)
set(GRANITE_PLATFORM "null" CACHE STRING "" FORCE)
set(GRANITE_TOOLS OFF CACHE BOOL "" FORCE)
set(GRANITE_VIDEO OFF CACHE BOOL "" FORCE)
set(GRANITE_FFMPEG OFF CACHE BOOL "" FORCE)

add_subdirectory(${GRANITE_SOURCE_DIR} Granite)
add_subdirectory(${PYROWAVE_SOURCE_DIR} pyrowave)
WRAPPER

    cmake . -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$BUILD_DIR/ios.toolchain.cmake" \
        -DPLATFORM=OS64 \
        -DGRANITE_SOURCE_DIR="$BUILD_DIR/Granite" \
        -DPYROWAVE_SOURCE_DIR="$BUILD_DIR/pyrowave"

    cd "$BUILD_DIR"
fi

cd build-ios
ninja -j$(sysctl -n hw.logicalcpu)

# ── Copy artifacts to project libs/ ──────────────────────────────
echo "=== Copying libraries ==="
mkdir -p "$LIBS_DIR/PyroWave/lib" "$LIBS_DIR/PyroWave/include"
mkdir -p "$LIBS_DIR/Granite/lib" "$LIBS_DIR/Granite/include"

cp pyrowave/libpyrowave.a "$LIBS_DIR/PyroWave/lib/libpyrowave.a"
# PyroWave headers (if any *.hpp in the pyrowave source root)
if ls "$BUILD_DIR/pyrowave"/*.hpp &>/dev/null; then
    cp "$BUILD_DIR/pyrowave"/*.hpp "$LIBS_DIR/PyroWave/include/"
fi

# Granite static libs (from the build tree)
find . -name "*.a" -exec cp {} "$LIBS_DIR/Granite/lib/" \;
# Granite headers (hpp/h from source, preserving tree)
rsync -a --include='*/' --include='*.hpp' --include='*.h' --exclude='*' \
  "$BUILD_DIR/Granite/" "$LIBS_DIR/Granite/include/"
# Remove third-party headers that shadow Apple system headers
rm -rf "$LIBS_DIR/Granite/include/third_party/rapidjson/include/rapidjson/msinttypes"
find "$LIBS_DIR/Granite/include/third_party" -type d -name dirent -exec rm -rf {} + 2>/dev/null || true

echo "=== Build complete ==="
echo "Libraries placed in:"
echo "  $LIBS_DIR/MoltenVK/"
echo "  $LIBS_DIR/Granite/"
echo "  $LIBS_DIR/PyroWave/"
