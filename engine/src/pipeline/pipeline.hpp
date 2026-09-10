// pipeline.hpp -- the render graph.
//
// A port of `runtime/pipeline.SimulationPipeline` plus the three stage objects
// and the node bodies `backends/metal/nodes.py` binds to them. The node order,
// the identity-pruning conditions and the labels are the reference's, because
// the labels are what per-node timings and a bisection over a regression are
// reported in.
//
// Two structural differences from the Python side, both deliberate:
//
// **No tap dictionary.** The Python topology is a general graph over named
// taps because it must support entering and leaving at any of them. Three
// entry/exit pairs are actually used -- RGB_IN -> CMY_FILM for the negative,
// CMY_FILM -> RGB_OUT for a reprint, RGB_IN -> RGB_OUT for a full render --
// so this exposes those three as `run_film` and `run_print` and keeps the
// order in code. Nothing is lost: the pruning decisions and the timings are
// the same.
//
// **Blur sigmas are computed per run, not per build.** The reference derives
// `lens_sigma` from `pixel_size_um` while building the topology, and
// `pixel_size_um` does not exist until the first render -- so
// `camera.lens_blur_um` is pruned unconditionally and has never done anything
// (verified: max |out(0) - out(50 um)| == 0.0 exactly). Here the pitch is a
// per-run argument, so the parameter works. That is a knowing divergence and
// the render-parity harness reports it as one.
#pragma once
#include <string>
#include <unordered_map>
#include <vector>

#include "blob.hpp"
#include "blur.hpp"
#include "cam16.hpp"
#include "colour.hpp"
#include "curves.hpp"
#include "hanatos.hpp"
#include "image.hpp"
#include "params.hpp"
#include "printing.hpp"
#include "setup_cache.hpp"
#include "spectral.hpp"

namespace spk {

// A render's progress and its cancellation flag. `cancel` is read between
// nodes, so a cancelled render unwinds at a node boundary rather than being
// abandoned mid-kernel.
//
// `node_ms` is **empty unless `detailed` is set**, and that is a correctness
// choice rather than a saving. Dispatches batch into one command buffer and
// only the final flush waits, so a wall-clock timer around a node body
// measures how long it took to *encode* -- which came out at 0.003 ms for a
// full-frame matmul, three orders of magnitude below the truth. Reporting
// those as per-node render times would put a plausible, wrong number in front
// of anyone bisecting a slow frame.
//
// With `detailed`, each node flushes before its timer stops, so the numbers
// are real GPU time and the batching is given up for the run. Set
// `SPEKTRAFILM_NODE_TIMINGS=1` to ask for it.
struct Progress {
    std::string progress_id;
    int total_nodes = 0;
    int fired = 0;
    std::string stage = "queued";
    bool cancelled = false;
    bool done = false;
    bool detailed = false;
    std::unordered_map<std::string, double> node_ms;
};

class Pipeline {
public:
    Pipeline(gpu::Gpu* gpu, const Colour* colour, const Blob* blob, SetupCache* cache)
        : gpu_(gpu), colour_(colour), blob_(blob), cache_(cache), blur_(gpu) {}
    // No destructor: every buffer it owns is a counted handle.

    // Bake everything that does not depend on a pixel or on the frame's size.
    // Expensive: the tc_lut is a 192x192x81 contraction and the C_max table is
    // 46,080 bisections, which is why `warm_up` exists to pay it early.
    bool build(const Params& params, std::string& error);

    // The film's pixel pitch, from the frame this pipeline is about to render.
    //
    // It must be set before *any* run, not just before `run_film`, and that is
    // the whole reason it is a separate call. `set_params` replaces the
    // pipeline for anything outside `LIVE_MUTABLE`, but only a *shoot*-layer
    // change drops the cached negative -- so a print-layer rebuild
    // (`scanner_lens_blur`, `output_color_space`, the filter pack, twelve
    // fields in all) left a fresh pipeline reprinting a negative it had never
    // rendered, with no pitch and no way to get one.
    void set_source_long_edge(uint32_t long_edge);

    // `Tap.RGB_IN` -> `Tap.CMY_FILM`. `out` is the developed negative.
    bool run_film(const Image& in, Image& out, Progress* progress, std::string& error);
    // `Tap.CMY_FILM` -> `Tap.RGB_OUT`.
    bool run_print(const Image& cmy, Image& out, Progress* progress, std::string& error);

    // The auto-exposure meter on its own, without applying its gain.
    // `solve(target="exposure")` reports the EV so the frontend can show it
    // and the user can override it; `preprocess.auto_exposure` applies the
    // same number. One implementation, so the two cannot disagree about what
    // "the exposure" is.
    bool measure_exposure_ev(const Image& in, double& ev, std::string& error);

    // The film's pixel pitch for the frame most recently run through
    // `run_film`, in micrometres. Grain, halation and the DIR-coupler
    // diffusion are all specified in micrometres and converted with it.
    double pixel_size_um() const { return pixel_size_um_; }

    const Params& params() const { return params_; }
    // The live-mutable print fields (`print_exposure`, the filter shifts,
    // `preflash_exposure`) are written straight onto the baked copy; the print
    // side re-derives its cheap constants every run, exactly as the reference
    // does, because the service mutates them between renders.
    void apply_live_delta(const Json& delta) { apply_delta(params_, delta); }

    int node_count() const { return node_count_; }

private:
    struct Timer;

