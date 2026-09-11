/*  spk_engine.h -- the whole surface of the Spektrafilm render engine.
 *
 *  RFC-014 §2.1. A hand-written C ABI, not Swift's C++ interop, for three
 *  reasons that all still hold on Xcode 26.6 / Swift 6.3:
 *
 *    - It is ABI-stable. C++ name mangling, std:: layouts and Swift's
 *      interop rules all move between toolchains; this does not.
 *    - It is drivable from three languages. Swift links it, the C++ tests
 *      call it, and `ctypes` loads the *shipping* dylib -- which is what
 *      keeps the numba parity oracle pointed at the code that ships rather
 *      than at a copy of it (RFC-014 §3).
 *    - It forces the boundary to stay narrow. Direct interop makes it easy
 *      to leak a std::vector<Node> across the line and rebuild the transport
 *      problem in a new form.
 *
 *  Three rules hold everywhere below:
 *
 *  1. **Nothing throws.** Every entry point is noexcept. Failure is a
 *     negative `spk_status` plus a message from `spk_last_error`. A C++
 *     exception unwinding into Swift is undefined behaviour.
 *  2. **Ownership never crosses.** The caller owns the device, the input
 *     pixels and the strings it passes in. The engine owns everything it
 *     allocates and frees it in the matching `_release`/`_free`. No buffer
 *     is freed by the side that did not allocate it.
 *  3. **Parameters are JSON.** They are small, the schema already exists
 *     (`service/schema.py`), and a struct-per-parameter surface would break
 *     every time a slider is added -- the thing contract §1 exists to
 *     prevent.
 */
#ifndef SPEKTRAFILM_SPK_ENGINE_H
#define SPEKTRAFILM_SPK_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- versions ---------------------------------------------------------
 * These are the same two numbers `service/capabilities` reports, and they
 * mean the same thing: the frontend refuses a transport it does not speak
 * and warns on a schema it does not speak (contract §2). Keeping the values
 * identical to the Python service is deliberate -- the wire did not change
 * when the engine did.
 */
#define SPK_TRANSPORT_VERSION 1
#define SPK_SCHEMA_VERSION    1

typedef int32_t spk_status;
enum {
    SPK_OK                 =  0,
    SPK_ERR_INVALID_ARG    = -1,   /* a null pointer, a bad tier, a bad enum   */
    SPK_ERR_USER           = -2,   /* the caller asked for something wrong     */
    SPK_ERR_RESOURCE       = -3,   /* out of memory, image too large           */
    SPK_ERR_UNSUPPORTED    = -4,   /* a configuration this build cannot render */
    SPK_ERR_GPU            = -5,   /* device, library or dispatch failed       */
    SPK_ERR_IO             = -6,   /* a resource file is missing or corrupt    */
    SPK_ERR_CANCELLED      = -7,
    SPK_ERR_INTERNAL       = -8    /* a bug here, not out there                */
};

typedef struct spk_engine  spk_engine;
typedef struct spk_session spk_session;

/* A caller-owned, tightly packed float32 image. `data` stays valid for the
 * duration of the call it is passed to; the engine copies what it keeps. */
typedef struct {
    const float* data;
    uint32_t     width;
    uint32_t     height;
    uint32_t     channels;   /* 3 or 4; a 4th channel is dropped at the door */
} spk_image;

/* The same image, already in GPU-visible memory: `buffer` is an
 * `id<MTLBuffer>` **on the engine's own device**, holding tightly packed
 * float32 pixels, top row first. Borrowed exactly as `spk_image.data` is --
 * valid for the duration of the call, not retained after it -- so the
 * caller may reuse or free it the moment the call returns.
 *
 * It exists so a caller that renders its frame into shared memory does not
 * pay a host copy the engine would immediately repeat: `spk_open` copies the
 * pixels into a Metal buffer before its first kernel, which at 45 MP is
 * 727 MB and ~235 ms. Refused, with a message, when the buffer belongs to
 * another device or is shorter than `width * height * channels * 4` bytes. */
typedef struct {
    void*    buffer;
    uint32_t width;
    uint32_t height;
    uint32_t channels;   /* 3 or 4; a 4th channel is dropped at the door */
} spk_device_image;

