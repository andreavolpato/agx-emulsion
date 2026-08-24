# Handoff: the render-service IPC contract (for a fresh session)

**Status:** not started. This file is the brief, not the design.

**Context you need first:** `AGENTS.md`, `ARCHITECTURE.md`, and
`rfc/RFC-005` §7 + `rfc/RFC-007` §8. Do not trust performance numbers written
before RFC-007 §8.3 — the profile changed shape.

---

## 1. What is being built and why

Spektrafilm is becoming a standalone Apple-Silicon-only desktop app: a Tauri
front-end over a local render service, with Capture One interop via TIFF
in/out. Open source (GPLv3, upstream Andrea Volpato) — that is settled, and it
is what makes the standalone-app path viable where a Photoshop plugin was not.

This task is **only** the IPC contract between the front-end and the render
backend. It is deliberately a separate session because it is a design problem,
not an optimisation one, and because wiring a UI to an unspecified interface
means rewriting the UI when the interface changes.

## 2. Why this must come before any Tauri work

The backend is fast enough to build a product on (12.9 s at 45 MP, down from
40.9 s), but the *interface* has three gaps that a UI will immediately expose:

1. **There is no cancellation.** `SimulationPipeline.process` runs to
   completion. A 13-second render a user cannot abort is unacceptable in a
   desktop app. `run_topology`'s `on_fire` hook is the natural interrupt point
   and already exists — it fires after every node.
2. **There is no progress reporting.** Same hook; `get_timings()` already
   returns per-node times, so per-node progress is available.
3. **The parameter schema has never crossed a process boundary.**
   `RuntimePhotoParams` is a Python dataclass tree consumed via
   `digest_params(...)`. Something has to define what goes over the wire, and
   what `digest_params(apply_stocks_specifics=True)` means on the far side.

## 3. Constraints that are already measured — do not re-litigate

- **Cold start is 1.78 s** (`import spektrafilm.runtime`), plus ~0.4 s of numba
  JIT on first render, cached to disk thereafter. The service must be
  long-lived; a process-per-render design pays 1.78 s every time.
- **Peak RSS is ~13.9 GB at 45 MP** (~300 B/px). One render at a time. The
  contract needs a queue, not concurrent renders.
- **Never call a `parallel=True` numba kernel from a thread pool** — numba's
  `workqueue` layer is not threadsafe and aborts the *process*. A threaded
  request handler around the pipeline will crash it. See RFC-007 §8.5.
- **QoS matters enormously.** A background-QoS process runs the same work
  **6.2× slower** (RFC-007 §4.2). A spawned helper can inherit or be demoted to
  background QoS. The service must assert `QOS_CLASS_USER_INTERACTIVE` at
  startup and should report its own QoS so the failure is visible rather than
  silent.
- **`unpooled_device_memory` sets `mx.set_cache_limit(0)` process-globally**
  and is not reentrant. Fine in a dedicated render process; revisit if the
  service ever shares an interpreter with another MLX user.
- **Lazy kernel globals** (`_gauss_kernel`, `_curve_kernel`, `_kernel`,
  `_SPECTRAL_LOCUS_XY_CACHE`) race on concurrent first call. Single-flight
  request handling avoids this; concurrent handling does not.

## 4. What to design

- Transport (localhost HTTP? stdio JSON-RPC? Unix socket?) and the argument for
  the choice, given a long-lived single-render-at-a-time service.
- Request/response schema for: render (full-res), preview render, cancel,
  progress, capability/version handshake.
- How the image crosses the boundary. A 45 MP float32 buffer is 0.54 GB —
  serialising it through JSON is not viable. Consider shared memory or a
  file-path handoff (which also suits the Capture One TIFF workflow).
- Parameter schema versioning: the front-end and backend will ship separately.
- Error taxonomy: what is a user error (bad file), a resource error (OOM at
  45 MP), and a bug.

## 5. Explicitly out of scope here

The C++ port (RFC-007 §5 D, deferred), RFC-006 (float32 colour accuracy), and
any further optimisation. Note that the profile is now **spatial-dominated**
(halation 26%, dir_couplers 19%) and neither fuses the way the pointwise stages
did — so re-measure before planning any of it.

## 6. Repo hygiene, pre-existing

Three tests fail on `main`, unrelated to recent work — one references a stale
field (`GrainParams.mult_usm_amount`), and `markdown` is declared in
`pyproject.toml` but missing from the venv (`tests/lut_creator/qa/
test_html_export.py` cannot import). Worth clearing before adding a service
layer on top.
