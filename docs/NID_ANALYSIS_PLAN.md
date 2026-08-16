# NID fleet output — analysis plan

**Date:** 2026-08-16. **Status: plan.** The ~73,303-dam NID
precipitation-frequency batch is ~42% complete (projected finish
~2026-08-22/23). This plan defines what to *learn* from the output — the
analyses, their inputs, artifacts, and dependencies — so work starts the
moment the data is ready (several pieces sooner). The companion
**`NID_QAQC_PLAN.md` is a hard prerequisite: no analysis below runs on
un-QC'd data, and every analysis artifact carries its own verification
step defined there.**

## Publication-safety boundary (governs every artifact)

This repo is **public**. The same reasoning that keeps the companion BOR
screening repo private applies to any output that ranks or singles out
dams by vulnerability:

- **Public-safe**: national/state aggregate maps, distribution-family
  geography, method-diagnostic atlases, gauge-desert maps, Atlas 14
  comparison statistics, methodology findings.
- **Never public**: per-dam ranked lists or filterable tables that combine
  a low capacity/hazard margin with an identified dam. Any per-dam
  screening product built from this data lives in the private BOR repo
  or an equivalent private space, full stop.
- Every analysis below states which side of the line its artifact falls on.

## Phase A — runs now, on partial data (refresh at completion)

### A1. The failure atlas / gauge-desert map *(public-safe)*
- **Question**: where does the method fail for lack of stations, and what
  does that say about national monitoring gaps?
- **Inputs**: `completed_ids.csv` (ok=FALSE rows) + `batch_diagnostics.csv`
  (n_stations, H1) + facility coordinates.
- **Method**: map failure density and station-count quantiles; classify
  failure reasons; overlay terrain/climate regions. The BOR run found
  failures cluster (e.g., 6-of-8 in Oklahoma); test whether that pattern
  is real nationally.
- **Artifact**: `docs/analysis/failure_atlas.md` + figures; a
  candidate-monitoring-gap list (aggregate by county/HUC, not by dam).

### A2. Tail-behavior geography *(public-safe)*
- **Question**: where does extreme rainfall have heavy tails?
- **Inputs**: `batch_diagnostics.csv` (chosen_dist, |Z|, z_margin,
  tail_spread_pct), `all_facilities_DDF.csv` (depth ratios, e.g.
  Q10000/Q100 as an empirical tail index).
- **Method**: map distribution-family choice and the Q10000/Q100 ratio;
  correlate with climate regions. Flag the *instability* layer separately
  (small z_margin = family choice is a coin-flip; the BOR work showed
  PE3/GLO facilities carry the largest method sensitivity).
- **Artifact**: `docs/analysis/tail_geography.md` + maps; a national
  "tail-heaviness + choice-stability" figure pair.

### A3. Heterogeneity hot-spots *(public-safe)*
- **Question**: where do sharp climate gradients defeat automated region
  formation — the national version of the Keene/Cascade-transition lesson?
- **Inputs**: H1 by facility; drop/removal reasons from station audit
  files.
- **Method**: map H1 exceedance density; test alignment with known
  gradients (coastal-interior transitions, rain shadows, mountain fronts).
  These hot-spots are also where per-facility expert review matters most —
  feed them into review prioritization.
- **Artifact**: section in `docs/analysis/method_diagnostics.md`.

## Phase B — at fleet completion

### B1. The Atlas 14 mega-comparison *(public-safe; flagship)*
- **Question**: how do uniform L-moments estimates compare with the
  official patchwork, at unprecedented breadth — and what systematic
  biases emerge in either?
- **Inputs**: fleet DDF + NOAA PFDS point queries (`compare_atlas14.R`
  exists for single sites).
- **Method**: **do not hammer PFDS with 73k queries.** Stratified sample
  (~3–5k dams across Atlas 14 volumes, climate regions, elevation bands)
  + all ~300 BOR dams; polite rate-limiting with a resumable ledger.
  Compare 100-yr/24-h (and 1000-yr where Atlas 14 provides it); decompose
  disagreement by Atlas 14 volume age, station density, terrain.
  Include the **Atlas 2 legacy zones** (Pacific NW) as a headline stratum:
  quantify what half a century of data does to the official number.
- **Artifact**: `docs/analysis/atlas14_comparison.md` + statistics tables;
  candidate short paper.
- **QC hook**: hand-verify N≥20 sites' PFDS values against the web UI
  before trusting the scraper (QAQC plan §C3).

### B2. Design-era drift *(public-safe as aggregates)*
- **Question**: how far has the rainfall design basis shifted under dams
  built to TP-40 (1961)-era depths?
- **Inputs**: fleet DDF + a digitized TP-40 100-yr/24-h surface.
- **Honest blocker to resolve first**: locate a citable digitized TP-40
  grid (state DOT/academic digitizations exist). If none survives
  scrutiny, fall back to Atlas 14-vs-L-moments drift by *dam completion
  decade* (NID has year-completed), which answers a similar question with
  cleaner data.
- **Artifact**: drift-by-decade and drift-by-region figures; aggregate
  only (a per-dam drift table crosses the publication line — private side
  if built at all).

### B3. National uncertainty structure *(public-safe)*
- **Question**: does the BOR finding (region-method choice moves 10,000-yr
  depths median ~15%, worst in small-donor-pool and mountain-transition
  settings) generalize nationally?
- **Dependency**: the fleet ran circular-only, pre-rebase. Full national
  two-method comparison = re-running the fleet (a rebase-decision
  question, not this plan's call). **Interim, decision-independent
  method**: stratified sample (~500–1,000 dams) re-run under both methods
  with elevation enriched for the sample only — enough to estimate the
  national band distribution without the full re-run.
- **Artifact**: `docs/analysis/national_uncertainty.md`; feeds the
  rebase decision with real numbers (cost of *not* rebasing, quantified).

### B4. Consistency cross-checks as findings *(public-safe)*
- The BOR-308 batch and the NID fleet ran the same physical dams through
  the same engine at different times with different manifests. Systematic
  comparison (see QAQC §B4) doubles as a **reproducibility statement** —
  publish the agreement statistics.

## Phase C — post-decision / downstream

- **C1. ASM/ARF national layer** — blocked on the rebase decision (ASM
  is null fleet-wide pre-rebase; drainage-area coverage is 77%).
- **C2. Precip-hazard screening index** — depth × NID hazard class ×
  storage. **Private-side artifact only** (BOR repo pattern); the public
  repo gets, at most, national aggregate statistics.
- **C3. Mechanism crosswalk** — distribution family vs flood mechanism
  requires basin delineations the NID fleet lacks; scope any extension to
  a delineated sample, or fold into future per-state work.

## Sequencing and effort

| Phase | Can start | Effort (est.) |
|---|---|---|
| QA/QC baseline (companion doc) | **now**, on partial | 1–2 sessions build, then automatic |
| A1–A3 | now, refresh at completion | 1 session each |
| B1 | at completion (sampler now) | 2–3 sessions + polite scrape time |
| B2 | after TP-40-source decision | 1–2 sessions |
| B3 | after sample-rerun approval | ~1 session + ~10 h compute |
| C1–C3 | after owner decisions | — |

Every artifact: committed script + pinned input-data commit hash +
verification note per the QA/QC plan. Analyses are screening-grade
research on screening-grade data; none of it outranks the per-facility
expert review this repo's own checklist demands.
