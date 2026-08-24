# RFC-003: Pipeline Decoupling

| | |
|---|---|
| Status | Proposed (M2) |
| Date | 2026-08-24 |
| Depends on | RFC-001 (M1, M1.5), RFC-002 (M1.6) |
| Scope | `runtime/topology.py`, `runtime/pipeline.py`, `runtime/stages/*` |
| Enables | M2.5 (half-resolution lanes), M3 (Metal port), tiling |

---

## 1. Motivation

### The profile is flat

16 MP, Portra 400 → Portra Endura, full quality, after M1.6 (9.78 s total):

| stage | sub-step | time |
|---|---|---|
| scanning | `compress_rgb` (CAM16-UCS) | 1.63 s |
| preprocess | float64 upcast + crop/rescale | 1.53 s |
| filming.expose | spectral upsampling | 1.49 s |
| filming.develop | grain | ~1.50 s |
| filming.expose | halation | 1.24 s |
| filming.develop | curves + DIR couplers | ~0.60 s |
| printing.expose | | 0.73 s |
| scanning | blur, unsharp, spectral, XYZ→RGB, cctf | ~0.60 s |

**Five items between 1.2 s and 1.7 s, and no bottleneck.** This is a
consequence of the previous three milestones: RFC-001 flattened the spectral
integrals (63 GB → 24 B/px), M1.5 flattened gamut compression (8.52 → 1.63 s),
M1.6 flattened grain (15.9 → 1.5 s). Each milestone found one dominant term
and removed it. There is no longer a dominant term to find.

Amdahl's law now bites hard: **eliminating any single line above buys at most
~15%.** Reaching a meaningful speedup requires acting on four or five of them,
which means the work has to shift from *optimising a hotspot* to *building a
mechanism that can be applied repeatedly*.

### The current granularity blocks that mechanism

The topology has six nodes. `filming.expose` alone performs spectral
upsampling, exposure compensation, highlight boost, a diffusion filter, lens
blur, in-emulsion scatter, back-reflection halation, and a log conversion —
eight effects spanning four different kernel shapes, behind one `run`
callable.

Three specific barriers follow, and this RFC exists to remove them.

**Decoupling itself makes nothing faster.** No measurement in this document
claims otherwise. It is an enabling change: it converts a set of currently
unimplementable optimisations into implementable ones.

---

## 2. The three barriers

### 2.1 Residency

The MLX spectral kernel is invoked *inside* a stage: NumPy → MLX → kernel →
NumPy, measured at 17.2 ms round trip for 16 MP. Cheap once. Port five effects
the same way and the arithmetic inverts:

| | kernels | host↔device transfers |
|---|---|---|
| five effects ported in isolation | ~250 ms | ~170 ms |

Transfers become roughly **40% of the post-port runtime**. The fix — keep a
*run* of GPU-capable effects device-resident, paying one upload and one
download for the whole run — requires the node to be the unit of backend
dispatch. It cannot be expressed inside a monolithic stage whose boundaries
are NumPy by construction.

This is the barrier that most directly converts into wall time, and it is why
the GPU port should not begin before this RFC lands.

### 2.2 Granularity

Porting `filming.expose` today means porting eight heterogeneous effects at
once, validating them jointly, with any single failure blocking the rest.
Split, it becomes eight independent ports, each testable against its own tap
with the existing harness. Same total work; incremental and verifiable rather
than one unfalsifiable rewrite.

### 2.3 Spatial support

A node's spatial support is the composition of everything inside it, and
halation's support is effectively global. So the monolith forces worst-case
halos, which makes tiling **impossible** rather than merely inefficient.
Per-node support declarations are what make a halo finite and a tile
schedulable.

### 2.4 What is *not* a motivation: bandwidth

The intuitive case for fusion is memory traffic. It does not survive
measurement. A `(H,W,3)` float64 at 16 MP is 384 MB; this machine moves
~300 GB/s:

$$\frac{384\ \text{MB} \times 2}{300\ \text{GB/s}} \approx 2.6\ \text{ms per boundary}$$

Across ~15 pointwise boundaries that is **~40 ms of 9780 ms, or 0.4%**. These
stages are compute-bound, not bandwidth-bound — the same finding as RFC-001's
float16 result, where halving the data moved gave no speedup at all.

**Fusion in this pipeline is a memory optimisation, not a speed
optimisation.** It is still worth doing (§4.2), for the right reason.

