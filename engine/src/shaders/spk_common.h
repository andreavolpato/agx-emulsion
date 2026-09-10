// spk_common.h -- the MSL fragments shared by several kernels.
//
// Every one of these is transferred **verbatim** from
// `src/spektrafilm/backends/metal/msl.py` and `grain.py`, where they were
// held to float32 storage epsilon against the numba reference (RFC-011).
// RFC-014 §5 step 2 is explicit that they must not be retyped: a
// transcription error in a density curve is a plausible-looking photograph.
//
// What changed on the way across: nothing inside a function body. The only
// difference is that these now live in a header the offline compiler
// `#include`s, instead of being string-concatenated in front of a kernel body
// by `mx.fast.metal_kernel`.
#pragma once
#include <metal_stdlib>
using namespace metal;

// A binary search that reproduces numba's scalar ``np.searchsorted(a, v,
// side='right')`` step for step -- including on the (slightly non-monotonic)
// toe of a measured density curve, where "the right answer" is whatever the
// reference's search returns.
inline uint search_right(const device float* a, uint stride, uint offset, uint n, float v) {
    uint lo = 0u, hi = n;
    while (lo < hi) {
        uint mid = lo + ((hi - lo) >> 1);
        if (a[mid * stride + offset] <= v) lo = mid + 1u; else hi = mid;
    }
    return lo;
}
// fast_interp semantics: endpoint clamp, right-biased exact match, linear in between.
// xa / y are (K, 3) row-major; inv is (K-1, 3).
inline float interp_channel(const device float* xa, const device float* inv, const device float* y,
                            uint K, uint c, float v) {
    float x0 = xa[c];
    float xN = xa[(K - 1u) * 3u + c];
    if (v <= x0) return y[c];
    if (v >= xN) return y[(K - 1u) * 3u + c];
    uint idx = search_right(xa, 3u, c, K, v);
    uint low = idx - 1u;
    float t = (v - xa[low * 3u + c]) * inv[low * 3u + c];
    float y0 = y[low * 3u + c];
    float y1 = y[(low + 1u) * 3u + c];
    return y0 + t * (y1 - y0);
}

// scipy.ndimage 'reflect' (d c b a | a b c d | d c b a).
inline int reflect_index(int i, int n) {
    if (0 <= i && i < n) return i;
    if (-n <= i && i < 0) return -i - 1;
    if (n <= i && i < 2 * n) return 2 * n - 1 - i;
    int period = 2 * n;
    int m = i % period;
    if (m < 0) m += period;
    if (m >= n) m = period - 1 - m;
    return m;
}

// scipy.ndimage 'mirror' (d c b | a b c d | c b a) -- what skimage's
// mode='reflect' (the numpy-pad name) translates to in ndimage.
inline int mirror_index(int i, int n) {
    if (n <= 1) return 0;
    int period = 2 * (n - 1);
    if (i < 0) i = -i;
    if (i >= period) i = i % period;
    if (i >= n) i = period - i;
    return i;
}

// Double-float (hi + lo) arithmetic with fma-based error-free transforms.
// Metal has no float64; this is what stands in for it where float32 is not
// enough (the recursive Gaussian's state, the geometry mapping's pixel
// coordinates on an 8k frame).
//
// It is also the first thing fast math would break: every one of these
// depends on `a + b` and `fma(a, b, -p)` *not* being reassociated. See
// build.sh, and `spk_math_probe`.
struct df { float hi; float lo; };
inline df two_sum(float a, float b) { float s = a + b; float bb = s - a; float e = (a - (s - bb)) + (b - bb); return df{s, e}; }
inline df quick_two_sum(float a, float b) { float s = a + b; float e = b - (s - a); return df{s, e}; }
inline df two_prod(float a, float b) { float p = a * b; float e = fma(a, b, -p); return df{p, e}; }
inline df df_add(df a, df b) {
    df s = two_sum(a.hi, b.hi); df t = two_sum(a.lo, b.lo);
    s.lo += t.hi; s = quick_two_sum(s.hi, s.lo); s.lo += t.lo; return quick_two_sum(s.hi, s.lo);
}
inline df df_mul(df a, df b) {
    df p = two_prod(a.hi, b.hi); p.lo += a.hi * b.lo + a.lo * b.hi; return quick_two_sum(p.hi, p.lo);
}
inline df df_mul_f(df a, float b) {
    df p = two_prod(a.hi, b); p.lo += a.lo * b; return quick_two_sum(p.hi, p.lo);
}
inline df df_from_f(float a) { return df{a, 0.0f}; }
inline df df_sub(df a, df b) { return df_add(a, df{-b.hi, -b.lo}); }

