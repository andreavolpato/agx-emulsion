#include "pipeline.hpp"

#include <chrono>
#include <cmath>
#include <cstring>

namespace spk {

namespace {

constexpr double kMidgray = 0.184;
// RFC-015 §2.3's four intents. `s_hi` and `s_lo` are how far past mid-grey a
// frame may sit before the protect modes act; §2.4 would take them from the
// stock's own shoulder and toe, which needs a calibration set this RFC does
// not have, so v1 uses fixed stops.
constexpr double kProtectHighlightsStops = 2.5;
constexpr double kProtectShadowsStops = 3.5;
constexpr double kProtectHighlightsClampEv = 3.0;   // EV_h is at least EV_b - 3
constexpr double kProtectShadowsClampEv = 2.0;      // EV_s is at most EV_b + 2
// The floor under the sample before any logarithm: twelve stops below
// mid-grey, which no real frame's shadow is and every black border is.
constexpr double kMeterFloor = kMidgray / 4096.0;
// `model/grain.MIN_EFFECTIVE_BLUR_SIGMA` -- a Gaussian narrower than this is
// numerically the identity, so the pass is skipped rather than paid for.
constexpr double kMinEffectiveBlurSigma = 0.4;

void fill3(double dst[3], double v) { dst[0] = dst[1] = dst[2] = v; }

// --- the two matrix conventions the kernels use, named so they cannot be
// confused again.
//
// The transferred MSL kernels do not agree with each other, and both spellings
// are correct for the Python call site each came from:
//
//   `spk_tc_b`, `spk_cam16ucs_compress`   out[i] = sum_j m[3i + j] * x[j]
//        -- plain row-major M. Their Python callers pass a matrix that has
//           already been transposed once (`tc_b_matrix` returns
//           `RGB_to_XYZ(eye).T`), so what arrives is plain M.
//
//   `spk_matmul3`, `spk_cctf_encode_matrix`   out[i] = sum_j m[3j + i] * x[j]
//        -- M **transposed**. Their Python callers pass `XYZ_to_RGB(eye)` and
//           `RGB_to_RGB(eye, cs, cs)` straight through, and evaluating those
//           on the identity yields M.T, not M.
//
// Getting this wrong is not a crash and not obviously wrong on screen: it
// shifted the red channel's mean by +0.14 and the blue's by -0.08, which looks
// like a grading decision. Hence two named helpers instead of a comment.
void row_major(const Mat3& m, double out[9]) { m.to_row_major(out); }
void transposed(const Mat3& m, double out[9]) { m.transposed().to_row_major(out); }

// The (K, 3) axis and its reciprocal steps, for an axis that is *not* a scaled
// log-exposure -- grain's density axis. `interp_tables`'s `1/dx` with 0 where
// the axis repeats, which is what `fast_interp` does.
void axis_and_inv(const Vec& axis, size_t k, Vec& inv) {
    inv.assign((k - 1) * 3, 0.0);
    for (size_t i = 0; i + 1 < k; ++i)
        for (int c = 0; c < 3; ++c) {
            const double dx = axis[3 * (i + 1) + size_t(c)] - axis[3 * i + size_t(c)];
            inv[3 * i + size_t(c)] = dx != 0.0 ? 1.0 / dx : 0.0;
        }
}

}  // namespace

// A node's timing, recorded under the reference's label so a per-node
// regression is attributable to the same name on both engines.
struct Pipeline::Timer {
    Timer(Pipeline* p, const char* label) : p_(p), label_(label) {
        if (p_->progress_) {
            p_->progress_->stage = label_;
            if (p_->progress_->detailed) start_ = std::chrono::steady_clock::now();
        }
    }
    ~Timer() {
        if (!p_->progress_) return;
        if (p_->progress_->detailed) {
            // Wait for the work this node encoded, so the number is GPU time
            // and not encode time. Costs the batching for the whole run.
            std::string error;
            p_->gpu_->flush(error);
            const double ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start_).count();
            p_->progress_->node_ms[label_] += ms;
        }
        p_->progress_->fired += 1;
    }
    Pipeline* p_;
    const char* label_;
    std::chrono::steady_clock::time_point start_;
};


uint32_t Pipeline::fresh_seed() {
    // splitmix64, so the stochastic grain sampler gets a fresh realisation per
    // render without pulling in a platform RNG. The seeded sampler
    // (`grain_sampler = "exact"`) does not come through here at all.
    rng_state_ += 0x9E3779B97F4A7C15ull;
    uint64_t z = rng_state_;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z = z ^ (z >> 31);
    return uint32_t(z & 0xFFFFFFFFu);
}

void Pipeline::set_source_long_edge(uint32_t long_edge) {
    if (long_edge == 0) return;
    source_long_edge_ = long_edge;
    pixel_size_um_ = params_.camera.film_format_mm * 1000.0 / double(long_edge);
}

bool Pipeline::alloc_like(const Image& img, Image& out, std::string& error) {
    out.h = img.h; out.w = img.w; out.c = img.c;
    out.buf = gpu_->alloc(img.bytes(), error);
    return static_cast<bool>(out.buf);
}

// ---------------------------------------------------------------------------
// build
// ---------------------------------------------------------------------------

