# Cross-duration consistency: the 72 h < 24 h crossings

_Follow-up item 2 of `docs/NID_COMPLETION_RUNBOOK.md` §4; sanity-gate check B1
(`docs/NID_QAQC_PLAN.md`). Written 2026-08-19. **Diagnostic only — no fix is
implemented here.** The plan calls for documenting the issue and its options and
letting the project owner / reviewing hydrologist choose; this document is that
input._

## 1. What was measured

The B1 sanity gate requires the 72-hour depth to be ≥ the 24-hour depth at every
return period. Within-duration monotonicity is **100% clean** (0 violations
across 61,370 growth curves and 57,300 DDF curves at the pinned commit). The
cross-duration requirement is not.

| Source | Sample | Sites with a 72 h < 24 h crossing |
|---|---|---|
| `qc/reports/sanity_report.md` (pinned fleet commit `b7207450`) | 27,476 attributable sites of 31,250 attempted | 4,305 (**15.7%**) |
| Independent recomputation for this document (release tag `nid-run1-data`, 50,451 attempted) | 42,426 attributable sites | 6,320 (**14.9%**) |

The two agree closely on a sample 55% larger, so the rate is stable and not an
artifact of the partial-run composition. All figures below are from the
recomputation.

**Crossings appear only in the extrapolated tail, and grow monotonically with T:**

| T (yr) | 2–100 | 200 | 500 | 1000 | 2000 | 5000 | 10000 |
|---|---|---|---|---|---|---|---|
| sites crossing | **0** | 172 | 1,281 | 2,446 | 3,803 | 5,244 | 6,320 |
| % of 42,426 | **0.00%** | 0.41% | 3.02% | 5.77% | 8.96% | 12.36% | 14.90% |

Magnitude, over the 19,266 crossing (site, T) pairs — deficit = (24 h − 72 h) as
a % of the 24 h depth:

| median | p75 | p90 | p95 | max |
|---|---|---|---|---|
| 7.2% | 15.4% | 24.1% | 28.4% | 44.1% |

The deficit is worst where the crossing starts earliest. Sites whose first
crossing is at T = 200 reach a median maximum deficit of **37.7%**; sites whose
first crossing is at T = 10,000 reach only **1.3%**. So the small population of
early crossers is the badly affected one, and the large population of
10,000-yr-only crossers is barely off.

## 2. What it means physically, and exactly which products are affected

A 72-hour annual maximum is, by construction, the maximum over a window that
**contains** the 24-hour window that produced the 24-hour annual maximum. The
72-hour depth therefore cannot be smaller than the 24-hour depth for the same
year, the same site, or the same exceedance probability. **A fitted 72 h < 24 h
pair is not a climate signal of any kind. It is an artifact of extrapolating two
independently fitted models past the data that constrains them.**

That framing bounds the damage precisely:

| Product | Affected? |
|---|---|
| **All 24-hour depths, every T** | **No.** The 24-h curve is never the one that is too low. |
| **All depths at T ≤ 100**, both durations | **No.** Zero crossings below T = 200; the tightest 100-yr margin anywhere in the fleet is 72h/24h = 1.013. |
| **Growth curves, regional L-moments, H1, distribution choice, tail_spread** | **No.** All within-duration; monotonicity is clean. |
| **A2/A3 spatial analyses** | **No.** 24-h only (`tail_geography.md` states this). |
| **72-hour depths at T ≥ 200 at the 14.9% of flagged facilities** | **Yes.** 19,266 values = **3.78%** of all 72-h DDF values, **7.57%** of 72-h values at T ≥ 200. |

Everything the project currently publishes as a headline product — 100-yr
estimates, family geography, tail-heaviness ratios, heterogeneity — is outside
the affected set.

One further consequence worth keeping: **the crossing is informative even
uncorrected.** A crossing is a directly observable, physically-anchored proof
that a facility's two tail extrapolations disagree by more than the
climatological gap between the durations. Nothing else the fleet produces gives
that kind of falsifiable check on tail quality.

