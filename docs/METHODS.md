# Technical basis — regional precipitation-frequency analysis by L-moments

This document states the method, the exact parameter choices, and their bases,
for reviewers (e.g. Reclamation flood hydrologists). It describes what the code
in `R/00_setup.R … R/11_audit_report.R` actually does. Notation and section
references follow **Hosking & Wallis (1997)**, *Regional Frequency Analysis: An
Approach Based on L-Moments*, Cambridge University Press (hereafter **H&W**).

Validation of this method against the H&W textbook examples and an independent
hand-calculation is in [`VALIDATION.md`](VALIDATION.md); assumptions and
limitations are in [`ASSUMPTIONS_AND_LIMITATIONS.md`](ASSUMPTIONS_AND_LIMITATIONS.md).

---

## 1. Objective

For a dam site, estimate **precipitation depth–duration–frequency (DDF)**: the
rainfall depth for each design duration and annual exceedance probability (AEP),
out to the **10,000-year** return period (AEP = 1×10⁻⁴), with uncertainty
bounds. A single gauge has far too short a record to estimate a 10⁴-year event
directly, so the **regional frequency analysis (RFA)** / **index-flood** approach
of H&W "trades space for time": many nearby gauges assumed to share one
dimensionless frequency distribution are pooled to estimate that distribution's
shape, and a site-specific scale factor (the *index flood*) rescales it.

## 2. Data

- **Precipitation:** GHCN-Daily (Global Historical Climatology Network – Daily),
  element `PRCP`, read from the AWS Open-Data mirror `noaa-ghcn-pds`. Observations
  failing NOAA quality assurance (non-blank QFLAG) are removed before analysis
  (`qflag_screen: true`). See `DATA_SOURCES.md`.
- **Site list:** dam coordinates from a NID-derived manifest (`config/*.csv`).
  **Unverified** — see `DATA_SOURCES.md`.

## 3. Region formation (per site)

Candidate gauges are selected around the site and screened:

| Control | Default | Meaning |
|---|---|---|
| `search_radius_km` | 175 | gauges within this great-circle radius of the dam |
| `elevation_band_m` | [-100, 6200] (fleet template); [600, 2600] for Como specifically | keep gauges within this elevation range |
| `min_record_years` | 20 | drop gauges with fewer valid annual maxima |
| `min_year_completeness` | 0.90 | fraction of in-season days a year must have to count |
| `max_stations` | 60 | cap on nearest gauges pulled (bounds download / region size) |

The radius/elevation/record filters implement H&W's guidance that a region be a
group of sites plausibly sharing a frequency distribution. All add/drop
decisions are logged to the provenance log. **`elevation_band_m` is a
site-specific tuning knob, not a universal constant** — Como's `[600,2600]`
correctly excludes lowland stations from a different storm regime for that
one high-mountain Montana site, but the same range copied unchanged into
every fleet facility's config silently zeroed the candidate pool for any
low-elevation region (confirmed 2026-08-11: 87.5% of one fleet round's
failures). The fleet template default is now wide (`[-100,6200]`) and relies
on the discordancy/heterogeneity statistics below — not the elevation
prefilter — as the actual region-homogeneity safeguard.

## 4. Annual maximum series (AMS) and durations

GHCN-Daily gives **calendar-day** totals. For a duration of `d` days the code
forms a **d-day running total** over the continuous (gap-filled) daily series and
takes, for each year, the maximum over windows whose **end date** falls in the
seasonal window (`R/functions.R: rolling_sum`, `build_ams_from_daily`). A window
containing any missing day yields `NA`; a year failing `min_year_completeness` is
dropped.

Two durations are analysed by default:

| Label | `days` | Fixed-interval factor | Basis |
|---|---|---|---|
| `24h` | 1 | 1.13 | converts constrained calendar-day maxima to true unconstrained 24-h depths |
| `72h` | 3 | 1.03 | same, for 3-day / 72-h |

The **fixed-interval factor** (Hershfield; WMO-No.1045) corrects the low bias of
fixed-clock-interval observations relative to true sliding-duration extremes
(a single clock-day boundary rarely coincides with the true worst 24 h).

**Season:** the default window is the **full calendar year** (`start_month: 1`,
`end_month: 12`) — the true annual maximum, which dam-safety work requires,
because the controlling storm (e.g. late-summer convection or fall rain-on-snow
in the Northern Rockies) often falls outside any single season. A restricted
season may be configured for a season-specific study, but it **biases estimates
low** (measured for Como: ~12–14% low at 24 h, up to ~54% low at 72 h).

## 5. At-site L-moments

For each gauge's AMS the sample **L-moments** and L-moment ratios (L-CV `t`,
L-skewness `t₃`, L-kurtosis `t₄`) are computed by `lmomRFA::regsamlmu()` (H&W
ch. 2). L-moments are used throughout because they are far less biased and more
robust for small samples and heavy tails than ordinary product moments.

## 6. Screening — discordancy `Dᵢ`

