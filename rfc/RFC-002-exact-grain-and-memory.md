# RFC-002: Exact Grain Sampling and the 45 MP Memory Budget

| | |
|---|---|
| Status | Implemented (M1.6) |
| Date | 2026-08-24 |
| Depends on | RFC-001 (M1 fused spectral, M1.5 chunked pointwise) |
| Scope | `model/grain.py`, `utils/grain_stats.py`, `runtime/topology.py` |

---

## 1. Motivation

After M1.5 the exact-path pipeline ran 16 MP in 8.14 s / 6.15 GB. The
full-quality path — the one a user actually experiences, with LUTs, grain and
glare — still took **24.10 s**, and profiling put roughly **16 s of that in
grain alone**. Grain was the single largest item in the pipeline and entirely
untouched.

Separately, a 45 MP frame peaked near **27 GB**. That number is survivable in
isolation on a 36 GB machine and unusable in practice: the intended deployment
is a plug-in running *alongside* Photoshop and Capture One, which is precisely
when 27 GB is not available.

Two goals, then: make grain fast without changing what it looks like, and get
45 MP into a budget that coexists with a real editing session.

### The constraint that shapes the whole design

Film grain is not uniform noise. Two of its properties vary with density, and
they behave differently:

| density | RMS granularity | skewness |
|---|---|---|
| 0.15 (shadow) | 24.8 | **+0.165** |
| 0.90 (mid) | 48.7 | +0.054 |
| 1.80 (highlight) | 39.6 | +0.022 |

RMS peaks at mid-density — the classic granularity curve. Skewness *falls*
monotonically with density, because a Poisson variate has skewness
`1/sqrt(mu)` and `mu` rises with density. Physically: shadows develop fewer
particles, so their grain is clumpier and more asymmetric than highlight
grain.

**That asymmetry is the tonal signature of the stock**, and any optimisation
that flattens it has changed the picture, not merely accelerated it. This
rules out the obvious speedup — see §3.4.

---

## 2. Background: where grain's 16 s went

`apply_grain_to_density_layers` runs a 3×3 loop (3 channels × 3 sub-layers).
Each of the nine iterations calls `layer_particle_model`, which draws

```
N ~ Poisson(lambda),   X | N ~ Binomial(N, p)
```

via `scipy.stats.poisson.rvs` and `scipy.stats.binom.rvs`. Measured at 16 MP:

| | per call | ×9 |
|---|---|---|
| `scipy.stats.poisson.rvs` | 454 ms | 4.09 s |
| `scipy.stats.binom.rvs` | 867 ms | 7.81 s |
| `blur_particle` gaussian | 2.5 ms | 23 ms |
| **total draws + blur** | | **11.9 s** |

plus micro-structure and the final blur. scipy is slow here not because the
sampling is slow but because `scipy.stats` wraps every call in distribution-
object construction and argument validation. The underlying sampler is
NumPy's, and it is fast.

---

## 3. Design

### 3.1 Poisson thinning — exact, and it deletes half the work

If `N ~ Poisson(lambda)` and `X | N ~ Binomial(N, p)`, then

$$X \sim \text{Poisson}(\lambda p)$$

**exactly**, as an identity of distributions. One draw replaces two, and the
intermediate `(H, W) int64` particle-count array never exists.

This is not an approximation and it does not touch the skewness: the thinned
variate is Poisson, so its skewness is `1/sqrt(lambda p)` — the same
density-dependent asymmetry the two-stage draw produces. Verified against
scipy across the density range in §6.1.

### 3.2 Thread the exact sampler, do not approximate it

`numpy.random.Generator.poisson` uses transformed rejection (Hörmann 1993) for
large rates — exact, O(1), and implemented in C. It also **releases the GIL**
while filling, so plain `ThreadPoolExecutor` over row bands scales:

| 16 MP, one sub-layer draw | time | skewness |
|---|---|---|
| `scipy` poisson + binom (previous default) | 1299 ms | exact |
| `numpy` poisson + binom | 1178 ms | exact |
| `numpy` `poisson(lambda*p)` — thinning | 416 ms | exact |
| **`numpy` `poisson(lambda*p)`, 12 threads** | **48 ms** | **exact** |
| `fast_stats` (normal approximation) | 35 ms | **destroyed** |

