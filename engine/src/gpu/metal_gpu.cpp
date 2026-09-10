// metal_gpu.cpp -- the Metal backend, through vendored metal-cpp.
//
// metal-cpp and not Objective-C++ (`.mm`), for the reason RFC-014 §2.2 gives:
// a `.mm` file is Apple-only by construction, which defeats the portability
// argument that chose C++ over Swift in the first place. metal-cpp is a
// *source* dependency vendored into the repo, not an install one, so it does
// not violate §0's "nothing to install".
//
// Ownership, stated once and then relied on everywhere: Swift owns the
// `MTLDevice` and the drawable; the engine owns everything it allocates and
// frees it in `end_frame` or in its destructor. No buffer is freed by the side
// that did not allocate it.
#include "gpu.hpp"

#include <Metal/Metal.hpp>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_map>
#include <vector>

namespace spk::gpu {

// `Buffer` is opaque to every caller; here it is a Metal buffer plus the size
// the arena tracks it by.
struct Buffer {
    MTL::Buffer* mtl = nullptr;
    size_t bytes = 0;
    bool in_use = false;
};

namespace {

constexpr size_t kThreadgroup = 256;
// A small constant goes in as `setBytes`, which avoids an allocation and a
// residency entry. 4 kB is Metal's documented limit for it.
constexpr size_t kInlineLimit = 4096;

class MetalGpu final : public Gpu {
public:
    MetalGpu(MTL::Device* device, bool owns_device, MTL::Library* library, MTL::CommandQueue* queue)
        : device_(device), owns_device_(owns_device), library_(library), queue_(queue) {}

    ~MetalGpu() override {
        for (Buffer* b : pool_) { if (b->mtl) b->mtl->release(); delete b; }
        for (Buffer* b : persistent_) { if (b->mtl) b->mtl->release(); delete b; }
        for (auto& kv : pipelines_) kv.second->release();
        if (command_buffer_) command_buffer_->release();
        if (queue_) queue_->release();
        if (library_) library_->release();
        if (device_ && owns_device_) device_->release();
    }

    std::string device_name() const override {
        return device_->name() ? device_->name()->utf8String() : "unknown";
    }

    bool check_math_mode(std::string& detail) override {
        // `a * b - a * b`: exactly 0 under fast math, and the rounding error
        // of `a*b` when the compiler is allowed to contract one product into
        // an fma but not to reassociate. Compared against the host's own
        // `fma(a, b, -(a*b))` rather than merely against zero, so a future
        // toolchain that stops contracting under safe math reports a mismatch
        // instead of a false pass.
        constexpr size_t n = 64;
        float in[2 * n];
        for (size_t i = 0; i < n; ++i) {
            in[2 * i] = 0.1f + 0.37f * float(i);
            in[2 * i + 1] = in[2 * i] * 0.5f + 1.0f;
        }
        begin_frame();
        std::string error;
        Buffer* src = upload(in, sizeof in, error);
        Buffer* dst = alloc(n * sizeof(float), error);
        if (!src || !dst) { detail = "math probe could not allocate: " + error; end_frame(); return false; }
        if (!dispatch("spk_math_probe", {Arg::buf(src), Arg::buf(dst)}, n, error) || !flush(error)) {
            detail = "math probe failed to run: " + error;
            end_frame();
            return false;
        }
        const float* got = static_cast<const float*>(contents(dst));
        size_t zeros = 0, mismatched = 0;
        for (size_t i = 0; i < n; ++i) {
            const float a = in[2 * i], b = in[2 * i + 1];
            const float want = std::fma(a, b, -(a * b));
            if (got[i] == 0.0f) ++zeros;
            else if (got[i] != want) ++mismatched;
        }
        end_frame();
        if (zeros == n) {
            detail = "the Metal library was compiled with fast math: `a*b - a*b` came back "
                     "exactly zero for all 64 probes. Rebuild with "
                     "-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise "
                     "(RFC-014 §5.1 trap 1: fast math drifts exp and fma contraction by up to "
                     "1.1e-5, which is past the float32 bar and silent).";
            return false;
        }
        if (mismatched > 0) {
            detail = "the fast-math probe returned " + std::to_string(mismatched) +
                     " of 64 values that match neither zero nor the host's fma error term. "
                     "The toolchain's contraction behaviour has changed; re-derive the probe "
                     "in shaders/util.metal before trusting parity.";
            return false;
        }
        detail = "safe (probe: fma contraction present, no reassociation)";
        return true;
    }

    void begin_frame() override {
        for (Buffer* b : pool_) b->in_use = false;
        live_.clear();
    }

    void end_frame() override {
        for (Buffer* b : pool_) b->in_use = false;
        live_.clear();
        // The pool itself is kept. Trimming it here would hand every 540 MB
        // buffer back to the OS and pay the page faults again on the next
        // render; `trim` exists for the memory-pressure path instead.
    }

