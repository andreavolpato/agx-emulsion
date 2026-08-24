# RFC-005: Where the GPU Time Actually Goes — Dispatch, Residency, Kernel Quality

| | |
|---|---|
| **Status** | P0 implemented; P1-P3 proposed |
| **Date** | 2026-08-24 |
| **Depends on** | RFC-001 (Metal/MLX backend), RFC-003 (decoupling), RFC-004 (float32 GPU port, P0–P2 landed) |
| **Scope** | `backends/mlx_ops.py`, `runtime/topology.py`, `runtime/pipeline.py` |
| **Hardware of record** | Apple M3 Max, 30-core GPU, MLX 0.32.1, macOS 25.5 |
| **Supersedes** | the "rewrite the GPU path against bare Metal (metal-cpp / PyObjC) instead of calling Metal through Python" proposal |

---

## 1. Motivation

The 45 MP frontend render is at ~22.6 s after RFC-003 + RFC-004 P0–P2
(~45% off the 40.9 s pre-split baseline). Two candidate directions were on the
table for the next round:

1. move every GPU stage off Python and onto bare Apple Metal (metal-cpp or
   PyObjC), on the theory that the Python call layer is the tax;
2. reduce the color accuracy lost in the float64 → float32 switch.

This RFC settles (1). It is a **measurement RFC first and a work plan second**,
because the measurement changes the plan: the Python layer is not the tax, and
three cheaper levers are worth roughly an order of magnitude more than the
rewrite would have been.

Direction (2) — float32 color accuracy — is deliberately **not** in scope here
and gets its own RFC-006.

---

## 2. Measurements

Reproduce with `tmp/bench_rfc005_dispatch.py` and `tmp/bench_rfc005_roofline.py`
(run outside the sandbox; MLX/Metal needed). All figures are best-of-N at
5500×8200 = 45.1 MP, float32 RGB = 0.54 GB per buffer.

### 2.1 The Python launch layer

| | |
|---|---|
| Python → `mx.fast.metal_kernel` launch + sync, trivial work | **157 µs** |

There are ~7 GPU-tagged nodes in the current graph, and even a fully ported
graph is ~24 nodes with a few kernels each — call it 100 launches. At 157 µs
that is **~16 ms of launch overhead across a 22.6 s render: 0.07%.**

A metal-cpp rewrite can attack only that 16 ms, and only part of it. It cannot
touch anything else in this table.

### 2.2 Memory bandwidth roofline

| | time | achieved |
|---|---|---|
| pure pointwise `x*k`, read 0.54 GB + write 0.54 GB | 4.45 ms | **243 GB/s** |

That is the floor. Any full-resolution pointwise stage that costs meaningfully
more than ~4.5 ms is losing to memory traffic or to arithmetic in the inner
loop, not to the host language.

### 2.3 Chain dispatch: how a run of 6 pointwise ops costs

| how the 6 ops are dispatched | time | vs best |
|---|---|---|
| **`mx.compile`d chain (one fused kernel)** | **8.4 ms** | 1.0× |
| lazy MLX graph, one `mx.eval` at the end | 54.4 ms | 6.5× |
| eager, `mx.eval` after each op | 55.4 ms | 6.6× |
| **as `topology.py` does it today** (`to_device`/`to_host` per node) | **151.7 ms** | **18.1×** |

Two things fall out:

- MLX's lazy graph does **not** fuse these on its own — 54.4 ms is six separate
  round trips through memory (6 × ~9 ms ≈ the roofline × 6). `mx.compile` fuses
  them into one pass and lands within 2× of the copy floor.
- The per-node host round trip in the current dispatcher costs another 2.8×
  on top.

### 2.4 Transfers

| | time |
|---|---|
| upload float32 `np → mx` | 9.7 ms |
| upload float64 `np → mx` (`to_device`: cast + copy) | 27.9 ms |
| download `mx → np` | 9.7 ms |
| **round trip per node, from a float64 tap** | **37.5 ms** |

