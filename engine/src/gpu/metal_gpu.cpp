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
#include <mutex>
#include <unordered_map>
#include <vector>

namespace spk::gpu {

// `Buffer` is opaque to every caller; here it is a Metal buffer plus the size
// the arena tracks it by.
struct Buffer {
    MTL::Buffer* mtl = nullptr;
    size_t bytes = 0;
    // 0 means "in the pool, free to reuse". Every `BufferRef` holds one count.
    int refs = 0;
    // Free *and* idle. A buffer is free when its last handle drops and idle
    // when the command buffer that last named it has completed; only both
    // together make it safe to hand out again.
    bool reusable = false;
    bool persistent = false;
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
        BufferRef src = upload(in, sizeof in, error);
        BufferRef dst = alloc(n * sizeof(float), error);
        if (!src || !dst) { detail = "math probe could not allocate: " + error; end_frame(); return false; }
        if (!dispatch("spk_math_probe", {Arg::buf(src), Arg::buf(dst)}, n, error) || !flush(error)) {
            detail = "math probe failed to run: " + error;
            end_frame();
            return false;
        }
        const float* got = static_cast<const float*>(contents(dst.get()));
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

    // The frame markers no longer reclaim anything -- reference counting does
    // that, continuously, which is the point. They remain as the place to hang
    // per-frame bookkeeping, and as an assertion: anything still referenced at
    // `end_frame` is a leak by a caller that kept a handle.
    void begin_frame() override {}

    void end_frame() override {
        // The pool itself is kept. Trimming it here would hand every 540 MB
        // buffer back to the OS and pay the page faults again on the next
        // render.
    }

    void retain(Buffer* buffer) override {
        if (!buffer) return;
        std::lock_guard<std::mutex> guard(pool_lock_);
        ++buffer->refs;
    }

    void release(Buffer* buffer) override {
        if (!buffer) return;
        std::lock_guard<std::mutex> guard(pool_lock_);
        if (--buffer->refs > 0) return;
        buffer->refs = 0;
        if (buffer->persistent) {
            // A one-off size nothing else would want: give it back to the OS.
            if (buffer->mtl) buffer->mtl->release();
            delete buffer;
            return;
        }
        // **Not** reusable yet. The last handle going away means no *future*
        // dispatch names this buffer; it says nothing about the dispatches
        // already encoded into the open command buffer, which have not run.
        // Handing it to the next `alloc` here let a later kernel overwrite a
        // buffer an earlier one had not read yet -- 25 of 27 render-parity
        // cases, with no crash and no error. It becomes reusable at `flush`,
        // which is also where the reference evaluates (AGENTS.md trap 5).
        pending_.push_back(buffer);
    }

    BufferRef alloc(size_t bytes, std::string& error) override {
        if (bytes == 0) { error = "zero-length allocation"; return {}; }
        {
            std::lock_guard<std::mutex> guard(pool_lock_);
            // Reuse the smallest free buffer that fits, so a chain of
            // same-sized full-frame nodes recycles two or three buffers
            // rather than one per node.
            Buffer* best = nullptr;
            for (Buffer* b : pool_)
                if (b->refs == 0 && b->reusable && b->bytes >= bytes &&
                    (!best || b->bytes < best->bytes)) best = b;
            if (best) {
                best->refs = 1;
                best->reusable = false;
                return BufferRef(this, best);
            }
        }
        MTL::Buffer* mtl = device_->newBuffer(bytes, MTL::ResourceStorageModeShared);
        if (!mtl) {
            error = "out of GPU memory allocating " + std::to_string(bytes) + " bytes";
            return {};
        }
        Buffer* b = new Buffer{mtl, bytes, 1, false, false};
        std::lock_guard<std::mutex> guard(pool_lock_);
        pool_.push_back(b);
        return BufferRef(this, b);
    }

    BufferRef alloc_zeroed(size_t bytes, std::string& error) override {
        BufferRef b = alloc(bytes, error);
        if (b) std::memset(b.get()->mtl->contents(), 0, bytes);
        return b;
    }

    BufferRef upload(const void* data, size_t bytes, std::string& error) override {
        BufferRef b = alloc(bytes, error);
        if (b) std::memcpy(b.get()->mtl->contents(), data, bytes);
        return b;
    }

    BufferRef upload_f32(const double* data, size_t count, std::string& error) override {
        BufferRef b = alloc(count * sizeof(float), error);
        if (!b) return {};
        float* dst = static_cast<float*>(b.get()->mtl->contents());
        for (size_t i = 0; i < count; ++i) dst[i] = float(data[i]);
        return b;
    }

    BufferRef upload_u32(const uint32_t* data, size_t count, std::string& error) override {
        return upload(data, count * sizeof(uint32_t), error);
    }

