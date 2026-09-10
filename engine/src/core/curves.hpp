// curves.hpp -- density curves, DIR couplers, and the print-curve morph.
//
// Ports of `model/density_curves.py`, `model/couplers.py` and
// `utils/morph_curves.py`. All of it is small-array work over measured data,
// run once per stock pair; the per-pixel side is a 1-D LUT lookup on the GPU,
// and what these produce is that LUT's contents.
#pragma once
#include <vector>

#include "numeric.hpp"
#include "params.hpp"
#include "profile.hpp"

namespace spk {

// The three tables the GPU's `interp_channel` reads: the per-channel x axis,
// the reciprocal of each step (0 where the axis repeats, as `fast_interp`
// does), and the values. All (K, 3) / (K-1, 3) row-major float64; the caller
// narrows to float32 on upload.
struct InterpTables {
    Vec x;      // (K, 3)
    Vec inv;    // (K-1, 3)
    Vec y;      // (K, 3)
    size_t k = 0;
};

// `x_axis / gamma` per channel, as `interpolate_exposure_to_density` builds it.
// `gamma` is one value per channel.
void build_interp_tables(const Vec& log_exposure, const double gamma[3],
                         const Vec& curves, InterpTables& out);

// `couplers.compute_dir_couplers_matrix(params) * params.amount`. Row is the
// donor layer that releases inhibitor, column the receiver whose exposure is
// reduced -- and the convention is the same on both sides of the diagonal.
void dir_couplers_matrix(const DirCouplersParams& p, double out[9]);

// `couplers.compute_density_curves_before_dir_couplers`.
//
// DIR couplers raise same-layer contrast, and a film is designed so the
// *finished* curves are the measured ones. To reproduce a measured grey ramp
// the pipeline therefore needs the curves as they were *before* the couplers
// acted, which is this inverse.
void density_curves_before_dir_couplers(const Vec& curves, const Vec& log_exposure,
                                        const double matrix[9], bool positive, Vec& out);

// `morph_curves.apply_print_curves_morph`.
//
// At the shipped defaults (`active = False`) this is the fitted density
// evaluated straight from the profile's model -- a sum of normal CDFs -- and
// nothing else runs. The morph itself is implemented too, because a parameter
// that is unreachable today is a parameter that will be wrong the first time
// it is wired up.
bool print_curves_morph(const Vec& log_exposure, const DensityCurvesModel& model,
                        const PrintCurvesMorphParams& morph, bool positive,
                        Vec& out, std::string& error);

}  // namespace spk
