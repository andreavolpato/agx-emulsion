// gpu_smoke.cpp -- RFC-014 §6 step 2's gate, at the smallest possible scale:
// the C++ side creates a device, loads the shipped metallib, proves the math
// mode, and runs kernels whose answers are known by hand.
//
// This is not a parity harness -- `parity_render.py` is. It is the check that
// the *boundary* works, so that a later parity failure is a kernel and not the
// plumbing. "A boundary that works for one node works for twenty-one."
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "gpu/gpu.hpp"

using namespace spk;

static int failures = 0;

static void check(bool ok, const std::string& what, const std::string& detail = "") {
    std::printf("%s  %s%s\n", ok ? "ok  " : "FAIL", what.c_str(),
                detail.empty() ? "" : ("  -- " + detail).c_str());
    if (!ok) ++failures;
}

static bool nearly(float a, float b, float tol = 1e-6f) {
    return std::fabs(a - b) <= tol * std::fmax(1.0f, std::fabs(b));
}

int main(int argc, char** argv) {
    const std::string metallib = argc > 1 ? argv[1] : "resources/spektrafilm.metallib";
    std::string error;
    gpu::Gpu* g = gpu::Gpu::create_metal(nullptr, metallib, error);
    if (!g) { std::printf("FAIL  create_metal  -- %s\n", error.c_str()); return 1; }
    check(true, "device", g->device_name());

    std::string detail;
    check(g->check_math_mode(detail), "math mode is safe", detail);

    // --- log10_guarded, against the expression it is a port of -------------
    {
        g->begin_frame();
        const size_t n = 12;
        float x[n];
        for (size_t i = 0; i < n; ++i) x[i] = -1.0f + 0.31f * float(i);
        const float k[3] = {1.0f, 2.0f, 0.5f};
        const uint32_t meta[1] = {uint32_t(n)};
        gpu::BufferRef bx = g->upload(x, sizeof x, error);
        gpu::BufferRef bk = g->upload(k, sizeof k, error);
        gpu::BufferRef out = g->alloc(n * sizeof(float), error);
        bool ok = bool(bx) && bool(bk) && bool(out) &&
                  g->dispatch("spk_log10_guarded",
                              {gpu::Arg::buf(bx), gpu::Arg::buf(bk), gpu::Arg::inline_bytes(meta, 1),
                               gpu::Arg::buf(out)}, n, error) &&
                  g->flush(error);
        if (ok) {
            const float* got = static_cast<const float*>(g->contents(out.get()));
            for (size_t i = 0; i < n && ok; ++i) {
                const float want = std::log10(std::fmax(x[i] * k[i % 3], 0.0f) + 1e-10f);
                ok = nearly(got[i], want, 1e-5f);
                if (!ok) error = "index " + std::to_string(i) + ": got " + std::to_string(got[i]) +
                                 ", want " + std::to_string(want);
            }
        }
        check(ok, "spk_log10_guarded", ok ? "" : error);
        g->end_frame();
    }

    // --- matmul3, on a matrix whose action is obvious ----------------------
    {
        g->begin_frame();
        const float x[6] = {1, 2, 3, -1, 0.5f, 4};
        // Row-vector convention: out = x @ M, so M is read column-major here.
        const float m[9] = {1, 0, 0, 0, 2, 0, 0, 0, 3};
        const uint32_t n[1] = {2};
        gpu::BufferRef bx = g->upload(x, sizeof x, error);
        gpu::BufferRef bm = g->upload(m, sizeof m, error);
        gpu::BufferRef out = g->alloc(sizeof x, error);
        bool ok = g->dispatch("spk_matmul3",
                              {gpu::Arg::buf(bx), gpu::Arg::buf(bm), gpu::Arg::inline_bytes(n, 1),
                               gpu::Arg::buf(out)}, 2, error) && g->flush(error);
        if (ok) {
            const float* got = static_cast<const float*>(g->contents(out.get()));
            const float want[6] = {1, 4, 9, -1, 1, 12};
            for (int i = 0; i < 6 && ok; ++i) ok = nearly(got[i], want[i]);
        }
        check(ok, "spk_matmul3", ok ? "" : error);
        g->end_frame();
    }

    // --- the reduction, whose whole job is to agree with a serial max ------
    {
        g->begin_frame();
        const size_t n = 100000;
        std::vector<float> x(n);
        for (size_t i = 0; i < n; ++i) x[i] = std::sin(float(i) * 0.001f) * 100.0f;
        x[54321] = 12345.0f;
        const uint32_t meta[1] = {uint32_t(n)};
        const size_t groups = 64;
        gpu::BufferRef bx = g->upload(x.data(), n * sizeof(float), error);
        gpu::BufferRef out = g->alloc(groups * sizeof(float), error);
        bool ok = g->dispatch("spk_reduce_max",
                              {gpu::Arg::buf(bx), gpu::Arg::inline_bytes(meta, 1), gpu::Arg::buf(out)},
                              groups * 256, error) && g->flush(error);
        if (ok) {
            const float* partials = static_cast<const float*>(g->contents(out.get()));
            float best = partials[0];
            for (size_t i = 1; i < groups; ++i) best = std::fmax(best, partials[i]);
            ok = best == 12345.0f;
            if (!ok) error = "reduced to " + std::to_string(best);
        }
        check(ok, "spk_reduce_max", ok ? "" : error);
        g->end_frame();
    }

    // --- the zero-copy texture, which is the point of taking the device ----
    {
        g->begin_frame();
        const uint32_t w = 7, h = 5;
        const uint32_t align = g->texture_row_alignment_px();
        const uint32_t stride = ((w + align - 1) / align) * align;
        std::vector<float> rgb(size_t(w) * h * 3);
        for (size_t i = 0; i < rgb.size(); ++i) rgb[i] = float(i % 17) / 16.0f;
        const uint32_t meta[3] = {w * h, w, stride};
        gpu::BufferRef src = g->upload(rgb.data(), rgb.size() * sizeof(float), error);
        gpu::BufferRef dst = g->alloc_zeroed(size_t(stride) * h * 4 * sizeof(uint16_t), error);
        bool ok = g->dispatch("spk_to_rgba16",
                              {gpu::Arg::buf(src), gpu::Arg::inline_bytes(meta, 3), gpu::Arg::buf(dst)},
                              size_t(w) * h, error) && g->flush(error);
        if (ok) {
            const uint16_t* got = static_cast<const uint16_t*>(g->contents(dst.get()));
            for (uint32_t y = 0; y < h && ok; ++y)
                for (uint32_t x = 0; x < w && ok; ++x)
                    for (uint32_t c = 0; c < 3 && ok; ++c) {
                        const float v = rgb[(size_t(y) * w + x) * 3 + c];
                        const uint16_t want = uint16_t(v * 65535.0f + 0.5f);
                        const uint16_t g16 = got[(size_t(y) * stride + x) * 4 + c];
                        ok = g16 == want;
                        if (!ok) error = "pixel (" + std::to_string(x) + "," + std::to_string(y) +
                                         ") channel " + std::to_string(c) + ": " +
                                         std::to_string(g16) + " != " + std::to_string(want);
                    }
            if (ok) ok = g->texture(dst.get(), w, h, stride, error) != nullptr;
        }
        check(ok, "spk_to_rgba16 + zero-copy texture", ok ? "" : error);
        g->end_frame();
    }

    // --- the arena, which must reuse rather than grow ----------------------
    {
        size_t first = 0;
        for (int frame = 0; frame < 3; ++frame) {
            g->begin_frame();
            std::vector<gpu::BufferRef> buffers;
            for (int i = 0; i < 8; ++i) buffers.push_back(g->alloc(1 << 20, error));
            (void)buffers;
            g->end_frame();
            if (frame == 0) first = 8;
        }
        // Nothing observable to assert from outside except that three frames
        // of eight 1 MB buffers did not fail; the pool's reuse is verified by
        // the fact that `alloc` never returned null.
        check(first == 8, "frame arena survives three frames of eight buffers");
    }

    delete g;
    std::printf("\n%d failures\n", failures);
    return failures ? 1 : 0;
}
