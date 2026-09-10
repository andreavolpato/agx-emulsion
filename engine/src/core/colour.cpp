#include "colour.hpp"

#include <cmath>
#include <cstring>

namespace spk {

namespace {

// `np.allclose` defaults: rtol 1e-5, atol 1e-8. The reference uses it to
// decide whether an illuminant *is* the colourspace's whitepoint, and that
// decision selects between "no adaptation" and "an adaptation matrix", so the
// tolerance has to be the same one.
bool allclose2(const double a[2], const double b[2]) {
    for (int i = 0; i < 2; ++i)
        if (std::fabs(a[i] - b[i]) > 1e-8 + 1e-5 * std::fabs(b[i])) return false;
    return true;
}

// colour.algebra.spow: |v|**p with v's sign kept, so a negative code value
// does not become NaN.
double spow(double v, double p) {
    const double s = v < 0.0 ? -1.0 : (v > 0.0 ? 1.0 : 0.0);
    return s * std::pow(std::fabs(v), p);
}

// The decode breakpoint is the *encoded* value of 0.0031308 -- 0.040449936 --
// not the rounded 0.04045 the spec prints. At exactly 0.04045 the two choose
// different branches (2.3e-9 apart), and colour uses the exact one.
constexpr double kSrgbLinearMax = 0.0031308;
constexpr double kSrgbEncodedMax = kSrgbLinearMax * 12.92;

double srgb_decode(double v) { return kSrgbEncodedMax >= v ? v / 12.92 : spow((v + 0.055) / 1.055, 2.4); }
double srgb_encode(double v) { return v <= kSrgbLinearMax ? v * 12.92 : 1.055 * spow(v, 1.0 / 2.4) - 0.055; }
double prophoto_decode(double v) { return v < 16.0 * (1.0 / 512.0) ? v / 16.0 : std::pow(v, 1.8); }
double prophoto_encode(double v) { return v < 1.0 / 512.0 ? v * 16.0 : std::pow(v, 1.0 / 1.8); }

constexpr double kAdobeGamma = 563.0 / 256.0;
double adobe_decode(double v) { return std::pow(v, kAdobeGamma); }
double adobe_encode(double v) { return std::pow(v, 1.0 / kAdobeGamma); }

// BT.709 and BT.2020 (10-bit system, colour's default) share alpha and beta.
// The inverse's breakpoint is the *encoded* value of beta, not 4.5*beta; and
// BT.2020's 12-bit constants are a different curve colour does not use here.
constexpr double kBtAlpha = 1.099;
constexpr double kBtBeta = 0.018;
double bt_encode(double v) { return kBtBeta > v ? v * 4.5 : kBtAlpha * spow(v, 0.45) - (kBtAlpha - 1.0); }
double bt_decode(double v) {
    const double bp = kBtAlpha * std::pow(kBtBeta, 0.45) - (kBtAlpha - 1.0);
    return bp > v ? v / 4.5 : spow((v + (kBtAlpha - 1.0)) / kBtAlpha, 1.0 / 0.45);
}

enum class Cctf { Srgb, ProPhoto, Adobe, Bt, Identity };

const std::unordered_map<std::string, Cctf>& cctf_table() {
    static const std::unordered_map<std::string, Cctf> t = {
        {"sRGB", Cctf::Srgb},
        {"Display P3", Cctf::Srgb},
        {"ProPhoto RGB", Cctf::ProPhoto},
        {"Adobe RGB (1998)", Cctf::Adobe},
        {"ITU-R BT.709", Cctf::Bt},
        {"ITU-R BT.2020", Cctf::Bt},
        {"ACEScg", Cctf::Identity},
        {"ACES2065-1", Cctf::Identity},
    };
    return t;
}

}  // namespace

bool Colour::init(const Blob& blob, std::string& error) {
    if (!blob.get("spectral/wavelengths", wavelengths_, error)) return false;
    if (wavelengths_.size() != kNumWavelengths) {
        error = "spectral shape is " + std::to_string(wavelengths_.size()) +
                " wavelengths; this build is built for " + std::to_string(kNumWavelengths);
        return false;
    }
    if (!blob.get("colour/cmfs_1931_2deg", cmfs_, error)) return false;
    if (!blob.get("colour/cmfs_lms", cmfs_lms_, error)) return false;
    if (!blob.get("colour/matrix_16", matrix16_, error)) return false;
    if (!blob.get("colour/mallett_srgb_basis", mallett_, error)) return false;

    for (const std::string& key : blob.names()) {
        if (key.rfind("colour/sd_illuminant/", 0) == 0 || key.rfind("colour/sd_light_source/", 0) == 0) {
            Vec v;
            if (!blob.get(key, v, error)) return false;
            illuminants_[key.substr(key.rfind('/') + 1)] = std::move(v);
        } else if (key.rfind("colour/cat/", 0) == 0) {
            Vec v;
            if (!blob.get(key, v, error)) return false;
            if (v.size() != 9) { error = key + ": expected a 3x3"; return false; }
            cats_[key.substr(key.rfind('/') + 1)] = Mat3::from_row_major(v.data());
        } else if (key.rfind("colour/cs/", 0) == 0) {
            // colour/cs/<name>/<field>, and <name> may itself contain a
            // slash-free space ("Adobe RGB (1998)"), so split on the last one.
            const size_t last = key.rfind('/');
            const std::string field = key.substr(last + 1);
            const std::string name = key.substr(10, last - 10);
            Vec v;
            if (!blob.get(key, v, error)) return false;
            Colourspace& cs = colourspaces_[name];
            if (field == "primaries") cs.primaries = std::move(v);
            else if (field == "whitepoint") { cs.whitepoint[0] = v[0]; cs.whitepoint[1] = v[1]; }
            else if (field == "matrix_RGB_to_XYZ") cs.rgb_to_xyz = Mat3::from_row_major(v.data());
            else if (field == "matrix_XYZ_to_RGB") cs.xyz_to_rgb = Mat3::from_row_major(v.data());
        }
    }
    if (colourspaces_.empty() || illuminants_.empty() || cats_.empty()) {
        error = "the resource blob carries no colourspaces, illuminants or adaptation transforms";
        return false;
    }
    return true;
}

bool Colour::illuminant_values(const std::string& name, Vec& out, std::string& error) const {
    auto it = illuminants_.find(name);
    if (it == illuminants_.end()) {
        std::string known;
        for (const auto& kv : illuminants_) { if (!known.empty()) known += ", "; known += kv.first; }
        error = "no baked illuminant '" + name + "'; baked: " + known +
                ". Add it to scripts/bake_colour_constants.py and re-bake.";
        return false;
    }
    out = it->second;
    return true;
}

bool Colour::has_colourspace(const std::string& name) const { return colourspaces_.count(name) != 0; }

bool Colour::colourspace(const std::string& name, const Colourspace*& out, std::string& error) const {
    auto it = colourspaces_.find(name);
    if (it == colourspaces_.end()) {
        std::string known;
        for (const auto& kv : colourspaces_) { if (!known.empty()) known += ", "; known += kv.first; }
        error = "no baked colourspace '" + name + "'; baked: " + known;
        return false;
    }
    out = &it->second;
    return true;
}

bool Colour::matrix_chromatic_adaptation(const double xy_source[2], const double xy_target[2],
                                         const std::string& transform, Mat3& out,
                                         std::string& error) const {
    auto it = cats_.find(transform);
    if (it == cats_.end()) {
        error = "no baked chromatic adaptation transform '" + transform + "'";
        return false;
    }
    const Mat3& M = it->second;
    double ws_xyz[3], wt_xyz[3], ws[3], wt[3];
    xy_to_XYZ(xy_source, ws_xyz);
    xy_to_XYZ(xy_target, wt_xyz);
    M.apply(ws_xyz, ws);      // `xy_to_XYZ(...) @ M.T`
    M.apply(wt_xyz, wt);
    out = M.inverse() * Mat3::diag(wt[0] / ws[0], wt[1] / ws[1], wt[2] / ws[2]) * M;
    return true;
}

bool Colour::matrix_RGB_to_XYZ(const std::string& cs_name, const double* illuminant_xy,
                               const std::string& cat, Mat3& out, std::string& error) const {
    const Colourspace* cs = nullptr;
    if (!colourspace(cs_name, cs, error)) return false;
    out = cs->rgb_to_xyz;
    if (illuminant_xy && !allclose2(illuminant_xy, cs->whitepoint)) {
        Mat3 adapt;
        if (!matrix_chromatic_adaptation(cs->whitepoint, illuminant_xy, cat, adapt, error)) return false;
        out = adapt * out;
    }
    return true;
}

bool Colour::matrix_XYZ_to_RGB(const std::string& cs_name, const double* illuminant_xy,
                               const std::string& cat, Mat3& out, std::string& error) const {
    const Colourspace* cs = nullptr;
    if (!colourspace(cs_name, cs, error)) return false;
    out = cs->xyz_to_rgb;
    if (illuminant_xy && !allclose2(illuminant_xy, cs->whitepoint)) {
        Mat3 adapt;
        if (!matrix_chromatic_adaptation(illuminant_xy, cs->whitepoint, cat, adapt, error)) return false;
        out = out * adapt;
    }
    return true;
}

bool Colour::matrix_RGB_to_RGB(const std::string& src_name, const std::string& dst_name,
                               const std::string& cat, Mat3& out, std::string& error) const {
    const Colourspace* src = nullptr;
    const Colourspace* dst = nullptr;
    if (!colourspace(src_name, src, error)) return false;
    if (!colourspace(dst_name, dst, error)) return false;
    out = src->rgb_to_xyz;
    if (!cat.empty() && !allclose2(src->whitepoint, dst->whitepoint)) {
        Mat3 adapt;
        if (!matrix_chromatic_adaptation(src->whitepoint, dst->whitepoint, cat, adapt, error)) return false;
        out = adapt * out;
    }
    out = dst->xyz_to_rgb * out;
    return true;
}

bool Colour::RGB_to_XYZ(const double rgb[3], const std::string& cs, bool decode,
                        const double* illuminant_xy, const std::string& cat,
                        double out[3], std::string& error) const {
    double v[3] = {rgb[0], rgb[1], rgb[2]};
    if (decode) for (int i = 0; i < 3; ++i) v[i] = cctf_decode(v[i], cs);
    Mat3 M;
    if (!matrix_RGB_to_XYZ(cs, illuminant_xy, cat, M, error)) return false;
    M.apply(v, out);
    return true;
}

bool Colour::XYZ_to_RGB(const double xyz[3], const std::string& cs, bool encode,
                        const double* illuminant_xy, const std::string& cat,
                        double out[3], std::string& error) const {
    Mat3 M;
    if (!matrix_XYZ_to_RGB(cs, illuminant_xy, cat, M, error)) return false;
    M.apply(xyz, out);
    if (encode) for (int i = 0; i < 3; ++i) out[i] = cctf_encode(out[i], cs);
    return true;
}

bool Colour::known_cctf(const std::string& cs) const { return cctf_table().count(cs) != 0; }

double Colour::cctf_decode(double v, const std::string& cs) const {
    auto it = cctf_table().find(cs);
    if (it == cctf_table().end()) return v;   // callers gate on known_cctf first
    switch (it->second) {
        case Cctf::Srgb: return srgb_decode(v);
        case Cctf::ProPhoto: return prophoto_decode(v);
        case Cctf::Adobe: return adobe_decode(v);
        case Cctf::Bt: return bt_decode(v);
        case Cctf::Identity: return v;
    }
    return v;
}

double Colour::cctf_encode(double v, const std::string& cs) const {
    auto it = cctf_table().find(cs);
    if (it == cctf_table().end()) return v;
    switch (it->second) {
        case Cctf::Srgb: return srgb_encode(v);
        case Cctf::ProPhoto: return prophoto_encode(v);
        case Cctf::Adobe: return adobe_encode(v);
        case Cctf::Bt: return bt_encode(v);
        case Cctf::Identity: return v;
    }
    return v;
}

void Colour::xy_to_XYZ(const double xy[2], double out[3]) {
    out[0] = xy[0] / xy[1];
    out[1] = 1.0;
    out[2] = (1.0 - xy[0] - xy[1]) / xy[1];
}

void Colour::XYZ_to_xy(const double xyz[3], double out[2]) {
    const double s = xyz[0] + xyz[1] + xyz[2];
    out[0] = xyz[0] / s;
    out[1] = xyz[1] / s;
}

double Colour::blackbody_spectral_radiance(double lam, double temperature) {
    constexpr double c1 = 3.741771e-16;   // W m^2
    constexpr double c2 = 1.4388e-2;      // m K, ITS-90
    constexpr double n = 1.0;
    const double pi = 3.14159265358979323846;
    return ((c1 * std::pow(n, -2.0) * std::pow(lam, -5.0)) / pi) /
           std::expm1(c2 / (n * lam * temperature));
}

}  // namespace spk
