// Native Metal compute shaders for PyroWave decompression.
// These bypass MoltenVK's SPIR-V compiler and work directly with Metal.
#include <metal_stdlib>
using namespace metal;

// Simple test: fill a texture with a solid gray value
kernel void mw_fillGray(
    texture2d<float, access::write> outTex [[texture(0)]],
    constant float &fillValue [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x < outTex.get_width() && gid.y < outTex.get_height()) {
        outTex.write(fillValue, gid);
    }
}