## 3. Where the crossings concentrate

### 3.1 The exact mechanism

Write `margin₁₀₀ = D₇₂(100) / D₂₄(100)` (the climatological duration gap, where
both fits are well constrained) and `steep_d = D_d(10000) / D_d(100)` (each
duration's own tail steepness). Then

> crossing at T = 10,000 ⟺ `margin₁₀₀ × (steep₇₂ / steep₂₄) < 1`

This is not a model — it is an identity, and it partitions the fleet with **zero
exceptions** (42,426 of 42,426 sites classified correctly). It says a crossing
needs two things at once: a small climatological margin, and a 24-hour growth
curve that is steeper than the 72-hour one.

| | crossing (n = 6,320) | not crossing (n = 36,106) |
|---|---|---|
| median `margin₁₀₀` | 1.125 | 1.225 |
| median `steep₇₂/steep₂₄` | **0.785** | **0.976** |
| median `steep₂₄` | 2.39 | 1.89 |
| median `steep₇₂` | 1.76 | 1.87 |

Note that `steep₇₂` is essentially identical in both groups. **The crossing
population is not one where the 72-hour fit went wrong — it is one where the
24-hour fit ran away.**

Counterfactuals, holding one factor at its non-crossing median across the whole
fleet:

| scenario | predicted crossing rate at T = 10,000 |
|---|---|
| actual | 14.90% |
| `margin₁₀₀` held fixed (only steepness varies) | 8.63% |
| **`steep₇₂/steep₂₄` held fixed (only margin varies)** | **0.03%** (14 sites) |

Growth-curve divergence is the **necessary** cause; the climatological margin is
a **modulator** that decides which sites the divergence is large enough to break.

### 3.2 Distribution-family choice — the dominant single factor

Crossing rate by whether the two durations selected the same family:

| | sites | crossing |
|---|---|---|
| different family per duration | 17,273 | **26.1%** |
| same family both durations | 25,153 | **7.2%** |

Different-family sites are 41% of the fleet but carry **71% of all crossings**.

Broken out by the **ordered** pair (24 h family / 72 h family), the pattern is
not merely "different" — it is strictly **directional**:

| 24h / 72h | sites | crossing % | | 24h / 72h | sites | crossing % |
|---|---|---|---|---|---|---|
| **GLO / GEV** | 2,961 | **93.8%** | | GEV / GLO | 5,086 | **0.0%** |
| GEV / PE3 | 278 | 43.5% | | PE3 / GEV | 408 | 0.0% |
| GNO / PE3 | 468 | 37.6% | | PE3 / GNO | 273 | 0.0% |
| GEV / GNO | 4,158 | 30.8% | | GNO / GEV | 3,245 | 0.0% |
| | | | | GNO / GLO | 247 | 0.0% |

Every ordering runs one way and its mirror runs at zero. The ordering is by
empirical tail heaviness — median `Q₁₀₀₀₀/Q₁₀₀` at 24 h by chosen family:

| GLO | GEV | GNO | PE3 |
|---|---|---|---|
| 2.76 | 1.92 | 1.77 | 1.51 |

**The rule is: a crossing occurs when the 24-hour duration selects a
heavier-tailed family than the 72-hour duration.** GLO/GEV alone — 24 h gets the
heaviest family, 72 h gets the next one down — accounts for **43.9% of every
crossing in the fleet**, at a 93.8% hit rate.

Same-family sites still cross, at a rate that also tracks tail heaviness:
GEV/GEV 8.6%, GLO/GLO 4.5%, GNO/GNO 0.5%, PE3/PE3 0.0%. So family choice is the
dominant factor but not the whole story — regional L-moments differ between
durations too (different station sets survive the 20-yr record screen, different
regions survive H1 pruning).

### 3.3 Is it the coin-flip facilities?

Largely yes. Grouping by whether the two durations had the _same top-two
candidate families_ and whether they picked the same winner:

| | sites | crossing |
|---|---|---|
| same top-2 set, **different** winner (a genuine coin flip) | 9,466 | **26.0%** |
| same top-2 set, same winner | 18,813 | 7.6% |
| different top-2 sets | 14,147 | 17.2% |

At the 2,961 GLO/GEV sites, GEV was the 24-hour runner-up in **100%** of cases —
so at every one of them the goodness-of-fit test was choosing between exactly the
two families whose tail behaviour differs most, and the 24-hour fit took the
heavier one. Their selection margins are correspondingly thin: median `z_margin`
0.854 (24 h) and 0.772 (72 h), against fleet medians of 1.057 and 0.866.

Crossing rate also falls monotonically with selection confidence at 72 h:
19.2% / 17.1% / 17.0% / 12.0% / **9.1%** across ascending `z_margin` quintiles.

### 3.4 Station count, homogeneity, record length, size

| covariate | pattern | read |
|---|---|---|
| `n_stations` (24 h) | 27.2% in the lowest decile (5–37 stations) falling to 8.1% in the highest (50–51) | **real, moderate** — thin regions give unstable higher L-moments |
| `H1` (24 h) | 20.9% (H1 < −2), 20.3% (−2 to −1), 14.6% (−1 to 0), 12.2% (0 to 1), 9.9% (1 to 2) | **real but counter-intuitive** — crossings are _more_ common at strongly negative H1, i.e. regions that look "too homogeneous", which is itself a small/correlated-station-pool signature rather than genuine homogeneity |
| `tail_spread_pct` (72 h) | 1.9% in the lowest quintile rising to ~20% in the upper four | **real** — the existing tail-instability diagnostic already sees this |
| `needs_review` | 30.1% when both durations are flagged vs 14.2% when neither is | **real** — the flag is doing its job |
| **record length** | median 53 yr at crossing sites vs 54 yr at non-crossing; no monotone pattern across quintiles | **no signal.** Crossings are _not_ a short-record problem |
| NID storage | 13.1% → 17.4% across quintiles (largest most affected) | **weak**; also confounded with the fleet's largest-first ordering |
| `homog_status` | 15.0% homogeneous/homogeneous vs ~9% where either duration is only "acceptably homogeneous" | **negligible / slightly inverted** |
| `\|n_stations₂₄ − n_stations₇₂\|` | flat, 9.9–16.2% with no ordering | **no signal** — differing _station pools_ are not the driver; differing _fits_ are |

### 3.5 Geography

Crossing rate is strongly regional, and it tracks the climatological duration
margin rather than anything about data quality:

| region | sites | crossing | median `margin₁₀₀` |
|---|---|---|---|
| Upper Midwest (MN WI MI IA) | 3,661 | **27.5%** | 1.147 |
| Northern Rockies / Plains (MT NE ND SD WY) | 5,953 | 23.7% | 1.178 |
| Northeast | 4,807 | 21.9% | 1.216 |
| Ohio Valley | 5,016 | 16.1% | 1.215 |
| Northwest (ID OR WA) | 1,237 | 13.7% | 1.434 |
| South (KS OK TX AR LA MS) | 12,142 | 9.4% | 1.206 |
| Southwest (AZ CO NM UT) | 2,088 | 9.0% | 1.327 |
| Southeast | 6,301 | 7.8% | 1.231 |
| West (CA NV) | 1,060 | **4.3%** | 1.548 |

Across states with n ≥ 100 the rank correlation between median `margin₁₀₀` and
crossing rate is **−0.59** (Pearson −0.45). The extremes: NE 59.3%, VT 52.2%,
VA 48.7%, OH 47.7%, MI 37.7% at the top; SC 0.2%, TN 0.2%, AL 0.5%, GA 0.6%,
MS 0.7% at the bottom.

This is physically coherent. Where extreme precipitation is convective and
short-duration-dominated (Plains, Upper Midwest), a 72-hour total is barely
larger than a 24-hour one and there is almost no margin for the two
extrapolations to diverge into. Where extremes are synoptic or orographic and
multi-day (California, Pacific Northwest, interior West), the margin is 1.4–1.6
and the divergence has to be enormous to close it. **The geography of crossings
is the geography of the 72 h/24 h ratio, not a map of where the method is
broken.**

### 3.6 Summary of the concentration analysis

A crossing facility is, in one sentence: **a facility in a
short-duration-dominated climate where a thin, marginal goodness-of-fit decision
handed the 24-hour duration a heavier-tailed distribution than the 72-hour
duration got.** Record length is irrelevant; differing station pools are
irrelevant; family selection and its tail-heaviness ordering do the work.

## 4. What the field does about this

This is a known, expected, routinely-corrected artifact in operational
precipitation-frequency practice — not a novel defect. Every agency product
checked below documents a cross-duration consistency step. Sources were fetched
and read for this document; page references are to the printed page numbers.

### 4.1 NOAA Atlas 14 — post-hoc correction, and a diagnosis identical to ours

Atlas 14 fits each duration independently and then repairs the result. Volume 2
(Ohio River Basin; Bonnin, Martin, Lin, Parzybok, Yekta & Riley, 2004 rev. 2006),
§4.6.3 "Practical consistency adjustments", p. 41, states the problem in terms
that map onto ours exactly:

> "Since the quantiles of each duration at a given station were calculated
> separately, inconsistencies could occur where a shorter duration had a
> quantile that was higher than the next longer duration at a given average
> recurrence interval. … This result, although based on sound statistical
> analysis, is physically unreasonable."

**Critically, NOAA's diagnosis of the cause is the same as our measurement**
(same section, same page):

> "Such results primarily occurred where durations had similar mean annual
> maxima but the shorter duration had higher regional parameters, such as
> coefficient of L-variation and L-skewness that produced a quantile higher than
> the longer duration quantile. The underlying causes of such an anomaly were
> primarily **discontinuities in selection and parameterization of distribution
> functions between durations**, data sampling variability, and the application
> of average conversion factors…"

Their worked example (Table 4.6.1, Hazard KY) shows the same tail signature we
see: the 3 h/2 h ratio is fine through 25 yr, dips below 1.0 at 50 yr, and
degrades monotonically out to 1000 yr.

Volume 2's grid-level rule, p. 54, also reports the only frequency
characterization NOAA published:

> "Frequency-based internal consistency violations (e.g., 100-year < 50-year)
> were very rare… **Duration-based internal consistency violations (e.g.,
> 24-hour < 12-hour) were more common**, particularly between 120-minute and
> 3-hour, but again were small violations… the longer duration or rarer
> frequency grid cell value was adjusted by multiplying the shorter duration or
> lower frequency grid cell value by 1.01…"

Volumes 9 (Southeastern, 2013), 10 (Northeastern, 2015 rev. 2019) and 11 (Texas,
2018) all carry the same rule verbatim at §4.8.2: duration check first, then a
re-check across frequencies because the duration fix can create a frequency
violation.

**Volume 9 §4.6.3 (p. 22) is the most directly actionable finding for us** —
NOAA gave up per-duration distribution selection precisely because of this:

> "The GEV distribution was adopted across all stations and for all durations…
> although it is not required to use the same type of distribution across all
> durations and/or regions, **changes in distribution type for different
> durations or regions often lead to considerable discontinuities in frequency
> estimates across durations** or between nearby locations, **particularly at
> more rare frequencies**."

Atlas 14 additionally applies cubic-spline smoothing of quantiles across
durations (Vol 9 §4.6.3) and clamps hourly confidence limits by the 24-hour ones
(Vol 9 §4.6.5) — but the spline is cosmetic and does not guarantee monotonicity;
the ×1.01 check is what enforces it. Sub-hourly durations are the one place NOAA
uses genuine scaling rather than fitting (fixed 0.57 and 0.82 factors off the
15-minute grids, Vol 9 p. 28).

### 4.2 NOAA Atlas 15 — same approach, stricter application

The Atlas 15 Pilot Technical Report (NOAA OWP, v1.1.p, 2025-03-25), §4.3.4,
p. 15, keeps Atlas 14's method:

> "To ensure consistency in estimates across all durations and frequencies…
> duration-based internal consistency checks were conducted and **in rare cases,
> adjusted as needed**. Similar to the approach used for Atlas 14… checks were
> performed on precipitation frequency estimates and their confidence bounds…
> and was implemented at station locations and again at all grids following
> interpolation."

Atlas 15 still fits the GEV **per duration** (§4.3.1); duration is not a
covariate, and regionalization is even performed separately above and below 24 h
(p. 11). So the current U.S. state of the art has **not** moved to joint
duration fitting — it has moved to checking twice.

### 4.3 Other national standards

- **Australian Rainfall & Runoff**, Book 2 §3.4.5.6 (v4.2, 2019, pp. 36–37): a
  sixth-order polynomial smoothing across durations, then _"Inconsistencies were
  addressed by adjusting the longer duration rainfall upwards so that the ratio
  of shorter duration rainfall to the longer duration rainfall equals 0.99"_ —
  the exact mirror of NOAA's ×1.01 — then re-smooth, re-adjust, and re-check
  across AEP.
- **UK FEH** (FEH Web Service, DDF Science overview; Stewart, Morris, Jones &
  Svensson 2012, IAHS Publ. 351, 638–643) is the one that is consistent _by
  construction_: the DDF model is a weighted sum of two gamma distributions
  _"parameterised by duration-dependent equations"_, and the documentation states
  the model _"ensures internal consistency in the resulting frequency estimates,
  i.e. that rainfall depths for any duration increase with increasing return
  period, and that rainfall depths for any return period increase with
  increasing duration"_ — plus a final smoothing pass across durations anyway.
- **WMO-No. 168** (_Guide to Hydrological Practices_, Vol. II) covers DDF
  relationships at §5.7.5.2 but contains **no** discussion of cross-duration
  consistency, monotonicity, or curve crossing. There is no WMO rule to appeal to.

### 4.4 The statistical literature — fit durations jointly

- **Koutsoyiannis, Kozonis & Manetas (1998)**, _J. Hydrology_ 206, 118–135,
  doi:10.1016/S0022-1694(98)00097-3 — the origin of duration-dependent
  parameterization, arguing that the conventional per-duration recipe is
  internally inconsistent because it treats intensity, duration and return period
  _"as having the same nature, in spite of the fact that they are fundamentally
  different in nature"_. **Honest caveat:** their empirical demonstration
  (Helliniko, §3.4) found jointly fitted and independently fitted quantiles
  _"practically indistinguishable"_; their tail complaint targets the empirical
  power-law post-fit step, not per-duration distribution fitting. Cite them for
  the joint-fitting _framework_, not for the crossing claim.
- **Fauer, Ulrich, Jurado & Rust (2021)**, _HESS_ 25, 6479–6494,
  doi:10.5194/hess-25-6479-2021 — the clean citation for the crossing claim:
  _"by using a duration-dependent extreme value distribution (d-GEV)… IDF
  estimation can be carried out in one step within a single model. To achieve
  this, GEV parameters are defined as functions of duration. **This approach
  prevents the crossing of quantiles across durations and is, thus, considered
  consistent.**"_ They name Germany's KOSTRA-DWD atlas as an instance of the
  two-step practice whose _"one huge disadvantage… is that quantile crossing can
  occur"_. Their own contribution adds multiscaling and a **flattening** term
  because plain power-law d-GEV misfits long durations — directly relevant at 72 h.
- **Ulrich, Jurado, Peter, Scheibel & Rust (2020)**, _Water_ 12(11), 3119,
  doi:10.3390/w12113119 — d-GEV with spatial covariates; concludes it _"is an
  improvement for the modeling of rare events"_ versus separate per-duration GEV
  fits.
- **Menabde, Seed & Pegram (1999)**, _WRR_ 35(1), 335–339,
  doi:10.1029/1998WR900012 — the simple-scaling IDF model. Its abstract claims
  simple scaling _"over the range 30 min to 24 hours and in some instances to 48
  hours"_ — i.e. **it is not validated at 72 h**. (Abstract verified via
  OpenAlex; the full text was behind a publisher block and was **not** read.)
