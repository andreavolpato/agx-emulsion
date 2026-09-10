// engine.cpp -- the C ABI, and the session behind it.
//
// A port of `service/engine.RenderEngine` and `service/session.RenderSession`,
// with the transport deleted. What that deletion removes, concretely:
//
//   * a 364 MB uncompressed TIFF crossing the boundary on every `open`, in
//     each direction;
//   * `_write_rgba16`, which was 10 ms of a 30.6 ms reprint -- a third of it;
//   * JSON-RPC framing, a workspace directory, and every filename in it.
//
// What it keeps, deliberately: the method surface, the tier names, the
// reply shapes and the two version numbers. The frontend asks the same
// questions and gets the same answers (contract §2), which is what makes this
// a deletion rather than a rewrite.
//
// One thing the in-process boundary lets go of. The Python engine holds an LRU
// over whole sessions (RFC-013 §2) because the wire has no way to express a
// session's lifetime -- a session id is a string and the client may come back
// to it at any time. Here a session *is* a pointer the caller holds, so the
// caller's own retention is the cache, and `spk_session_release` is when it
// ends. The `session_cache` field stays in `capabilities` so the frontend's
// status bar keeps working; it reports the sessions currently open.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>
#include <vector>

#include "spektrafilm/spk_engine.h"

#include "blob.hpp"
#include "colour.hpp"
#include "image.hpp"
#include "json.hpp"
#include "params.hpp"
#include "pipeline.hpp"
#include "setup_cache.hpp"

using namespace spk;

namespace {

// API-SPEC §6's three tiers, by long edge in pixels. `live` targets the
// interaction budget for a print-side slider drag; `preview` is deliberately
// large enough to read grain and halation, which are invisible at contact
// sheet scale.
struct Tier {
    const char* name;
    uint32_t long_edge;   // 0 = the frame's own resolution
};
constexpr Tier kTiers[] = {{"live", 1600}, {"preview", 3400}, {"full", 0}};
constexpr double kMaxMP = 60.0;

const Tier* find_tier(const char* name) {
    if (!name) return nullptr;
    for (const Tier& t : kTiers) if (std::strcmp(t.name, name) == 0) return &t;
    return nullptr;
}

std::string read_text_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// A per-thread error slot, so `spk_last_error` is meaningful when two threads
// render different tiers at once -- which the engine supports and the Python
// service's numba path never could.
thread_local std::string g_error;

char* dup_json(const Json& j) {
    const std::string text = j.dump();
    char* out = static_cast<char*>(std::malloc(text.size() + 1));
    if (out) std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}

uint32_t next_id() {
    static std::atomic<uint32_t> counter{1};
    return counter.fetch_add(1);
}

}  // namespace

// ---------------------------------------------------------------------------
// the session
// ---------------------------------------------------------------------------

struct spk_session {
    spk_engine* engine = nullptr;
    std::string session_id;

    // The source frame at its own resolution, **on the device**. A tier is
    // built from it lazily and a stock change re-renders from it, so it has to
    // be kept -- but keeping it on the host meant a full-frame copy at `open`
    // and a second upload per tier. At 24 MP that was 384 MB of each.
    //
    // `spk_open` is documented not to retain the caller's pointer, so exactly
    // one copy is unavoidable; this makes that copy the upload.
    Image source;

    Params params;
    std::unique_ptr<Pipeline> pipeline;

    // Per tier: the downscaled source, the cached negative, and the result.
    struct TierState {
        Image image;      // the source at this tier
        Image negative;   // Tap.CMY_FILM
        bool has_negative = false;
    };
    std::unordered_map<std::string, TierState> tiers;

    std::mutex lock;
    Progress progress;
};

// ---------------------------------------------------------------------------
// the engine
// ---------------------------------------------------------------------------

struct spk_engine {
    std::string resources_dir;
    Blob blob;
    Colour colour;
    gpu::Gpu* gpu = nullptr;
    Json neutral_filters;
    // Shared by every pipeline this engine builds, which is the point: a
    // slider outside LIVE_MUTABLE rebuilds the pipeline, and neither of these
    // depends on what the slider changed.
    SetupCache setup_cache;
    std::string math_mode;
    std::string cached_capabilities;
    std::string cached_schema;
    std::vector<spk_session*> sessions;
    std::mutex lock;

    ~spk_engine() { delete gpu; }

