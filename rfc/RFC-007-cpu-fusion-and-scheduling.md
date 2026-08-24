# RFC-007: The CPU Path — Fusion, Language Choice, and Heterogeneous Scheduling

| | |
|---|---|
| **Status** | A implemented; B-D proposed |
| **Date** | 2026-08-24 |
| **Depends on** | RFC-003 (decoupling), RFC-005 (dispatch/kernel quality) |
| **Scope** | `utils/spectral_upsampling.py`, `utils/gamut_compression.py`, numba threading policy, process QoS |
| **Hardware of record** | Apple M3 Max — **10 performance + 4 efficiency cores**, 14 total; macOS 25.5; clang 21.0.0; numba 0.67.0, `workqueue` threading layer |

---

## 1. Questions this RFC answers

After RFC-005 the GPU-tagged nodes are ~1.8 s of a ~20 s render. The rest is
CPU. Three proposals were on the table:

1. **Rewrite the CPU path in C++** — will that make it faster?
2. **Drop the JIT** — is numba's JIT buying anything?
3. **Pin the computation to performance cores**, with `num_workers` equal to
   the P-core count, and chunk the work accordingly.

All three are measurable, and were measured before this RFC proposed anything.
Two of the three answers are *no*, and the part that is *yes* is not the part
that was expected.

---

## 2. Method

One kernel, four implementations, identical math: a pointwise film-math chain
(`exp`, `log10`, `pow`, one branch) over 135.3 M float32 elements — the 45 MP
RGB working size. This is the shape of `boost`, `cctf`, and the curve stages.
C++ built with `clang -O3 -march=native -ffast-math -std=c++17`; numba with
`njit(parallel=True, fastmath=True, cache=True)`. Best-of-5.

Reproduce: `tmp/rfc007/` (`kern.cpp`, `kern2.cpp`, `shootout.py`, `sweep.py`,
`sched.py`, `nbtile.py`).

Caveat carried through the whole RFC: this is **one synthetic pointwise chain**.
The real stages have different arithmetic intensity, and two of them call into
scipy (`map_coordinates`) and matplotlib (`Path`) code that will not fuse at
all. Treat the ratios as an upper bound on what fusion buys, not a forecast.

---

## 3. Language and fusion

| implementation | time | |
|---|---|---|
| NumPy expression (8 full-res temporaries) | 1111.5 ms | |
| **numba `njit(parallel, fastmath)`, 14 threads** | **190.5 ms** | **5.8x over NumPy** |
| C++ static chunking, 14 threads | 142.6 ms | 1.34x over numba |
| **C++ dynamic chunking, 14 threads** | **124.4 ms** | **1.53x over numba** |
| C++, single thread | 1421.1 ms | |

### 3.1 C++ is not the lever

The full ladder from NumPy to the best C++ is **8.9x**. numba captures 5.8x of
it without leaving Python. What remains for a C++ rewrite is **1.53x** — bought
at the cost of a build system, a cross-platform toolchain, and (per the
Photoshop discussion) a code-signing and distribution story.

The reason is structural: **there is no interpreter in the hot loop today.**
numba emits LLVM IR; clang emits LLVM IR. Same optimiser, same auto-vectoriser,
same NEON registers. Rewriting a numba kernel in C++ swaps compiled machine
code for different compiled machine code. The residual gap is libm and
thread-scheduling differences (see 4), not language.

### 3.2 What NumPy actually costs is memory traffic, not instructions

Every operator in a NumPy expression materialises a full-resolution temporary.
Measured on the real stage with `tracemalloc`:

```
gamut_compress (CAM16-UCS, NumPy)  2202 ms  peak temporaries 1792 MB = 18.67x input
```

**18.67x the input in temporaries.** At 45 MP float64 that is ~20 GB of
allocation churn for one stage. This is simultaneously the speed problem and
the memory problem RFC-005 7.4 left open.

And the two largest CPU stages are exactly the un-fused ones:

| module | njit kernels | 45 MP cost |
|---|---|---|
| `utils/spectral_upsampling.py` | **0** | ~4.0 s |
| `utils/gamut_compression.py` | **0** | ~4.5 s |

8.5 s of a ~20 s render, sitting in the regime where fusion is worth ~5.8x.

### 3.3 The JIT is not costing anything

| | |
|---|---|
| first 512x512 render (JIT) | 0.76 s |
| warm render | 0.37 s |

~0.4 s once, and `cache=True` persists compiled artifacts to disk across
process restarts. The JIT also earns its keep: RFC-005 needed float32 *and*
float64 variants of `boost_highlights`, and numba compiled both from one
generic function.

**Verdict: no JIT work is needed, and numba should not be dropped** — it is the
mechanism that captures the 5.8x. The one legitimate argument for AOT is
*distribution*: llvmlite is ~100 MB and first-run compilation on an end-user
machine is a support burden. That is a packaging concern for the plugin
question, not a performance one, and must not be conflated with it.

---

## 4. Heterogeneous scheduling: P-cores, workers, and chunking

