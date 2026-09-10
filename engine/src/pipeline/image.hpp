// image.hpp -- a tap: device memory plus the shape that gives it meaning.
//
// Every buffer in a render is tightly packed float32, row-major, channels
// innermost. There is no stride and no padding, and that is worth stating
// because it is what lets `n_threads = h * w` index every kernel the same way.
// The one exception is the rgba16 result, whose rows are aligned so the canvas
// can draw them in place (`gpu::Gpu::texture`).
#pragma once
#include <cstdint>

#include "gpu/gpu.hpp"

namespace spk {

struct Image {
    // A counted handle, not a raw pointer: when the last `Image` naming a
    // buffer goes out of scope the buffer returns to the pool, so a linear
    // node chain holds two or three full-frame buffers rather than one per
    // node. Reclaiming only at the end of a frame cost 6.4 s instead of 0.8
    // at 24 MP, and 3.2 GB instead of a few hundred megabytes.
    gpu::BufferRef buf;
    uint32_t h = 0, w = 0, c = 3;

    bool valid() const { return static_cast<bool>(buf) && h > 0 && w > 0; }
    size_t pixels() const { return size_t(h) * size_t(w); }
    size_t elements() const { return pixels() * c; }
    size_t bytes() const { return elements() * sizeof(float); }
};

}  // namespace spk
