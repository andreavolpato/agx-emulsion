// printing.hpp -- the enlarger's per-render constants.
//
// A port of `runtime/stages/printing.PrintingStage`'s setup half plus the part
// of `FilmingStage` that exists only to balance the print
// (`_compute_density_spectral_midgray_to_balance_print`). None of it touches a
// pixel; all of it changes when a filter shift does, which is why it is
// re-derived per render rather than baked.
//
// It lives in `core/` and not in the pipeline for one reason: it was wrong
// once, by a factor small enough to look like a grading choice (a 2-count
// shift over 93 % of the frame), and a value the pipeline computes privately
// is a value no harness can see. `parity_setup.py` checks every field below.
#pragma once
#include <string>

#include "blob.hpp"
#include "colour.hpp"
#include "hanatos.hpp"
#include "numeric.hpp"
#include "params.hpp"
#include "spectral.hpp"

namespace spk {

struct PrintConstants {
    SpectralConstants spectral;   // the film's density through the enlarger's light
    double gain[3] = {1, 1, 1};   // `_compute_exposure_factor_midgray`
    double offset[3] = {0, 0, 0}; // `_compute_raw_preflash`
    Vec print_illuminant;         // the filtered enlarger light, 81 values
    Vec paper_sensitivity;        // 10 ** log_sensitivity, NaN-zeroed, (81, 3)
    // The film's black and white through the same response -- what the
    // scanner's black/white correction line is anchored to.
    double log_raw_black[3] = {0, 0, 0};
    double log_raw_white[3] = {0, 0, 0};
    // The midgray spectral densities, exposed because they are the two values
    // the gain is a ratio of and the ratio hides an error in either.
    Vec density_spectral_midgray;
    Vec density_spectral_midgray_comp;
    bool has_comp = false;
};

// `tc_lut` is passed in rather than rebuilt: the midgray probe runs one pixel
// of 0.184 grey through the *film* model, and rebuilding a 192x192x81
// contraction to do it would cost more than the render it is normalising.
//
// The probe's own RGB->XYZ matrix is **not** passed in, and that is the point.
// `FilmingStage._simple_rgb_to_density_spectral` calls `_rgb_to_film_raw(rgb)`
// with no `color_space` argument, so it takes that method's default -- which
// is `"sRGB"`, not `io.input_color_space`. The print balance therefore
// evaluates its grey in sRGB whatever the frame is encoded in.
//
// That reads like an oversight in the reference, and it may be one, but it is
// what sets every print's exposure: using the input space instead moved the
// midgray spectral density by 7.6e-5 relative and every rendered print by
// ~2 counts over 93 % of the frame. It is reproduced here, and named, rather
// than quietly corrected.
constexpr const char* kMidgrayProbeColourSpace = "sRGB";

bool print_constants(const Colour& colour, const Blob& blob, const Params& params,
                     const Vec& tc_lut, size_t tc_lut_side,
                     PrintConstants& out, std::string& error);

// The print-exposure gain the log node applies: the slider times the
// black/white correction. Split out because the correction needs the scanner's
// own constants, which the pipeline owns.
double print_exposure_bw_gain(const Params& params, double y_black, double y_white,
                              double black_level, double white_level);

}  // namespace spk