Feeding the GPU from a float64 tap costs 2.9× the upload of a float32 tap. The
`working_precision="float32"` graph policy from RFC-003 §3.5 is therefore also a
*transfer* optimisation, not only a compute one.

### 2.5 Kernel quality: the separable Gaussian

`gpu_gaussian_blur`, σ=2.0 (r=6), two passes:

| variant | time | vs best |
|---|---|---|
| **current `gpu_gaussian_blur`** | **76.0 ms** | 8.3× |
| same MSL, without the internal host round trips | 56.7 ms | 6.2× |
| **precomputed weights + `float3` vector loads** | **9.2 ms** | **1.0×** |

The current kernel is 8.3× off, and the *dominant* term is not the transfers —
it is the inner loop. Per thread it (a) runs a full radius loop just to compute
the normalisation `sum`, (b) evaluates `exp2` **twice per tap** for weights that
are the same for every one of 45 million threads, and (c) loads the three
channels as three scalar reads. Hoisting the weights to a host-computed
`(2r+1)` array and vectorising the load gets to 9.2 ms — roughly the roofline
for two passes.

That 8.3× is available **inside MLX**, in the MSL source we already own.

### 2.6 The residency claim in RFC-004 §3/P0 is not implemented

`runtime/topology.py:143-152` dispatches GPU nodes **one at a time**, with a
`to_device` on entry and a `to_host` on exit for every node. The docstring
concedes it ("Residency grouping … is P0's scheduler"). Separately,
`gpu_separable_gaussian` and `gpu_curve_interp` call `to_device(...)` on values
that are *already* `mx.array`s; `to_device` runs `np.asarray(..., float32)`,
which forces a device→host materialisation and a re-upload. A single
`gpu_gaussian_blur` therefore performs **four** hidden transfers that the
residency design says should be zero.

Note also that the 7 GPU-tagged nodes are, with one exception (`exposure` →
`boost`), *not adjacent* in the graph. Residency grouping alone buys almost
nothing until more nodes move to the GPU — which is why it is sequenced after
kernel quality below, not before it.

---

## 3. Decision

**Reject the bare-Metal rewrite.** Measured, it addresses 0.07% of the render.
The premise behind it — that "calling Metal acceleration through Python" is the
cost — does not survive §2.1. Additionally, `mx.fast.metal_kernel` already
compiles hand-written MSL: the kernels in `mlx_ops.py` *are* bare Metal
shaders. What sits between us and the GPU is not a Python abstraction over
Metal; it is a Python function that hands MSL to the Metal compiler once and
then launches it in 157 µs. Rewriting against metal-cpp would buy the launch
delta, cost the MLX allocator, the unified-memory `mx.array` interop with NumPy,
`mx.compile` fusion, and the autograd-free lazy graph, and would have to
re-implement the buffer pool by hand.

**Accept instead** the three levers §2 exposes, in this order:

| | lever | measured basis | est. at 45 MP |
|---|---|---|---|
| **A** | fix kernel inner loops (weights, vector loads, no hidden transfers) | §2.5: 76.0 → 9.2 ms on one blur | largest, and unblocks the rest |
| **B** | `mx.compile` fused pointwise runs | §2.3: 54.4 → 8.4 ms per 6-op run | grows as more nodes port |
| **C** | true device residency + float32 taps | §2.3/§2.4: 151.7 → 54.4 ms; 27.9 → 9.7 ms upload | grows as runs get longer |

A is unconditional and independent. B and C only pay in proportion to how many
*consecutive* nodes are on the GPU, so they are sequenced after the RFC-004
P3–P5 stages land.

---

## 4. Phases

### P0 — kernel-quality pass on what already exists *(this RFC's first commit)*

1. **`gpu_separable_gaussian`**: host-compute the normalised `(2r+1)` weight
   array, pass it as an input, drop the two per-tap `exp2` calls and the
   normalisation loop; load/store as `float3`. Keep the existing
   `reflect`-mode boundary arithmetic bit-for-bit.
