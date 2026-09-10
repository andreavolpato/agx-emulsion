# Handoff: the native host, and what the frontend does about it

| | |
|---|---|
| **For** | FE (`modern_UI/**`), and whoever writes the C++ host next |
| **From** | BE, 2026-09-10 |
| **Status** | RFC-012 steps 1, 3, 4 landed. Step 5 (the host) not started. |
| **Wire** | **Unchanged, and expected to stay unchanged.** |

---

## 1. The short answer for FE: do nothing

The native host is a change of *what is on the other end of the pipe*. It is
not a change to the pipe.

`CONTRACT-frontend-backend.md` §1 is frozen: the same newline-delimited
JSON-RPC 2.0 over stdio, the same method names, the same `rgba16` file
handoff, the same three tier names, the same single-flight default. FE's
`ServiceClient.swift` should not need one line changed when the host lands,
and if it does, that is a bug in the host, not a migration for FE.

That is the entire reason RFC-012 §3.2 picks option C — "it is D with the
boundary still in place" — and the reason step 4 was done before the host
rather than after.

**So: keep building against the Python service.** When the host is ready both
will be runnable side by side and the switch is which binary gets spawned.

## 2. The one thing that will change, and it is additive

`capabilities.backend` gains a field saying which host answered:

```jsonc
"backend": {
  "render_core": "metal",     // unchanged: which executor renders
  "host": "python" | "native" // NEW, additive
}
```

Additive, so contract §2 says no version bump and no agreement needed. FE may
ignore it entirely; it exists so that a bug report says which binary produced
the picture.

**`render_core` must stay as honest in the host as it is now** — HANDOFF-GPU-WIRING
§0 is on the wall here. The current implementation probes what is *reachable*
(`mdev.available()`), which is a proxy rather than an observation, and the
host should report what the process actually loaded: the metallib it opened
and the MLX it linked. A self-report that cannot be wrong is not a report. If
the host cannot answer "which executor am I", FE has no way to say so either,
and that is exactly the session HANDOFF-GPU-WIRING describes.

## 3. What will *not* change, stated so nobody plans around it

- **Not the framing.** `transport_version` stays 1. FE's refusal path
  (`CapabilityNegotiationTests`, `86b30af`) should never fire because of the
  host swap. If the framing or the file-handoff convention ever has to change,
  it goes in contract §5 *before* it is built — not as a bumped number
  discovered at runtime.
- **Not the tier names.** `live` / `preview` / `full`, per contract §1.2.3.
- **Not `rgba16`.** Little-endian, row 0 = top, Display-P3 encoded, opaque
  alpha. Contract §1.2.1.
- **Not single-flight.** `configure_transport` stays opt-in and off by default.

## 4. What changes at option D, which is a separate RFC

D removes the process. That *does* touch FE, and it is not this handoff:
`_write_rgba16` and the file handoff disappear, which means FE's
`RenderScheduler` and its texture upload path change shape. RFC-012 §5.6 says
D needs its own RFC and a contract amendment, and that still holds. Nothing in
step 5 anticipates it beyond keeping the seam clean.

Worth knowing why D is worth the disruption, measured on this branch rather
than quoted from the RFC:

| tier | GPU render | `_write_rgba16` | handoff share |
|---|---|---|---|
| live | 14.3 ms | 14.2 ms | **50 %** |
| preview | 54.0 ms | 75.8 ms | **58 %** |
| full | 258.5 ms | 451.9 ms | **64 %** |

*(45.4 MP frame, M3 Max, warm, `core=metal`.)* RFC-012 §1.1 measured this at
33 % and called it the document's strongest argument. It is now half to
two-thirds, because RFC-011 made the render fast and left the handoff fixed.

## 5. State of the prerequisites

| step | what | state |
|---|---|---|
| 1 | MLX from a C++ host, byte-identical | **done** (`ee00a44`) — and `MathMode::Safe` is mandatory, pinned by a test |
| 2 | GPU resize | done earlier (`d8c4881`) |
| 3 | bake the colour constants | **substantially done** (`06e16be`) — a reprint loads no colour-science; `open` still does, at three CAM16-UCS sites |
| 4 | split the wire from the render | **done** (`f7b6c77`) — `service/engine.py` is the in-process API the host implements |
| 5 | the native host | not started |
| 6 | D | its own RFC |

**Step 3 is the gate on step 5, and it is not fully closed.** The host has to
construct the pipeline without Python, which means every per-session constant
must come from baked data. Three remain: `gamut_compression`'s
`XYZ_to_CAM16UCS` / `CAM16UCS_to_XYZ` (the CAM16-UCS C_max table) and one
`RGB_COLOURSPACES` lookup. `utils/fused_gamut_cam16.py` already implements the
same CIECAM16 model in numba, so this is routing, not new colour science.
`tests/test_rfc012_no_colour_at_render_time.py` carries it as an `xfail` that
names the three sites and turns green on its own when they are done.

## 6. For whoever writes the host

- The interface to implement is `service/engine.py`'s `RenderEngine`. It takes
  typed arguments and returns arrays. Do not implement `service.py` twice —
  the wire skin is small and the point is that it stays small.
- `scripts/gpu_native/native_host_spike/` is the working C++ example: how to
  link `libmlx.dylib`, how to hand MSL to `mlx::core::fast::metal_kernel`, and
  the parity harness shape.
- Keep `CompileOptions{MathMode::Safe}`. Relaxed math moved two of four spike
  kernels by up to 1.1e-5 absolute, past RFC-011's float32 storage epsilon,
  silently.
- numba stays the colour reference forever (RFC-011 §3.3), and so does
  colour-science now (`tests/test_rfc012_baked_colour.py`). Neither ships.
- `scripts/gpu_native/parity.py` is the small-frame parity run; use it on every
  change rather than once at the end.
