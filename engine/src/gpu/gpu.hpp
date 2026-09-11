// gpu.hpp -- the GPU layer, behind an interface narrow enough to swap.
//
// This is the abstraction the MSL-only decision (RFC-014 §6 step 1) was taken
// *with*: the kernels stay MSL and are not cross-compiled, but nothing above
// this header names Metal. A Vulkan backend would implement `Gpu` and supply
// its own SPIR-V for the same kernel names; the pipeline, the node bodies and
// the C ABI would not change.
//
// It is deliberately not a general compute abstraction. Five verbs cover every
// dispatch in the engine, because the render graph is a chain of full-frame
// kernels over tightly packed float32:
//
//     alloc / upload      get memory, put constants in it
//     dispatch            run a named kernel over N threads
//     flush               commit the batch and wait
//     read                bring a buffer's contents back to the host
//     texture             hand the canvas the pixels without copying them
//
// Two properties of this design are load-bearing rather than incidental.
//
// **Dispatches batch.** `dispatch` encodes into an open command buffer and
// returns; nothing is submitted until `flush`. A 21-node render is therefore
// one submission, not 21 -- which is what makes the per-node cost the kernel
// and not the round trip. The pipeline calls `flush` only where it must: a
// host read, a reduction it needs the value of, or the end of a render.
//
// **Buffers are reference-counted, into a pool.** `alloc` hands back a
// `BufferRef`; when the last handle to it goes out of scope the buffer returns
// to the pool and the *next* `alloc` of a compatible size reuses it.
//
// The first version of this reclaimed only at the end of a frame, and that was
// wrong in a way that only showed at full resolution. A render's peak
// footprint became the sum of every intermediate rather than the two or three
// that are live at once: 24 MP held ~11 buffers of 288 MB, one command buffer
// referenced all 3.2 GB simultaneously, and the render took **6.4 s instead of
// 0.8** -- a number that looks exactly like a CPU fallback and is not one. The
// pool itself is still kept across renders, because the alternative is a page
// fault per buffer (RFC-011: a trivial pointwise node then costs 16 ms instead
// of 4 at 45 MP).
#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace spk::gpu {

// Opaque device memory. On Apple silicon this is shared storage, so
// `contents()` is a pointer into the same pages the GPU reads -- no staging,
// no copy.
struct Buffer;

class Gpu;

// A counted handle on a pooled buffer. Copy it and the buffer stays; drop the
// last one and it goes back to the pool, ready for the next node.
//
// This is what makes a linear node chain (`cur = next`) return each stage's
// memory as soon as the stage after it has run, without any node having to
// know which of its inputs is dead.
class BufferRef {
public:
    BufferRef() = default;
    BufferRef(Gpu* gpu, Buffer* buffer) : gpu_(gpu), buffer_(buffer) {}
    BufferRef(const BufferRef& other);
    BufferRef(BufferRef&& other) noexcept : gpu_(other.gpu_), buffer_(other.buffer_) {
        other.gpu_ = nullptr;
        other.buffer_ = nullptr;
    }
    BufferRef& operator=(const BufferRef& other);
    BufferRef& operator=(BufferRef&& other) noexcept;
    ~BufferRef();

    Buffer* get() const { return buffer_; }
    explicit operator bool() const { return buffer_ != nullptr; }
    void reset();

private:
    Gpu* gpu_ = nullptr;
    Buffer* buffer_ = nullptr;
};

// One dispatch's arguments, in buffer-index order. A small constant may be
// passed inline (`bytes`) instead of allocated; the backend decides how.
struct Arg {
    Buffer* buffer = nullptr;
    const void* bytes = nullptr;
    size_t size = 0;

    static Arg buf(Buffer* b) { return Arg{b, nullptr, 0}; }
    static Arg buf(const BufferRef& b) { return Arg{b.get(), nullptr, 0}; }
    template <typename T>
    static Arg inline_bytes(const T* p, size_t count) { return Arg{nullptr, p, count * sizeof(T)}; }
};

class Gpu {
public:
    virtual ~Gpu() = default;

    // `device` is the caller's `MTLDevice` (an `id<MTLDevice>`) or null to
    // create one. The engine retains what it is given for its lifetime, and
    // renders into textures that device can draw -- RFC-014 §2.2's whole
    // point, and the deletion of a 364 MB round trip in each direction.
    static Gpu* create_metal(void* device, const std::string& metallib_path, std::string& error);

    virtual std::string device_name() const = 0;

    // The fast-math probe. Returns false, with a message, when the kernels in
    // the loaded library were compiled with fast math -- which drifts `exp`
    // and fma contraction by up to 1.1e-5, past the float32 bar, silently
    // (RFC-014 §5.1 trap 1). Checked at engine creation, not trusted.
    virtual bool check_math_mode(std::string& detail) = 0;

    // Frame arena. `alloc` and `upload` return memory that lives until
    // `end_frame`; `begin_frame` resets the arena and reuses what it can.
    virtual void begin_frame() = 0;
    virtual void end_frame() = 0;