bool Pipeline::build(const Params& params, std::string& error) {
    params_ = params;
    const Profile& film = params_.film;
    const Profile& print = params_.print;

    // Configurations this build does not implement. The Python core could
    // return None from a node body and let the dispatcher run the numba
    // reference; there is no reference here, so an unsupported configuration
    // must be refused loudly rather than silently rendered differently.
    if (params_.settings.rgb_to_raw_method != "hanatos2025") {
        error = "rgb_to_raw_method '" + params_.settings.rgb_to_raw_method +
                "' is not implemented by the native engine (only hanatos2025)";
        return false;
    }
    if (params_.settings.use_enlarger_lut || params_.settings.use_scanner_lut) {
        error = "the enlarger/scanner LUT approximations are not implemented by the native "
                "engine; it always evaluates the exact spectral integral";
        return false;
    }
    if (params_.camera.diffusion_filter.active || params_.enlarger.diffusion_filter.active) {
        error = "diffusion filters are not implemented by the native engine";
        return false;
    }
    if (params_.io.crop || params_.io.upscale_factor != 1.0) {
        error = "the legacy io.crop / io.upscale_factor path is not implemented by the native "
                "engine; use io.geometry";
        return false;
    }
    if (params_.settings.grain_sampler != "exact" && params_.settings.grain_sampler != "stochastic") {
        error = "grain_sampler '" + params_.settings.grain_sampler + "' is not implemented "
                "by the native engine (only exact and stochastic)";
        return false;
    }
    if (!colour_->known_cctf(params_.io.output_color_space) ||
        !colour_->has_colourspace(params_.io.output_color_space)) {
        error = "output colour space '" + params_.io.output_color_space + "' is not baked into "
                "this build";
        return false;
    }
    if (!colour_->has_colourspace(params_.io.input_color_space)) {
        error = "input colour space '" + params_.io.input_color_space + "' is not baked into "
                "this build";
        return false;
    }

    // --- the transfer-function modes, as `shaders/nodes.metal` numbers them
    auto cctf_mode = [](const std::string& cs) -> uint32_t {
        if (cs == "sRGB" || cs == "Display P3") return 0;
        if (cs == "ProPhoto RGB") return 1;
        if (cs == "Adobe RGB (1998)") return 2;
        if (cs == "ITU-R BT.709" || cs == "ITU-R BT.2020") return 3;
        return 4;
    };
    input_cctf_mode_ = cctf_mode(params_.io.input_color_space);
    output_cctf_mode_ = cctf_mode(params_.io.output_color_space);

    // --- the spectral upsampling LUT -------------------------------------
    if (!film_sensitivity(*colour_, *blob_, film, params_.camera, film_sensitivity_, error)) return false;
    {
        const Vec* lut = nullptr;
        size_t side = 0;
        if (!cache_->tc_lut(*colour_, *blob_, film, params_.settings,
                            params_.io.input_gamut_compress, film_sensitivity_, lut, side, error))
            return false;
        baked_.tc_lut_side = side;
        baked_.tc_lut = gpu_->upload_persistent_f32(lut->data(), lut->size(), error);
        if (!baked_.tc_lut) return false;
        tc_lut_host_ = *lut;
    }
    {
        Mat3 m;
        if (!tc_b_matrix(*colour_, *blob_, params_.io.input_color_space,
                         film.info.reference_illuminant, m, error)) return false;
        tc_b_host_ = m;
        double row[9];
        row_major(m, row);   // spk_tc_b's convention
        baked_.tc_b_matrix = gpu_->upload_persistent_f32(row, 9, error);
        if (!baked_.tc_b_matrix) return false;
    }
    // The auto-exposure meter's luminance: `RGB_to_XYZ(image, cs)` with no
    // illuminant adaptation, exactly as `autoexposure._luminance_y` calls it.
    if (!colour_->matrix_RGB_to_XYZ(params_.io.input_color_space, nullptr, "CAT02",
                                    rgb_to_xyz_ae_, error)) return false;

    // --- film density curves ---------------------------------------------
    const size_t k = film.data.n_exposure;
    double gamma[3];
    fill3(gamma, params_.film_render.density_curve_gamma);
    {
        InterpTables t;
        build_interp_tables(film.data.log_exposure, gamma, film.normalized_curves, t);
        baked_.film_curve_k = t.k;
        baked_.film_curve_x = gpu_->upload_persistent_f32(t.x.data(), t.x.size(), error);
        baked_.film_curve_inv = gpu_->upload_persistent_f32(t.inv.data(), t.inv.size(), error);
        baked_.film_curve_y = gpu_->upload_persistent_f32(t.y.data(), t.y.size(), error);
        if (!baked_.film_curve_x || !baked_.film_curve_inv || !baked_.film_curve_y) return false;
    }

    // --- DIR couplers -----------------------------------------------------
    if (params_.film_render.dir_couplers.active) {
        double matrix[9];
        dir_couplers_matrix(params_.film_render.dir_couplers, matrix);
        Vec curves0;
        density_curves_before_dir_couplers(film.normalized_curves, film.data.log_exposure, matrix,
                                           film.info.is_positive(), curves0);
        InterpTables t;
        build_interp_tables(film.data.log_exposure, gamma, curves0, t);
        baked_.coupler_curve_x = gpu_->upload_persistent_f32(t.x.data(), t.x.size(), error);
        baked_.coupler_curve_inv = gpu_->upload_persistent_f32(t.inv.data(), t.inv.size(), error);
        baked_.coupler_curve_y = gpu_->upload_persistent_f32(t.y.data(), t.y.size(), error);
        baked_.coupler_matrix = gpu_->upload_persistent_f32(matrix, 9, error);
        baked_.coupler_dmax = gpu_->upload_persistent_f32(film.density_max, 3, error);
        const double shift[1] = {0.0};   // high_exposure_couplers_shift, unused today
        baked_.coupler_shift = gpu_->upload_persistent_f32(shift, 1, error);
        if (!baked_.coupler_curve_x || !baked_.coupler_matrix || !baked_.coupler_dmax ||
            !baked_.coupler_shift) return false;
    }

    // --- grain -------------------------------------------------------------
    if (params_.film_render.grain.active && params_.film_render.grain.sublayers_active) {
        if (film.data.density_curves_layers.empty()) {
            error = "film profile '" + film.info.stock + "' has no density_curves_layers, which "
                    "the sub-layer grain model needs";
            return false;
        }
        // The axis is the normalised curve itself, negated for positive film
        // because the reference negates both the axis and the query to keep
        // `np.interp`'s increasing-x requirement.
        Vec axis = film.normalized_curves;
        if (film.info.is_positive()) for (double& v : axis) v = -v;
        Vec inv;
        axis_and_inv(axis, k, inv);
        // ylay[k][ch * 3 + sl] from density_curves_layers[k][sl][ch].
        Vec ylay(k * 9, 0.0);
        for (size_t i = 0; i < k; ++i)
            for (size_t sl = 0; sl < 3; ++sl)
                for (size_t ch = 0; ch < 3; ++ch)
                    ylay[i * 9 + ch * 3 + sl] = film.data.density_curves_layers[i * 9 + sl * 3 + ch];
        baked_.grain_xa = gpu_->upload_persistent_f32(axis.data(), axis.size(), error);
        baked_.grain_inv = gpu_->upload_persistent_f32(inv.data(), inv.size(), error);
        baked_.grain_ylay = gpu_->upload_persistent_f32(ylay.data(), ylay.size(), error);
        uint32_t streams[9];
        const uint32_t base_seed[3] = {0, 1, 2};
        for (uint32_t ch = 0; ch < 3; ++ch)
            for (uint32_t sl = 0; sl < 3; ++sl) streams[ch * 3 + sl] = base_seed[ch] + sl * 10;
        baked_.grain_streams = gpu_->upload_persistent_u32(streams, 9, error);
        if (!baked_.grain_xa || !baked_.grain_inv || !baked_.grain_ylay || !baked_.grain_streams)
            return false;
    }

    // --- print curves -------------------------------------------------------
    if (!params_.io.scan_film) {
        Vec morphed;
        if (!print_curves_morph(print.data.log_exposure, print.data.model,
                                params_.print_render.density_curves_morph,
                                print.info.is_positive(), morphed, error)) return false;
        double one[3];
        fill3(one, 1.0);
        InterpTables t;
        build_interp_tables(print.data.log_exposure, one, morphed, t);
        baked_.print_curve_k = t.k;
        baked_.print_curve_x = gpu_->upload_persistent_f32(t.x.data(), t.x.size(), error);
        baked_.print_curve_inv = gpu_->upload_persistent_f32(t.inv.data(), t.inv.size(), error);
        baked_.print_curve_y = gpu_->upload_persistent_f32(t.y.data(), t.y.size(), error);
        if (!baked_.print_curve_x || !baked_.print_curve_inv || !baked_.print_curve_y) return false;
    }

    // --- the scanner's spectral integral and its illuminant ----------------
    {
        const Profile& scanned = params_.io.scan_film ? film : print;
        const std::string illum_name = params_.io.scan_film ? film.info.viewing_illuminant
                                                            : print.info.viewing_illuminant;
        Vec illum;
        if (!standard_illuminant(*colour_, *blob_, illum_name, illum, error)) return false;
        const Vec& cmfs = colour_->cmfs_1931_2deg();
        double norm = 0.0;
        for (size_t i = 0; i < illum.size(); ++i) norm += illum[i] * cmfs[3 * i + 1];
        SpectralConstants sc;
        prepare_spectral_constants(scanned.data.channel_density, scanned.data.base_density,
                                   illum, cmfs, norm, sc);
        baked_.scan_chd = gpu_->upload_persistent_f32(sc.channel_density.data(), sc.channel_density.size(), error);
        baked_.scan_base = gpu_->upload_persistent_f32(sc.base_density.data(), sc.base_density.size(), error);
        baked_.scan_ixs = gpu_->upload_persistent_f32(sc.illum_x_sens.data(), sc.illum_x_sens.size(), error);
        if (!baked_.scan_chd || !baked_.scan_base || !baked_.scan_ixs) return false;

        // The glare's tint is the viewing illuminant's own XYZ.
        double illum_xyz[3] = {0, 0, 0};
        for (size_t i = 0; i < illum.size(); ++i)
            for (int c = 0; c < 3; ++c) illum_xyz[c] += illum[i] * cmfs[3 * i + size_t(c)];
        for (int c = 0; c < 3; ++c) illum_xyz[c] /= norm;
        baked_.glare_illuminant = gpu_->upload_persistent_f32(illum_xyz, 3, error);
        if (!baked_.glare_illuminant) return false;

        // XYZ -> RGB, adapted to the scan illuminant, evaluated once.
        double illum_xy[2];
        Colour::XYZ_to_xy(illum_xyz, illum_xy);
        Mat3 m;
        if (!colour_->matrix_XYZ_to_RGB(params_.io.output_color_space, illum_xy, "CAT02", m, error))
            return false;
        double row[9];
        transposed(m, row);   // spk_matmul3's convention
        baked_.xyz_to_rgb = gpu_->upload_persistent_f32(row, 9, error);
        if (!baked_.xyz_to_rgb) return false;
    }

    // --- the output transfer function's near-identity matrix ---------------
    {
        Mat3 m;
        if (!colour_->matrix_RGB_to_RGB(params_.io.output_color_space, params_.io.output_color_space,
                                        "", m, error)) return false;
        double row[9];
        transposed(m, row);   // spk_cctf_encode_matrix's convention
        baked_.output_matrix = gpu_->upload_persistent_f32(row, 9, error);
        if (!baked_.output_matrix) return false;
    }

    // --- CAM16-UCS ---------------------------------------------------------
    const GamutCompressSpec& og = params_.io.output_gamut_compress;
    if (og.algorithm != "off") {
        if (og.algorithm != "cam16ucs") {
            error = "output gamut compression '" + og.algorithm + "' is not implemented by the "
                    "native engine (only cam16ucs and off)";
            return false;
        }
        const Cam16Setup* cached = nullptr;
        if (!cache_->cam16(*colour_, params_.io.output_color_space, cached, error)) return false;
        cam16_ = *cached;
        double m2x[9], m2r[9];
        row_major(cam16_.m_to_xyz, m2x);   // spk_cam16ucs_compress's convention
        row_major(cam16_.m_to_rgb, m2r);
        baked_.cam16_m2x = gpu_->upload_persistent_f32(m2x, 9, error);
        baked_.cam16_m2r = gpu_->upload_persistent_f32(m2r, 9, error);
        baked_.cam16_cmax = gpu_->upload_persistent_f32(cam16_.c_max_table.data(),
                                                        cam16_.c_max_table.size(), error);
        baked_.cam16_nl = cam16_.l_grid.size();
        baked_.cam16_nh = cam16_.h_grid.size();
        baked_.cam16_lightness = og.lightness_compression_active;
        const double consts[22] = {
            cam16_.F_L, cam16_.N_bb, cam16_.N_cb, cam16_.n, cam16_.z, cam16_.A_w, cam16_.c, cam16_.N_c,
            cam16_.l_grid.front(), cam16_.l_grid.back(),
            cam16_.h_grid.front(), cam16_.h_grid[1] - cam16_.h_grid[0],
            og.knee[0], og.knee[1], og.knee[2],
            og.lightness_compression_active ? og.lightness_compression[0] : 0.0,
            og.lightness_compression_active ? og.lightness_compression[1] : 1.0,
            og.lightness_compression_active ? og.lightness_compression[2] : 1.0,
            cam16_.white_Jp, cam16_.D_rgb[0], cam16_.D_rgb[1], cam16_.D_rgb[2],
        };
        baked_.cam16_k = gpu_->upload_persistent_f32(consts, 22, error);
        if (!baked_.cam16_m2x || !baked_.cam16_m2r || !baked_.cam16_cmax || !baked_.cam16_k)
            return false;
    }

    // --- the black/white scanner references --------------------------------
    bw_active_ = params_.scanner.black_correction || params_.scanner.white_correction;
    if (bw_active_) {
        // `_remove_sRGB_cctf`: the levels are given in sRGB code values, and
        // the correction line works in linear light.
        black_level_ = colour_->cctf_decode(params_.scanner.black_level, "sRGB");
        white_level_ = colour_->cctf_decode(params_.scanner.white_level, "sRGB");
    }

    // The node count the frontend's progress bar divides by. Counted the same
    // way as `len(pipe._topology)`: the nodes that survive pruning.
    node_count_ = 0;
    node_count_ += 1;                                                    // input_cast
    node_count_ += params_.io.input_cctf_decoding ? 1 : 0;               // decode_input
    node_count_ += params_.io.geometry.is_identity() ? 0 : 1;            // geometry
    node_count_ += params_.camera.auto_exposure ? 1 : 0;                 // auto_exposure
    node_count_ += 1;                                                    // crop_rescale
    node_count_ += 1;                                                    // upsample
    node_count_ += 1;                                                    // exposure
    node_count_ += 1;                                                    // boost
    node_count_ += params_.camera.lens_blur_um > 0.0 ? 1 : 0;            // lens_blur
    node_count_ += params_.film_render.halation.active ? 1 : 0;          // halation
    node_count_ += 1;                                                    // expose.log
    node_count_ += 1;                                                    // develop.curves
    node_count_ += params_.film_render.dir_couplers.active ? 1 : 0;      // dir_couplers
    node_count_ += params_.film_render.grain.active ? 1 : 0;             // grain
    if (!params_.io.scan_film) node_count_ += 3;                         // the printing stage
    node_count_ += 5;                                                    // scan..gamut_compress
    node_count_ += params_.scanner.lens_blur > 0.0 ? 1 : 0;              // scanner_blur
    node_count_ += (params_.scanner.unsharp_mask[0] > 0.0 &&
                    params_.scanner.unsharp_mask[1] > 0.0) ? 1 : 0;      // unsharp
    node_count_ += 1;                                                    // cctf

    built_ = true;
    return true;
}

