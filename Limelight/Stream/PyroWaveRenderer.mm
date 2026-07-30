#import "PyroWaveRenderer.h"
#import "PyroWaveShaders.h"
#import "StreamView.h"

#include <QuartzCore/CAMetalLayer.h>
#include <SDL.h>

#pragma push_macro("signals")
#undef signals

// Xcode 15.4 / iOS 17.5 SDK workaround: the prebuilt Darwin.C.time module
// doesn't export nanosleep or struct tm. Provide them directly.
// NOTE: _LIBCPP_HAS_NO_WIDE_CHARACTERS=1 (set in project defines) prevents
// <cwchar> -> <wchar.h> from textually redefining struct tm, which would
// conflict with this definition.
struct tm {
  int tm_sec; int tm_min; int tm_hour; int tm_mday; int tm_mon;
  int tm_year; int tm_wday; int tm_yday; int tm_isdst;
  long tm_gmtoff; const char *tm_zone;
};
extern "C" int nanosleep(const struct timespec *, struct timespec *);

// Enable Metal surface extension and use Granite's Vulkan header wrapper
#define VK_USE_PLATFORM_METAL_EXT 1
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan_headers.hpp>
// Alias for renamed Vulkan extension type (EXT is now defined by vulkan.h)
typedef VkPhysicalDeviceFaultFeaturesEXT VkPhysicalDeviceFaultFeaturesKHR;

#include <dlfcn.h>

// Returns MoltenVK's real vkGetInstanceProcAddr entry point.
//
// volk defines a global *variable* named vkGetInstanceProcAddr which shadows
// MoltenVK's exported *function* for both link-time binding and RTLD_DEFAULT
// lookups, and Granite's fallback dlopen("libMoltenVK.dylib") cannot find an
// embedded iOS framework. dlopen the embedded framework explicitly and use a
// handle-scoped dlsym to bypass the shadowing.
static PFN_vkGetInstanceProcAddr loadMoltenVKGIPA(void) {
    static PFN_vkGetInstanceProcAddr gipa = nullptr;
    if (!gipa) {
        void *h = dlopen("@executable_path/Frameworks/MoltenVK.framework/MoltenVK",
                         RTLD_LAZY | RTLD_LOCAL);
        if (h) {
            gipa = (PFN_vkGetInstanceProcAddr)dlsym(h, "vkGetInstanceProcAddr");
        }
    }
    return gipa;
}

#include "context.hpp"
#include "device.hpp"
#include "wsi.hpp"
#include "command_buffer.hpp"
#include "image.hpp"
#include "thread_id.hpp"

#include "pyrowave_decoder.hpp"
#include "pyrowave_config.hpp"
#include "pyrowave_common.hpp"

#pragma pop_macro("signals")

#include <cstring>
#include <vector>
#include <memory>

using namespace Vulkan;

static void claimGraniteThread() {
    static thread_local bool registered = false;
    if (!registered) {
        Util::register_thread_index(0);
        registered = true;
    }
}

namespace {

class IOSWSIPlatform : public WSIPlatform {
public:
    void set_layer(CAMetalLayer *layer, UIView *view) {
        metalLayer = layer;
        uiView = view;
    }

    VkSurfaceKHR create_surface(VkInstance instance, VkPhysicalDevice) override {
        if (!metalLayer) return VK_NULL_HANDLE;
        VkMetalSurfaceCreateInfoEXT sci = {};
        sci.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
        sci.pNext = nullptr;
        sci.flags = 0;
        sci.pLayer = metalLayer;
        VkSurfaceKHR surface = VK_NULL_HANDLE;
        PFN_vkCreateMetalSurfaceEXT vkCreateMetalSurfaceEXT =
            (PFN_vkCreateMetalSurfaceEXT)vkGetInstanceProcAddr(instance, "vkCreateMetalSurfaceEXT");
        if (!vkCreateMetalSurfaceEXT) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "PyroWave: vkCreateMetalSurfaceEXT not found");
            return VK_NULL_HANDLE;
        }
        VkResult res = vkCreateMetalSurfaceEXT(instance, &sci, nullptr, &surface);
        if (res != VK_SUCCESS) {
            SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                         "PyroWave: vkCreateMetalSurfaceEXT failed: %d", res);
            return VK_NULL_HANDLE;
        }
        return surface;
    }

    std::vector<const char *> get_instance_extensions() override {
        return {
            VK_KHR_SURFACE_EXTENSION_NAME,
            VK_EXT_METAL_SURFACE_EXTENSION_NAME,
            "VK_KHR_get_physical_device_properties2",
        };
    }

    uint32_t get_surface_width() override {
        if (!metalLayer) return 0;
        CGSize s = metalLayer.drawableSize;
        return (uint32_t)s.width;
    }

    uint32_t get_surface_height() override {
        if (!metalLayer) return 0;
        CGSize s = metalLayer.drawableSize;
        return (uint32_t)s.height;
    }

    bool alive(WSI &) override { return metalLayer != nullptr; }
    void poll_input() override {}
    void poll_input_async(Granite::InputTrackerHandler *) override {}