    // Counted. The buffer returns to the pool when the last handle drops.
    virtual BufferRef alloc(size_t bytes, std::string& error) = 0;
    virtual BufferRef alloc_zeroed(size_t bytes, std::string& error) = 0;
    virtual BufferRef upload(const void* data, size_t bytes, std::string& error) = 0;

    // Used only by `BufferRef`.
    virtual void retain(Buffer* buffer) = 0;
    virtual void release(Buffer* buffer) = 0;
    // float64 host data narrowed to float32 on the way in -- every constant
    // the setup maths produces arrives this way, and doing the narrowing here
    // means no caller keeps a float32 shadow copy.
    virtual BufferRef upload_f32(const double* data, size_t count, std::string& error) = 0;
    virtual BufferRef upload_u32(const uint32_t* data, size_t count, std::string& error) = 0;

    // The baked constants, and the results that outlive a render. Same
    // counted handle, different reclamation: a pooled buffer goes back to the
    // pool at zero references and one of these is *destroyed*, because its
    // size (a 192x192x3 LUT, a 64x720 table, a tier's rgba16) is not one a
    // later node would want.
    //
    // One lifetime model rather than two. The first version had
    // `release_persistent` alongside the pool and it was the seam every
    // ownership bug landed on.
    virtual BufferRef alloc_persistent(size_t bytes, std::string& error) = 0;
    virtual BufferRef upload_persistent(const void* data, size_t bytes, std::string& error) = 0;
    virtual BufferRef upload_persistent_f32(const double* data, size_t count, std::string& error) = 0;
    virtual BufferRef upload_persistent_u32(const uint32_t* data, size_t count, std::string& error) = 0;

    // A caller's `id<MTLBuffer>`, wrapped without a copy. Retained while a
    // handle exists and released -- never pooled -- when the last one drops,
    // which is the persistent lifetime above with somebody else's memory in
    // it. Refused if the buffer belongs to another device or holds fewer
    // than `bytes`.
    //
    // For `spk_open_device` only, and only for the length of that call: the
    // frame goes through `spk_take_rgb` into the engine's own buffer and the
    // borrow ends when the call returns. Nothing may keep the handle, because
    // the caller reuses or frees the memory the moment it gets control back.
    virtual BufferRef borrow(void* mtl_buffer, size_t bytes, std::string& error) = 0;

    virtual void* contents(Buffer* b) = 0;
    virtual size_t size_bytes(Buffer* b) const = 0;

    virtual bool dispatch(const char* kernel, const std::vector<Arg>& args,
                          size_t n_threads, std::string& error) = 0;
    virtual bool flush(std::string& error) = 0;

    // A texture over `b`'s memory, RGBA16Unorm, `width` x `height`, rows
    // `row_stride_px` pixels apart. Zero copy, and returned **+1: the caller
    // owns it**.
    //
    // It is not arena-owned, and that is deliberate rather than an oversight
    // corrected: a render's result outlives the render, because the frontend
    // caches it. A Metal texture over a buffer retains that buffer, so
    // handing over the only reference is also what keeps the pixels alive
    // exactly as long as someone is looking at them.
    virtual void* texture(Buffer* b, uint32_t width, uint32_t height,
                          uint32_t row_stride_px, std::string& error) = 0;
    virtual void release_texture(void* texture) = 0;
    // `spk_result_free` gets a result, not an engine, and a texture handed out
    // +1 must be releasable without one.
    static void release_texture_static(void* texture);
    // The row alignment `texture` requires, in pixels of RGBA16.
    virtual uint32_t texture_row_alignment_px() const = 0;
    // The largest 2D texture side this device will make. 16384 on Apple
    // silicon today, but it is the device's answer rather than a constant:
    // the app draws the print and the original on `MTLTexture`s, so a frame
    // wider than this renders and then cannot be shown.
    virtual uint32_t max_texture_dimension_2d() const = 0;
};

// --- BufferRef, once Gpu is complete ---------------------------------------

inline BufferRef::BufferRef(const BufferRef& other) : gpu_(other.gpu_), buffer_(other.buffer_) {
    if (gpu_ && buffer_) gpu_->retain(buffer_);
}

inline BufferRef& BufferRef::operator=(const BufferRef& other) {
    if (this == &other) return *this;
    if (other.gpu_ && other.buffer_) other.gpu_->retain(other.buffer_);
    reset();
    gpu_ = other.gpu_;
    buffer_ = other.buffer_;
    return *this;
}

inline BufferRef& BufferRef::operator=(BufferRef&& other) noexcept {
    if (this == &other) return *this;
    reset();
    gpu_ = other.gpu_;
    buffer_ = other.buffer_;
    other.gpu_ = nullptr;
    other.buffer_ = nullptr;
    return *this;
}

inline BufferRef::~BufferRef() { reset(); }

inline void BufferRef::reset() {
    if (gpu_ && buffer_) gpu_->release(buffer_);
    gpu_ = nullptr;
    buffer_ = nullptr;
}

}  // namespace spk::gpu
