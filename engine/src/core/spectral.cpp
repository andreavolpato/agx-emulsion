#include "spectral.hpp"

#include <cmath>
#include <cstdlib>

namespace spk {

namespace {
// `sigmoid_erf(x, center, width) = erf((x - center)/width) * 0.5 + 0.5`. Note
// the width may be *negative* (the IR edge passes `-width`), which flips the
// edge; std::erf is odd, so nothing special is needed -- but it is the reason
// this is not written as a clamped ramp.
double sigmoid_erf(double x, double center, double width) {
    return std::erf((x - center) / width) * 0.5 + 0.5;
}
}  // namespace

bool standard_illuminant(const Colour& colour, const Blob& blob, const std::string& type,
                         Vec& out, std::string& error) {
    const Vec& wl = colour.wavelengths();
    out.assign(wl.size(), 0.0);

    auto blackbody = [&](double temperature) {
        for (size_t i = 0; i < wl.size(); ++i)
            out[i] = Colour::blackbody_spectral_radiance(wl[i] * 1e-9, temperature);
    };
    auto apply_baked_filter = [&](const char* key) -> bool {
        Vec t;
        if (!blob.get(key, t, error)) return false;
        if (t.size() != out.size()) { error = std::string(key) + ": wrong length"; return false; }
        // GenericFilter.apply with value=1.0: `1 - (1 - transmittance) * 1`.
        for (size_t i = 0; i < out.size(); ++i) out[i] *= t[i];
        return true;
    };

    if (type.size() > 2 && type[0] == 'B' && type[1] == 'B') {
        blackbody(std::strtod(type.c_str() + 2, nullptr));
    } else if (type == "T") {
        if (!colour.illuminant_values("Incandescent", out, error)) return false;
    } else if (type == "K75P") {
        if (!colour.illuminant_values("Kinoton 75P", out, error)) return false;
    } else if (type == "TH-KG3") {
        blackbody(3400.0);
        if (!apply_baked_filter("filters/kg3")) return false;
    } else if (type == "TH-KG3-L") {
        blackbody(3400.0);
        if (!apply_baked_filter("filters/kg3")) return false;
        if (!apply_baked_filter("filters/lens_canon")) return false;
    } else {
        if (!colour.illuminant_values(type, out, error)) return false;
    }

    double sum = 0.0;
    for (double v : out) sum += v;
    const double normalization = sum / double(out.size());
    for (double& v : out) v /= normalization;
    return true;
}

void illuminant_to_xy(const Colour& colour, const Vec& illuminant, double out_xy[2]) {
    const Vec& cmfs = colour.cmfs_1931_2deg();
    double xyz[3] = {0, 0, 0};
    for (size_t i = 0; i < illuminant.size(); ++i)
        for (int c = 0; c < 3; ++c) xyz[c] += illuminant[i] * cmfs[3 * i + size_t(c)];
    const double total = xyz[0] + xyz[1] + xyz[2];
    out_xy[0] = xyz[0] / total;
    out_xy[1] = xyz[1] / total;
}

void custom_dichroic_filters(const Vec& wl, Vec& out) {
    // `create_combined_dichroic_filter(edges=[516,500,610,607], transitions=[12,8,8,8])`.
    // Column order is C, M, Y; the M column is piecewise about 550 nm, and the
    // C and M-below-550 edges are *negated* erfs (falling edges).
    static const double edges[4] = {516.0, 500.0, 610.0, 607.0};
    static const double trans[4] = {12.0, 8.0, 8.0, 8.0};
    out.assign(wl.size() * 3, 0.0);
    for (size_t i = 0; i < wl.size(); ++i) {
        const double w = wl[i];
        const double y = std::erf((w - edges[0]) / trans[0]);
        const double m = w <= 550.0 ? -std::erf((w - edges[1]) / trans[1])
                                    :  std::erf((w - edges[2]) / trans[2]);
        const double c = -std::erf((w - edges[3]) / trans[3]);
        out[3 * i + 0] = c / 2.0 + 0.5;
        out[3 * i + 1] = m / 2.0 + 0.5;
        out[3 * i + 2] = y / 2.0 + 0.5;
    }
}

void color_enlarger(const Vec& light, const Vec& dichroics, const double cc[3], Vec& out) {
    double transmittance[3];
    for (int k = 0; k < 3; ++k) transmittance[k] = std::pow(10.0, -(cc[k] / 100.0));
    out.assign(light.size(), 0.0);
    for (size_t i = 0; i < light.size(); ++i) {
        double total = 1.0;
        for (int k = 0; k < 3; ++k) {
            // DichroicFilters.apply: dim each filter toward transparent.
            const double dimmed = 1.0 - (1.0 - dichroics[3 * i + size_t(k)]) * (1.0 - transmittance[k]);
            total *= dimmed;
        }
        out[i] = light[i] * total;
    }
}

void band_pass_filter(const Vec& wl, const double uv[3], const double ir[3], Vec& out) {
    const double amp_uv = uv[0] < 0.0 ? 0.0 : (uv[0] > 1.0 ? 1.0 : uv[0]);
    const double amp_ir = ir[0] < 0.0 ? 0.0 : (ir[0] > 1.0 ? 1.0 : ir[0]);
    out.assign(wl.size(), 1.0);
    for (size_t i = 0; i < wl.size(); ++i) {
        const double f_uv = 1.0 - amp_uv + amp_uv * sigmoid_erf(wl[i], uv[1], uv[2]);
        const double f_ir = 1.0 - amp_ir + amp_ir * sigmoid_erf(wl[i], ir[1], -ir[2]);
        out[i] = f_uv * f_ir;
    }
}

void prepare_spectral_constants(const Vec& channel_density, const Vec& base_density,
                                const Vec& illuminant, const Vec& sensitivity,
                                double normalization, SpectralConstants& out) {
    const size_t n = base_density.size();
    out.channel_density = channel_density;
    out.base_density = base_density;
    out.illum_x_sens.assign(n * 3, 0.0);
    for (size_t l = 0; l < n; ++l)
        for (int c = 0; c < 3; ++c)
            out.illum_x_sens[3 * l + size_t(c)] = illuminant[l] * sensitivity[3 * l + size_t(c)] / normalization;

    for (size_t l = 0; l < n; ++l) {
        bool invalid = is_nan(base_density[l]);
        for (int c = 0; c < 3 && !invalid; ++c)
            invalid = is_nan(out.channel_density[3 * l + size_t(c)]) ||
                      is_nan(out.illum_x_sens[3 * l + size_t(c)]);
        if (!invalid) continue;
        out.base_density[l] = 0.0;
        for (int c = 0; c < 3; ++c) {
            out.channel_density[3 * l + size_t(c)] = 0.0;
            out.illum_x_sens[3 * l + size_t(c)] = 0.0;
        }
    }
}

}  // namespace spk