    Buffer* alloc(size_t bytes, std::string& error) override {
        if (bytes == 0) { error = "zero-length allocation"; return nullptr; }
        // Reuse the smallest free buffer that fits, so a chain of same-sized
        // full-frame nodes recycles two or three buffers rather than growing
        // one per node.
        Buffer* best = nullptr;
        for (Buffer* b : pool_)
            if (!b->in_use && b->bytes >= bytes && (!best || b->bytes < best->bytes)) best = b;
        if (best) {
            best->in_use = true;
            live_.push_back(best);
            return best;
        }
        MTL::Buffer* mtl = device_->newBuffer(bytes, MTL::ResourceStorageModeShared);
        if (!mtl) {
            error = "out of GPU memory allocating " + std::to_string(bytes) + " bytes";
            return nullptr;
        }
        Buffer* b = new Buffer{mtl, bytes, true};
        pool_.push_back(b);
        live_.push_back(b);
        return b;
    }

    Buffer* alloc_zeroed(size_t bytes, std::string& error) override {
        Buffer* b = alloc(bytes, error);
        if (b) std::memset(b->mtl->contents(), 0, bytes);
        return b;
    }

    Buffer* upload(const void* data, size_t bytes, std::string& error) override {
        Buffer* b = alloc(bytes, error);
        if (b) std::memcpy(b->mtl->contents(), data, bytes);
        return b;
    }

    Buffer* upload_f32(const double* data, size_t count, std::string& error) override {
        Buffer* b = alloc(count * sizeof(float), error);
        if (!b) return nullptr;
        float* dst = static_cast<float*>(b->mtl->contents());
        for (size_t i = 0; i < count; ++i) dst[i] = float(data[i]);
        return b;
    }

    Buffer* upload_u32(const uint32_t* data, size_t count, std::string& error) override {
        return upload(data, count * sizeof(uint32_t), error);
    }

    Buffer* alloc_persistent(size_t bytes, std::string& error) override {
        if (bytes == 0) { error = "zero-length allocation"; return nullptr; }
        MTL::Buffer* mtl = device_->newBuffer(bytes, MTL::ResourceStorageModeShared);
        if (!mtl) { error = "out of GPU memory allocating " + std::to_string(bytes) + " bytes"; return nullptr; }
        Buffer* b = new Buffer{mtl, bytes, true};
        persistent_.push_back(b);
        return b;
    }

    Buffer* upload_persistent(const void* data, size_t bytes, std::string& error) override {
        Buffer* b = alloc_persistent(bytes, error);
        if (b) std::memcpy(b->mtl->contents(), data, bytes);
        return b;
    }

    Buffer* upload_persistent_f32(const double* data, size_t count, std::string& error) override {
        Buffer* b = alloc_persistent(count * sizeof(float), error);
        if (!b) return nullptr;
        float* dst = static_cast<float*>(b->mtl->contents());
        for (size_t i = 0; i < count; ++i) dst[i] = float(data[i]);
        return b;
    }

    Buffer* upload_persistent_u32(const uint32_t* data, size_t count, std::string& error) override {
        return upload_persistent(data, count * sizeof(uint32_t), error);
    }

    void release_persistent(Buffer* b) override {
        if (!b) return;
        for (size_t i = 0; i < persistent_.size(); ++i)
            if (persistent_[i] == b) { persistent_.erase(persistent_.begin() + long(i)); break; }
        if (b->mtl) b->mtl->release();
        delete b;
    }

    void* contents(Buffer* b) override { return b->mtl->contents(); }
    size_t size_bytes(Buffer* b) const override { return b->bytes; }

    bool dispatch(const char* kernel, const std::vector<Arg>& args,
                  size_t n_threads, std::string& error) override {
        if (n_threads == 0) return true;
        MTL::ComputePipelineState* pso = pipeline(kernel, error);
        if (!pso) return false;
        MTL::ComputeCommandEncoder* enc = encoder(error);
        if (!enc) return false;
        enc->setComputePipelineState(pso);
        for (size_t i = 0; i < args.size(); ++i) {
            const Arg& a = args[i];
            if (a.buffer) enc->setBuffer(a.buffer->mtl, 0, NS::UInteger(i));
            else if (a.bytes && a.size <= kInlineLimit) enc->setBytes(a.bytes, a.size, NS::UInteger(i));
            else if (a.bytes) {
                Buffer* tmp = upload(a.bytes, a.size, error);
                if (!tmp) return false;
                enc->setBuffer(tmp->mtl, 0, NS::UInteger(i));
            } else { error = std::string(kernel) + ": argument " + std::to_string(i) + " is empty"; return false; }
        }
        const size_t width = std::min<size_t>(pso->maxTotalThreadsPerThreadgroup(), kThreadgroup);
        enc->dispatchThreads(MTL::Size(n_threads, 1, 1), MTL::Size(width, 1, 1));
        return true;
    }

    bool flush(std::string& error) override {
        if (!command_buffer_) return true;
        if (encoder_) { encoder_->endEncoding(); encoder_ = nullptr; }
        command_buffer_->commit();
        command_buffer_->waitUntilCompleted();
        const MTL::CommandBufferStatus status = command_buffer_->status();
        if (status == MTL::CommandBufferStatusError) {
            NS::Error* err = command_buffer_->error();
            error = std::string("GPU command buffer failed: ") +
                    (err && err->localizedDescription() ? err->localizedDescription()->utf8String() : "unknown");
            command_buffer_->release();
            command_buffer_ = nullptr;
            return false;
        }
        command_buffer_->release();
        command_buffer_ = nullptr;
        return true;
    }

