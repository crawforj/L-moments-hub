# Region-building method sensitivity — does it actually matter?

A Bureau of Reclamation reviewer called region-*building* method (how the pool
of donor stations for a facility is assembled) "one of the most influential
points in the L-moments analysis," and asked for an alternative to the
original circular-radius rule. That request is why `region.method: cluster`
(Ward's-method cluster analysis, H&W 1997 sec. 9.2.3, via `lmomRFA::cluagg` /
`cluinf`) exists alongside `region.method: circular` in
[`R/region_methods.R`](../R/region_methods.R) (config: `region.method` in
`config/*.yml`).

Acknowledging the concern in prose isn't the same as answering it. This page
reports the answer: for a real facility, run the full pipeline once per
region-building method, using otherwise-identical config, and measure how
much the DDF (depth-duration-frequency) tail estimate moves. The tool that
does this is [`compare_regions.R`](../compare_regions.R) (repo root); this
page records the real output of actually running it, since the CSVs it
writes (`outputs/tables/*_region_method_sensitivity.csv`,
`*_region_method_spread.csv`) are not tracked in the repo (`outputs/` is
gitignored — see `.gitignore`).

## Como Dam (Bitterroot Valley, MT) — the primary validated test site

Run 2026-08-13: `Rscript compare_regions.R config/como.yml` (default
`circular,cluster`), full pipeline for both durations (24h, 72h), all 12
return periods (2 through 10,000 yr), config otherwise unchanged from
`config/como.yml`.

**Region composition differed, but both were judged homogeneous** — the
comparison isn't "one method fails," it's "two legitimate, passing regions
disagree on the number":

| duration | method | stations used | H1 | status | chosen dist. | index flood (mm) |
|---|---|---|---|---|---|---|
| 24h | circular | 36 | 0.725 | homogeneous | GEV | 29.29 |
| 24h | cluster | 41 | 0.630 | homogeneous | GNO | 30.78 |
| 72h | circular | 41 | 0.938 | homogeneous | GLO | 44.00 |
| 72h | cluster | 38 | 0.719 | homogeneous | GEV | 40.73 |

Note the distribution *choice itself* changes between methods for 24h (GEV
vs. GNO) — the region-building decision doesn't just resize the pool, it can
tip which family the goodness-of-fit step selects.

**Spread in the resulting depth estimate, per duration x return period**
(`spread_pct = 100 * (max - min) / max` across the two methods; full table:
`outputs/tables/COMO_DAM_region_method_spread.csv` after a local run):

| duration | T (yr) | depth, circular (mm) | depth, cluster (mm) | spread_pct |
|---|---|---|---|---|
| 72h | 10000 | 179.28 | 139.51 | **22.2%** |
| 72h | 5000 | 161.71 | 131.29 | 18.8% |
| 24h | 10000 | 93.35 | 114.48 | 18.5% |
| 24h | 5000 | 88.48 | 106.82 | 17.2% |
| 24h | 2000 | 81.97 | 97.02 | 15.5% |
| 72h | 2000 | 120.49 | 140.97 | 14.5% |
| 24h | 1000 | 76.99 | 89.82 | 14.3% |
| 24h | 500 | 71.96 | 82.81 | 13.1% |
| 24h | 200 | 65.24 | 73.79 | 11.6% |
| 72h | 1000 | 112.39 | 126.97 | 11.5% |
| 24h | 100 | 60.09 | 67.13 | 10.5% |
| 24h | 50 | 54.87 | 60.57 | 9.4% |
| 72h | 2 | 38.33 | 42.28 | 9.3% |
| 72h | 500 | 104.33 | 114.27 | 8.7% |
| 24h | 25 | 49.57 | 54.07 | 8.3% |
| 24h | 10 | 42.34 | 45.45 | 6.8% |
| 72h | 200 | 93.74 | 99.26 | 5.6% |
| 24h | 5 | 36.56 | 38.70 | 5.5% |
| 72h | 5 | 50.85 | 53.36 | 4.7% |
| 72h | 100 | 85.77 | 89.09 | 3.7% |
| 24h | 2 | 27.72 | 28.69 | 3.4% |
| 72h | 10 | 59.22 | 60.92 | 2.8% |
| 72h | 50 | 77.82 | 79.82 | 2.5% |
| 72h | 25 | 69.86 | 71.30 | 2.0% |

