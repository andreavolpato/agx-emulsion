#include "params.hpp"

#include <cmath>
#include <cstring>
#include <fstream>
#include <sstream>
#include <unordered_map>

namespace spk {

namespace {

constexpr FieldType F = FieldType::Float;
constexpr FieldType B = FieldType::Bool;
constexpr FieldType S = FieldType::Str;
constexpr FieldType I = FieldType::Int;
constexpr Layer SHOOT = Layer::Shoot;
constexpr Layer PRINT = Layer::Print;

// service/schema.py::LIVE_MUTABLE -- deliberately short. API-SPEC §1 verified
// these three specifically; everything else gets a rebuild, which measured
// 18.8 ms against a 190 ms reprint, so the conservative default is nearly free.
bool is_live(const char* name) {
    return std::strcmp(name, "print_exposure") == 0 || std::strcmp(name, "m_filter_shift") == 0 ||
           std::strcmp(name, "y_filter_shift") == 0 || std::strcmp(name, "preflash_exposure") == 0;
}

const SchemaField kFields[] = {
    {"film_stock",               "film.info.stock",                       S, SHOOT, false, 0, 0, false},
    {"print_stock",              "print.info.stock",                      S, PRINT, false, 0, 0, false},
    {"exposure_compensation_ev", "camera.exposure_compensation_ev",       F, SHOOT, true, -8.0, 8.0, false},
    {"auto_exposure",            "camera.auto_exposure",                  B, SHOOT, false, 0, 0, false},
    {"film_format_mm",           "camera.film_format_mm",                 F, SHOOT, true, 4.0, 200.0, false},
    {"lens_blur_um",             "camera.lens_blur_um",                   F, SHOOT, true, 0.0, 200.0, false},
    {"halation_active",          "film_render.halation.active",           B, SHOOT, false, 0, 0, false},
    {"halation_amount",          "film_render.halation.halation_amount",  F, SHOOT, true, 0.0, 4.0, false},
    {"halation_boost_ev",        "film_render.halation.boost_ev",         F, SHOOT, true, 0.0, 8.0, false},
    {"grain_active",             "film_render.grain.active",              B, SHOOT, false, 0, 0, false},
    {"grain_sublayers_active",   "film_render.grain.sublayers_active",    B, SHOOT, false, 0, 0, false},
    {"dir_couplers_active",      "film_render.dir_couplers.active",       B, SHOOT, false, 0, 0, false},
    {"dir_couplers_amount",      "film_render.dir_couplers.amount",       F, SHOOT, true, 0.0, 4.0, false},
    {"density_curve_gamma",      "film_render.density_curve_gamma",       F, SHOOT, true, 0.2, 4.0, false},
    {"input_color_space",        "io.input_color_space",                  S, SHOOT, false, 0, 0, false},
    {"input_cctf_decoding",      "io.input_cctf_decoding",                B, SHOOT, false, 0, 0, false},
    {"geometry_crop_x",          "io.geometry.crop_x",                    F, SHOOT, true, 0.0, 1.0, false},
    {"geometry_crop_y",          "io.geometry.crop_y",                    F, SHOOT, true, 0.0, 1.0, false},
    {"geometry_crop_w",          "io.geometry.crop_w",                    F, SHOOT, true, 1e-4, 1.0, false},
    {"geometry_crop_h",          "io.geometry.crop_h",                    F, SHOOT, true, 1e-4, 1.0, false},
    {"geometry_rotation_deg",    "io.geometry.rotation_deg",              F, SHOOT, true, -45.0, 45.0, false},
    {"geometry_quarter_turns",   "io.geometry.quarter_turns",             I, SHOOT, true, 0, 3, false},
    {"geometry_flip_h",          "io.geometry.flip_h",                    B, SHOOT, false, 0, 0, false},
    {"geometry_flip_v",          "io.geometry.flip_v",                    B, SHOOT, false, 0, 0, false},
    {"print_exposure",           "enlarger.print_exposure",               F, PRINT, true, 0.05, 20.0, true},
    {"m_filter_shift",           "enlarger.m_filter_shift",               F, PRINT, true, -1.0, 1.0, true},
    {"y_filter_shift",           "enlarger.y_filter_shift",               F, PRINT, true, -1.0, 1.0, true},
    {"c_filter_neutral",         "enlarger.c_filter_neutral",             F, PRINT, true, 0.0, 200.0, false},
    {"m_filter_neutral",         "enlarger.m_filter_neutral",             F, PRINT, true, 0.0, 200.0, false},
    {"y_filter_neutral",         "enlarger.y_filter_neutral",             F, PRINT, true, 0.0, 200.0, false},
    {"preflash_exposure",        "enlarger.preflash_exposure",            F, PRINT, true, 0.0, 1.0, true},
    {"enlarger_illuminant",      "enlarger.illuminant",                   S, PRINT, false, 0, 0, false},
    {"glare_active",             "print_render.glare.active",             B, PRINT, false, 0, 0, false},
    {"scanner_white_correction", "scanner.white_correction",              B, PRINT, false, 0, 0, false},
    {"scanner_black_correction", "scanner.black_correction",              B, PRINT, false, 0, 0, false},
    {"scanner_lens_blur",        "scanner.lens_blur",                     F, PRINT, true, 0.0, 20.0, false},
    {"output_color_space",       "io.output_color_space",                 S, PRINT, false, 0, 0, false},
    {"output_cctf_encoding",     "io.output_cctf_encoding",               B, PRINT, false, 0, 0, false},
    {"scan_film",                "io.scan_film",                          B, PRINT, false, 0, 0, false},
};

const SchemaField* find_field(const std::string& name) {
    for (const SchemaField& f : kFields) if (name == f.name) return &f;
    return nullptr;
}

// --- the dotted-path binding -------------------------------------------
// One switch over the 39 declared paths, rather than reflection. It is more
// typing than a field-offset table and it is what makes `parity_schema.py`
// able to prove the two sides agree: a path this does not know is a build
// error here and a test failure there, never a silently ignored slider.

double* float_slot(Params& p, const std::string& path) {
    if (path == "camera.exposure_compensation_ev") return &p.camera.exposure_compensation_ev;
    if (path == "camera.film_format_mm") return &p.camera.film_format_mm;
    if (path == "camera.lens_blur_um") return &p.camera.lens_blur_um;
    if (path == "film_render.halation.halation_amount") return &p.film_render.halation.halation_amount;
    if (path == "film_render.halation.boost_ev") return &p.film_render.halation.boost_ev;
    if (path == "film_render.dir_couplers.amount") return &p.film_render.dir_couplers.amount;
    if (path == "film_render.density_curve_gamma") return &p.film_render.density_curve_gamma;
    if (path == "io.geometry.crop_x") return &p.io.geometry.crop_x;
    if (path == "io.geometry.crop_y") return &p.io.geometry.crop_y;
    if (path == "io.geometry.crop_w") return &p.io.geometry.crop_w;
    if (path == "io.geometry.crop_h") return &p.io.geometry.crop_h;
    if (path == "io.geometry.rotation_deg") return &p.io.geometry.rotation_deg;
    if (path == "enlarger.print_exposure") return &p.enlarger.print_exposure;
    if (path == "enlarger.m_filter_shift") return &p.enlarger.m_filter_shift;
    if (path == "enlarger.y_filter_shift") return &p.enlarger.y_filter_shift;
    if (path == "enlarger.c_filter_neutral") return &p.enlarger.c_filter_neutral;
    if (path == "enlarger.m_filter_neutral") return &p.enlarger.m_filter_neutral;
    if (path == "enlarger.y_filter_neutral") return &p.enlarger.y_filter_neutral;
    if (path == "enlarger.preflash_exposure") return &p.enlarger.preflash_exposure;
    if (path == "scanner.lens_blur") return &p.scanner.lens_blur;
    return nullptr;
}

bool* bool_slot(Params& p, const std::string& path) {
    if (path == "camera.auto_exposure") return &p.camera.auto_exposure;
    if (path == "film_render.halation.active") return &p.film_render.halation.active;
    if (path == "film_render.grain.active") return &p.film_render.grain.active;
    if (path == "film_render.grain.sublayers_active") return &p.film_render.grain.sublayers_active;
    if (path == "film_render.dir_couplers.active") return &p.film_render.dir_couplers.active;
    if (path == "io.input_cctf_decoding") return &p.io.input_cctf_decoding;
    if (path == "io.geometry.flip_h") return &p.io.geometry.flip_h;
    if (path == "io.geometry.flip_v") return &p.io.geometry.flip_v;
    if (path == "print_render.glare.active") return &p.print_render.glare.active;
    if (path == "scanner.white_correction") return &p.scanner.white_correction;
    if (path == "scanner.black_correction") return &p.scanner.black_correction;
    if (path == "io.output_cctf_encoding") return &p.io.output_cctf_encoding;
    if (path == "io.scan_film") return &p.io.scan_film;
    return nullptr;
}

std::string* str_slot(Params& p, const std::string& path) {
    if (path == "film.info.stock") return &p.film_stock;
    if (path == "print.info.stock") return &p.print_stock;
    if (path == "io.input_color_space") return &p.io.input_color_space;
    if (path == "enlarger.illuminant") return &p.enlarger.illuminant;
    if (path == "io.output_color_space") return &p.io.output_color_space;
    return nullptr;
}

int* int_slot(Params& p, const std::string& path) {
    if (path == "io.geometry.quarter_turns") return &p.io.geometry.quarter_turns;
    return nullptr;
}

const char* type_name(FieldType t) {
    switch (t) {
        case FieldType::Float: return "float";
        case FieldType::Bool: return "bool";
        case FieldType::Str: return "str";
        case FieldType::Int: return "int";
    }
    return "?";
}

}  // namespace

const std::vector<SchemaField>& schema_fields() {
    static const std::vector<SchemaField> v(std::begin(kFields), std::end(kFields));
    return v;
}

Json transport_schema() {
    // A default tree, so the schema's default annotation *is* the engine's
    // default rather than being re-decided here (API-SPEC §4).
    Params defaults;
    Json fields = Json::array();
    for (const SchemaField& f : kFields) {
        Json entry = Json::object();
        entry.set("name", Json(std::string(f.name)));
        entry.set("path", Json(std::string(f.path)));
        entry.set("type", Json(std::string(type_name(f.type))));
        entry.set("layer", Json(std::string(f.layer == Layer::Shoot ? "shoot" : "print")));
        switch (f.type) {
            case FieldType::Float: entry.set("default", Json(*float_slot(defaults, f.path))); break;
            case FieldType::Bool: entry.set("default", Json(*bool_slot(defaults, f.path))); break;
            case FieldType::Str: entry.set("default", Json(*str_slot(defaults, f.path))); break;
            case FieldType::Int: entry.set("default", Json(double(*int_slot(defaults, f.path)))); break;
        }
        entry.set("live", Json(is_live(f.name)));
        if (f.has_range) {
            Json r = Json::array();
            r.push(Json(f.lo));
            r.push(Json(f.hi));
            entry.set("range", std::move(r));
        }
        fields.push(std::move(entry));
    }
    Json out = Json::object();
    out.set("schema_version", Json(double(1)));
    out.set("fields", std::move(fields));
    return out;
}

bool validate_delta(const Json& delta, std::string& error, std::string& param) {
    if (!delta.is_object()) { error = "params_delta must be an object"; param.clear(); return false; }
    for (const auto& kv : delta.fields()) {
        const SchemaField* f = find_field(kv.first);
        if (!f) { error = "unknown parameter '" + kv.first + "'"; param = kv.first; return false; }
        const Json& v = kv.second;
        // A JSON bool is not a number, and the reference rejects it explicitly
        // for a float field rather than letting `true` become 1.0.
        const bool wrong =
            (f->type == FieldType::Float && !v.is_number()) ||
            (f->type == FieldType::Int && !v.is_number()) ||
            (f->type == FieldType::Bool && !v.is_bool()) ||
            (f->type == FieldType::Str && !v.is_string());
        if (wrong) {
            error = "'" + kv.first + "' expects " + type_name(f->type);
            param = kv.first;
            return false;
        }
        if (f->has_range) {
            const double d = v.as_double();
            if (!(d >= f->lo && d <= f->hi)) {
                error = "'" + kv.first + "'=" + std::to_string(d) + " is outside [" +
                        std::to_string(f->lo) + ", " + std::to_string(f->hi) + "]";
                param = kv.first;
                return false;
            }
        }
    }
    return true;
}

bool delta_needs_rebuild(const Json& delta) {
    for (const auto& kv : delta.fields()) if (!is_live(kv.first.c_str())) return true;
    return false;
}

bool delta_touches_shoot(const Json& delta) {
    for (const auto& kv : delta.fields()) {
        const SchemaField* f = find_field(kv.first);
        if (f && f->layer == Layer::Shoot) return true;
    }
    return false;
}

void apply_delta(Params& params, const Json& delta) {
    for (const auto& kv : delta.fields()) {
        const SchemaField* f = find_field(kv.first);
        if (!f) continue;
        if (kv.first == "film_stock" || kv.first == "print_stock") continue;  // the caller loads profiles
        switch (f->type) {
            case FieldType::Float: if (double* s = float_slot(params, f->path)) *s = kv.second.as_double(); break;
            case FieldType::Bool: if (bool* s = bool_slot(params, f->path)) *s = kv.second.as_bool(); break;
            case FieldType::Str: if (std::string* s = str_slot(params, f->path)) *s = kv.second.as_string(); break;
            case FieldType::Int: if (int* s = int_slot(params, f->path)) *s = kv.second.as_int(); break;
        }
    }
}

Json read_params(const Params& params) {
    Params& p = const_cast<Params&>(params);   // the slot lookups are read-only here
    Json out = Json::object();
    for (const SchemaField& f : kFields) {
        switch (f.type) {
            case FieldType::Float: out.set(f.name, Json(*float_slot(p, f.path))); break;
            case FieldType::Bool: out.set(f.name, Json(*bool_slot(p, f.path))); break;
            case FieldType::Str: out.set(f.name, Json(*str_slot(p, f.path))); break;
            case FieldType::Int: out.set(f.name, Json(double(*int_slot(p, f.path)))); break;
        }
    }
    return out;
}

// --- digest ------------------------------------------------------------

namespace {

void set3(double dst[3], double a, double b, double c) { dst[0] = a; dst[1] = b; dst[2] = c; }
void set2(double dst[2], double a, double b) { dst[0] = a; dst[1] = b; }

// `params_builder._HALATION_PRESETS`, keyed by (use, antihalation). sigma_h is
// set by the base material and halation_strength by the antihalation layer;
// the user-facing amounts stay at 1.0 on top.
void apply_halation_preset(Params& p) {
    if (p.film.info.support != "film") return;
    const std::string& use = p.film.info.use;
    const std::string& ah = p.film.info.antihalation;
    const double sigma = use == "cine" ? 50.0 : 65.0;
    double s0, s1, s2;
    if (ah == "strong") { s0 = 0.015; s1 = 0.005; s2 = 0.0; }
    else if (ah == "weak") { s0 = 0.08; s1 = 0.02; s2 = 0.0; }
    else if (ah == "no") { s0 = 0.30; s1 = 0.10; s2 = 0.015; }
    else return;   // an unknown tag leaves the defaults, as the dict lookup does
    if (use != "still" && use != "cine") return;
    set3(p.film_render.halation.halation_first_sigma_um, sigma, sigma, sigma);
    set3(p.film_render.halation.halation_strength, s0, s1, s2);
}

void apply_film_specifics(Params& p) {
    DirCouplersParams& dc = p.film_render.dir_couplers;
    if (p.film.info.is_positive()) {
        set3(dc.gamma_samelayer_rgb, 0.12, 0.08, 0.06);
        set2(dc.gamma_interlayer_r_to_gb, 0.12, 0.06);
        set2(dc.gamma_interlayer_g_to_rb, 0.08, 0.06);
        set2(dc.gamma_interlayer_b_to_rg, 0.06, 0.06);
    } else {
        set3(dc.gamma_samelayer_rgb, 0.336, 0.319, 0.273);
        set2(dc.gamma_interlayer_r_to_gb, 0.353, 0.302);
        set2(dc.gamma_interlayer_g_to_rb, 0.154, 0.353);
        set2(dc.gamma_interlayer_b_to_rg, 0.168, 0.226);
    }
    apply_halation_preset(p);
    if (p.film.info.stock == "fujifilm_velvia_100") {
        set3(dc.gamma_samelayer_rgb, 0.108, 0.072, 0.054);
        set2(dc.gamma_interlayer_r_to_gb, 0.108, 0.054);
        set2(dc.gamma_interlayer_g_to_rb, 0.072, 0.054);
        set2(dc.gamma_interlayer_b_to_rg, 0.054, 0.054);
    } else if (p.film.info.stock == "fujifilm_provia_100f") {
        set3(dc.gamma_samelayer_rgb, 0.156, 0.104, 0.078);
        set2(dc.gamma_interlayer_r_to_gb, 0.156, 0.078);
        set2(dc.gamma_interlayer_g_to_rb, 0.104, 0.078);
        set2(dc.gamma_interlayer_b_to_rg, 0.078, 0.078);
    }
}

}  // namespace

bool digest(Params& p, const Json& neutral_filters, std::string& error) {
    (void)error;
    // `apply_database_neutral_print_filters`: print stock -> illuminant ->
    // film stock -> (c, m, y). A missing entry leaves the defaults, which is
    // what the reference does after printing a warning.
    if (p.settings.neutral_print_filters_from_database) {
        const Json& row = neutral_filters.at(p.print.info.stock)
                                          .at(p.enlarger.illuminant)
                                          .at(p.film.info.stock);
        if (row.is_array() && row.items().size() == 3) {
            p.enlarger.c_filter_neutral = row.items()[0].as_double();
            p.enlarger.m_filter_neutral = row.items()[1].as_double();
            p.enlarger.y_filter_neutral = row.items()[2].as_double();
        }
    }

    if (p.settings.preview_mode) {
        p.enlarger.lens_blur = 0.0;
        p.film_render.dir_couplers.diffusion_size_um = 0.0;
        p.film_render.grain.active = false;
        p.film_render.grain.particle_area_um2 = 0.0;
        p.film_render.grain.blur = 0.0;
        p.print_render.glare.blur = 0.0;
        p.camera.lens_blur_um = 0.0;
        p.scanner.lens_blur = 0.0;
        set2(p.scanner.unsharp_mask, 0.0, 0.0);
    }

    apply_film_specifics(p);

    if (p.debug.lut_mode) {
        p.debug.deactivate_spatial_effects = true;
        p.debug.deactivate_stochastic_effects = true;
        p.camera.auto_exposure = false;
        p.camera.exposure_compensation_ev = 0.0;
        p.enlarger.print_exposure_compensation = false;
        p.enlarger.print_exposure = 1.0;
        p.film_render.halation.boost_ev = 0.0;
        p.scanner.white_correction = false;
        p.scanner.black_correction = false;
        set2(p.scanner.unsharp_mask, 0.0, 0.0);
    }

    if (p.debug.deactivate_spatial_effects) {
        p.film_render.halation.active = false;
        set3(p.film_render.halation.scatter_core_um, 0.0, 0.0, 0.0);
        set3(p.film_render.halation.scatter_tail_um, 0.0, 0.0, 0.0);
        set3(p.film_render.halation.halation_first_sigma_um, 0.0, 0.0, 0.0);
        p.film_render.dir_couplers.diffusion_size_um = 0.0;
        p.film_render.grain.blur = 0.0;
        p.film_render.grain.blur_dye_clouds_um = 0.0;
        // Only the blur half of micro_structure is spatial; [1] is the field's
        // sigma in nm and is not this flag's to touch.
        p.film_render.grain.micro_structure[0] = 0.0;
        p.print_render.glare.blur = 0.0;
        p.camera.lens_blur_um = 0.0;
        p.enlarger.lens_blur = 0.0;
        p.enlarger.diffusion_filter.active = false;
        p.camera.diffusion_filter.active = false;
        p.scanner.lens_blur = 0.0;
        set2(p.scanner.unsharp_mask, 0.0, 0.0);
    }

    if (p.debug.deactivate_stochastic_effects) {
        p.film_render.grain.active = false;
        p.print_render.glare.active = false;
    }
    return true;
}

bool init_params(const std::string& resources_dir, const std::string& film_stock,
                 const std::string& print_stock, const Json& neutral_filters,
                 Params& out, std::string& error) {
    if (!load_profile(resources_dir, film_stock, out.film, error)) return false;
    if (!load_profile(resources_dir, print_stock, out.print, error)) return false;
    out.film_stock = out.film.info.stock.empty() ? film_stock : out.film.info.stock;
    out.print_stock = out.print.info.stock.empty() ? print_stock : out.print.info.stock;
    return digest(out, neutral_filters, error);
}

}  // namespace spk