private:
    CAMetalLayer *metalLayer = nullptr;
    UIView *uiView = nullptr;
};

} // namespace

// Forward declared in @implementation below
struct PyroWaveImpl {
    UIView *view = nil;
    CAMetalLayer *metalLayer = nil;
    IOSWSIPlatform platform;
    WSI wsi;
    Device *device = nullptr;

    int videoFormat = 0;
    int width = 0, height = 0, chromaW = 0, chromaH = 0;
    PyroWave::ChromaSubsampling chroma = PyroWave::ChromaSubsampling::Chroma420;

    bool is_hdr = false;
    bool bt2020 = false;
    bool full_range = false;

    bool decoder_ready = false;
    bool swapchain_ready = false;
    bool initialized = false;

    PyroWave::Decoder decoder;
    ImageHandle yuvImages[3];
    PyroWave::ViewBuffers views;
    Program *present_program = nullptr;

    std::vector<uint8_t> packetScratch;

    bool init_swapchain(bool want_hdr);
    bool init_decoder(PyroWave::ChromaSubsampling c);
};

static void LogPyro(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:[@"[PyroWave] " stringByAppendingString:fmt] arguments:args];
    va_end(args);
    fprintf(stderr, "%s\n", msg.UTF8String);
    // Public os_log so messages survive iOS privacy redaction in device logs
    os_log(MoonlightPublicLog(), "%{public}s", msg.UTF8String);
}

@implementation PyroWaveRenderer {
    std::unique_ptr<PyroWaveImpl> d;
    int _videoFormat;
    bool _stopped;
}

- (id)initWithView:(UIView*)view {
    self = [super init];
    if (self) {
        d = std::make_unique<PyroWaveImpl>();
        d->view = view;
        _stopped = false;

        CGFloat scale = [UIScreen mainScreen].nativeScale;
        __block CAMetalLayer *layer = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            layer = [CAMetalLayer layer];
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.contentsScale = scale;
            layer.frame = view.bounds;
            layer.drawableSize = CGSizeMake(view.bounds.size.width * scale, view.bounds.size.height * scale);
            layer.opaque = YES;
            [view.layer addSublayer:layer];
        });
        d->metalLayer = layer;

        LogPyro(@"initWithView bounds=%.0fx%.0f scale=%.1f drawable=%.0fx%.0f",
                view.bounds.size.width, view.bounds.size.height, scale,
                layer.drawableSize.width, layer.drawableSize.height);
    }
    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight {
    _videoFormat = videoFormat;
    d->videoFormat = videoFormat;
    d->width = videoWidth;
    d->height = videoHeight;
    LogPyro(@"setupWithVideoFormat format=0x%x width=%d height=%d", videoFormat, videoWidth, videoHeight);
}

- (BOOL)isReady {
    return d->initialized;
}

- (BOOL)initializeDecoder {
    if (d->initialized) return YES;

    claimGraniteThread();

    void (^updateLayer)(void) = ^{
        if (self->d->metalLayer && self->d->view) {
            CGFloat scale = [UIScreen mainScreen].nativeScale;
            self->d->metalLayer.frame = self->d->view.bounds;
            self->d->metalLayer.contentsScale = scale;
            self->d->metalLayer.drawableSize = CGSizeMake(self->d->view.bounds.size.width * scale, self->d->view.bounds.size.height * scale);
        }
    };
    if ([NSThread isMainThread]) {
        updateLayer();
    } else {
        dispatch_sync(dispatch_get_main_queue(), updateLayer);
    }

    LogPyro(@"Initializing Vulkan context (%dx%d)...", d->width, d->height);

    PFN_vkGetInstanceProcAddr gipa = loadMoltenVKGIPA();
    if (!gipa) {
        LogPyro(@"Failed to locate MoltenVK vkGetInstanceProcAddr (embedded framework missing?)");
        return NO;
    }
    if (!Context::init_loader(gipa)) {
        LogPyro(@"Vulkan loader init failed");
        return NO;
    }

    d->platform.set_layer(d->metalLayer, d->view);

    auto iext = d->platform.get_instance_extensions();
    const char *dext[] = { "VK_KHR_swapchain" };

    ContextHandle ctx = Util::make_handle<Context>();
    // Disable push descriptors — MoltenVK's push-descriptor path crashes on
    // texel-buffer descriptors (used by PyroWave's texel-buffer fallback on Apple).
    // Standard descriptor sets (vkUpdateDescriptorSets) are stable.
    if (!ctx->init_instance_and_device(iext.data(), (uint32_t)iext.size(), dext, 1,
                                       0)) {
        LogPyro(@"Granite Vulkan context init failed");
        return NO;
    }

    d->wsi.set_platform(&d->platform);
    d->wsi.set_present_mode(PresentMode::UnlockedNoTearing);
    d->wsi.set_backbuffer_format(BackbufferFormat::UNORM);

    if (!d->wsi.init_from_existing_context(std::move(ctx))) {
        LogPyro(@"WSI context init failed");
        return NO;
    }
    if (!d->wsi.init_device()) {
        LogPyro(@"WSI device init failed");
        return NO;
    }
    d->device = &d->wsi.get_device();

    d->present_program = d->device->request_program(
        fullscreen_vert_spv, sizeof(fullscreen_vert_spv),
        yuv2rgb_frag_spv, sizeof(yuv2rgb_frag_spv));
    if (!d->present_program) {
        LogPyro(@"Present program creation failed");
        return NO;
    }

    d->initialized = true;
    LogPyro(@"Vulkan context ready %dx%d", d->width, d->height);
    return YES;
}

