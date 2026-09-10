#include "hanatos.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

#include "cam16.hpp"      // reinhard_knee
#include "spectral.hpp"   // standard_illuminant, illuminant_to_xy, band_pass_filter

namespace spk {

namespace {

constexpr double kSqrt2 = 1.41421356237309504880;
constexpr double kSqrt2Pi = 2.50662827463100050242;
// `_HANATOS2025_MAX_CORRECTION_STOPS`, the bound the surface fit was made with.
constexpr double kMaxCorrectionStops = 2.0;

double clip01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

// Jakob & Hanika 2019's algebraic sigmoid, bounded to +/- max_val.
double hanika_sigmoid(double z, double max_val) {
    return z / std::sqrt(1.0 + (z / max_val) * (z / max_val));
}

// `poly2d_deg4`: degree-4 in (x, y) with no constant term, so the centre is
// exactly zero correction.
double poly2d_deg4(double x, double y, const double* p) {
    const double x2 = x * x, y2 = y * y, xy = x * y, x3 = x2 * x, y3 = y2 * y;
    return p[1] * x + p[2] * y + p[3] * x2 + p[4] * y2 + p[5] * xy +
           p[6] * x3 + p[7] * y3 + p[8] * (x2 * y) + p[9] * (x * y2) +
           p[10] * (x2 * x2) + p[11] * (y2 * y2) + p[12] * (x3 * y) +
           p[13] * (x2 * y2) + p[14] * (x * y3);
}

// `locked_logistic_rising`: locked through (mu, 1/2) with maximum slope
// 1/(sigma*sqrt(2*pi)); nu bends the tails.
double locked_logistic_rising(double x, double mu, double sigma, double nu) {
    nu = std::max(nu, 1e-5);
    const double S = 1.0 / (sigma * kSqrt2Pi);
    const double k = (2.0 * nu * S) / (1.0 - std::pow(2.0, -nu));
    double exponent = -k * (x - mu);
    exponent = std::max(-500.0, std::min(500.0, exponent));
    const double nu_log2 = nu * std::log(2.0);
    const double log_q = nu_log2 > 50.0 ? nu_log2 + std::log1p(-std::exp(-nu_log2))
                                        : std::log(std::expm1(nu_log2));
    // np.logaddexp(0, log_q + exponent)
    const double t = log_q + exponent;
    const double log_denom = t > 0.0 ? t + std::log1p(std::exp(-t)) : std::log1p(std::exp(t));
    return std::exp(-(1.0 / nu) * log_denom);
}

// `eval_spectral_bandpass_window`, both models. (81, 3) row-major.
void spectral_bandpass_window(const Vec& wl, const Vec& params, Vec& out) {
    const size_t n = wl.size();
    out.assign(n * 3, 1.0);
    if (params.size() == 4) {
        const double c_uv = params[0], s_uv = params[1], c_ir = params[2], s_ir = params[3];
        for (size_t i = 0; i < n; ++i) {
            const double edge_uv = 0.5 * (1.0 + std::erf((wl[i] - c_uv) / (s_uv * kSqrt2)));
            const double edge_ir = 0.5 * (1.0 - std::erf((wl[i] - c_ir) / (s_ir * kSqrt2)));
            const double common = edge_uv * edge_ir;
            for (int c = 0; c < 3; ++c) out[3 * i + size_t(c)] = common;
        }
    } else if (params.size() == 8) {
        const double c_uv_base = params[0], sigma_uv = params[1];
        const double c_ir_base = params[2], sigma_ir = params[3];
        const double c_uv_b = params[4], c_ir_r = params[5];
        const double nu_uv = params[6], nu_ir = params[7];
        const double cuv[3] = {c_uv_base, c_uv_base, c_uv_b};
        const double cir[3] = {c_ir_r, c_ir_base, c_ir_base};
        for (size_t i = 0; i < n; ++i)
            for (int c = 0; c < 3; ++c) {
                const double e_uv = locked_logistic_rising(wl[i], cuv[c], sigma_uv, nu_uv);
                const double e_ir = 1.0 - locked_logistic_rising(wl[i], cir[c], sigma_ir, nu_ir);
                out[3 * i + size_t(c)] = e_uv * e_ir;
            }
    }
}

// `_ray_polygon_distance`: distance from `origin` along unit `direction` to
// the first intersection with the closed polygon.
double ray_polygon_distance(const double origin[2], const double dir[2], const Vec& polygon) {
    const size_t n_edges = polygon.size() / 2 - 1;
    double t_min = std::numeric_limits<double>::infinity();
    for (size_t k = 0; k < n_edges; ++k) {
        const double ax = polygon[2 * k], ay = polygon[2 * k + 1];
        const double ex = polygon[2 * (k + 1)] - ax, ey = polygon[2 * (k + 1) + 1] - ay;
        const double denom = dir[0] * ey - dir[1] * ex;
        if (std::fabs(denom) <= 1e-12) continue;
        const double ox = origin[0] - ax, oy = origin[1] - ay;
        const double t = (-ox * ey + oy * ex) / denom;
        const double s = (-ox * dir[1] + oy * dir[0]) / denom;
        if (t > 1e-9 && s >= 0.0 && s <= 1.0 && t < t_min) t_min = t;
    }
    return t_min;
}

// scipy.ndimage.map_coordinates(order=1, mode='nearest'): bilinear, with
// out-of-grid coordinates taking the closest edge value rather than wrapping
// or extrapolating past 0/1 in raw RGB.
double bilinear_nearest(const Vec& lut, size_t h, size_t w, size_t channel,
                        double ci, double cj) {
    ci = std::max(0.0, std::min(double(h - 1), ci));
    cj = std::max(0.0, std::min(double(w - 1), cj));
    const size_t i0 = size_t(std::floor(ci)), j0 = size_t(std::floor(cj));
    const size_t i1 = std::min(i0 + 1, h - 1), j1 = std::min(j0 + 1, w - 1);
    const double ti = ci - double(i0), tj = cj - double(j0);
    const double v00 = lut[3 * (i0 * w + j0) + channel], v01 = lut[3 * (i0 * w + j1) + channel];
    const double v10 = lut[3 * (i1 * w + j0) + channel], v11 = lut[3 * (i1 * w + j1) + channel];
    return v00 * (1 - ti) * (1 - tj) + v01 * (1 - ti) * tj + v10 * ti * (1 - tj) + v11 * ti * tj;
}

}  // namespace

void tri2quad(const double tc[2], double out[2]) {
    const double one_minus_x = 1.0 - tc[0];
    out[1] = clip01(tc[1] / std::max(one_minus_x, 1e-10));
    out[0] = clip01(one_minus_x * one_minus_x);
}

void quad2tri(const double xy[2], double out[2]) {
    const double s = std::sqrt(xy[0]);
    out[0] = 1.0 - s;
    out[1] = xy[1] * s;
}

void spectral_locus_xy(const Colour& colour, Vec& out) {
    // 380..700 at 5 nm is the first 65 rows of the baked CMFS; no
    // interpolation, and identical to what colour returned here.
    constexpr size_t n = 65;
    const Vec& cmfs = colour.cmfs_1931_2deg();
    out.assign((n + 1) * 2, 0.0);
    for (size_t i = 0; i < n; ++i) {
        const double X = cmfs[3 * i], Y = cmfs[3 * i + 1], Z = cmfs[3 * i + 2];
        const double total = std::max(X + Y + Z, 1e-12);
        out[2 * i] = X / total;
        out[2 * i + 1] = Y / total;
    }
    out[2 * n] = out[0];
    out[2 * n + 1] = out[1];
}

void compress_xy_radial(const double xy[2], const double white_xy[2], const Vec& locus,
                        double threshold, double limit, double power, double out[2]) {
    const double dx = xy[0] - white_xy[0], dy = xy[1] - white_xy[1];
    const double dist = std::hypot(dx, dy);
    if (dist < 1e-9) { out[0] = xy[0]; out[1] = xy[1]; return; }   // at white: direction undefined
    const double safe = std::max(dist, 1e-12);
    const double dir[2] = {dx / safe, dy / safe};
    const double boundary = ray_polygon_distance(white_xy, dir, locus);
    const double d_norm = dist / std::max(boundary, 1e-12);
    const double d = reinhard_knee(d_norm, threshold, limit, power);
    out[0] = white_xy[0] + dir[0] * (d * boundary);
    out[1] = white_xy[1] + dir[1] * (d * boundary);
}

bool film_sensitivity(const Colour& colour, const Blob& blob, const Profile& film,
                      const CameraParams& camera, Vec& out, std::string& error) {
    const size_t n = kNumWavelengths;
    out.assign(n * 3, 0.0);
    for (size_t i = 0; i < n * 3; ++i) {
        const double v = std::pow(10.0, film.data.log_sensitivity[i]);
        out[i] = is_nan(v) ? 0.0 : v;      // np.nan_to_num
    }
    if (!(camera.filter_uv[0] > 0.0 || camera.filter_ir[0] > 0.0)) return true;

    Vec illuminant;
    if (!standard_illuminant(colour, blob, film.info.reference_illuminant, illuminant, error)) return false;
    Vec bp;
    band_pass_filter(colour.wavelengths(), camera.filter_uv, camera.filter_ir, bp);
    // Renormalise per channel so the cut does not shift the film's white
    // balance: the filter divides out its own effect on the reference white.
    double num[3] = {0, 0, 0}, den[3] = {0, 0, 0};
    for (size_t i = 0; i < n; ++i)
        for (int c = 0; c < 3; ++c) {
            num[c] += out[3 * i + size_t(c)] * bp[i] * illuminant[i];
            den[c] += out[3 * i + size_t(c)] * illuminant[i];
        }
    for (size_t i = 0; i < n; ++i)
        for (int c = 0; c < 3; ++c) out[3 * i + size_t(c)] *= bp[i] / (num[c] / den[c]);
    return true;
}

bool tc_b_matrix(const Colour& colour, const Blob& blob, const std::string& color_space,
                 const std::string& reference_illuminant, Mat3& out, std::string& error) {
    Vec sd;
    if (!standard_illuminant(colour, blob, reference_illuminant, sd, error)) return false;
    double xy[2];
    illuminant_to_xy(colour, sd, xy);
    return colour.matrix_RGB_to_XYZ(color_space, xy, "CAT16", out, error);
}

bool build_tc_lut(const Colour& colour, const Blob& blob, const Profile& film,
                  const SettingsParams& settings, const GamutCompressSpec& compress,
                  const Vec& sensitivity, Vec& out, size_t& side, std::string& error) {
    Vec spectra;
    uint32_t dims[4] = {0, 0, 0, 0};
    uint32_t ndim = 0;
    if (!blob.get("hanatos/spectra_lut", spectra, dims, ndim, error)) return false;
    if (ndim != 3 || dims[0] != dims[1] || dims[2] != kNumWavelengths) {
        error = "hanatos/spectra_lut has the wrong shape";
        return false;
    }
    side = dims[0];
    const size_t n_lambda = kNumWavelengths;

    if (settings.spectral_gaussian_blur > 0.0) {
        // The reference blurs the spectra along the wavelength axis with
        // scipy.ndimage.gaussian_filter, whose default 'reflect' edges and
        // truncate=4.0 are what this reproduces.
        Vec kernel;
        const size_t radius = gaussian_kernel_1d(settings.spectral_gaussian_blur, 4.0, kernel);
        if (radius > 0) {
            Vec blurred(spectra.size(), 0.0);
            const int n = int(n_lambda), r = int(radius);
            for (size_t cell = 0; cell < side * side; ++cell) {
                const double* src = &spectra[cell * n_lambda];
                double* dst = &blurred[cell * n_lambda];
                for (int i = 0; i < n; ++i) {
                    double acc = 0.0;
                    for (int k = -r; k <= r; ++k) {
                        int j = i + k;
                        // scipy 'reflect': (d c b a | a b c d | d c b a)
                        if (j < 0) j = -j - 1;
                        if (j >= n) j = 2 * n - 1 - j;
                        if (j < 0) j = 0;
                        acc += src[j] * kernel[size_t(k + r)];
                    }
                    dst[i] = acc;
                }
            }
            spectra.swap(blurred);
        }
    }

    // sensitivity, optionally through the film's own spectral window, which is
    // normalised per channel so it preserves white balance.
    Vec weights = sensitivity;
    if (settings.apply_hanatos2025_adaptation_window && !film.data.adaptation_window_params.empty()) {
        Vec window;
        spectral_bandpass_window(colour.wavelengths(), film.data.adaptation_window_params, window);
        Vec illuminant;
        if (!standard_illuminant(colour, blob, film.info.reference_illuminant, illuminant, error)) return false;
        double num[3] = {0, 0, 0}, den[3] = {0, 0, 0};
        for (size_t l = 0; l < n_lambda; ++l)
            for (int c = 0; c < 3; ++c) {
                num[c] += sensitivity[3 * l + size_t(c)] * illuminant[l] * window[3 * l + size_t(c)];
                den[c] += sensitivity[3 * l + size_t(c)] * illuminant[l];
            }
        for (size_t l = 0; l < n_lambda; ++l)
            for (int c = 0; c < 3; ++c)
                weights[3 * l + size_t(c)] = sensitivity[3 * l + size_t(c)] *
                                             (window[3 * l + size_t(c)] / (num[c] / den[c]));
    }

    // raw_lut[i, j, m] = sum_l spectra[i, j, l] * weights[l, m]
    out.assign(side * side * 3, 0.0);
    for (size_t cell = 0; cell < side * side; ++cell) {
        const double* sp = &spectra[cell * n_lambda];
        double acc[3] = {0, 0, 0};
        for (size_t l = 0; l < n_lambda; ++l)
            for (int c = 0; c < 3; ++c) acc[c] += sp[l] * weights[3 * l + size_t(c)];
        for (int c = 0; c < 3; ++c) out[3 * cell + size_t(c)] = acc[c];
    }

    if (settings.apply_hanatos2025_adaptation_surface && film.data.adaptation_surface_rows == 3) {
        Vec sd;
        if (!standard_illuminant(colour, blob, film.info.reference_illuminant, sd, error)) return false;
        double illu_xy[2], centre[2];
        illuminant_to_xy(colour, sd, illu_xy);
        tri2quad(illu_xy, centre);
        const size_t stride = film.data.adaptation_surface_cols;
        for (size_t i = 0; i < side; ++i)
            for (size_t j = 0; j < side; ++j) {
                const double tc0 = double(i) / double(side - 1), tc1 = double(j) / double(side - 1);
                for (int c = 0; c < 3; ++c) {
                    const double raw = poly2d_deg4(tc0 - centre[0], tc1 - centre[1],
                                                   &film.data.adaptation_surface_params[size_t(c) * stride]);
                    const double correction = hanika_sigmoid(raw, kMaxCorrectionStops);
                    out[3 * (i * side + j) + size_t(c)] *= std::pow(2.0, correction);
                }
            }
    }

    if (!compress.active) return true;

    // new_lut[xy] = old_lut[compress(xy)], so the per-pixel path stays
    // compression-agnostic. The achromatic axis is the film's own reference
    // white, which is the same illuminant `_rgb_to_tc_b` evaluates against at
    // runtime -- if those two disagree the compression pulls toward the wrong
    // neutral.
    Vec sd;
    if (!standard_illuminant(colour, blob, film.info.reference_illuminant, sd, error)) return false;
    double ref_xy[2];
    illuminant_to_xy(colour, sd, ref_xy);
    Vec locus;
    spectral_locus_xy(colour, locus);

    Vec remapped(out.size(), 0.0);
    for (size_t i = 0; i < side; ++i)
        for (size_t j = 0; j < side; ++j) {
            const double tc[2] = {double(i) / double(side - 1), double(j) / double(side - 1)};
            double xy[2], compressed[2], tc2[2];
            quad2tri(tc, xy);
            compress_xy_radial(xy, ref_xy, locus, compress.knee[0], compress.knee[1], compress.knee[2], compressed);
            tri2quad(compressed, tc2);
            const double ci = tc2[0] * double(side - 1), cj = tc2[1] * double(side - 1);
            for (int c = 0; c < 3; ++c)
                remapped[3 * (i * side + j) + size_t(c)] =
                    bilinear_nearest(out, side, side, size_t(c), ci, cj);
        }
    out.swap(remapped);
    return true;
}

}  // namespace spk
