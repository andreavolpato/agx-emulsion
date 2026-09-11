// util.metal -- the primitives MLX supplied for free, plus the tier downscale
// and the output conversion.
//
// RFC-014 §0.1 counted every `mx.*` call in the GPU core: `mx.array`,
// `mx.contiguous`, `mx.zeros`, `mx.transpose`, `mx.max`, `mx.eval`. None of
// them is arithmetic MLX owns; each is one Metal call or one trivial kernel,
// and this file is those trivial kernels.
#include "spk_common.h"

// `mx.contiguous(img[:, :, 0:3])` -- alpha is dropped at the door, and the
// pipeline never reads a tier image's alpha again.
kernel void spk_take_rgb(device const float* img [[buffer(0)]],
                         device const uint* meta [[buffer(1)]],
                         device float* out [[buffer(2)]],
                         uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint n = meta[0], channels = meta[1];
    if (i >= n) return;
    for (uint c = 0u; c < 3u; ++c) out[3u * i + c] = img[channels * i + c];
}

// `out[i] = x[i] * s[c] + t[c]` -- the per-channel affine that stands in for
// `x * scalar`, `x - density_min`, `x / n_sub`, and the exposure gain.
kernel void spk_affine3(device const float* x [[buffer(0)]],
                        device const float* s [[buffer(1)]],
                        device const float* t [[buffer(2)]],
                        device const uint* n [[buffer(3)]],
                        device float* out [[buffer(4)]],
                        uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    uint c = i % 3u;
    out[i] = x[i] * s[c] + t[c];
}

// Elementwise product -- grain's micro-structure field.
kernel void spk_mul(device const float* x [[buffer(0)]],
                    device const float* y [[buffer(1)]],
                    device const uint* n [[buffer(2)]],
                    device float* out [[buffer(3)]],
                    uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    out[i] = x[i] * y[i];
}

// `xyz + (field / 100) * illuminant_xyz` -- `model/glare.add_glare`.
kernel void spk_glare_add(device const float* xyz [[buffer(0)]],
                          device const float* field [[buffer(1)]],
                          device const float* illum [[buffer(2)]],
                          device const uint* n [[buffer(3)]],
                          device float* out [[buffer(4)]],
                          uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    uint c = i % 3u;
    out[i] = xyz[i] + (field[i] / 100.0f) * illum[c];
}

// `mx.max(x)`, as one partial per threadgroup; the host takes the max of the
// partials, which is a few thousand floats and order-independent.
kernel void spk_reduce_max(device const float* x [[buffer(0)]],
                           device const uint* n [[buffer(1)]],
                           device float* partials [[buffer(2)]],
                           uint3 thread_position_in_grid [[thread_position_in_grid]],
                           uint3 threads_per_grid [[threads_per_grid]],
                           uint lid [[thread_index_in_threadgroup]],
                           uint3 tg [[threadgroup_position_in_grid]],
                           uint3 tgsize [[threads_per_threadgroup]]) {
    // Metal requires every grid attribute on a kernel to be uniformly scalar
    // or uniformly vector, so `threads_per_threadgroup` is uint3 here even
    // though only .x is used.
    threadgroup float scratch[256];
    float best = -INFINITY;
    for (uint i = thread_position_in_grid.x; i < n[0]; i += threads_per_grid.x) best = max(best, x[i]);
    scratch[lid] = best;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = tgsize.x / 2u; stride > 0u; stride >>= 1) {
        if (lid < stride) scratch[lid] = max(scratch[lid], scratch[lid + stride]);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0u) partials[tg.x] = scratch[0];
}

// `mx.contiguous(mx.transpose(img, (1, 0, 2)))` -- the IIR's horizontal pass
// is the vertical kernel on the transpose, so every recurrence thread reads
// coalesced memory.
kernel void spk_transpose3(device const float* img [[buffer(0)]],
                           device const uint* meta [[buffer(1)]],
                           device float* out [[buffer(2)]],
                           uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint H = meta[0], W = meta[1];
    if (i >= H * W) return;
    uint y = i / W, x = i % W;
    uint dst = x * H + y;
    for (uint c = 0u; c < 3u; ++c) out[3u * dst + c] = img[3u * i + c];
}

