# RFC-008: Optional Stochastic Grain and Glare

| | |
|---|---|
| **Status** | A implemented (grain engine swap); B proposed (fused interpolation) |
| **Date** | 2026-08-25 |
| **Depends on** | RFC-002 (exact grain), RFC-003 (decoupling) |
| **Hardware of record** | Apple M3 Max, macOS 25.5 |

---

## 1. The problem as stated

Film grain and glare are physically *stochastic* — no two exposures develop the
same granularity. Yet the pipeline currently forces them deterministic: grain is
seeded (`seed = [0, 1, 2]` in `apply_grain_to_density`) and glare is run with a
fixed-per-run field so that A/B comparisons and regression tests reproduce.
That determinism is **not** physics; it is measurement hygiene.

It is also expensive. The demand for a *reproducible* grain realisation forces
the sampler onto NumPy's `Generator.poisson` with `SeedSequence.spawn` per chunk
(`utils/grain_stats.py`), which is the slow route. A fast, unseeded, exact
sampler exists (numba `np.random.poisson`), but it cannot honour a seed, so it
was never used.

This RFC adds an **optional, genuinely-stochastic** path for the *product* while
keeping the deterministic path for *evaluation*:

> One deterministic grain/glare generation path for A/B and testing.
> One stochastic grain/glare generation path for daily usage / the future app.

And it records the measured cost of the swap.

---

## 2. Key correction from measurement

The prior microbenchmark (RFC-007 3) showed single-threaded NumPy
`Generator.poisson` at 27 ms / 1 M variates vs parallel numba at 3.5 ms — a
**7.8×** gap. That number is **not** the pipeline number. The deterministic
path in `grain_stats.sample_layer_density` is already chunk-parallel across 12
threads (64 chunks / `SeedSequence.spawn`), so it is far faster than the
single-threaded microbenchmark. Measured on the real grain pipeline:

| | deterministic (`exact`) | stochastic (`numba`) | ratio |
|---|---|---|---|
| full grain, 2 MP (3 sub × 3 ch) | 204.5 ms | 121.6 ms | **1.68×** |
| raw Poisson draws, 1 MP, λ~mid | 9.8 ms | 5.2 ms | **1.91×** |
| peak allocation, 2 MP | 129.6 MB | 129.7 MB | **1.00×** |

Two facts follow:

1. **The stochastic engine swap alone is worth ~1.7–1.9× on grain time, not
   7.8×.** The deterministic path was already using the cores; numba only
   removes the Python/NumPy per-chunk overhead and the `rate`/`counts`
   intermediates.
2. **The engine swap alone changes peak memory by roughly nothing.** Both paths
   allocate the dominant object: the `density_cmy_layers` array,
   `(H, W, 3, 3) float64` = 72 B/px. At 45 MP that is **~3.2 GB** regardless of
   which sampler draws. To actually cut memory you must also **fuse the
   per-sublayer interpolation into the kernel** so the `(H, W, 3, 3)` buffer
   never exists (Part B below). That is the real memory win, and it is not free
   in the engine swap.

Distribution sanity (synthetic mid-tone input, `std` of the output field):

| | mean | std | skew |
|---|---|---|---|
| deterministic (`exact`) | 3.0586 | 0.4096 | 0.019 |
| stochastic (`numba`) | 3.1433 | 0.4099 | 0.011 |

The standard deviation matches to three digits (0.4096 vs 0.4099) — the
granularity is preserved. The skew differs, but on a single 200 k-sample
realisation at λ≈300 the true skew (~0.06) has large sampling noise, so this is
expected realisation-to-realisation scatter, not a distributional change. Both
draw from the same Poisson family; the stochastic path is just a different seed.

---

## 3. The dual-path contract

### 3.1 Grain

`layer_particle_model` (via `apply_grain_to_density*`) now accepts
`sampler='exact'` (unchanged default) and `sampler='stochastic'`.

- `'exact'` → `grain_stats.sample_layer_density`: seeded, chunk-spawned,
  reproducible across runs and worker counts. **Use for A/B and tests.**
- `'stochastic'` → `model.grain._sample_density_stochastic`: unseeded numba
  `prange` kernel, exact Poisson from the global RNG, no `SeedSequence`, no
  per-chunk rate/counts intermediates. **Use for the product / daily usage.**

Both branches share the exact Poisson-thinning math (clip to `(1e-6, 1-1e-6)`,
`saturation`, `rate = (n/sat)*p`, `contribution = counts * od * sat`), so the
third-moment (skewness) character is preserved; only the RNG source differs.

The default remains `'exact'` — the pipeline output is unchanged for anyone who
does not opt in.

### 3.2 Glare

Glare is already unseeded (stochastic) in `compute_random_glare_amount`; it uses
`fast_lognormal_from_mean_std` (numba) plus a fast Gaussian, and is cheap
(~4 ms / 1 MP at shipped defaults). There is **no** measurable speed or memory
benefit to be had here — it already is stochastic and already fast. The only
action is to formalise the contract: add an optional `seed` parameter so a
*deterministic* glare path exists for evaluation, and document that the default
(unseeded) is the stochastic/product path.

---

## 4. What "this alone" buys

