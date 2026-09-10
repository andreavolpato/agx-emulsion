// numeric.hpp -- the small numeric vocabulary the setup maths is written in.
//
// Everything here is host-side float64 over small arrays: curves of 256
// points, spectra of 81, matrices of 3x3. None of it touches a pixel. The
// per-pixel arithmetic lives in `engine/src/shaders/` and runs on the GPU.
//
// Two of these functions exist to reproduce a *specific* reference behaviour
// rather than a textbook one, and both are load-bearing:
//
//   - `searchsorted_right` reproduces numpy's scalar search step for step,
//     including on the slightly non-monotonic toe of a measured density
//     curve, where "the right answer" is whatever the reference's search
//     returns.
//   - `nanmin` / `nanmax` skip NaN the way numpy's do, because the measured
//     profiles carry NaN where no measurement exists and the pipeline
//     normalises curves against `nanmin` before anything else touches them.
#pragma once
#include <cmath>
#include <cstddef>
#include <vector>

namespace spk {

using Vec = std::vector<double>;

// Row-major 3x3. `apply` is numpy's `v @ M.T`: out[i] = sum_j m[i][j] * v[j].
struct Mat3 {
    double m[3][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}};

    static Mat3 identity() { return Mat3{}; }
    static Mat3 diag(double a, double b, double c) {
        Mat3 r; r.m[0][0] = a; r.m[1][1] = b; r.m[2][2] = c;
        r.m[0][1] = r.m[0][2] = r.m[1][0] = r.m[1][2] = r.m[2][0] = r.m[2][1] = 0.0;
        return r;
    }
    static Mat3 from_row_major(const double* p) {
        Mat3 r;
        for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) r.m[i][j] = p[3 * i + j];
        return r;
    }
    void to_row_major(double* p) const {
        for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) p[3 * i + j] = m[i][j];
    }
    Mat3 operator*(const Mat3& o) const {
        Mat3 r;
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j) {
                double s = 0;
                for (int k = 0; k < 3; ++k) s += m[i][k] * o.m[k][j];
                r.m[i][j] = s;
            }
        return r;
    }
    void apply(const double in[3], double out[3]) const {
        for (int i = 0; i < 3; ++i) out[i] = m[i][0] * in[0] + m[i][1] * in[1] + m[i][2] * in[2];
    }
    Mat3 transposed() const {
        Mat3 r;
        for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) r.m[i][j] = m[j][i];
        return r;
    }
    Mat3 inverse() const;   // exact cofactor inverse; 3x3 is small enough to be closed form
};

inline bool is_nan(double v) { return v != v; }

double nanmin(const double* p, size_t n, size_t stride = 1);
double nanmax(const double* p, size_t n, size_t stride = 1);
double nanmean(const double* p, size_t n, size_t stride = 1);

// numpy's `searchsorted(a, v, side='right')` for one scalar, over a strided
// column. Half-open binary search, identical branch for branch.
size_t searchsorted_right(const double* a, size_t stride, size_t n, double v);

// numpy's `np.interp` with the same endpoint clamping. `x` must be
// non-decreasing; the reference does not check and neither does this.
double interp(double v, const double* x, const double* y, size_t n);
void interp_many(const double* v, size_t nv, const double* x, const double* y, size_t n, double* out);

// scipy.ndimage's 1-D Gaussian kernel, order 0: radius = int(truncate*sigma+0.5),
// normalised. Returns the radius; `out` is resized to 2r+1.
size_t gaussian_kernel_1d(double sigma, double truncate, Vec& out);

// Young & van Vliet 2002 third-order IIR coefficients, as
// `utils/fast_gaussian_filter._yvv_coeffs`. Returns (B, B1, B2, B3).
void yvv_coeffs(double sigma, double out[4]);

// The Gaussian-mixture surrogate for a 2-D isotropic exponential PSF,
// `_EXPONENTIAL_GAUSSIAN_FITS`. `n` is 2 or 3; `out` is (amplitude, sigma
// ratio) pairs.
void exponential_gaussian_fit(int n, std::vector<std::pair<double, double>>& out);

// `utils/fast_gaussian_filter.SMALL_SIGMA_MAX` -- the FIR/IIR crossover. The
// GPU blur dispatches on this per channel, so it has to be the same number.
constexpr double kSmallSigmaMax = 3.0;

}  // namespace spk
