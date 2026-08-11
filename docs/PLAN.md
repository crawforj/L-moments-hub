# Plan — Regional Precipitation Frequency Analysis for Como Dam, Montana

**Method:** Regional Frequency Analysis (RFA) based on L-moments, per
*Hosking & Wallis (1997), "Regional Frequency Analysis: An Approach Based on
L-Moments," Cambridge University Press.*
**Language:** R. **Target site:** Como Dam / Lake Como, Bitterroot Valley,
Ravalli County, western Montana (≈46.06° N, −114.23° W — parameterized).

---

## 1. Context — why this analysis

Como Dam requires precipitation-frequency estimates out to very rare events
(up to the **10,000-year** return period, annual exceedance probability
AEP = 0.0001) to support dam-safety / spillway hydrology. A single gauge has
far too short a record to estimate a 1-in-10,000-year depth directly. The
Hosking & Wallis L-moment **regional** approach pools many stations from a
climatologically **homogeneous region** to "trade space for time," extending
the effective record length and stabilizing the extreme tail. L-moments are
used throughout because they are more robust to outliers and less biased for
small samples than conventional product moments.

**Goal:** a portable, documented R pipeline that produces 24-hour and 72-hour
precipitation-frequency estimates at Como Dam to AEP 1e-4, plus all requested
diagnostic deliverables, and that can be re-pointed at any other basin by
editing one config file.

---

## 2. The Hosking & Wallis (1997) procedure (four steps)

1. **Screening — discordancy `Di`.** Flag sites whose sample L-moment ratios
   are grossly discordant from the group (H&W §3.2.3). Remove and log them.
2. **Homogeneity — heterogeneity `H`.** Compare the observed dispersion of
   at-site L-moment ratios to that expected from a homogeneous region simulated
   with a fitted **kappa** distribution (H&W §4.3). Decision rule:
   `H < 1` = acceptably homogeneous, `1 ≤ H < 2` = possibly heterogeneous
   (review), `H ≥ 2` = heterogeneous (revise the region). Iterate.
3. **Distribution choice.** Use the **L-moment ratio diagram** (L-kurtosis vs
   L-skewness) and the **Z-statistic goodness-of-fit** `Z^DIST` (H&W §5.2.3);
   `|Z^DIST| ≤ 1.64` is an acceptable fit. Candidates: GLO, GEV, GNO
   (generalized normal / lognormal), PE3 (Pearson III), GPA. Kappa/Wakeby
   considered for tail robustness at the 10,000-yr extrapolation.
4. **Estimation — index-flood.** Assume all sites share one regional growth
   curve `q(F)` apart from a site scale factor (the index flood, the at-site
   mean). Quantiles: `Q_i(F) = mu_i · q(F)`. Estimate `q(F)` from regional
   average L-moments; assess accuracy by Monte Carlo simulation (H&W §6, §9).

---

## 3. R implementation stack

| Purpose | Package / function |
|---|---|
| L-moments, distributions, ratio diagram | **`lmom`** — `samlmu`, `lmrd`, `quagev`, `cdfgev`, `pelgev`, … |
| RFA engine (the book, in code) | **`lmomRFA`** — `as.regdata`/`regsamlmu`, `regtst` (Di, H, Z), `regfit`, `regquant`, `regsimh`, `regsimq` |
| Data acquisition (GHCN-Daily) | direct NCEI download of `ghcnd-stations.txt`, `ghcnd-inventory.txt`, `*.dly`; `FedData::get_ghcn_daily` as an alternative. (`rnoaa` is archived — not relied upon.) |
| Mapping / spatial | `sf`, `ggplot2`, `rnaturalearth`(+`hires` data), `maps`, `ggspatial` (scale bar + north arrow); `elevatr`/`terra` optional for elevation |
| Config & reproducibility | `yaml` (config), `renv` (pinned versions), fixed RNG seeds |

`lmomRFA` is Hosking's own implementation of the 1997 book, so the pipeline
follows the reference method rather than re-deriving it.

---

## 4. Data handling

