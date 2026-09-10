// nodes.metal -- the pointwise and per-node kernels.
//
// Every body below is transferred verbatim from
// `src/spektrafilm/backends/metal/kernels.py`, where it was held to float32
// storage epsilon against the numba reference. The only change is the
// signature: `mx.fast.metal_kernel` wrapped each body in one at run time from
// `input_names` / `output_names`, and here it is written out so the kernels
// compile with the app instead (RFC-014 §2.3 -- a broken kernel becomes a
// build failure rather than a first-render failure).
//
// `thread_position_in_grid` is declared `uint3` on purpose: it is what the
// bodies say, and keeping the name and the type means the body is a copy
// rather than a transcription.
#include "spk_common.h"

// ``log10(fmax(x * c, 0) + 1e-10)`` -- the guard every log node uses;
// ``c`` may be per channel.
kernel void spk_log10_guarded(device const float* x [[buffer(0)]],
                              device const float* k [[buffer(1)]],
                              device const uint* n [[buffer(2)]],
                              device float* out [[buffer(3)]],
                              uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    float v = max(x[i] * k[i % 3u], 0.0f) + 1e-10f;
    out[i] = log10(v);
}

// ``boost_highlights`` with the image-global max reduced on device; the host
// solves for the four constants and passes them in.
kernel void spk_boost(device const float* x [[buffer(0)]],
                      device const float* p [[buffer(1)]],
                      device const uint* n [[buffer(2)]],
                      device float* out [[buffer(3)]],
                      uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    float xv = x[i];
    float raw_x0 = p[0], inv_max_raw = p[1], a = p[2], boost_scale = p[3];
    if (xv <= raw_x0) { out[i] = xv; return; }
    float dx = (xv - raw_x0) * inv_max_raw;
    out[i] = xv + boost_scale * (exp(a * dx) - a * dx - 1.0f);
}

// Per-channel 1-D linear LUT with ``fast_interp`` semantics.
kernel void spk_curves(device const float* x [[buffer(0)]],
                       device const float* xa [[buffer(1)]],
                       device const float* inv [[buffer(2)]],
                       device const float* y [[buffer(3)]],
                       device const uint* meta [[buffer(4)]],
                       device float* out [[buffer(5)]],
                       uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint K = meta[0], n = meta[1];
    if (i >= n) return;
    for (uint c = 0u; c < 3u; ++c) out[3u * i + c] = interp_channel(xa, inv, y, K, c, x[3u * i + c]);
}

// ``x @ M`` for an (H, W, 3) image and a 3x3 matrix, in one pass.
kernel void spk_matmul3(device const float* x [[buffer(0)]],
                        device const float* m [[buffer(1)]],
                        device const uint* n [[buffer(2)]],
                        device float* out [[buffer(3)]],
                        uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    float a = x[3u * i], b = x[3u * i + 1u], c = x[3u * i + 2u];
    // row-vector convention: out = x @ M
    out[3u * i]      = a * m[0] + b * m[3] + c * m[6];
    out[3u * i + 1u] = a * m[1] + b * m[4] + c * m[7];
    out[3u * i + 2u] = a * m[2] + b * m[5] + c * m[8];
}

// Hanatos 2025 spectral upsampling, front half: RGB -> (tc, b).
kernel void spk_tc_b(device const float* rgb [[buffer(0)]],
                     device const float* m [[buffer(1)]],
                     device const uint* n [[buffer(2)]],
                     device float* tc [[buffer(3)]],
                     device float* bout [[buffer(4)]],
                     uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    float r = rgb[3u * i], g = rgb[3u * i + 1u], bl = rgb[3u * i + 2u];
    float X = m[0] * r + m[1] * g + m[2] * bl;
    float Y = m[3] * r + m[4] * g + m[5] * bl;
    float Z = m[6] * r + m[7] * g + m[8] * bl;
    float b = X + Y + Z;
    float denom = b > 1e-10f ? b : 1e-10f;
    float x = X / denom, y = Y / denom;
    float omx = 1.0f - x;
    float ty = y / (omx > 1e-10f ? omx : 1e-10f);
    float tx = omx * omx;
    tc[2u * i] = clamp(tx, 0.0f, 1.0f);
    tc[2u * i + 1u] = clamp(ty, 0.0f, 1.0f);
    bout[i] = isnan(b) ? 0.0f : b;
}