The discordancy measure `Dᵢ` (H&W §3.2.4) flags gauges whose L-moment ratios are
far from the regional average (data errors, atypical sites). A gauge is removed
when `Dᵢ ≥ D_crit`, where `D_crit` is the H&W critical value returned by
`regtst()` (a function of the number of sites, capped at 3). Computed in
`R/03_screening.R`.

## 7. Homogeneity — heterogeneity `H`

The region's homogeneity is measured by the heterogeneity statistic `H₁` (and
`H₂, H₃`), H&W §4.3, comparing the observed between-site dispersion of L-moment
ratios to that expected from `n_sim` simulations of a homogeneous region drawn
from a fitted kappa distribution. Interpretation (H&W):

- `H₁ < 1` — acceptably homogeneous;
- `1 ≤ H₁ < 2` — possibly heterogeneous;
- `H₁ ≥ 2` — definitely heterogeneous (flagged for manual region review).

The region is refined iteratively (`R/04_homogeneity.R`); the simulation is
**seeded** (`seed: 20260811`) so `H` is reproducible.

## 8. Distribution choice — goodness-of-fit `Z`

Five candidate three-parameter distributions are tested: **GLO, GEV, GNO, PE3,
GPA**. For each, the goodness-of-fit statistic `Z^DIST` (H&W §5.2.3) compares the
regional-average L-kurtosis to the value implied by the fitted distribution;
`|Z^DIST| ≤ 1.645` indicates an acceptable fit. The pipeline **auto-selects the
distribution with the smallest `|Z|`** among the candidates. Precedence
(`R/05_distribution.R`): an **expert review record** (`config/distribution_review.csv`)
overrides a **config override** (`distribution_override`) overrides the
**automatic** min-`|Z|` choice. Automated fleet runs always auto-select; the
L-moment ratio diagram (`R/09_plots.R`) is the visual companion.

Because the far tail can depend strongly on this choice, every run also reports a
**tail-sensitivity** table: the 10,000-year depth under *every* candidate, so the
distribution-choice contribution to extreme-tail uncertainty is explicit.

## 9. Estimation — index-flood growth curve and site quantiles

The regional growth curve `q(F)` (the dimensionless quantile function) is fit by
`lmomRFA::regfit()` from the record-length-weighted regional average L-moments,
and quantiles are read off with `regquant()` (H&W ch. 6). Site quantiles are

```
Q(F) = index_flood × q(F)
```

where `F = 1 − 1/T` and `index_flood` is the site mean annual maximum transferred
to the (usually ungauged) dam:

- `method: "regression"` — regress at-site mean on elevation across the regional
  gauges and predict at the dam elevation (used for Como);
- `method: "nearest"` — use the nearest gauge's mean (used for the fleet, where
  ground elevations are absent). If a site elevation is missing under the
  regression method, the code falls back to the regional mean rather than error.

Return periods reported: `2, 5, 10, 25, 50, 100, 200, 500, 1000, 2000, 5000,
10000` yr (`AEP = 1/T`). Growth curves are checked for monotonicity.

## 10. Uncertainty

Error bounds are produced by Monte-Carlo (`lmomRFA::regsimq`, `n_sim: 500`) at
the `conf: 0.90` level (`R/07_uncertainty.R`), giving a 90% band and a relative
RMSE per quantile. **These bounds reflect sampling/parameter uncertainty of the
fitted regional model.** They do **not** capture model-selection uncertainty
(that is what the tail-sensitivity table is for), regionalization error, or input
data error — see `ASSUMPTIONS_AND_LIMITATIONS.md`.

## 11. Deliverables and provenance

Each run writes: the region map; used/removed station lists with reasons; the
L-moment ratio diagram and growth-curve fit plot; DDF tables and curves with
bounds; a self-contained HTML audit report; and a provenance manifest (config,
code state, seed, station disposition, timestamps). Station-count reconciliation
is asserted as an audit invariant. Output columns are defined in
[`OUTPUT_DATA_DICTIONARY.md`](OUTPUT_DATA_DICTIONARY.md); the reviewer sign-off
procedure is in [`expert_review_checklist.md`](expert_review_checklist.md).

## 12. Software

`lmom` and `lmomRFA` (J.R.M. Hosking) are the reference L-moment engines and do
all core computation; where CRAN is unreachable they are built from the public
CRAN GitHub mirrors. Mapping/plotting use `ggplot2`, `sf`, `maps`. R ≥ 4.

## References

- Hosking, J.R.M., and Wallis, J.R. (1997). *Regional Frequency Analysis: An
  Approach Based on L-Moments.* Cambridge University Press.
- Hosking, J.R.M. `lmom` and `lmomRFA` R packages (reference implementation).
- World Meteorological Organization, *Manual on Estimation of Probable Maximum
  Precipitation (PMP)*, WMO-No. 1045 — fixed-interval adjustment.
- Menne, M.J., et al. (2012). GHCN-Daily. *J. Atmos. Oceanic Technol.*
