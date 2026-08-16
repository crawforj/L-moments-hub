# NID fleet -- statistical + coordinate sanity report (QAQC plan sections B, C1)

_Generated 2026-08-16 20:31 UTC by `qc/nid_qc_sanity.py`._

**Partial data.** Input pinned to fleet-branch commit `b7207450f61518acd022204b178fdfb55fef9313` (`claude/desktop-nid-ad-hoc`), N = 31,250 of 73,303 facilities attempted (42.6%). The fleet runs largest-storage-first, so this partial sample over-represents large dams; refresh every artifact at fleet completion before treating any number here as final.

Flags are advisory ("flags not drops"); the machine-readable copy is
`qc/reports/sanity_flags.csv` (4,317 rows).

## Verdicts

| Check | Verdict | Detail |
|---|---|---|
| B1 monotonicity + 72h>=24h | **FAIL** | within-duration monotonicity CLEAN (61,370 growth curves, 57,300 DDF curves, 0 violations); BUT 72h<24h duration crossings at 4,305 of 27,476 unique-name sites (15.7%) -- all at T>=200; diagnosed as an engine limitation (24h and 72h fitted independently with no cross-duration consistency constraint), not a corrupt fold; see the crossing section below |
| B2 physical bounds | **PASS** | 100yr/24h out-of-bounds: 0 of 27,476 attributable facilities (CONUS: 0/27366, AK: 0/31, HI: 0/45, PR: 0/34); CI-ordering violations: 0; tail-band ordering violations: 0. (1174 collided site names excluded from state attribution) |
| B3 profile vs BOR-308 reference | **WARN** | max KS D across 8 metric/duration cells = 0.435 (reference = docs/example_outputs/fleet_308dam/batch_diagnostics.csv; data/region_method_band/bor308_band.csv is not on main -- unmerged PR); see figures/profile_vs_bor308.png |
| B4 needs_review accounting | **WARN** | national needs_review rate 13.1% of facility-durations; states >max(2x national, +5pp) with n>=100: AZ 28.6% (n=454.0), ID 31.0% (n=490.0), MN 34.6% (n=1224.0), ND 31.7% (n=698.0), OH 37.1% (n=996.0), OK 28.1% (n=4760.0), WA 34.7% (n=602.0) |
| C1 coordinate sanity | **WARN** | 12 of 31,250 attempted facilities flagged (bbox test with 1.0 deg buffer; polygon-accurate test deferred to completion pass); non-CONUS attempted: 128 ({'AK': 48, 'HI': 46, 'PR': 34}) |

## Flag counts

| Flag | Severity | Rows |
|---|---|---|
| `coord_outside_state_bbox` | WARN | 12 |
| `dur72_lt_dur24` | FAIL | 4,305 |

## The 72h < 24h duration-crossing finding (B1)

Within-duration monotonicity is perfectly clean, but at 4,305 of
27,476 unique-name sites (15.7%) the fitted
72-h depth drops below the 24-h depth somewhere in the extrapolated tail --
physically impossible for nested annual maxima, so it is a pure artifact of the
engine fitting each duration **independently** (different station sets after the
20-yr record screen, different regions after the H1 homogeneity pruning, and
often a different chosen distribution family) with no cross-duration consistency
constraint.

| T (yr) | crossing sites |
|---|---|
| 200 | 109 |
| 500 | 904 |
| 1000 | 1,730 |
| 2000 | 2,683 |
| 5000 | 3,584 |
| 10000 | 4,305 |

Deficit (24h minus 72h, % of 24h) across crossing (site, T) pairs: median 7.6%, p75 16.1%, max 44.1%.

Supporting evidence for the independent-fit diagnosis: at crossing sites the
24h and 72h fits chose **different** distribution families 75%
of the time, vs 35% at non-crossing sites.