- **Roksvåg, Lutz, Grinde, Dyrrdal & Thorarinsdottir (2021)**, _J. Hydrology_
  603, 127000, doi:10.1016/j.jhydrol.2021.127000 — post-processing of Bayesian
  posterior quantiles into consistent IDF curves, reportedly including isotonic
  regression. **Citation confirmed via Crossref; the text was NOT accessible and
  its contents are unverified.** Pull the PDF before relying on it.

## 5. The options, with trade-offs

Nothing below is implemented. Ordered by cost.

**Option 0 — carry as a documented, flagged limitation. Change nothing.**
Every affected value already carries a hard `dur72_lt_dur24` flag, no headline
product is affected, and the crossing rate is a genuinely useful tail-uncertainty
diagnostic. _Cost:_ none. _Risk:_ a 72-hour tail number could be used
downstream without reading the flag. _Precedent:_ weak — no agency ships
uncorrected crossings, though none of them ships a per-facility flag either.

**Option 1 — post-hoc hard bump (NOAA ×1.01 / ARR ×0.99).** Set
`D₇₂(T) = 1.01 × D₂₄(T)` wherever the check fails, durations first, then re-check
across T. _Cost:_ trivial; a post-processing pass over the DDF table. _Cited
precedent:_ Atlas 14 Vol 9/10/11 §4.8.2; Atlas 15 §4.3.4; ARR Book 2 §3.4.5.6.
_Risk:_ NOAA designed this rule for _"small violations"_. Ours are not uniformly
small — at sites that first cross at T = 200–500 the deficits are 28–38%, and a
hard clip there would replace a smooth curve with a visible kink and quietly
convert a large disagreement into a plausible-looking number. It repairs the
symptom and destroys the diagnostic.