**27× over scipy at zero statistical cost**, and within 1.4× of the
approximation that throws the tonal character away.

`utils/grain_stats.py::sample_layer_density` implements this. Two properties
are deliberate:

- **Chunk count is fixed at 64, independent of worker count.** Chunk *k*
  always draws from `SeedSequence(seed).spawn(64)[k]`, so a render is
  reproducible on any machine regardless of core count. Verified in §6.1.
- **Chunks outnumber workers.** One chunk per worker puts every chunk in
  flight at once and concurrency re-multiplies exactly what chunking divided
  (AGENTS.md trap 4). 64/12 keeps the transient set bounded.

### 3.3 Two allocation fixes

**Accumulate in place.** The nine sub-layer results were summed with
`density_cmy_out[:,:,ch] += layer_particle_model(...)`, which materialises a
full-resolution temporary per iteration. `layer_particle_model` now takes
`out=` and `accumulate=`, writing directly into the destination plane.

**Skip the no-op blur.** `blur_particle`'s effective sigma is
`blur_particle * sqrt(od_particle)` = `1.0 * sqrt(2.2/500)` = **0.066 px**.
Measured `max|blurred - original| = 0.000e+00` — the filter returns its input
bit for bit. The guard tested the *parameter* (`if blur_particle > 0`) rather
than the effective sigma, so nine no-op blur passes ran every frame. Now
gated on `MIN_EFFECTIVE_BLUR_SIGMA = 0.4`, matching the threshold this module
already uses for `grain_blur` and the micro-structure blur.

### 3.4 Rejected: the normal approximation (`use_fast_stats`)

`utils/fast_stats.py` already existed, disabled by default, and is 35 ms per
draw — the fastest option measured. It is **not** adopted as the default.

Above `lambda > 30` (Poisson) and `var > 10` (binomial) it substitutes a
normal deviate. The pinned Portra 400 setup runs `lambda` between 511 and
2523, so *every* draw takes that branch. Measured consequence:

| density | exact skew | `fast_stats` skew |
|---|---|---|
| 0.15 | +0.1649 | −0.0010 |
| 0.90 | +0.0551 | −0.0007 |
| 1.80 | +0.0238 | +0.0014 |

RMS granularity survives to within 0.14%; skewness is flattened to zero at
every density. That is exactly the shadow/highlight grain character described
in §1. For 1.4× over the exact path, it is not a trade worth making.

`use_fast_stats` remains available for preview rendering — reachable only via
`grain_sampler='scipy'`, since the exact branch is taken first — and is
documented as *destroys grain skewness* rather than as a general speed switch.
Code that previously set `use_fast_stats=True` for speed now gets the exact
sampler instead, which is faster anyway.

### 3.5 A branchless form, for the GPU

Transformed rejection is a bounded rejection loop — portable to Metal but
branchy. For a future MSL kernel the cheaper option matches the first three
moments in closed form (Cornish–Fisher):

$$X = \mu + \sqrt{\mu}\left(z + \frac{z^2-1}{6\sqrt{\mu}}\right), \quad z \sim \mathcal{N}(0,1)$$

| density | mu | exact skew | Cornish–Fisher | plain normal | RMS err |
|---|---|---|---|---|---|
| 0.15 | 36.5 | 0.1649 | **0.1646** | −0.0002 | 0.18% |
| 0.90 | 341.4 | 0.0551 | **0.0543** | 0.0002 | 0.01% |
| 1.80 | 2064.2 | 0.0238 | **0.0238** | 0.0018 | 0.02% |

Branchless, three FLOPs plus one normal deviate, and it keeps the tonal
signature. Approximate in the far tail, so exact PTRS stays the CPU
reference. Deferred until the Metal grain kernel (M3), which also needs
Philox-on-global-`(x,y)` for tile invariance.

### 3.6 Note on chunking and seams

The intuition that grain cannot be chunked because chunk edges would show is
half right, and the half that is wrong matters.