    Json capabilities_json() {
        Json backend = Json::object();
        backend.set("spectral", Json(std::string("native")));
        backend.set("gpu", Json(gpu ? gpu->device_name() : std::string("none")));
        backend.set("gpu_available", Json(gpu != nullptr));
        backend.set("working_precision", Json(std::string("float32")));
        // Contract §6 / RFC-014 §5.1 trap 6: what the engine *loaded*, not
        // what the process could reach. `render_core` was a probe of
        // availability, and that hid a session silently demoted to the CPU
        // while capabilities still said metal.
        backend.set("render_core", Json(std::string("native-metal")));
        backend.set("host", Json(std::string("native")));
        backend.set("math_mode", Json(math_mode));
        // Concurrent entry is safe: there is no numba here, and renders on
        // different tiers hold different locks.
        backend.set("concurrent", Json(true));
        Json cache = Json::object();
        cache.set("entries", Json(double(sessions.size())));
        cache.set("max_entries", Json(double(0)));
        cache.set("enabled", Json(false));
        // The setup cache is what decides whether a non-live slider costs
        // 7 ms or 250, so its hit rate belongs next to the session count
        // rather than in a log.
        const SetupCache::Stats s = setup_cache.stats();
        cache.set("hits", Json(double(s.hits)));
        cache.set("misses", Json(double(s.misses)));
        cache.set("setup_tc_luts", Json(double(s.lut_entries)));
        cache.set("setup_cam16", Json(double(s.cam16_entries)));
        backend.set("session_cache", std::move(cache));

        Json out = Json::object();
        out.set("version", Json(std::string(spk_build_info())));
        out.set("engine", Json(std::string("spektrafilm.native")));
        out.set("max_mp", Json(kMaxMP));
        Json tiers = Json::object();
        for (const Tier& t : kTiers) {
            if (t.long_edge) tiers.set(t.name, Json(double(t.long_edge)));
            else tiers.set(t.name, Json());
        }
        out.set("tiers", std::move(tiers));
        out.set("transport_version", Json(double(SPK_TRANSPORT_VERSION)));
        out.set("schema_version", Json(double(SPK_SCHEMA_VERSION)));
        out.set("backend", std::move(backend));
        return out;
    }
};

namespace {

// The tier downscale: `utils/preview.resize_for_preview` on device, i.e.
// skimage's anti-aliased `resize(order=1)` with its exact parameters -- a
// separable Gaussian prefilter with sigma = max(0, (factor - 1) / 2) per axis,
// truncate 4.0, ndimage 'mirror' edges, then bilinear at (i + 0.5) * factor -
// 0.5. It is a port and not a different downscale: its output feeds the film
// simulation.
bool downscale(gpu::Gpu* gpu, const Image& src, uint32_t max_size, Image& out, std::string& error) {
    const uint32_t longest = std::max(src.h, src.w);
    if (max_size == 0 || longest <= max_size) { out = src; return true; }
    const double scale = double(max_size) / double(longest);
    const uint32_t oh = std::max(1u, uint32_t(double(src.h) * scale));
    const uint32_t ow = std::max(1u, uint32_t(double(src.w) * scale));
    const double factors[2] = {double(src.h) / double(oh), double(src.w) / double(ow)};

    Image cur = src;
    for (int axis = 0; axis < 2; ++axis) {
        const double sigma = std::max(0.0, (factors[axis] - 1.0) / 2.0);
        Vec weights;
        const size_t radius = gaussian_kernel_1d(sigma, 4.0, weights);
        if (radius == 0) continue;
        std::vector<float> table(3 * weights.size());
        for (int c = 0; c < 3; ++c)
            for (size_t i = 0; i < weights.size(); ++i)
                table[size_t(c) * weights.size() + i] = float(weights[i]);
        gpu::BufferRef w = gpu->upload(table.data(), table.size() * sizeof(float), error);
        const float ones[3] = {1.0f, 1.0f, 1.0f};
        gpu::BufferRef wt = gpu->upload(ones, sizeof ones, error);
        Image next;
        next.h = cur.h; next.w = cur.w; next.c = 3;
        next.buf = gpu->alloc(cur.bytes(), error);
        if (!w || !wt || !next.buf) return false;
        // accumulate = 1 with acc = the input and weight 1 makes the pass
        // `acc + 1 * conv`, which is not what is wanted -- so the prefilter
        // uses accumulate = 0 and runs one axis at a time.
        const uint32_t meta[6] = {cur.h, cur.w, uint32_t(radius), uint32_t(axis), 0u, 1u};
        if (!gpu->dispatch("spk_sep_fir_acc",
                           {gpu::Arg::buf(cur.buf), gpu::Arg::buf(w), gpu::Arg::buf(cur.buf),
                            gpu::Arg::buf(wt), gpu::Arg::inline_bytes(meta, 6), gpu::Arg::buf(next.buf)},
                           cur.pixels(), error)) return false;
        cur = next;
    }
    out.h = oh; out.w = ow; out.c = 3;
    out.buf = gpu->alloc(out.bytes(), error);
    if (!out.buf) return false;
    const uint32_t meta[4] = {cur.h, cur.w, oh, ow};
    return gpu->dispatch("spk_zoom_bilinear_mirror",
                         {gpu::Arg::buf(cur.buf), gpu::Arg::inline_bytes(meta, 4), gpu::Arg::buf(out.buf)},
                         out.pixels(), error);
}

}  // namespace

