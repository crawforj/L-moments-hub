# Cluster vs. circular region method — fleet-wide result (all 308 BOR dams)

`docs/REGION_METHOD_SENSITIVITY.md` answered "does region-building method
matter" for two hand-picked facilities (Como, Hoover). This page answers it
for the **whole BOR-308 fleet**, now that elevation is real for every
facility (see `docs/ASSUMPTIONS_AND_LIMITATIONS.md` §B5) and `cluster` can
actually run instead of silently falling back to `circular`.

## Run

- **Circular baseline**: the pre-existing fleet run in the main clone,
  `C:\dev\L-moments-hub\outputs\batch\all_facilities_DDF_full308.csv`
  (`region.method: circular`, the manifest default).
- **Cluster run**: `Rscript run_batch.R --manifest
  config/facilities_BOR_cluster.csv` (a copy of `facilities_BOR.csv` with
  `region_method: cluster` added per row — `facilities_BOR.csv` itself was
  deliberately left untouched; promoting `cluster` to the fleet *default* is
  a separate decision, not made here). Run 2026-08-14, ~35 sec/facility
  (faster than the 10-dam timing test predicted), full 308 in ~3.1 hours.
  **292/308 (94.8%) succeeded**; 16 failed for legitimate, unrelated reasons
  (8 transient GHCN download errors, 8 genuine too-few-stations-for-a-region
  cases) — not a `cluster`-specific failure mode, comparable to this
  project's usual fleet failure rate.

## FINAL, CLEAN RESULT (2026-08-14 evening): confound eliminated, comparison re-run

The baseline-staleness confound documented in the follow-up section below is
now **resolved, not just disclosed**: the full 308-dam `circular` baseline was
re-run with the same real, elevation-enriched manifest the cluster run used
(`config/facilities_BOR_circular.csv`, 297/308 ok), so both sides of the
comparison share the identical index-flood method. Every number in this
section supersedes both the original headline section and the interim
corrected reading below.

**Proof the comparison is now clean — the fallback control group:** the 84
facilities where `cluster` internally fell back to `circular` (identical
region-building to the baseline by construction) now show **0.0% spread at
every one of their 296 facility×duration×return-period combinations** —
exactly the ~0% a clean comparison requires. In the confounded version this
group's spread was median 26.4% at T=10,000 yr, purely from the elevation
artifact. It is now zero. The comparison methodology is validated, not
assumed.

**The real, region-method-only fleet-wide effect (221 genuine-cluster
facilities, 428 facility×duration combinations):**

| Return period | Median spread | Mean spread | Max spread | >15% spread |
|---|---:|---:|---:|---:|
| T = 100 yr | 9.5% | 13.4% | 95.6% | — |
| T = 10,000 yr | **15.1%** | **20.0%** | 94.6% | **215/428 (50.2%)** |

Distribution at T=10,000 yr: <5%: 74 · 5–15%: 139 · 15–30%: 108 ·
30–50%: 83 · >50%: 24.

Top movers (T=10,000 yr): Bradbury 94.6%, BOR Deer Creek 67.0%, Jamestown
Dam 66.7%, Lauro 65.2%, Ochoco 62.8%, Roza Diversion 62.7%, East Canyon
61.8% — the same names the confounded pass surfaced, confirming those were
real signal, not artifact.

**Bottom line for Reclamation:** where cluster analysis genuinely engages
(221 of 292 completed facilities; the rest fall back to circular by
design), the region-building choice moves the design-relevant tail estimate
by a median ~15% and mean ~20%, with **half the fleet moving more than 15%**
and a tail of facilities moving 50–95%. The reviewer's "one of the most
influential points" assessment is quantitatively confirmed at fleet scale,
cleanly. Neither method is thereby shown "correct" — both pass homogeneity
testing — so per-facility expert review of region composition (see
`expert_review_checklist.md`) remains the resolution path, now with real
numbers showing where that review matters most.

**Correlational patterns, re-derived from the clean data** (T=10,000 yr,
428 genuine-cluster combinations — these supersede the confound-era
patterns in the follow-up section below):

- **The elevation pattern DID NOT SURVIVE.** Clean terciles: low-elevation
  mean 20.3%, mid 18.6%, high 21.0% — essentially flat. The confounded
  pass's low-17.6%/high-23.1% gradient was largely an artifact of the
  confound itself (unsurprising in hindsight: the confound *was* the
  elevation/index-flood fix, which acts through site elevation). Do not
  quote "mountainous sites are more sensitive to region-building choice" —
  the clean data doesn't support it.
