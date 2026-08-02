#!/bin/bash
# Build Granite + PyroWave + MoltenVK for tvOS arm64
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
LIBS_DIR="$PROJECT_DIR/libs"

# Versions / revisions (same as iOS build)
MOLTENVK_VERSION="1.4.2"
GRANITE_REV="094adec89cbdb4f29ecaf858ed944a53ebe9d18a"
PYROWAVE_REV="217366d4d772eb800150fa57e703da295605d63f"
PYROWAVE_REPO="https://github.com/Themaister/pyrowave.git"
GRANITE_REPO="https://github.com/Themaister/Granite.git"
IOS_CMAKE_REPO="https://github.com/leetal/ios-cmake.git"

BUILD_DIR="/tmp/pyrowave-tvos-build"
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
    echo "=== Fetching MoltenVK ${MOLTENVK_VERSION} for tvOS ==="
    curl -L "https://github.com/KhronosGroup/MoltenVK/releases/download/v${MOLTENVK_VERSION}/MoltenVK-all.tar" -o moltenvk.tar
    mkdir -p moltenvk-extract
    tar xf moltenvk.tar -C moltenvk-extract
fi
mkdir -p "$LIBS_DIR/MoltenVK/include"
# Find MoltenVK.framework for tvos-arm64 from the xcframework archive
FW="$(find "$BUILD_DIR/moltenvk-extract" -path "*/tvos-arm64*/MoltenVK.framework" -type d | head -1)"
if [ -z "$FW" ]; then
    echo "ERROR: MoltenVK.framework for tvos-arm64 not found in archive"
    exit 1
fi
cp -R "$FW" "$LIBS_DIR/MoltenVK/"
# Copy Include directory if present (both old and new archive layouts)
if [ -d "$BUILD_DIR/moltenvk-extract/Include" ]; then
    cp -R "$BUILD_DIR/moltenvk-extract/Include/" "$LIBS_DIR/MoltenVK/include/"
elif [ -d "$BUILD_DIR/moltenvk-extract/MoltenVK/MoltenVK/include" ]; then
    cp -R "$BUILD_DIR/moltenvk-extract/MoltenVK/MoltenVK/include/" "$LIBS_DIR/MoltenVK/include/"
elif [ -d "$BUILD_DIR/moltenvk-extract/MoltenVK/include" ]; then
    cp -R "$BUILD_DIR/moltenvk-extract/MoltenVK/include/" "$LIBS_DIR/MoltenVK/include/"
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

    # Patch util/timer.cpp for iOS/tvOS compatibility
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
print('Patched util/timer.cpp for tvOS')
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

cd "$BUILD_DIR"
fi

# Remove any leftover DEBUG clear_image block from pyrowave_decoder.cpp.
# This guarantees the decoder leaves its real iDWT output in the YUV planes
# regardless of what stale cache is restored.
python3 << 'PYEOF'
import sys
path = 'pyrowave/pyrowave_decoder.cpp'
with open(path) as f:
    content = f.read()
start = content.find('\t// DEBUG: Overwrite Y plane')
if start != -1:
    end = content.find('\n\tdecoded_frame_for_current_sequence = true;', start)
    if end != -1:
        content = content[:start] + '\tdecoded_frame_for_current_sequence = true;' + content[end + len('\n\tdecoded_frame_for_current_sequence = true;'):]
        with open(path, 'w') as f:
            f.write(content)
        print('Removed DEBUG clear_image block from pyrowave_decoder.cpp')
    else:
        print('WARNING: found DEBUG block start but no end marker', file=sys.stderr)
        sys.exit(1)
else:
    print('No DEBUG clear_image block present (already clean)')
PYEOF

# ── CMake build ──────────────────────────────────────────────────
if [ ! -f "build-tvos/build.ninja" ]; then
    echo "=== Configuring Granite + PyroWave for tvOS arm64 ==="
    mkdir -p build-tvos
    cd build-tvos

    # Write wrapper CMakeLists.txt so PyroWave is NOT a top-level project.
    # This avoids building test executables (which fail on iOS) and install targets.
    cat > CMakeLists.txt << 'WRAPPER'
cmake_minimum_required(VERSION 3.20)
project(pyrowave-tvos LANGUAGES CXX C)

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
        -DPLATFORM=TVOS \
        -DGRANITE_SOURCE_DIR="$BUILD_DIR/Granite" \
        -DPYROWAVE_SOURCE_DIR="$BUILD_DIR/pyrowave"

    cd "$BUILD_DIR"
fi

cd build-tvos
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