// ---------------------------------------------------------------------------
// the C ABI
// ---------------------------------------------------------------------------

extern "C" {

const char* spk_build_info(void) {
    // The build stamp is what a bug report quotes, so it names the three
    // things that decide whether two builds render the same picture: the
    // engine's own version, the compiler date, and the Metal math mode the
    // kernels were compiled with.
    static const std::string info =
        std::string("spektrafilm-native 0.1.0 (") + __DATE__ " " __TIME__ ", math=safe)";
    return info.c_str();
}

const char* spk_last_error(spk_engine* engine) {
    (void)engine;
    return g_error.c_str();
}

void spk_string_free(char* s) { std::free(s); }

spk_engine* spk_engine_create(const char* resources_dir, void* device) {
    g_error.clear();
    if (!resources_dir) { g_error = "resources_dir is null"; return nullptr; }
    auto engine = std::make_unique<spk_engine>();
    engine->resources_dir = resources_dir;

    std::string error;
    if (!engine->blob.open(engine->resources_dir + "/spektrafilm_constants.bin", error)) {
        g_error = error;
        return nullptr;
    }
    if (!engine->colour.init(engine->blob, error)) { g_error = error; return nullptr; }

    const std::string filters_text = read_text_file(engine->resources_dir + "/neutral_print_filters.json");
    if (!filters_text.empty()) {
        std::string parse_error;
        if (!Json::parse(filters_text, engine->neutral_filters, parse_error)) {
            g_error = "neutral_print_filters.json: " + parse_error;
            return nullptr;
        }
    }

    engine->gpu = gpu::Gpu::create_metal(device, engine->resources_dir + "/spektrafilm.metallib", error);
    if (!engine->gpu) { g_error = error; return nullptr; }

    // RFC-014 §5.1 trap 1, checked rather than trusted. A build flag is the
    // kind of guard that stops being read; this asks the GPU what it actually
    // compiled, and refuses to start if the answer is fast math.
    std::string detail;
    if (!engine->gpu->check_math_mode(detail)) { g_error = detail; return nullptr; }
    engine->math_mode = detail;

    engine->cached_capabilities = engine->capabilities_json().dump();
    engine->cached_schema = transport_schema().dump();
    return engine.release();
}

void spk_engine_destroy(spk_engine* engine) {
    if (!engine) return;
    {
        std::lock_guard<std::mutex> guard(engine->lock);
        for (spk_session* s : engine->sessions) delete s;
        engine->sessions.clear();
    }
    delete engine;
}

const char* spk_capabilities(spk_engine* engine) {
    if (!engine) return "";
    std::lock_guard<std::mutex> guard(engine->lock);
    // Recomputed rather than served from the cache, because the session count
    // it reports changes -- the status bar reads it to tell "switching frames
    // is slow" from "the cache evicts on every switch".
    engine->cached_capabilities = engine->capabilities_json().dump();
    return engine->cached_capabilities.c_str();
}

const char* spk_params_schema(spk_engine* engine) {
    return engine ? engine->cached_schema.c_str() : "";
}

spk_status spk_warm_up(spk_engine* engine, const char* film_stock, const char* print_stock,
                       char** out_json) {
    if (!engine) { g_error = "engine is null"; return SPK_ERR_INVALID_ARG; }
    g_error.clear();
    const auto started = std::chrono::steady_clock::now();

    // RFC-013 §3: pay the fixed per-stock-pair setup while the boot window is
    // up. On this engine there is no interpreter to hide, so what is left is
    // the real work -- the tc_lut contraction and the 46,080-cell C_max
    // bisection -- and it is the same work `open` would otherwise do on the
    // frame the user is waiting for.
    Json steps = Json::array();
    auto step = [&](const char* name, bool ok, double ms, const std::string& detail) {
        Json entry = Json::object();
        entry.set("name", Json(std::string(name)));
        entry.set("ok", Json(ok));
        entry.set("ms", Json(std::round(ms * 100.0) / 100.0));
        if (!detail.empty()) entry.set("error", Json(detail));
        steps.push(std::move(entry));
    };

    const std::string film = film_stock && *film_stock ? film_stock : "kodak_portra_400";
    const std::string print = print_stock && *print_stock ? print_stock : "kodak_portra_endura";

    Params params;
    std::string error;
    auto t0 = std::chrono::steady_clock::now();
    bool ok = init_params(engine->resources_dir, film, print, engine->neutral_filters, params, error);
    step("profiles", ok, std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - t0).count(), ok ? "" : error);

    if (ok) {
        params.settings.working_precision = "float32";
        t0 = std::chrono::steady_clock::now();
        Pipeline pipeline(engine->gpu, &engine->colour, &engine->blob, &engine->setup_cache);
        const bool built = pipeline.build(params, error);
        step("pipeline", built, std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count(), built ? "" : error);
        ok = built;

        if (built) {
            // Run a small frame all the way through, so every kernel's
            // `MTLComputePipelineState` exists before the user's first frame
            // needs it.
            //
            // Measured, because the obvious claim for this is wrong: it does
            // *not* take 300 ms off the first reprint. Over seven runs the
            // median first reprint is 83 ms cold and 80 ms warmed. What it
            // removes is the tail -- worst case 160 ms cold against 86 ms
            // warmed -- because a pipeline state built on first use lands on
            // the frame the user is waiting for rather than on the boot
            // window. Worth 4 ms of warm-up for that alone; not worth
            // claiming more than it does.
            t0 = std::chrono::steady_clock::now();
            engine->gpu->begin_frame();
            std::string warm_error;
            // A small frame, but told it came from a *live-tier* one. The two
            // are decoupled on purpose: every blur's sigma is in micrometres
            // divided by the pixel pitch, so a 32 px frame that really was
            // 32 px has a pitch of 1093 um and every blur collapses to a
            // no-op -- warming nothing, in 3.7 ms. At the live tier's pitch
            // the halation and DIR-coupler tails cross into the IIR kernel,
            // which is the one a real frame actually pays for.
            constexpr uint32_t kEdge = 64;
            constexpr uint32_t kLiveLongEdge = 1600;
            std::vector<float> pixels(size_t(kEdge) * kEdge * 3, 0.18f);
            Image seed;
            seed.h = kEdge;
            seed.w = kEdge;
            seed.c = 3;
            seed.buf = engine->gpu->upload(pixels.data(), pixels.size() * sizeof(float), warm_error);
            bool warmed = static_cast<bool>(seed.buf);
            Image negative, rgb;
            if (warmed) {
                pipeline.set_source_long_edge(kLiveLongEdge);
                warmed = pipeline.run_film(seed, negative, nullptr, warm_error) &&
                         pipeline.run_print(negative, rgb, nullptr, warm_error) &&
                         engine->gpu->flush(warm_error);
            }
            engine->gpu->end_frame();
            step("kernels", warmed, std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - t0).count(), warmed ? "" : warm_error);
        }
    }

    Json out = Json::object();
    out.set("film_stock", Json(film));
    out.set("print_stock", Json(print));
    out.set("already_warm", Json(false));
    out.set("render_core", Json(std::string("native-metal")));
    out.set("total_ms", Json(std::round(std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count() * 100.0) / 100.0));
    out.set("steps", std::move(steps));
    if (out_json) *out_json = dup_json(out);
    // A warm-up step that fails is not fatal: the work is simply paid again
    // inside `open`, and the boot window reports it.
    return SPK_OK;
}

