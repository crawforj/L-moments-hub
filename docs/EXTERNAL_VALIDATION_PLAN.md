# External Validation Plan — pre-registered

**Committed 2026-08-24, before any comparison below was run.** The tolerances
in §3 are frozen as of this commit: they were set from the 35-site pilot and
from measured data-vintage effects, and they will not be revised after
results exist. If a result misses its tolerance, that is a finding to
report, not a threshold to move. The git history of this file is the
pre-registration record.

## Why two tiers

Two distinct claims, validated separately:

- **Tier 1 (product comparison):** our estimates are consistent with NOAA
  Atlas 14, the national standard. Answers *"are the numbers right?"*
- **Tier 2 (method reproduction):** our pipeline reproduces published
  Hosking–Wallis studies at their own sites — growth curves and L-moment
  ratios, not just final depths. Answers *"is the method implemented
  right?"*

They fail differently: Tier 1 could pass through cancelling errors; Tier 2
could pass while national bias remains. Both are required. A third tier —
treating the *disagreements between defensible expert analyses* as the
measured quantity — is the research output that the first two make credible
(see `docs/CLUSTER_FLEET_RESULTS.md` for the within-project version).

## 1. Gate

Nothing below runs until the post-completion remediation is finished (ledger
back at 73,303 with a fresh integrity pass showing zero name-collision
facilities). 15,340 facilities carry ambiguous attribution until then; any
comparison drawn early would be contaminated and would have to be retracted.

## 2. Tier 1 — full stratified Atlas 14 sample

- **Tool:** `analysis/b1_atlas14_sampler.py` (ground-truthed against 30
  hand-verified PFDS sites, max abs rel-diff 0.00000 —
  `docs/analysis/atlas14_pilot.md`).
- **Frame:** the committed 61-stratum allocation
  (`data/atlas14/summary/full_frame_allocation.csv`): Atlas 14 coverage ×
  climate region × elevation band; target n = 4,000. Sample per allocation,
  not opportunistically.
- **Durations/AEPs:** 24 h and 72 h at T = 2…1000 yr (Atlas 14's ceiling).
- **Primary readout:** signed and absolute percent difference by stratum,
  plus **conditional-on-H1** curves. The pilot's strongest result is that
  regional heterogeneity predicts |difference| (Spearman 0.532,
  permutation p = 0.0009); the full sample either confirms this with tight
  intervals or kills it. Both outcomes are reportable.
- **Series-type control:** carry the pilot's PDS/AMS check at the same rate.

## 3. Pre-registered expectations — FROZEN

Set from the n = 35 pilot (`data/atlas14/summary/pilot_stats_overall.csv`).

| Quantity (24 h / 100-yr unless noted) | Expectation | Basis (pilot) |
|---|---|---|
| National median signed difference | within ±5% | −1.76% |
| National median &#124;difference&#124; | ≤ 12% | 8.71% |
| Fraction within 20% | ≥ 65% | 74.3% |
| Spearman(H1, &#124;diff&#124;) | > 0, p < 0.05 | 0.532, p = 0.0009 |
| 72 h behaviour | same sign, wider spread | 72 h IQR ≈ 24 h |
| T = 1000 | wider than T = 100, same sign | −4.58% median |

Tier 2 site-level classification (24 h only — the reference study has no
72 h):

| Class | Rule |
|---|---|
| REPRODUCED | &#124;diff&#124; ≤ 10% **and** growth-curve shape ratio within 10% |
| EXPLAINABLE | ≤ 25% with an identified, named cause (station vintage, record length, their Kappa tail vs our selected family, elevation-band handling) |
| DISCREPANT | > 25% or unexplained — published verbatim, listed first, never dropped |

Credibility target: ≥ 70% REPRODUCED and ≤ 10% DISCREPANT across Washington
dams where our region passes homogeneity (H1 < 1). A 100% pass would itself
be suspect; the discrepant list is a deliverable.

## 4. Tier 2 — Washington State (Wallis, Schaefer, Barker & Taylor 2007)

**Reference:** Wallis, J.R., M.G. Schaefer, B.L. Barker & G.H. Taylor
(2007), "Regional precipitation-frequency analysis and spatial mapping for
24-hour and 2-hour durations for Washington State," *HESS* 11:415–442 —
regional L-moments, 12 homogeneous regions, GEV with a 4-parameter Kappa
extension. Codified as Washington's dam-safety standard (Ecology Technical
Note 3, publication 92-55G) and still operationally distributed by the
Department of Ecology.

Why this target first: peer-reviewed; same statistical machinery; a
co-author is the Wallis of Hosking–Wallis; and the result *became a state's
regulatory standard*. Reproducing it is the strongest single credibility
artifact available.

Steps:

1. Acquire Ecology's gridded 24-h precipitation-frequency datasets (the
   TN3 grids). Record retrieval date and checksums; the grids are
   2002/2006-era analyses — vintage documented, not assumed.
2. Extract reference values at our Washington dam coordinates
   (T = 2…500 yr, plus TN3 design-step AEPs 1e-3/1e-4 where gridded).
3. Extract our post-remediation 24-h quantiles for the same dams
   (`site_id`-keyed only; name joins are prohibited).
4. Compare three layers: (a) quantile depths; (b) **growth-curve shape**,
   q(F)/q(100) — the scale-free method fingerprint, insensitive to
   index-flood scaling; (c) regional L-moment ratios (t3/t4) where the paper
   tabulates them.
5. Classify per §3; attribute every EXPLAINABLE to a named cause; publish
   the DISCREPANT list first.

**Confounds declared in advance:** their durations are 2 h/24 h vs our
24 h/72 h (only 24 h overlaps); their Kappa tail vs our five-candidate
selection (shape comparison restricted to T ≤ 500 where both are
GEV-anchored); their 12 fixed regions vs our per-site regions
(membership differences are expected and are data, not error); station
records to ~2003 vs our GHCN through 2026.

Later Tier 2 targets, same template: the Colorado–New Mexico Regional
Extreme Precipitation Study (regulatorily binding in Colorado), NOAA
Atlas 14 Volume 12 (ID/MT/WY, 2024 — the newest volume), and one
NASEM-cited eastern study as an out-of-region control.

## 5. Standing rules

Screening-grade evidence for routing dams to expert review — never
engineering determinations. No per-dam public rankings. Corrections stay in
the record. Every reported number cites the ledger commit and release-asset
checksum it was computed from.