// ---------------------------------------------------------------------------
// small dispatch helpers
// ---------------------------------------------------------------------------

bool Pipeline::curve_interp(const Image& x, const gpu::BufferRef& xa, const gpu::BufferRef& inv,
                            const gpu::BufferRef& y, size_t k, Image& out, std::string& error) {
    if (!alloc_like(x, out, error)) return false;
    const uint32_t meta[2] = {uint32_t(k), uint32_t(x.pixels())};
    return gpu_->dispatch("spk_curves",
                          {gpu::Arg::buf(x.buf), gpu::Arg::buf(xa), gpu::Arg::buf(inv),
                           gpu::Arg::buf(y), gpu::Arg::inline_bytes(meta, 2), gpu::Arg::buf(out.buf)},
                          x.pixels(), error);
}

bool Pipeline::matmul3(const Image& x, const gpu::BufferRef& m, Image& out, std::string& error) {
    if (!alloc_like(x, out, error)) return false;
    const uint32_t n[1] = {uint32_t(x.pixels())};
    return gpu_->dispatch("spk_matmul3",
                          {gpu::Arg::buf(x.buf), gpu::Arg::buf(m), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          x.pixels(), error);
}

bool Pipeline::spectral(const Image& cmy, const gpu::BufferRef& chd, const gpu::BufferRef& base,
                        const gpu::BufferRef& ixs, const double gain[3], const double offset[3],
                        bool log_out, size_t n_lambda, Image& out, std::string& error) {
    if (!alloc_like(cmy, out, error)) return false;
    const float ep[6] = {float(gain[0]), float(gain[1]), float(gain[2]),
                         float(offset[0]), float(offset[1]), float(offset[2])};
    gpu::BufferRef ep_buf = gpu_->upload(ep, sizeof ep, error);
    if (!ep_buf) return false;
    const uint32_t meta[3] = {uint32_t(cmy.pixels()), uint32_t(n_lambda), log_out ? 0u : 1u};
    return gpu_->dispatch("spk_spectral_epilogue",
                          {gpu::Arg::buf(cmy.buf), gpu::Arg::buf(chd), gpu::Arg::buf(base),
                           gpu::Arg::buf(ixs), gpu::Arg::buf(ep_buf),
                           gpu::Arg::inline_bytes(meta, 3), gpu::Arg::buf(out.buf)},
                          cmy.pixels(), error);
}

bool Pipeline::lognormal_field(uint32_t h, uint32_t w, double mean, double std, uint32_t seed,
                               uint32_t stream0, bool per_channel, Image& out, std::string& error) {
    out.h = h; out.w = w; out.c = 3;
    out.buf = gpu_->alloc(out.bytes(), error);
    if (!out.buf) return false;
    const float p[2] = {float(mean), float(std)};
    gpu::BufferRef p_buf = gpu_->upload(p, sizeof p, error);
    if (!p_buf) return false;
    const uint32_t meta[4] = {uint32_t(out.pixels()), seed, stream0, per_channel ? 1u : 0u};
    return gpu_->dispatch("spk_lognormal_field",
                          {gpu::Arg::buf(p_buf), gpu::Arg::inline_bytes(meta, 4), gpu::Arg::buf(out.buf)},
                          out.pixels(), error);
}

bool Pipeline::device_max(const Image& img, double& out, std::string& error) {
    constexpr size_t groups = 256;
    gpu::BufferRef partials = gpu_->alloc(groups * sizeof(float), error);
    if (!partials) return false;
    const uint32_t n[1] = {uint32_t(img.elements())};
    if (!gpu_->dispatch("spk_reduce_max",
                        {gpu::Arg::buf(img.buf), gpu::Arg::inline_bytes(n, 1), gpu::Arg::buf(partials)},
                        groups * 256, error)) return false;
    // A reduction the host needs the value of is the one place a flush is not
    // optional: `boost_highlights` solves for its constants from the frame's
    // own maximum.
    if (!gpu_->flush(error)) return false;
    const float* p = static_cast<const float*>(gpu_->contents(partials.get()));
    float best = p[0];
    for (size_t i = 1; i < groups; ++i) best = std::fmax(best, p[i]);
    out = double(best);
    return true;
}

bool Pipeline::read_back(const Image& img, std::vector<float>& out, std::string& error) {
    if (!gpu_->flush(error)) return false;
    out.resize(img.elements());
    std::memcpy(out.data(), gpu_->contents(img.buf.get()), img.bytes());
    return true;
}

// ---------------------------------------------------------------------------
// preprocess
// ---------------------------------------------------------------------------

bool Pipeline::node_input_cast(const Image& in, Image& out, std::string& error) {
    Timer t(this, "preprocess.input_cast");
    if (in.c == 3) { out = in; return true; }
    out.h = in.h; out.w = in.w; out.c = 3;
    out.buf = gpu_->alloc(out.bytes(), error);
    if (!out.buf) return false;
    const uint32_t meta[2] = {uint32_t(in.pixels()), in.c};
    return gpu_->dispatch("spk_take_rgb",
                          {gpu::Arg::buf(in.buf), gpu::Arg::inline_bytes(meta, 2), gpu::Arg::buf(out.buf)},
                          in.pixels(), error);
}

bool Pipeline::node_decode_input(const Image& in, Image& out, std::string& error) {
    if (!params_.io.input_cctf_decoding) { out = in; return true; }
    Timer t(this, "preprocess.decode_input");
    if (!alloc_like(in, out, error)) return false;
    const uint32_t meta[2] = {uint32_t(in.elements()), input_cctf_mode_};
    return gpu_->dispatch("spk_cctf_decode",
                          {gpu::Arg::buf(in.buf), gpu::Arg::inline_bytes(meta, 2), gpu::Arg::buf(out.buf)},
                          in.elements(), error);
}

bool Pipeline::node_geometry(const Image& in, Image& out, std::string& error) {
    // The pre-crop long edge is the film's, whatever part of the frame the
    // user kept -- so grain and halation do not coarsen when a crop is
    // applied. Recorded before the identity check, as the reference's node
    // body does, so it is set on both paths.
    source_long_edge_ = std::max(in.h, in.w);
    const GeometryParams& g = params_.io.geometry;
    if (g.is_identity()) { out = in; return true; }
    Timer t(this, "preprocess.geometry");

    // `utils/geometry.output_size`: the crop in source pixels, rounded, with
    // the quarter turns swapping the axes.
    const uint32_t turns = uint32_t(((g.quarter_turns % 4) + 4) % 4);
    uint32_t oh = uint32_t(std::lround(g.crop_h * double(in.h)));
    uint32_t ow = uint32_t(std::lround(g.crop_w * double(in.w)));
    if (turns % 2 == 1) std::swap(oh, ow);
    oh = std::max(oh, 1u);
    ow = std::max(ow, 1u);
    const uint32_t cw = turns % 2 == 0 ? ow : oh;   // the crop's own frame
    const uint32_t ch = turns % 2 == 0 ? oh : ow;

    const double a = g.rotation_deg * 3.14159265358979323846 / 180.0;
    const double vals[8] = {
        g.crop_w * double(in.w) / double(cw), g.crop_h * double(in.h) / double(ch),
        g.crop_w * double(in.w) / 2.0, g.crop_h * double(in.h) / 2.0,
        (g.crop_x + g.crop_w / 2.0) * double(in.w) - 0.5,
        (g.crop_y + g.crop_h / 2.0) * double(in.h) - 0.5,
        std::cos(a), std::sin(a),
    };
    // Each constant as a (hi, lo) float pair: the kernel carries the pixel
    // mapping as a double-float because a float32 coordinate on an 8k axis is
    // off by half a pixel at the far edge.
    float consts[16];
    for (int i = 0; i < 8; ++i) {
        consts[2 * i] = float(vals[i]);
        consts[2 * i + 1] = float(vals[i] - double(consts[2 * i]));
    }
    gpu::BufferRef g_buf = gpu_->upload(consts, sizeof consts, error);
    if (!g_buf) return false;
    out.h = oh; out.w = ow; out.c = 3;
    out.buf = gpu_->alloc(out.bytes(), error);
    if (!out.buf) return false;
    const uint32_t flips = (g.flip_h ? 1u : 0u) | (g.flip_v ? 2u : 0u);
    const uint32_t meta[6] = {in.h, in.w, oh, ow, turns, flips};
    return gpu_->dispatch("spk_geometry_resample_df",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(g_buf),
                           gpu::Arg::inline_bytes(meta, 6), gpu::Arg::buf(out.buf)},
                          out.pixels(), error);
}

