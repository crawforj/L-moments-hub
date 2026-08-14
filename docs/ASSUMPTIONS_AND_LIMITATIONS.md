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
2. **No ground elevation.** The NID gives structure heights, not site MSL
   elevation, so `elevation_m` is blank fleet-wide. The fleet therefore uses
   `index_flood.method: "nearest"` (no elevation dependence). The
   elevation-regression transfer is only meaningful where a real site elevation
   is supplied (e.g. Como).
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
   **Fleet-wide caveat, found 2026-08-14, not yet resolved:** `cluster` uses
   site elevation as a clustering attribute and silently falls back to
   `circular` (logged, not errored) whenever a facility's config has no
   `elevation_m`. As of this writing, **0/308 facilities in
   `config/facilities_BOR.csv` and 0/73,303 in `config/nid_manifest.csv`**
   have real elevation data (both are the literal string `NA` throughout) —
   `region.method: cluster` is therefore currently a **complete no-op for the
   entire fleet**; it only ran for real at Como because that config's
   elevation was set by hand. `enrich_elevations()` (`R/functions.R`) already
   exists to fix this (a DEM lookup) but is off by default
   (`LMC_ENRICH_ELEV=1`) and has not been run against either manifest.
   Anything told to Reclamation about fleet-wide cluster-region availability
   must account for this until it's resolved.
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

## D. What the uncertainty bounds do and do not include

12. The Monte-Carlo 90% bounds capture **sampling/parameter uncertainty of the
    fitted regional model** only. They do **not** include: distribution-selection
    uncertainty (use the **tail-sensitivity** table), regionalization error
    (wrong/heterogeneous region), input-data error (bad coordinate, gauge
    undercatch), the fixed-interval factor's error, or nonstationarity. True
    uncertainty is **wider** than the reported band.

## E. Scope / engineering-use limitations

13. **Not a substitute for NOAA Atlas 14** where Atlas 14 exists, nor for a
    site-specific study. Atlas 14 is the U.S. authoritative point-precipitation-
    frequency standard; this tool's estimates should be **cross-checked against
    Atlas 14** (see [`VALIDATION.md`](VALIDATION.md) §"recommended expert step"
    and `compare_atlas14.R`).
14. **No PMP.** This is frequency analysis, not Probable Maximum Precipitation.
15. **Season default is full-year.** Correct for annual-maximum dam-safety work;
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
