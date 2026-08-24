# Assumptions & limitations

A single authoritative register of what this analysis assumes and what it does
**not** account for. Read it before trusting any number. Nothing here is a
defect to hide — it is the boundary of valid use, stated plainly for the
reviewing flood hydrologist. Companion docs: [`METHODS.md`](METHODS.md),
[`VALIDATION.md`](VALIDATION.md), [`../DATA_SOURCES.md`](../DATA_SOURCES.md).

**Bottom line:** this is a **research / triage screen**, not an engineering
product. Its purpose is to produce first-pass regional DDF estimates and to flag
which dams and regions need an expert's attention. No value here is valid for
design or safety decisions until an expert has verified the inputs and reviewed
the region (see [`expert_review_checklist.md`](expert_review_checklist.md)).

---

## A. Input-data assumptions (the largest source of risk)

1. **Dam inventory is unverified.** Coordinates, names, and ownership come from a
   third-party ~2013 mirror of the NID (see `DATA_SOURCES.md`). A wrong
   coordinate silently analyses the wrong location. **Verify each dam's
   coordinates against an authoritative source before use.**
2. **No ground elevation in run 1.** The NID gives structure heights, not
   site MSL elevation, so run 1's manifest had `elevation_m` blank
   fleet-wide. The config nominally requests `index_flood.method:
   "regression"`, but `estimate_index_flood()` (`R/functions.R`) **silently
   degrades to the plain regional mean of the donor gauges' at-site means**
   whenever the site elevation is not finite — so that degraded transfer is
   what every run-1 facility actually used. (An earlier version of this
   paragraph said the fleet uses `"nearest"`; that was wrong — corrected
   2026-08-24 after verifying against the code. Measured on identical
   regions nationally, regression-vs-regional-mean moves depths by a median
   of only ~1.4%, but p90 ~8% and worst cases far more.) Run 2's manifest
   carries DEM-derived elevations (elevatr z=10) and gets the real
   regression; the two runs therefore differ in index-flood method as well
   as region method — see `docs/CLUSTER_FLEET_RESULTS.md` for why that
   confound matters.
3. **Weather data is unverified GHCN-Daily.** QFLAG-failed observations are
   removed, but station siting, gaps, undercatch (especially snow), and station
   moves are not individually reviewed. Gauge undercatch tends to bias depths
   **low**.
4. **Some dams cannot be analysed.** Where fewer than 5 qualifying gauges fall in
   the search radius/elevation band with sufficient record, the region cannot
   form and the dam is reported **failed** (not forced). In the first NID tranche
   this was ~15% of dams — expect a meaningful failed fraction in sparse-gauge
   regions; those dams need a manually widened region or a different data source.

## B. Method assumptions (standard RFA / index-flood)