bool Pipeline::exposure_sample_y(const Image& in, bool stride, std::vector<double>& Y,
                                 uint32_t& sh, uint32_t& sw, std::string& error) {
    // A strided 256 px sample, gathered on device and read back small. A
    // full-resolution order-0 downscale cost 7.1 s at 45 MP against ~0 ms for
    // a stride, and the meter only ever wanted a sparse view of the frame
    // (AGENTS.md trap 10).
    const uint32_t n = std::max(in.h, in.w);
    const uint32_t step = (stride && n > 256) ? uint32_t(std::ceil(double(n) / 256.0)) : 1u;
    Image small;
    small.h = (in.h + step - 1) / step;
    small.w = (in.w + step - 1) / step;
    small.c = 3;
    small.buf = gpu_->alloc(small.bytes(), error);
    if (!small.buf) return false;
    const uint32_t meta[4] = {in.w, small.h, small.w, step};
    if (!gpu_->dispatch("spk_stride_sample",
                        {gpu::Arg::buf(in.buf), gpu::Arg::inline_bytes(meta, 4), gpu::Arg::buf(small.buf)},
                        small.pixels(), error)) return false;
    std::vector<float> host;
    if (!read_back(small, host, error)) return false;

    // `autoexposure._luminance_y`: the Y row of RGB->XYZ, no adaptation.
    sh = small.h; sw = small.w;
    Y.assign(size_t(sh) * size_t(sw), 0.0);
    for (size_t i = 0; i < size_t(sh) * size_t(sw); ++i)
        Y[i] = rgb_to_xyz_ae_.m[1][0] * double(host[3 * i]) +
               rgb_to_xyz_ae_.m[1][1] * double(host[3 * i + 1]) +
               rgb_to_xyz_ae_.m[1][2] * double(host[3 * i + 2]);
    return true;
}

bool Pipeline::legacy_exposure_ev(const std::vector<double>& Y, uint32_t sh, uint32_t sw,
                                  const std::string& method, double& ev, std::string& error) {
    double exposure = 1.0;
    if (method == "average") {
        double sum = 0.0;
        for (double v : Y) sum += v;
        exposure = (sum / double(Y.size())) / kMidgray;
    } else if (method == "median") {
        std::vector<double> sorted = Y;
        std::sort(sorted.begin(), sorted.end());
        const size_t m = sorted.size();
        const double median = m % 2 ? sorted[m / 2] : 0.5 * (sorted[m / 2 - 1] + sorted[m / 2]);
        exposure = median / kMidgray;
    } else if (method == "center_weighted") {
        // center_weighted: a Gaussian falloff from the centre, sigma 0.2 of
        // the long edge, normalised to sum 1.
        const double m_edge = double(std::max(sh, sw));
        const double norm_h = double(sh) / m_edge, norm_w = double(sw) / m_edge;
        constexpr double sigma = 0.2;
        std::vector<double> xs(sw), ys(sh);
        for (size_t j = 0; j < sw; ++j) xs[j] = (double(j) / double(sw) - 0.5) * norm_w;
        for (size_t i = 0; i < sh; ++i) ys[i] = (double(i) / double(sh) - 0.5) * norm_h;
        double mass = 0.0, weighted = 0.0;
        for (size_t i = 0; i < sh; ++i)
            for (size_t j = 0; j < sw; ++j) {
                const double w = std::exp(-(xs[j] * xs[j] + ys[i] * ys[i]) / (2.0 * sigma * sigma));
                mass += w;
                weighted += Y[i * sw + j] * w;
            }
        exposure = (weighted / mass) / kMidgray;
    } else {
        // Unreachable through the wire (`validate_delta` rejects a name this
        // is not) and kept as the meter's own backstop for a `Params` built in
        // code, which is where an unknown name used to be caught.
        error = "auto_exposure_method '" + method + "' is not implemented by the native engine";
        return false;
    }
    ev = -std::log2(exposure);
    // The reference warns and falls back to 0 EV on an all-black frame.
    if (!std::isfinite(ev)) ev = 0.0;
    return true;
}

ExposureEvs Pipeline::exposure_evs_from(const std::vector<double>& raw, uint32_t sh, uint32_t sw) {
    const size_t n = raw.size();
    // `n - 1` below is unsigned; an empty sample has no exposure to report,
    // and the reference's own all-black answer is 0 EV.
    if (n == 0) return ExposureEvs{};
    // The floor is what keeps `ln` finite and stops a black border — the frame
    // edge of a scan, the letterbox of a video grab — from running away with
    // the mean. 0.184 * 2^-12 is twelve stops under mid-grey.
    std::vector<double> y(n);
    for (size_t i = 0; i < n; ++i) y[i] = std::max(raw[i], kMeterFloor);

    // `P(q)`: the element at 0-based rank k of the sorted sample, **k in exact
    // integer division**. Computing `q/100 * (n-1)` in floating point is the
    // trap this avoids: 0.01 and 0.995 are not representable, and either can
    // land one rank low, which the Python side will not do.
    std::vector<double> sorted = y;
    auto rank = [&](int q10) {
        const size_t k = (size_t(q10) * (n - 1)) / 1000u;
        std::nth_element(sorted.begin(), sorted.begin() + k, sorted.end());
        return sorted[k];
    };
    const double p1 = rank(10), p5 = rank(50), p99 = rank(990), p995 = rank(995);

    ExposureEvs out;
    // The trim set: P(1)..P(99) inclusive, by rank. The log mean is what a
    // mid-grey in *stops* means, so it is hardly moved by a small bright
    // region and only needs the trim for the near-black one (RFC-015 §2.2).
    double ln_sum = 0.0;
    size_t count = 0;
    for (size_t i = 0; i < n; ++i)
        if (y[i] >= p1 && y[i] <= p99) { ln_sum += std::log(y[i]); ++count; }
    out.balanced = -std::log2(std::exp(ln_sum / double(count)) / kMidgray);

    // `center` is the same statistic through today's centre-weighted grid:
    // the weights move *where* the mean is taken, not what is trimmed, and
    // they are the same xs/ys and sigma `center_weighted` uses.
    const double m_edge = double(std::max(sh, sw));
    const double norm_h = double(sh) / m_edge, norm_w = double(sw) / m_edge;
    constexpr double sigma = 0.2;
    std::vector<double> xs(sw), ys(sh);
    for (size_t j = 0; j < sw; ++j) xs[j] = (double(j) / double(sw) - 0.5) * norm_w;
    for (size_t i = 0; i < sh; ++i) ys[i] = (double(i) / double(sh) - 0.5) * norm_h;
    double mass = 0.0, weighted = 0.0;
    for (size_t i = 0; i < sh; ++i)
        for (size_t j = 0; j < sw; ++j) {
            const double v = y[i * sw + j];
            if (v < p1 || v > p99) continue;
            const double w = std::exp(-(xs[j] * xs[j] + ys[i] * ys[i]) / (2.0 * sigma * sigma));
            mass += w;
            weighted += std::log(v) * w;
        }
    out.center = -std::log2(std::exp(weighted / mass) / kMidgray);

    // The protect modes are **bounds on balanced, not meters of their own**:
    // a frame with nothing at risk comes out at exactly `balanced`, and the
    // clamps stop one specular highlight, or one black border, from deciding
    // the exposure. Their percentiles are over every sample — protection is
    // never trimmed and never centre-weighted (RFC-015 §2.3).
    out.protect_highlights = std::clamp(
        std::log2(kMidgray * std::pow(2.0, kProtectHighlightsStops) / p995),
        out.balanced - kProtectHighlightsClampEv, out.balanced);
    out.protect_shadows = std::clamp(
        std::log2(kMidgray * std::pow(2.0, -kProtectShadowsStops) / p5),
        out.balanced, out.balanced + kProtectShadowsClampEv);
    return out;
}

bool Pipeline::measure_exposure_ev(const Image& in, double& ev, std::string& error, bool stride) {
    const std::string& method = params_.camera.auto_exposure_method;
    if (!is_known_exposure_method(method)) {
        error = "auto_exposure_method '" + method + "' is not implemented by the native engine "
                "(balanced, center, protect_highlights, protect_shadows, center_weighted, "
                "average and median are)";
        return false;
    }

    std::vector<double> Y;
    uint32_t sh = 0, sw = 0;
    if (!exposure_sample_y(in, stride, Y, sh, sw, error)) return false;
    if (method == "center_weighted" || method == "average" || method == "median")
        return legacy_exposure_ev(Y, sh, sw, method, ev, error);

    // One sample, four answers. The node only needs the session's own intent,
    // and computing all four costs one extra log2 and a clamp next to the
    // readback that produced `Y`.
    const ExposureEvs evs = exposure_evs_from(Y, sh, sw);
    if (method == "balanced") ev = evs.balanced;
    else if (method == "center") ev = evs.center;
    else if (method == "protect_highlights") ev = evs.protect_highlights;
    else ev = evs.protect_shadows;
    return true;
}

double ExposureEvs::of(const std::string& method) const {
    if (method == "balanced") return balanced;
    if (method == "center") return center;
    if (method == "protect_highlights") return protect_highlights;
    if (method == "protect_shadows") return protect_shadows;
    if (method == "average") return average;
    if (method == "median") return median;
    return center_weighted;
}