2. **`to_device` must not accept device arrays.** Add an early
   `if isinstance(array, mx.array): return array.astype(mx.float32)` guard, so
   an accidental in-chain call is free instead of a round trip. Then remove the
   `to_device` calls inside `gpu_separable_gaussian` and `gpu_curve_interp`
   that operate on already-device values.
3. **`gpu_boost`**: `float(mx.max(x))` forces a full sync mid-chain. Keep the
   reduction on device and fold the scalar into the kernel, or hoist the
   reduction to the head of the run where the sync is already paid.
4. **`gpu_curve_interp`**: the binary search is per-thread over a `K×3` axis in
   device memory; stage the axis in threadgroup memory once per threadgroup.

*Exit:* each touched kernel benchmarked before/after in
`tmp/bench_rfc005_dispatch.py`, and bit-identical or within the RFC-004 §2.2
visual gate against its CPU float64 reference.

### P1 — `mx.compile` the pointwise runs

Wrap each maximal run of pointwise `run_mlx` callables in `mx.compile` with the
image as the only traced input and all parameters closed over as constants
(they are fixed for a render). Cache the compiled function on the pipeline,
keyed by the run's node names + parameter hash, so the GUI's re-render does not
recompile.

*Risk:* `mx.compile` retraces on shape change; the GUI preview and the full-res
export are two shapes, so expect two compilations per run. Cache both.

### P2 — real residency in the dispatcher

Replace the per-node branch in `topology.py` with the grouping RFC-004 P0
described: scan the topology for maximal consecutive runs where every node has
`run_mlx` and `"mlx" in node.backend`, upload once at the run head, keep
`mx.array`s in `state` for the interior taps, download once at the tail. The
`precision` re-cast and the `free_taps` bookkeeping both need to learn about
device values. Only makes sense once P3–P5 of RFC-004 have made the runs long
enough to matter — currently the longest run is 2 nodes.

### P3 — float32 taps end to end

Default the frontend path to `working_precision="float32"` so run heads upload
9.7 ms instead of 27.9 ms, keeping `upsample` and `gamut_compress` on float64 as
RFC-004 §2 decided. **Gated on RFC-006** — this is a color-accuracy decision,
not a performance one, and it is that RFC's call to make.

---

## 5. Acceptance

Same protocol as RFC-004 §2.2 — per-phase CPU-float64 vs GPU samples written to
`tests/baseline/out/rfc005/<phase>/`, ΔE2000 / PSNR / MS-SSIM reported for
transparency, and the gate is the reviewer's eyes on the side-by-side. Grain and
glare off for every A/B (RFC-001 §6.0).

Performance is reported against the same 45 MP deterministic frontend metric
used all through RFC-003/004, with the ±1–2 s run-to-run variance stated.

---

## 6. Open question deferred to RFC-006

Everything above holds the color policy fixed. The remaining question — how much
accuracy the float64 → float32 move actually costs, and whether `upsample`
(Hanatos spectral reconstruction) and `gamut_compress` (CAM16-UCS) can join the
GPU without a visible change — is the subject of RFC-006. §2.4 is the one place
the two RFCs touch: float32 taps are worth 18 ms per run head, which is a reason
to want the answer, not a reason to pre-empt it.


---

## 7. P0 results (implemented)

### 7.1 Methodology correction

The §2 figures, and the 22.6 s / 37.4 s numbers this RFC was written against,
came from **sequential** runs. Re-measuring the unchanged baseline commit hours
later gave 18.9 s / 15.5 GB where it had earlier given 23.3 s / 11.5 GB — the
machine drifts by more than the effects being measured. Every number below is
from **interleaved A/B** (stash, run baseline, pop, run patched, repeat), 8
pairs. Sequential before/after comparisons on this box are not trustworthy at
the ±2 s / ±1.5 GB level and should not be quoted.

### 7.2 Changes landed

1. `prune_identity_nodes` — dead-node elimination now aliases the dropped
   node's write tap to its read tap. RFC-003 3.3 declared this but filtering
   alone broke the graph, so it had never actually run. Four nodes are dropped
   at default parameters (both blurs, diffusion filter, unsharp).
