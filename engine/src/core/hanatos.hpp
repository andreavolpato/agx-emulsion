// hanatos.hpp -- the spectral upsampling LUT, and the input gamut compression
// baked into it.
//
// `filming.expose.upsample` turns RGB into a film exposure by looking up a
// (192, 192, 3) table indexed by chromaticity. Building that table is the
// single largest piece of setup in the engine, and it is a port of
// `utils/spectral_upsampling.compute_hanatos2025_tc_lut` plus
// `utils/gamut_compression.remap_tc_lut_for_compression`.
//
// The shape of it:
//
//   spectra_lut (192, 192, 81)   baked, the Hanatos irradiance spectra
//     x  sensitivity (81, 3)     10 ** the profile's log_sensitivity
//     x  window      (81, 3)     the film's own spectral bandpass, normalised
//                                to preserve white balance
//   -> raw_lut (192, 192, 3)
//     x  2 ** surface            an optional per-chromaticity exposure
//                                correction (off at the shipped defaults)
//   -> remapped so new[xy] = old[compress(xy)]
//
// That last step is the reason the per-pixel path knows nothing about gamut
// compression: the compression is *inside* the table, and a runtime lookup
// returns what the uncompressed table would have returned for the compressed
// chromaticity (n100 §3.1).
#pragma once
#include <string>
#include <vector>

#include "blob.hpp"
#include "colour.hpp"
#include "numeric.hpp"
#include "params.hpp"
#include "profile.hpp"

namespace spk {

// The LUT's own coordinate map, `_tri2quad` / `_quad2tri`. Triangular
// chromaticity coordinates sample the visible locus far better than xy does,
// which is why the table is indexed this way at all.
void tri2quad(const double xy[2], double out[2]);
void quad2tri(const double tc[2], double out[2]);

// The closed polygon of the CIE 1931 2-degree visible spectral locus in xy,
// 380..700 at 5 nm with the first vertex repeated. The baked CMFS is already
// on that sampling, so this is its first 65 rows with no interpolation.
void spectral_locus_xy(const Colour& colour, Vec& out);

// ACES-RGC-style radial compression toward the locus, around `white_xy`. Hue
// (dominant wavelength) is preserved by construction.
void compress_xy_radial(const double xy[2], const double white_xy[2], const Vec& locus,
                        double threshold, double limit, double power, double out[2]);

// `10 ** log_sensitivity`, NaN-zeroed, through the camera's UV/IR cut when
// either amplitude is above zero -- and renormalised so the filter does not
// change the film's white balance.
bool film_sensitivity(const Colour& colour, const Blob& blob, const Profile& film,
                      const CameraParams& camera, Vec& out, std::string& error);

// The whole of `compute_hanatos2025_tc_lut`, compression included.
// `out` is (192, 192, 3) row-major.
bool build_tc_lut(const Colour& colour, const Blob& blob, const Profile& film,
                  const SettingsParams& settings, const GamutCompressSpec& compress,
                  const Vec& sensitivity, Vec& out, size_t& side, std::string& error);

// `fused_tc_b.tc_b_matrix` -- RGB -> XYZ including the CAT16 adaptation to the
// film's reference illuminant, evaluated once on the identity so the per-pixel
// kernel is numerically equivalent rather than merely close.
bool tc_b_matrix(const Colour& colour, const Blob& blob, const std::string& color_space,
                 const std::string& reference_illuminant, Mat3& out, std::string& error);

}  // namespace spk