5. **Regional homogeneity.** The index-flood method assumes all gauges in a
   region share one dimensionless frequency distribution. This is *tested*
   (heterogeneity `H`) and flagged when violated (`H₁ ≥ 2`), but a region passing
   the test is still an approximation, and automated region formation can cross a
   divide, rain-shadow, or climate boundary. **Region appropriateness must be
   eyeballed per facility.**
   Two region-*building* methods are available (`region.method` in
   `config/<id>.yml`): the default `circular` (geographic-radius + elevation
   band — H&W 1997's "geographical convenience" approach, the one susceptible
   to the divide/rain-shadow risk above) and `cluster` (H&W 1997 sec. 9.2.3,
   Ward's-method clustering on standardized site attributes via `lmomRFA`,
   added in response to Reclamation reviewer feedback calling region
   construction "one of the most influential points in the L-moments
   analysis" — see `R/region_methods.R`). Neither is authoritative; run
   `compare_regions.R config/<id>.yml circular,cluster` per facility to see how
   much the choice moves the tail estimate. **Verified 2026-08-14 at Como**
   (see `docs/REGION_METHOD_SENSITIVITY.md` for the full table): the two
   methods move the depth estimate **18-22% at T=10,000 yr** (both durations),
   shrinking to **3.7-10.5% by T=100 yr** and under 10% below T=25 yr — large
   enough at the design-relevant tail that the choice is a documented,
   per-facility reviewed decision, not a cosmetic option. H&W (1997) also
   describes **subjective** (covariate, e.g. mean-annual-precipitation,
   partitioning) and **objective** (L-moment-ratio threshold) partitioning;
   both are **not yet implemented** — deferred pending Reclamation-set
   thresholds/weights this project should not guess at (a climatological
   judgment call, not a software one).
   **Fleet-wide caveat, found 2026-08-14, partially resolved same day:**
   `cluster` uses site elevation as a clustering attribute and silently
   falls back to `circular` (logged, not errored) whenever a facility's
   config has no `elevation_m`. As first found, **0/308 facilities in
   `config/facilities_BOR.csv`, 0/8 in `config/pilot.csv`, and 0/73,303 in
   `config/nid_manifest.csv`** had real elevation data (all the literal
   string `NA`) — `region.method: cluster` was therefore a **complete no-op
   for the entire fleet**; it only ran for real at Como because that
   config's elevation was set by hand.

   **Fixed the same day for the BOR-308 and pilot-8 manifests only.**
   `enrich_elevations()` (`R/functions.R`, DEM lookup via
   `elevatr::get_elev_point(src = "aws")`, AWS Terrain Tiles, no auth) was
   run for real and its result written back durably to the CSVs (new script:
   `enrich_manifest_elevations.R` at the repo root — `enrich_elevations()`
   was already wired into `run_batch.R`'s `gen_configs_from_manifest()`
   behind `LMC_ENRICH_ELEV=1`, but that only enriched the manifest in
   memory for one run and never persisted it, so every run re-did the same
   DEM lookups; this closes that gap for good). Result: **308/308 (100%) of
   `config/facilities_BOR.csv` and 8/8 (100%) of `config/pilot.csv`** now
   have a real DEM-derived `elevation_m`, in ~6 s and ~1 s respectively (AWS
   Terrain Tiles was fast and reliable both times — no timeouts, no
   retries needed). Spot-checked against known crest/reservoir elevations:
   Hoover 421-425 m (real crest ~376 m), Grand Coulee 413-446 m (real
   reservoir full pool ~393 m), Shasta 301-332 m (real crest ~328 m) —
   all in the right ballpark for a coordinate-based DEM point lookup near,
   not exactly on, the dam structure (a few tens of metres off is expected;
   values are never negative, zero, or off by orders of magnitude). Note:
   re-running the enrichment produces slightly different values run to run
   (Hoover: 421 m alone vs. 425 m as part of the 308-row batch) — `elevatr`
   appears to auto-select its DEM zoom/tile resolution from the bounding box
   of all points in a single call, so a wider-spanning batch samples at
   coarser resolution. This is noise at the few-tens-of-metres level, not a
   correctness bug, but it means elevation values (and therefore `cluster`
   region composition) are not perfectly deterministic across separate
   enrichment runs.

   `config/nid_manifest.csv` (73,303 rows) is **explicitly out of scope**
   for this fix — still 0/73,303, still a complete no-op there. Enriching
   the full NID fleet is a much larger DEM-lookup cost/scope decision left
   to the project owner. Anything told to Reclamation about fleet-wide
   cluster-region availability must state clearly: BOR-308 and pilot-8 now
   have real elevation and can genuinely use `cluster`; the full
   73k-manifest fleet still cannot.

   With elevation now real, the Hoover Dam (`NV10122`) region comparison in
   `docs/REGION_METHOD_SENSITIVITY.md` was re-run and **no longer falls
   back** — `cluster` builds a real, different region (7 stations vs.
   `circular`'s 27-29) with a real spread (27-48% across return periods, a
   different shape than Como's tail-growing 18-22% pattern but confirming
   the reviewer's concern generalizes beyond one basin).

   **Fleet-scale result, 2026-08-14 (`docs/CLUSTER_FLEET_RESULTS.md`):**
   `cluster` was run for real across all 308 `facilities_BOR.csv` dams
   (292/308 succeeded; 16 failed for reasons unrelated to region method —
   8 transient GHCN download errors, 8 genuine too-few-station cases,
   6 of those 8 clustered in Oklahoma, worth a separate look). Of the 292
   successes, **215 genuinely engaged `cluster`**; the other **74 silently
   fell back to `circular`** internally (too few stations in the 600 km
   prefilter pool, undersized assigned cluster, etc. — same graceful-degrade
   behavior as the single-facility case above, logged not errored).
   Comparing depths against the pre-existing circular-308 baseline
   (`C:\dev\L-moments-hub\outputs\batch\all_facilities_DDF_full308.csv`)
   found a **second, unrelated confound**: that baseline was run before the
   elevation fix (still `NA` fleet-wide in the main clone today), so
   `estimate_index_flood()`'s default `"regression"` method silently
   degraded to a plain regional mean for every baseline facility, whereas
   every facility in the new run (region method aside) now gets a real
   elevation-regression index flood. The 74 internal-fallback facilities —
   identical region-building to the baseline by construction — isolate this
   confound's own magnitude: median 26.4% / mean 27.9% spread at T=10,000 yr
   from the elevation fix **alone**, nothing to do with region method. The
   215 genuine-`cluster` facilities show median 15.3% / mean 20.0% at
   T=10,000 yr against the same stale baseline — smaller than the confound's
   own noise floor, so that comparison could not cleanly separate the two
   effects.
   **RESOLVED same day (2026-08-14 evening): the circular baseline was
   re-run fleet-wide with the same elevation-enriched manifest** (297/308
   ok), eliminating the confound rather than merely disclosing it. Proof of
   cleanliness: the internal-fallback control group's spread vs. the fresh
   baseline is now **exactly 0.0% across all 296 combinations** (was median
   26.4% against the stale one). The clean, region-method-only fleet result
   (221 genuine-cluster facilities, 428 facility×duration combinations):
   **median 15.1% / mean 20.0% spread at T=10,000 yr, with 50.2% of
   combinations exceeding 15%** and a tail reaching 94.6% (Bradbury). The
   reviewer's "one of the most influential points" is confirmed at fleet
   scale on clean data. See `docs/CLUSTER_FLEET_RESULTS.md`'s "FINAL, CLEAN
   RESULT" section. Patterns re-derived from clean data (same section):
   the elevation gradient **did not survive** (it was largely the confound
   itself); the state pattern (WA/UT/OR highest, NE lowest) and the
   small-cluster-region pattern (<18 stations: mean 26.7% vs. 16.3% for
   >28) both survive — small-region facilities deserve the closest
   region-composition review.
6. **The regional distribution is the right family.** One distribution is chosen
   by min `|Z|`. When several fit comparably, or none fits well (`|Z| > 1.645`,
   flagged `needs_review`), the far tail is uncertain — see the tail-sensitivity
   table.
7. **Point frequencies remain the primary output; an ARF is applied only where
   a drainage area is known.** `depth_mm` is always the **point** precipitation
   depth. Where a facility has a configured `site.drainage_area_mi2` (see
   `enrich_drainage_area.R` — covers ~86% of `facilities_BOR.csv`, ~77% of the
   full `nid_manifest.csv`), an **additional** `depth_areal_mm` column is
   computed via a general national-average Areal Reduction Factor curve
   (Leclerc & Schaake 1972 — see `R/arf.R`), never replacing the point depth.
   This is a documented DEFAULT, not a region-specific or Reclamation-reviewed
   curve — treat `depth_areal_mm` as provisional until an expert confirms the
   method is appropriate for the region, or supplies a preferred curve to swap
   in via `arf.method` (`R/arf.R`). Facilities with no drainage area on file
   report `depth_areal_mm = NA` (point-only, as before).
8. **Fixed-interval adjustment is a constant factor.** Calendar-day maxima are
   scaled to true-duration depths by fixed factors (1.13 at 24 h, 1.03 at 72 h;
   Hershfield/WMO). This is a standard approximation, not a site-specific
   correction.
9. **Stationarity.** The record is treated as identically distributed over time —
   no trend or climate-change nonstationarity is modelled.
10. **Independent annual maxima.** Standard AMS assumption; the largest storm per
    year per site is taken.

## C. Extrapolation

11. **10,000-year estimates are deep extrapolation.** Gauge records are typically
    decades long; the 10⁴-year (AEP 1e-4) quantile is far beyond the data and
    depends heavily on the distribution's tail. Treat rare-event depths as
    model-dependent estimates with wide, partly unquantified uncertainty. For
    context, compare against PMP-based methods (HMR / site-specific), which are
    the usual basis for extreme dam-safety hydrology.
12. **Durations are fitted independently, so the tail can cross.** Each duration
    gets its own regional L-moments, distribution choice and growth curve, with
    no cross-duration constraint — so in the far tail a fitted 72-h depth can
    fall **below** the 24-h depth, which is physically impossible (the 72-h
    window contains the 24-h one). Measured on the NID fleet: ~15% of facilities,
    **only at T ≥ 200** (median deficit 7.2%, max 44%); 24-h products and all
    estimates at T ≤ 100 are unaffected. Affected values carry a hard
    `dur72_lt_dur24` QC flag; do not use a flagged 72-h depth at T ≥ 200.
    Measurement, cause, field practice (NOAA Atlas 14/15 correct this post hoc)
    and the options are in
    [`analysis/cross_duration_consistency.md`](analysis/cross_duration_consistency.md).

## D. What the uncertainty bounds do and do not include

13. The Monte-Carlo 90% bounds capture **sampling/parameter uncertainty of the
    fitted regional model** only. They do **not** include: distribution-selection
    uncertainty (use the **tail-sensitivity** table), regionalization error
    (wrong/heterogeneous region), input-data error (bad coordinate, gauge
    undercatch), the fixed-interval factor's error, or nonstationarity. True
    uncertainty is **wider** than the reported band.

## E. Scope / engineering-use limitations

14. **Not a substitute for NOAA Atlas 14** where Atlas 14 exists, nor for a
    site-specific study. Atlas 14 is the U.S. authoritative point-precipitation-
    frequency standard; this tool's estimates should be **cross-checked against
    Atlas 14** (see [`VALIDATION.md`](VALIDATION.md) §"recommended expert step"
    and `compare_atlas14.R`).
15. **No PMP.** This is frequency analysis, not Probable Maximum Precipitation.
16. **Season default is full-year.** Correct for annual-maximum dam-safety work;
    a season-restricted run biases estimates low and is only for season-specific
    studies.

## F. What IS solid

Stated for balance: the L-moment computations are Hosking's reference
implementation (`lmomRFA`); the pipeline reproduces the Hosking & Wallis
textbook example findings; the index-flood scaling matches an independent
hand-calculation to 0.000%; runs are seeded and reproducible; and every
station add/drop and distribution decision is logged. The *method* is
implemented correctly and transparently — the caveats above are about **inputs,
model assumptions, and extrapolation**, which is where regional frequency
analysis always requires expert judgement. See [`VALIDATION.md`](VALIDATION.md).