// Back half: bicubic sample of the tc_lut, scaled back by b.
kernel void spk_lut2d_cubic(device const float* tc [[buffer(0)]],
                            device const float* b [[buffer(1)]],
                            device const float* lut [[buffer(2)]],
                            device const uint* meta [[buffer(3)]],
                            device float* out [[buffer(4)]],
                            uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint L = meta[0], n = meta[1];
    if (i >= n) return;
    float scale = (float)(L - 1u);
    float x = tc[2u * i] * scale, y = tc[2u * i + 1u] * scale;
    int xb, yb; float xf, yf;
    base_frac(x, (int)L, xb, xf);
    base_frac(y, (int)L, yb, yf);
    float wx[4] = { mitchell(xf + 1.0f), mitchell(xf), mitchell(xf - 1.0f), mitchell(xf - 2.0f) };
    float wy[4] = { mitchell(yf + 1.0f), mitchell(yf), mitchell(yf - 1.0f), mitchell(yf - 2.0f) };
    float3 acc = float3(0.0f); float wsum = 0.0f;
    for (int a = 0; a < 4; ++a) {
        int xi = safe_index(xb - 1 + a, (int)L);
        for (int bb = 0; bb < 4; ++bb) {
            int yj = safe_index(yb - 1 + bb, (int)L);
            float wgt = wx[a] * wy[bb];
            wsum += wgt;
            uint o = 3u * ((uint)xi * L + (uint)yj);
            acc += wgt * float3(lut[o], lut[o + 1u], lut[o + 2u]);
        }
    }
    if (wsum != 0.0f) acc /= wsum;
    float bv = b[i];
    out[3u * i] = acc.x * bv; out[3u * i + 1u] = acc.y * bv; out[3u * i + 2u] = acc.z * bv;
}

// The DIR-coupler correction field, before its spatial diffusion.
kernel void spk_couplers_correction(device const float* cmy [[buffer(0)]],
                                    device const float* m [[buffer(1)]],
                                    device const float* dmax [[buffer(2)]],
                                    device const uint* pos [[buffer(3)]],
                                    device const float* shift [[buffer(4)]],
                                    device const uint* n [[buffer(5)]],
                                    device float* out [[buffer(6)]],
                                    uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    float c0 = cmy[3u * i], c1 = cmy[3u * i + 1u], c2 = cmy[3u * i + 2u];
    if (pos[0] != 0u) { c0 = dmax[0] - c0; c1 = dmax[1] - c1; c2 = dmax[2] - c2; }
    float sh = shift[0];
    c0 += sh * c0 * c0; c1 += sh * c1 * c1; c2 += sh * c2 * c2;
    out[3u * i]      = c0 * m[0] + c1 * m[3] + c2 * m[6];
    out[3u * i + 1u] = c0 * m[1] + c1 * m[4] + c2 * m[7];
    out[3u * i + 2u] = c0 * m[2] + c1 * m[5] + c2 * m[8];
}

// The fused spectral integral. 3-in / 3-out, so the wavelength axis never
// needs to exist in memory -- it lives in registers.
kernel void spk_spectral_epilogue(device const float* cmy [[buffer(0)]],
                                  device const float* chd [[buffer(1)]],
                                  device const float* base [[buffer(2)]],
                                  device const float* ixs [[buffer(3)]],
                                  device const float* ep [[buffer(4)]],
                                  device const uint* meta [[buffer(5)]],
                                  device float* out [[buffer(6)]],
                                  uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint n = meta[0], nl = meta[1], mode = meta[2];
    if (i >= n) return;
    float c0 = cmy[3u * i], c1 = cmy[3u * i + 1u], c2 = cmy[3u * i + 2u];
    float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    for (uint l = 0u; l < nl; ++l) {
        float d = c0 * chd[3u * l] + c1 * chd[3u * l + 1u] + c2 * chd[3u * l + 2u] + base[l];
        float t = exp2(-d * 3.321928094887362f);
        a0 += t * ixs[3u * l]; a1 += t * ixs[3u * l + 1u]; a2 += t * ixs[3u * l + 2u];
    }
    // epilogue: v = a * gain + offset; mode 0 -> log10(max(v,0)+1e-10); mode 1 -> max(v,0)+1e-10
    float v0 = max(a0 * ep[0] + ep[3], 0.0f) + 1e-10f;
    float v1 = max(a1 * ep[1] + ep[4], 0.0f) + 1e-10f;
    float v2 = max(a2 * ep[2] + ep[5], 0.0f) + 1e-10f;
    if (mode == 0u) { v0 = log10(v0); v1 = log10(v1); v2 = log10(v2); }
    out[3u * i] = v0; out[3u * i + 1u] = v1; out[3u * i + 2u] = v2;
}