The proposal was: run on P-cores only, set worker count to the P-core count
(10), then chunk. Measured, on the same kernel:

### 4.1 Thread-count sweep

| threads | C++ | numba |
|---|---|---|
| 1 | 1419.1 ms | 1900.7 ms |
| 8 | 184.0 ms | 246.7 ms |
| **10 (= P-core count)** | **152.2 ms** | **205.7 ms** |
| 12 | 141.9 ms | 196.5 ms |
| **14 (= all cores, default)** | **142.6 ms** | **190.5 ms** |

**Restricting to the P-core count is 6.7% *slower* (C++) and 7.4% slower
(numba).** The efficiency cores contribute real throughput; excluding them
throws it away.

### 4.2 QoS is the only lever macOS gives, and the danger is the downside

Apple Silicon exposes no CPU-affinity API. `THREAD_AFFINITY_POLICY` is a hint
that the scheduler ignores. The only real control is the QoS class:

| 14 threads, static chunking | time |
|---|---|
| `QOS_CLASS_USER_INTERACTIVE` | **136.7 ms** |
| default (unspecified) | 142.6 ms |
| `QOS_CLASS_BACKGROUND` | **881.7 ms** |

Two findings, and the second matters more than the first:

- Asking for high QoS is worth ~4%. Cheap, worth taking.
- **Being demoted to background QoS costs 6.2x.** This is a production hazard,
  not a curiosity: a helper process spawned by a host application, or one that
  is not frontmost, can inherit or be demoted to background QoS by macOS. The
  Photoshop-plugin architecture sketched previously — a local render helper
  behind a UXP front-end — is exactly the shape that gets demoted. A 20 s
  render silently becoming a 2-minute render is a support nightmare with no
  visible cause.

### 4.3 Chunking is the part that was right

| 14 threads, dynamic tiles from an atomic cursor | time |
|---|---|
| tile 0.02 M elems (0.1 MB) | **124.4 ms** |
| tile 0.13 M elems (0.5 MB) | 124.6 ms |
| tile 1.05 M elems (4.2 MB) | 127.2 ms |
| tile 8.39 M elems (33.6 MB) | 185.7 ms |
| *(static, one chunk per thread, for reference)* | *142.6 ms* |

Dynamic chunking is **13% faster than static** at 14 threads, and 18% faster
than the 10-thread P-core-only variant. Coarse tiles lose the benefit and end
up *worse* than static, because with ~16 tiles across 14 threads the imbalance
returns.

**This inverts the original proposal.** Chunking is not a follow-on to P-core
pinning; it is the *replacement* for it. Dynamic tiles are precisely what makes
heterogeneous cores pay: a slower E-core simply claims fewer tiles instead of
holding a barrier open. Fix the scheduling and the "problem" the pinning was
meant to solve disappears, with more throughput than pinning could have given.

### 4.4 numba cannot currently capture it

numba's default `workqueue` threading layer statically partitions the `prange`
iteration space. Restructuring as `prange` over tiles does not help — it makes
things worse by adding loop overhead without adding balance:

| numba, 14 threads | time |
|---|---|
| flat `prange` (static partition) | **195.6 ms** |
| `prange` over 0.02 M-elem tiles | 265.3 ms |
| `prange` over 1.05 M-elem tiles | 265.3 ms |

The 13% dynamic-scheduling win needs a work-stealing scheduler. numba's TBB
threading layer provides one; TBB is **not currently installed**, so this is
untested and is an explicit open question (6.1), not a recommendation.

---

## 5. Decision

Ranked by measured value per unit of risk:

| | action | measured basis | cost |
|---|---|---|---|
| **A** | Fuse `gamut_compress` and `upsample` into numba kernels | 5.8x on the chain; 18.67x -> ~1x temporaries | contained, no new toolchain |
| **B** | Set `QOS_CLASS_USER_INTERACTIVE` on the render threads, and assert QoS at startup | +4%; guards against a 6.2x demotion | trivial |
| **C** | Evaluate numba's TBB threading layer for work-stealing | 13% in C++; unverified for numba | a dependency |
| **D** | Rewrite in C++ | 1.53x over numba | build + distribution |

**A is the whole recommendation.** It is the only item worth more than the
others combined, it addresses the memory problem RFC-005 could not, and it
needs no new dependency, language, or build step.

**B should land regardless** — not for the 4%, but because the failure mode in
4.2 is silent and severe.

**D is rejected for now.** 1.53x does not justify a C++ toolchain while a 5.8x
NumPy-fusion win is sitting unclaimed in the same files. Revisit only after A
lands and the profile is re-measured — at which point the remaining hotspots
will be different ones, and this analysis will need redoing.

---

## 6. Open questions

1. **Does numba's TBB layer actually deliver the 13%?** Untested; TBB is not
   installed. If it does not, the dynamic-scheduling win is C++-only and moves
   into D's column, changing D's cost/benefit.
