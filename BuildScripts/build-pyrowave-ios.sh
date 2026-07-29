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
MOLTENVK_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v${MOLTENVK_VERSION}/MoltenVK-${MOLTENVK_VERSION}.tar.gz"
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
if [ ! -d "MoltenVK" ]; then
    echo "=== Fetching MoltenVK ${MOLTENVK_VERSION} ==="
    curl -L "$MOLTENVK_URL" -o moltenvk.tar.gz
    tar xzf moltenvk.tar.gz
fi
MOLTENVK_DIR="$BUILD_DIR/MoltenVK"
mkdir -p "$LIBS_DIR/MoltenVK/include"
cp -R "$MOLTENVK_DIR/MoltenVK.xcframework/ios-arm64/MoltenVK.framework" "$LIBS_DIR/MoltenVK/"
cp -R "$MOLTENVK_DIR/Include/" "$LIBS_DIR/MoltenVK/include/"

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

cmake ../pyrowave -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$BUILD_DIR/ios.toolchain.cmake" \
    -DPLATFORM=OS64 \
    -DGRANITE_SOURCE_DIR="$BUILD_DIR/Granite" \
    -DPYROWAVE_DEVEL=OFF \
    -DGRANITE_VULKAN_SYSTEM_HANDLES=ON \
    -DGRANITE_VULKAN_SPIRV_CROSS=ON \
    -DSDL_UNIX_CONSOLE_BUILD=ON \
    -DSDL_SHARED=OFF \
    -DSDL_STATIC=OFF \
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