/* One rendered tier.
 *
 * **This struct is the one exception to rule 2 above**, and it is worth
 * reading before using it. `texture` is an `id<MTLTexture>` over the rendered
 * pixels, returned **+1: the caller owns it**. In Swift that means
 * `takeRetainedValue()` and ARC; in C it means `spk_result_free` when done.
 *
 * The exception exists because the caller caches these. The frontend keeps the
 * last eight frames' live textures resident so switching frames is instant, so
 * a texture whose pixels the engine reuses on the next render of the same tier
 * would silently become a different photograph. Each render therefore gets its
 * own buffer, and handing over the only reference is what ties that buffer's
 * lifetime to the caller's use of it rather than to the engine's next frame.
 *
 * `rgba16` points into the texture's own memory, so it is valid for exactly as
 * long as `texture` is retained. It is there for callers that want the pixels
 * rather than something to draw -- the parity harness reads it, and it is the
 * same rows `service._write_rgba16` used to put in a file.
 */
typedef struct {
    const uint16_t* rgba16;
    void*           texture;
    uint32_t        width;
    uint32_t        height;
    /* Row pitch of `rgba16`, in pixels, which is `width` rounded up to the
     * device's linear-texture alignment. It is reported rather than left for
     * the caller to re-derive: the alignment is queried from the device
     * (`minimumLinearTextureAlignmentForPixelFormat`), not a constant, and a
     * caller that assumed 256 bytes read past the end of the buffer. */
    uint32_t        row_stride_px;
    double          elapsed_ms;
    int32_t         reprint;              /* 1 if the negative was reused   */
    int32_t         negative_was_cached;
    char            progress_id[40];
} spk_result;

/* --- engine ----------------------------------------------------------- */

/* `resources_dir` holds what `engine/tools/bake_resources.py` wrote plus the
 * compiled `spektrafilm.metallib`. `device` is the caller's `MTLDevice`
 * (an `id<MTLDevice>`, retained by the engine for its lifetime); pass NULL
 * to let the engine create its own, which the parity harness does. */
spk_engine* spk_engine_create(const char* resources_dir, void* device);
void        spk_engine_destroy(spk_engine* engine);

/* JSON, engine-owned, valid until the next call on this engine:
 *   capabilities  -> the `capabilities` reply, verbatim
 *   params_schema -> the `params_schema` reply, verbatim
 * Both exist so the frontend keeps asking the same two questions it asked
 * the Python service, and gets the same two answers.
 */
const char* spk_capabilities(spk_engine* engine);
const char* spk_params_schema(spk_engine* engine);

/* Pay the fixed per-stock-pair setup before the user is looking (RFC-013 §3).
 * Idempotent. `out_json` receives the `warm_up` reply. */
spk_status spk_warm_up(spk_engine* engine, const char* film_stock,
                       const char* print_stock, char** out_json);

/* --- session ---------------------------------------------------------- */

/* Open one frame. `params_delta_json` may be NULL. `out_json` receives the
 * `open` reply (session id, meta, detected input, resolved params). */
spk_session* spk_open(spk_engine* engine, const spk_image* input,
                      const char* params_delta_json, char** out_json);

/* `spk_open` with the pixels already on the device (see `spk_device_image`).
 * Same reply, same session, same source: the two differ only in how the
 * frame reaches the GPU, and share every line after that. */
spk_session* spk_open_device(spk_engine* engine, const spk_device_image* input,
                             const char* params_delta_json, char** out_json);

/* `out_json` receives `{"invalidated": ..., "params": {...}}`. */
spk_status spk_set_params(spk_session* session, const char* params_delta_json,
                          char** out_json);
spk_status spk_get_params(spk_session* session, char** out_json);

/* `target` is "exposure", "filter_pack" or "both". */
spk_status spk_solve(spk_session* session, const char* target, char** out_json);

/* Tiers are the three API-SPEC §6 names: "live", "preview", "full". */
spk_status spk_reprint(spk_session* session, const char* tier, spk_result* out);
spk_status spk_render(spk_session* session, const char* tier, spk_result* out);

