# D2/B4 -- BOR-308 vs NID-fleet reproducibility cross-check

_Generated 2026-08-20 by `qc/nid_bor_crosscheck.py`. Public-safe: agreement
statistics, method-diagnostic aggregates and named facility IDs only -- no
per-dam vulnerability content._

**Partial data.** NID inputs pinned to fleet-branch commit
`b63d8180746aee55239b3b5fa683c078fa5a9940` (`claude/desktop-nid-ad-hoc`,
50,375 of 73,303 facilities attempted = 68.7%) and to the `nid-run1-data`
release-asset snapshot uploaded `2026-08-20T03:23:19Z`
(`all_facilities_DDF.csv.gz` md5 `7692f87ecae15fb3c36b41fc1a93799c`,
`batch_diagnostics.csv.gz` md5 `62e42f1d862bce352c8d8f493abb0d78`,
`stations_used.csv.gz` md5 `7809f51141a233db5037bc6041e484cd`,
`stations_removed.csv.gz` md5 `5b19a6bcfe12ddfa5740f29c661deb21`). That tag is
re-clobbered every tranche round; the script re-verifies the digests and warns
loudly if a re-run is reading a different snapshot. **Partial completion does
not weaken this artifact**: the fleet runs largest-storage-first, so 298 of the
308 BOR dams (96.8%) are already complete. The 10 that are not are the
smallest in the BOR manifest (30-74 acre-ft, against a 90 acre-ft minimum among
the matched ones) and will simply extend the sample when they land.

BOR inputs are committed on `main` and need no pin: the pre-enrichment run at
`docs/example_outputs/fleet_308dam/` and the elevation-enriched circular
baseline preserved as `depth_circular_mm` in
`data/region_method_band/bor308_band.csv`.

## Why this is a reproducibility test at all

The same physical Bureau of Reclamation dams went through this pipeline twice,
from two manifests that key, name and enrich their facilities differently:

| | BOR-308 batch (pre) | BOR-308 batch (post) | NID national fleet |
|---|---|---|---|
| manifest | `config/facilities_BOR.csv` | same, elevation-enriched | `config/nid_manifest.csv` |
| run date | 2026-08-11 06:05 UTC | 2026-08-14 | 2026-08-11 -> ongoing |
| `elevation_m` | `NA` fleet-wide | DEM-enriched | `NA` fleet-wide |
| index flood | regional-mean fallback | elevation regression | regional-mean fallback |
| `elevation_band_m` | `[600, 2600]` | `[600, 2600]` | `[600, 2600]`, then `[-100, 6200]` |
| region method | circular | circular | circular |
| `search_radius_km` | 175 (manifest column) | 175 | 175 (`config/como.yml` default) |
| executor | local, `run_batch.R` | local | GitHub Actions, `run_nid_tranche.R` |
| output | `docs/example_outputs/fleet_308dam/` | `bor308_band.csv` | fleet branch + release assets |

Two of those rows are *natural experiments* rather than nuisances, and the
whole analysis turns on them:

- **elevation enrichment** (`bca0e992`, 2026-08-14) changed the BOR manifest
  only. Comparing NID against the **pre**-enrichment BOR run holds the
  index-flood path fixed; comparing it against the **post**-enrichment run
  isolates the enrichment (known-issue register item 4).
- **the elevation band** widened on the fleet branch at `603224c3`
  (2026-08-11 21:14 UTC, `[600, 2600] m` -> `[-100, 6200] m`) and was ported to
  `main` only on 2026-08-18 (`ca9a22ff`). So NID facilities completed *before*
  that fix ran the **same candidate-station rule as both BOR runs**, and those
  completed after did not. The band is an absolute filter on GHCN station
  elevation (`ghcn_candidates()` in `R/functions.R`), so widening it
  restructures the region for any dam whose surroundings fall outside
  600-2600 m -- and 119 of the 308 BOR dams sit outside that band themselves
  (104 below, 15 above).

Cohort membership is read from the fleet ledger at `a85ef3d2`
(`manifest_refresh`), the first ledger state after both the band fix and the
manifest refresh: **109 matched facilities in the narrow-band cohort, 186 in
the wide-band cohort.**

## Method

### Crosswalk (ID-keyed, no fuzzy matching anywhere)

