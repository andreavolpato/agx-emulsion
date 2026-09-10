// profile.hpp -- a measured film or paper profile, loaded from the same JSON
// the Python engine reads.
//
// The profiles did not need porting: `data/profiles/*.json` is already the
// wire format, and `engine/tools/bake_resources.py` copies them into the app
// bundle byte for byte. What this adds is the *shape check* that
// `ProfileData.__post_init__` performed implicitly by handing everything to
// numpy -- and it is stricter on purpose. A profile whose `density_curves`
// arrives (3, 256) instead of (256, 3) must fail at load, not silently
// produce a plausible photograph.
#pragma once
#include <string>
#include <vector>

#include "json.hpp"
#include "numeric.hpp"

namespace spk {

struct DensityCurvesModel {
    std::string model_type = "cdfs";
    size_t n_channels = 0, n_layers = 0;
    Vec centers, amplitudes, sigmas;    // (n_channels, n_layers) row-major
};

struct ProfileInfo {
    std::string stock, name, type = "negative", support = "film", stage = "filming";
    std::string use = "still", antihalation = "weak", target_print;
    std::string channel_model = "color", densitometer = "status_M";
    double log_sensitivity_density_over_min = 0.2;
    std::string reference_illuminant = "D55", viewing_illuminant = "D50";

    bool is_positive() const { return type == "positive"; }
};

struct ProfileData {
    Vec wavelengths;              // (81)
    Vec log_sensitivity;          // (81, 3)
    Vec adaptation_window_params;     // (4) erf4 or (8) logiflex8, or empty
    Vec adaptation_surface_params;    // (3, 15) or empty
    size_t adaptation_surface_rows = 0, adaptation_surface_cols = 0;
    Vec channel_density;          // (81, 3), carries NaN where unmeasured
    Vec base_density;             // (81)
    Vec midscale_neutral_density; // (81)
    Vec log_exposure;             // (K)
    Vec density_curves;           // (K, 3)
    Vec density_curves_layers;    // (K, 3, 3) = [k][layer][channel]
    size_t n_exposure = 0;
    DensityCurvesModel model;
};

struct Profile {
    ProfileInfo info;
    ProfileData data;

    // Derived once at load, because every stage recomputes them otherwise and
    // two of them are `nanmin`/`nanmax` over a 256-point curve:
    //   normalized  = density_curves - nanmin(density_curves, axis=0)
    //   density_max = nanmax(normalized, axis=0)
    Vec normalized_curves;        // (K, 3)
    double density_min[3] = {0, 0, 0};
    double density_max[3] = {0, 0, 0};

    bool load(const std::string& path, std::string& error);
    bool from_json(const Json& root, std::string& error);
};

// `<resources>/profiles/<stock>.json`, with the stock name validated as a
// path component so a stock string off the wire cannot walk the filesystem.
bool load_profile(const std::string& resources_dir, const std::string& stock,
                  Profile& out, std::string& error);

}  // namespace spk