- (int)submitDecodeUnit:(PDECODE_UNIT)du {
    claimGraniteThread();

    if (_stopped) return DR_OK;

    if (!d->initialized) {
        if (![self initializeDecoder]) {
            LogPyro(@"initializeDecoder failed");
            return DR_NEED_IDR;
        }
    }

    const uint8_t *frameData;
    size_t frameLen;

    if (du->bufferList->next == nullptr) {
        frameData = (const uint8_t *)du->bufferList->data;
        frameLen = (size_t)du->bufferList->length;
    } else {
        d->packetScratch.clear();
        d->packetScratch.reserve((size_t)du->fullLength);
        for (PLENTRY entry = du->bufferList; entry != nullptr; entry = entry->next) {
            const uint8_t *p = (const uint8_t *)entry->data;
            d->packetScratch.insert(d->packetScratch.end(), p, p + entry->length);
        }
        frameData = d->packetScratch.data();
        frameLen = d->packetScratch.size();
    }

    if (!d->decoder_ready) {
        if (frameLen < sizeof(PyroWave::BitstreamSequenceHeader)) {
            LogPyro(@"frameLen %zu < header %zu, requesting IDR", frameLen, sizeof(PyroWave::BitstreamSequenceHeader));
            return DR_NEED_IDR;
        }
        auto *seq = (const PyroWave::BitstreamSequenceHeader *)frameData;
        if (!seq->extended) {
            LogPyro(@"Bitstream sequence header missing extended flag, requesting IDR");
            return DR_NEED_IDR;
        }

        auto detected = (seq->chroma_resolution == PyroWave::CHROMA_RESOLUTION_444)
                            ? PyroWave::ChromaSubsampling::Chroma444
                            : PyroWave::ChromaSubsampling::Chroma420;
        d->bt2020 = seq->color_primaries == PyroWave::COLOR_PRIMARIES_BT2020;
        d->full_range = seq->ycbcr_range == PyroWave::YCBCR_RANGE_FULL;
        d->is_hdr = seq->transfer_function == PyroWave::TRANSFER_FUNCTION_PQ;

        LogPyro(@"IDR sequence header detected: chroma=%s hdr=%d bt2020=%d full_range=%d",
                (detected == PyroWave::ChromaSubsampling::Chroma444) ? "4:4:4" : "4:2:0",
                d->is_hdr, d->bt2020, d->full_range);

        if (!d->init_swapchain(d->is_hdr)) {
            LogPyro(@"init_swapchain failed");
            return DR_NEED_IDR;
        }
        if (!d->init_decoder(detected)) {
            LogPyro(@"init_decoder failed");
            return DR_NEED_IDR;
        }
    }

    if (!d->decoder.push_packet(frameData, frameLen)) {
        LogPyro(@"push_packet() failed");
        d->decoder.clear();
        return DR_NEED_IDR;
    }

    if (!d->decoder.decode_is_ready(false))
        return DR_OK;

    LogPyro(@"frame %u: decode_is_ready, begin_frame", du->frameNumber);

    if (!d->wsi.begin_frame()) {
        LogPyro(@"wsi.begin_frame() returned false");
        return DR_OK;
    }

    auto cmd = d->device->request_command_buffer();

    if (!d->decoder.decode(*cmd, d->views)) {
        LogPyro(@"decode() failed");
        d->device->submit(cmd);
        d->wsi.end_frame();
        return DR_NEED_IDR;
    }

    LogPyro(@"frame %u: decode done, presenting", du->frameNumber);

    cmd->barrier(VK_PIPELINE_STAGE_2_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                 VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT | VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                 VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
                 VK_ACCESS_2_SHADER_SAMPLED_READ_BIT);

    // DEBUG: Render Y-only as red to verify decoder writes Y plane.
    // If you see red image: Y plane is filled correctly by decoder.
    // If black: Y plane is empty / decoder not writing to views.planes[0].
    {
        auto rp_info = d->device->get_swapchain_render_pass(SwapchainRenderPass::ColorOnly);
        rp_info.clear_color[0].float32[0] = 0.0f;
        rp_info.clear_color[0].float32[1] = 0.0f;
        rp_info.clear_color[0].float32[2] = 0.0f;
        rp_info.clear_color[0].float32[3] = 1.0f;
        cmd->begin_render_pass(rp_info);
        cmd->set_quad_state();
        cmd->set_program(d->device->request_program(fullscreen_vert_spv, sizeof(fullscreen_vert_spv),
                                                     debug_y2r_frag_spv, sizeof(debug_y2r_frag_spv)));
        cmd->set_texture(0, 0, *d->views.planes[0]);
        cmd->set_sampler(0, 3, StockSampler::LinearClamp);
        cmd->draw(3);
    }
    cmd->end_render_pass();

    d->device->submit(cmd);
    d->wsi.end_frame();
    LogPyro(@"frame %u: presented", du->frameNumber);
    return DR_OK;
}