Both manifests carry the NID `facility_id`, so the crosswalk is an exact
inner join and no name-or-coordinate fallback was needed or used.

| step | count | share |
|---|---|---|
| BOR-308 manifest facilities | 308 | |
| matched on NID `facility_id` | **298** | **96.8%** |
| matched *and* `ok` in the NID run | 298 | 100% of matches |
| fuzzy / name-coordinate fallback matches | **0** | -- |
| not yet reached by the NID fleet | 10 | 3.2% |
| matched but *failed* in the BOR-308 run (`ND00449`, `OK82908`, `SD01143`) | 3 | |
| **comparable facilities** | **295** | |

The name-join hazard this repo has been burned by is real here too: **38 of the
298 matched facilities (12.8%) carry a dam name that is not unique among the
50,375 completed NID facilities** (`TWIN LAKES` appears 10 times, `FISH LAKE`
9, `EAGLE LAKE DAM` 8, `WILLOW CREEK` 7). Four ID matches disagree on the
facility *name* across the two manifests, and the same four disagree on
*coordinates* by 0.72-0.98 km -- NID-mirror vintage drift, listed in full
below because two of them turn out to matter.

### Recovering depths from name-keyed outputs

Both runs' `all_facilities_DDF.csv` are keyed by dam NAME with no usable
`site_id` for their early cohorts (register item 8). Their
`batch_diagnostics.csv` *are* site_id-keyed and carry `depth_10k_mm`, so each
name's DDF rows were split into contiguous 24-row blocks (12 return periods x
2 durations, layout verified row-by-row) and each block attributed to a
`site_id` **only** when exactly one block matched that facility's T=10,000-yr
depth at *both* durations. Anything ambiguous is reported, not guessed:

- NID: **273 of 298** facilities got a verified full-T block. The 25 failures
  are register item 8 damage -- 24 whose name-block was overwritten by another
  dam and 1 genuinely ambiguous.
- BOR-pre: 303 of 305; BOR-post (`bor308_band.csv`) is already site_id-keyed
  for 285.
- **Full-T comparison set: 268 facilities x 2 durations x 12 return periods.**

A second layer sidesteps the name join entirely: `depth_10k_mm` is
site_id-keyed on *both* sides, giving a **T=10,000-yr comparison over all 295
comparable facilities with no name matching anywhere**. It agrees with the
full-T layer wherever both exist, which is itself a check on the block
attribution.

### Scale/shape decomposition

Because `depth(T) = index_flood x growth(T)` (`R/06_estimation.R`), an
index-flood-only difference is a *constant* depth ratio across T, while a
difference in region membership or distribution choice bends the ratio. Every
comparison below is therefore split into a **scale** component
(`median_T` of the ratio) and a **shape** component (spread of the ratio across
T). This turns "which input caused it" from an assertion into a measurement.

## Results

### Depth differences, NID relative to the pre-enrichment BOR run

![Two panels, T = 100 yr and T = 10,000 yr at 24 h, each an empirical CDF of the absolute relative depth difference on a log x-axis. The matched-elevation-band cohort is a near-vertical line pinned at the left axis limit: 95 of 96 facilities agree exactly and all agree within 1%. The widened-band cohort rises gradually from 11% exact agreement through the 1% mark near the 15th percentile and out past 100% difference in the tail.](figures/bor_nid_reldiff_ecdf.png)

| cohort | T | dur | n | median | median abs | IQR | p90 abs | max abs | within 1% |
|---|---|---|---|---|---|---|---|---|---|
| narrow band | 100 | 24h | 96 | +0.00% | **0.00%** | [0.00, 0.00] | 0.00% | 0.89% | **100.0%** |
| narrow band | 100 | 72h | 96 | +0.00% | **0.00%** | [0.00, 0.00] | 0.00% | 1.50% | 99.0% |
| narrow band | 10,000 | 24h | 96 | +0.00% | **0.00%** | [0.00, 0.00] | 0.00% | 0.27% | **100.0%** |
| narrow band | 10,000 | 72h | 96 | +0.00% | **0.00%** | [0.00, 0.00] | 0.00% | 1.55% | 99.0% |
| wide band | 100 | 24h | 172 | +0.00% | 8.23% | [-19.04, +4.23] | 42.06% | 147.42% | 19.2% |
| wide band | 100 | 72h | 172 | +0.00% | 10.58% | [-21.76, +5.01] | 50.91% | 179.06% | 19.8% |
| wide band | 10,000 | 24h | 172 | -1.06% | 12.54% | [-25.36, +5.74] | 43.70% | 230.22% | 14.5% |
| wide band | 10,000 | 72h | 172 | -0.03% | 13.84% | [-28.21, +4.87] | 59.83% | 302.60% | 20.3% |

