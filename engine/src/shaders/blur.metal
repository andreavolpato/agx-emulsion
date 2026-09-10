// blur.metal -- the separable blurs, transferred verbatim from
// `src/spektrafilm/backends/metal/blur.py`.
//
// Two paths, dispatched per channel exactly as `utils/fast_gaussian_filter`
// does on the CPU: a fused FIR for sigma < 3 ('reflect' edges, truncate 3.0)
// and the Young & van Vliet 2002 third-order IIR for sigma >= 3
// (sample-replication edges). The host side picks; these only execute.
//
// The IIR's recurrence state is a double-float, and that is not decoration.
// The reference keeps it in float64 registers; at sigma ~130 px the YvV poles
// sit close enough to the unit circle that a float32 recurrence drifts by
// ~1e-2 relative -- measured at 6.2e-3 max abs on the DIR-coupler tail at
// 45 MP. Metal has no float64.
#include "spk_common.h"

// One thread per pixel. `accumulate` fuses the mixture's multiply-add into the
// second pass, which is what keeps a three-component exponential PSF at three
// blurs rather than three blurs plus three full-resolution adds.
kernel void spk_sep_fir_acc(device const float* img [[buffer(0)]],
                            device const float* w [[buffer(1)]],
                            device const float* accin [[buffer(2)]],
                            device const float* wt [[buffer(3)]],
                            device const uint* meta [[buffer(4)]],
                            device float* out [[buffer(5)]],
                            uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint gid = thread_position_in_grid.x;
    uint H = meta[0], W = meta[1];
    if (gid >= H * W) return;
    int R = (int)meta[2];          // padded half-width shared by the 3 channels
    uint axis = meta[3];
    uint accumulate = meta[4];     // out = acc + wt * conv (fuses the mixture's multiply-add)
    uint mirror = meta[5];         // 0: scipy 'reflect' (d c b a | a b c d), 1: scipy 'mirror' (d c b | a b c d | c b a)
    uint y = gid / W, x = gid % W;
    int nlim = (axis == 0u) ? (int)H : (int)W;
    int base = (axis == 0u) ? (int)y : (int)x;
    float3 acc = float3(0.0f);
    for (int k = -R; k <= R; ++k) {
        int j = mirror != 0u ? mirror_index(base + k, nlim) : reflect_index(base + k, nlim);
        uint src = (axis == 0u) ? ((uint)j * W + x) : (y * W + (uint)j);
        uint wi = (uint)(k + R);
        float3 wv = float3(w[wi], w[(2u * (uint)R + 1u) + wi], w[2u * (2u * (uint)R + 1u) + wi]);
        acc += float3(img[3u * src], img[3u * src + 1u], img[3u * src + 2u]) * wv;
    }
    if (accumulate != 0u) {
        acc = float3(accin[3u * gid], accin[3u * gid + 1u], accin[3u * gid + 2u]) + acc * float3(wt[0], wt[1], wt[2]);
    }
    out[3u * gid] = acc.x; out[3u * gid + 1u] = acc.y; out[3u * gid + 2u] = acc.z;
}

// One thread per (column, channel). Forward sweep down the rows, backward
// sweep up. Coefficients arrive as (hi, lo) pairs; inactive channels copy
// through. The horizontal pass is this kernel applied to a transposed copy, so
// every recurrence thread reads coalesced memory.
kernel void spk_iir_vertical_df_acc(device const float* img [[buffer(0)]],
                                    device const float* coef [[buffer(1)]],
                                    device const uint* act [[buffer(2)]],
                                    device const float* accin [[buffer(3)]],
                                    device const float* wt [[buffer(4)]],
                                    device const uint* meta [[buffer(5)]],
                                    device float* out [[buffer(6)]],
                                    uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint t = thread_position_in_grid.x;
    uint H = meta[0], W = meta[1], accumulate = meta[2];
    if (t >= W * 3u) return;
    uint c = t % 3u, x = t / 3u;
    df B  = df{coef[8u * c + 0u], coef[8u * c + 1u]};
    df B1 = df{coef[8u * c + 2u], coef[8u * c + 3u]};
    df B2 = df{coef[8u * c + 4u], coef[8u * c + 5u]};
    df B3 = df{coef[8u * c + 6u], coef[8u * c + 7u]};
    uint stride = W * 3u;
    uint base = x * 3u + c;
    if (act[c] == 0u) {
        for (uint i = 0u; i < H; ++i) {
            uint idx = base + i * stride;
            out[idx] = accumulate != 0u ? accin[idx] + wt[c] * img[idx] : img[idx];
        }
        return;
    }
    float x0 = img[base];
    df w1 = df{x0, 0.0f}, w2 = w1, w3 = w1;
    for (uint i = 0u; i < H; ++i) {
        df v = df_mul_f(B, img[base + i * stride]);
        v = df_add(v, df_mul(B1, w1));
        v = df_add(v, df_mul(B2, w2));
        v = df_add(v, df_mul(B3, w3));
        out[base + i * stride] = v.hi;
        w3 = w2; w2 = w1; w1 = v;
    }
    float xn = out[base + (H - 1u) * stride];
    df y1 = df{xn, 0.0f}, y2 = y1, y3 = y1;
    for (int i = (int)H - 1; i >= 0; --i) {
        uint idx = base + (uint)i * stride;
        df v = df_mul_f(B, out[idx]);
        v = df_add(v, df_mul(B1, y1));
        v = df_add(v, df_mul(B2, y2));
        v = df_add(v, df_mul(B3, y3));
        out[idx] = accumulate != 0u ? accin[idx] + wt[c] * v.hi : v.hi;
        y3 = y2; y2 = y1; y1 = v;
    }
}

// ``a * x + b * y`` with per-channel scalars, in one pass. Also carries the
// unsharp mask (a = 1 + amount, b = -amount) and the halation mixes.
kernel void spk_lincomb3(device const float* x [[buffer(0)]],
                         device const float* y [[buffer(1)]],
                         device const float* a [[buffer(2)]],
                         device const float* b [[buffer(3)]],
                         device const uint* n [[buffer(4)]],
                         device float* out [[buffer(5)]],
                         uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= n[0]) return;
    uint c = i % 3u;
    out[i] = a[c] * x[i] + b[c] * y[i];
}
