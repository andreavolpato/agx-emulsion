#include "profile.hpp"

#include <cstdio>
#include <fstream>
#include <sstream>

namespace spk {

namespace {

bool read_file(const std::string& path, std::string& out, std::string& error) {
    std::ifstream in(path, std::ios::binary);
    if (!in) { error = "cannot open " + path; return false; }
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

bool want_vec(const Json& parent, const char* key, Vec& out, size_t expect, std::string& error) {
    if (!json_to_vec(parent.at(key), out)) { error = std::string(key) + ": expected a list of numbers"; return false; }
    if (expect && out.size() != expect) {
        error = std::string(key) + ": expected " + std::to_string(expect) + " values, got " + std::to_string(out.size());
        return false;
    }
    return true;
}

bool want_mat(const Json& parent, const char* key, Vec& out, size_t rows, size_t cols, std::string& error) {
    size_t r = 0, c = 0;
    if (!json_to_mat(parent.at(key), out, r, c)) { error = std::string(key) + ": expected a 2-D list of numbers"; return false; }
    if ((rows && r != rows) || (cols && c != cols)) {
        error = std::string(key) + ": expected (" + std::to_string(rows) + ", " + std::to_string(cols) +
                "), got (" + std::to_string(r) + ", " + std::to_string(c) + ")";
        return false;
    }
    return true;
}

std::string str_or(const Json& j, const char* key, const std::string& fallback) {
    const Json& v = j.at(key);
    return v.is_string() ? v.as_string() : fallback;
}

}  // namespace

bool Profile::from_json(const Json& root, std::string& error) {
    const Json& in = root.at("info");
    if (!in.is_object()) { error = "profile has no 'info' object"; return false; }
    info.stock = str_or(in, "stock", "");
    info.name = str_or(in, "name", info.stock);
    info.type = str_or(in, "type", "negative");
    info.support = str_or(in, "support", "film");
    info.stage = str_or(in, "stage", "filming");
    info.use = str_or(in, "use", "still");
    info.antihalation = str_or(in, "antihalation", "weak");
    info.target_print = str_or(in, "target_print", "");
    info.channel_model = str_or(in, "channel_model", "color");
    info.densitometer = str_or(in, "densitometer", "status_M");
    info.log_sensitivity_density_over_min = in.at("log_sensitivity_density_over_min").as_double(0.2);
    info.reference_illuminant = str_or(in, "reference_illuminant", "D55");
    info.viewing_illuminant = str_or(in, "viewing_illuminant", "D50");
    if (info.type != "negative" && info.type != "positive") {
        error = "profile '" + info.stock + "': type is '" + info.type + "', expected negative or positive";
        return false;
    }

    const Json& d = root.at("data");
    if (!d.is_object()) { error = "profile '" + info.stock + "' has no 'data' object"; return false; }

    if (!want_vec(d, "wavelengths", data.wavelengths, 0, error)) return false;
    const size_t nw = data.wavelengths.size();
    if (nw != 81) {
        error = "profile '" + info.stock + "': " + std::to_string(nw) +
                " wavelengths; this build is built for 81 (380..780 at 5 nm)";
        return false;
    }
    if (!want_mat(d, "log_sensitivity", data.log_sensitivity, nw, 3, error)) return false;
    if (!want_mat(d, "channel_density", data.channel_density, nw, 3, error)) return false;
    if (!want_vec(d, "base_density", data.base_density, nw, error)) return false;
    if (d.has("midscale_neutral_density") && !want_vec(d, "midscale_neutral_density", data.midscale_neutral_density, nw, error))
        return false;

    if (!want_vec(d, "log_exposure", data.log_exposure, 0, error)) return false;
    data.n_exposure = data.log_exposure.size();
    if (data.n_exposure < 2) { error = "profile '" + info.stock + "': log_exposure needs at least two points"; return false; }
    if (!want_mat(d, "density_curves", data.density_curves, data.n_exposure, 3, error)) return false;

    if (d.has("density_curves_layers")) {
        size_t d0 = 0, d1 = 0, d2 = 0;
        if (!json_to_3d(d.at("density_curves_layers"), data.density_curves_layers, d0, d1, d2)) {
            error = "profile '" + info.stock + "': density_curves_layers is not a 3-D list";
            return false;
        }
        if (d0 != data.n_exposure || d1 != 3 || d2 != 3) {
            error = "profile '" + info.stock + "': density_curves_layers is (" + std::to_string(d0) + ", " +
                    std::to_string(d1) + ", " + std::to_string(d2) + "), expected (" +
                    std::to_string(data.n_exposure) + ", 3, 3)";
            return false;
        }
    }

    // Hanatos adaptation. Both are optional: paper profiles carry neither.
    if (d.has("hanatos2025_adaptation_window_params"))
        json_to_vec(d.at("hanatos2025_adaptation_window_params"), data.adaptation_window_params);
    if (d.has("hanatos2025_adaptation_surface_params")) {
        size_t r = 0, c = 0;
        if (json_to_mat(d.at("hanatos2025_adaptation_surface_params"), data.adaptation_surface_params, r, c)) {
            data.adaptation_surface_rows = r;
            data.adaptation_surface_cols = c;
        }
    }
    if (!data.adaptation_window_params.empty() &&
        data.adaptation_window_params.size() != 4 && data.adaptation_window_params.size() != 8) {
        error = "profile '" + info.stock + "': the spectral bandpass window has " +
                std::to_string(data.adaptation_window_params.size()) + " parameters; erf4 wants 4 and logiflex8 wants 8";
        return false;
    }

    const Json& m = d.at("density_curves_model");
    if (m.is_object()) {
        data.model.model_type = str_or(m, "model_type", "cdfs");
        size_t r = 0, c = 0;
        if (json_to_mat(m.at("centers"), data.model.centers, r, c)) {
            data.model.n_channels = r;
            data.model.n_layers = c;
        }
        size_t r2 = 0, c2 = 0;
        if (!json_to_mat(m.at("amplitudes"), data.model.amplitudes, r2, c2) || r2 != r || c2 != c) {
            error = "profile '" + info.stock + "': density_curves_model.amplitudes does not match centers";
            return false;
        }
        if (!json_to_mat(m.at("sigmas"), data.model.sigmas, r2, c2) || r2 != r || c2 != c) {
            error = "profile '" + info.stock + "': density_curves_model.sigmas does not match centers";
            return false;
        }
    }

    // `density_curves - nanmin(density_curves, axis=0)`, and the nanmax of
    // that. Every stage that touches the curves starts from these.
    normalized_curves.assign(data.density_curves.size(), 0.0);
    for (int c = 0; c < 3; ++c) {
        density_min[c] = nanmin(data.density_curves.data() + c, data.n_exposure, 3);
        for (size_t k = 0; k < data.n_exposure; ++k)
            normalized_curves[3 * k + size_t(c)] = data.density_curves[3 * k + size_t(c)] - density_min[c];
        density_max[c] = nanmax(normalized_curves.data() + c, data.n_exposure, 3);
    }
    return true;
}

bool Profile::load(const std::string& path, std::string& error) {
    std::string text;
    if (!read_file(path, text, error)) return false;
    Json root;
    std::string parse_error;
    if (!Json::parse(text, root, parse_error)) { error = path + ": " + parse_error; return false; }
    return from_json(root, error);
}

bool load_profile(const std::string& resources_dir, const std::string& stock,
                  Profile& out, std::string& error) {
    // A stock name reaches here straight off the wire. Restricting it to the
    // characters a stock id actually uses is what stops `film_stock:
    // "../../etc/passwd"` from being a file read.
    if (stock.empty() || stock.size() > 96) { error = "bad stock name"; return false; }
    for (char c : stock) {
        const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                        (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!ok) { error = "bad stock name '" + stock + "'"; return false; }
    }
    if (!out.load(resources_dir + "/profiles/" + stock + ".json", error)) {
        error = "no profile '" + stock + "' (" + error + ")";
        return false;
    }
    return true;
}

}  // namespace spk