bool Pipeline::measure_meter_evs(const Image& in, ExposureEvs& out, std::string& error) {
    // The node's own upstream nodes, so the meter sees what the node would:
    // decoded, cropped and turned. `node_geometry` records the frame's long
    // edge for the film's pitch, and this is not the frame being rendered,
    // so the pitch state is put back afterwards; the timings are not this
    // render's either.
    const uint32_t saved_long_edge = source_long_edge_;
    Progress* const saved_progress = progress_;
    progress_ = nullptr;
    Image cast, decoded, framed;
    const bool ok = node_input_cast(in, cast, error) &&
                    node_decode_input(cast, decoded, error) &&
                    node_geometry(decoded, framed, error);
    source_long_edge_ = saved_long_edge;
    progress_ = saved_progress;
    if (!ok) return false;

    // The whole image, not a stride: this is metered once per frame.
    std::vector<double> Y;
    uint32_t sh = 0, sw = 0;
    if (!exposure_sample_y(framed, /*stride=*/false, Y, sh, sw, error)) return false;
    out = exposure_evs_from(Y, sh, sw);
    return legacy_exposure_ev(Y, sh, sw, "center_weighted", out.center_weighted, error) &&
           legacy_exposure_ev(Y, sh, sw, "average", out.average, error) &&
           legacy_exposure_ev(Y, sh, sw, "median", out.median, error);
}

bool Pipeline::node_auto_exposure(const Image& in, Image& out, std::string& error) {
    if (!params_.camera.auto_exposure) { out = in; return true; }
    Timer t(this, "preprocess.auto_exposure");
    // The session's one EV for the frame when it gave one (RFC-015 P.1);
    // otherwise the reference's own stride meter of this input.
    double ev = 0.0;
    if (injected_ev_) ev = *injected_ev_;
    else if (!measure_exposure_ev(in, ev, error)) return false;
    last_ae_ev_ = ev;
    // `matching_scalar`: the gain is narrowed to float32 before it multiplies
    // the frame, exactly as the CPU path narrows it, so the two agree bit for
    // bit rather than nearly.
    const double gain = double(float(std::pow(2.0, ev)));
    double s[3], t0[3];
    fill3(s, gain);
    fill3(t0, 0.0);
    return blur_.affine(in, s, t0, out, error);
}

// ---------------------------------------------------------------------------
// filming.expose
// ---------------------------------------------------------------------------

bool Pipeline::node_upsample(const Image& in, Image& out, std::string& error) {
    Timer t(this, "filming.expose.upsample");
    // Hanatos 2025: RGB -> (tc, b) -> bicubic tc_lut -> * b.
    Image tc;
    tc.h = in.h;
    tc.w = in.w;
    tc.c = 2;
    tc.buf = gpu_->alloc(tc.bytes(), error);
    gpu::BufferRef b = gpu_->alloc(in.pixels() * sizeof(float), error);
    if (!tc.buf || !b) return false;
    const uint32_t n[1] = {uint32_t(in.pixels())};
    if (!gpu_->dispatch("spk_tc_b",
                        {gpu::Arg::buf(in.buf), gpu::Arg::buf(baked_.tc_b_matrix),
                         gpu::Arg::inline_bytes(n, 1), gpu::Arg::buf(tc.buf), gpu::Arg::buf(b)},
                        in.pixels(), error)) return false;
    if (!alloc_like(in, out, error)) return false;
    const uint32_t meta[2] = {uint32_t(baked_.tc_lut_side), uint32_t(in.pixels())};
    return gpu_->dispatch("spk_lut2d_cubic",
                          {gpu::Arg::buf(tc.buf), gpu::Arg::buf(b), gpu::Arg::buf(baked_.tc_lut),
                           gpu::Arg::inline_bytes(meta, 2), gpu::Arg::buf(out.buf)},
                          in.pixels(), error);
}

bool Pipeline::node_exposure(const Image& in, Image& out, std::string& error) {
    Timer t(this, "filming.expose.exposure");
    double s[3], t0[3];
    fill3(s, std::pow(2.0, params_.camera.exposure_compensation_ev));
    fill3(t0, 0.0);
    return blur_.affine(in, s, t0, out, error);
}

bool Pipeline::node_boost(const Image& in, Image& out, std::string& error) {
    const HalationParams& hal = params_.film_render.halation;
    if (hal.boost_ev == 0.0) { out = in; return true; }
    Timer t(this, "filming.expose.boost");
    // `boost_highlights`: an exponential lift above a protected level,
    // normalised by the frame's own maximum -- so it is image-global, which is
    // why it cannot be baked into a LUT and why the maximum is reduced here.
    double max_raw = 0.0;
    if (!device_max(in, max_raw, error)) return false;
    if (max_raw == 0.0) {
        double s[3], t0[3];
        fill3(s, 0.0);
        fill3(t0, 0.0);
        return blur_.affine(in, s, t0, out, error);
    }
    const double raw_x0 = std::min(std::max(kMidgray * std::pow(2.0, hal.protect_ev), 0.0), max_raw);
    if (raw_x0 == max_raw) { out = in; return true; }
    const double a = std::pow(28.0, 1.0 - hal.boost_range);
    const double x0 = raw_x0 / max_raw;
    const double denom = std::exp(a * (1.0 - x0)) - a * (1.0 - x0) - 1.0;
    if (denom <= 0.0) {
        error = "invalid highlight-boost parameters: the normalisation denominator is non-positive";
        return false;
    }
    const double kk = (std::pow(2.0, hal.boost_ev) - 1.0) / denom;
    const float p[4] = {float(raw_x0), float(1.0 / max_raw), float(a), float(kk * max_raw)};
    gpu::BufferRef p_buf = gpu_->upload(p, sizeof p, error);
    if (!p_buf) return false;
    if (!alloc_like(in, out, error)) return false;
    const uint32_t n[1] = {uint32_t(in.elements())};
    return gpu_->dispatch("spk_boost",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(p_buf), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          in.elements(), error);
}

bool Pipeline::node_lens_blur(const Image& in, Image& out, std::string& error) {
    // The pitch is live here, not frozen at build time -- which is the whole
    // of the divergence from the Python engine noted in the header.
    const double sigma_px = pixel_size_um_ > 0.0 ? params_.camera.lens_blur_um / pixel_size_um_ : 0.0;
    if (sigma_px <= 0.0) { out = in; return true; }
    Timer t(this, "filming.expose.lens_blur");
    double sigma[3];
    fill3(sigma, sigma_px);
    return blur_.gaussian(in, sigma, out, error);
}

bool Pipeline::node_halation(const Image& in, Image& out, std::string& error) {
    const HalationParams& hal = params_.film_render.halation;
    if (!hal.active) { out = in; return true; }
    Timer t(this, "filming.expose.halation");
    const double px = pixel_size_um_;
    Image raw = in;

    // Scatter: a Gaussian core plus an exponential tail, as one accumulated
    // mixture, then mixed back over the original by `scatter_amount`.
    const double s_amount = hal.scatter_amount, s_scale = hal.scatter_spatial_scale;
    double sigma_c[3], lambda_t[3], core_w[3], tail_w[3];
    bool any_scatter = false;
    for (int c = 0; c < 3; ++c) {
        sigma_c[c] = hal.scatter_core_um[c] * s_scale / px;
        lambda_t[c] = hal.scatter_tail_um[c] * s_scale / px;
        core_w[c] = 1.0 - hal.scatter_tail_weight[c];
        tail_w[c] = hal.scatter_tail_weight[c];
        any_scatter |= sigma_c[c] > 0.0 || lambda_t[c] > 0.0;
    }
    if (s_amount > 0.0 && any_scatter) {
        std::vector<Blur::Component> comps;
        Blur::Component core{};
        for (int c = 0; c < 3; ++c) {
            core.weight[c] = core_w[c];
            core.sigma[c] = std::max(sigma_c[c], 1e-6);
        }
        comps.push_back(core);
        double tail_lambda[3];
        for (int c = 0; c < 3; ++c) tail_lambda[c] = std::max(lambda_t[c], 1e-6);
        std::vector<Blur::Component> tail;
        Blur::exponential_components(tail_lambda, tail_w, tail);
        comps.insert(comps.end(), tail.begin(), tail.end());
        Image scattered;
        if (!blur_.mixture(raw, comps, scattered, error)) return false;
        double a[3], b[3];
        fill3(a, 1.0 - s_amount);
        fill3(b, s_amount);
        Image mixed;
        if (!blur_.lincomb(raw, scattered, a, b, mixed, error)) return false;
        raw = mixed;
    }

    // Back-reflection: N bounces off the base, each a wider Gaussian, with a
    // geometric decay normalised to sum 1.
    const double h_amount = hal.halation_amount, h_scale = hal.halation_spatial_scale;
    double a_tot[3], sigma_h[3];
    bool any_strength = false, any_sigma = false;
    for (int c = 0; c < 3; ++c) {
        a_tot[c] = double(float(hal.halation_strength[c]) * float(h_amount));
        sigma_h[c] = hal.halation_first_sigma_um[c] * h_scale / px;
        any_strength |= a_tot[c] > 0.0;
        any_sigma |= sigma_h[c] > 0.0;
    }
    const int N = hal.halation_n_bounces;
    if (N >= 1 && any_strength && any_sigma) {
        // Braced, not parenthesised: `std::vector<double> decay(size_t(N))`
        // is a function declaration, not a vector (most vexing parse).
        std::vector<double> decay(static_cast<size_t>(N), 0.0);
        double total = 0.0;
        for (int k = 1; k <= N; ++k) {
            decay[size_t(k - 1)] = std::pow(hal.halation_bounce_decay, double(k - 1));
            total += decay[size_t(k - 1)];
        }
        for (double& d : decay) d /= total;
        std::vector<Blur::Component> comps;
        for (int k = 1; k <= N; ++k) {
            Blur::Component comp{};
            for (int c = 0; c < 3; ++c) {
                comp.weight[c] = decay[size_t(k - 1)];
                comp.sigma[c] = std::max(sigma_h[c] * std::sqrt(double(k)), 1e-6);
            }
            comps.push_back(comp);
        }
        Image hb;
        if (!blur_.mixture(raw, comps, hb, error)) return false;
        double a[3], b[3];
        if (hal.halation_renormalize) {
            for (int c = 0; c < 3; ++c) {
                a[c] = 1.0 / (1.0 + a_tot[c]);
                b[c] = a_tot[c] / (1.0 + a_tot[c]);
            }
        } else {
            fill3(a, 1.0);
            for (int c = 0; c < 3; ++c) b[c] = a_tot[c];
        }
        Image mixed;
        if (!blur_.lincomb(raw, hb, a, b, mixed, error)) return false;
        raw = mixed;
    }
    out = raw;
    return true;
}