spk_session* spk_open(spk_engine* engine, const spk_image* input, const char* params_delta_json,
                      char** out_json) {
    if (!engine || !input || !input->data) { g_error = "engine or image is null"; return nullptr; }
    g_error.clear();
    if (input->channels != 3 && input->channels != 4) {
        g_error = "input image must have 3 or 4 channels";
        return nullptr;
    }
    const double mp = double(input->width) * double(input->height) / 1e6;
    if (mp > kMaxMP) {
        g_error = "image is " + std::to_string(mp) + " MP, above the engine limit of " +
                  std::to_string(int(kMaxMP)) + " MP";
        return nullptr;
    }

    Json delta = Json::object();
    if (params_delta_json && *params_delta_json) {
        std::string parse_error;
        if (!Json::parse(params_delta_json, delta, parse_error)) {
            g_error = "params_delta: " + parse_error;
            return nullptr;
        }
        std::string message, param;
        if (!validate_delta(delta, message, param)) { g_error = message; return nullptr; }
    }

    auto session = std::make_unique<spk_session>();
    session->engine = engine;
    session->session_id = "s" + std::to_string(next_id());

    std::string film = "kodak_portra_400", print = "kodak_portra_endura";
    if (delta.has("film_stock")) film = delta.at("film_stock").as_string();
    if (delta.has("print_stock")) print = delta.at("print_stock").as_string();

    std::string error;
    if (!init_params(engine->resources_dir, film, print, engine->neutral_filters,
                     session->params, error)) { g_error = error; return nullptr; }
    // The project convention, applied before the delta so an explicit
    // `output_color_space` still wins: ProPhoto RGB in, Display P3 out.
    session->params.io.output_color_space = "Display P3";
    session->params.io.output_cctf_encoding = true;
    apply_delta(session->params, delta);
    session->params.settings.working_precision = "float32";
    if (!digest(session->params, engine->neutral_filters, error)) { g_error = error; return nullptr; }

    // Uploaded as handed over, alpha and all; `spk_take_rgb` drops the fourth
    // channel on device below. Stripping it on the host would be a full-frame
    // CPU pass -- 543 MB of loads and stores at 45 MP.
    {
        engine->gpu->begin_frame();
        Image uploaded;
        uploaded.h = input->height;
        uploaded.w = input->width;
        uploaded.c = input->channels;
        const size_t bytes = uploaded.elements() * sizeof(float);
        std::string upload_error;
        if (input->channels == 3) {
            uploaded.buf = engine->gpu->upload_persistent(input->data, bytes, upload_error);
            session->source = uploaded;
        } else {
            uploaded.buf = engine->gpu->upload(input->data, bytes, upload_error);
            Image rgb;
            rgb.h = uploaded.h;
            rgb.w = uploaded.w;
            rgb.c = 3;
            if (uploaded.buf) rgb.buf = engine->gpu->alloc_persistent(rgb.bytes(), upload_error);
            const uint32_t meta[2] = {uint32_t(uploaded.pixels()), uploaded.c};
            if (!uploaded.buf || !rgb.buf ||
                !engine->gpu->dispatch("spk_take_rgb",
                                       {gpu::Arg::buf(uploaded.buf), gpu::Arg::inline_bytes(meta, 2),
                                        gpu::Arg::buf(rgb.buf)},
                                       uploaded.pixels(), upload_error) ||
                !engine->gpu->flush(upload_error)) {
                engine->gpu->end_frame();
                g_error = upload_error;
                return nullptr;
            }
            session->source = rgb;
        }
        engine->gpu->end_frame();
        if (!session->source.buf) { g_error = upload_error; return nullptr; }
    }

    session->pipeline = std::make_unique<Pipeline>(engine->gpu, &engine->colour, &engine->blob,
                                                  &engine->setup_cache);
    if (!session->pipeline->build(session->params, error)) { g_error = error; return nullptr; }

    Json meta = Json::object();
    meta.set("width", Json(double(input->width)));
    meta.set("height", Json(double(input->height)));
    meta.set("megapixels", Json(std::round(mp * 100.0) / 100.0));
    meta.set("source", Json(std::string("<in-process>")));

    // `detected_input` is the service's file sniffing, and the engine no
    // longer opens files: the caller decoded the frame and knows its encoding,
    // so it reports what it passed in. Kept in the reply because the frontend
    // reads it (contract §2's additive fields).
    Json detected = Json::object();
    detected.set("input_color_space", Json(session->params.io.input_color_space));
    detected.set("input_cctf_decoding", Json(session->params.io.input_cctf_decoding));
    detected.set("input_color_space_source", Json(std::string("caller")));

    Json out = Json::object();
    out.set("session_id", Json(session->session_id));
    out.set("meta", std::move(meta));
    out.set("detected_input", std::move(detected));
    out.set("params", read_params(session->params));
    out.set("capabilities", engine->capabilities_json());
    if (out_json) *out_json = dup_json(out);

    spk_session* raw = session.release();
    {
        std::lock_guard<std::mutex> guard(engine->lock);
        engine->sessions.push_back(raw);
    }
    return raw;
}

