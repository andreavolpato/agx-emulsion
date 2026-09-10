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
    gpu::Buffer* buf = nullptr;
    uint32_t h = 0, w = 0, c = 3;

    bool valid() const { return buf != nullptr && h > 0 && w > 0; }
    size_t pixels() const { return size_t(h) * size_t(w); }
    size_t elements() const { return pixels() * c; }
    size_t bytes() const { return elements() * sizeof(float); }
};

}  // namespace spk
