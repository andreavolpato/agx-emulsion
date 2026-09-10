#include "printing.hpp"

#include <cmath>

namespace spk {

namespace {

constexpr double kMidgray = 0.184;

// `utils/conversions.density_to_light`: `10 ** -density * light`, with NaN
// zeroed -- which is where the reference neutralises the unmeasured
// wavelengths on this path.
void density_to_light(const Vec& density, const Vec& light, Vec& out) {
    out.assign(density.size(), 0.0);
    for (size_t i = 0; i < density.size(); ++i) {
        const double t = std::pow(10.0, -density[i]) * light[i];
        out[i] = is_nan(t) ? 0.0 : t;
    }
}

// The Mitchell bicubic tc_lut sample, on the host, for the 1x1 midgray probe.
// The same kernel and the same edge reflection as `spk_lut2d_cubic`.
double mitchell(double t) {
    constexpr double B = 1.0 / 3.0, C = 1.0 / 3.0;
    const double x = std::fabs(t);
    if (x < 1.0)
        return (1.0 / 6.0) * ((12.0 - 9.0 * B - 6.0 * C) * x * x * x +
                              (-18.0 + 12.0 * B + 6.0 * C) * x * x + (6.0 - 2.0 * B));
    if (x < 2.0)
        return (1.0 / 6.0) * ((-B - 6.0 * C) * x * x * x + (6.0 * B + 30.0 * C) * x * x +
                              (-12.0 * B - 48.0 * C) * x + (8.0 * B + 24.0 * C));
    return 0.0;
}

int safe_index(int idx, int L) {
    if (idx < 0) return -idx;
    if (idx >= L) return 2 * (L - 1) - idx;
    return idx;
}

void base_frac(double coord, int L, int& base, double& frac) {
    const double upper = double(L - 1);
    if (coord <= 0.0) coord = 0.0;
    if (coord >= upper) { base = L - 2; frac = 1.0; return; }
    base = int(std::floor(coord));
    frac = coord - double(base);
}

void lut2d_cubic_host(const Vec& lut, size_t L, const double tc[2], double out[3]) {
    const double scale = double(L - 1);
    int xb, yb;
    double xf, yf;
    base_frac(tc[0] * scale, int(L), xb, xf);
    base_frac(tc[1] * scale, int(L), yb, yf);
    const double wx[4] = {mitchell(xf + 1.0), mitchell(xf), mitchell(xf - 1.0), mitchell(xf - 2.0)};
    const double wy[4] = {mitchell(yf + 1.0), mitchell(yf), mitchell(yf - 1.0), mitchell(yf - 2.0)};
    double acc[3] = {0, 0, 0}, wsum = 0.0;
    for (int a = 0; a < 4; ++a) {
        const int xi = safe_index(xb - 1 + a, int(L));
        for (int b = 0; b < 4; ++b) {
            const int yj = safe_index(yb - 1 + b, int(L));
            const double wgt = wx[a] * wy[b];
            wsum += wgt;
            const size_t o = 3 * (size_t(xi) * L + size_t(yj));
            for (int c = 0; c < 3; ++c) acc[c] += wgt * lut[o + size_t(c)];
        }
    }
    for (int c = 0; c < 3; ++c) out[c] = wsum != 0.0 ? acc[c] / wsum : acc[c];
}

}  // namespace

bool print_constants(const Colour& colour, const Blob& blob, const Params& params,
                     const Vec& tc_lut, size_t tc_lut_side,
                     PrintConstants& out, std::string& error) {
    const Profile& film = params.film;
    const Profile& print = params.print;

    // See kMidgrayProbeColourSpace: the probe's grey is an sRGB grey.
    Mat3 tc_b;
    if (!tc_b_matrix(colour, blob, kMidgrayProbeColourSpace, film.info.reference_illuminant,
                     tc_b, error)) return false;

    out.paper_sensitivity.assign(kNumWavelengths * 3, 0.0);
    for (size_t i = 0; i < out.paper_sensitivity.size(); ++i) {
        const double v = std::pow(10.0, print.data.log_sensitivity[i]);
        out.paper_sensitivity[i] = is_nan(v) ? 0.0 : v;
    }

    Vec light;
    if (!standard_illuminant(colour, blob, params.enlarger.illuminant, light, error)) return false;
    Vec dichroics;
    custom_dichroic_filters(colour.wavelengths(), dichroics);
    // The grading head: C fixed at its neutral, M and Y offset by the two wire
    // shifts. There is no C shift, because a subtractive dichroic head grades
    // on two axes.
    const double cc[3] = {params.enlarger.c_filter_neutral,
                          params.enlarger.m_filter_neutral + params.enlarger.m_filter_shift,
                          params.enlarger.y_filter_neutral + params.enlarger.y_filter_shift};
    color_enlarger(light, dichroics, cc, out.print_illuminant);

    prepare_spectral_constants(film.data.channel_density, film.data.base_density,
                              out.print_illuminant, out.paper_sensitivity, 1.0, out.spectral);

    // --- the midgray probe ------------------------------------------------
    // One pixel of 0.184 grey through the film model: RGB -> (tc, b) -> the
    // tc_lut -> log -> the film's own density curves -> a spectral density.
    auto density_spectral_for = [&](double grey, Vec& dst) {
        const double rgb[3] = {grey, grey, grey};
        double xyz[3];
        tc_b.apply(rgb, xyz);
        const double b = xyz[0] + xyz[1] + xyz[2];
        const double denom = b > 1e-10 ? b : 1e-10;
        const double xy[2] = {xyz[0] / denom, xyz[1] / denom};
        double tc[2];
        tri2quad(xy, tc);
        double raw[3];
        lut2d_cubic_host(tc_lut, tc_lut_side, tc, raw);
        for (int c = 0; c < 3; ++c) raw[c] *= is_nan(b) ? 0.0 : b;

        // `develop_simple` on the film's *raw* density curves -- not the
        // normalised ones the image path uses. The reference is explicit that
        // the print balance stays anchored to the stock's own curves, and
        // using the normalised ones here shifts every print by the curves'
        // toe offset.
        const size_t k = film.data.n_exposure;
        double density_cmy[3];
        Vec xs(k), ys(k);
        for (int c = 0; c < 3; ++c) {
            for (size_t i = 0; i < k; ++i) {
                xs[i] = film.data.log_exposure[i] / params.film_render.density_curve_gamma;
                ys[i] = film.data.density_curves[3 * i + size_t(c)];
            }
            density_cmy[c] = interp(std::log10(raw[c] + 1e-10), xs.data(), ys.data(), k);
        }
        dst.assign(kNumWavelengths, 0.0);
        for (size_t l = 0; l < kNumWavelengths; ++l) {
            double d = film.data.base_density[l];
            for (int c = 0; c < 3; ++c)
                d += density_cmy[c] * film.data.channel_density[3 * l + size_t(c)];
            dst[l] = d;
        }
    };

    auto exposure_factor = [&](const Vec& density_spectral, double factor[3]) {
        Vec lightm;
        density_to_light(density_spectral, out.print_illuminant, lightm);
        double raw[3] = {0, 0, 0};
        for (size_t l = 0; l < kNumWavelengths; ++l)
            for (int c = 0; c < 3; ++c)
                raw[c] += lightm[l] * out.paper_sensitivity[3 * l + size_t(c)];
        // The *geometric* mean over the channels, so the normalisation moves
        // brightness and leaves the filter pack's colour alone.
        double log_sum = 0.0;
        for (int c = 0; c < 3; ++c) log_sum += std::log(std::fmax(raw[c], 1e-10));
        const double geomean = std::exp(log_sum / 3.0);
        for (int c = 0; c < 3; ++c) factor[c] = 1.0 / geomean;
    };

    density_spectral_for(kMidgray, out.density_spectral_midgray);
    double factor_midgray[3];
    exposure_factor(out.density_spectral_midgray, factor_midgray);

    double factor_comp[3] = {1.0, 1.0, 1.0};
    out.has_comp = params.enlarger.print_exposure_compensation;
    if (out.has_comp) {
        density_spectral_for(kMidgray * std::pow(2.0, params.camera.exposure_compensation_ev),
                             out.density_spectral_midgray_comp);
        exposure_factor(out.density_spectral_midgray_comp, factor_comp);
    }
    for (int c = 0; c < 3; ++c) {
        if (params.enlarger.print_exposure_compensation && !params.enlarger.normalize_print_exposure)
            out.gain[c] = factor_comp[c] / factor_midgray[c];
        else if (params.enlarger.normalize_print_exposure && params.enlarger.print_exposure_compensation)
            out.gain[c] = factor_comp[c];
        else if (params.enlarger.normalize_print_exposure)
            out.gain[c] = factor_midgray[c];
        else
            out.gain[c] = 1.0;
    }

    // --- the preflash offset ----------------------------------------------
    for (int c = 0; c < 3; ++c) out.offset[c] = 0.0;
    if (params.enlarger.preflash_exposure > 0.0) {
        const double pre_cc[3] = {params.enlarger.c_filter_neutral,
                                  params.enlarger.m_filter_neutral + params.enlarger.preflash_m_filter_shift,
                                  params.enlarger.y_filter_neutral + params.enlarger.preflash_y_filter_shift};
        Vec preflash_illuminant;
        color_enlarger(light, dichroics, pre_cc, preflash_illuminant);
        Vec lightm;
        density_to_light(film.data.base_density, preflash_illuminant, lightm);
        for (size_t l = 0; l < kNumWavelengths; ++l)
            for (int c = 0; c < 3; ++c)
                out.offset[c] += lightm[l] * out.paper_sensitivity[3 * l + size_t(c)];
        for (int c = 0; c < 3; ++c) out.offset[c] *= params.enlarger.preflash_exposure;
    }

    // --- the film's black and white through the enlarger --------------------
    auto film_cmy_to_print_log_raw = [&](const double cmy[3], double dst[3]) {
        double acc[3] = {0, 0, 0};
        for (size_t l = 0; l < kNumWavelengths; ++l) {
            double d = out.spectral.base_density[l];
            for (int c = 0; c < 3; ++c)
                d += cmy[c] * out.spectral.channel_density[3 * l + size_t(c)];
            const double t = std::exp2(-d * 3.321928094887362);
            for (int c = 0; c < 3; ++c) acc[c] += t * out.spectral.illum_x_sens[3 * l + size_t(c)];
        }
        for (int c = 0; c < 3; ++c)
            dst[c] = std::log10(std::fmax(acc[c] * out.gain[c] + out.offset[c], 0.0) + 1e-10);
    };
    const double film_black[3] = {-params.film_render.grain.density_min[0],
                                  -params.film_render.grain.density_min[1],
                                  -params.film_render.grain.density_min[2]};
    double film_white[3];
    for (int c = 0; c < 3; ++c)
        film_white[c] = nanmax(film.data.density_curves.data() + c, film.data.n_exposure, 3);
    film_cmy_to_print_log_raw(film_black, out.log_raw_black);
    film_cmy_to_print_log_raw(film_white, out.log_raw_white);
    return true;
}

double print_exposure_bw_gain(const Params& params, double y_black, double y_white,
                              double black_level, double white_level) {
    if (!(params.scanner.black_correction || params.scanner.white_correction)) return 1.0;
    if (params.io.scan_film || params.print.info.is_positive()) return 1.0;
    double white = white_level, black = black_level;
    if (params.scanner.black_correction && !params.scanner.white_correction) white = y_white;
    if (params.scanner.white_correction && !params.scanner.black_correction) black = y_black;
    const double m = (white - black) / (y_white - y_black + 1e-10);
    const double q = black - m * y_black;
    const double midgray_corrected = (kMidgray - q) / m;

    const double density_midgray = -std::log10(kMidgray);
    const double density_corrected = -std::log10(midgray_corrected);
    const size_t k = params.print.data.n_exposure;
    Vec curve_av(k);
    for (size_t i = 0; i < k; ++i)
        curve_av[i] = nanmean(params.print.data.density_curves.data() + 3 * i, 3, 1);
    const double dmin_av = nanmean(params.print.data.base_density.data(),
                                   params.print.data.base_density.size(), 1);
    const double le_corrected = interp(density_corrected - dmin_av, curve_av.data(),
                                       params.print.data.log_exposure.data(), k);
    const double le_midgray = interp(density_midgray - dmin_av, curve_av.data(),
                                     params.print.data.log_exposure.data(), k);
    return std::pow(10.0, le_corrected - le_midgray);
}

}  // namespace spk
