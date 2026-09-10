// gamut.metal -- CAM16-UCS output gamut compression, verbatim from
// `src/spektrafilm/backends/metal/cam16.py`.
//
// A line-for-line port of `utils/fused_gamut_cam16._fused`. All setup -- the
// RGB<->XYZ matrices with adaptation, the viewing-condition constants, the
// C_max(J', h') table -- comes from `core/cam16.cpp`; only the per-pixel
// arithmetic runs here, in float32.
//
// Three of the reference's traps are reproduced deliberately:
//   * the sign-preserving power for J (a negative achromatic response gives a
//     negative J, and pipeline output legitimately reaches -0.20);
//   * the 460/1403 family of normalisation factors in the inverse (a, b)
//     solve, whose omission cost dE2000 max 33;
//   * numba's `%` on a negative hue index follows Python (non-negative) and
//     MSL's follows C, so the wrap is spelled out.
//
// One number here is knowingly not the same as its host-side counterpart. The
// inverse cone matrix below is the *published* eight-digit CAM16 inverse;
// `core/cam16.cpp` derives `inv(MATRIX_16)` numerically, as colour-science
// does, and the two differ by ~1e-9 relative. That is two orders of magnitude
// below float32 storage epsilon, so it cannot move a pixel -- and this body
// is the one RFC-011 measured, so it is transferred rather than improved. The
// host needs the derived one because the C_max bisection is in float64 and
// 1e-9 there flips gamut decisions; see that file.
#include "spk_common.h"