// --- the bicubic 2-D LUT sampler (Mitchell B=C=1/3) ------------------------
inline float mitchell(float t) {
    const float B = 1.0f / 3.0f, C = 1.0f / 3.0f;
    float x = fabs(t);
    if (x < 1.0f) return (1.0f / 6.0f) * ((12.0f - 9.0f * B - 6.0f * C) * x * x * x + (-18.0f + 12.0f * B + 6.0f * C) * x * x + (6.0f - 2.0f * B));
    if (x < 2.0f) return (1.0f / 6.0f) * ((-B - 6.0f * C) * x * x * x + (6.0f * B + 30.0f * C) * x * x + (-12.0f * B - 48.0f * C) * x + (8.0f * B + 24.0f * C));
    return 0.0f;
}
inline int safe_index(int idx, int L) {
    if (idx < 0) return -idx;
    if (idx >= L) return 2 * (L - 1) - idx;
    return idx;
}
inline void base_frac(float coord, int L, thread int &base, thread float &frac) {
    float upper = (float)(L - 1);
    if (coord <= 0.0f) coord = 0.0f;
    if (coord >= upper) { base = L - 2; frac = 1.0f; return; }
    base = (int)floor(coord);
    frac = coord - (float)base;
}

// --- randomness ------------------------------------------------------------
// Philox4x32-10 keyed on (pixel, stream, seed): tile-invariant, reproducible
// for the seeded sampler, fresh per render for the stochastic one. The
// realisation differs from NumPy's PCG stream by construction; the
// distribution at every density is the same (RFC-011 3.4).
inline uint4 philox4x32_10(uint4 ctr, uint2 key) {
    for (int r = 0; r < 10; ++r) {
        uint hi0 = mulhi(0xD2511F53u, ctr.x), lo0 = 0xD2511F53u * ctr.x;
        uint hi1 = mulhi(0xCD9E8D57u, ctr.z), lo1 = 0xCD9E8D57u * ctr.z;
        ctr = uint4(hi1 ^ ctr.y ^ key.x, lo1, hi0 ^ ctr.w ^ key.y, lo0);
        key.x += 0x9E3779B9u; key.y += 0xBB67AE85u;
    }
    return ctr;
}
inline float u01(uint x) { return (float(x >> 8) + 0.5f) * (1.0f / 16777216.0f); }

struct Rng {
    uint4 ctr; uint2 key; uint4 buf; int n;
    Rng(uint pixel, uint stream, uint seed) { ctr = uint4(pixel, stream, 0u, 0u); key = uint2(seed, 0u); n = 0; }
    float next() {
        if (n == 0) { buf = philox4x32_10(ctr, key); ctr.z += 1u; n = 4; }
        uint v = buf.x; buf = buf.yzwx; n -= 1;
        return u01(v);
    }
    float normal() {  // Box-Muller, one deviate
        float u1 = next(), u2 = next();
        return sqrt(-2.0f * log(u1)) * cos(6.283185307179586f * u2);
    }
};

