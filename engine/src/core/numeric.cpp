#include "numeric.hpp"

#include <algorithm>

namespace spk {

Mat3 Mat3::inverse() const {
    const double a = m[0][0], b = m[0][1], c = m[0][2];
    const double d = m[1][0], e = m[1][1], f = m[1][2];
    const double g = m[2][0], h = m[2][1], i = m[2][2];
    const double A =  (e * i - f * h), B = -(d * i - f * g), C =  (d * h - e * g);
    const double det = a * A + b * B + c * C;
    Mat3 r;
    const double inv = 1.0 / det;   // singular input is a bug upstream, not a case
    r.m[0][0] = A * inv;                    r.m[0][1] = -(b * i - c * h) * inv; r.m[0][2] =  (b * f - c * e) * inv;
    r.m[1][0] = B * inv;                    r.m[1][1] =  (a * i - c * g) * inv; r.m[1][2] = -(a * f - c * d) * inv;
    r.m[2][0] = C * inv;                    r.m[2][1] = -(a * h - b * g) * inv; r.m[2][2] =  (a * e - b * d) * inv;
    return r;
}

double nanmin(const double* p, size_t n, size_t stride) {
    double best = NAN;
    for (size_t i = 0; i < n; ++i) {
        const double v = p[i * stride];
        if (is_nan(v)) continue;
        if (is_nan(best) || v < best) best = v;
    }
    return best;
}

double nanmax(const double* p, size_t n, size_t stride) {
    double best = NAN;
    for (size_t i = 0; i < n; ++i) {
        const double v = p[i * stride];
        if (is_nan(v)) continue;
        if (is_nan(best) || v > best) best = v;
    }
    return best;
}

double nanmean(const double* p, size_t n, size_t stride) {
    double sum = 0.0;
    size_t count = 0;
    for (size_t i = 0; i < n; ++i) {
        const double v = p[i * stride];
        if (is_nan(v)) continue;
        sum += v;
        ++count;
    }
    return count ? sum / double(count) : NAN;
}

size_t searchsorted_right(const double* a, size_t stride, size_t n, double v) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        const size_t mid = lo + ((hi - lo) >> 1);
        if (a[mid * stride] <= v) lo = mid + 1; else hi = mid;
    }
    return lo;
}

double interp(double v, const double* x, const double* y, size_t n) {
    if (n == 0) return NAN;
    if (v <= x[0]) return y[0];
    if (v >= x[n - 1]) return y[n - 1];
    const size_t idx = searchsorted_right(x, 1, n, v);
    const size_t low = idx - 1;
    const double dx = x[low + 1] - x[low];
    if (dx == 0.0) return y[low];
    const double t = (v - x[low]) / dx;
    return y[low] + t * (y[low + 1] - y[low]);
}

void interp_many(const double* v, size_t nv, const double* x, const double* y, size_t n, double* out) {
    for (size_t i = 0; i < nv; ++i) out[i] = interp(v[i], x, y, n);
}

size_t gaussian_kernel_1d(double sigma, double truncate, Vec& out) {
    const size_t radius = size_t(truncate * sigma + 0.5);
    const size_t size = 2 * radius + 1;
    out.assign(size, 0.0);
    if (sigma <= 0.0) { out.assign(1, 1.0); return 0; }
    double total = 0.0;
    for (size_t i = 0; i < size; ++i) {
        const double x = double(i) - double(radius);
        const double val = std::exp(-0.5 * (x / sigma) * (x / sigma));
        out[i] = val;
        total += val;
    }
    for (size_t i = 0; i < size; ++i) out[i] /= total;
    return radius;
}

void yvv_coeffs(double sigma, double out[4]) {
    const double q = sigma >= 2.5 ? 0.98711 * sigma - 0.96330
                                  : 3.97156 - 4.14554 * std::sqrt(1.0 - 0.26891 * sigma);
    const double q2 = q * q, q3 = q2 * q;
    const double b0 = 1.57825 + 2.44413 * q + 1.4281 * q2 + 0.422205 * q3;
    const double b1 = 2.44413 * q + 2.85619 * q2 + 1.26661 * q3;
    const double b2 = -(1.4281 * q2 + 1.26661 * q3);
    const double b3 = 0.422205 * q3;
    out[0] = 1.0 - (b1 + b2 + b3) / b0;
    out[1] = b1 / b0;
    out[2] = b2 / b0;
    out[3] = b3 / b0;
}

void exponential_gaussian_fit(int n, std::vector<std::pair<double, double>>& out) {
    out.clear();
    if (n == 2) {
        out.push_back({0.6235, 0.9401});
        out.push_back({0.3765, 2.5177});
    } else {
        out.push_back({0.1633, 0.5360});
        out.push_back({0.6496, 1.5236});
        out.push_back({0.1870, 2.7684});
    }
}

}  // namespace spk