- (void)stop {
    _stopped = true;
    claimGraniteThread();
    if (d->device) {
        d->device->wait_idle();
    }
    for (auto &img : d->yuvImages) {
        img.reset();
    }
    if (d->metalLayer) {
        [d->metalLayer removeFromSuperlayer];
        d->metalLayer = nil;
    }
}

- (void)setHdrMode:(BOOL)enabled {
    // HDR is detected per-stream from the bitstream sequence header
}

- (int)decoderColorspace {
    return d->bt2020 ? COLORSPACE_REC_2020 : COLORSPACE_REC_709;
}

- (int)decoderColorRange {
    return d->full_range ? COLOR_RANGE_FULL : COLOR_RANGE_LIMITED;
}

@end

bool PyroWaveImpl::init_swapchain(bool want_hdr) {
    wsi.set_backbuffer_format(want_hdr ? BackbufferFormat::HDR10 : BackbufferFormat::UNORM);
    if (!wsi.init_surface_swapchain()) {
        if (want_hdr) {
            LogPyro(@"HDR10 swapchain failed, retrying SDR");
            wsi.set_backbuffer_format(BackbufferFormat::UNORM);
            if (!wsi.init_surface_swapchain()) {
                LogPyro(@"swapchain init failed");
                return false;
            }
            is_hdr = false;
        } else {
            LogPyro(@"swapchain init failed");
            return false;
        }
    }
    swapchain_ready = true;
    return true;
}

bool PyroWaveImpl::init_decoder(PyroWave::ChromaSubsampling c) {
    chroma = c;
    chromaW = (c == PyroWave::ChromaSubsampling::Chroma420) ? width >> 1 : width;
    chromaH = (c == PyroWave::ChromaSubsampling::Chroma420) ? height >> 1 : height;

    VkFormat plane_format = is_hdr ? VK_FORMAT_R16_UNORM : VK_FORMAT_R8_UNORM;
    ImageCreateInfo info = ImageCreateInfo::immutable_2d_image(width, height, plane_format);
    info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT |
                 VK_IMAGE_USAGE_STORAGE_BIT;
    info.initial_layout = VK_IMAGE_LAYOUT_UNDEFINED;
    yuvImages[0] = device->create_image(info);
    info.width = chromaW; info.height = chromaH;
    yuvImages[1] = device->create_image(info);
    yuvImages[2] = device->create_image(info);
    if (!yuvImages[0] || !yuvImages[1] || !yuvImages[2]) {
        LogPyro(@"Failed to allocate YCbCr plane images");
        return false;
    }
    for (int i = 0; i < 3; i++)
        views.planes[i] = &yuvImages[i]->get_view();

    if (!decoder.init(device, width, height, chroma, true)) {
        LogPyro(@"Decoder::init() failed");
        return false;
    }

    LogPyro(@"Decoder ready %dx%d chroma=%s hdr=%d bt2020=%d full_range=%d",
          width, height,
          (c == PyroWave::ChromaSubsampling::Chroma444) ? "4:4:4" : "4:2:0",
          is_hdr, bt2020, full_range);
    decoder_ready = true;
    return true;
}

// Stub for Granite::GLSLCompiler (forward-declared but not defined in headers)
namespace Granite {
enum class Stage { Vertex, Fragment, Compute };
class GLSLCompiler {
public:
  GLSLCompiler(FilesystemInterface &) {}
  void set_source_from_file(const std::string &, Stage) {}
  void set_include_directories(const std::vector<std::string> *) {}
  uint64_t get_source_hash() const { return 0; }
  bool compile(std::string &,
               const std::vector<std::pair<std::string, int>> *) const {
    return false;
  }
};
} // namespace Granite