// The tier downscale's resample half, verbatim from
// `backends/metal/resize.py`. The Gaussian prefilter in front of it is
// `spk_sep_fir_acc` in 'mirror' mode, which is what skimage's
// `mode='reflect'` translates to in ndimage.
kernel void spk_zoom_bilinear_mirror(device const float* img [[buffer(0)]],
                                     device const uint* meta [[buffer(1)]],
                                     device float* out [[buffer(2)]],
                                     uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint SH = meta[0], SW = meta[1], OH = meta[2], OW = meta[3];
    if (i >= OH * OW) return;
    uint oy = i / OW, ox = i % OW;
    int ya, yb, xa, xb; float ty, tx;
    sample_axis(oy, SH, OH, ya, yb, ty);
    sample_axis(ox, SW, OW, xa, xb, tx);
    for (uint c = 0u; c < 3u; ++c) {
        float a = img[3u * ((uint)ya * SW + (uint)xa) + c], b = img[3u * ((uint)ya * SW + (uint)xb) + c];
        float d = img[3u * ((uint)yb * SW + (uint)xa) + c], e = img[3u * ((uint)yb * SW + (uint)xb) + c];
        float top = a + tx * (b - a);
        float bot = d + tx * (e - d);
        out[3u * i + c] = top + ty * (bot - top);
    }
}

// `service._write_rgba16`, on device: raw uint16 RGBA, opaque alpha. The
// rounding is `(v * 65535 + 0.5)` after a clamp, the same expression, so a
// frame that used to round-trip through a file now does not change value on
// its way to the canvas.
// `meta` is (n, width, row_stride_px). The stride exists because a texture
// over this buffer needs its rows aligned (256 B on macOS), so the canvas can
// draw the pixels where they are instead of being handed a copy.
kernel void spk_to_rgba16(device const float* rgb [[buffer(0)]],
                          device const uint* meta [[buffer(1)]],
                          device ushort* out [[buffer(2)]],
                          uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint n = meta[0], width = meta[1], stride = meta[2];
    if (i >= n) return;
    uint y = i / width, x = i % width;
    uint dst = y * stride + x;
    for (uint c = 0u; c < 3u; ++c) {
        float v = clamp(rgb[3u * i + c], 0.0f, 1.0f);
        out[4u * dst + c] = (ushort)(v * 65535.0f + 0.5f);
    }
    out[4u * dst + 3u] = 65535;
}

// The fast-math probe (RFC-014 §5.1 trap 1).
//
// `a * b - a * b` is not a tautology in floating point once the compiler is
// allowed to contract one of the two products into an fma: under
// `-fmetal-math-mode=safe` it evaluates to `fma(a, b, -(a*b))`, the exact
// rounding error of `a*b`, which is small and *non-zero*. Under fast math the
// expression is reassociated away and the result is exactly 0.
//
// So the engine can ask the GPU, at startup, which way its own kernels were
// compiled, instead of trusting a flag in a build script that nothing reads.
// `spk_engine_create` refuses to start if this comes back zero.
//
// The property this depends on is contraction, not a particular compiler
// version's choice of it. If a future toolchain stops contracting under safe
// math the probe will report a false positive -- so it is checked against a
// host-computed `fma(a, b, -(a*b))`, not merely against zero.
kernel void spk_math_probe(device const float* in [[buffer(0)]],
                           device float* out [[buffer(1)]],
                           uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    float a = in[2u * i], b = in[2u * i + 1u];
    out[i] = a * b - a * b;
}

// A strided sample of the frame, gathered on device.
//
// The auto-exposure meter needs a ~256 px view of the frame and nothing more
// (AGENTS.md trap 10: a full-resolution order-0 downscale cost 7.1 s at 45 MP
// against ~0 ms for a stride). Gathering it here rather than reading the whole
// frame back is the difference between moving 540 MB and moving 800 kB.
kernel void spk_stride_sample(device const float* img [[buffer(0)]],
                              device const uint* meta [[buffer(1)]],
                              device float* out [[buffer(2)]],
                              uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint SW = meta[0], OH = meta[1], OW = meta[2], step = meta[3];
    if (i >= OH * OW) return;
    uint oy = i / OW, ox = i % OW;
    uint src = (oy * step) * SW + (ox * step);
    for (uint c = 0u; c < 3u; ++c) out[3u * i + c] = img[3u * src + c];
}