inline float loggam(float x) {
    const float a0 = 8.333333333333333e-02f, a1 = -2.777777777777778e-03f, a2 = 7.936507936507937e-04f,
                a3 = -5.952380952380952e-04f, a4 = 8.417508417508418e-04f;
    float x0 = x; int n = 0;
    if (x == 1.0f || x == 2.0f) return 0.0f;
    if (x <= 7.0f) { n = int(7.0f - x); x0 = x + float(n); }
    float x2 = 1.0f / (x0 * x0);
    float gl0 = a4; gl0 = gl0 * x2 + a3; gl0 = gl0 * x2 + a2; gl0 = gl0 * x2 + a1; gl0 = gl0 * x2 + a0;
    float gl = gl0 / x0 + 0.5f * log(6.283185307179586f) + (x0 - 0.5f) * log(x0) - x0;
    if (x <= 7.0f) for (int k = 1; k <= n; ++k) { gl -= log(x0 - 1.0f); x0 -= 1.0f; }
    return gl;
}

// Exact Poisson(mu): PTRS (Hoermann 1993) for mu >= 10, sequential search
// below. Exact, not Gaussian-approximated, because the third moment is what
// carries film's shadow-versus-highlight grain character (AGENTS.md trap 8).
inline float poisson(thread Rng &rng, float mu) {
    if (mu >= 10.0f) {
        float slam = sqrt(mu), loglam = log(mu);
        float b = 0.931f + 2.53f * slam, a = -0.059f + 0.02483f * b;
        float invalpha = 1.1239f + 1.1328f / (b - 3.4f), vr = 0.9277f - 3.6224f / (b - 2.0f);
        for (int it = 0; it < 64; ++it) {
            float U = rng.next() - 0.5f, V = rng.next();
            float us = 0.5f - fabs(U);
            float k = floor((2.0f * a / us + b) * U + mu + 0.43f);
            if (us >= 0.07f && V <= vr) return k;
            if (k < 0.0f || (us < 0.013f && V > us)) continue;
            if (log(V) + log(invalpha) - log(a / (us * us) + b) <= -mu + k * loglam - loggam(k + 1.0f)) return k;
        }
        return floor(mu);
    }
    float enlam = exp(-mu), X = 0.0f, prod = 1.0f;
    for (int it = 0; it < 512; ++it) {
        prod *= rng.next();
        if (prod > enlam) X += 1.0f; else return X;
    }
    return X;
}

// One sub-layer draw: density d, saturation density dmax, particles n, uniformity u.
inline float layer_draw(thread Rng &rng, float d, float dmax, float n, float u) {
    float p = d / dmax;
    p = clamp(p, 1e-6f, 1.0f - 1e-6f);
    float sat = 1.0f - p * u * (1.0f - 1e-6f);
    float rate = (n / sat) * p;
    float od = dmax / n;
    return poisson(rng, rate) * (od * sat);
}

// scipy.ndimage.zoom(order=1, mode='mirror', grid_mode=True): the sample sits at
// in = (out + 0.5) * (in_len / out_len) - 0.5, mirrored about the end samples
// when it falls in the half-pixel margins. Computed as an exact rational --
// N = (2*out + 1) * in_len - out_len over 2 * out_len -- so the base index is
// an exact integer and only the fraction is rounded (a float32 coordinate on
// an 8k axis would be off by ~5e-4 px).
inline void sample_axis(uint o, uint in_len, uint out_len, thread int &i0, thread int &i1, thread float &t) {
    long num = (long)(2u * o + 1u) * (long)in_len - (long)out_len;   // >= 0 when downscaling
    long den = 2L * (long)out_len;
    long top = den * (long)(in_len - 1u);
    if (num > top) num = 2L * top - num;                             // mirror past the last sample
    if (num < 0) num = -num;                                          // mirror before the first (upscale only)
    long base = num / den;
    t = (float)(num - base * den) / (float)den;
    i0 = (int)base; i1 = min((int)base + 1, (int)in_len - 1);
}