namespace {

// The source at a tier's resolution, built on first use. `open` needs the live
// tier and nothing else; the preview tier is needed only if the user zooms
// past 100 %, and building both eagerly put two full-resolution anti-aliased
// downscales of a 45 MP frame inside every open.
bool tier_image(spk_session* session, const Tier& tier, Image& out, std::string& error) {
    spk_session::TierState& state = session->tiers[tier.name];
    if (state.image.valid()) { out = state.image; return true; }
    gpu::Gpu* gpu = session->engine->gpu;
    // Already on the device, three channels, from `spk_open`.
    const Image& full = session->source;
    Image scaled;
    if (!downscale(gpu, full, tier.long_edge, scaled, error)) return false;
    if (scaled.buf.get() == full.buf.get()) {
        // At or below the tier: share the source itself. It is already
        // persistent, and another copy of a 45 MP frame is 543 MB.
        state.image = full;
    } else {
        // The downscale ran in the frame arena; copy the result into a
        // persistent buffer, because a tier image outlives the render that
        // built it and every subsequent render reads it.
        if (!gpu->flush(error)) return false;
        Image kept;
        kept.h = scaled.h; kept.w = scaled.w; kept.c = 3;
        kept.buf = gpu->upload_persistent(gpu->contents(scaled.buf.get()), scaled.bytes(), error);
        if (!kept.buf) return false;
        state.image = kept;
    }
    out = state.image;
    return true;
}

bool negative_for(spk_session* session, const Tier& tier, Progress* progress, Image& out,
                  std::string& error) {
    spk_session::TierState& state = session->tiers[tier.name];
    if (state.has_negative) { out = state.negative; return true; }
    Image source;
    if (!tier_image(session, tier, source, error)) return false;
    Image negative;
    if (!session->pipeline->run_film(source, negative, progress, error)) return false;
    // The negative is what every subsequent slider drag reprints from, so it
    // has to outlive the frame arena. Copying it here is also what makes a
    // reprint grain-consistent for free: the realisation is baked in and is
    // never redrawn.
    gpu::Gpu* gpu = session->engine->gpu;
    if (!gpu->flush(error)) return false;
    Image kept;
    kept.h = negative.h; kept.w = negative.w; kept.c = 3;
    kept.buf = gpu->upload_persistent(gpu->contents(negative.buf.get()), negative.bytes(), error);
    if (!kept.buf) return false;
    state.negative = kept;
    state.has_negative = true;
    out = kept;
    return true;
}

// The rgba16 result: a fresh buffer with texture-aligned rows, a texture over
// it, and the only reference handed to the caller. RFC-014 §2.2's zero copy,
// and the deletion of `_write_rgba16` -- 10 ms of a 30.6 ms reprint, and a
// 364 MB file at the full tier.
//
// A *fresh* buffer, not a pooled one, and not one kept per tier. The frontend
// keeps the last eight frames' live textures resident so switching frames is
// instant; a buffer the engine reused on the next render of the same tier
// would turn those cached textures into a different photograph without
// anything changing hands. So each render allocates, and the texture's own
// reference to the buffer is what keeps the pixels alive for exactly as long
// as the caller is looking at them.
bool materialise(spk_session* session, const Image& rgb, spk_result* out, std::string& error) {
    gpu::Gpu* gpu = session->engine->gpu;
    const uint32_t align = gpu->texture_row_alignment_px();
    const uint32_t stride = ((rgb.w + align - 1) / align) * align;
    const size_t bytes = size_t(stride) * rgb.h * 4 * sizeof(uint16_t);
    gpu::BufferRef buffer = gpu->alloc_persistent(bytes, error);
    if (!buffer) return false;

    const uint32_t meta[3] = {uint32_t(rgb.pixels()), rgb.w, stride};
    bool ok = gpu->dispatch("spk_to_rgba16",
                            {gpu::Arg::buf(rgb.buf), gpu::Arg::inline_bytes(meta, 3),
                             gpu::Arg::buf(buffer)},
                            rgb.pixels(), error) && gpu->flush(error);
    if (ok) {
        out->rgba16 = static_cast<const uint16_t*>(gpu->contents(buffer.get()));
        out->width = rgb.w;
        out->height = rgb.h;
        out->row_stride_px = stride;
        out->texture = gpu->texture(buffer.get(), rgb.w, rgb.h, stride, error);
        ok = out->texture != nullptr;
    }
    // Drop the engine's reference either way. On success the texture still
    // holds one, so the buffer lives; on failure it dies here.
    return ok;
}

spk_status render_tier(spk_session* session, const char* tier_name, bool use_reprint,
                       spk_result* out) {
    if (!session || !out) { g_error = "session or result is null"; return SPK_ERR_INVALID_ARG; }
    const Tier* tier = find_tier(tier_name);
    if (!tier) {
        g_error = std::string("unknown tier '") + (tier_name ? tier_name : "(null)") +
                  "'; expected live, preview or full";
        return SPK_ERR_INVALID_ARG;
    }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    std::memset(out, 0, sizeof *out);

    gpu::Gpu* gpu = session->engine->gpu;
    const auto started = std::chrono::steady_clock::now();
    session->progress = Progress{};
    session->progress.progress_id = "p" + std::to_string(next_id());
    // Opt-in, because turning it on serialises every node. See Progress.
    session->progress.detailed = std::getenv("SPEKTRAFILM_NODE_TIMINGS") != nullptr;

    gpu->begin_frame();
    std::string error;
    const bool had_negative = session->tiers[tier->name].has_negative;
    Image negative, rgb;
    // Before anything runs, and from the tier image rather than from whatever
    // the pipeline last saw: a print-layer rebuild hands us a fresh pipeline
    // that has never rendered a frame, and the negative it is about to reprint
    // may be one the *previous* pipeline made.
    Image tier_source;
    bool ok = tier_image(session, *tier, tier_source, error);
    if (ok) session->pipeline->set_source_long_edge(std::max(tier_source.h, tier_source.w));
    if (ok) ok = negative_for(session, *tier, &session->progress, negative, error);
    if (ok) ok = session->pipeline->run_print(negative, rgb, &session->progress, error);
    if (ok) ok = materialise(session, rgb, out, error);
    gpu->end_frame();

    if (!ok) {
        g_error = error;
        return error == "render cancelled" ? SPK_ERR_CANCELLED : SPK_ERR_GPU;
    }
    out->elapsed_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    out->reprint = use_reprint && had_negative ? 1 : 0;
    out->negative_was_cached = had_negative ? 1 : 0;
    std::snprintf(out->progress_id, sizeof out->progress_id, "%s",
                  session->progress.progress_id.c_str());
    session->progress.done = true;
    return SPK_OK;
}

}  // namespace