(Note: at 72h, `circular` gives the *higher* depth for T >= 1000 yr, while at
24h `cluster` gives the higher depth throughout — the sign of the effect is
duration-dependent, not a uniform "cluster runs high/low.")

### Reading

- **The reviewer's concern is real and quantified, not just acknowledged.**
  Region-building method moves the extreme-tail (T=10,000 yr, i.e. AEP 1e-4 —
  the design-relevant end for dam-safety PMF-adjacent screening) estimate by
  **18-22%** at Como, both durations. That is not noise-level; it is large
  enough that which method is used should be a documented, reviewed choice
  per facility, not a silent default.
- **It shrinks fast at operational return periods.** By T=100 yr the spread
  is 3.7-10.5%, and below T=25 yr it's mostly under 10% except for a modest
  9.3% blip at 72h/T=2 (a low-*T* return period where absolute depths are
  small, so percentage spread is more sensitive to small mm differences).
  The tail is where it matters most, and the tail is exactly where dam-safety
  screening looks.
- **Both regions pass homogeneity** (H1 < 1 for all four duration x method
  combinations) — this is not "one method is defensible and the other
  isn't." A reviewer cannot resolve this by homogeneity testing alone; it
  needs a judgment call on which station pool is climatologically more
  appropriate for Como (see the region maps,
  `outputs/figures/COMO_DAM__circular_region_map.png` and
  `..._cluster_region_map.png`, after a local run), which is exactly the kind
  of call the [`expert_review_checklist.md`](expert_review_checklist.md)
  "Region composition" section asks a reviewing hydrologist to make.

### How to reproduce

```
Rscript compare_regions.R config/como.yml
```

Writes `outputs/tables/COMO_DAM_region_method_sensitivity.csv` (detail, one
row per duration x method x return period) and
`COMO_DAM_region_method_spread.csv` (the spread table above) — both
gitignored (regenerate locally; not tracked in the repo).

## Hoover Dam (Colorado River, NV) — second facility, desert Southwest

Run 2026-08-13, same procedure: a one-off config built from the `NV10122`
row of `config/pilot.csv` via the same pattern `run_batch.R`'s
`gen_configs_from_manifest()` uses (template = `config/como.yml`, so
everything except site identity/coordinates matches Como's config), then
`Rscript compare_regions.R <that config>`.

**Result: 0.0% spread at every duration x return period.** Not because the
region-building choice doesn't matter here — it's a null result for a
different, and itself useful, reason:

```text
[...] Cluster region: site attributes (e.g. elevation) unavailable;
      falling back to circular.
```

`config/pilot.csv` (the 8-dam BOR pilot manifest) has no `elevation_m` for
any facility (`NA` — see the manifest and the note in
`gen_configs_from_manifest()`'s comments in `run_batch.R`). The Ward's-method
cluster region-builder in `R/region_methods.R` uses site elevation as one of
its clustering attributes; without it, it silently falls back to the
circular method instead of erroring — so `region.method: cluster` and
`region.method: circular` produced **the literal same region** for Hoover
(confirmed: identical `n_stations`, `H1`, chosen distribution, and depths for
both "methods" in `outputs/tables/NV10122_region_method_sensitivity.csv`).

This is a real, separate finding worth flagging on its own: **the cluster
method is silently a no-op for any facility whose config lacks
`elevation_m`** (all 8 current pilot dams, unless DEM elevation enrichment —
`LMC_ENRICH_ELEV=1`, off by default per `run_batch.R` — is run first). A
reviewer or future fleet run relying on `region.method: cluster` for
elevation-less facilities is silently getting circular's result, not
cluster's, with no warning surfaced above the `message()` log line. Whether
that fallback should instead be a hard error (so a mismatched
config/manifest combination can't pass silently) is a design question for
the project owner, not addressed here.

Given the fallback, Hoover does **not** answer whether the ~20% Como tail
spread is Rocky-Mountain-specific — it answers a different, useful question
(the elevation-dependency gotcha above). A real second data point would need
either a facility with real elevation data, or a Como/pilot run with
`LMC_ENRICH_ELEV=1` first.
