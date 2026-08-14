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

**2026-08-13 finding (superseded below): the first run of this comparison
was a false null.** `config/pilot.csv` had no `elevation_m` for any of its 8
facilities (`NA` fleet-wide), so the Ward's-method cluster region-builder in
`R/region_methods.R` — which uses site elevation as one of its clustering
attributes — silently fell back to `circular` (logged, not errored):

```text
[...] Cluster region: site attributes (e.g. elevation) unavailable;
      falling back to circular.
```

That produced **the literal same region** for both "methods" (identical
`n_stations`, `H1`, chosen distribution, depths) and a meaningless 0.0%
spread. It was a real, useful finding on its own — cluster is silently a
no-op wherever elevation is missing — but it did not answer the intended
question. See `docs/ASSUMPTIONS_AND_LIMITATIONS.md` section B item 5 for how
that gap was closed (DEM elevation enrichment via `enrich_elevations()`,
run for real against `config/pilot.csv` and `config/facilities_BOR.csv` on
2026-08-14).

### 2026-08-14 — real run, elevation enriched, no fallback

`config/pilot.csv`'s `NV10122` row now carries a real DEM-derived
`elevation_m` (421 m — see the elevation-enrichment run in
`ASSUMPTIONS_AND_LIMITATIONS.md` §B5; Hoover's actual dam-crest elevation is
~376 m, so this is in the right ballpark for a coordinate-based DEM point
lookup near, not exactly on, the crest). Same procedure as before: a one-off
config built from that row via `gen_configs_from_manifest()`
(template = `config/como.yml`), then `Rscript compare_regions.R <that
config>`. The audit log for this run contains **no** "site attributes
unavailable" message — `cluster` genuinely engaged and built a different
region from `circular`:

| duration | method | stations used | H1 | status | chosen dist. | index flood (mm) |
|---|---|---|---|---|---|---|
| 24h | circular | 29 | 0.912 | homogeneous | GLO | 16.86 |
| 24h | cluster | 7 | -1.304 | homogeneous | GLO | 28.92 |
| 72h | circular | 27 | 0.308 | homogeneous | GLO | 18.02 |
| 72h | cluster | 7 | -1.893 | homogeneous | GLO | 33.92 |

Unlike Como, the chosen distribution family doesn't flip (GLO both methods,
both durations) — but the region **size** swings hard: `cluster` picks a
much tighter pool (7 stations) than `circular`'s radius-based 27-29, and
that smaller, more climatologically homogeneous-by-construction pool has a
markedly higher regional mean (index flood ~1.7x `circular`'s).

**Spread in the resulting depth estimate, per duration x return period**
(`outputs/tables/NV10122_region_method_spread.csv`):

| duration | T (yr) | depth, circular (mm) | depth, cluster (mm) | spread_pct |
|---|---|---|---|---|
| 72h | 2 | 16.61 | 31.74 | 47.7% |
| 72h | 5 | 23.76 | 45.41 | 47.7% |
| 72h | 10 | 28.87 | 54.79 | 47.3% |
| 72h | 25 | 36.14 | 67.72 | 46.6% |
| 72h | 50 | 42.30 | 78.35 | 46.0% |
| 24h | 2 | 15.39 | 26.98 | 43.0% |
| 72h | 100 | 49.21 | 89.97 | 45.3% |
| 24h | 5 | 21.95 | 38.45 | 42.9% |
| 72h | 200 | 57.00 | 102.74 | 44.5% |
| 24h | 10 | 26.76 | 46.39 | 42.3% |
| 72h | 500 | 68.90 | 121.67 | 43.4% |
| 24h | 25 | 33.79 | 57.42 | 41.2% |
| 72h | 1000 | 79.29 | 137.73 | 42.4% |
| 24h | 50 | 39.88 | 66.56 | 40.1% |
| 72h | 2000 | 91.07 | 155.49 | 41.4% |
| 24h | 100 | 46.84 | 76.61 | 38.9% |
| 72h | 5000 | 109.10 | 181.88 | 40.0% |
| 24h | 200 | 54.83 | 87.72 | 37.5% |
| 72h | 10000 | 124.88 | 204.31 | 38.9% |
| 24h | 500 | 67.30 | 104.30 | 35.5% |
| 24h | 1000 | 78.43 | 118.47 | 33.8% |
| 24h | 2000 | 91.28 | 134.23 | 32.0% |
| 24h | 5000 | 111.38 | 157.82 | 29.4% |
| 24h | 10000 | 129.35 | 178.00 | 27.3% |

### Reading — Hoover answers the open question, and the answer is "no, not Rocky-Mountain-specific, but the SHAPE is different"

- **Region-building method moves Hoover's estimate a lot more than Como's,
  and in the opposite direction with respect to return period.** At Como,
  spread *grows* with T (13-14% around T=1000 up to 18-22% at T=10,000 — the
  tail is where it matters most). At Hoover, spread *shrinks* with T (~43-48%
  at T=2-50 down to 27-39% at T=10,000). The desert-Southwest site is not a
  smaller-magnitude repeat of Como's finding — it's a genuinely different
  failure mode: `cluster`'s much smaller donor pool (7 vs. 27-29 stations)
  pulls the regional mean up hard at every return period, and the GLO growth
  curve's shape (same family both methods, so no distribution-choice effect
  here) means that inflation attenuates slightly, rather than compounds, at
  the extreme tail.
- **So: yes, this is a real second data point, and it says the
  reviewer's concern generalizes rather than being basin-specific** — but
  each facility's spread has its own shape, driven by how differently
  `cluster` and `circular` populate the donor pool at that location, not by
  a single fleet-wide "cluster runs X% high" rule. That reinforces the
  existing reviewer guidance: `compare_regions.R` should be run **per
  facility**, not assumed from one prior result.
- **Both regions still pass homogeneity** (`cluster`'s negative H1 values,
  -1.3 and -1.9, indicate an unusually *tight*, low-dispersion pool — well
  within the homogeneous range, not a red flag by itself, but worth an
  expert eyeballing whether 7 stations is enough donor depth for a
  10,000-yr estimate; see `expert_review_checklist.md`).

### How to reproduce

```
Rscript compare_regions.R config/facilities/NV10122.yml
```

(`config/facilities/NV10122.yml` is generated on demand from
`config/pilot.csv`'s `NV10122` row via `run_batch.R`'s
`gen_configs_from_manifest()` — not tracked in the repo, `config/facilities/`
is gitignored; regenerate locally.)