- **Element:** `PRCP` from GHCN-Daily.
- **Durations:** 24-hr → annual-maximum **1-day** total; 72-hr →
  annual-maximum running **3-day** total.
- **Seasonal constraint (configurable):** annual maxima can be restricted to a
  month window via `config$season = {start_month, end_month}`, **default
  April–July** (spring snowmelt / rain-on-snow flood season for the Bitterroot).
  Set the window to Jan–Dec to use the full calendar year. Seasonal maxima are
  extracted per water/calendar year within the window before L-moment
  computation; the completeness gate is applied to the in-season days only.
- **Fixed-interval correction (WMO/Hershfield):** multiply single-obs-per-day
  annual maxima by constraint factors to approximate true clock-hour depths —
  defaults ≈ **1.13** (1-day→24-hr) and ≈ **1.02–1.04** (3-day→72-hr), both
  configurable constants.
- **Candidate stations:** within a configurable search radius of Como Dam
  (default ~150 km) and an elevation/climate band; minimum record length
  (default ≥ 20 yr) and annual completeness threshold (e.g., ≤ ~10% missing in
  the wet season). Every exclusion is logged with a reason.
- **Auto-download + fallback:** the acquisition module downloads from NCEI;
  if the network is unavailable or `config$use_local = TRUE`, it reads a
  user-supplied CSV (`station_id, year, value`) from `data/external/`, so the
  pipeline is fully runnable offline.

---

## 5. Repository layout

```
L-moments-como-/
  README.md
  renv.lock                # pinned package versions
  config/
    como.yml               # Como site/basin knobs (portability boundary)
    golden.yml             # golden (known-answer) validation case
  R/
    00_setup.R             # packages, source functions, read config
    01_data_acquisition.R  # GHCN-Daily download/parse + CSV fallback -> AMS
    02_lmoments.R          # at-site sample L-moments -> regdata object
    03_screening.R         # discordancy Di; drop + log discordant sites
    04_homogeneity.R       # heterogeneity H; iterate region definition
    05_distribution.R      # L-moment ratio diagram + Z-statistic -> pick dist
    06_estimation.R        # regfit + regquant to AEP 1e-4; at-site quantiles
    07_uncertainty.R       # regsimq Monte-Carlo error bounds
    08_mapping.R           # region map: used vs removed stations + boundary
    09_plots.R             # ratio diagram, growth curve, DDF curves
    10_report_tables.R     # write deliverable CSVs + station lists
    11_audit_report.R      # render the reviewer report (Quarto/RMarkdown)
    checks.R               # embedded invariant assertions (halt on failure)
    functions.R            # site-agnostic reusable helpers (portable core)
  data/{raw,processed,external}/
  golden/                  # frozen golden inputs + expected reference outputs
  tests/                   # testthat unit + regression tests
  outputs/
    {figures,tables}/
    provenance/            # per-run manifest: git hash, pkg versions, data vintage
    report.html            # rendered human-review / audit report
  run_analysis.R           # master: runs 00..11 for a given config
  run_golden.R             # runs the golden case beside Como (same code paths)
  report.qmd               # Quarto audit report source
  docs/
    users_guide.md
    audit_guide.md         # how to review & audit a run; sign-off checklist
    PLAN.md                # this file
```

---

## 6. Step-by-step build

**01 — Acquisition.** `get_station_inventory()` filters the GHCN inventory to
`PRCP` within the site bounding box + min years; `download_station()` parses
`.dly`/CSV to a daily series; `build_ams(daily, duration_days, corr_factor,
season)` computes annual maxima of running d-day sums **within the configured
seasonal window (default April–July)** with a per-year completeness gate and
applies the correction factor. Fallback path reads `data/external/`.

**02 — L-moments.** `samlmu()` per station → `n, mean (l1), t (L-CV),
t3 (L-skew), t4 (L-kurt)`; assemble a `regdata` object per duration.

