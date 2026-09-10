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
// **Buffers come from a frame arena.** Every allocation inside a render is
// released together at the end of it. A pool is kept and reused across renders
// (RFC-011 measured the alternative: with the cache limit at zero, each 540 MB
// buffer comes from the OS with page faults and a trivial pointwise node costs
// 16 ms instead of 4 at 45 MP).
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

// One dispatch's arguments, in buffer-index order. A small constant may be
// passed inline (`bytes`) instead of allocated; the backend decides how.
struct Arg {
    Buffer* buffer = nullptr;
    const void* bytes = nullptr;
    size_t size = 0;

    static Arg buf(Buffer* b) { return Arg{b, nullptr, 0}; }
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

    virtual Buffer* alloc(size_t bytes, std::string& error) = 0;
    virtual Buffer* alloc_zeroed(size_t bytes, std::string& error) = 0;
    virtual Buffer* upload(const void* data, size_t bytes, std::string& error) = 0;
    // float64 host data narrowed to float32 on the way in -- every constant
    // the setup maths produces arrives this way, and doing the narrowing here
    // means no caller keeps a float32 shadow copy.
    virtual Buffer* upload_f32(const double* data, size_t count, std::string& error) = 0;
    virtual Buffer* upload_u32(const uint32_t* data, size_t count, std::string& error) = 0;

    // The second lifetime: the baked constants. A tc_lut, a C_max table and a
    // set of density curves are built once per stock pair and read by every
    // render, so they cannot live in the frame arena -- and they are not
    // cheap to rebuild (the tc_lut is a 192x192x81 contraction). These are
    // freed only by `release_persistent` or by the destructor.
    virtual Buffer* alloc_persistent(size_t bytes, std::string& error) = 0;
    virtual Buffer* upload_persistent(const void* data, size_t bytes, std::string& error) = 0;
    virtual Buffer* upload_persistent_f32(const double* data, size_t count, std::string& error) = 0;
    virtual Buffer* upload_persistent_u32(const uint32_t* data, size_t count, std::string& error) = 0;
    virtual void release_persistent(Buffer* b) = 0;

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
};

}  // namespace spk::gpu