bool Pipeline::node_expose_log(const Image& in, Image& out, std::string& error) {
    Timer t(this, "filming.expose.log");
    // `black_white_filming_exposure_correction` is 1.0 for negative film and
    // for a print-side scan, which is every configuration the wire can reach
    // today; positive film scanned directly is the one that is not.
    double correction[3];
    fill3(correction, 1.0);
    if (bw_active_ && params_.io.scan_film && params_.film.info.is_positive()) {
        error = "black/white correction on a directly scanned positive film is not implemented "
                "by the native engine";
        return false;
    }
    const float k[3] = {float(correction[0]), float(correction[1]), float(correction[2])};
    gpu::BufferRef k_buf = gpu_->upload(k, sizeof k, error);
    if (!k_buf) return false;
    if (!alloc_like(in, out, error)) return false;
    const uint32_t n[1] = {uint32_t(in.elements())};
    return gpu_->dispatch("spk_log10_guarded",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(k_buf), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          in.elements(), error);
}

// ---------------------------------------------------------------------------
// filming.develop
// ---------------------------------------------------------------------------

bool Pipeline::node_film_curves(const Image& in, Image& out, std::string& error) {
    Timer t(this, "filming.develop.curves");
    return curve_interp(in, baked_.film_curve_x, baked_.film_curve_inv, baked_.film_curve_y,
                        baked_.film_curve_k, out, error);
}

bool Pipeline::node_dir_couplers(const Image& cmy, const Image& log_raw, Image& out,
                                 std::string& error) {
    const DirCouplersParams& dcp = params_.film_render.dir_couplers;
    if (!dcp.active) { out = cmy; return true; }
    Timer t(this, "filming.develop.dir_couplers");
    Image corr;
    if (!alloc_like(cmy, corr, error)) return false;
    const uint32_t pos[1] = {params_.film.info.is_positive() ? 1u : 0u};
    const uint32_t n[1] = {uint32_t(cmy.pixels())};
    if (!gpu_->dispatch("spk_couplers_correction",
                        {gpu::Arg::buf(cmy.buf), gpu::Arg::buf(baked_.coupler_matrix),
                         gpu::Arg::buf(baked_.coupler_dmax), gpu::Arg::inline_bytes(pos, 1),
                         gpu::Arg::buf(baked_.coupler_shift), gpu::Arg::inline_bytes(n, 1),
                         gpu::Arg::buf(corr.buf)},
                        cmy.pixels(), error)) return false;

    if (dcp.diffusion_size_um > 0.0) {
        const double size_px = dcp.diffusion_size_um / pixel_size_um_;
        const double tail_px = dcp.diffusion_tail_um / pixel_size_um_;
        const double wt = dcp.diffusion_tail_weight;
        std::vector<Blur::Component> comps;
        Blur::Component core{};
        for (int c = 0; c < 3; ++c) { core.weight[c] = 1.0 - wt; core.sigma[c] = size_px; }
        comps.push_back(core);
        double lambda[3], weight[3];
        fill3(lambda, tail_px);
        fill3(weight, wt);
        std::vector<Blur::Component> tail;
        Blur::exponential_components(lambda, weight, tail);
        comps.insert(comps.end(), tail.begin(), tail.end());
        Image diffused;
        if (!blur_.mixture(corr, comps, diffused, error)) return false;
        corr = diffused;
    }

    double a[3], b[3];
    fill3(a, 1.0);
    fill3(b, -1.0);
    Image log_raw_0;
    if (!blur_.lincomb(log_raw, corr, a, b, log_raw_0, error)) return false;
    return curve_interp(log_raw_0, baked_.coupler_curve_x, baked_.coupler_curve_inv,
                        baked_.coupler_curve_y, baked_.film_curve_k, out, error);
}

bool Pipeline::node_grain(const Image& in, Image& out, std::string& error) {
    const GrainParams& g = params_.film_render.grain;
    if (!g.active) { out = in; return true; }
    Timer t(this, "filming.develop.grain");
    const double px = pixel_size_um_;
    // `grain_sampler = "exact"` pins the realisation so an A/B is meaningful;
    // "stochastic" is the product path, where a fresh grain per render is the
    // honest answer. Either way the *distribution* at every density is the
    // same -- which is what the third moment carries.
    const uint32_t seed = params_.settings.grain_sampler == "exact" ? 0x5EEDu : fresh_seed();
    Image grain;

    if (g.sublayers_active) {
        const Profile& film = params_.film;
        const size_t k = film.data.n_exposure;
        // dmax per (sub-layer, channel), and the fractions that split the
        // total density between them.
        double dmax_layers[3][3], fractions[3][3], dmin_layers[3][3];
        double dmax_total[3] = {0, 0, 0};
        for (size_t sl = 0; sl < 3; ++sl)
            for (size_t ch = 0; ch < 3; ++ch) {
                dmax_layers[sl][ch] = nanmax(film.data.density_curves_layers.data() + sl * 3 + ch, k, 9);
                dmax_total[ch] += dmax_layers[sl][ch];
            }
        for (size_t sl = 0; sl < 3; ++sl)
            for (size_t ch = 0; ch < 3; ++ch) {
                fractions[sl][ch] = dmax_layers[sl][ch] / dmax_total[ch];
                dmin_layers[sl][ch] = fractions[sl][ch] * g.density_min[ch];
                dmax_layers[sl][ch] += dmin_layers[sl][ch];
            }
        float lp[36];
        double sigma_particle[3][3];
        bool dye_clouds = false;
        for (size_t ch = 0; ch < 3; ++ch)
            for (size_t sl = 0; sl < 3; ++sl) {
                const double area = g.particle_area_um2 * g.particle_scale[ch] * g.particle_scale_layers[sl];
                const double n_particles = px * px * fractions[sl][ch] / area;
                const double od = dmax_layers[sl][ch] / n_particles;
                sigma_particle[sl][ch] = g.blur_dye_clouds_um > 0.0
                                       ? g.blur_dye_clouds_um * std::sqrt(od) : 0.0;
                dye_clouds |= sigma_particle[sl][ch] > kMinEffectiveBlurSigma;
                const size_t col = ch * 3 + sl;
                lp[4 * col + 0] = float(dmin_layers[sl][ch]);
                lp[4 * col + 1] = float(dmax_layers[sl][ch]);
                lp[4 * col + 2] = float(n_particles);
                lp[4 * col + 3] = float(g.uniformity[ch]);
            }
        gpu::BufferRef lp_buf = gpu_->upload(lp, sizeof lp, error);
        if (!lp_buf) return false;

        if (!dye_clouds) {
            if (!alloc_like(in, grain, error)) return false;
            const uint32_t meta[4] = {uint32_t(k), uint32_t(in.pixels()),
                                      params_.film.info.is_positive() ? 1u : 0u, seed};
            if (!gpu_->dispatch("spk_grain_layers",
                                {gpu::Arg::buf(in.buf), gpu::Arg::buf(baked_.grain_xa),
                                 gpu::Arg::buf(baked_.grain_inv), gpu::Arg::buf(baked_.grain_ylay),
                                 gpu::Arg::buf(lp_buf), gpu::Arg::buf(baked_.grain_streams),
                                 gpu::Arg::inline_bytes(meta, 4), gpu::Arg::buf(grain.buf)},
                                in.pixels(), error)) return false;
        } else {
            // The dye-cloud blur is per (sub-layer, channel), so each
            // sub-layer is drawn on its own, blurred with that sub-layer's
            // per-channel sigma, and accumulated -- which is what the
            // reference's `layer_particle_model(blur_particle=...)` does.
            grain.h = in.h; grain.w = in.w; grain.c = 3;
            grain.buf = gpu_->alloc_zeroed(in.bytes(), error);
            if (!grain.buf) return false;
            for (uint32_t sl = 0; sl < 3; ++sl) {
                Image layer;
                if (!alloc_like(in, layer, error)) return false;
                const uint32_t meta[5] = {uint32_t(k), uint32_t(in.pixels()),
                                          params_.film.info.is_positive() ? 1u : 0u, seed, sl};
                if (!gpu_->dispatch("spk_grain_layer_one",
                                    {gpu::Arg::buf(in.buf), gpu::Arg::buf(baked_.grain_xa),
                                     gpu::Arg::buf(baked_.grain_inv), gpu::Arg::buf(baked_.grain_ylay),
                                     gpu::Arg::buf(lp_buf), gpu::Arg::buf(baked_.grain_streams),
                                     gpu::Arg::inline_bytes(meta, 5), gpu::Arg::buf(layer.buf)},
                                    in.pixels(), error)) return false;
                double sigma[3];
                for (int ch = 0; ch < 3; ++ch)
                    sigma[ch] = sigma_particle[sl][size_t(ch)] > kMinEffectiveBlurSigma
                              ? sigma_particle[sl][size_t(ch)] : 0.0;
                double one[3];
                fill3(one, 1.0);
                Image accumulated;
                if (!blur_.gaussian(layer, sigma, accumulated, error, 3.0, &grain, one)) return false;
                grain = accumulated;
            }
        }
    } else {
        double density_max[3], n_particles[3];
        const int nsub = std::max(1, g.n_sub_layers);
        float lp[12];
        for (int ch = 0; ch < 3; ++ch) {
            density_max[ch] = params_.film.density_max[ch] + g.density_min[ch];
            n_particles[ch] = px * px / (g.particle_area_um2 * g.particle_scale[ch]);
            if (nsub > 1) n_particles[ch] /= double(nsub);
            lp[4 * ch + 0] = float(g.density_min[ch]);
            lp[4 * ch + 1] = float(density_max[ch]);
            lp[4 * ch + 2] = float(n_particles[ch]);
            lp[4 * ch + 3] = float(g.uniformity[ch]);
        }
        gpu::BufferRef lp_buf = gpu_->upload(lp, sizeof lp, error);
        const uint32_t streams[3] = {0, 1, 2};
        gpu::BufferRef streams_buf = gpu_->upload_u32(streams, 3, error);
        if (!lp_buf || !streams_buf) return false;
        if (!alloc_like(in, grain, error)) return false;
        const uint32_t meta[3] = {uint32_t(in.pixels()), uint32_t(nsub), seed};
        if (!gpu_->dispatch("spk_grain_simple",
                            {gpu::Arg::buf(in.buf), gpu::Arg::buf(lp_buf), gpu::Arg::buf(streams_buf),
                             gpu::Arg::inline_bytes(meta, 3), gpu::Arg::buf(grain.buf)},
                            in.pixels(), error)) return false;
        double s[3], t0[3];
        fill3(s, 1.0 / double(nsub));
        for (int c = 0; c < 3; ++c) t0[c] = -g.density_min[c];
        Image scaled;
        if (!blur_.affine(grain, s, t0, scaled, error)) return false;
        if (g.blur > kMinEffectiveBlurSigma) {
            double sigma[3];
            fill3(sigma, g.blur);
            return blur_.gaussian(scaled, sigma, out, error);
        }
        out = scaled;
        return true;
    }

    // --- the sub-layer path's tail: micro-structure, then density_min, then
    // the overall grain blur. The order is the reference's.
    const double blur_px = g.micro_structure[0] / px;
    const double micro_sigma = g.micro_structure[1] * 0.001 / px;
    if (micro_sigma > 0.05) {
        Image field;
        if (!lognormal_field(in.h, in.w, 1.0, micro_sigma, seed, 100, true, field, error)) return false;
        if (blur_px > kMinEffectiveBlurSigma) {
            double sigma[3];
            fill3(sigma, blur_px);
            Image blurred;
            if (!blur_.gaussian(field, sigma, blurred, error)) return false;
            field = blurred;
        }
        Image multiplied;
        if (!alloc_like(grain, multiplied, error)) return false;
        const uint32_t n[1] = {uint32_t(grain.elements())};
        if (!gpu_->dispatch("spk_mul",
                            {gpu::Arg::buf(grain.buf), gpu::Arg::buf(field.buf),
                             gpu::Arg::inline_bytes(n, 1), gpu::Arg::buf(multiplied.buf)},
                            grain.elements(), error)) return false;
        grain = multiplied;
    }
    double s[3], t0[3];
    fill3(s, 1.0);
    for (int c = 0; c < 3; ++c) t0[c] = -g.density_min[c];
    Image shifted;
    if (!blur_.affine(grain, s, t0, shifted, error)) return false;
    if (g.blur > 0.0) {
        double sigma[3];
        fill3(sigma, g.blur);
        return blur_.gaussian(shifted, sigma, out, error);
    }
    out = shifted;
    return true;
}