- **The state pattern survives**: WA (mean 29.5%), UT (24.0%), OR (23.7%)
  highest; NE (9.8%), NM (12.8%), ND (13.7%) lowest. Pacific NW /
  Intermountain West facilities remain the most method-sensitive.
- **The small-region pattern survives, strongly**: cluster regions under 18
  stations show mean 26.7% spread vs. 16.3% for regions above 28 stations —
  fewer donor stations means each has more leverage on the growth curve.
  This is the most actionable pattern: small-cluster facilities deserve the
  closest region-composition review.
- **The distribution-family pattern survives and sharpens**: PE3-selected
  facilities mean 29.5% (n=26, small), GLO 24.7% (n=116), GEV 17.6%
  (n=244), GNO 15.0% (n=42).

The two sections below are retained as the honest record of how this result
was first computed wrong, caught, and fixed — read them for provenance, not
for numbers.

## Same-day follow-up: the headline numbers below conflate two effects — read this first

A second pass over this same run's output (same `outputs/batch/all_facilities_DDF.csv`
in this worktree, same baseline file, nothing re-run) found that the "spread"
numbers in the **Headline result** section below are not a clean measurement
of region-*building* method alone. They also carry a second, unrelated effect
from comparing against a **stale baseline**, and the two need to be
separated before either number is quoted to Reclamation.

**The confound.** `estimate_index_flood()` (`R/functions.R`) defaults to
`index_flood.method: "regression"` (fit mean-AMS-vs-elevation across the
region's stations, then predict at the target site's elevation) in *both*
`config/como.yml` templates (main clone and this worktree — verified
identical). But when the target site's `elevation_m` is `NA`, that function
silently degrades to the plain **regional mean** (`mean(means)` — see
`functions.R` lines 481-497) instead of a real regression, "so it doesn't
crash." The archived circular baseline
(`C:\dev\L-moments-hub\outputs\batch\all_facilities_DDF_full308.csv`, run
2026-08-13) was generated when `config/facilities_BOR.csv` had `elevation_m
= NA` fleet-wide (verified: `git show HEAD:config/facilities_BOR.csv` in the
main clone still shows `NA` for Hoover/Glen Canyon today) — i.e. it used the
degraded regional-mean fallback for **every** facility, regardless of
region-building method. The elevation fix (`dcb1ac83`, same day as this
batch run) means every facility in *this* run — `cluster` **and** any
facility where `cluster` internally fell back to `circular` — now gets a
real elevation-regression index flood. So "cluster run vs. archived
baseline" silently measures **(region-method change) + (index-flood-method
change)** at once, not region-method alone.

**How this was caught: the 74 facilities where `cluster` itself fell back to
`circular`.** `region.method: cluster`'s candidate selection
(`R/region_methods.R`) still falls back to the plain circular-radius method
per-facility whenever the geographic/attribute prefilter can't support a
usable cluster (too few stations in the 600 km prefilter pool, assigned
cluster below the 5-site floor, elevation-band re-check drops too many
members, etc. — logged via `audit_log()`, not errored). For these 74
facilities, region-building is **identical** to the archived baseline (same
`ghcn_candidates()` call, same station pool) — so any depth difference from
the baseline can *only* come from the index-flood confound, not region
choice. It should be ~0%. It is not:

| | T = 100 yr | T = 10,000 yr |
|---|---:|---:|
| Fallback facilities (n=146 facility×duration, confound only, no region-method effect) — median / mean / max spread | 19.7% / 23.3% / 60.0% | 26.4% / 27.9% / 70.8% |

That is the confound's own magnitude, fleet-wide: a **median ~20-26%,
mean ~23-28%, spread purely from the elevation/index-flood fix**, with
nothing to do with `circular` vs. `cluster`.

**Corrected, region-method-only reading: the 215 facilities where `cluster`
genuinely engaged** (verified via the run's audit log — real cluster
membership assignment, not a fallback message; identified programmatically
by grepping `outputs/batch/cluster_full308/run_log_cluster308.txt` for
`Cluster region: falling back to circular` vs. `nearest centroid dist=`
per facility block). These 215 facilities' comparison against the baseline
still carries *some* of the same index-flood confound (their baseline
comparison point is equally stale), but at least isn't purely the fallback
group's noise floor:

