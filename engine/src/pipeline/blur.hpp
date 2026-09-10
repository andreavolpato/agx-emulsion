// blur.hpp -- the host half of the separable blurs.
//
// A port of `src/spektrafilm/backends/metal/blur.py`'s dispatch: which of the
// two kernels runs, per channel, and how a Gaussian *mixture* is accumulated.
// The kernels are in `shaders/blur.metal`; nothing here touches a pixel.
//
// The dispatch rule is `utils/fast_gaussian_filter`'s, unchanged, because the
// numba reference is what parity is measured against: sigma <= 0 is identity,
// sigma < 3 is FIR with 'reflect' edges and truncate 3.0, sigma >= 3 is the
// Young & van Vliet IIR -- decided **per channel**, since halation's three
// channels routinely straddle the crossover.
#pragma once
#include <string>
#include <utility>
#include <vector>

#include "image.hpp"
#include "numeric.hpp"

namespace spk {

class Blur {
public:
    Blur(gpu::Gpu* gpu) : gpu_(gpu) {}

    // Per-channel Gaussian. With `acc` and `weight`, returns
    // `acc + weight * G(img)` with the multiply-add fused into the last pass
    // -- which is what keeps a three-component exponential PSF at three blurs
    // instead of three blurs plus three full-frame adds.
    bool gaussian(const Image& img, const double sigma[3], Image& out, std::string& error,
                  double truncate = 3.0, const Image* acc = nullptr, const double* weight = nullptr);

    // `sum_k w_k * G(sigma_k)(img)`, accumulated in the reference's order, so
    // the difference from it is a rounding of the running sum and not a
    // different sum.
    struct Component {
        double weight[3];
        double sigma[3];
    };
    bool mixture(const Image& img, const std::vector<Component>& components, Image& out,
                 std::string& error, double truncate = 3.0);

    // The (weight, sigma) list `fast_exponential_filter` is a sum of: a
    // three-Gaussian surrogate for an isotropic 2-D exponential PSF.
    static void exponential_components(const double decay[3], const double weight[3],
                                       std::vector<Component>& out, int n_gaussians = 3);

    // `a * x + b * y` with per-channel scalars.
    bool lincomb(const Image& x, const Image& y, const double a[3], const double b[3],
                 Image& out, std::string& error);

    // A per-channel affine, `x * s + t` -- the exposure gain, the density_min
    // subtraction, the sub-layer division.
    bool affine(const Image& x, const double s[3], const double t[3], Image& out, std::string& error);

private:
    bool fir(const Image& img, const double sigmas[3], double truncate, const bool active[3],
             Image& out, std::string& error, const Image* acc, const double* weight);
    bool iir(const Image& img, const double sigmas[3], const bool active[3],
             Image& out, std::string& error, const Image* acc, const double* weight);
    bool alloc_like(const Image& img, Image& out, std::string& error);

    gpu::Gpu* gpu_;
};

}  // namespace spk