    // --- per-node bodies, in topology order -----------------------------
    bool node_input_cast(const Image& in, Image& out, std::string& error);
    bool node_decode_input(const Image& in, Image& out, std::string& error);
    bool node_geometry(const Image& in, Image& out, std::string& error);
    bool node_auto_exposure(const Image& in, Image& out, std::string& error);
    bool node_upsample(const Image& in, Image& out, std::string& error);
    bool node_exposure(const Image& in, Image& out, std::string& error);
    bool node_boost(const Image& in, Image& out, std::string& error);
    bool node_lens_blur(const Image& in, Image& out, std::string& error);
    bool node_halation(const Image& in, Image& out, std::string& error);
    bool node_expose_log(const Image& in, Image& out, std::string& error);
    bool node_film_curves(const Image& in, Image& out, std::string& error);
    bool node_dir_couplers(const Image& cmy, const Image& log_raw, Image& out, std::string& error);
    bool node_grain(const Image& in, Image& out, std::string& error);
    bool node_enlarger_spectral(const Image& in, Image& out, std::string& error);
    bool node_print_exposure(const Image& in, Image& out, std::string& error);
    bool node_print_curves(const Image& in, Image& out, std::string& error);
    bool node_scan_spectral(const Image& in, Image& out, std::string& error);
    bool node_bw_correction(const Image& in, Image& out, std::string& error);
    bool node_glare(const Image& in, Image& out, std::string& error);
    bool node_xyz_to_rgb(const Image& in, Image& out, std::string& error);
    bool node_gamut_compress(const Image& in, Image& out, std::string& error);
    bool node_scanner_blur(const Image& in, Image& out, std::string& error);
    bool node_unsharp(const Image& in, Image& out, std::string& error);
    bool node_cctf(const Image& in, Image& out, std::string& error);

    // --- helpers ---------------------------------------------------------
    bool alloc_like(const Image& img, Image& out, std::string& error);
    bool curve_interp(const Image& x, const gpu::BufferRef& xa, const gpu::BufferRef& inv,
                      const gpu::BufferRef& y, size_t k, Image& out, std::string& error);
    bool matmul3(const Image& x, const gpu::BufferRef& m, Image& out, std::string& error);
    bool spectral(const Image& cmy, const gpu::BufferRef& chd, const gpu::BufferRef& base,
                  const gpu::BufferRef& ixs, const double gain[3], const double offset[3],
                  bool log_out, size_t n_lambda, Image& out, std::string& error);
    bool lognormal_field(uint32_t h, uint32_t w, double mean, double std, uint32_t seed,
                         uint32_t stream0, bool per_channel, Image& out, std::string& error);
    bool device_max(const Image& img, double& out, std::string& error);
    bool read_back(const Image& img, std::vector<float>& out, std::string& error);
    uint32_t fresh_seed();

    // The black/white scanner references, and the two exposure corrections
    // that fall out of them (`runtime/services/color_reference.py`). All of it
    // is 1x1 spectral integrals on the host; none of it is per pixel.
    bool update_bw_references(std::string& error);
    void correction_line(double& m, double& q, double& midgray_corrected) const;

    // Enlarger-side constants that a live filter-shift edit invalidates, so
    // they are re-derived at the top of every `run_print`.
    bool refresh_print_constants(std::string& error);

    gpu::Gpu* gpu_;
    const Colour* colour_;
    const Blob* blob_;
    SetupCache* cache_;
    Blur blur_;
    Params params_;
    bool built_ = false;
    int node_count_ = 0;
    double pixel_size_um_ = 0.0;
    uint32_t source_long_edge_ = 0;
    Progress* progress_ = nullptr;

    // --- baked, persistent ----------------------------------------------
    struct Baked {
        gpu::BufferRef tc_lut;
        size_t tc_lut_side = 0;

        gpu::BufferRef film_curve_x, film_curve_inv, film_curve_y;
        size_t film_curve_k = 0;
        gpu::BufferRef coupler_curve_x, coupler_curve_inv, coupler_curve_y;
        gpu::BufferRef coupler_matrix, coupler_dmax, coupler_shift;

        gpu::BufferRef grain_xa, grain_inv, grain_ylay;
        gpu::BufferRef grain_streams;

        gpu::BufferRef print_curve_x, print_curve_inv, print_curve_y;
        size_t print_curve_k = 0;

        gpu::BufferRef scan_chd, scan_base, scan_ixs;
        gpu::BufferRef glare_illuminant;

        gpu::BufferRef tc_b_matrix;
        gpu::BufferRef xyz_to_rgb;
        gpu::BufferRef output_matrix;

        gpu::BufferRef cam16_m2x, cam16_m2r, cam16_cmax, cam16_k;
        size_t cam16_nl = 0, cam16_nh = 0;
        bool cam16_lightness = false;
    } baked_;

    // --- derived on the host, refreshed per run --------------------------
    Vec film_sensitivity_;
    // The tc_lut and its matrix are kept on the host as well as on device:
    // the print exposure's midgray probe runs one pixel of grey through the
    // film model, and rebuilding a 192x192x81 contraction to do that on every
    // print run cost more than the render it was normalising.
    Vec tc_lut_host_;
    Mat3 tc_b_host_;
    PrintConstants print_constants_;
    Cam16Setup cam16_;
    Mat3 rgb_to_xyz_ae_;          // the auto-exposure meter's luminance row
    uint32_t output_cctf_mode_ = 4;
    uint32_t input_cctf_mode_ = 4;

    // print side, per run
    gpu::BufferRef print_chd_, print_base_, print_ixs_;
    double print_gain_[3] = {1, 1, 1};
    double print_offset_[3] = {0, 0, 0};
    double print_exposure_gain_[3] = {1, 1, 1};

    // black/white references
    bool bw_active_ = false;
    double y_black_ = 0.0, y_white_ = 1.0;
    double black_level_ = 0.0, white_level_ = 1.0;
    Vec log_raw_print_black_, log_raw_print_white_;
    bool have_print_references_ = false;

    uint64_t rng_state_ = 0x243F6A8885A308D3ull;
};

}  // namespace spk