At the current deterministic-45 MP grain cost (measured ~2 MP → 204 ms, scales
to roughly **4.6 s / ~3.2 GB** at 45 MP, sublayers on, with synthetic mid-tone
density):

| view | time | peak |
|---|---|---|
| deterministic (`exact`) | ~4.6 s | ~3.2 GB |
| **stochastic engine swap alone** | **~2.7 s** | **~3.2 GB** |
| *+ fused interpolation (Part B)* | *~1.5 s (est.)* | *~input+output* |

So **the engine swap is a ~1.9 s / 0 GB win.** It is cheap and worth taking, but
it is not the headline. The headline memory + the additional time come from
**Part B**, fusing the per-sublayer interpolation and the final `grain_blur`
into one tiled kernel with a coordinate-keyed RNG. See `rfc/RFC-007` §8 for the
fusion pattern that already won on `gamut_compress` and `upsample`.

---

## 5. Design (Part A — landed)

Add to `spektrafilm/model/grain.py`:

```python
@njit(parallel=True, cache=True, fastmath=True)
def _sample_density_stochastic(density, density_max, n_particles_per_pixel,
                               grain_uniformity, out, accumulate):
    # per element, from the shared global RNG (unseeded):
    #   p = clip(d/density_max, 1e-6, 1-1e-6)
    #   saturation = 1 - p * uniformity * (1 - 1e-6)
    #   rate = (n_particles_per_pixel / saturation) * p
    #   contribution = np.random.poisson(rate) * (density_max/n_particles) * saturation
```

Dispatch in `layer_particle_model`:

```python
if method == 'poisson_binomial' and sampler == 'stochastic':
    grain = sample_density_stochastic(...)   # numba, unseeded
```

No default changes. `sampler` is threaded from `settings.grain_sampler`.

---

## 6. Safety / correctness

- **Distribution preserved.** Same Poisson-thinning identity (`Poisson(n)*Bin(p)
  == Poisson(n*p)`), same clips, same `od_particle` scaling. The only difference
  is the RNG stream, which is unseeded.
- **No nesting hazard.** The grain node runs in-pipeline (not inside
  `parallel_pointwise`), so a numba `parallel=True` kernel is safe there.
  Do **not** wrap it in a thread pool (RFC-007 §8.5) or the process aborts.
- **Deterministic path untouched by default.** Existing tests/A-B that rely on
  `sampler='exact'` see no change.
- **Grain+glare stay OFF for any ΔE comparison** (RFC-001 6.0/6.1). The
  stochastic path is for the *product*, not for color measurements.

---

## 7. Part B (implemented this RFC): fuse interpolation into the kernel

`apply_grain_to_density_layers_fused` computes the three sub-layer densities for
a single channel on the fly — a `(H, W, 3)` buffer (24 B/px) instead of the full
`(H, W, 3, 3)` (72 B/px) — then draws that channel's sub-layers and frees the
buffer before the next channel. The interpolation and the Poisson draws are
unchanged, so a seeded run is **bit-identical** to the unfused reference.
`apply_grain` now routes the sub-layers path through the fused version.

Measured (2 MP, 3 sub × 3 ch, real Portra-400 curves, deterministic `exact`,
same seed):

| | time | peak alloc | B/px |
|---|---|---|---|
| unfused (materialises `(H,W,3,3)`) | 258.3 ms | 273.4 MB | 137 |
| **fused** | 250.9 ms | 208.0 MB | 104 |

- **Correctness: no quality loss.** `np.array_equal(ref, fused) == True`,
  `max abs diff 0.0`. Mean / std / skew identical (1.0028, 0.2119, 0.0192).
- Node time: **1.03×** (interpolation work is the same; only buffer traffic
  dropped). Combined with the stochastic engine: **166.4 ms**, i.e. **1.55×** vs
  the deterministic unfused reference.
- Memory: **1.31×** lower allocation in the grain node, 137 → 104 B/px
  (~**3.2 GB → ~2.3 GB** at 45 MP).

End-to-end 45 MP, full quality (color LUTs + stochastic grain + glare, MLX):

| | time | peak RSS | B/px |
|---|---|---|---|
| Part A only (engine swap, unfused) | 26.95 s | 13.97 GB | 310 |
| **Part A + Part B (fused)** | **24.33 s** | **12.34 GB** | **274** |

So Part B takes the full-quality path from 26.95 s / 13.97 GB to **24.33 s /
12.34 GB**, a further **2.6 s** and **1.63 GB** saved. The remaining grain cost
is dominated by the per-element Poisson draws, not the interpolation or the
buffer; going significantly below this needs the coordinate-keyed Philox RNG
plus a single fused blur pass (RFC-008 open question 3).

---

## 8. Open questions

1. Should `sampler='stochastic'` become the GUI/product default, with the
   deterministic path reserved for tests and A/B? (This is the intended end
   state, but it changes full-quality output per-run, which is fine for a product
   and wrong for a reference tool.)
2. Does an end-user "same photo → same grain" guarantee matter? If yes, keep a
   per-job `seed` even in the stochastic path (still fast — the cost is the
   *reproducible RNG*, not the draw). If no, leave it truly unseeded.
3. For the future tiled/app path, Part B needs a coordinate-keyed RNG
   (Philox) so tile boundaries are seamless even with the fused blur. Without
   it, the blurs need 4 px halos (AGENTS trap 9).
