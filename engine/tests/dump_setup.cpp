// dump_setup.cpp -- write every setup quantity the C++ engine derives, so
// `parity_setup.py` can hold each one against the Python reference.
//
// Usage: dump_setup <resources_dir> <out.dat> <out.idx>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "blob.hpp"
#include "cam16.hpp"
#include "curves.hpp"
#include "hanatos.hpp"
#include "params.hpp"
#include "printing.hpp"
#include "profile.hpp"
#include "colour.hpp"
#include "dump.hpp"
#include "numeric.hpp"
#include "spectral.hpp"

using namespace spk;

static void die(const std::string& msg) {
    std::fprintf(stderr, "dump_setup: %s\n", msg.c_str());
    std::exit(1);
}

int main(int argc, char** argv) {
    if (argc != 4) die("usage: dump_setup <resources_dir> <out.dat> <out.idx>");
    const std::string res = argv[1];
    std::string err;

    Blob blob;
    if (!blob.open(res + "/spektrafilm_constants.bin", err)) die(err);
    Colour colour;
    if (!colour.init(blob, err)) die(err);

    Dump d(argv[2], argv[3]);
    if (!d.ok()) die("cannot open the output files");

    // --- illuminants ------------------------------------------------------
    for (const char* name : {"D50", "D55", "D65", "D75", "E", "A", "T", "K75P",
                             "TH-KG3", "TH-KG3-L", "BB3400", "BB5500"}) {
        Vec v;
        if (!standard_illuminant(colour, blob, name, v, err)) die(err);
        d.add(std::string("illuminant/") + name, v);
        double xy[2];
        illuminant_to_xy(colour, v, xy);
        d.add(std::string("illuminant_xy/") + name, xy, 2);
    }

    // --- enlarger filters --------------------------------------------------
    Vec dichroics;
    custom_dichroic_filters(colour.wavelengths(), dichroics);
    d.add("dichroic/custom", dichroics);

    {
        Vec light;
        if (!standard_illuminant(colour, blob, "TH-KG3", light, err)) die(err);
        // The shipped neutral pack for kodak_portra_endura, and a shifted one:
        // `enlarger.{c,m,y}_filter_neutral` plus the two wire shifts.
        const double packs[3][3] = {{0.0, 65.0, 55.0}, {0.0, 65.9, 54.2}, {10.0, 0.0, 120.0}};
        for (int k = 0; k < 3; ++k) {
            Vec out;
            color_enlarger(light, dichroics, packs[k], out);
            d.add("enlarger/filtered_" + std::to_string(k), out);
        }
    }

    // --- camera band pass ---------------------------------------------------
    {
        // The default is amplitude 0 (inactive) -- which is exactly why the
        // *active* case is dumped too: an edge that is never exercised is an
        // edge that is wrong the first time someone turns it on.
        const double uv_off[3] = {0.0, 410.0, 8.0}, ir_off[3] = {0.0, 675.0, 15.0};
        const double uv_on[3] = {1.0, 410.0, 8.0}, ir_on[3] = {0.8, 675.0, 15.0};
        Vec bp;
        band_pass_filter(colour.wavelengths(), uv_off, ir_off, bp);
        d.add("bandpass/off", bp);
        band_pass_filter(colour.wavelengths(), uv_on, ir_on, bp);
        d.add("bandpass/on", bp);
    }

    // --- colour matrices ----------------------------------------------------
    {
        const char* spaces[] = {"sRGB", "ProPhoto RGB", "Display P3", "Adobe RGB (1998)",
                                "ACEScg", "ACES2065-1", "ITU-R BT.709", "ITU-R BT.2020"};
        const char* illuminants[] = {"D50", "D55", "D65"};
        double row[9];
        for (const char* cs : spaces) {
            Mat3 M;
            if (!colour.matrix_RGB_to_XYZ(cs, nullptr, "CAT02", M, err)) die(err);
            M.to_row_major(row);
            d.add(std::string("m_rgb_to_xyz/") + cs, row, 9);
            if (!colour.matrix_XYZ_to_RGB(cs, nullptr, "CAT02", M, err)) die(err);
            M.to_row_major(row);
            d.add(std::string("m_xyz_to_rgb/") + cs, row, 9);
            if (!colour.matrix_RGB_to_RGB(cs, cs, "CAT02", M, err)) die(err);
            M.to_row_major(row);
            d.add(std::string("m_rgb_to_rgb_same/") + cs, row, 9);
            for (const char* ill : illuminants) {
                Vec sd;
                if (!standard_illuminant(colour, blob, ill, sd, err)) die(err);
                double xy[2];
                illuminant_to_xy(colour, sd, xy);
                // CAT16 is what `fused_tc_b.tc_b_matrix` uses on the input
                // side; CAT02 is what `_xyz_to_rgb_matrix` uses on the output
                // side. Both are dumped because both are on the render path.
                if (!colour.matrix_RGB_to_XYZ(cs, xy, "CAT16", M, err)) die(err);
                M.to_row_major(row);
                d.add(std::string("m_rgb_to_xyz_cat16/") + cs + "/" + ill, row, 9);
                if (!colour.matrix_XYZ_to_RGB(cs, xy, "CAT02", M, err)) die(err);
                M.to_row_major(row);
                d.add(std::string("m_xyz_to_rgb_cat02/") + cs + "/" + ill, row, 9);
            }
        }
    }

    // --- transfer functions -------------------------------------------------
    {
        // A dense sweep including both sides of every breakpoint and negative
        // values, because `spow` keeping the sign there is the whole reason
        // the reference uses it.
        std::vector<double> xs;
        for (int i = 0; i <= 400; ++i) xs.push_back(-0.2 + 1.4 * double(i) / 400.0);
        for (double b : {0.0031308, 0.040449936, 0.018, 1.0 / 512.0, 16.0 / 512.0, 0.081})
            for (double eps : {-1e-9, 0.0, 1e-9}) xs.push_back(b + eps);
        d.add("cctf/x", xs);
        for (const char* cs : {"sRGB", "ProPhoto RGB", "Display P3", "Adobe RGB (1998)",
                               "ACEScg", "ITU-R BT.709", "ITU-R BT.2020"}) {
            std::vector<double> dec, enc;
            for (double x : xs) { dec.push_back(colour.cctf_decode(x, cs)); enc.push_back(colour.cctf_encode(x, cs)); }
            d.add(std::string("cctf_decode/") + cs, dec);
            d.add(std::string("cctf_encode/") + cs, enc);
        }
    }

    // --- per-stock setup: curves, couplers, the tc_lut ---------------------
    {
        std::string text;
        {
            std::ifstream in(res + "/neutral_print_filters.json", std::ios::binary);
            std::ostringstream ss;
            ss << in.rdbuf();
            text = ss.str();
        }
        Json filters;
        std::string parse_error;
        if (!text.empty() && !Json::parse(text, filters, parse_error)) die(parse_error);

        const char* stocks[][2] = {
            {"kodak_portra_400", "kodak_portra_endura"},
            {"fujifilm_velvia_100", "kodak_portra_endura"},
            {"kodak_gold_200", "kodak_endura_premier"},
        };
        for (const auto& pair : stocks) {
            Params params;
            if (!init_params(res, pair[0], pair[1], filters, params, err)) die(err);
            const std::string p = std::string("stock/") + pair[0] + "/";

            d.add(p + "normalized_curves", params.film.normalized_curves);
            d.add(p + "density_max", params.film.density_max, 3);

            const double gamma[3] = {params.film_render.density_curve_gamma,
                                     params.film_render.density_curve_gamma,
                                     params.film_render.density_curve_gamma};
            InterpTables tables;
            build_interp_tables(params.film.data.log_exposure, gamma, params.film.normalized_curves, tables);
            d.add(p + "curve_x", tables.x);
            d.add(p + "curve_inv", tables.inv);

            double matrix[9];
            dir_couplers_matrix(params.film_render.dir_couplers, matrix);
            d.add(p + "dir_matrix", matrix, 9);
            Vec curves0;
            density_curves_before_dir_couplers(params.film.normalized_curves,
                                               params.film.data.log_exposure, matrix,
                                               params.film.info.is_positive(), curves0);
            d.add(p + "curves_before_couplers", curves0);

            Vec morphed;
            if (!print_curves_morph(params.print.data.log_exposure, params.print.data.model,
                                    params.print_render.density_curves_morph,
                                    params.print.info.is_positive(), morphed, err)) die(err);
            d.add(p + "print_curves", morphed);

            // The morph itself, on a setting the wire cannot reach today --
            // an unreachable parameter is one that will be wrong the first
            // time it is wired up.
            PrintCurvesMorphParams morph;
            morph.active = true;
            morph.gamma_factor = 1.15;
            morph.gamma_factor_fast = 0.9;
            morph.gamma_factor_slow = 1.1;
            morph.gamma_factor_red = 1.05;
            morph.gamma_factor_blue = 0.95;
            Vec morphed2;
            if (!print_curves_morph(params.print.data.log_exposure, params.print.data.model,
                                    morph, params.print.info.is_positive(), morphed2, err)) die(err);
            d.add(p + "print_curves_morphed", morphed2);

            Vec sens;
            if (!film_sensitivity(colour, blob, params.film, params.camera, sens, err)) die(err);
            d.add(p + "sensitivity", sens);

            CameraParams filtered = params.camera;
            filtered.filter_uv[0] = 1.0;
            filtered.filter_ir[0] = 0.8;
            Vec sens_f;
            if (!film_sensitivity(colour, blob, params.film, filtered, sens_f, err)) die(err);
            d.add(p + "sensitivity_filtered", sens_f);

            Vec lut;
            size_t side = 0;
            if (!build_tc_lut(colour, blob, params.film, params.settings,
                              params.io.input_gamut_compress, sens, lut, side, err)) die(err);
            d.add("tc_lut/" + std::string(pair[0]), lut);

            SettingsParams no_window = params.settings;
            no_window.apply_hanatos2025_adaptation_window = false;
            GamutCompressSpec off;
            off.active = false;
            Vec lut_plain;
            if (!build_tc_lut(colour, blob, params.film, no_window, off, sens, lut_plain, side, err)) die(err);
            d.add("tc_lut/" + std::string(pair[0]) + "/plain", lut_plain);

            SettingsParams with_surface = params.settings;
            with_surface.apply_hanatos2025_adaptation_surface = true;
            Vec lut_surface;
            if (!build_tc_lut(colour, blob, params.film, with_surface, off, sens, lut_surface, side, err)) die(err);
            d.add("tc_lut/" + std::string(pair[0]) + "/surface", lut_surface);

            Mat3 m;
            if (!tc_b_matrix(colour, blob, params.io.input_color_space,
                             params.film.info.reference_illuminant, m, err)) die(err);
            double row[9];
            m.to_row_major(row);
            d.add(p + "tc_b_matrix", row, 9);

            // The enlarger's per-render constants. Every one of these was
            // computed privately inside the pipeline once, and one of them was
            // wrong by an amount that looked like a grading choice.
            PrintConstants pc;
            if (!print_constants(colour, blob, params, lut, side, pc, err)) die(err);
            const std::string pp = std::string("print/") + pair[0] + "|" + pair[1] + "/";
            d.add(pp + "illuminant", pc.print_illuminant);
            d.add(pp + "paper_sensitivity", pc.paper_sensitivity);
            d.add(pp + "chd", pc.spectral.channel_density);
            d.add(pp + "base", pc.spectral.base_density);
            d.add(pp + "ixs", pc.spectral.illum_x_sens);
            d.add(pp + "density_spectral_midgray", pc.density_spectral_midgray);
            d.add(pp + "gain", pc.gain, 3);
            d.add(pp + "offset", pc.offset, 3);
            d.add(pp + "log_raw_black", pc.log_raw_black, 3);
            d.add(pp + "log_raw_white", pc.log_raw_white, 3);

            // And with a filter shift and a preflash on, because both are
            // live-mutable and neither is exercised at the defaults.
            Params shifted = params;
            shifted.enlarger.m_filter_shift = 0.4;
            shifted.enlarger.y_filter_shift = -0.3;
            shifted.enlarger.preflash_exposure = 0.35;
            PrintConstants pc2;
            if (!print_constants(colour, blob, shifted, lut, side, pc2, err)) die(err);
            d.add(pp + "shifted_gain", pc2.gain, 3);
            d.add(pp + "shifted_offset", pc2.offset, 3);
            d.add(pp + "shifted_illuminant", pc2.print_illuminant);

            // The spectral integral's constants, for the scanner side.
            Vec illum;
            if (!standard_illuminant(colour, blob, params.print.info.viewing_illuminant, illum, err)) die(err);
            const Vec& cmfs = colour.cmfs_1931_2deg();
            double norm = 0.0;
            for (size_t i = 0; i < illum.size(); ++i) norm += illum[i] * cmfs[3 * i + 1];
            SpectralConstants sc;
            prepare_spectral_constants(params.print.data.channel_density, params.print.data.base_density,
                                       illum, cmfs, norm, sc);
            d.add("spectral_constants/" + std::string(pair[1]) + "/chd", sc.channel_density);
            d.add("spectral_constants/" + std::string(pair[1]) + "/base", sc.base_density);
            d.add("spectral_constants/" + std::string(pair[1]) + "/ixs", sc.illum_x_sens);
        }
    }

    // --- the spectral locus and the input xy compression --------------------
    {
        Vec locus;
        spectral_locus_xy(colour, locus);
        d.add("locus/xy", locus);

        Vec sd;
        if (!standard_illuminant(colour, blob, "D55", sd, err)) die(err);
        double white[2];
        illuminant_to_xy(colour, sd, white);
        std::vector<double> compressed;
        for (int i = 0; i < 64; ++i)
            for (int j = 0; j < 64; ++j) {
                const double xy[2] = {double(i) / 63.0 * 0.8, double(j) / 63.0 * 0.9};
                double out[2];
                compress_xy_radial(xy, white, locus, 0.0, 1.0, 6.0, out);
                compressed.push_back(out[0]);
                compressed.push_back(out[1]);
            }
        d.add("compress_xy/values", compressed);
    }

    // --- CAM16-UCS setup and the C_max table -------------------------------
    for (const char* cs : {"sRGB", "Display P3"}) {
        Cam16Setup st;
        if (!cam16_setup_for(colour, cs, st, err)) die(err);
        const std::string p = std::string("cam16/") + cs + "/";
        const double scalars[8] = {st.n, st.F_L, st.N_bb, st.N_cb, st.z, st.A_w, st.c, st.N_c};
        d.add(p + "scalars", scalars, 8);
        d.add(p + "D_rgb", st.D_rgb, 3);
        double row[9];
        st.m_to_xyz.to_row_major(row); d.add(p + "m_to_xyz", row, 9);
        st.m_to_rgb.to_row_major(row); d.add(p + "m_to_rgb", row, 9);
        d.add(p + "white_Jp", st.white_Jp);
        d.add(p + "l_grid", st.l_grid);
        d.add(p + "h_grid", st.h_grid);
        d.add("cmax/" + std::string(cs), st.c_max_table);

        // The forward and inverse on their own, over a sweep that reaches the
        // negative achromatic response the pipeline actually produces.
        std::vector<double> fwd, inv;
        for (int i = 0; i < 400; ++i) {
            const double t = double(i) / 399.0;
            const double rgb[3] = {-0.2 + 1.6 * t, 0.9 - 0.8 * t, 0.05 + 1.1 * t * t};
            double xyz[3], jab[3], back[3];
            st.m_to_xyz.apply(rgb, xyz);
            xyz_to_cam16ucs(st, xyz, jab);
            for (int k = 0; k < 3; ++k) fwd.push_back(jab[k]);
            cam16ucs_to_xyz(st, jab, back);
            for (int k = 0; k < 3; ++k) inv.push_back(back[k]);
        }
        d.add(p + "forward", fwd);
        d.add(p + "inverse", inv);
    }

    // --- the Reinhard knee ---------------------------------------------------
    {
        std::vector<double> knee;
        for (int i = 0; i <= 300; ++i) {
            const double x = 3.0 * double(i) / 300.0;
            knee.push_back(reinhard_knee(x, 0.0, 1.0, 6.0));
            knee.push_back(reinhard_knee(x, 0.7, 1.0, 2.2));
        }
        d.add("knee/values", knee);
    }

    std::fprintf(stderr, "dump_setup: ok\n");
    return 0;
}
