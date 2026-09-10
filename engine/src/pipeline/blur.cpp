#include "blur.hpp"

#include <cmath>
#include <cstring>

namespace spk {

namespace {

// The reference splits every IIR coefficient into a (hi, lo) float pair on the
// host, so the kernel's double-float recurrence starts from the float64 value.
std::pair<float, float> split(double v) {
    const float hi = float(v);
    return {hi, float(v - double(hi))};
}

void broadcast3(const double* src, double dst[3], double fallback) {
    if (!src) { dst[0] = dst[1] = dst[2] = fallback; return; }
    dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
}

}  // namespace

bool Blur::alloc_like(const Image& img, Image& out, std::string& error) {
    out.h = img.h; out.w = img.w; out.c = img.c;
    out.buf = gpu_->alloc(img.bytes(), error);
    return out.buf != nullptr;
}

bool Blur::fir(const Image& img, const double sigmas[3], double truncate, const bool active[3],
               Image& out, std::string& error, const Image* acc, const double* weight) {
    // (3, 2R+1) weights, a delta for every inactive channel, so one kernel
    // handles a mix of blurred and pass-through channels in one pass.
    Vec kernels[3];
    size_t radii[3] = {0, 0, 0};
    for (int c = 0; c < 3; ++c) {
        if (active[c] && sigmas[c] > 0.0) radii[c] = gaussian_kernel_1d(sigmas[c], truncate, kernels[c]);
        else { kernels[c].assign(1, 1.0); radii[c] = 0; }
    }
    const size_t R = std::max(radii[0], std::max(radii[1], radii[2]));
    if (R == 0 && active[0] && active[1] && active[2] && !acc) { out = img; return true; }

    std::vector<float> table(3 * (2 * R + 1), 0.0f);
    for (int c = 0; c < 3; ++c) {
        const size_t r = radii[c];
        for (size_t i = 0; i < kernels[c].size(); ++i)
            table[size_t(c) * (2 * R + 1) + (R - r + i)] = float(kernels[c][i]);
    }
    gpu::Buffer* w = gpu_->upload(table.data(), table.size() * sizeof(float), error);
    if (!w) return false;

    double wt[3];
    broadcast3(weight, wt, 1.0);
    const float wtf[3] = {float(wt[0]), float(wt[1]), float(wt[2])};
    gpu::Buffer* wt_buf = gpu_->upload(wtf, sizeof wtf, error);
    if (!wt_buf) return false;

    // The reference runs vertical then horizontal, and the fused multiply-add
    // rides on the second pass.
    Image tmp;
    if (!alloc_like(img, tmp, error)) return false;
    if (!alloc_like(img, out, error)) return false;
    gpu::Buffer* dummy = acc ? acc->buf : img.buf;
    const uint32_t meta_v[6] = {img.h, img.w, uint32_t(R), 0, 0, 0};
    const uint32_t meta_h[6] = {img.h, img.w, uint32_t(R), 1, acc ? 1u : 0u, 0};
    const size_t n = img.pixels();
    if (!gpu_->dispatch("spk_sep_fir_acc",
                        {gpu::Arg::buf(img.buf), gpu::Arg::buf(w), gpu::Arg::buf(dummy),
                         gpu::Arg::buf(wt_buf), gpu::Arg::inline_bytes(meta_v, 6), gpu::Arg::buf(tmp.buf)},
                        n, error)) return false;
    return gpu_->dispatch("spk_sep_fir_acc",
                          {gpu::Arg::buf(tmp.buf), gpu::Arg::buf(w), gpu::Arg::buf(dummy),
                           gpu::Arg::buf(wt_buf), gpu::Arg::inline_bytes(meta_h, 6), gpu::Arg::buf(out.buf)},
                          n, error);
}

bool Blur::iir(const Image& img, const double sigmas[3], const bool active[3],
               Image& out, std::string& error, const Image* acc, const double* weight) {
    float coef[24] = {};
    uint32_t act[3] = {0, 0, 0};
    bool any = false;
    for (int c = 0; c < 3; ++c) {
        if (!(active[c] && sigmas[c] > 0.0)) continue;
        double b[4];
        yvv_coeffs(sigmas[c], b);
        for (int j = 0; j < 4; ++j) {
            const auto hl = split(b[j]);
            coef[8 * c + 2 * j] = hl.first;
            coef[8 * c + 2 * j + 1] = hl.second;
        }
        act[c] = 1;
        any = true;
    }
    if (!any && !acc) { out = img; return true; }

    gpu::Buffer* coef_buf = gpu_->upload(coef, sizeof coef, error);
    gpu::Buffer* act_buf = gpu_->upload_u32(act, 3, error);
    if (!coef_buf || !act_buf) return false;
    double wt[3];
    broadcast3(weight, wt, 1.0);
    const float wtf[3] = {float(wt[0]), float(wt[1]), float(wt[2])};
    gpu::Buffer* wt_buf = gpu_->upload(wtf, sizeof wtf, error);
    gpu::Buffer* one = nullptr;
    {
        const float ones[3] = {1.0f, 1.0f, 1.0f};
        one = gpu_->upload(ones, sizeof ones, error);
    }
    if (!wt_buf || !one) return false;

    // The horizontal pass is the vertical kernel applied to a transposed copy,
    // so every recurrence thread marches down contiguous memory.
    Image t{nullptr, img.w, img.h, 3};
    t.buf = gpu_->alloc(img.bytes(), error);
    Image t2{nullptr, img.w, img.h, 3};
    t2.buf = gpu_->alloc(img.bytes(), error);
    Image back;
    if (!t.buf || !t2.buf || !alloc_like(img, back, error)) return false;
    if (!alloc_like(img, out, error)) return false;

    const uint32_t tmeta[2] = {img.h, img.w};
    const uint32_t bmeta[2] = {img.w, img.h};
    const uint32_t pass_plain[3] = {t.h, t.w, 0};
    const uint32_t pass_final[3] = {img.h, img.w, acc ? 1u : 0u};
    gpu::Buffer* dummy = acc ? acc->buf : img.buf;

    if (!gpu_->dispatch("spk_transpose3",
                        {gpu::Arg::buf(img.buf), gpu::Arg::inline_bytes(tmeta, 2), gpu::Arg::buf(t.buf)},
                        img.pixels(), error)) return false;
    if (!gpu_->dispatch("spk_iir_vertical_df_acc",
                        {gpu::Arg::buf(t.buf), gpu::Arg::buf(coef_buf), gpu::Arg::buf(act_buf),
                         gpu::Arg::buf(t.buf), gpu::Arg::buf(one), gpu::Arg::inline_bytes(pass_plain, 3),
                         gpu::Arg::buf(t2.buf)},
                        size_t(t.w) * 3, error)) return false;
    if (!gpu_->dispatch("spk_transpose3",
                        {gpu::Arg::buf(t2.buf), gpu::Arg::inline_bytes(bmeta, 2), gpu::Arg::buf(back.buf)},
                        t2.pixels(), error)) return false;
    return gpu_->dispatch("spk_iir_vertical_df_acc",
                          {gpu::Arg::buf(back.buf), gpu::Arg::buf(coef_buf), gpu::Arg::buf(act_buf),
                           gpu::Arg::buf(dummy), gpu::Arg::buf(wt_buf),
                           gpu::Arg::inline_bytes(pass_final, 3), gpu::Arg::buf(out.buf)},
                          size_t(img.w) * 3, error);
}

bool Blur::gaussian(const Image& img, const double sigma[3], Image& out, std::string& error,
                    double truncate, const Image* acc, const double* weight) {
    bool use_fir[3], use_iir[3];
    bool any_fir = false, any_iir = false;
    for (int c = 0; c < 3; ++c) {
        use_fir[c] = sigma[c] > 0.0 && sigma[c] < kSmallSigmaMax;
        use_iir[c] = sigma[c] >= kSmallSigmaMax;
        any_fir |= use_fir[c];
        any_iir |= use_iir[c];
    }
    if (!acc) {
        Image cur = img;
        if (any_fir) {
            Image next;
            if (!fir(cur, sigma, truncate, use_fir, next, error, nullptr, nullptr)) return false;
            cur = next;
        }
        if (any_iir) {
            Image next;
            if (!iir(cur, sigma, use_iir, next, error, nullptr, nullptr)) return false;
            cur = next;
        }
        out = cur;
        return true;
    }
    if (!any_iir) return fir(img, sigma, truncate, use_fir, out, error, acc, weight);
    if (!any_fir) return iir(img, sigma, use_iir, out, error, acc, weight);
    // Mixed FIR / IIR channels: blur fully, then one fused multiply-add.
    Image blurred;
    if (!gaussian(img, sigma, blurred, error, truncate)) return false;
    const double a[3] = {1.0, 1.0, 1.0};
    double b[3];
    broadcast3(weight, b, 1.0);
    return lincomb(*acc, blurred, a, b, out, error);
}

void Blur::exponential_components(const double decay[3], const double weight[3],
                                  std::vector<Component>& out, int n_gaussians) {
    std::vector<std::pair<double, double>> fit;
    exponential_gaussian_fit(n_gaussians, fit);
    out.clear();
    for (const auto& [amplitude, sigma_ratio] : fit) {
        Component comp{};
        for (int c = 0; c < 3; ++c) {
            comp.weight[c] = weight[c] * amplitude;
            comp.sigma[c] = sigma_ratio * decay[c];
        }
        out.push_back(comp);
    }
}

bool Blur::mixture(const Image& img, const std::vector<Component>& components, Image& out,
                   std::string& error, double truncate) {
    bool have_acc = false;
    Image acc;
    for (const Component& comp : components) {
        const bool identity = comp.sigma[0] <= 0.0 && comp.sigma[1] <= 0.0 && comp.sigma[2] <= 0.0;
        if (!have_acc) {
            if (identity) {
                // `G(0)` is the input; the reference still forms
                // `0 * img + weight * img` so the accumulator exists.
                const double a[3] = {0.0, 0.0, 0.0};
                if (!lincomb(img, img, a, comp.weight, acc, error)) return false;
            } else {
                Image zero;
                zero.h = img.h; zero.w = img.w; zero.c = img.c;
                zero.buf = gpu_->alloc_zeroed(img.bytes(), error);
                if (!zero.buf) return false;
                if (!gaussian(img, comp.sigma, acc, error, truncate, &zero, comp.weight)) return false;
            }
            have_acc = true;
        } else {
            Image next;
            if (!gaussian(img, comp.sigma, next, error, truncate, &acc, comp.weight)) return false;
            acc = next;
        }
    }
    if (!have_acc) { error = "blur mixture with no components"; return false; }
    out = acc;
    return true;
}

bool Blur::lincomb(const Image& x, const Image& y, const double a[3], const double b[3],
                   Image& out, std::string& error) {
    const float af[3] = {float(a[0]), float(a[1]), float(a[2])};
    const float bf[3] = {float(b[0]), float(b[1]), float(b[2])};
    gpu::Buffer* ab = gpu_->upload(af, sizeof af, error);
    gpu::Buffer* bb = gpu_->upload(bf, sizeof bf, error);
    if (!ab || !bb) return false;
    if (!alloc_like(x, out, error)) return false;
    const uint32_t n[1] = {uint32_t(x.elements())};
    return gpu_->dispatch("spk_lincomb3",
                          {gpu::Arg::buf(x.buf), gpu::Arg::buf(y.buf), gpu::Arg::buf(ab),
                           gpu::Arg::buf(bb), gpu::Arg::inline_bytes(n, 1), gpu::Arg::buf(out.buf)},
                          x.elements(), error);
}

bool Blur::affine(const Image& x, const double s[3], const double t[3], Image& out, std::string& error) {
    const float sf[3] = {float(s[0]), float(s[1]), float(s[2])};
    const float tf[3] = {float(t[0]), float(t[1]), float(t[2])};
    gpu::Buffer* sb = gpu_->upload(sf, sizeof sf, error);
    gpu::Buffer* tb = gpu_->upload(tf, sizeof tf, error);
    if (!sb || !tb) return false;
    if (!alloc_like(x, out, error)) return false;
    const uint32_t n[1] = {uint32_t(x.elements())};
    return gpu_->dispatch("spk_affine3",
                          {gpu::Arg::buf(x.buf), gpu::Arg::buf(sb), gpu::Arg::buf(tb),
                           gpu::Arg::inline_bytes(n, 1), gpu::Arg::buf(out.buf)},
                          x.elements(), error);
}

}  // namespace spk