spk_status spk_reprint(spk_session* session, const char* tier, spk_result* out) {
    return render_tier(session, tier, /*use_reprint=*/true, out);
}

spk_status spk_render(spk_session* session, const char* tier, spk_result* out) {
    return render_tier(session, tier, /*use_reprint=*/false, out);
}

spk_status spk_set_params(spk_session* session, const char* params_delta_json, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    g_error.clear();
    Json delta;
    std::string parse_error;
    if (!params_delta_json || !Json::parse(params_delta_json, delta, parse_error)) {
        g_error = "params_delta: " + parse_error;
        return SPK_ERR_USER;
    }
    std::string message, param;
    if (!validate_delta(delta, message, param)) { g_error = message; return SPK_ERR_USER; }

    std::lock_guard<std::mutex> guard(session->lock);
    spk_engine* engine = session->engine;
    const bool shoot = delta_touches_shoot(delta);
    const bool stock_change = delta.has("film_stock") || delta.has("print_stock");
    const bool rebuild = stock_change || delta_needs_rebuild(delta);

    if (stock_change) {
        // A stock change rebuilds the parameter tree, because it needs a
        // profile load and a fresh digest. `settings` is carried across
        // deliberately: every field in it is a decision the *caller* made at
        // open, none is derived from a profile, and rebuilding it from
        // defaults is what silently replaced the GPU core with numba for the
        // rest of a session on the Python side.
        const SettingsParams settings = session->params.settings;
        Json current = read_params(session->params);
        for (const auto& kv : delta.fields()) current.set(kv.first, kv.second);
        Params fresh;
        std::string error;
        if (!init_params(engine->resources_dir,
                         current.at("film_stock").as_string(),
                         current.at("print_stock").as_string(),
                         engine->neutral_filters, fresh, error)) {
            g_error = error;
            return SPK_ERR_USER;
        }
        fresh.settings = settings;
        Json carry = Json::object();
        for (const auto& kv : current.fields())
            if (kv.first != "film_stock" && kv.first != "print_stock") carry.set(kv.first, kv.second);
        apply_delta(fresh, carry);
        if (!digest(fresh, engine->neutral_filters, error)) { g_error = error; return SPK_ERR_USER; }
        session->params = fresh;
    } else {
        apply_delta(session->params, delta);
    }

    if (rebuild) {
        std::string error;
        auto pipeline = std::make_unique<Pipeline>(engine->gpu, &engine->colour, &engine->blob,
                                                   &engine->setup_cache);
        if (!pipeline->build(session->params, error)) { g_error = error; return SPK_ERR_USER; }
        session->pipeline = std::move(pipeline);
    } else {
        // The live path: written straight onto the pipeline's own copy, which
        // re-derives the enlarger's cheap constants on the next print run.
        session->pipeline->apply_live_delta(delta);
    }

    if (shoot || (stock_change && delta.has("film_stock"))) {
        for (auto& kv : session->tiers) {
            if (kv.second.has_negative) {
                // Dropping the handle is the whole of it: the buffer goes back
                // to the pool for the film side to reuse on the re-render.
                kv.second.negative = Image{};
                kv.second.has_negative = false;
            }
        }
    }

    Json out = Json::object();
    out.set("invalidated", Json(std::string(shoot ? "shoot" : "print")));
    out.set("params", read_params(session->params));
    if (out_json) *out_json = dup_json(out);
    return SPK_OK;
}

