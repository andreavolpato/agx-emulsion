// dump_json.cpp -- emit the JSON the engine would put on the wire, plus the
// digested internals a reply does not carry, so `parity_schema.py` can diff
// both against the Python service.
//
// Usage: dump_json <resources_dir>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

#include "json.hpp"
#include "params.hpp"

using namespace spk;

static Json vec3(const double v[3]) {
    Json j = Json::array();
    for (int i = 0; i < 3; ++i) j.push(Json(v[i]));
    return j;
}
static Json vec2(const double v[2]) {
    Json j = Json::array();
    for (int i = 0; i < 2; ++i) j.push(Json(v[i]));
    return j;
}

// The digested fields that never cross the wire but decide the picture. A
// stock-specific DIR-coupler gamma or a halation preset that silently differs
// from the reference is exactly the class of bug the wire cannot show.
static Json internals(const Params& p) {
    Json j = Json::object();
    j.set("dir_couplers.gamma_samelayer_rgb", vec3(p.film_render.dir_couplers.gamma_samelayer_rgb));
    j.set("dir_couplers.gamma_interlayer_r_to_gb", vec2(p.film_render.dir_couplers.gamma_interlayer_r_to_gb));
    j.set("dir_couplers.gamma_interlayer_g_to_rb", vec2(p.film_render.dir_couplers.gamma_interlayer_g_to_rb));
    j.set("dir_couplers.gamma_interlayer_b_to_rg", vec2(p.film_render.dir_couplers.gamma_interlayer_b_to_rg));
    j.set("halation.halation_first_sigma_um", vec3(p.film_render.halation.halation_first_sigma_um));
    j.set("halation.halation_strength", vec3(p.film_render.halation.halation_strength));
    j.set("grain.micro_structure", vec2(p.film_render.grain.micro_structure));
    j.set("scanner.unsharp_mask", vec2(p.scanner.unsharp_mask));
    j.set("enlarger.c_filter_neutral", Json(p.enlarger.c_filter_neutral));
    j.set("enlarger.m_filter_neutral", Json(p.enlarger.m_filter_neutral));
    j.set("enlarger.y_filter_neutral", Json(p.enlarger.y_filter_neutral));
    j.set("profile.film.type", Json(p.film.info.type));
    j.set("profile.film.use", Json(p.film.info.use));
    j.set("profile.film.antihalation", Json(p.film.info.antihalation));
    j.set("profile.film.reference_illuminant", Json(p.film.info.reference_illuminant));
    j.set("profile.print.viewing_illuminant", Json(p.print.info.viewing_illuminant));
    j.set("profile.film.density_min", vec3(p.film.density_min));
    j.set("profile.film.density_max", vec3(p.film.density_max));
    j.set("profile.print.density_min", vec3(p.print.density_min));
    j.set("profile.print.density_max", vec3(p.print.density_max));
    return j;
}

int main(int argc, char** argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: dump_json <resources_dir>\n"); return 1; }
    const std::string res = argv[1];

    std::string text, err;
    {
        std::ifstream in(res + "/neutral_print_filters.json", std::ios::binary);
        std::ostringstream ss;
        ss << in.rdbuf();
        text = ss.str();
    }
    Json filters;
    std::string parse_error;
    if (!text.empty() && !Json::parse(text, filters, parse_error)) {
        std::fprintf(stderr, "neutral_print_filters.json: %s\n", parse_error.c_str());
        return 1;
    }

    Json out = Json::object();
    out.set("schema", transport_schema());

    Json pairs = Json::object();
    const char* stocks[][2] = {
        {"kodak_portra_400", "kodak_portra_endura"},
        {"kodak_gold_200", "kodak_endura_premier"},
        {"fujifilm_velvia_100", "kodak_portra_endura"},
        {"fujifilm_provia_100f", "kodak_portra_endura"},
        {"kodak_ektachrome_100", "kodak_ektacolor_edge"},
        {"kodak_portra_800", "kodak_portra_endura"},
    };
    for (const auto& pair : stocks) {
        Params p;
        if (!init_params(res, pair[0], pair[1], filters, p, err)) {
            std::fprintf(stderr, "init_params(%s, %s): %s\n", pair[0], pair[1], err.c_str());
            return 1;
        }
        Json entry = Json::object();
        entry.set("params", read_params(p));
        entry.set("internals", internals(p));
        pairs.set(std::string(pair[0]) + "|" + pair[1], std::move(entry));
    }
    out.set("pairs", std::move(pairs));
    std::printf("%s\n", out.dump().c_str());
    return 0;
}