**Option 2 — post-hoc ratio taper (NOAA Atlas 14 Vol 2 §4.6.3).** Distribute the
last valid ratio surplus at a constant slope along the return-period axis so the
ratio converges to ~1.0 at the far end, rather than clipping. _Cost:_ modest;
one function plus a re-check. _Cited precedent:_ Vol 2 §4.6.3 + Table 4.6.1.
_Advantage over Option 1:_ smooth, and it is the method NOAA actually used at
station level rather than the coarse grid backstop. _Risk:_ still cosmetic — it
makes the 72-hour tail defensible-looking without making it more reliable, and
both durations' tails at a crossing site are suspect, not just the 72-hour one.

**Option 3 — force a single distribution family across both durations, at the
source.** Select one family per facility (e.g. by pooled goodness-of-fit across
durations, or GEV outright) and refit. _Cost:_ an engine change; requires a
re-run. _Cited precedent:_ this is NOAA's own documented reason for adopting GEV
everywhere (Atlas 14 Vol 9 §4.6.3). _Evidence from our data:_ different-family
sites carry **71% of all crossings**, and GLO/GEV alone carries 43.9%. Forcing
one family removes the dominant cause rather than papering over it. _Risk:_
same-family sites still cross at 7.2%, so it is not a complete fix and would
still need a consistency backstop; and forcing GEV where GLO genuinely fits
better trades one bias for another (our fleet is 66.9% GEV at 24 h already, so
the disruption is bounded).