The name-join-free T=10,000-yr layer over all 295 comparable facilities says
the same thing: narrow-band cohort (n = 218 facility x duration) **99.1% within
0.05%, 99.5% within 1%, worst case 1.58%**; wide-band cohort (n = 372) median
absolute difference **12.95%**, worst case 302.5%.

Note the medians in every row are ~0.00%: the disagreement is **symmetric, not
a bias**. Widening the band moves individual dams a long way in both
directions; it does not systematically raise or lower national depths.

### Cause attribution

![Log-log scatter of the shape component against the scale component, one point per facility and duration. The elevation-enrichment comparisons and the BOR-internal control form a flat band at 0.01 to 0.05 percent shape spread while their scale component ranges over four orders of magnitude, showing elevation moves only the magnitude. The widened-band comparison scatters upward, most points above the 1 percent shape line, showing the station pool changes the shape of the frequency curve as well. The fully matched comparison sits pinned in the bottom-left corner: 190 of 192 are identical in both components.](figures/bor_nid_scale_shape.png)

| comparison | n | scale, \|ln ratio\| p50/p90 | shape spread p50/p90/max | shape < 1% |
|---|---|---|---|---|
| narrow cohort vs BOR-pre (**every known input matched**) | 192 | 0.0000 / 0.0000 | 0.000 / 0.000 / 1.754% | 99.5% |
| narrow cohort vs BOR-post (elevation enrichment only) | 178 | 0.0443 / 0.2436 | 0.014 / 0.026 / 1.761% | 99.4% |
| **BOR-post vs BOR-pre** (BOR-internal control, elevation only) | 570 | 0.0679 / 0.4047 | 0.014 / 0.026 / **0.049%** | **100.0%** |
| wide cohort vs BOR-pre (elevation band differs) | 344 | 0.0930 / 0.5727 | 6.663 / 40.248 / 105.532% | 17.7% |
| wide cohort vs BOR-post (band + elevation) | 324 | 0.1014 / 0.4130 | 6.255 / 36.529 / 96.101% | 18.5% |

Read the third row first. The two BOR runs differ *only* in manifest
elevation, and their depth ratio is constant across T to within **0.049% at
the worst facility in 285** -- i.e. to rounding. That is the prediction
`estimate_index_flood()` makes if elevation touches nothing but the index
flood, and it confirms the mechanism instead of assuming it. Its magnitude is
large: the enrichment moves depths by a median of **6.8%** and up to **69%**,
identically at every return period. Register item 4 is not a footnote.

The wide-cohort rows are qualitatively different -- the ratio bends across T
(median 6.7% spread, p90 40%) as well as shifting. That is a *region* change,
not an index-flood change, exactly what widening an absolute elevation filter
on candidate stations should do.

### The decisive test: did the band actually bind?

`stations_used.csv` + `stations_removed.csv` joined to GHCN station elevations
say, per facility, whether the `[600, 2600] m` band would have excluded any
station the NID run actually considered. Within the wide-band cohort (cohort
held constant, so timing and code vintage cannot confound it):

| | band did **not** bind | band bound |
|---|---|---|
| reproduces BOR-pre byte-identically | **18** | 0 |
| does not | 2 | 152 |

Fisher exact p = 1.8e-22; complete separation apart from two facilities. Put
plainly: **every wide-cohort facility whose candidate pool the old band would
have touched disagrees, and 18 of the 20 whose pool it would not have touched
agree to the last decimal place.** Those 18 controls are not a timing artifact
-- they span ledger ranks 1,001 to 46,175, i.e. 2026-08-12 through 2026-08-18,
up to seven days after the BOR run and on GitHub-Actions runners rather than
the local machine.