**03 — Screening (Di).** `regtst()` → discordancy; flag `Di ≥` the
sites-count-dependent critical value (H&W Table 3.1, provided by `lmomRFA`).
Removed sites recorded → **deliverable: stations removed** (with reason:
short record / low completeness / discordant / dropped in homogeneity revision).

**04 — Homogeneity (H).** `regtst()` computes `H1/H2/H3` from 500 kappa
simulations (seeded). Apply the `<1 / <2 / ≥2` rule; iterate region membership
until acceptably homogeneous. Final membership → **deliverable: stations used**.

**05 — Distribution selection.** `lmrd()` L-moment ratio diagram plotting each
site and the regional average against theoretical GLO/GEV/GNO/PE3/GPA curves →
**deliverable: plot of station data relative to distributions**. Pick the
distribution by minimum `|Z^DIST|` (≤ 1.64), with explicit discussion of tail
behavior for the 10,000-yr extrapolation (GEV/GNO/PE3 vs Kappa/Wakeby).

**06 — Estimation.** `regfit()` → regional growth-curve parameters;
`regquant()` over an `F`-grid including `F = 1 − 1/T` for
`T ∈ {2,5,10,25,50,100,200,500,1000,2000,5000,10000}`. At Como Dam (ungauged
at the dam itself) the **index flood** is estimated by a configurable transfer
method (default: regression of at-site mean AMS on elevation / mean-annual
precipitation, or nearest-analog ratio) — assumption documented. Output:
depth-duration-frequency (DDF) table, 24-hr & 72-hr, to AEP 1e-4.

**07 — Uncertainty.** `regsimq()` Monte Carlo (≈500–1000 sims, seeded) → RMSE
and 90% error bounds on the growth curve and quantiles, emphasized at the
extreme tail. **Deliverable: uncertainty bounds table.**

**08 — Mapping.** `sf`/`ggplot2` map of Montana + county context with stations
symbolized as **used vs removed**, the Como Dam marker, and the region boundary
(radius circle and/or convex hull), scale bar + north arrow →
**deliverable: map of the region** (PNG + PDF).

**09 — Plots.** (a) L-moment ratio diagram (step 05); (b) regional growth curve
with candidate distributions overlaid and at-site empirical points (Cunnane
plotting positions) on a Gumbel/AEP axis; (c) final DDF curves (depth vs return
period) for both durations with the uncertainty band.

**10 — Tables / lists.** `stations_used.csv`, `stations_removed.csv` (reasoned),
`regional_Lmoments.csv`, `gof_Zstatistic.csv`, `growth_curve.csv`,
`quantiles_DDF.csv`, `uncertainty_bounds.csv`.

---

## 7. Portability

Every basin-specific value lives in `config/como.yml`: site name, lat/lon,
search radius, elevation band, min years, completeness threshold, durations
(days) + correction factors, **seasonal window (default April–July)**,
candidate distributions, return periods, simulation counts, RNG seeds, and
index-flood transfer method. **To run another basin:** copy the YAML, edit
coordinates/parameters, run `run_analysis.R`. All functions in `functions.R`
are site-agnostic; no hard-coded Como values.

---

## 8. Documentation

- **Inline:** roxygen-style headers on every function (purpose, args, return);
  each numbered script opens with its objective, inputs, outputs, and the
  relevant Hosking & Wallis (1997) section reference.
- **`docs/users_guide.md`:** install (`renv::restore()`), configure the YAML,
  run the pipeline, interpret each output, swap basins, and read the caveats.

---

## 9. Verification, human review & audit

The results must be **reproducible, traceable, and defensible** to an
independent reviewer (dam-safety context). Five layers:

### 9.1 Reproducibility & provenance
- `renv` lock + fixed RNG seeds → bit-for-bit repeatable runs.
- Every run writes `outputs/provenance/run_manifest.json`: timestamp, git commit
  hash, `sessionInfo()` (R + package versions), the **exact config used** (copied
  verbatim), GHCN data vintage / download date, and input station inventory with
  record spans. An auditor can reproduce any figure from the manifest alone.

