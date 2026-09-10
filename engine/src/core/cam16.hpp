// cam16.hpp -- CAM16-UCS setup for the output gamut compression.
//
// The per-pixel arithmetic is in `shaders/gamut.metal`; what is here is
// everything that does not depend on a pixel, which is what
// `utils/fused_gamut_cam16._setup_for` computes once per output colourspace:
// the viewing-condition scalars, the adaptation gains, the RGB<->XYZ matrices,
// the whitepoint's J', and the C_max(J', h') table.
//
// The table is the expensive one: 64 lightnesses x 720 hues, 18 bisection
// steps, each step running the CAM16 *inverse* and an XYZ->RGB to ask whether
// the colour is still inside the cube. The reference builds it with
// colour-science; this builds it with the port below, and
// `engine/tests/parity_setup.py` compares the two tables cell by cell.
//
// Two of the reference's traps are reproduced deliberately, both because they
// produce plausible-looking output when got wrong:
//   * the sign-preserving power for J -- a negative achromatic response gives
//     a negative J, and pipeline output legitimately reaches -0.20;
//   * the 460/1403 family of normalisation factors in the (a, b) solve, whose
//     omission cost dE2000 max 33 before it was caught.
#pragma once
#include <string>
#include <vector>

#include "colour.hpp"
#include "numeric.hpp"

namespace spk {

// `gamut_compression._CAM16UCS_L_A` / `_Y_B`: the canonical display-review
// setup, and the colour-science defaults for the rest.
constexpr double kCam16LA = 64.0;
constexpr double kCam16Yb = 20.0;
constexpr double kCam16F = 1.0;
constexpr double kCam16c = 0.69;
constexpr double kCam16Nc = 1.0;

// `_OKLCH_CMAX_TABLE_N_L` / `_N_H` / `_N_BISECT`, shared by every perceptual
// space's table.
constexpr size_t kCmaxNL = 64;
constexpr size_t kCmaxNH = 720;
constexpr int kCmaxNBisect = 18;

struct Cam16Setup {
    double n = 0, F_L = 0, N_bb = 0, N_cb = 0, z = 0, A_w = 0;
    double c = kCam16c, N_c = kCam16Nc;
    double D_rgb[3] = {1, 1, 1};
    Mat3 m_to_xyz, m_to_rgb;     // RGB<->XYZ for the output space, adaptation included
    double white_Jp = 0.0;
    Vec l_grid;                  // (64)
    Vec h_grid;                  // (720)
    Vec c_max_table;             // (64, 720) row-major
};

// `cam16_setup(xyz_w, L_A, Y_b)` -- the pixel-independent scalars.
void cam16_setup(const double xyz_w[3], double L_A, double Y_b, Cam16Setup& out);

// The CAM16 forward and inverse in float64, matching colour-science's
// `XYZ_to_CAM16UCS` / `CAM16UCS_to_XYZ` under these viewing conditions.
// `xyz` is normalised so diffuse white has Y = 1, the convention every other
// XYZ in this engine uses.
void xyz_to_cam16ucs(const Cam16Setup& st, const double xyz[3], double jab[3]);
void cam16ucs_to_xyz(const Cam16Setup& st, const double jab[3], double xyz[3]);

// The whole of `_setup_for(output_color_space)`, table included.
bool cam16_setup_for(const Colour& colour, const std::string& output_color_space,
                     Cam16Setup& out, std::string& error);

// `reinhard_knee`: identity below `threshold`, smoothly asymptotic at `limit`
// above it. Bit-identical to the ACES RGC v1.3 reference.
double reinhard_knee(double d, double threshold, double limit, double power);

}  // namespace spk