The **draws are i.i.d. per pixel**. Chunking them yields a different
realisation but no boundary artefact whatsoever — there is no spatial
correlation to break. Seams come only from the **spatially coupled**
operations: `grain_blur` (sigma 0.65 px on the output) and the
micro-structure blur. Those need halos, and at these sigmas a 4-pixel halo is
sufficient. This RFC chunks the draws only, and applies both blurs to the
assembled full-resolution array, so no halo logic is required yet.

There is a real RNG hazard, just a different one: the previous code called
`np.random.seed(seed)` — *global* legacy state — inside the per-layer
function, which is not thread-safe. `sample_layer_density` uses per-chunk
`Generator` objects from a spawned `SeedSequence` and touches no global state.

---

## 4. Memory: the 45 MP budget

### 4.1 Tap freeing

`run_topology` accumulated every tap in one state dict and freed nothing
until the run returned — seven full-resolution `(H, W, 3)` float64 buffers,
168 B/px, of which at most two are ever live.

It now computes, over the whole declared topology, the index of the last node
that reads each tap, and drops the reference once that node has fired. It is
conservative: a tap survives if any later node *might* read it, so nodes that
do not fire cannot cause a premature free. `free_taps=False` restores the old
behaviour for debugging, and collecting intermediate taps
(`process(img, collect=Tap.CMY_PRINT)`) is unaffected — verified.

Measured at 16 MP on the exact path: **6.15 → 5.57 GB**, a 9.4% reduction, at
no time cost.

### 4.2 Rejected: float32 working precision

Adding `settings.working_precision = 'float32'` to `_preprocess` is
numerically free — ΔE2000 max **0.000138**, PSNR **172 dB** against the
float64 render — and bought **no memory at all**: 5.61 GB vs 5.57 GB.

The cause is AGENTS.md trap 7: `colour.RGB_to_RGB` / `RGB_to_XYZ` promote
back to float64 regardless of input dtype, so the float32 array is upcast by
the first colourspace conversion in `filming.expose`. Casting at the door
does nothing; a real float32 pipeline means casting after every
colour-science call, which belongs with the M2 node split.

The setting is kept (default `'float64'`) because it is correct and costs
nothing, but it must not be described as a memory optimisation until the
promotions are fixed.

### 4.3 Where the remaining memory is

Peak RSS by pipeline prefix, 16 MP full quality:

| collect tap | time | peak | B/px | delta |
|---|---|---|---|---|
| `rgb_pre` | 1.53 s | 1.46 GB | 91 | — |
| `log_e_film` | 4.17 s | 4.87 GB | 304 | **+213** |
| `cmy_film` | 6.28 s | 6.19 GB | 387 | **+83** |
| `log_e_print` | 7.01 s | 6.21 GB | 388 | +1 |
| `cmy_print` | 6.97 s | 6.23 GB | 389 | +1 |
| `rgb_out` | 9.50 s | 6.46 GB | 404 | +15 |

The high-water mark is set in the **first two nodes**. Everything downstream
of `cmy_film` — the stages M1 and M1.5 addressed — is now flat.

Drilling into `filming.expose`:

| step | delta B/px |
|---|---|
| `rgb_to_film_raw` (spectral upsampling) | **+93** |
| `apply_diffusion_filter_um` | 0 |
| `apply_gaussian_blur_um` | 0 |
| `apply_halation_um` | **+96** |
| `log10` | 0 |

Two allocations of ~95 B/px each — roughly four full-resolution float64
`(H, W, 3)` buffers apiece. The spatial filters are already in-place. These
two are the M2 target; this RFC does not touch them.

---

## 5. Measured results (M1.6)

All numbers: Portra 400 → Portra Endura, MLX backend, M3 Max / 36 GB, via
`tests/baseline/run_reference.py`.

### 16 MP (3264×4901)

| path | M1.5 | **M1.6** | change |
|---|---|---|---|
| exact (no LUT / no grain / no glare) | 8.14 s / 6.15 GB | **8.25 s / 5.57 GB** | memory −9.4% |
| full quality (LUT + grain + glare) | 24.10 s / 6.66 GB | **9.78 s / 6.60 GB** | **2.47× faster** |

