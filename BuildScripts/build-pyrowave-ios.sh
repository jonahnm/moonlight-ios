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
    git clone --depth 1 "$IOS_CMAKE_REPO" ios-cmake
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
    git clone "$GRANITE_REPO" Granite
    cd Granite
    git checkout "$GRANITE_REV"
    cd "$BUILD_DIR"
fi

# ── PyroWave ─────────────────────────────────────────────────────
if [ ! -d "pyrowave" ]; then
    echo "=== Fetching PyroWave ==="
    git clone "$PYROWAVE_REPO" pyrowave
    cd pyrowave
    git checkout "$PYROWAVE_REV"
    cd "$BUILD_DIR"
fi

# ── CMake build ──────────────────────────────────────────────────
echo "=== Building Granite + PyroWave for iOS arm64 ==="
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
set(GRANITE_VIDEO OFF CACHE BOOL "" FORCE)
set(GRANITE_FFMPEG OFF CACHE BOOL "" FORCE)

add_subdirectory(${GRANITE_SOURCE_DIR} Granite EXCLUDE_FROM_ALL)
add_subdirectory(${PYROWAVE_SOURCE_DIR} pyrowave EXCLUDE_FROM_ALL)
WRAPPER

cmake . -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$BUILD_DIR/ios.toolchain.cmake" \
    -DPLATFORM=OS64 \
    -DGRANITE_SOURCE_DIR="$BUILD_DIR/Granite" \
    -DPYROWAVE_SOURCE_DIR="$BUILD_DIR/pyrowave" \
    -DVulkan_INCLUDE_DIR="$LIBS_DIR/MoltenVK/include" \
    -DVulkan_LIBRARY="$LIBS_DIR/MoltenVK/MoltenVK.framework"

ninja -j$(sysctl -n hw.logicalcpu)

# ── Copy artifacts to project libs/ ──────────────────────────────
echo "=== Copying libraries ==="
mkdir -p "$LIBS_DIR/PyroWave/lib" "$LIBS_DIR/PyroWave/include"
mkdir -p "$LIBS_DIR/Granite/lib" "$LIBS_DIR/Granite/include"

cp libpyrowave.a "$LIBS_DIR/PyroWave/lib/libpyrowave.a"
# PyroWave headers (if any *.hpp in the pyrowave source root)
if ls "$BUILD_DIR/pyrowave"/*.hpp &>/dev/null; then
    cp "$BUILD_DIR/pyrowave"/*.hpp "$LIBS_DIR/PyroWave/include/"
fi

# Granite static libs (from the build tree)
find . -name "*.a" -exec cp {} "$LIBS_DIR/Granite/lib/" \;
# Granite headers (hpp/h from source, preserving tree)
rsync -a --include='*/' --include='*.hpp' --include='*.h' --exclude='*' "$BUILD_DIR/Granite/" "$LIBS_DIR/Granite/include/"

echo "=== Build complete ==="
echo "Libraries placed in:"
echo "  $LIBS_DIR/MoltenVK/"
echo "  $LIBS_DIR/Granite/"
echo "  $LIBS_DIR/PyroWave/"
