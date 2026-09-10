// colour.hpp -- the colour transforms the render path calls, over baked data.
//
// A port of `model/colour_baked.py`, which is itself the slice of
// colour-science the pipeline reaches. The chain of responsibility is worth
// stating once, because it is what keeps this from being a reimplementation
// of a colour library:
//
//     colour-science  ->  scripts/bake_colour_constants.py  ->  the .npz
//                     ->  engine/tools/bake_resources.py    ->  the blob
//                     ->  this file
//
// colour-science stays the reference. `engine/tests/parity_setup.py`
// re-derives every matrix, illuminant and transfer function here from the
// Python side and compares. If you need a transform that is not here, add it
// *and* add its check -- RFC-010 exists because three colour bugs were once
// live with 750 tests passing.
#pragma once
#include <string>
#include <unordered_map>

#include "blob.hpp"
#include "numeric.hpp"

namespace spk {

// 380..780 at 5 nm: `config.SPECTRAL_SHAPE`, and the sampling every measured
// profile in `data/profiles` is aligned to.
constexpr size_t kNumWavelengths = 81;

class Colour {
public:
    bool init(const Blob& blob, std::string& error);

    const Vec& wavelengths() const { return wavelengths_; }
    const Vec& cmfs_1931_2deg() const { return cmfs_; }      // (81, 3) row-major
    const Vec& matrix_16() const { return matrix16_; }
    const Vec& mallett_srgb_basis() const { return mallett_; }

    // The raw aligned SD for a named illuminant, before normalisation.
    // Unknown names fail loudly rather than falling back, so a new profile
    // breaks at the bake list instead of rendering a different picture.
    bool illuminant_values(const std::string& name, Vec& out, std::string& error) const;

    struct Colourspace {
        Vec primaries;              // (3, 2)
        double whitepoint[2] = {0, 0};
        Mat3 rgb_to_xyz;
        Mat3 xyz_to_rgb;
    };
    bool colourspace(const std::string& name, const Colourspace*& out, std::string& error) const;
    bool has_colourspace(const std::string& name) const;

    // Von Kries-style adaptation, as
    // `colour.adaptation.matrix_chromatic_adaptation_VonKries`.
    bool matrix_chromatic_adaptation(const double xy_source[2], const double xy_target[2],
                                     const std::string& transform, Mat3& out,
                                     std::string& error) const;

    // The three transforms the render path calls. `illuminant` may be null,
    // meaning "no adaptation" -- and note the reference's `np.allclose` guard:
    // an illuminant equal to the colourspace's own whitepoint applies no
    // adaptation at all, not an identity-shaped one.
    bool RGB_to_XYZ(const double rgb[3], const std::string& cs, bool decode,
                    const double* illuminant_xy, const std::string& cat,
                    double out[3], std::string& error) const;
    bool XYZ_to_RGB(const double xyz[3], const std::string& cs, bool encode,
                    const double* illuminant_xy, const std::string& cat,
                    double out[3], std::string& error) const;

    // The *matrix* forms, which is what the pipeline actually wants: the
    // reference evaluates these transforms on the identity once and applies
    // the 3x3 per pixel (`fused_tc_b.tc_b_matrix`,
    // `ScanningStage._xyz_to_rgb_matrix`). Same construction, no per-pixel
    // colour call, and numerically equivalent rather than merely close.
    bool matrix_RGB_to_XYZ(const std::string& cs, const double* illuminant_xy,
                           const std::string& cat, Mat3& out, std::string& error) const;
    bool matrix_XYZ_to_RGB(const std::string& cs, const double* illuminant_xy,
                           const std::string& cat, Mat3& out, std::string& error) const;
    // `RGB_to_RGB(x, cs, cs, encode=False, decode=False)` -- the near-identity
    // the output CCTF node applies before the curve (AGENTS.md trap 7). It is
    // not the identity, and replacing it with one changes output by 3.8e-4.
    bool matrix_RGB_to_RGB(const std::string& src, const std::string& dst,
                           const std::string& cat, Mat3& out, std::string& error) const;

    // Transfer functions, per colourspace. `known_cctf` is false for the
    // cinema log curves, which are bake-time only and must not be reachable
    // from a render (`Colourspace.from_reference`'s shipped behaviour is to
    // raise).
    bool known_cctf(const std::string& cs) const;
    double cctf_decode(double v, const std::string& cs) const;
    double cctf_encode(double v, const std::string& cs) const;

    static void xy_to_XYZ(const double xy[2], double out[3]);
    static void XYZ_to_xy(const double xyz[3], double out[2]);

    // Planck's law with colour-science's constants, not the exact physical
    // ones: the measured profiles were characterised against this curve
    // (`colour_baked.blackbody_spectral_radiance`).
    static double blackbody_spectral_radiance(double wavelength_m, double temperature);

private:
    Vec wavelengths_, cmfs_, cmfs_lms_, matrix16_, mallett_;
    std::unordered_map<std::string, Colourspace> colourspaces_;
    std::unordered_map<std::string, Vec> illuminants_;
    std::unordered_map<std::string, Mat3> cats_;
};

}  // namespace spk