spk_status spk_get_params(spk_session* session, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    std::lock_guard<std::mutex> guard(session->lock);
    if (out_json) *out_json = dup_json(read_params(session->params));
    return SPK_OK;
}

spk_status spk_solve(spk_session* session, const char* target, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    const std::string want = target && *target ? target : "both";
    if (want != "exposure" && want != "filter_pack" && want != "both") {
        g_error = "unknown solve target '" + want + "'";
        return SPK_ERR_USER;
    }
    std::lock_guard<std::mutex> guard(session->lock);
    g_error.clear();
    Json solved = Json::object();

    if (want == "exposure" || want == "both") {
        // The same measurement `preprocess.auto_exposure` makes, on the live
        // tier, reported rather than applied -- so the frontend can show the
        // number and the user can override it.
        gpu::Gpu* gpu = session->engine->gpu;
        gpu->begin_frame();
        Image live;
        std::string error;
        double ev = 0.0;
        bool ok = tier_image(session, kTiers[0], live, error) &&
                  session->pipeline->measure_exposure_ev(live, ev, error);
        gpu->end_frame();
        if (!ok) { g_error = error; return SPK_ERR_GPU; }
        solved.set("exposure_compensation_ev", Json(ev));
    }
    if (want == "filter_pack" || want == "both") {
        Params probe = session->params;
        probe.settings.neutral_print_filters_from_database = true;
        std::string error;
        if (!digest(probe, session->engine->neutral_filters, error)) {
            g_error = error;
            return SPK_ERR_INTERNAL;
        }
        solved.set("c_filter_neutral", Json(probe.enlarger.c_filter_neutral));
        solved.set("m_filter_neutral", Json(probe.enlarger.m_filter_neutral));
        solved.set("y_filter_neutral", Json(probe.enlarger.y_filter_neutral));
    }
    Json out = Json::object();
    out.set("solved_params", std::move(solved));
    if (out_json) *out_json = dup_json(out);
    return SPK_OK;
}

