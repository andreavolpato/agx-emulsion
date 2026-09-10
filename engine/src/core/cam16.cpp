#include "cam16.hpp"

#include <array>
#include <cmath>

namespace spk {

namespace {

constexpr double kPi = 3.14159265358979323846;

// colour.algebra.spow, again -- see colour.cpp. Repeated rather than shared
// because the two files are ports of two different reference modules and
// keeping each self-contained is what makes each diffable against its source.
double spow(double v, double p) {
    const double s = v < 0.0 ? -1.0 : (v > 0.0 ? 1.0 : 0.0);
    return s * std::pow(std::fabs(v), p);
}

// `colour.appearance.cam16.MATRIX_16` and its inverse.
//
// The forward matrix is a table of spec constants and is written out. The
// inverse is **computed**, and that distinction is worth a line: colour-science
// builds it with `np.linalg.inv(MATRIX_16)`, while the published inverse -- the
// one the MSL kernel carries, at eight digits -- differs from it by ~1e-9
// relative. In float32 that is far below storage epsilon and the kernel is
// right to hold the literal. In float64 it is a real difference, and it moved
// the CAM16 inverse by 1.3e-9, which was enough to flip the in-gamut test in
// the C_max bisection and send 38 of 46,080 cells to a completely different
// value. Derive it.
constexpr double M16[9] = {
     0.401288,  0.650173, -0.051461,
    -0.250268,  1.204414,  0.045854,
    -0.002079,  0.048952,  0.953127,
};

const double* m16_inverse() {
    static const std::array<double, 9> inv = [] {
        std::array<double, 9> out{};
        Mat3::from_row_major(M16).inverse().to_row_major(out.data());
        return out;
    }();
    return inv.data();
}

void mat_apply(const double m[9], const double in[3], double out[3]) {
    for (int i = 0; i < 3; ++i) out[i] = m[3 * i] * in[0] + m[3 * i + 1] * in[1] + m[3 * i + 2] * in[2];
}

// `colour_baked.viewing_conditions_dependent_parameters` and
// `degree_of_adaptation`, both one-line formulae from CIE 159:2004.
void viewing_conditions(double Y_b, double Y_w, double L_A,
                        double& n, double& F_L, double& N_bb, double& N_cb, double& z) {
    n = Y_b / Y_w;
    const double k = 1.0 / (5.0 * L_A + 1.0);
    const double k4 = k * k * k * k;
    F_L = 0.2 * k4 * (5.0 * L_A) + 0.1 * (1.0 - k4) * (1.0 - k4) * std::cbrt(5.0 * L_A);
    N_bb = N_cb = 0.725 * std::pow(1.0 / n, 0.2);
    z = 1.48 + std::sqrt(n);
}

double degree_of_adaptation(double F, double L_A) {
    return F * (1.0 - (1.0 / 3.6) * std::exp((-L_A - 42.0) / 92.0));
}

}  // namespace

double reinhard_knee(double d, double threshold, double limit, double power) {
    if (!(d > threshold)) return d;
    const double scale = limit - threshold;
    const double x = (d - threshold) / scale;
    const double y = x / std::pow(1.0 + std::pow(x, power), 1.0 / power);
    return threshold + scale * y;
}

void cam16_setup(const double xyz_w_in[3], double L_A, double Y_b, Cam16Setup& out) {
    const double xyz_w[3] = {xyz_w_in[0] * 100.0, xyz_w_in[1] * 100.0, xyz_w_in[2] * 100.0};
    const double Y_w = xyz_w[1];
    viewing_conditions(Y_b, Y_w, L_A, out.n, out.F_L, out.N_bb, out.N_cb, out.z);
    double D = degree_of_adaptation(kCam16F, L_A);
    D = D < 0.0 ? 0.0 : (D > 1.0 ? 1.0 : D);

    double rgb_w[3];
    mat_apply(M16, xyz_w, rgb_w);
    double rgb_aw[3];
    for (int i = 0; i < 3; ++i) {
        out.D_rgb[i] = D * Y_w / rgb_w[i] + 1.0 - D;
        const double rgb_wc = out.D_rgb[i] * rgb_w[i];
        const double f = std::pow(out.F_L * std::fabs(rgb_wc) / 100.0, 0.42);
        const double sign = rgb_wc < 0.0 ? -1.0 : (rgb_wc > 0.0 ? 1.0 : 0.0);
        rgb_aw[i] = 400.0 * sign * f / (27.13 + f) + 0.1;
    }
    out.A_w = (2.0 * rgb_aw[0] + 1.0 * rgb_aw[1] + (1.0 / 20.0) * rgb_aw[2] - 0.305) * out.N_bb;
    out.c = kCam16c;
    out.N_c = kCam16Nc;
}

void xyz_to_cam16ucs(const Cam16Setup& st, const double xyz_in[3], double jab[3]) {
    const double xyz[3] = {xyz_in[0] * 100.0, xyz_in[1] * 100.0, xyz_in[2] * 100.0};
    double rgb[3];
    mat_apply(M16, xyz, rgb);

    double rgb_a[3];
    for (int i = 0; i < 3; ++i) {
        const double rc = st.D_rgb[i] * rgb[i];
        const double sign = rc < 0.0 ? -1.0 : (rc > 0.0 ? 1.0 : 0.0);
        const double f = std::pow(st.F_L * std::fabs(rc) / 100.0, 0.42);
        rgb_a[i] = 400.0 * sign * f / (27.13 + f) + 0.1;
    }
    const double a = rgb_a[0] - 12.0 * rgb_a[1] / 11.0 + rgb_a[2] / 11.0;
    const double b = (rgb_a[0] + rgb_a[1] - 2.0 * rgb_a[2]) / 9.0;
    const double h = std::atan2(b, a);
    const double e_t = 0.25 * (std::cos(h + 2.0) + 3.8);

    const double A = (2.0 * rgb_a[0] + rgb_a[1] + rgb_a[2] / 20.0 - 0.305) * st.N_bb;
    // Sign-preserving: a negative achromatic response gives a negative J.
    const double J = 100.0 * spow(A / st.A_w, st.c * st.z);

    const double den = rgb_a[0] + rgb_a[1] + 21.0 * rgb_a[2] / 20.0;
    double t = 0.0;
    if (den != 0.0)
        t = (50000.0 / 13.0 * st.N_c * st.N_cb * e_t * std::sqrt(a * a + b * b)) / den;
    const double e_c = std::pow(1.64 - std::pow(0.29, st.n), 0.73);
    const double C = t > 0.0 ? std::pow(t, 0.9) * std::sqrt(std::fabs(J) / 100.0) * e_c : 0.0;
    const double M = C * std::pow(st.F_L, 0.25);

    const double Mp = (1.0 / 0.0228) * std::log(1.0 + 0.0228 * M);
    jab[0] = 1.7 * J / (1.0 + 0.007 * J);
    jab[1] = Mp * std::cos(h);
    jab[2] = Mp * std::sin(h);
}

void cam16ucs_to_xyz(const Cam16Setup& st, const double jab[3], double xyz_out[3]) {
    const double Jp = jab[0];
    const double Mp = std::hypot(jab[1], jab[2]);
    const double h = std::atan2(jab[2], jab[1]);

    const double M = (std::exp(Mp * 0.0228) - 1.0) / 0.0228;
    const double J = Jp / (1.7 - 0.007 * Jp);
    const double C = M / std::pow(st.F_L, 0.25);

    const double e_c = std::pow(1.64 - std::pow(0.29, st.n), 0.73);
    const double A = st.A_w * spow(J / 100.0, 1.0 / (st.c * st.z));
    const double sq = std::sqrt(std::fabs(J) / 100.0);
    const double t = (sq > 0.0 && C > 0.0) ? std::pow(C / (sq * e_c), 1.0 / 0.9) : 0.0;
    const double e_t = 0.25 * (std::cos(h + 2.0) + 3.8);

    const double ca = std::cos(h), sa = std::sin(h);
    const double p2 = A / st.N_bb + 0.305;
    constexpr double p3 = 21.0 / 20.0;
    double a2, b2;
    if (t == 0.0) {
        a2 = 0.0;
        b2 = 0.0;
    } else {
        const double p1 = ((50000.0 / 13.0) * st.N_c * st.N_cb * e_t) / t;
        // The 460/1403, 220/1403, 27/1403 and 6300/1403 factors are the
        // CIECAM inverse's normalisation. Dropping them still produces a
        // plausible picture; it cost dE2000 max 33.
        if (std::fabs(sa) >= std::fabs(ca)) {
            const double p4 = p1 / sa;
            b2 = (p2 * (2.0 + p3) * (460.0 / 1403.0)) /
                 (p4 + (2.0 + p3) * (220.0 / 1403.0) * (ca / sa) - (27.0 / 1403.0) + p3 * (6300.0 / 1403.0));
            a2 = b2 * (ca / sa);
        } else {
            const double p5 = p1 / ca;
            a2 = (p2 * (2.0 + p3) * (460.0 / 1403.0)) /
                 (p5 + (2.0 + p3) * (220.0 / 1403.0) - ((27.0 / 1403.0) - p3 * (6300.0 / 1403.0)) * (sa / ca));
            b2 = a2 * (sa / ca);
        }
    }
    const double rgb_a[3] = {
        (460.0 * p2 + 451.0 * a2 + 288.0 * b2) / 1403.0,
        (460.0 * p2 - 891.0 * a2 - 261.0 * b2) / 1403.0,
        (460.0 * p2 - 220.0 * a2 - 6300.0 * b2) / 1403.0,
    };
    double rgb_c[3];
    for (int i = 0; i < 3; ++i) {
        const double vm = rgb_a[i] - 0.1;
        const double sign = vm < 0.0 ? -1.0 : (vm > 0.0 ? 1.0 : 0.0);
        // colour's `post_adaptation_non_linear_response_compression_inverse`,
        // **unguarded**: past |vm| = 400 the denominator goes negative, spow
        // keeps the sign, and the result is a large negative response.
        //
        // The MSL kernel clamps that branch to zero instead, and is right to:
        // no pixel the pipeline produces reaches it, and RFC-011 held the
        // kernel to float32 epsilon with the clamp in place. Here the clamp is
        // wrong, because the C_max bisection probes chroma 75 at J' = 4.5
        // precisely to be told it is far outside the cube. Clamping answered
        // "zero, so in gamut", and 19 of 46,080 cells came back at 75 instead
        // of 8.
        const double base = (27.13 * std::fabs(vm)) / (400.0 - std::fabs(vm));
        rgb_c[i] = (100.0 / st.F_L) * sign * spow(base, 1.0 / 0.42) / st.D_rgb[i];
    }
    double xyz[3];
    mat_apply(m16_inverse(), rgb_c, xyz);
    for (int i = 0; i < 3; ++i) xyz_out[i] = xyz[i] / 100.0;
}

bool cam16_setup_for(const Colour& colour, const std::string& cs, Cam16Setup& out,
                     std::string& error) {
    const Colour::Colourspace* space = nullptr;
    if (!colour.colourspace(cs, space, error)) return false;
    const double white[2] = {space->whitepoint[0], space->whitepoint[1]};
    double xyz_w[3];
    Colour::xy_to_XYZ(white, xyz_w);

    cam16_setup(xyz_w, kCam16LA, kCam16Yb, out);
    if (!colour.matrix_RGB_to_XYZ(cs, white, "CAT02", out.m_to_xyz, error)) return false;
    if (!colour.matrix_XYZ_to_RGB(cs, white, "CAT02", out.m_to_rgb, error)) return false;

    double jab_w[3];
    xyz_to_cam16ucs(out, xyz_w, jab_w);
    out.white_Jp = jab_w[0];

    // `_get_output_c_max_table("cam16ucs", cs)`: J' from 1 to 110 (near-black
    // to a hair above white), hue over the full turn with no endpoint, and a
    // bisection on chroma from 0 to 150.
    out.l_grid.resize(kCmaxNL);
    for (size_t i = 0; i < kCmaxNL; ++i)
        out.l_grid[i] = 1.0 + (110.0 - 1.0) * double(i) / double(kCmaxNL - 1);
    out.h_grid.resize(kCmaxNH);
    for (size_t i = 0; i < kCmaxNH; ++i)
        out.h_grid[i] = -kPi + 2.0 * kPi * double(i) / double(kCmaxNH);

    out.c_max_table.assign(kCmaxNL * kCmaxNH, 0.0);
    for (size_t li = 0; li < kCmaxNL; ++li) {
        for (size_t hi_ = 0; hi_ < kCmaxNH; ++hi_) {
            const double L = out.l_grid[li], hue = out.h_grid[hi_];
            const double cosh = std::cos(hue), sinh = std::sin(hue);
            double lo = 0.0, hi = 150.0;
            for (int step = 0; step < kCmaxNBisect; ++step) {
                const double mid = (lo + hi) * 0.5;
                const double jab[3] = {L, mid * cosh, mid * sinh};
                double xyz[3], rgb[3];
                cam16ucs_to_xyz(out, jab, xyz);
                out.m_to_rgb.apply(xyz, rgb);
                // In gamut iff every channel is in [0, 1]. The 1e-6 slack
                // absorbs the matrix-inverse noise that would otherwise leave
                // the largest in-gamut chroma slightly conservative.
                const bool in_gamut = rgb[0] >= -1e-6 && rgb[0] <= 1.0 + 1e-6 &&
                                      rgb[1] >= -1e-6 && rgb[1] <= 1.0 + 1e-6 &&
                                      rgb[2] >= -1e-6 && rgb[2] <= 1.0 + 1e-6;
                if (in_gamut) lo = mid; else hi = mid;
            }
            out.c_max_table[li * kCmaxNH + hi_] = lo;
        }
    }
    return true;
}

}  // namespace spk
