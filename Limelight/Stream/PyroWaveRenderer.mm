#import "PyroWaveRenderer.h"
#import "PyroWaveShaders.h"
#import "StreamView.h"

#include <QuartzCore/CAMetalLayer.h>

#pragma push_macro("signals")
#undef signals

// Xcode 15.4 / iOS 17.5 SDK workaround: the prebuilt Darwin.C.time module
// doesn't export nanosleep or tm. Include time.h textually with modules off.
#pragma clang module off
#include <time.h>
#pragma clang module on

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
        sci.pLayer = (__bridge CFTypeRef)metalLayer;
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

struct PyroWaveRenderer::Impl {
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

@implementation PyroWaveRenderer {
    std::unique_ptr<Impl> d;
    int _videoFormat;
    bool _stopped;
}

- (id)initWithView:(UIView*)view {
    self = [super init];
    if (self) {
        d = std::make_unique<Impl>();
        d->view = view;
        _stopped = false;

        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        layer.drawableSize = view.bounds.size;
        layer.frame = view.bounds;
        layer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        layer.opaque = YES;
        [view.layer addSublayer:layer];
        d->metalLayer = layer;
    }
    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight {
    _videoFormat = videoFormat;
    d->videoFormat = videoFormat;
    d->width = videoWidth;
    d->height = videoHeight;
}

- (BOOL)isReady {
    return d->initialized;
}

- (BOOL)initializeDecoder {
    if (d->initialized) return YES;

    claimGraniteThread();

    if (!Context::init_loader(nullptr)) {
        NSLog(@"PyroWave: Vulkan loader init failed");
        return NO;
    }

    d->platform.set_layer(d->metalLayer, d->view);

    auto iext = d->platform.get_instance_extensions();
    const char *dext[] = { "VK_KHR_swapchain" };

    ContextHandle ctx = Util::make_handle<Context>();
    if (!ctx->init_instance_and_device(iext.data(), (uint32_t)iext.size(), dext, 1,
                                       CONTEXT_CREATION_ENABLE_PUSH_DESCRIPTOR_BIT)) {
        NSLog(@"PyroWave: Granite Vulkan context init failed");
        return NO;
    }

    d->wsi.set_platform(&d->platform);
    d->wsi.set_present_mode(PresentMode::UnlockedNoTearing);
    d->wsi.set_backbuffer_format(BackbufferFormat::UNORM);

    if (!d->wsi.init_from_existing_context(std::move(ctx))) {
        NSLog(@"PyroWave: WSI context init failed");
        return NO;
    }
    if (!d->wsi.init_device()) {
        NSLog(@"PyroWave: WSI device init failed");
        return NO;
    }
    d->device = &d->wsi.get_device();

    d->present_program = d->device->request_program(
        fullscreen_vert_spv, sizeof(fullscreen_vert_spv),
        yuv2rgb_frag_spv, sizeof(yuv2rgb_frag_spv));
    if (!d->present_program) {
        NSLog(@"PyroWave: present program creation failed");
        return NO;
    }

    d->initialized = true;
    NSLog(@"PyroWave: Vulkan context ready %dx%d", d->width, d->height);
    return YES;
}

- (int)submitDecodeUnit:(PDECODE_UNIT)du {
    claimGraniteThread();

    if (_stopped) return DR_OK;

    if (!d->initialized) {
        if (![self initializeDecoder]) {
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
        if (frameLen < sizeof(PyroWave::BitstreamSequenceHeader))
            return DR_NEED_IDR;
        auto *seq = (const PyroWave::BitstreamSequenceHeader *)frameData;
        if (!seq->extended)
            return DR_NEED_IDR;

        auto detected = (seq->chroma_resolution == PyroWave::CHROMA_RESOLUTION_444)
                            ? PyroWave::ChromaSubsampling::Chroma444
                            : PyroWave::ChromaSubsampling::Chroma420;
        d->bt2020 = seq->color_primaries == PyroWave::COLOR_PRIMARIES_BT2020;
        d->full_range = seq->ycbcr_range == PyroWave::YCBCR_RANGE_FULL;
        d->is_hdr = seq->transfer_function == PyroWave::TRANSFER_FUNCTION_PQ;

        if (!d->init_swapchain(d->is_hdr))
            return DR_NEED_IDR;
        if (!d->init_decoder(detected))
            return DR_NEED_IDR;
    }

    if (!d->decoder.push_packet(frameData, frameLen)) {
        NSLog(@"PyroWave: push_packet() failed");
        d->decoder.clear();
        return DR_NEED_IDR;
    }

    if (!d->decoder.decode_is_ready(false))
        return DR_OK;

    if (!d->wsi.begin_frame())
        return DR_OK;

    auto cmd = d->device->request_command_buffer();

    if (!d->decoder.decode(*cmd, d->views)) {
        NSLog(@"PyroWave: decode() failed");
        d->device->submit(cmd);
        d->wsi.end_frame();
        return DR_NEED_IDR;
    }

    cmd->begin_render_pass(d->device->get_swapchain_render_pass(SwapchainRenderPass::ColorOnly));
    cmd->set_quad_state();
    cmd->set_program(d->present_program);
    cmd->set_texture(0, 0, *d->views.planes[0]);
    cmd->set_texture(0, 1, *d->views.planes[1]);
    cmd->set_texture(0, 2, *d->views.planes[2]);
    cmd->set_sampler(0, 3, StockSampler::LinearClamp);
    cmd->set_specialization_constant_mask(0x7);
    cmd->set_specialization_constant(0, d->full_range);
    cmd->set_specialization_constant(1, d->bt2020);
    cmd->set_specialization_constant(2, d->is_hdr);
    cmd->draw(3);
    cmd->end_render_pass();

    d->device->submit(cmd);
    d->wsi.end_frame();
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

bool PyroWaveRenderer::Impl::init_swapchain(bool want_hdr) {
    wsi.set_backbuffer_format(want_hdr ? BackbufferFormat::HDR10 : BackbufferFormat::UNORM);
    if (!wsi.init_surface_swapchain()) {
        if (want_hdr) {
            NSLog(@"PyroWave: HDR10 swapchain failed, retrying SDR");
            wsi.set_backbuffer_format(BackbufferFormat::UNORM);
            if (!wsi.init_surface_swapchain()) {
                NSLog(@"PyroWave: swapchain init failed");
                return false;
            }
            is_hdr = false;
        } else {
            NSLog(@"PyroWave: swapchain init failed");
            return false;
        }
    }
    swapchain_ready = true;
    return true;
}

bool PyroWaveRenderer::Impl::init_decoder(PyroWave::ChromaSubsampling c) {
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
        NSLog(@"PyroWave: failed to allocate YCbCr plane images");
        return false;
    }
    for (int i = 0; i < 3; i++)
        views.planes[i] = &yuvImages[i]->get_view();

    if (!decoder.init(device, width, height, chroma, true)) {
        NSLog(@"PyroWave: Decoder::init() failed");
        return false;
    }

    NSLog(@"PyroWave decoder ready %dx%d chroma=%s hdr=%d bt2020=%d full_range=%d",
          width, height,
          (c == PyroWave::ChromaSubsampling::Chroma444) ? "4:4:4" : "4:2:0",
          is_hdr, bt2020, full_range);
    decoder_ready = true;
    return true;
}