void spk_cancel(spk_session* session, const char* progress_id) {
    if (!session) return;
    // Deliberately not under the session lock: the render holds that lock for
    // its whole duration, so taking it here would make cancellation wait for
    // the thing it is cancelling. `cancelled` is read between nodes.
    if (!progress_id || session->progress.progress_id == progress_id)
        session->progress.cancelled = true;
}

spk_status spk_progress(spk_session* session, const char* progress_id, char** out_json) {
    if (!session) { g_error = "session is null"; return SPK_ERR_INVALID_ARG; }
    const Progress& p = session->progress;
    if (progress_id && *progress_id && p.progress_id != progress_id) {
        g_error = std::string("unknown progress id '") + progress_id + "'";
        return SPK_ERR_USER;
    }
    Json times = Json::object();
    for (const auto& kv : p.node_ms) times.set(kv.first, Json(kv.second));
    Json out = Json::object();
    out.set("progress_id", Json(p.progress_id));
    out.set("stage", Json(p.stage));
    out.set("pct", Json(p.done ? 100.0
                               : (p.total_nodes ? 100.0 * double(p.fired) / double(p.total_nodes) : 0.0)));
    out.set("node_times", std::move(times));
    out.set("done", Json(p.done));
    out.set("cancelled", Json(p.cancelled));
    if (out_json) *out_json = dup_json(out);
    return SPK_OK;
}

void spk_result_free(spk_result* result) {
    if (!result || !result->texture) return;
    // The engine kept no reference to hand back, so this is the caller's own
    // +1 going away -- and with it the buffer `rgba16` pointed into.
    gpu::Gpu::release_texture_static(result->texture);
    result->texture = nullptr;
    result->rgba16 = nullptr;
}

void spk_session_release(spk_session* session) {
    if (!session) return;
    spk_engine* engine = session->engine;
    {
        std::lock_guard<std::mutex> guard(engine->lock);
        for (size_t i = 0; i < engine->sessions.size(); ++i)
            if (engine->sessions[i] == session) {
                engine->sessions.erase(engine->sessions.begin() + long(i));
                break;
            }
    }
    // Every buffer the session held is a counted handle, so destroying it is
    // all the releasing there is.
    delete session;
}

}  // extern "C"
