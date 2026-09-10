// spectral.hpp -- illuminants, enlarger filters, and the spectral integral's
// per-parameter-set constants.
//
// Ports of `model/illuminants.py`, the reachable half of
// `model/color_filters.py`, and `utils/fused_spectral.prepare_spectral_constants`.
//
// One thing here is a port rather than a bake, deliberately: the dichroic set
// the enlarger grades with is `custom_dichroic_filters`, which is four erfs
// over the wavelength axis and not measured data. It is computed, and
// `parity_setup.py` checks it against the baked copy of the Python result --
// which is the only way to know the port is right rather than merely
// plausible.
#pragma once
#include <string>

#include "colour.hpp"
#include "numeric.hpp"

namespace spk {

// `standard_illuminant(type)`: the named SD (or a blackbody for "BB<temp>"),
// optionally through the KG3 heat filter, normalised so its mean over the 81
// wavelengths is 1. Returns the 81 values.
bool standard_illuminant(const Colour& colour, const Blob& blob, const std::string& type,
                         Vec& out, std::string& error);

// `_illuminant_to_xy` -- the chromaticity of an already-normalised SD under
// the 1931 2-degree observer.
void illuminant_to_xy(const Colour& colour, const Vec& illuminant, double out_xy[2]);

// `custom_dichroic_filters.filters`: (81, 3) row-major, C/M/Y.
void custom_dichroic_filters(const Vec& wavelengths, Vec& out);

// `color_enlarger(light, cc)`: CC units are proportional to density, 100 CC =
// 1.0 density. Dims each dichroic toward transparent, multiplies the three,
// and applies the product to the light.
void color_enlarger(const Vec& light, const Vec& dichroics, const double cc[3], Vec& out);

// `compute_band_pass_filter(filter_uv, filter_ir)` -- the camera's UV/IR cut,
// two erf edges. Each triple is (amplitude, wavelength, width).
void band_pass_filter(const Vec& wavelengths, const double uv[3], const double ir[3], Vec& out);

// `prepare_spectral_constants`: `I(lambda) * S(lambda, m) / norm` precombined,
// and the NaN wavelengths neutralised **outside** the loop.
//
// That second part is not an optimisation. Measured profiles carry NaN where
// no data exists (Portra 400 has 22 in `channel_density`); the reference lets
// them propagate to a NaN transmittance and zeroes them in `density_to_light`.
// Doing that per pixel would mean an `isnan` branch inside the hot kernel, and
// under fast math such a branch is not reliably preserved. Zeroing the
// affected rows here is numerically identical to the reference with no
// in-kernel branch (RFC-014 §5.1 trap 5).
struct SpectralConstants {
    Vec channel_density;   // (81, 3) row-major, NaN rows zeroed
    Vec base_density;      // (81)
    Vec illum_x_sens;      // (81, 3) row-major, NaN rows zeroed
};

void prepare_spectral_constants(const Vec& channel_density, const Vec& base_density,
                                const Vec& illuminant, const Vec& sensitivity,
                                double normalization, SpectralConstants& out);

}  // namespace spk