// The baked print+scan LUT, applied trilinearly.
//
// Transferred verbatim from `backends/mlx_ops._LUT3D_SOURCE`, which was held
// to the `scipy.ndimage.map_coordinates(order=1)` reference at mean 1.3e-8 /
// max 2.4e-7 -- float32 storage epsilon, i.e. the same eight corners with the
// same weights (HANDOFF-PRINT-LUT §3.1). The only change on the way across is
// the kernel signature: what MLX passed as named inputs is now numbered
// buffers.
//
// `lo` and `inv_span` come from the LUT's own per-channel density axes, which
// the bake writes **uniformly spaced** -- `bake_resources.bake_print_luts`
// checks that at bake time, because one subtract and one multiply is only the
// same interpolation as the reference's when the axis is uniform, and a
// kernel cannot report the difference.
//
// Coordinates are clipped, so ndimage's 'nearest' boundary handling reduces
// to clamping the upper neighbour index -- `min(i0 + 1, S - 1)` below.
//
// One thread per pixel; the eight corner fetches are independent loads, so
// this is bound by the LUT gather rather than by arithmetic. The table is
// 33^3 * 3 * 4 B = 431 kB and stays hot in cache across the whole frame.
kernel void spk_lut3d_trilinear(device const float* density [[buffer(0)]],
                                device const float* lut [[buffer(1)]],
                                device const float* lo [[buffer(2)]],
                                device const float* inv_span [[buffer(3)]],
                                device const uint* meta [[buffer(4)]],
                                device float* out [[buffer(5)]],
                                uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint gid = thread_position_in_grid.x;
    uint n = meta[0];
    uint S = meta[1];
    if (gid >= n) return;

    float fS = (float)(S - 1);
    float c0 = (density[3*gid + 0] - lo[0]) * inv_span[0];
    float c1 = (density[3*gid + 1] - lo[1]) * inv_span[1];
    float c2 = (density[3*gid + 2] - lo[2]) * inv_span[2];
    c0 = clamp(c0, 0.0f, 1.0f) * fS;
    c1 = clamp(c1, 0.0f, 1.0f) * fS;
    c2 = clamp(c2, 0.0f, 1.0f) * fS;

    uint i0 = (uint)floor(c0); uint j0 = (uint)floor(c1); uint k0 = (uint)floor(c2);
    float fx = c0 - (float)i0, fy = c1 - (float)j0, fz = c2 - (float)k0;
    uint i1 = min(i0 + 1u, S - 1u);
    uint j1 = min(j0 + 1u, S - 1u);
    uint k1 = min(k0 + 1u, S - 1u);

    // Row-major (S, S, S, 3): index = ((i*S + j)*S + k)*3 + ch
    uint b00 = ((i0 * S + j0) * S) * 3u;
    uint b01 = ((i0 * S + j1) * S) * 3u;
    uint b10 = ((i1 * S + j0) * S) * 3u;
    uint b11 = ((i1 * S + j1) * S) * 3u;
    uint k0o = k0 * 3u, k1o = k1 * 3u;

    float w0 = 1.0f - fx, w1 = fx;
    float v0 = 1.0f - fy, v1 = fy;
    float u0 = 1.0f - fz, u1 = fz;

    for (uint ch = 0; ch < 3u; ++ch) {
        float c000 = lut[b00 + k0o + ch], c001 = lut[b00 + k1o + ch];
        float c010 = lut[b01 + k0o + ch], c011 = lut[b01 + k1o + ch];
        float c100 = lut[b10 + k0o + ch], c101 = lut[b10 + k1o + ch];
        float c110 = lut[b11 + k0o + ch], c111 = lut[b11 + k1o + ch];
        float c00 = c000 * u0 + c001 * u1;
        float c01 = c010 * u0 + c011 * u1;
        float c10 = c100 * u0 + c101 * u1;
        float c11 = c110 * u0 + c111 * u1;
        out[3*gid + ch] = (c00 * v0 + c01 * v1) * w0 + (c10 * v0 + c11 * v1) * w1;
    }
}

// The DI package's normalisation: `clip((negative - lo) / (hi - lo), 0, 1)`,
// the same per-channel axes the LUT is indexed by -- so the flat file and the
// `.cube` agree on what 0 and 1 mean and the cube needs no DOMAIN_MIN/MAX
// support in whatever opens it (`service._m_export_di`).
kernel void spk_di_normalise(device const float* density [[buffer(0)]],
                             device const float* lo [[buffer(1)]],
                             device const float* inv_span [[buffer(2)]],
                             device const uint* n [[buffer(3)]],
                             device float* out [[buffer(4)]],
                             uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    uint c = i % 3u;
    out[i] = clamp((density[i] - lo[c]) * inv_span[c], 0.0f, 1.0f);
}