| | T = 100 yr | T = 10,000 yr |
|---|---:|---:|
| Genuine-cluster facilities (n=426 facility×duration) — median / mean / max spread | 9.9% / 14.2% / 95.2% | 15.3% / 20.0% / 93.8% |

**The honest bottom line:** the genuine-cluster group's median/mean spread
(15.3% / 20.0% at T=10,000) is *smaller* than the fallback group's pure
confound noise floor (26.4% / 27.9%) — meaning this baseline-comparison
methodology **cannot cleanly separate "cluster picked a different, better/
worse region" from "the baseline is stale."** It does not mean region
method doesn't matter — the controlled, same-process, same-elevation
`compare_regions.R` spot checks in `docs/REGION_METHOD_SENSITIVITY.md`
(Como 18-22%, Hoover 27-48%, both with real elevation on *both* sides of
the comparison) remain the most trustworthy quantification of the
region-method effect specifically, and land in a similar range to the
genuine-cluster fleet numbers above, which is reassuring but not proof.
**A clean fleet-wide answer needs one of:** (a) a fresh `circular`
baseline re-run with today's real elevation (~3 hours, not done in this
pass — the task that produced this page was scoped to "run `cluster`
fleet-wide against the *existing* baseline," not to regenerate that
baseline), or (b) fleet-scale paired `compare_regions.R`-style runs (both
methods, same process, same elevation, per facility) — ~2x the compute of
this pass, also not done here.

**Real patterns that emerged in the genuine-cluster group** (T=10,000 yr
spread, all still subject to the confound caveat above, so read as
suggestive, not final):
- **Elevation correlates with spread**: low-elevation tercile (<1,020 m)
  mean 17.6%, high-elevation tercile (>1,643 m) mean 23.1% — mountainous
  sites are more sensitive to region-building choice, plausibly because
  orographic precipitation gradients make *which* stations end up in the
  donor pool matter more.
- **State/region pattern**: WA (27.1%), UT (26.7%), OR (25.1%), CO (24.3%)
  — Pacific NW / Intermountain West states — show the highest mean spread;
  NE (9.3%), NM (12.4%), MT (12.6%) the lowest. Consistent with the
  elevation pattern (terrain-driven climate transitions vs. flatter, more
  climatologically uniform terrain).
- **Chosen distribution family matters**: facilities where `cluster` selected
  GLO show much higher mean spread (28.2%) than GNO (13.0%) or GEV (17.5%,
  the most common choice, n=241/426) — GLO's unbounded tail behavior appears
  more sensitive to which stations are in the region.
- **Smaller cluster regions show more spread**: bottom tercile by station
  count (<18 stations) mean 24.5% vs. mid-tercile 17.5% — consistent with
  the Hoover finding (a 7-station cluster region swinging 27-48%) — fewer
  donor stations means each one has more leverage on the regional growth
  curve.

**Failure breakdown (16/308, unrelated to `cluster` specifically):** 8
transient GHCN download errors (`TX04425, OK02504, OK02501, OH02253,
IL50045, IL50021, IL50054, TX06567`) and 8 genuine too-few-candidate-station
cases (`OK02503, CA10154, OK02502, OK82908, OK20502, KS00023, OK02500,
SD01143`) — note **6 of the 8 station-sparse failures are Oklahoma**
(`OK02500-OK02504`, `OK20502`, `OK82908`), a real regional data-sparsity
cluster worth a closer look independent of this task (possibly a GHCN
coverage gap in that part of OK, not a facility-specific issue).

**Duplicate facility names**: `facilities_BOR.csv` has 3 duplicate `name`
values (`PATHFINDER DIKE`, `GLENDO DIKE NO. 1`, `SCOGGINS` — 2 facilities
each, different `facility_id`s). Both the cluster and circular DDF outputs
key on `name` only (no `facility_id` column), so these 6 facility_ids are
**excluded** from all paired comparisons above (unresolvable ambiguity, not
a data error) — a caveat for the numbers in this section specifically; the
Headline result section below did not apply this exclusion.

## Headline result: the reviewer's concern is real for most of the fleet, not a Como-specific curiosity

> **As-first-written, unconflated.** The table below joins all 289 unique
> `site` names present in both outputs (578 = 289 × 2 durations), including
> the 3 duplicate-name facilities (ambiguous 1:many join — see the
> follow-up section above) and the 74 facilities where `cluster` internally
> fell back to `circular` (region-method-identical to the baseline, so their
> spread here is confound-only, not a region-method signal). **Use the
> follow-up section above for the region-method-only reading**
> (genuine-cluster-only, duplicate names excluded); this section is kept
> as originally written for the record.