// ---------------------------------------------------------------------------
// printing
// ---------------------------------------------------------------------------

namespace {






}  // namespace

bool Pipeline::refresh_print_constants(std::string& error) {
    // Every value here changes when a filter shift does, and the filter shifts
    // are live-mutable -- the caller writes them straight onto this pipeline
    // between renders. So they are re-derived per print run, exactly as the
    // reference's node body recomputes them per call.
    if (!print_constants(*colour_, *blob_, params_, tc_lut_host_, baked_.tc_lut_side,
                         print_constants_, error)) return false;

    const SpectralConstants& sc = print_constants_.spectral;
    print_chd_ = gpu_->upload_persistent_f32(sc.channel_density.data(), sc.channel_density.size(), error);
    print_base_ = gpu_->upload_persistent_f32(sc.base_density.data(), sc.base_density.size(), error);
    print_ixs_ = gpu_->upload_persistent_f32(sc.illum_x_sens.data(), sc.illum_x_sens.size(), error);
    if (!print_chd_ || !print_base_ || !print_ixs_) return false;

    for (int c = 0; c < 3; ++c) {
        print_gain_[c] = print_constants_.gain[c];
        print_offset_[c] = print_constants_.offset[c];
    }
    log_raw_print_black_.assign(print_constants_.log_raw_black, print_constants_.log_raw_black + 3);
    log_raw_print_white_.assign(print_constants_.log_raw_white, print_constants_.log_raw_white + 3);
    have_print_references_ = true;

    if (!update_bw_references(error)) return false;
    const double bw_gain = print_exposure_bw_gain(params_, y_black_, y_white_,
                                                  black_level_, white_level_);
    for (int c = 0; c < 3; ++c)
        print_exposure_gain_[c] = params_.enlarger.print_exposure * bw_gain;
    return true;
}

void Pipeline::correction_line(double& m, double& q, double& midgray_corrected) const {
    // `_correction_fucntion`: a clipped linear map taking the measured black
    // and white to the requested levels. With only one of the two corrections
    // on, the *other* end is left where the medium puts it.
    double white = white_level_, black = black_level_;
    if (params_.scanner.black_correction && !params_.scanner.white_correction) white = y_white_;
    if (params_.scanner.white_correction && !params_.scanner.black_correction) black = y_black_;
    m = (white - black) / (y_white_ - y_black_ + 1e-10);
    q = black - m * y_black_;
    midgray_corrected = (kMidgray - q) / m;
}

bool Pipeline::update_bw_references(std::string& error) {
    if (!bw_active_) return true;
    if (params_.io.scan_film) {
        if (params_.film.info.is_positive()) {
            error = "black/white correction on a directly scanned positive film is not implemented "
                    "by the native engine";
            return false;
        }
        return true;   // negative film scanned directly is not corrected
    }
    if (params_.print.info.is_positive() || !have_print_references_) return true;

    // The paper's own black and white: develop the two reference exposures on
    // the paper's *raw* curves, then read their Y through the scanner.
    const Profile& print = params_.print;
    const size_t k = print.data.n_exposure;
    auto develop_and_y = [&](const Vec& log_raw) -> double {
        double cmy[3];
        for (int c = 0; c < 3; ++c) {
            Vec xs(k), ys(k);
            for (size_t i = 0; i < k; ++i) {
                xs[i] = print.data.log_exposure[i];
                ys[i] = print.data.density_curves[3 * i + size_t(c)];
            }
            cmy[c] = interp(log_raw[size_t(c)], xs.data(), ys.data(), k);
        }
        // The scanner's spectral integral on one pixel, with the constants the
        // build already prepared.
        const float* chd = static_cast<const float*>(gpu_->contents(baked_.scan_chd.get()));
        const float* base = static_cast<const float*>(gpu_->contents(baked_.scan_base.get()));
        const float* ixs = static_cast<const float*>(gpu_->contents(baked_.scan_ixs.get()));
        double acc = 0.0;
        for (size_t l = 0; l < kNumWavelengths; ++l) {
            double d = double(base[l]);
            for (int c = 0; c < 3; ++c) d += cmy[c] * double(chd[3 * l + size_t(c)]);
            acc += std::exp2(-d * 3.321928094887362) * double(ixs[3 * l + 1]);   // the Y row
        }
        return std::fmax(acc, 0.0) + 1e-10;
    };
    y_black_ = develop_and_y(log_raw_print_black_);
    y_white_ = develop_and_y(log_raw_print_white_);
    return true;
}

bool Pipeline::node_enlarger_spectral(const Image& in, Image& out, std::string& error) {
    Timer t(this, "printing.expose.enlarger_spectral");
    return spectral(in, print_chd_, print_base_, print_ixs_, print_gain_, print_offset_,
                    /*log_out=*/true, kNumWavelengths, out, error);
}

bool Pipeline::node_print_exposure(const Image& in, Image& out, std::string& error) {
    Timer t(this, "printing.expose.print_exposure");
    const float k[3] = {float(print_exposure_gain_[0]), float(print_exposure_gain_[1]),
                        float(print_exposure_gain_[2])};
    gpu::BufferRef k_buf = gpu_->upload(k, sizeof k, error);
    if (!k_buf) return false;
    if (!alloc_like(in, out, error)) return false;
    const uint32_t n[1] = {uint32_t(in.elements())};
    return gpu_->dispatch("spk_print_exposure",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(k_buf), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          in.elements(), error);
}

bool Pipeline::node_print_curves(const Image& in, Image& out, std::string& error) {
    Timer t(this, "printing.develop.print_curves");
    return curve_interp(in, baked_.print_curve_x, baked_.print_curve_inv, baked_.print_curve_y,
                        baked_.print_curve_k, out, error);
}

// ---------------------------------------------------------------------------
// scanning
// ---------------------------------------------------------------------------

bool Pipeline::node_scan_spectral(const Image& in, Image& out, std::string& error) {
    Timer t(this, "scanning.scan_spectral");
    double gain[3], offset[3];
    fill3(gain, 1.0);
    fill3(offset, 0.0);
    // `log_out = false` returns `max(v, 0) + 1e-10`, which is exactly
    // `10 ** log10(max(v, 0) + 1e-10)` -- the reference's round trip, with the
    // log and the exponent cancelled rather than evaluated.
    return spectral(in, baked_.scan_chd, baked_.scan_base, baked_.scan_ixs, gain, offset,
                    /*log_out=*/false, kNumWavelengths, out, error);
}