/* --- the baked print+scan LUTs ----------------------------------------
 *
 * Three methods that used to live in Python and be refused here by name
 * (ARCHITECTURE §8.8). What they share is one asset: the eight print-preview
 * LUTs `scripts/bake_all_print_luts.py` baked and validated, now inside
 * `spektrafilm_constants.bin` with their metadata in `print_luts.json`.
 *
 * Neither method includes `scanning.glare`, and that is the design rather
 * than a gap: glare is a spatial, stochastic veiling field and cannot be
 * represented in a pointwise table. It costs mean abs 0.00085 -> 0.00177
 * against a production render (HANDOFF-PRINT-LUT §2). A finished print still
 * goes through `spk_reprint`, which has glare.
 */

/* Which print stocks have a shipped LUT, as the `print_luts.json` index
 * verbatim: an object keyed by stock, each with `paired_film`,
 * `declared_pairing`, `lut_size`, `output_color_space` and
 * `output_cctf_encoding`. Engine-owned; "{}" when none are bundled. */
const char* spk_print_lut_catalog(spk_engine* engine);

/* One stock's table, as tightly packed float32 in (S, S, S, 3) row-major
 * order -- the `.cube` writer's input, and the only thing on this surface
 * that is neither JSON nor a texture.
 *
 * Engine-owned and valid for the engine's lifetime: the table is loaded from
 * the blob on first use and cached, so the pointer stays good and must not be
 * freed. `*out_size` is S. */
spk_status spk_print_lut_table(spk_engine* engine, const char* print_stock,
                               const float** out_table, uint32_t* out_size);

/* Flip between print stocks by table lookup instead of by re-rendering the
 * print+scan chain: the session's cached negative for `tier`, through the
 * trilinear kernel. Measured at 45 MP, warm, against a reprint of the same
 * tier: 2.0 ms against 9 at live, 9.5 against 34 at preview, 47 against 167
 * at full.
 *
 * `out` is a texture exactly as `spk_reprint` leaves one, and is owned by the
 * caller the same way. `out_json` receives `apply_ms`, `tier`, `paired_film`,
 * `declared_pairing`, and a `warning` when the session's film is not the one
 * the LUT was baked against -- the table is coupled to the negative's dye
 * spectra as well as to the paper, so a mismatched film is an approximation
 * with unmeasured error (PRD §7.3). */
spk_status spk_preview_stock_lut(spk_session* session, const char* print_stock,
                                 const char* tier, spk_result* out, char** out_json);

/* The DI package's picture half: the full-tier negative normalised to [0, 1]
 * by the LUT's own per-channel density axes, so the `.cube` the caller writes
 * from `spk_print_lut_table` has domain 0..1 and needs no DOMAIN_MIN/MAX
 * support in whatever opens it.
 *
 * `print_stock` may be NULL, meaning the session's own. `out_json` carries
 * `print_stock`, `paired_film`, `declared_pairing` and the same mismatch
 * `warning`. Layer 2 does not apply to this image and must not be baked into
 * it: it is pre-print by definition. */
spk_status spk_export_di(spk_session* session, const char* print_stock,
                         spk_result* out, char** out_json);

/* Release a result's texture (and with it the pixels `rgba16` points at).
 * Do **not** call it after taking ownership of `texture` in a language with
 * its own reference counting -- Swift's `takeRetainedValue()` already did. */
void spk_result_free(spk_result* result);
void spk_session_release(spk_session* session);

/* --- cancellation ------------------------------------------------------
 * `spk_cancel` is safe to call from another thread while a render is in
 * flight; the render unwinds at the next node boundary and returns
 * SPK_ERR_CANCELLED.
 */
void spk_cancel(spk_session* session, const char* progress_id);
spk_status spk_progress(spk_session* session, const char* progress_id, char** out_json);

/* --- strings and errors ------------------------------------------------ */

/* Frees a `char*` an `out_json` produced. Never call it on the return of
 * `spk_capabilities` / `spk_params_schema` / `spk_last_error`, which the
 * engine owns. */
void spk_string_free(char* s);

/* The last failure on this engine, on this thread. Never NULL; "" when
 * nothing has failed. Valid until the next failed call on this thread. */
const char* spk_last_error(spk_engine* engine);

/* Build identity, for `capabilities.backend` and for a human reading a bug
 * report: version, git-ish build stamp, the Metal math mode the kernels were
 * compiled with, and whether the fast-math probe agreed with it. */
const char* spk_build_info(void);

#ifdef __cplusplus
}  /* extern "C" */
#endif
#endif /* SPEKTRAFILM_SPK_ENGINE_H */