Consequences: (1) every crossing site carries a hard `dur72_lt_dur24` flag (the
plan's rule); (2) no crossing occurs below T=200, so 100-yr products are
unaffected; (3) T>=200 **72h** depths at flagged sites should not be used
without a cross-duration consistency fix or an explicit caveat; (4) the
crossing rate itself is a measure of independent-fit tail uncertainty and is
worth reporting alongside the tail_spread diagnostics.

## B3: diagnostic profile vs the BOR-308 reference shape

Reference used: `docs/example_outputs/fleet_308dam/batch_diagnostics.csv`
(the curated BOR-308 fleet diagnostics committed on main).
`data/region_method_band/bor308_band.csv` was specified as an alternative but
is **not on main** (it lives on the unmerged region-methods PR branch), so the
example-outputs diagnostics file is the benchmark, as the closest validated
reference actually available.

![profile comparison](figures/profile_vs_bor308.png)

KS D statistics (distribution-shape distance, 0 = identical; with n≈31k any
difference is 'significant', so D itself is the honest quantity):

| Duration | Metric | n fleet | n BOR | KS D |
|---|---|---|---|---|
| 24h | H1 | 31,204 | 305 | 0.435 |
| 24h | chosen_absZ | 31,204 | 305 | 0.211 |
| 24h | z_margin | 31,204 | 305 | 0.295 |
| 24h | tail_spread_pct | 31,204 | 305 | 0.186 |
| 72h | H1 | 31,204 | 305 | 0.433 |
| 72h | chosen_absZ | 31,204 | 305 | 0.143 |
| 72h | z_margin | 31,204 | 305 | 0.176 |
| 72h | tail_spread_pct | 31,204 | 305 | 0.180 |

Quantiles (q05 | q25 | q50 | q75 | q95):

| Duration | Metric | Series | q05 | q25 | q50 | q75 | q95 |
|---|---|---|---|---|---|---|---|
| 24h | H1 | NID fleet | -1.98 | -0.97 | -0.19 | 0.54 | 0.9 |
| 24h | H1 | BOR-308 | -0.4 | 0.33 | 0.65 | 0.82 | 0.98 |
| 24h | chosen_absZ | NID fleet | 0.05 | 0.28 | 0.59 | 1.12 | 1.78 |
| 24h | chosen_absZ | BOR-308 | 0.11 | 0.39 | 0.98 | 1.4 | 1.97 |
| 24h | z_margin | NID fleet | 0.13 | 0.64 | 1.05 | 1.36 | 1.87 |
| 24h | z_margin | BOR-308 | 0.09 | 0.46 | 0.8 | 1.01 | 1.75 |
| 24h | tail_spread_pct | NID fleet | 60.7 | 87.0 | 89.8 | 91.3 | 97.7 |
| 24h | tail_spread_pct | BOR-308 | 58.3 | 62.6 | 88.2 | 90.8 | 100.24 |
| 72h | H1 | NID fleet | -2.38 | -1.4 | -0.49 | 0.49 | 0.9 |
| 72h | H1 | BOR-308 | -0.97 | 0.23 | 0.64 | 0.8 | 1.02 |
| 72h | chosen_absZ | NID fleet | 0.07 | 0.36 | 0.83 | 1.45 | 2.09 |
| 72h | chosen_absZ | BOR-308 | 0.13 | 0.51 | 1.08 | 1.6 | 2.07 |
| 72h | z_margin | NID fleet | 0.11 | 0.52 | 0.88 | 1.21 | 1.93 |
| 72h | z_margin | BOR-308 | 0.11 | 0.41 | 0.7 | 1.08 | 2.05 |
| 72h | tail_spread_pct | NID fleet | 59.3 | 84.0 | 88.9 | 90.8 | 99.9 |
| 72h | tail_spread_pct | BOR-308 | 56.32 | 61.1 | 86.6 | 91.4 | 99.76 |

Distribution-family share at 24 h (fraction of facilities):

| Family | NID fleet | BOR-308 |
|---|---|---|
| GEV | 0.669 | 0.564 |
| GLO | 0.178 | 0.302 |
| GNO | 0.136 | 0.125 |
| PE3 | 0.017 | 0.010 |

Interpretation caveats: the BOR-308 set is ~300 large federal dams (many in
the interior West), while the partial NID fleet is the ~31k largest-storage
dams nationally -- some profile difference is expected from geography alone,
not only from method behavior. A national profile wildly different from the
validated subset would still be a finding to explain before use (plan B3);
the comparison above is the check.

## B4: needs_review by state

![needs_review by state](figures/needs_review_by_state.png)

## C1: coordinate sanity

In-state test uses generous state bounding boxes with a 1.0 deg buffer -- a coarse screen for gross errors (sign slips,
transpositions, wrong state). A polygon-accurate in-state / open-water test is
deferred to the completion pass. Known-issue register item 2 (NID mirror
coordinates unverified) applies to every facility regardless of flags here.

![flag map](figures/sanity_flags_map.png)

## Known-issue register propagation

Touches register items 2 (coordinates -- C1), 4 (elevation NA -- degrades the
index-flood regression fleet-wide; bounds in B2 remain valid screens), and 5
(gauge undercatch biases mountain depths low -- bounds are generous enough that
undercatch cannot flip a pass/fail).

## Pinned inputs

- Fleet data: `b7207450f61518acd022204b178fdfb55fef9313` (`claude/desktop-nid-ad-hoc`)
- BOR-308 reference: `docs/example_outputs/fleet_308dam/batch_diagnostics.csv` (main)