---

## 3. Design

### 3.1 Effect contracts

`Node` gains declarative metadata. Everything else in this RFC consumes it.

| field | purpose |
|---|---|
| `kind` | `pointwise` \| `spatial` \| `stochastic` — determines kernel shape and whether tiling needs a halo |
| `support(params)` | halo radius in pixels; `0` for pointwise, `inf` for global operators |
| `is_identity(params)` | whether current parameters make this node a no-op |
| `backend` | which backends can execute it |
| `precision` | lowest dtype this node tolerates |

`kind` already exists informally in `ARCHITECTURE.md §3`; this promotes it from
prose to something the dispatcher can act on.

### 3.2 The split

Roughly six nodes become roughly twenty:

| current | becomes |
|---|---|
| `preprocess` | `input_cast`, `auto_exposure`, `crop_rescale` |
| `filming.expose` | `upsample`, `exposure`, `diffusion_filter`, `lens_blur`, `scatter`, `halation`, `log` |
| `filming.develop` | `curves`, `dir_couplers`, `grain` |
| `printing.expose` | `enlarger_spectral`, `print_exposure` |
| `printing.develop` | `print_curves`, `print_glare` |
| `scanning.scan` | `scan_spectral`, `bw_correction`, `glare`, `xyz_to_rgb`, `gamut_compress`, `scanner_blur`, `unsharp`, `cctf` |

`Tap` becomes a namespace rather than a fixed enum; the seven canonical taps
stay addressable by name so existing debugging and `collect=` calls keep
working.

### 3.3 Graph rewriting passes

With contracts in place the dispatcher becomes a small compiler. Four passes,
in order:

**Dead node elimination.** A node whose `is_identity(params)` holds is dropped
along with its buffer. This is what the GUI's feature toggles do by hand, done
automatically and — unlike the toggles — reclaiming the memory too. Note that
`apply_diffusion_filter_um` and `apply_gaussian_blur_um` already measure at
0.0 ms under default parameters: they early-return internally but still sit
inside the monolith holding its structure. Elision makes that visible to the
scheduler.

**Pointwise fusion.** Chain adjacent `pointwise` nodes into a single kernel.
For memory (§4.2), not speed (§2.4).

**Residency planning.** Assign backends so that maximal runs of GPU-capable
nodes execute device-resident, with transfers only at run boundaries. Directly
addresses §2.1.

**Buffer liveness and reuse.** The general form of the tap freeing landed in
M1.6: compute live ranges over the rewritten graph, reuse buffers whose ranges
do not overlap, and mark in-place-safe nodes.

### 3.4 Incremental recompute

Hash `(node identity, param digest, input hash)` and cache the resulting tap;
a parameter change invalidates only its node and everything downstream.
`digest_params` already exists, so the harder half is done.

This does not improve throughput at all. It changes interactive latency:
adjusting gamut compression re-runs one node instead of the whole graph, and
most look-development edits go from 9.78 s to sub-second. For the way this
tool is actually used, that is the largest perceived improvement in this
document.

### 3.5 Per-node precision policy

RFC-002 §4.2 found that `working_precision='float32'` is numerically free
(ΔE max 1.4e-4, PSNR 172 dB) and saves **zero memory**, because
colour-science promotes back to float64 at the first colourspace conversion.
Casting at the pipeline entrance cannot survive that.

Casting at *every node boundary* can. With `precision` declared per node the
dispatcher re-casts after each node, so a promotion inside one node cannot
propagate. This is worth roughly another 2× on peak memory and is the single
largest remaining memory lever.

---

## 4. Sequencing

### 4.1 Split and fuse must land together

**Splitting without fusing makes memory worse.** More nodes means more
boundaries means more simultaneously-live buffers — it would undo the M1.6 tap
freeing. Buffer liveness (§3.3) must be in place *before* node count rises.

Recommended order: contracts → liveness → split → fusion → elision →
residency. Only the last enables the GPU work.

### 4.2 Memory is the acceptance criterion, not speed

M2 should be judged on peak RSS, because that is where its own passes act.
Current state, 45 MP full quality: **15.64 GB, 348 B/px**, with the high-water
mark set entirely in the first two nodes:

| step | Δ B/px |
|---|---|
| `rgb_to_film_raw` (spectral upsampling) | +93 |
| `apply_halation_um` | +96 |
| grain | +83 |
| everything downstream of `cmy_film` | +17 total |