**Option 4 — joint duration-dependent fit (d-GEV).** Make crossings structurally
impossible. _Cost:_ highest — a new estimator, new validation, new golden
anchors. _Cited precedent:_ Fauer et al. 2021; Ulrich et al. 2020;
Koutsoyiannis et al. 1998. _Risk:_ the 72-hour end is exactly where the
literature says plain d-GEV struggles — Menabde's simple scaling is validated
only to 24–48 h, and Fauer et al. added a flattening term specifically because
power-law scaling misfits long durations. With only **two** durations in this
pipeline, a two-point duration-scaling fit is barely identified. Not proportionate
to a research/triage screen.

## 6. Recommendation — for the owner / reviewing hydrologist to accept or override

**Run 1, as published: Option 0 + one disclosure change. Do not retro-patch.**
No product currently published is affected; the crossing is confined to 72-hour
depths at T ≥ 200, which the register already places deep inside "deep
extrapolation" territory. Applying Option 1 or 2 now would edit 19,266 values in
a dataset that is about to be archived, and would delete the single most
informative tail-quality signal the fleet produces in exchange for cosmetic
monotonicity. The disclosure change: state in the data dictionary and the users'
guide that **72-hour depths at T ≥ 200 carrying `dur72_lt_dur24` are not to be
used**, rather than leaving that in the QC report only.