Grain itself: **~15.9 s → ~1.5 s**, measured as the full-quality/exact-path
delta with the sampler as the only variable (24.13 s vs 9.78 s, same config).

### 45 MP (5475×8220)

| | before | **M1.6** |
|---|---|---|
| full quality | ~27 GB | **32.03 s / 15.64 GB** |

**1.7× leaner**, at 348 B/px — the same per-pixel budget as 16 MP, so the
pipeline is now linear in pixel count with no super-linear term.

### Cumulative, full-quality 16 MP

| | time | peak |
|---|---|---|
| before RFC-001 | 33.13 s | 13.07 GB |
| after M1.5 | 24.10 s | 6.66 GB |
| **after M1.6** | **9.78 s** | **6.60 GB** |

**3.39× faster, 1.98× leaner** than the starting point.

---

## 6. Equivalence

Grain is stochastic, so RFC-001 §6.2's distribution test applies: the two
samplers must agree on *statistics*, not per-pixel values.

### 6.1 Unit level

`sample_layer_density` vs `layer_particle_model(method='poisson_binomial')`,
2048² flat patches:

| | mean | RMS×1000 | skew |
|---|---|---|---|
| scipy reference | 0.900025 | 48.739 | +0.0529 |
| exact (thinned, threaded) | 0.899991 | 48.707 | +0.0529 |

Reproducibility: identical output for a repeated call, and identical across
worker counts (3 vs 12). Skewness matches the theoretical `1/sqrt(mu)` to
three decimals across the full density range.

### 6.2 End-to-end, 16 MP

`compare.py --mode stochastic`, grain field isolated against a grain-free
render, glare disabled:

| metric | bar | measured | |
|---|---|---|---|
| `grain_mean_shift_rms` | ≤ 0.05 | **0.00112** | PASS |
| `grain_rms_rel` | ≤ 0.02 | **0.00088** | PASS |
| `skew_rel` | ≤ 0.05 | **0.03382** | PASS |
| `kurtosis_rel` | ≤ 0.05 | **0.00739** | PASS |
| `psd_correlation` | ≥ 0.98 | **0.99951** | PASS |

The grain's power spectrum, amplitude, asymmetry and tail weight are all
preserved. `skew_rel` at 3.4% is the loosest of the five and is the metric
that matters most here — it is the one `fast_stats` fails outright (it would
report ~1.0, a total loss).

### 6.3 One metric was changed

`STOCHASTIC_BARS` previously held `grain_mean_rel ≤ 0.01`, a *relative* error
on the grain field's mean. The grain field is zero-mean by construction, so
that divides by ~0 and reports numerical noise: it read 0.111 for an absolute
mean shift of 2.7e-5, under a sixth of a 16-bit code value.

Replaced with `grain_mean_shift_rms` — the DC shift in units of grain RMS,
barred at 5%. This is a meaningful quantity (how far the noise floor moved
relative to the noise itself) and it is the stricter test in any case where
grain is actually present. Recorded here because changing a pass/fail
criterion mid-effort deserves to be visible rather than buried.

---

## 7. Compatibility

`settings.grain_sampler` defaults to `'exact'`, which **changes the rendered
output**: same distribution, different realisation. Existing renders are not
reproducible pixel-for-pixel against a pre-M1.6 build. Set
`grain_sampler='scipy'` to recover the previous stream exactly.

This is a deliberate default change. It is called out here, in `AGENTS.md`,
and in the field's own comment in `params_schema.py`.

---

## 8. Next

1. **`filming.expose` memory** — `rgb_to_film_raw` +93 B/px and
   `apply_halation_um` +96 B/px are the entire remaining high-water mark
   (§4.3). Roughly four full-resolution temporaries each.
2. **Fix the float64 promotions** so §4.2 becomes real. This is the single
   largest remaining lever: it would nearly halve 45 MP again, to ~8 GB.
3. **M2 node split** — prerequisite for both of the above, and for tiling.
4. **Metal grain kernel** — §3.5 Cornish–Fisher plus Philox on global
   `(x, y)`, which also delivers tile invariance.

Grain is no longer the bottleneck. At 16 MP full quality the profile is now
led by `filming.expose` (~2.6 s) and `scanning.scan_print` (~2.3 s).