Exact-reproduction rates overall: **narrow-band cohort 95 of 96 facilities
byte-identical at all 24 depths (99.0%)**; wide-band cohort 18 of 172 (10.5%).

### Null and alternative-explanation checks (QA/QC §E2)

Each candidate cause was *tested*, not asserted.

1. **GHCN data vintage -- ruled out for these dams.** The NID run has a far
   larger station cache (18,191 files vs 4,438 on `main`), but it is a strict
   superset: **all 4,438 blobs the BOR run committed are byte-identical on the
   fleet branch**, and `data/ghcn_inventory/` is the *same git tree object*
   (`c24fca8e`) on both branches, unchanged since 2026-08-11 03:18 UTC. All
   368 distinct stations the narrow cohort used are in that shared cache and
   byte-identical. **This is a real limit on the claim**: the agreement below
   demonstrates determinism and manifest-independence *given identical input
   data*, and says nothing about robustness to a genuine GHCN re-download.
   That test still has to be run.
2. **Code vintage -- ruled out.** `R/01_data_acquisition.R`,
   `R/03_screening.R`, `R/04_homogeneity.R` and `R/functions.R` are
   byte-identical between the BOR-run commit (`5a8c5b88`) and the fleet-branch
   commit in force when the residual cases ran. The only configuration delta
   was `data.use_local_fallback: true -> false` (the synthetic-fallback block,
   register item 1), which is all-or-nothing per facility and therefore cannot
   produce a one-station change.
3. **Nondeterminism -- searched for, not found.** The RNG is seeded from
   `cfg$seed` (`20260811`, inherited by every generated facility config) at
   `R/07_uncertainty.R:38`. Testing the *Monte-Carlo bounds* rather than just
   the point estimates: **93 of 96 narrow-cohort facilities reproduce
   `depth_lo_mm`, `depth_hi_mm` and `rel_rmse` byte-identically too.** The
   three that do not are all in the coordinate-shift list. No unseeded
   randomness was found anywhere in the comparison.
4. **Is the agreement trivially guaranteed?** No. The two runs generated their
   per-facility YAML from different manifests, ran under different runners
   (`run_batch.R` locally vs `run_nid_tranche.R` on GitHub Actions), on
   different operating environments, and at different times; the fleet run
   additionally routes every output through a fold-in step the BOR run does
   not have. Byte-identical depths across that gap are not free.
5. **Spatial autocorrelation as an alternative to "the band bound".** The 2x2
   above is computed *within* the wide cohort and keyed on a per-facility
   mechanical property (does any considered station fall outside 600-2600 m),
   not on geography. The 18 controls are spread across CO, ID, MT, NE, OR, SD
   and WY rather than clustered, so the separation is not one region behaving
   differently.

### Residual: the three facilities that do not fit

| facility | cohort | what differs | size |
|---|---|---|---|
| `ID00275` (MINIDOKA SOUTH DIKE / MINIDOKA) | narrow | manifest coordinates differ by **0.82 km** -> one station swap | max 1.55% on depths |
| `SD01139`, `SD01141` (PACTOLA, SHADEHILL dikes) | narrow | coordinates differ by 0.76 / 0.72 km; **point estimates identical**, only MC bounds move | max 0.44% on bounds |
| `CO01659`, `ID00276` | wide, band-insensitive | one fewer station in the NID region (20->19, 44->43 / 46->45) | max 4.73% / 2.94% |

`SD01139` / `SD01141` are the informative pair. Their point estimates are
identical to the last decimal, which *proves* the station set is unchanged
(a different set could not produce identical pooled L-moments); only the
seeded bootstrap's bounds move, by at most 0.44%. The most economical reading
is that the sub-kilometre coordinate shift reorders stations by distance and
so changes the order in which the seeded RNG stream is consumed, while every
order-invariant quantity is untouched. That is determinism that is sensitive
to input *ordering*, not nondeterminism -- but it is worth knowing that the
published uncertainty bounds carry a ~0.5% ordering sensitivity that the point
estimates do not.