2. `to_device` passes `mx.array` through instead of round-tripping it to host.
3. Separable Gaussian: host-computed weights, `float3` loads. **76.0 -> 12.7 ms**
   at 45 MP, sigma=2. Truncation radius corrected from `ceil(3*sigma)` to the
   CPU's `int(3*sigma + 0.5)`, which brings sigma < 3 to float32 epsilon
   (1.5e-07). sigma >= 3 still diverges (~0.15) because the CPU switches to a
   Young-van Vliet IIR approximation there; that gap predates this RFC.
4. `exposure`, `boost`, `curves`, `xyz_to_rgb` lose their `backend=('mlx',)`
   tag (§2 showed they lost on device); `log` and `cctf` keep theirs.
5. **`Node.precision` is now honoured.** This is the substantive finding: a
   node tagged `backend=('mlx',)` returned float32, which propagated into every
   downstream CPU stage. Removing a GPU tag therefore changed *numerics*, and
   the first attempt at (4) cost 2.0 s because halation and dir_couplers fell
   back to float64. The tap dtypes the GPU port was producing by accident are
   now declared, independent of which backend runs the node.
6. `boost_highlights` preserves float32 instead of forcing float64, removing a
   1.08 GB promotion copy at 45 MP.
7. `run_topology` frees spent input taps *before* the precision cast, not
   after — the cast allocates a second buffer for the same tap, so doing it
   with inputs still pinned put three full-res buffers in flight where two
   suffice.
8. MLX's buffer pool is capped to zero for full-resolution runs
   (`unpooled_device_memory`). Preview runs keep the pool.

### 7.3 Measured outcome (45 MP, 8 interleaved pairs)

| | baseline | patched | delta |
|---|---|---|---|
| time, mean | 19.70 s | 19.61 s | **-0.09 s (noise)** |
| time, range | 2.34 s | 1.93 s | |
| peak RSS, mean | 15.02 GB | 14.25 GB | **-0.77 GB** |
| **peak RSS, range** | **1.80 GB** | **0.20 GB** | **9x more predictable** |

Output is unchanged: dE2000 mean 0.00000 / p99 0.00003 / **max 0.00011**,
PSNR 152 dB, max abs diff 3.6e-07 against the baseline commit at 16 MP.

**Honest reading: this is a memory and predictability win, not a speed win.**
The kernel and dispatch fixes are real (the Gaussian is 6x faster, 174 ms of
no-op round trips are gone) but they act on nodes worth ~1.8 s of a ~20 s
render, and what they gave back was spent re-establishing the float32 tap
dtypes the GPU tags had been providing for free. The baseline's 1.80 GB spread
in peak RSS was largely MLX's pool carrying allocations across runs; capping it
is what collapsed the variance.

### 7.4 Garbage collection: measured, and not the lever

Python's cyclic GC is irrelevant here. Rendering with `gc.disable()`:

| | time | peak RSS |
|---|---|---|
| gc enabled | 6.82 s | 5.08 GB |
| gc disabled | 6.85 s | 5.07 GB |

Across a full render the collector sees 33 gen-0 collections and reclaims 415
objects, none of them arrays; **zero** arrays over 50 MB are reachable through
cycles and `gc.collect()` finds zero unreachable-cycle objects. NumPy buffers
are freed by refcount the moment the last reference drops, so tuning
thresholds, `gc.freeze()`, or manual `collect()` calls cannot help.

What governs the footprint instead, in order of measured effect:

1. **Tap dtype** — 1.08 GB per float64 full-res buffer, 0.54 GB per float32.
2. **Reference lifetime** — `free_taps` and the ordering in 7.2 (7).
3. **Promotion copies** — an `asarray(x, dtype=float64)` on a float32 input is
   a silent full-resolution allocation (7.2 (6)).
4. **The MLX pool** — 1.76 GB held with active memory at 0.00 GB (7.2 (8)).

The remaining footprint is dominated by stages that allocate float64
temporaries internally (`upsample`, `gamut_compress`, `dir_couplers`). Cutting
those is the float32 question, i.e. RFC-006.