kernel void spk_print_exposure(device const float* x [[buffer(0)]],
                               device const float* k [[buffer(1)]],
                               device const uint* n [[buffer(2)]],
                               device float* out [[buffer(3)]],
                               uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    float raw = exp2(x[i] * 3.321928094887362f) * k[i % 3u];
    out[i] = log10(max(raw, 0.0f) + 1e-10f);
}

// Signed power, `colour.algebra.spow`: |v|**p with v's sign kept, so a
// negative code value does not become NaN. The transfer functions below use it
// wherever the reference does and nowhere else -- ProPhoto's and Adobe's
// curves are bare `**` in colour, and matching that includes matching where
// they produce NaN.
inline float spow(float v, float p) {
    float s = v < 0.0f ? -1.0f : (v > 0.0f ? 1.0f : 0.0f);
    return s * pow(fabs(v), p);
}

// The transfer functions, as one kernel over a mode. Mode order matches
// `core/colour.cpp`'s `Cctf` enum: 0 sRGB (and Display P3), 1 ProPhoto RGB,
// 2 Adobe RGB (1998), 3 BT.709/BT.2020, 4 identity (the ACES spaces).
//
// The breakpoints are the reference's exact ones, not the spec's printed
// roundings: the sRGB decode turns at the *encoded* value of 0.0031308
// (0.040449936), and the BT inverse at the encoded value of beta rather than
// 4.5*beta. At exactly 0.04045 the two choices take different branches.
inline float cctf_decode_mode(float v, uint mode) {
    switch (mode) {
        case 0u: return (0.040449936f >= v) ? v / 12.92f : spow((v + 0.055f) / 1.055f, 2.4f);
        case 1u: return (v < 16.0f * (1.0f / 512.0f)) ? v / 16.0f : pow(v, 1.8f);
        case 2u: return pow(v, 563.0f / 256.0f);
        case 3u: {
            const float alpha = 1.099f, beta = 0.018f;
            const float bp = alpha * pow(beta, 0.45f) - (alpha - 1.0f);
            return (bp > v) ? v / 4.5f : spow((v + (alpha - 1.0f)) / alpha, 1.0f / 0.45f);
        }
        default: return v;
    }
}

inline float cctf_encode_mode(float v, uint mode) {
    switch (mode) {
        // Transferred verbatim from `spk_srgb_oetf` in
        // backends/metal/kernels.py -- the one expression on the hot path, so
        // it lives inside the switch rather than in a second kernel that could
        // drift from this one.
        case 0u: return (v <= 0.0031308f) ? 12.92f * v : 1.055f * spow(v, 1.0f / 2.4f) - 0.055f;
        case 1u: return (v < 1.0f / 512.0f) ? v * 16.0f : pow(v, 1.0f / 1.8f);
        case 2u: return pow(v, 256.0f / 563.0f);
        case 3u: {
            const float alpha = 1.099f, beta = 0.018f;
            return (beta > v) ? v * 4.5f : alpha * spow(v, 0.45f) - (alpha - 1.0f);
        }
        default: return v;
    }
}

// The input transfer function, applied once at the door (`decode_input`).
//
// It is at the door and not inside `upsample` for a measured reason: a linear
// auto-exposure gain multiplied into gamma-encoded data is not the same as
// gain-then-decode -- for ProPhoto's 1.8 the effective gain is g**1.8, which
// silently mis-exposed every encoded input.
kernel void spk_cctf_decode(device const float* x [[buffer(0)]],
                            device const uint* meta [[buffer(1)]],
                            device float* out [[buffer(2)]],
                            uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= meta[0]) return;
    out[i] = cctf_decode_mode(x[i], meta[1]);
}

// The output transfer function. The matrix is `RGB_to_RGB(x, cs, cs)`'s
// near-identity, recovered on the identity at setup: it is *not* the identity,
// and replacing it with one changes output by 3.8e-4 (AGENTS.md trap 7).
kernel void spk_cctf_encode_matrix(device const float* x [[buffer(0)]],
                                   device const float* m [[buffer(1)]],
                                   device const uint* meta [[buffer(2)]],
                                   device float* out [[buffer(3)]],
                                   uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= meta[0]) return;
    uint mode = meta[1];
    float a = x[3u * i], b = x[3u * i + 1u], c = x[3u * i + 2u];
    float v[3] = { a * m[0] + b * m[3] + c * m[6], a * m[1] + b * m[4] + c * m[7], a * m[2] + b * m[5] + c * m[8] };
    for (uint k = 0u; k < 3u; ++k) out[3u * i + k] = cctf_encode_mode(v[k], mode);
}