kernel void spk_cam16ucs_compress(device const float* rgb [[buffer(0)]],
                                  device const float* m2x [[buffer(1)]],
                                  device const float* m2r [[buffer(2)]],
                                  device const float* cmax [[buffer(3)]],
                                  device const float* k [[buffer(4)]],
                                  device const uint* meta [[buffer(5)]],
                                  device float* out [[buffer(6)]],
                                  uint3 thread_position_in_grid [[thread_position_in_grid]]) {
    uint i = thread_position_in_grid.x;
    if (i >= meta[0]) return;
    const uint nL = meta[1], nh = meta[2], lc_active = meta[3];
    // scalar constants
    const float F_L = k[0], N_bb = k[1], N_cb = k[2], n_ = k[3], z = k[4], A_w = k[5], c_ = k[6], N_c = k[7];
    const float L_grid0 = k[8], L_grid1 = k[9], h_grid0 = k[10], h_step = k[11];
    const float threshold = k[12], limit = k[13], power_ = k[14];
    const float lc_threshold = k[15], lc_limit = k[16], lc_power = k[17], L_white = k[18];
    const float D0 = k[19], D1 = k[20], D2 = k[21];
    const float e_c = pow(1.64f - pow(0.29f, n_), 0.73f);
    const float inv_FL4 = pow(F_L, 0.25f);

    float r = rgb[3u * i], g = rgb[3u * i + 1u], b_ = rgb[3u * i + 2u];
    float X = m2x[0] * r + m2x[1] * g + m2x[2] * b_;
    float Y = m2x[3] * r + m2x[4] * g + m2x[5] * b_;
    float Z = m2x[6] * r + m2x[7] * g + m2x[8] * b_;
    X *= 100.0f; Y *= 100.0f; Z *= 100.0f;

    float R = 0.401288f * X + 0.650173f * Y - 0.051461f * Z;
    float G = -0.250268f * X + 1.204414f * Y + 0.045854f * Z;
    float B = -0.002079f * X + 0.048952f * Y + 0.953127f * Z;

    float Rc = D0 * R, Gc = D1 * G, Bc = D2 * B;
    float sR = Rc >= 0.0f ? 1.0f : -1.0f, sG = Gc >= 0.0f ? 1.0f : -1.0f, sB = Bc >= 0.0f ? 1.0f : -1.0f;
    float fR = pow(F_L * fabs(Rc) / 100.0f, 0.42f);
    float fG = pow(F_L * fabs(Gc) / 100.0f, 0.42f);
    float fB = pow(F_L * fabs(Bc) / 100.0f, 0.42f);
    float Ra = 400.0f * sR * fR / (27.13f + fR) + 0.1f;
    float Ga = 400.0f * sG * fG / (27.13f + fG) + 0.1f;
    float Ba = 400.0f * sB * fB / (27.13f + fB) + 0.1f;

    float a = Ra - 12.0f * Ga / 11.0f + Ba / 11.0f;
    float bb = (Ra + Ga - 2.0f * Ba) / 9.0f;
    float hrad = atan2(bb, a);
    float e_t = 0.25f * (cos(hrad + 2.0f) + 3.8f);

    float A = (2.0f * Ra + Ga + Ba / 20.0f - 0.305f) * N_bb;
    float Aratio = A / A_w;
    float sJ = Aratio >= 0.0f ? 1.0f : -1.0f;
    float J = 100.0f * sJ * pow(fabs(Aratio), c_ * z);

    float den = Ra + Ga + 21.0f * Ba / 20.0f;
    float t = 0.0f;
    if (den != 0.0f) t = (50000.0f / 13.0f * N_c * N_cb * e_t * sqrt(a * a + bb * bb)) / den;
    float sq = sqrt(fabs(J) / 100.0f);
    float C = (t > 0.0f) ? pow(t, 0.9f) * sq * e_c : 0.0f;
    float M = C * inv_FL4;

    float Mp = (1.0f / 0.0228f) * log(1.0f + 0.0228f * M);
    float Jp = 1.7f * J / (1.0f + 0.007f * J);

    if (lc_active != 0u) {
        float Ln = Jp / L_white;
        if (Ln > lc_threshold) {
            float lsc = lc_limit - lc_threshold;
            float lx = (Ln - lc_threshold) / lsc;
            float ly = lx / pow(1.0f + pow(lx, lc_power), 1.0f / lc_power);
            Ln = lc_threshold + lsc * ly;
        }
        Jp = Ln * L_white;
    }

    float Lc = min(max(Jp, L_grid0), L_grid1);
    float Li = (Lc - L_grid0) / (L_grid1 - L_grid0) * (float)(nL - 1u);
    int l0 = (int)floor(Li); l0 = min(max(l0, 0), (int)nL - 2);
    float lf = Li - (float)l0;
    float hi_ = (hrad - h_grid0) / h_step;
    float hfl = floor(hi_);
    int nhi = (int)nh;
    int h0 = ((int)hfl % nhi + nhi) % nhi;     // Python-style modulo
    int h1 = (h0 + 1) % nhi;
    float hf = hi_ - hfl;
    float c00 = cmax[l0 * nhi + h0], c01 = cmax[l0 * nhi + h1];
    float c10 = cmax[(l0 + 1) * nhi + h0], c11 = cmax[(l0 + 1) * nhi + h1];
    float Cmax = (1.0f - lf) * ((1.0f - hf) * c00 + hf * c01) + lf * ((1.0f - hf) * c10 + hf * c11);
    float safe = Cmax > 1e-9f ? Cmax : 1e-9f;

    float d = Mp / safe;
    if (d > threshold) {
        float sc = limit - threshold;
        float xk = (d - threshold) / sc;
        float yk = xk / pow(1.0f + pow(xk, power_), 1.0f / power_);
        d = threshold + sc * yk;
    }
    float Mp_new = d * safe;

    float M_new = (exp(Mp_new * 0.0228f) - 1.0f) / 0.0228f;
    float J_new = Jp / (1.7f - 0.007f * Jp);
    float C_new = M_new / inv_FL4;

    float sJ2 = J_new >= 0.0f ? 1.0f : -1.0f;
    float A2 = A_w * sJ2 * pow(fabs(J_new) / 100.0f, 1.0f / (c_ * z));
    float sq2 = sqrt(fabs(J_new) / 100.0f);
    float t2 = (sq2 > 0.0f && C_new > 0.0f) ? pow(C_new / (sq2 * e_c), 1.0f / 0.9f) : 0.0f;
    float ca = cos(hrad), sa = sin(hrad);
    float p2 = A2 / N_bb + 0.305f;
    const float p3 = 21.0f / 20.0f;
    float a2, b2;
    if (t2 == 0.0f) { a2 = 0.0f; b2 = 0.0f; }
    else {
        float p1 = ((50000.0f / 13.0f) * N_c * N_cb * e_t) / t2;
        if (fabs(sa) >= fabs(ca)) {
            float p4 = p1 / sa;
            b2 = (p2 * (2.0f + p3) * (460.0f / 1403.0f)) /
                 (p4 + (2.0f + p3) * (220.0f / 1403.0f) * (ca / sa) - (27.0f / 1403.0f) + p3 * (6300.0f / 1403.0f));
            a2 = b2 * (ca / sa);
        } else {
            float p5 = p1 / ca;
            a2 = (p2 * (2.0f + p3) * (460.0f / 1403.0f)) /
                 (p5 + (2.0f + p3) * (220.0f / 1403.0f) - ((27.0f / 1403.0f) - p3 * (6300.0f / 1403.0f)) * (sa / ca));
            b2 = a2 * (sa / ca);
        }
    }
    float Ra2 = (460.0f * p2 + 451.0f * a2 + 288.0f * b2) / 1403.0f;
    float Ga2 = (460.0f * p2 - 891.0f * a2 - 261.0f * b2) / 1403.0f;
    float Ba2 = (460.0f * p2 - 220.0f * a2 - 6300.0f * b2) / 1403.0f;

    float vm, sv, base_;
    vm = Ra2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
    base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
    float Rf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D0;
    vm = Ga2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
    base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
    float Gf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D1;
    vm = Ba2 - 0.1f; sv = vm >= 0.0f ? 1.0f : -1.0f;
    base_ = (fabs(vm) < 400.0f) ? (27.13f * fabs(vm)) / (400.0f - fabs(vm)) : 0.0f;
    float Bf = (100.0f / F_L) * sv * pow(base_, 1.0f / 0.42f) / D2;

    float Xn = 1.86206786f * Rf - 1.01125463f * Gf + 0.14918677f * Bf;
    float Yn = 0.38752654f * Rf + 0.62144744f * Gf - 0.00897398f * Bf;
    float Zn = -0.01584150f * Rf - 0.03412294f * Gf + 1.04996444f * Bf;
    Xn /= 100.0f; Yn /= 100.0f; Zn /= 100.0f;

    out[3u * i]      = m2r[0] * Xn + m2r[1] * Yn + m2r[2] * Zn;
    out[3u * i + 1u] = m2r[3] * Xn + m2r[4] * Yn + m2r[5] * Zn;
    out[3u * i + 2u] = m2r[6] * Xn + m2r[7] * Yn + m2r[8] * Zn;
}