bool Pipeline::node_bw_correction(const Image& in, Image& out, std::string& error) {
    if (!bw_active_) { out = in; return true; }
    if (params_.io.scan_film && !params_.film.info.is_positive()) { out = in; return true; }
    Timer t(this, "scanning.bw_correction");
    // `black_white_xyz_correction`: scale XYZ by the correction the *Y*
    // channel needs, so the correction is a luminance stretch and not a
    // per-channel one.
    double m = 1.0, q = 0.0, midgray_corrected = kMidgray;
    correction_line(m, q, midgray_corrected);
    const float p[2] = {float(m), float(q)};
    gpu::BufferRef p_buf = gpu_->upload(p, sizeof p, error);
    if (!p_buf) return false;
    if (!alloc_like(in, out, error)) return false;
    const uint32_t n[1] = {uint32_t(in.pixels())};
    return gpu_->dispatch("spk_bw_correct",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(p_buf), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          in.pixels(), error);
}

bool Pipeline::node_glare(const Image& in, Image& out, std::string& error) {
    if (params_.io.scan_film) { out = in; return true; }
    const GlareParams& glare = params_.print_render.glare;
    if (!glare.active || glare.percent <= 0.0) { out = in; return true; }
    Timer t(this, "scanning.glare");
    Image field;
    if (!lognormal_field(in.h, in.w, glare.percent, glare.roughness * glare.percent,
                         fresh_seed(), 200, false, field, error)) return false;
    if (glare.blur > 0.0) {
        double sigma[3];
        fill3(sigma, glare.blur);
        Image blurred;
        if (!blur_.gaussian(field, sigma, blurred, error)) return false;
        field = blurred;
    }
    if (!alloc_like(in, out, error)) return false;
    const uint32_t n[1] = {uint32_t(in.elements())};
    return gpu_->dispatch("spk_glare_add",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(field.buf),
                           gpu::Arg::buf(baked_.glare_illuminant), gpu::Arg::inline_bytes(n, 1),
                           gpu::Arg::buf(out.buf)},
                          in.elements(), error);
}

bool Pipeline::node_xyz_to_rgb(const Image& in, Image& out, std::string& error) {
    Timer t(this, "scanning.xyz_to_rgb");
    return matmul3(in, baked_.xyz_to_rgb, out, error);
}

bool Pipeline::node_gamut_compress(const Image& in, Image& out, std::string& error) {
    if (params_.io.output_gamut_compress.algorithm == "off") { out = in; return true; }
    Timer t(this, "scanning.gamut_compress");
    if (!alloc_like(in, out, error)) return false;
    const uint32_t meta[4] = {uint32_t(in.pixels()), uint32_t(baked_.cam16_nl),
                              uint32_t(baked_.cam16_nh), baked_.cam16_lightness ? 1u : 0u};
    return gpu_->dispatch("spk_cam16ucs_compress",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(baked_.cam16_m2x),
                           gpu::Arg::buf(baked_.cam16_m2r), gpu::Arg::buf(baked_.cam16_cmax),
                           gpu::Arg::buf(baked_.cam16_k), gpu::Arg::inline_bytes(meta, 4),
                           gpu::Arg::buf(out.buf)},
                          in.pixels(), error);
}

bool Pipeline::node_scanner_blur(const Image& in, Image& out, std::string& error) {
    if (params_.scanner.lens_blur <= 0.0) { out = in; return true; }
    Timer t(this, "scanning.scanner_blur");
    double sigma[3];
    fill3(sigma, params_.scanner.lens_blur);
    return blur_.gaussian(in, sigma, out, error);
}

bool Pipeline::node_unsharp(const Image& in, Image& out, std::string& error) {
    const double sigma_px = params_.scanner.unsharp_mask[0];
    const double amount = params_.scanner.unsharp_mask[1];
    if (!(sigma_px > 0.0 && amount > 0.0)) { out = in; return true; }
    Timer t(this, "scanning.unsharp");
    double sigma[3];
    fill3(sigma, sigma_px);
    Image blurred;
    if (!blur_.gaussian(in, sigma, blurred, error)) return false;
    // `rgb + amount * (rgb - blurred)`, folded into one pass.
    double a[3], b[3];
    fill3(a, 1.0 + amount);
    fill3(b, -amount);
    return blur_.lincomb(in, blurred, a, b, out, error);
}

bool Pipeline::node_cctf(const Image& in, Image& out, std::string& error) {
    if (!params_.io.output_cctf_encoding) { out = in; return true; }
    Timer t(this, "scanning.cctf");
    if (!alloc_like(in, out, error)) return false;
    const uint32_t meta[2] = {uint32_t(in.pixels()), output_cctf_mode_};
    return gpu_->dispatch("spk_cctf_encode_matrix",
                          {gpu::Arg::buf(in.buf), gpu::Arg::buf(baked_.output_matrix),
                           gpu::Arg::inline_bytes(meta, 2), gpu::Arg::buf(out.buf)},
                          in.pixels(), error);
}

// ---------------------------------------------------------------------------
// the two runs
// ---------------------------------------------------------------------------

// Fire one node, then evaluate.
//
// The flush is not bookkeeping: a buffer freed by the node that just ran only
// becomes reusable once the work naming it has completed, so without this the
// next node allocates fresh memory and a full-resolution render's footprint
// becomes the sum of every intermediate rather than the two or three live at
// once. Measured at 24 MP: 6.4 s and 3.2 GB batched to the end of the frame,
// 0.4 s evaluating here. It is also where the reference evaluates
// (AGENTS.md trap 5, `mx.eval` at node boundaries).
#define SPK_NODE(call)                                                     \
    do {                                                                   \
        if (progress_ && progress_->cancelled) {                           \
            error = "render cancelled";                                    \
            return false;                                                  \
        }                                                                  \
        if (!(call)) return false;                                         \
        if (!gpu_->flush(error)) return false;                             \
    } while (0)

bool Pipeline::run_film(const Image& in, Image& out, Progress* progress, std::string& error) {
    if (!built_) { error = "pipeline was not built"; return false; }
    progress_ = progress;
    if (progress_) { progress_->total_nodes = node_count_; progress_->fired = 0; }
    last_ae_ev_.reset();

    Image cur, next;
    SPK_NODE(node_input_cast(in, cur, error));
    SPK_NODE(node_decode_input(cur, next, error)); cur = next;
    SPK_NODE(node_geometry(cur, next, error)); cur = next;
    SPK_NODE(node_auto_exposure(cur, next, error)); cur = next;

    // `preprocess.crop_rescale`: at the shipped defaults its only job is to
    // fix the film's pixel pitch, which every micrometre-specified effect
    // downstream converts with. The pitch is the *pre-crop* long edge's.
    {
        Timer t(this, "preprocess.crop_rescale");
        if (source_long_edge_ == 0) source_long_edge_ = std::max(cur.h, cur.w);
        pixel_size_um_ = params_.camera.film_format_mm * 1000.0 / double(source_long_edge_);
    }

    SPK_NODE(node_upsample(cur, next, error)); cur = next;
    SPK_NODE(node_exposure(cur, next, error)); cur = next;
    SPK_NODE(node_boost(cur, next, error)); cur = next;
    SPK_NODE(node_lens_blur(cur, next, error)); cur = next;
    SPK_NODE(node_halation(cur, next, error)); cur = next;
    Image log_e_film;
    SPK_NODE(node_expose_log(cur, log_e_film, error));
    Image cmy;
    SPK_NODE(node_film_curves(log_e_film, cmy, error));
    SPK_NODE(node_dir_couplers(cmy, log_e_film, next, error)); cmy = next;
    SPK_NODE(node_grain(cmy, out, error));
    progress_ = nullptr;
    return true;
}

bool Pipeline::run_print(const Image& cmy, Image& out, Progress* progress, std::string& error) {
    if (!built_) { error = "pipeline was not built"; return false; }
    progress_ = progress;
    if (pixel_size_um_ <= 0.0) {
        // Every reprint is preceded by the negative that produced its input,
        // so the pitch is always known by the time this runs. Saying so beats
        // silently dividing by zero if that ever stops being true.
        error = "run_print was called before any run_film, so the film's pixel pitch is unknown";
        return false;
    }

    Image cur = cmy, next;
    if (!params_.io.scan_film) {
        // The enlarger's cheap constants are re-derived on every print run,
        // because `print_exposure` and the two filter shifts are live-mutable:
        // the service writes them straight onto this pipeline between renders.
        if (!refresh_print_constants(error)) { progress_ = nullptr; return false; }
        SPK_NODE(node_enlarger_spectral(cur, next, error)); cur = next;
        SPK_NODE(node_print_exposure(cur, next, error)); cur = next;
        SPK_NODE(node_print_curves(cur, next, error)); cur = next;
    }
    SPK_NODE(node_scan_spectral(cur, next, error)); cur = next;
    SPK_NODE(node_bw_correction(cur, next, error)); cur = next;
    SPK_NODE(node_glare(cur, next, error)); cur = next;
    SPK_NODE(node_xyz_to_rgb(cur, next, error)); cur = next;
    SPK_NODE(node_gamut_compress(cur, next, error)); cur = next;
    SPK_NODE(node_scanner_blur(cur, next, error)); cur = next;
    SPK_NODE(node_unsharp(cur, next, error)); cur = next;
    SPK_NODE(node_cctf(cur, out, error));
    if (progress_) progress_->done = true;
    progress_ = nullptr;
    return true;
}

#undef SPK_NODE

}  // namespace spk