Comparing every successfully-completed facility × duration combination
(578 total) at the two return periods a dam-safety screen cares about most:

| Return period | Median spread | Mean spread | Max spread |
|---|---:|---:|---:|
| T = 100 yr | 12.2% | 16.4% | 95.3% |
| T = 10,000 yr | 17.5% | 22.0% | 93.8% |

**Distribution of T=10,000yr spread across all 578 combinations:**

| Spread | Count | % of fleet |
|---|---:|---:|
| < 5% | 92 | 15.9% |
| 5-15% | 160 | 27.7% |
| 15-30% | 155 | 26.8% |
| 30-50% | 131 | 22.7% |
| > 50% | 40 | 6.9% |

**62.8% of dam×duration combinations (363/578) show a >15% spread at
either T=100 or T=10,000 yr.** This is materially larger and more
widespread than the two-facility spot check suggested (Como: 18-22%,
Hoover: 27-48%) — those weren't outliers, but they also weren't
representative of the tail of the distribution, where some dams move by
70-95% depending on which region-building method is used.

**Top 15 by T=10,000yr spread:**

| Facility | Duration | T=100 spread | T=10,000 spread |
|---|---|---:|---:|
| Bradbury | 24h | 95.3% | 93.8% |
| Jamestown Dam | 24h | 71.2% | 76.0% |
| Adahl-Jones Project | 24h | 69.5% | 73.5% |
| Lauro | 24h | 77.7% | 71.1% |
| Little Panoche Detention | 72h | 49.7% | 70.8% |
| BOR Deer Creek | 72h | 67.2% | 67.9% |
| Upper Wheeler Saddle Dam | 72h | 52.8% | 66.9% |
| Upper Wheeler Saddle Dam | 24h | 50.6% | 64.9% |
| East Canyon | 24h | 55.6% | 62.4% |
| Ochoco | 72h | 54.8% | 62.3% |
| Reservoir A | 72h | 27.3% | 61.3% |
| San Justo | 72h | 40.8% | 60.7% |
| Jamestown Dam | 72h | 56.7% | 60.4% |
| Westside Deten Dk 3 | 24h | 55.0% | 60.3% |
| West Side Detention Dike No. 2 | 24h | 56.1% | 60.0% |

## Reading this honestly

- **This is not evidence that `cluster` is "more correct" than `circular`,
  or vice versa.** Both methods pass the same homogeneity test per facility
  (see the per-facility spot checks in `REGION_METHOD_SENSITIVITY.md` — both
  Como region variants and both Hoover region variants were "homogeneous" by
  the pipeline's own H1 statistic). A large spread means the *choice*
  matters, not that one number is right and the other wrong — that
  determination needs a reviewing hydrologist looking at which station pool
  is actually climatologically appropriate for each specific dam, exactly
  what `expert_review_checklist.md`'s region-composition section now asks
  for.
- **No obvious single driver identified yet.** The top-spread facilities
  span multiple states/regions (CA, ND, others) — this wasn't run down to a
  root cause (e.g. sparse-station areas, coastal/orographic transitions,
  small drainage areas) in this pass; that's a natural next analysis if
  useful, not done here to avoid scope creep on what was asked.
- **Every one of the 292 completed facilities now has both a `circular` and
  a `cluster` result on file** — `outputs/batch/all_facilities_DDF.csv` in
  this worktree (cluster) and the main clone's
  `all_facilities_DDF_full308.csv` (circular) — so any facility's specific
  comparison can be pulled directly rather than re-run.
- **This still isn't the full H&W (1997) picture.** Subjective and
  objective partitioning remain unimplemented (see
  `ASSUMPTIONS_AND_LIMITATIONS.md` §B5) — this result is "circular vs. one
  alternative," not "circular vs. every alternative the reviewer raised."

## What this means for the fleet-default decision

`docs/REGION_METHOD_SENSITIVITY.md`'s Part A Phase 4 ("promote `cluster` to
the fleet default, if Reclamation signs off") was written before this
fleet-scale result existed. This result doesn't resolve that decision — it
sharpens the stakes of it: with 62.8% of the fleet showing a >15% tail
spread between methods, *not* picking a reviewed default (or flagging
per-facility which method's result is being relied on) means a large
fraction of BOR dam screenings are silently sitting on an unreviewed
methodological choice. That's a call for the project owner / Reclamation,
not something resolved by this batch run.