**Run 2 (cluster, `docs/NID_RUN2_CLUSTER_PLAN.md`, fresh branch, not yet
launched): Option 3 + Option 2 as a backstop — fix the cause, then check.**
Run 2 is already a from-scratch re-run on a new branch, so an engine change costs
nothing extra there, and the evidence that family divergence is the cause is
strong (93.8% at GLO/GEV, 0.0% at every mirrored ordering, and the counterfactual
that removes 99.8% of crossings). NOAA reached the same conclusion and made the
same choice for the same stated reason. Adding the Vol 2 ratio taper afterwards
catches the residual 7.2% same-family crossings and makes the product citable
against Atlas 14 practice.

**Reject Option 4 for now.** Record it as the rigorous long-term path, but with
two durations, a 72-hour upper end, and a research-screen mandate, it is not
proportionate — and the literature specifically flags the long-duration end as
where the simple scaling assumption fails.

**Two things to decide explicitly, either way:**

1. Should the crossing rate be **promoted to a reported diagnostic** alongside
   `tail_spread_pct`? It is a physically anchored, falsifiable measure of
   independent-fit tail disagreement, which `tail_spread_pct` is not.
2. If run 2 forces one family per facility, does the same rule apply to the
   **region** definition (currently pruned per duration by H1)? Our data says
   differing station pools contribute little, so probably not — but it should be
   a decision rather than an omission.

## 7. Provenance

- **Recomputation input:** `all_facilities_DDF.csv`, `batch_diagnostics.csv`,
  `stations_used.csv` from release tag `nid-run1-data`
  (`nid_state.json`: 50,451 of 73,303 facilities attempted, fleet commit
  `b63d8180`, uploaded 2026-08-20T03:23Z). Read-only; nothing on the fleet branch
  was touched.
- **Attribution:** restricted to the 42,426 site names mapping to at most one
  `site_id` in both tables, mirroring the sanity layer's handling of the
  name-collision cohort (register item 8).
- **Reference measurement:** `qc/reports/sanity_report.md` and
  `qc/reports/sanity_flags.csv` at pinned fleet commit `b7207450`.
- **Register items touched:** **3** (circular-only regions — family selection
  could shift under the region-method band, which would move these numbers),
  **5** (undercatch — direction-consistent across durations, so it does not
  explain the crossings), **8** (name collisions — handled by the attribution
  filter above).
- All literature and agency documents in §4 were fetched and read for this
  document, except the two explicitly marked otherwise (Menabde et al. 1999 full
  text; Roksvåg et al. 2021 in its entirety).