    BufferRef alloc_persistent(size_t bytes, std::string& error) override {
        if (bytes == 0) { error = "zero-length allocation"; return {}; }
        MTL::Buffer* mtl = device_->newBuffer(bytes, MTL::ResourceStorageModeShared);
        if (!mtl) { error = "out of GPU memory allocating " + std::to_string(bytes) + " bytes"; return {}; }
        Buffer* b = new Buffer{mtl, bytes, 1, false, true};
        return BufferRef(this, b);
    }

    BufferRef upload_persistent(const void* data, size_t bytes, std::string& error) override {
        BufferRef b = alloc_persistent(bytes, error);
        if (b) std::memcpy(b.get()->mtl->contents(), data, bytes);
        return b;
    }

    BufferRef upload_persistent_f32(const double* data, size_t count, std::string& error) override {
        BufferRef b = alloc_persistent(count * sizeof(float), error);
        if (!b) return {};
        float* dst = static_cast<float*>(b.get()->mtl->contents());
        for (size_t i = 0; i < count; ++i) dst[i] = float(data[i]);
        return b;
    }

    BufferRef upload_persistent_u32(const uint32_t* data, size_t count, std::string& error) override {
        return upload_persistent(data, count * sizeof(uint32_t), error);
    }

    BufferRef borrow(void* mtl_buffer, size_t bytes, std::string& error) override {
        auto* mtl = static_cast<MTL::Buffer*>(mtl_buffer);
        if (!mtl) { error = "no buffer to borrow"; return {}; }
        // A buffer from another device is not an error Metal reports: it is
        // a GPU fault at the first dispatch that names it.
        if (mtl->device() != device_) {
            error = "the frame's MTLBuffer belongs to a different MTLDevice than the engine's";
            return {};
        }
        if (mtl->length() < bytes) {
            error = "the frame's MTLBuffer holds " + std::to_string(mtl->length()) +
                    " bytes; the image needs " + std::to_string(bytes);
            return {};
        }
        mtl->retain();
        // `persistent`, so the last release gives the retain back and deletes
        // the wrapper rather than putting the caller's memory in the pool.
        return BufferRef(this, new Buffer{mtl, bytes, 1, false, true});
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
                // Larger than `setBytes` allows. The handle lives until the
                // end of this dispatch call, which is long enough: the encoder
                // has already taken its own reference on the MTLBuffer.
                BufferRef tmp = upload(a.bytes, a.size, error);
                if (!tmp) return false;
                enc->setBuffer(tmp.get()->mtl, 0, NS::UInteger(i));
                inflight_.push_back(std::move(tmp));
            } else { error = std::string(kernel) + ": argument " + std::to_string(i) + " is empty"; return false; }
        }
        const size_t width = std::min<size_t>(pso->maxTotalThreadsPerThreadgroup(), kThreadgroup);
        enc->dispatchThreads(MTL::Size(n_threads, 1, 1), MTL::Size(width, 1, 1));
        return true;
    }

    bool flush(std::string& error) override {
        // Anything held only for an encoded-but-unsubmitted dispatch can go
        // back to the pool once the work has run.
        struct Clear { std::vector<BufferRef>* v; ~Clear() { v->clear(); } } clear{&inflight_};
        if (!command_buffer_) { reclaim(); return true; }
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
        reclaim();
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

    uint32_t max_texture_dimension_2d() const override {
        // The largest texture side this device will make. It matters because
        // the app draws the print and the original on `MTLTexture`s, so a
        // frame whose long edge is past it renders and then cannot be shown.
        //
        // **Metal does not publish this.** There is `maxBufferLength` and
        // `maxThreadsPerThreadgroup`; there is no `maxTextureDimension` in the
        // SDK's `MTLDevice.h` at all (checked, not assumed — this first sent
        // that selector and the device answered `unrecognized selector`).
        // Neither can it be probed for: asking `newTexture` for a 32768-wide
        // descriptor is not a nil return but `MTLTextureDescriptor`'s own
        // assertion — "width (32768) greater than the maximum allowed size of
        // 16384" — which takes the process with it.
        //
        // So the family is asked instead, and 16384 is the answer for every
        // family that answers: Apple7 and up, and Mac2. That covers every
        // Metal-capable Mac. A device that answers none of them is older than
        // this build supports, and 16384 is still the safe reading there — the
        // only thing it can do is refuse a frame too big to be drawn.
        const bool known = device_->supportsFamily(MTL::GPUFamilyMac2) ||
                           device_->supportsFamily(MTL::GPUFamilyApple7);
        return known ? 16384u : 8192u;
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

    // Everything freed since the last flush is now genuinely idle: the work
    // that referenced it has completed.
    void reclaim() {
        std::lock_guard<std::mutex> guard(pool_lock_);
        for (Buffer* b : pending_) if (b->refs == 0) b->reusable = true;
        pending_.clear();
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
    mutable std::mutex pool_lock_;
    std::vector<Buffer*> pool_;
    std::vector<Buffer*> pending_;
    // Buffers created to back an oversized inline argument, kept alive until
    // the command buffer that references them has completed.
    std::vector<BufferRef> inflight_;
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