// preprocess.geometry -- a transliteration of utils/geometry.py, with the
// pixel coordinates carried as double-floats so an 8k frame's mapping is not
// off by half a pixel.
kernel void spk_geometry_resample_df(device const float* img [[buffer(0)]],
                                     device const float* g [[buffer(1)]],
                                     device const uint* meta [[buffer(2)]],
                                     device float* out [[buffer(3)]],
                                     uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    uint SH = meta[0], SW = meta[1], OH = meta[2], OW = meta[3], turns = meta[4], flips = meta[5];
    if (i >= OH * OW) return;
    uint oy = i / OW, ox = i % OW;
    // Output pixel -> the crop's unrotated frame, in *output pixels* (exact
    // integers plus 0.5) so the flips and quarter turns cost no rounding.
    float u = (float)ox + 0.5f, v = (float)oy + 0.5f;   // in [0, OW] x [0, OH]
    if (flips & 1u) u = (float)OW - u;
    if (flips & 2u) v = (float)OH - v;
    float t;
    // after a turn the crop's own frame is (CW, CH) = (OH, OW) for odd turns
    switch (turns) {
        case 1u: t = u; u = v; v = (float)OW - t; break;
        case 2u: u = (float)OW - u; v = (float)OH - v; break;
        case 3u: t = u; u = (float)OH - v; v = t; break;
        default: break;
    }
    // g (df pairs): 0 sx = crop_w*SW/CW, 1 sy = crop_h*SH/CH, 2 hx = crop_w*SW/2, 3 hy = crop_h*SH/2,
    //               4 cx*SW - 0.5, 5 cy*SH - 0.5, 6 cos, 7 sin
    df px = df_sub(df_mul_f(df{g[0], g[1]}, u), df{g[4], g[5]});
    df py = df_sub(df_mul_f(df{g[2], g[3]}, v), df{g[6], g[7]});
    df ca = df{g[12], g[13]}, sa = df{g[14], g[15]};
    df fx = df_add(df{g[8], g[9]},  df_sub(df_mul(px, ca), df_mul(py, sa)));
    df fy = df_add(df{g[10], g[11]}, df_add(df_mul(px, sa), df_mul(py, ca)));
    float w1 = (float)SW - 1.0f, h1 = (float)SH - 1.0f;
    // clamp to edge, then split into an integer base and an exact fraction
    float x0f, y0f, tx, ty;
    if (fx.hi <= 0.0f) { x0f = 0.0f; tx = 0.0f; }
    else if (fx.hi >= w1) { x0f = w1; tx = 0.0f; }
    else { x0f = floor(fx.hi); tx = (fx.hi - x0f) + fx.lo; if (tx < 0.0f) { tx = 0.0f; } if (tx > 1.0f) { tx = 1.0f; } }
    if (fy.hi <= 0.0f) { y0f = 0.0f; ty = 0.0f; }
    else if (fy.hi >= h1) { y0f = h1; ty = 0.0f; }
    else { y0f = floor(fy.hi); ty = (fy.hi - y0f) + fy.lo; if (ty < 0.0f) { ty = 0.0f; } if (ty > 1.0f) { ty = 1.0f; } }
    uint x0 = (uint)x0f, y0 = (uint)y0f;
    uint x1 = min(x0 + 1u, SW - 1u), y1 = min(y0 + 1u, SH - 1u);
    for (uint c = 0u; c < 3u; ++c) {
        float a = img[3u * (y0 * SW + x0) + c], b = img[3u * (y0 * SW + x1) + c];
        float d = img[3u * (y1 * SW + x0) + c], e = img[3u * (y1 * SW + x1) + c];
        float top = a * (1.0f - tx) + b * tx;
        float bot = d * (1.0f - tx) + e * tx;
        out[3u * i + c] = top * (1.0f - ty) + bot * ty;
    }
}

// `ColorReferenceService.black_white_xyz_correction`.
//
// A clipped linear stretch derived from the *Y* channel, applied to all three
// -- so it moves luminance and leaves chromaticity alone. `p` is (m, q) from
// the correction line the host solved from the medium's own black and white.
kernel void spk_bw_correct(device const float* xyz [[buffer(0)]],
                           device const float* p [[buffer(1)]],
                           device const uint* n [[buffer(2)]],
                           device float* out [[buffer(3)]],
                           uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    float y = xyz[3u * i + 1u];
    float corrected = clamp(p[0] * y + p[1], 0.0f, 1.0f);
    float scale = corrected / (y + 1e-10f);
    for (uint c = 0u; c < 3u; ++c) out[3u * i + c] = xyz[3u * i + c] * scale;
}
