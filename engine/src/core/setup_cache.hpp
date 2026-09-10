// setup_cache.hpp -- the two expensive setup products, kept across rebuilds.
//
// This is a port of three caches on the Python side that the first pass of
// RFC-014 missed, and missing them is felt rather than merely inefficient:
//
//     utils/fused_gamut_cam16._SETUP_CACHE
//     utils/gamut_compression._OUTPUT_CMAX_CACHE
//     runtime/services/spectral_lut_compute.SpectralLUTService.filming_tc_lut_memory
//
// Why it matters. Any parameter outside `LIVE_MUTABLE` rebuilds the pipeline
// -- twelve of the print-layer fields alone, which is most of the right-hand
// panel -- and a rebuild was re-deriving both of these from scratch:
//
//     the CAM16 C_max table   64 x 720 cells x 18 bisections, each running a
//                             full CAM16 inverse: ~830,000 inversions
//     the Hanatos tc_lut      a 192 x 192 x 81 contraction, plus a
//                             192 x 192 ray-polygon remap when input gamut
//                             compression is on (it is, by default)
//
// Measured at 160 ms (-O2) and 250 ms (-O0, which is what Xcode's Debug
// configuration compiles) on every such slider. Neither product depends on
// anything the slider changed.
//
// Both are keyed on exactly what they depend on, so a key collision is a wrong
// picture rather than a slow one -- which is why the tc_lut's key folds in the
// sensitivity itself (that is where the camera's UV/IR cut lands) rather than
// just the stock name.
#pragma once
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "blob.hpp"
#include "cam16.hpp"
#include "colour.hpp"
#include "hanatos.hpp"
#include "params.hpp"
#include "profile.hpp"

namespace spk {

class SetupCache {
public:
    // The CAM16-UCS setup for one output colourspace, table included. Depends
    // on the colourspace and nothing else -- the knee and the lightness
    // compression are per-render constants the kernel reads separately.
    bool cam16(const Colour& colour, const std::string& output_color_space,
               const Cam16Setup*& out, std::string& error);

    // The spectral upsampling LUT. `out` points into the cache and stays
    // valid until this cache is destroyed.
    bool tc_lut(const Colour& colour, const Blob& blob, const Profile& film,
                const SettingsParams& settings, const GamutCompressSpec& compress,
                const Vec& sensitivity, const Vec*& out, size_t& side, std::string& error);

    // For `capabilities`, and for anyone wondering whether a slider was slow
    // because of a miss.
    struct Stats { size_t cam16_entries = 0, lut_entries = 0, hits = 0, misses = 0; };
    Stats stats() const;

private:
    // Four is a user switching between a few stocks; each entry is 884 kB.
    // The Python service keeps exactly one, which makes an A/B between two
    // stocks pay the rebuild every time.
    static constexpr size_t kMaxLuts = 4;

    struct LutEntry {
        std::string key;
        Vec lut;
        size_t side = 0;
    };

    mutable std::mutex lock_;
    std::unordered_map<std::string, Cam16Setup> cam16_;
    std::vector<LutEntry> luts_;      // most recently used first
    mutable size_t hits_ = 0, misses_ = 0;
};

}  // namespace spk