Target: **≤ 200 B/px at 45 MP (~9 GB)** via liveness, fusion and per-node
precision, with wall time no worse than today.

---

## 5. What this unblocks

**M3 — Metal port.** Ranked by expected return, given the flat profile:

1. `compress_rgb` (1.63 s) — pointwise, ~40 transcendentals per pixel across
   the CIECAM16 forward and inverse, no data-dependent branching. The largest
   CPU/GPU capability gap in the pipeline, and it has nowhere else to go: the
   LUT failed at 6.9e-3 and chunk-parallelism already took the easy 7×.
2. spectral upsampling (1.49 s) — the hot operation is a bicubic lookup into a
   192×192×3 table (442 KB, fits in texture cache); Metal does bilinear in
   hardware.
3. halation (1.24 s) — separable convolution, and the only candidate that
   fixes a time hotspot and a memory hotspot in one change.
4. grain (~1.5 s) — RFC-002 §3.5 already specifies the kernel (Philox on
   global `(x,y)`, branchless Cornish–Fisher). Built regardless, since
   counter-based RNG is a hard prerequisite for tiling.

**Not a porting target: `preprocess` (1.53 s).** It is a float64 upcast plus
`crop_and_rescale`, not colour science. The fix is to stop upcasting and skip
the resample when the scale factor is 1 — likely the cheapest item on the
whole list, with no kernel written.

**M2.5 — half-resolution lanes (phone-oriented).** Deferred deliberately, and
gated on an unresolved risk. Measured on the worst-gradient 1024² crop:

| strategy | ΔE mean | ΔE p99 | ΔE max |
|---|---|---|---|
| naive: upsample the output | 0.3849 | 2.1033 | **8.7902** |
| delta: upsample `out − in` | 0.0000 | 0.0003 | **0.0185** |

The correction-transfer form is four orders of magnitude below visibility on
`compress_rgb` and gives 4.31× on that stage. But that is **one stage, one
crop**, and the failure mode of the naive form is precisely edge ringing and
softening — concentrated exactly where the metric mean hides it (0.385 reads
as "fine"; the max of 8.79 is the tell). Edge integrity is the gating concern
and it is not yet settled. M2.5 needs per-stage verification on high-gradient
crops using p99 and max, never whole-image mean, before any of it ships.

It also depends on this RFC: half-resolution lanes are a graph rewriting pass
over `kind`-annotated nodes, and cannot be expressed against the current
topology.

**Tiling.** Requires §3.1 `support` and counter-based RNG. Converts memory
from linear in pixel count to O(tile + halo) — the difference between "45 MP
fits if you close Capture One" and "any resolution fits in a fixed budget".
Own RFC.

---

## 6. Test plan

No new harness. RFC-001 §6 already distinguishes deterministic from
stochastic comparison, and M1.6 exercised both.

- **Per-node equivalence.** Every split node is checked against the
  pre-split pipeline at its own tap. A split is correct only if it is
  bit-identical; any node that is not must be justified individually.
- **End-to-end regression.** `--no-glare`, no grain: bit-identical
  (`np.array_equal`). With grain: `compare.py --mode stochastic`.
- **Memory as a gate.** 45 MP peak RSS recorded per milestone against the
  §4.2 target. A pass that raises peak RSS fails, whatever it does to time.
- **Rewriting passes are checked against the unrewritten graph**, so the
  optimiser is verified separately from the split.

---

## 7. Risks

| risk | mitigation |
|---|---|
| Split without fusion raises peak RSS | §4.1 ordering; §4.2 memory gate |
| Node explosion makes the graph unreadable | Keep the seven canonical taps addressable by name; `collect=` must keep working |
| Rewriting passes introduce silent numerical drift | Every pass validated against the unrewritten graph, not just end to end |
| Effort spent on a mechanism that never pays | M2 must not be merged before at least one M3 port lands on top of it and demonstrates the residency win |
| Incremental caching serves stale taps | Hash inputs, not just params; `digest_params` is necessary but not sufficient |

---

## 8. Non-goals

- No GPU kernels. M3.
- No half-resolution lanes. M2.5, and gated on §5's edge-integrity question.
- No tiling. Own RFC.
- No change to rendered output. M2 is a refactor; any pixel change is a bug.
