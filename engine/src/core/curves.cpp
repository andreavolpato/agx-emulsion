#include "curves.hpp"

#include <algorithm>
#include <functional>
#include <cmath>

namespace spk {

namespace {
constexpr double kSqrt1_2 = 0.70710678118654752440;
constexpr double kSigmaFloor = 0.05;   // morph_curves.SIGMA_FLOOR

// scipy.stats.norm.cdf is `ndtr`, i.e. `0.5 * erfc(-x / sqrt(2))`.
double norm_cdf(double z) { return 0.5 * std::erfc(-z * kSqrt1_2); }

const double kGumbelLocation = -std::log(std::log(2.0));
const double kGumbelWidth = 0.5 * std::log(2.0) * std::sqrt(2.0 * 3.14159265358979323846);

double gumbel_matched_cdf(double z) {
    return std::exp(-std::exp(-(z / kGumbelWidth + kGumbelLocation)));
}

double layer_cdf(double z, bool positive, double gumbel_mix) {
    const double sz = positive ? -z : z;
    double cdf = norm_cdf(sz);
    if (gumbel_mix > 0.0) cdf = (1.0 - gumbel_mix) * cdf + gumbel_mix * gumbel_matched_cdf(sz);
    return cdf;
}

void evaluate_channel_density(const double* x, size_t nx, const double* centers,
                              const double* amplitudes, const double* sigmas, size_t n_layers,
                              bool positive, const double* gumbel_mix, double* out, size_t stride) {
    for (size_t i = 0; i < nx; ++i) out[i * stride] = 0.0;
    for (size_t l = 0; l < n_layers; ++l) {
        const double mix = gumbel_mix ? gumbel_mix[l] : 0.0;
        for (size_t i = 0; i < nx; ++i) {
            const double z = (x[i] - centers[l]) / sigmas[l];
            out[i * stride] += amplitudes[l] * layer_cdf(z, positive, mix);
        }
    }
}

// Brent's method (Brent 1973), to the reference's `xtol = 1e-10`. Inverse
// quadratic interpolation where it is well behaved, secant where it is not,
// bisection whenever either would step outside the bracket -- which is the
// property that makes it robust and the reason a bare secant loop is not
// substituted for it.
//
// `scipy.optimize.brentq` converges to a root of a continuous function; at
// 1e-10 on this smooth, monotone residual the two implementations agree far
// past the point where the answer depends on which one ran. The path is
// unreachable at the shipped defaults: `developer_exhaustion = 0` returns
// before it.
double brent(double a, double b, double fa, double fb,
             const std::function<double(double)>& f, double xtol) {
    double c = a, fc = fa, d = b - a, e = d;
    for (int iter = 0; iter < 200; ++iter) {
        if (fb * fc > 0.0) { c = a; fc = fa; d = e = b - a; }
        if (std::fabs(fc) < std::fabs(fb)) {
            a = b; b = c; c = a;
            fa = fb; fb = fc; fc = fa;
        }
        const double tol = 2.0 * 2.220446049250313e-16 * std::fabs(b) + 0.5 * xtol;
        const double m = 0.5 * (c - b);
        if (std::fabs(m) <= tol || fb == 0.0) return b;

        if (std::fabs(e) < tol || std::fabs(fa) <= std::fabs(fb)) {
            d = e = m;                       // bisect
        } else {
            const double s = fb / fa;
            double p, q;
            if (a == c) {                     // secant
                p = 2.0 * m * s;
                q = 1.0 - s;
            } else {                          // inverse quadratic
                const double qq = fa / fc, r = fb / fc;
                p = s * (2.0 * m * qq * (qq - r) - (b - a) * (r - 1.0));
                q = (qq - 1.0) * (r - 1.0) * (s - 1.0);
            }
            if (p > 0.0) q = -q; else p = -p;
            if (2.0 * p < std::min(3.0 * m * q - std::fabs(tol * q), std::fabs(e * q))) {
                e = d;
                d = p / q;
            } else {
                d = e = m;                    // the step left the bracket
            }
        }
        a = b;
        fa = fb;
        b += std::fabs(d) > tol ? d : (m > 0.0 ? tol : -tol);
        fb = f(b);
    }
    return b;
}

}  // namespace

void build_interp_tables(const Vec& log_exposure, const double gamma[3],
                         const Vec& curves, InterpTables& out) {
    const size_t k = log_exposure.size();
    out.k = k;
    out.x.assign(k * 3, 0.0);
    out.y = curves;
    for (size_t i = 0; i < k; ++i)
        for (int c = 0; c < 3; ++c) out.x[3 * i + size_t(c)] = log_exposure[i] / gamma[c];
    out.inv.assign((k - 1) * 3, 0.0);
    for (size_t i = 0; i + 1 < k; ++i)
        for (int c = 0; c < 3; ++c) {
            const double dx = out.x[3 * (i + 1) + size_t(c)] - out.x[3 * i + size_t(c)];
            out.inv[3 * i + size_t(c)] = dx != 0.0 ? 1.0 / dx : 0.0;
        }
}

void dir_couplers_matrix(const DirCouplersParams& p, double out[9]) {
    for (int i = 0; i < 9; ++i) out[i] = 0.0;
    for (int i = 0; i < 3; ++i) out[3 * i + i] = p.gamma_samelayer_rgb[i] * p.inhibition_samelayer;
    double inter[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
    inter[0 * 3 + 1] = p.gamma_interlayer_r_to_gb[0];
    inter[0 * 3 + 2] = p.gamma_interlayer_r_to_gb[1];
    inter[1 * 3 + 0] = p.gamma_interlayer_g_to_rb[0];
    inter[1 * 3 + 2] = p.gamma_interlayer_g_to_rb[1];
    inter[2 * 3 + 0] = p.gamma_interlayer_b_to_rg[0];
    inter[2 * 3 + 1] = p.gamma_interlayer_b_to_rg[1];
    for (int i = 0; i < 9; ++i) out[i] += inter[i] * p.inhibition_interlayer;
    for (int i = 0; i < 9; ++i) out[i] *= p.amount;
}

void density_curves_before_dir_couplers(const Vec& curves, const Vec& log_exposure,
                                        const double matrix[9], bool positive, Vec& out) {
    const size_t k = log_exposure.size();
    // Positive film: interimage effects act in the silver development stage,
    // and silver density is taken as d_max - d.
    Vec silver(k * 3, 0.0);
    double dmax[3];
    for (int c = 0; c < 3; ++c) dmax[c] = nanmax(curves.data() + c, k, 3);
    for (size_t i = 0; i < k; ++i)
        for (int c = 0; c < 3; ++c)
            silver[3 * i + size_t(c)] = positive ? dmax[c] - curves[3 * i + size_t(c)]
                                                 : curves[3 * i + size_t(c)];

    // log_exposure_0[:, m] = log_exposure - sum_k silver[:, k] * matrix[k, m]
    Vec le0(k * 3, 0.0);
    for (size_t i = 0; i < k; ++i)
        for (int m = 0; m < 3; ++m) {
            double amount = 0.0;
            for (int kk = 0; kk < 3; ++kk) amount += silver[3 * i + size_t(kk)] * matrix[3 * kk + m];
            le0[3 * i + size_t(m)] = log_exposure[i] - amount;
        }

    out.assign(k * 3, 0.0);
    Vec xs(k), ys(k);
    for (int c = 0; c < 3; ++c) {
        // `np.interp` needs an increasing x. For a positive profile the
        // reference negates both the curve and the result to keep it so, which
        // is not the same as interpolating the un-negated pair.
        for (size_t i = 0; i < k; ++i) {
            xs[i] = le0[3 * i + size_t(c)];
            ys[i] = positive ? -curves[3 * i + size_t(c)] : curves[3 * i + size_t(c)];
        }
        for (size_t i = 0; i < k; ++i) {
            const double v = interp(log_exposure[i], xs.data(), ys.data(), k);
            out[3 * i + size_t(c)] = positive ? -v : v;
        }
    }
}

bool print_curves_morph(const Vec& log_exposure, const DensityCurvesModel& model,
                        const PrintCurvesMorphParams& morph, bool positive,
                        Vec& out, std::string& error) {
    const size_t nx = log_exposure.size();
    const size_t nc = model.n_channels, nl = model.n_layers;
    if (nc == 0 || nl == 0) { error = "the print profile carries no fitted density_curves_model"; return false; }
    out.assign(nx * nc, 0.0);

    if (!morph.active) {
        for (size_t c = 0; c < nc; ++c)
            evaluate_channel_density(log_exposure.data(), nx, &model.centers[c * nl],
                                     &model.amplitudes[c * nl], &model.sigmas[c * nl], nl,
                                     positive, nullptr, out.data() + c, nc);
        return true;
    }

    const double gammas[6] = {morph.gamma_factor, morph.gamma_factor_fast, morph.gamma_factor_slow,
                              morph.gamma_factor_red, morph.gamma_factor_green, morph.gamma_factor_blue};
    for (double g : gammas)
        if (!(g > 0.0)) { error = "every print-curve gamma factor must be strictly positive"; return false; }
    if (!(morph.developer_exhaustion >= 0.0 && morph.developer_exhaustion <= 1.0)) {
        error = "developer_exhaustion must be in [0, 1]";
        return false;
    }

    for (size_t c = 0; c < nc; ++c) {
        std::vector<double> centers(&model.centers[c * nl], &model.centers[c * nl] + nl);
        std::vector<double> amplitudes(&model.amplitudes[c * nl], &model.amplitudes[c * nl] + nl);
        std::vector<double> sigmas(&model.sigmas[c * nl], &model.sigmas[c * nl] + nl);

        // Layers are mapped by grain *speed* -- the sensitivity threshold,
        // i.e. ascending centre -- not by position on the D-logE curve.
        std::vector<size_t> order(nl);
        for (size_t i = 0; i < nl; ++i) order[i] = i;
        std::sort(order.begin(), order.end(),
                  [&](size_t a, size_t b) { return centers[a] < centers[b]; });
        const size_t i_fast = order.front(), i_mid = order[nl / 2], i_slow = order.back();

        const double channel_gamma = c == 0 ? morph.gamma_factor_red
                                   : c == 1 ? morph.gamma_factor_green
                                            : morph.gamma_factor_blue;
        const double g_fast = morph.gamma_factor * channel_gamma * morph.gamma_factor_fast;
        const double g_mid = morph.gamma_factor * channel_gamma * morph.gamma_factor_slow;
        const double g_slow = g_mid;

        auto scale = [&](size_t idx, double g) {
            sigmas[idx] = std::max(sigmas[idx] / g, kSigmaFloor);
            centers[idx] = centers[idx] / g;
        };
        scale(i_fast, g_fast);
        scale(i_mid, g_mid);
        scale(i_slow, g_slow);

        std::vector<double> mix(nl, morph.developer_exhaustion);
        double offset = 0.0;
        if (morph.developer_exhaustion != 0.0) {
            // A common horizontal offset per channel, so developer exhaustion
            // does not move midgray: solve for the shift that restores D(0).
            const double zero = 0.0;
            double target = 0.0;
            std::vector<double> none(nl, 0.0);
            evaluate_channel_density(&zero, 1, centers.data(), amplitudes.data(), sigmas.data(),
                                     nl, positive, none.data(), &target, 1);
            auto residual = [&](double shift) {
                std::vector<double> shifted(nl);
                for (size_t i = 0; i < nl; ++i) shifted[i] = centers[i] + shift;
                double d0 = 0.0;
                evaluate_channel_density(&zero, 1, shifted.data(), amplitudes.data(), sigmas.data(),
                                         nl, positive, mix.data(), &d0, 1);
                return d0 - target;
            };
            const double r0 = residual(0.0);
            if (std::fabs(r0) > 1e-12) {
                double lo = -0.25, hi = 0.25;
                for (int i = 0; i < 12; ++i) {
                    const double r_lo = residual(lo), r_hi = residual(hi);
                    if (r_lo == 0.0) { offset = lo; break; }
                    if (r_hi == 0.0) { offset = hi; break; }
                    if (r_lo * r_hi < 0.0) { offset = brent(lo, hi, r_lo, r_hi, residual, 1e-10); break; }
                    lo *= 2.0;
                    hi *= 2.0;
                }
            }
        }
        for (size_t i = 0; i < nl; ++i) centers[i] += offset;

        evaluate_channel_density(log_exposure.data(), nx, centers.data(), amplitudes.data(),
                                 sigmas.data(), nl, positive, mix.data(), out.data() + c, nc);
    }
    return true;
}

}  // namespace spk
