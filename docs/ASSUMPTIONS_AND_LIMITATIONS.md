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

1. **Dam inventory started unverified, now partially refreshed.** Coordinates,
   names, and ownership originally came from a third-party ~2013 mirror of the
   NID (see `DATA_SOURCES.md`). `refresh_nid_live.R` (2026-08-11) refreshed
   coordinates/storage/drainage-area for ~90% of facilities from the live,
   current NID — check `coord_drift_km` in the manifest for a given facility;
   a wrong coordinate silently analyses the wrong location. Ownership is
   still unverified either way. **Verify against an authoritative source
   before use regardless — refreshed doesn't mean expert-confirmed.**
2. **No ground elevation, from any source.** Neither the old mirror nor the
   live NID gives site MSL elevation (only structure heights), so
   `elevation_m` is blank fleet-wide. The fleet therefore uses
   `index_flood.method: "nearest"` (no elevation dependence). The
   elevation-regression transfer is only meaningful where a real site elevation
   is supplied (e.g. Como).
3. **Weather data is unverified GHCN-Daily.** QFLAG-failed observations are
   removed, but station siting, gaps, undercatch (especially snow), and station
   moves are not individually reviewed. Gauge undercatch tends to bias depths
   **low**.
4. **`data.use_local_fallback` must be `false`.** Left `true`, a GHCN download
   failure silently substitutes a synthetic dataset and still reports the
   facility as **successful** — no visible flag in the batch output or ledger.
   This happened for real (~200 facilities across two incidents, 2026-08-11,
   found and cleaned up) before the default was changed. See
   `docs/batch_runs_guide.md`.
5. **Some dams cannot be analysed — but check why before assuming it's data
   scarcity.** Where fewer than 5 qualifying gauges fall in the search
   radius/elevation band with sufficient record, the region cannot form and
   the dam is reported **failed** (not forced). The first NID tranches showed
   ~15-65% failure rates that turned out to be **mostly a config bug**
   (`elevation_band_m` inherited unchanged from Como's Montana-specific
   `[600,2600]` range, zeroing the candidate pool for low-elevation regions —
   confirmed 87.5% of one round's failures) rather than genuine sparse-gauge
   regions. Fixed by widening the band (`[-100,6200]`) fleet-wide; a residual
   failed fraction is expected and legitimate in truly sparse-gauge regions,
   but don't assume every failure is one without checking the actual reason
   in `batch_status.csv`.

## B. Method assumptions (standard RFA / index-flood)

5. **Regional homogeneity.** The index-flood method assumes all gauges in a
   region share one dimensionless frequency distribution. This is *tested*
   (heterogeneity `H`) and flagged when violated (`H₁ ≥ 2`), but a region passing
   the test is still an approximation, and automated region formation (radius +
   elevation band) can cross a divide, rain-shadow, or climate boundary. **Region
   appropriateness must be eyeballed per facility.**
6. **The regional distribution is the right family.** One distribution is chosen
   by min `|Z|`. When several fit comparably, or none fits well (`|Z| > 1.645`,
   flagged `needs_review`), the far tail is uncertain — see the tail-sensitivity
   table.
7. **Point frequencies, not areal.** Outputs are **point** precipitation depths
   at a gauge/site. They include **no areal reduction factor (ARF)**; converting
   to basin-average design rainfall requires an ARF the pipeline does not apply.
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