`CO01659` and `ID00276` are **not explained by this analysis and are logged as
open**. Band, station files, inventory, analysis code and coordinates are all
ruled out above; both simply lose one station from the final region, and in
`CO01659`'s case the surviving region includes stations sitting exactly at the
20-year `min_record_years` threshold, where any difference in how a record is
counted flips membership. Two facilities in 116 informative comparisons
(1.7%) is a small but non-zero unexplained rate and should be closed by
re-running those two under current code at fleet completion.

## The reproducibility statement

> **On the 96 Bureau of Reclamation dams where the NID national fleet run and
> the BOR-308 batch run shared every known input -- same manifest coordinates,
> same `NA` elevation and therefore same index-flood path, same
> `[600, 2600] m` elevation band, same 175 km search radius, same circular
> region method, same GHCN station files and inventory -- 95 of 96 (99.0%)
> reproduce **byte-identically at all 24 depth-duration-frequency points**, and
> 93 of 96 reproduce their Monte-Carlo uncertainty bounds byte-identically as
> well. The single exception is a facility whose coordinates differ by 0.82 km
> between the two manifests, and it agrees to within 1.6%. Across the whole
> matched set the worst disagreement under matched inputs is **1.58%**.
>
> This holds across two different manifests with different facility naming
> (12.8% of the matched dams have names that are ambiguous nationally), two
> different batch runners, two different execution environments (local vs
> GitHub Actions), and up to seven days apart. **The pipeline is deterministic
> and manifest-independent.**
>
> Where the two runs *disagree* -- median 12.95% and up to 302% at
> T = 10,000 yr -- the disagreement is fully accounted for by two documented
> input changes, in this order of importance:
> 1. **the elevation-band widening** (`[600, 2600]` -> `[-100, 6200] m`), which
>    explains the disagreement with complete separation (Fisher p = 1.8e-22):
>    every facility the old band would have constrained disagrees, 18 of the 20
>    it would not have are byte-identical;
> 2. **manifest elevation enrichment**, which acts as a pure multiplicative
>    scale on the index flood (shape spread <= 0.049% across 285 facilities)
>    worth a median 6.8% and up to 69% in depth.
>
> **Caveats.** (a) Both runs read the *same* committed GHCN station files and
> the same inventory tree, so this establishes computational determinism, not
> robustness to a data re-download -- that test is still owed. (b) Two
> facilities (1.7% of the informative sample) lose a single region station for
> reasons this analysis could not isolate. (c) The comparison covers 268
> facilities at full T and 295 at T = 10,000 yr, out of 308; 25 NID facilities
> were excluded because register-item-8 name-collision damage makes their
> full-T rows unattributable, and 3 failed in the BOR run. (d) Everything here
> is screening-grade research on screening-grade data and does not outrank the
> per-facility expert review `docs/expert_review_checklist.md` demands.

## Known-issue register items touching this artifact

- **Item 8** (fold-in name-collision damage) -- the direct reason 25 of 298
  matched NID facilities have no attributable full-T row, and the reason the
  T=10,000-yr layer is computed from site_id-keyed diagnostics instead.
- **Item 4** (elevation `NA` fleet-wide) -- quantified here for the first time
  against a real enriched counterpart: median 6.8%, p90 36%, max 69%, purely
  multiplicative.
- **Item 3** (fleet ran circular-only, pre-rebase) -- both sides of this
  comparison are circular, so the comparison is unaffected, but nothing here
  transfers to a cluster-region fleet.
- **Item 1** (synthetic-fallback incident) -- the BOR-308 outputs predate the
  fix and were never audited against it. This cross-check gives partial
  reassurance: 113 of the 116 facilities where a contaminated BOR region would
  have shown up as a disagreement are byte-identical.
- **Item 2** (unverified NID coordinates) -- the four coordinate-drift matches
  found here are a direct instance, and three of the five residual facilities
  trace to them.

## Reproduce

```sh
python qc/nid_bor_crosscheck.py          # pinned inputs; re-fetches assets if absent
```

Outputs `qc/reports/bor_nid_crosscheck.csv` (295 facilities x 2 durations, with
cohort, band-binding, station counts, chosen distributions, depths from all
three runs and the scale/shape decomposition) plus the two figures above. The
script verifies the pinned release-asset MD5s and warns rather than silently
re-basing the analysis on a newer fleet snapshot; `--fleet-ref` re-pins
deliberately at fleet completion.