### 9.2 Automated invariant checks (`checks.R`)
Assertions embedded in the pipeline that **halt with a clear message** if an
invariant breaks, so a silent error can't reach the output: quantiles monotone
increasing in `T`; growth curve increasing in `F`; `H` decreasing after
discordant-site removal; `|Z^DIST|` reported for every candidate; no `NA`
leakage into L-moments; station counts reconcile (candidates = used + removed).
Passed checks are logged as an audit trail.

### 9.3 Golden-dataset validation (run **side-by-side** with Como)
A known-answer case is run through the **identical code paths** as Como
(`run_golden.R`, same functions, a `golden.yml` config) so the reviewer sees the
same machinery produce a verifiable result and the real result:
- **(a) Published benchmark** — Hosking & Wallis worked examples bundled in
  `lmomRFA` (e.g., `Cascades`, `appalach`, `Maxwind`). The pipeline must
  reproduce the book's published `Di`, `H`, `Z`, and quantiles within tolerance.
  Validates that the method is wired correctly.
- **(b) Synthetic known-truth** — simulate stations from a **known** regional
  distribution (known growth curve, known index floods, fixed seed), so the
  *true* quantiles to AEP 1e-4 are known exactly; confirm the pipeline recovers
  them within Monte-Carlo tolerance. Validates the whole chain end-to-end,
  including estimation and the 10,000-yr extrapolation.
- Expected reference outputs are **frozen in `golden/`** and compared on every
  run; explicit numeric tolerances are defined, and drift fails the test.

### 9.4 Human-review audit report (`report.qmd` → `outputs/report.html`)
A single rendered report that walks a reviewer through each H&W step with the
diagnostics inline: candidate stations and the map, the `Di`/`H` decision log
(which sites were dropped and **why**, at each iteration), the L-moment ratio
diagram and `Z`-statistic table with the selection rationale, the growth curve
and DDF tables with uncertainty bands, the golden-case results beside Como, and
the provenance manifest. Every table ships with a **data dictionary**; every
figure/table is captioned with the script/function and H&W section that produced
it. `docs/audit_guide.md` gives a reviewer sign-off checklist.

### 9.5 Tests & cross-checks
- `tests/` (`testthat`): unit tests for each function + a **regression test**
  asserting golden outputs match the frozen reference within tolerance (CI-ready).
- Independent recomputation of key L-moments two ways (via `lmom` and a
  from-scratch helper) as a cross-check.
- **Offline dry-run** on the bundled fallback CSV proves the pipeline runs with
  no network.
- Optional cross-check of Como results against published NOAA Atlas 14 / Atlas 2
  estimates for the region, where available.

---

## 10. Caveats (documented in outputs and the user's guide)

- Estimating a 10,000-yr depth extrapolates far beyond the observed record;
  regional pooling extends effective length but the extreme tail remains
  model-dependent — hence the reported uncertainty bounds and a distribution
  sensitivity note.
- GHCN daily totals are fixed calendar-day; the constraint-correction factors
  only approximate true 24/72-hr clock depths.
- The Como Dam index flood is transferred from regional gauges (the dam site is
  ungauged), which introduces additional uncertainty.

---

## 11. Deliverables checklist (maps to the request)

- [x] Homogeneous region defined (Di screening + H test, iterated)
- [x] Map of the region (stations used/removed + boundary)
- [x] List of meteorology stations **used**
- [x] List of stations **removed** (with reasons)
- [x] Plot of station data vs candidate distributions (L-moment ratio diagram +
      growth-curve fit) illustrating distribution selection
- [x] Precipitation-frequency results to the **10,000-year** return period
      (AEP 1e-4), for **24-hr and 72-hr** durations, with uncertainty bounds
- [x] Portable, inline-commented R code + user's guide
- [x] **Auditability:** provenance manifest, embedded invariant checks, decision
      log, rendered human-review report, data dictionaries, reviewer sign-off guide
- [x] **Golden dataset** (published benchmark + synthetic known-truth) run
      side-by-side with Como and regression-tested to prove output is
      error-free and defensible