2. **How much of `gamut_compress` and `upsample` is genuinely fusable?**
   `gamut_compress` calls `scipy.ndimage.map_coordinates` and
   `matplotlib.path.Path`; `upsample` does LUT interpolation. Those parts will
   not fuse. Profile *inside* both functions before committing to a number —
   3-4x is a more defensible expectation than 5.8x.
3. **Does fusing change the picture?** CAM16 in a fused float32 kernel is the
   same accuracy question RFC-006 owns. A fused *float64* kernel captures the
   allocation win with no color risk and should be measured first.

---

## 7. Acceptance

Per RFC-005 5: CPU-float64 reference vs the fused kernel, dE2000 / PSNR /
MS-SSIM reported, gate is the reviewer's eyes on the side-by-side samples.
Grain and glare off.

Performance reported as **interleaved A/B** (RFC-005 7.1) — sequential
before/after comparisons on this machine are not trustworthy at the +/-2 s
level, and the baseline itself has been observed to drift by 4 s between
sessions.


---

## 8. Phase A results (implemented)

### 8.1 Measured outcome (45 MP, 4 interleaved pairs)

A/B via the `_FORCE_REFERENCE_CAM16` / `_FORCE_REFERENCE_TC_B` switches, which
restore the pre-fusion NumPy path in-process, so both arms run the identical
binary and only the kernel differs.

| | reference (NumPy) | fused | delta |
|---|---|---|---|
| time, mean | 18.93 s | **12.93 s** | **-31.7%** |
| time, spread | 0.24 s | 0.11 s | |
| peak RSS, mean | 14.30 GB | 13.85 GB | -0.45 GB |

Per-node, at 45 MP:

| node | before | after | |
|---|---|---|---|
| `filming.expose.upsample` | 3.97 s | **0.59 s** | **6.8x** |
| `scanning.gamut_compress` | 4.32 s | **1.38 s** | **3.1x** |

Output is unchanged end to end: dE2000 mean 0.000000 / p99 0.000002 /
**max 0.000041**, PSNR 172 dB, **0 of 16.0 M pixels above dE 0.1**.

### 8.2 Where the estimate landed

RFC-007 6.2 predicted 3-4x on these two stages and warned 5.8x was optimistic.
On the isolated stage the fused CAM16 kernel measured **23.7x** (7.70 s ->
0.32 s on a real 16 MP tap, temporaries 19.67x -> 2.00x). In the full pipeline
it is 3.1x, because the reference was already being chunk-parallelised across
12 threads by `parallel_pointwise` while the isolated benchmark was
single-threaded NumPy. **The 3-4x pipeline estimate was right; the 23.7x
microbenchmark number is not a pipeline number and should not be quoted as
one.**

### 8.3 What is now the profile

| node | time | share |
|---|---|---|
| `filming.expose.halation` | 3.30 s | 26.0% |
| `filming.develop.dir_couplers` | 2.40 s | 18.9% |
| `scanning.scan_spectral` | 1.58 s | 12.4% |
| `scanning.gamut_compress` | 1.38 s | 10.8% |
| `printing.expose.print_exposure` | 1.24 s | 9.8% |

The two largest stages are now **spatial**, not pointwise. Neither fuses the
way A did: `halation` is `support=inf` (global), and `dir_couplers` is a
diffusion. Every estimate in this RFC predating 8.1 was made against the old
profile and needs re-deriving before it is acted on.

### 8.4 Four traps, all found by tests rather than by reading

1. **The CIECAM02 inverse (a, b) solve carries 460/1403, 220/1403, 27/1403 and
   6300/1403 normalisation factors.** Omitting them produced images that looked
   entirely plausible and were dE2000 33 wrong.
2. **colour-science uses a sign-preserving power (`spow`) for J.** A negative
   achromatic response must yield negative J, not zero. Pipeline output reaches
   -0.20, so the path is live.
3. **The GUI default sets `lightness_compression=(0.7, 1.0, 2.2)`.** The first
   version of the kernel did not implement it and correctly fell back to the
   reference -- which meant the kernel was dead code on every real render while
   the unit tests passed. The A/B is what exposed it: `gamut_compress` had not
   moved at all.
4. **The reference accepts any `(..., 3)` shape**; LUT bakes and reference
   probes pass `(3,)` and `(N, 3)`, not images. The kernel is written for
   `(H, W, 3)` and crashed until the wrapper normalised the shape.

### 8.5 Nested parallelism

`_scan_gamut_compress` wrapped `compress_rgb` in `parallel_pointwise` (a thread
pool). Calling a `parallel=True` numba kernel from those threads aborts the
process: *"Numba workqueue threading layer is terminating: Concurrent access
has been detected."* The fused path now bypasses `parallel_pointwise` -- it is
internally parallel over rows, and the 19.67x allocation that the chunking
existed to tame is now 2.00x.

This is a second, independent argument for 5 C (the TBB threading layer): TBB
is threadsafe under nesting, `workqueue` is not, and the constraint will
resurface anywhere else a fused kernel meets a thread pool.