    void* texture(Buffer* b, uint32_t width, uint32_t height,
                  uint32_t row_stride_px, std::string& error) override {
        MTL::TextureDescriptor* desc = MTL::TextureDescriptor::alloc()->init();
        desc->setTextureType(MTL::TextureType2D);
        desc->setPixelFormat(MTL::PixelFormatRGBA16Unorm);
        desc->setWidth(width);
        desc->setHeight(height);
        desc->setUsage(MTL::TextureUsageShaderRead);
        desc->setStorageMode(MTL::StorageModeShared);
        MTL::Texture* tex = b->mtl->newTexture(desc, 0, size_t(row_stride_px) * 8);
        desc->release();
        if (!tex) { error = "could not create a texture over the result buffer"; return nullptr; }
        // `newTexture` is already +1 and the texture retains `b->mtl`, so the
        // caller now holds the only reference it needs. Not tracked here.
        return tex;
    }

    void release_texture(void* texture) override {
        if (texture) static_cast<MTL::Texture*>(texture)->release();
    }

    uint32_t texture_row_alignment_px() const override {
        // `minimumLinearTextureAlignmentForPixelFormat` is in bytes; RGBA16 is
        // 8 bytes per pixel. Asking the device beats hardcoding 256 B, which
        // is right on today's Macs and is not a promise.
        const NS::UInteger bytes = device_->minimumLinearTextureAlignmentForPixelFormat(
            MTL::PixelFormatRGBA16Unorm);
        const uint32_t px = uint32_t(std::max<NS::UInteger>(bytes, 8) / 8);
        return px == 0 ? 1 : px;
    }

private:
    MTL::ComputePipelineState* pipeline(const char* name, std::string& error) {
        auto it = pipelines_.find(name);
        if (it != pipelines_.end()) return it->second;
        NS::String* fn_name = NS::String::string(name, NS::UTF8StringEncoding);
        MTL::Function* fn = library_->newFunction(fn_name);
        if (!fn) {
            error = std::string("no kernel '") + name + "' in spektrafilm.metallib";
            return nullptr;
        }
        NS::Error* err = nullptr;
        MTL::ComputePipelineState* pso = device_->newComputePipelineState(fn, &err);
        fn->release();
        if (!pso) {
            error = std::string("could not build a pipeline for '") + name + "': " +
                    (err && err->localizedDescription() ? err->localizedDescription()->utf8String() : "unknown");
            return nullptr;
        }
        pipelines_[name] = pso;
        return pso;
    }

    MTL::ComputeCommandEncoder* encoder(std::string& error) {
        if (!command_buffer_) {
            command_buffer_ = queue_->commandBuffer();
            if (!command_buffer_) { error = "could not open a command buffer"; return nullptr; }
            command_buffer_->retain();
            encoder_ = nullptr;
        }
        if (!encoder_) {
            encoder_ = command_buffer_->computeCommandEncoder();
            if (!encoder_) { error = "could not open a compute encoder"; return nullptr; }
        }
        return encoder_;
    }

    MTL::Device* device_ = nullptr;
    bool owns_device_ = false;
    MTL::Library* library_ = nullptr;
    MTL::CommandQueue* queue_ = nullptr;
    MTL::CommandBuffer* command_buffer_ = nullptr;
    MTL::ComputeCommandEncoder* encoder_ = nullptr;
    std::unordered_map<std::string, MTL::ComputePipelineState*> pipelines_;
    std::vector<Buffer*> pool_;
    std::vector<Buffer*> live_;
    std::vector<Buffer*> persistent_;
};

}  // namespace

void Gpu::release_texture_static(void* texture) {
    if (texture) static_cast<MTL::Texture*>(texture)->release();
}

Gpu* Gpu::create_metal(void* device_handle, const std::string& metallib_path, std::string& error) {
    MTL::Device* device = static_cast<MTL::Device*>(device_handle);
    const bool owns = device == nullptr;
    if (owns) device = MTL::CreateSystemDefaultDevice();
    if (!device) { error = "no Metal device"; return nullptr; }
    if (!owns) device->retain();   // the caller keeps its own reference

    NS::Error* err = nullptr;
    NS::String* path = NS::String::string(metallib_path.c_str(), NS::UTF8StringEncoding);
    MTL::Library* library = device->newLibrary(path, &err);
    if (!library) {
        error = "cannot load " + metallib_path + ": " +
                (err && err->localizedDescription() ? err->localizedDescription()->utf8String() : "unknown");
        device->release();
        return nullptr;
    }
    MTL::CommandQueue* queue = device->newCommandQueue();
    if (!queue) {
        error = "cannot create a Metal command queue";
        library->release();
        device->release();
        return nullptr;
    }
    return new MetalGpu(device, owns, library, queue);
}

}  // namespace spk::gpu
