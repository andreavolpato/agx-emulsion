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

/* One rendered tier. `rgba16` is engine-owned and valid until the next
 * render on the same session or `spk_result_release`, whichever is first.
 *
 * `texture` is the same pixels as an `id<MTLTexture>` the caller may draw
 * directly -- RFC-014 §2.2's zero copy, and the reason `spk_engine_create`
 * takes the caller's device. It is NULL when the engine could not share
 * (no device passed in); `rgba16` is always present.
 */
typedef struct {
    const uint16_t* rgba16;
    void*           texture;
    uint32_t        width;
    uint32_t        height;
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

/* `out_json` receives `{"invalidated": ..., "params": {...}}`. */
spk_status spk_set_params(spk_session* session, const char* params_delta_json,
                          char** out_json);
spk_status spk_get_params(spk_session* session, char** out_json);

/* `target` is "exposure", "filter_pack" or "both". */
spk_status spk_solve(spk_session* session, const char* target, char** out_json);

/* Tiers are the three API-SPEC §6 names: "live", "preview", "full". */
spk_status spk_reprint(spk_session* session, const char* tier, spk_result* out);
spk_status spk_render(spk_session* session, const char* tier, spk_result* out);

void spk_result_release(spk_session* session);
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
