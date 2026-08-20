# B1 — NOAA Atlas 14 comparison: sampler, ground-truthing, and 40-site pilot

**Status: infrastructure built and ground-truthed; pilot run; full sample NOT run.**
The NID fleet is ~69 % complete, and the flagship comparison waits for it. What is
finished is everything that has to be right *before* the full run: the endpoint
contract, the coverage map, the series-type question, a scraper that has been
checked value-by-value against what NOAA's own web UI serves, and a 40-site pilot
that proves the whole path end to end.

- **Tool**: [`analysis/b1_atlas14_sampler.py`](../../analysis/b1_atlas14_sampler.py)
- **Companion**: [`docs/atlas14_comparison.md`](../atlas14_comparison.md) is the
  single-facility operator protocol (`compare_atlas14.R`) and is unchanged. This
  document covers the fleet-scale sampler only.
- **Plan refs**: `NID_ANALYSIS_PLAN.md` §B1; `NID_QAQC_PLAN.md` §D3 (hand-verify
  N ≥ 20 PFDS values before trusting the scraper) and §E (pinned inputs,
  independent verification, publication safety).
- **Publication safety**: public-safe. Every artifact here is an aggregate
  statistic, a coverage map, or a methodology finding. The per-facility
  comparison table contains depths, not vulnerability margins, and no ranking.

Pinned inputs for every number below:

| Input | Pin |
|---|---|
| Fleet DDF + diagnostics | GitHub release `nid-run1-data`, `nid_state.json` = commit `b63d8180`, `completed_rows` 50,451; `all_facilities_DDF.csv.gz` sha256 `fda8160d654f39fb…` |
| Fleet ledger | `origin/claude/desktop-nid-ad-hoc` @ `a4aa61a0` — 50,450 / 73,303 attempted (68.8 %), 50,400 ok |
| Manifest | `config/nid_manifest.csv` on `main` (73,303 rows) |
| PFDS queries | fetched 2026-08-20 UTC; raw responses cached under `data/atlas14/cache/` |

> **Why the fleet tables come from a release, not the branch.** Fleet commit
> `934e89ba` untracked the eight cumulative CSVs and moved them to release assets
> (LFS quota). `qc/nid_qc_common.materialize()` can no longer reach them, so this
> script downloads them from the release tag instead. `completed_ids.csv` is
> still a plain blob on the branch.

---

## 1. Endpoint contract (verified live, 2026-08-20)

### 1.1 The scripted path

```
GET https://hdsc.nws.noaa.gov/cgi-bin/new/fe_text_mean.csv
      ?lat=<deg>&lon=<deg>&data=depth&units=english&series=<pds|ams>
```

| Parameter | Verified values | Notes |
|---|---|---|
| `lat`, `lon` | decimal degrees, `lon` negative in CONUS | 4 dp is ample (grids are 30 arc-second) |
| `data` | `depth`, `intensity` | `intensity` returns in/hr — **do not** feed it to a depth parser |
| `units` | `english` (inches), `metric` (millimetres) | this project requests `english` and converts with 25.4 |
| `series` | `pds`, `ams` | see §3 |

**The path moved.** NOAA's own (commented-out) JS still uses
`/cgi-bin/hdsc/new/`; that now answers **301 Moved Permanently** to
`/cgi-bin/new/` (re-verified live 2026-08-20). `readLines()` in R follows the
redirect, so `compare_atlas14.R` kept working on the stale path — but it now
requests the current path directly, as the sampler always did, and the contract
is recorded here so the next person does not have to rediscover it.

**No coverage is an HTTP 200, not a 404.** Outside every Atlas 14 project area
the server returns status 200 with the body:

```text
result = 'none';
ErrorMsg =  'Error 3.0: Selected location is not within a project area';
```

Conflating that with a network failure would silently delete the single most
interesting stratum in the analysis. `parse_pfds_csv()` raises a distinct
`PFDSNoCoverage`, and the ledger records `status = no_coverage` separately from
`fetch_error` and `parse_error`.

**Response shape.** A header block (`NOAA Atlas 14 Volume <N> Version <M>`, data
type, time series type, project area, latitude/longitude, elevation), then a
matrix: one row per duration (19 durations, `5-min` … `60-day`, identical in every
CONUS volume probed and in AK/HI/PR), one column per ARI. Units are stated on
line 1 and are parsed, never assumed.

### 1.2 The web UI's own backend (used for ground-truthing)

```
GET https://hdsc.nws.noaa.gov/cgi-bin/new/cgi_readH5.py
      ?lat=&lon=&type=pf&data=depth&units=english&series=<pds|ams>
```

Found by reading `hdsc.nws.noaa.gov/pfds/code/code_gen_16.js`, function
`getTableVals()`. This is what the PFDS interactive page actually calls to fill
its table — a different CGI program returning `quantiles` / `upper` / `lower`
matrices as Python literals plus `volume`, `version`, `region`, `authors`. The
matrices are **unlabelled**: row order is the duration order, which is an
assumption, and §4 is the test of it.

`fe_text_upper.csv` / `fe_text_lower.csv` do **not** exist (404). The 90 %
confidence bounds are only available through `cgi_readH5.py`.

### 1.3 Published GIS grids (third channel, and the only channel in the PNW)

```
https://hdsc.nws.noaa.gov/pub/hdsc/data/<region>/<region><T>yr<dur>a[_ams].zip
https://hdsc.nws.noaa.gov/pub/hdsc/data/{oregon,washington}/na2_{or,wa}_<T>yr<dur>.zip
```

ArcInfo ASCII grids, 30 arc-second (Atlas 14) / 15 arc-second (Atlas 2), NAD83.
Atlas 14 grid values are **thousandths of an inch**; Atlas 2 grid values are
**hundred-thousandths of an inch** (§2.2). ~2 MB per Atlas 14 grid.

### 1.4 Citizenship

The sampler is built for a scrape of thousands of points against one NOAA host:

- ≥ 2 s between requests plus 0–0.6 s jitter (`--sleep`, `--jitter`);
- every raw response written to `data/atlas14/cache/` and **never re-requested**;
- an append-only resumable ledger (`data/atlas14/ledger.csv`) keyed on
  (facility, series) — the standard `_read_ledger()` / append pattern from
  `run_nid_tranche.R`; a re-run of `fetch` with nothing new prints
  *"nothing to do"* and issues zero requests (verified);
- retry with 5 s / 20 s / 60 s backoff, and 400/404 treated as answers, not
  failures;
- a hard per-invocation cap (`--max`, default 250);
- a descriptive `User-Agent` identifying the project and its repository.

---

## 2. Coverage: which volume covers what, and what Atlas 14 does not cover at all

### 2.1 Volumes

Two independent sources were used, and the sampler carries both. They agree
exactly on *which states are covered*; they disagree on one state's volume
number (§ traps, below), and where they disagree the server wins:

1. **NOAA's own state table** — `var states` in
   `hdsc.nws.noaa.gov/pfds/code/general_16.js` (the PFDS web client), lifted
   verbatim into `NOAA_STATE_REGION`.
2. **An empirical probe** — `b1_atlas14_sampler.py coverage`, 122 real NID dam
   coordinates across all 51 states/territories in the manifest, each asked what
   the server itself says. Result: `data/atlas14/summary/coverage_probe.csv`.

| Volume | Version (server) | Project area | States (probe-confirmed) |
|---|---|---|---|
| 1 | 5 | Southwest | AZ, NM, NV, UT |
| 2 | 3 | Ohio River Basin | DE, IL, IN, KY, MD, NC, NJ, OH, PA, SC, TN, VA, WV (+ DC) |
| 3 | 4 | Puerto Rico and U.S. Virgin Islands | PR (, VI) |
| 4 | 3 | Hawaiian Islands | HI |
| 6 | 2 | *reported as* "Southwest" | CA |
| 7 | 2 | Alaska | AK |
| 8 | 2 | Midwestern States | CO, IA, KS, MI, MN, MO, ND, NE, OK, SD, WI |
| 9 | 2 | Southeastern States | AL, AR, FL, GA, LA, MS |
| 10 | 3 | Northeastern States | CT, MA, ME, NH, NY, RI, VT |
| 11 | 2 | Texas | TX |
| 12 | 2 | Interior Northwest | ID, MT, WY |
| — | — | **no Atlas 14** | **OR, WA** |

Two traps found, both of which would have mislabelled strata:

- **Colorado.** NOAA's JS table says `Vol 1`; the server says **Volume 8,
  Midwestern States**. The server wins. The JS `Vol` field is a
  documentation-PDF pointer, not the study that produced the number. The ledger
  therefore records the volume **the server printed for that point**, and the
  static table is used only for pre-fetch stratification and the coverage map.
- **California.** Volume 6, but its `Project area` string is `Southwest` — the
  same string Volume 1 uses. Group by (volume, project area), never by project
  area alone.

![NID dams coloured by the NOAA Atlas 14 volume covering their state; Oregon and
Washington dams are black, marking the 1,602 CONUS dams with no Atlas 14
coverage.](figures/b1_coverage_map.png)

### 2.2 The Pacific Northwest runs on a 1973 atlas

Oregon and Washington are absent from NOAA's own state table and every probe
point in them returns `not within a project area`: **24 / 24 probe points in
OR + WA uncovered, 98 / 98 elsewhere covered.** The current official product
there is, per NOAA's own state pages:

- **Oregon** → NOAA Atlas 2, **Volume 10** (1973)
- **Washington** → NOAA Atlas 2, **Volume 9** (1973)

*"Precipitation Frequency Atlas of the Western United States"* — "Generalized
maps … for 6- and 24-hr point precipitation for the return periods of 2, 5, 10,
25, 50, and 100 years."

Consequences for B1, which the plan's "headline stratum" framing needs stated
plainly:

- **1,602 CONUS NID dams** (2.2 % of the fleet) have no Atlas 14 benchmark at all.
- Atlas 2 stops at **100 years** — there is **no 1000-yr Atlas 2 comparison**, and
  no 72-h one either. In the PNW the *only* overlapping quantiles are 24 h at
  T = 2 and T = 100.
- There is no Atlas 2 point-query service. The machine-readable form is the
  published grid, so `b1_atlas14_sampler.py atlas2` samples
  `na2_{or,wa}_{2,100}yr24hr.zip` at the dam's cell.
- **Grid units.** The Atlas 2 `.asc` headers state no units. The scale
  (1 count = 10⁻⁵ inch) was established two ways, both recorded in
  `data/atlas14/summary/atlas2_grid_unit_check.csv`: the value range over Oregon
  is 1.70–14.50 in for 100-yr/24-h (which is the range Volume 10's isopluvials
  show, with the Coast Range at the top), and a cross-border check — sampling the
  Oregon Atlas 2 grid at −117.10° against the Atlas 14 Volume 12 CGI at −116.90°
  on the Idaho side gives ratios of **0.75 and 1.15** at 42.5 °N and 43.5 °N. A
  factor-of-ten scale error would be unmissable at that test; the residual spread
  is a real 1973-vs-modern difference.

---

## 3. Series type: partial-duration vs annual-maximum

The fleet builds **fixed-interval-corrected annual-maximum series** from GHCN-D
(`R/01_data_acquisition.R`, `build_ams_from_daily()`). PFDS defaults to, and the
web UI headlines, **partial-duration series**. So the like-for-like request is
`series=ams`, and that is what `compare` uses.

The two series are *not* two independent studies. NOAA fits PDS and converts to
AMS with Langbein-type factors that tend to 1 as T grows. Measured, not assumed,
on all 35 covered pilot sites across 11 volumes
(`pilot_series_type_check.csv`):

| Quantile | Sites | Bit-identical AMS vs PDS | Max abs % diff | Median abs % diff |
|---|---|---|---|---|
| 24 h / 100 yr | 35 | 30 | 1.25 % | 0.00 % |
| 24 h / 1000 yr | 35 | 31 | 1.08 % | 0.00 % |
| 72 h / 100 yr | 35 | 30 | 0.87 % | 0.00 % |

The residual ≤ 1.25 % is three-significant-figure rounding in the published
tables, not a methodological gap. **At the return periods B1 headlines, the
series-type choice does not move the answer.** It moves it materially only at
T = 2, 5, 10 — e.g. at Como Dam, 24 h / 2 yr is 1.37 in (PDS) vs 1.29 in (AMS),
a 6 % difference. Any future extension of B1 to short return periods must use
`series=ams`; the sampler fetches and caches both so that would need no re-scrape.

**Two parser dialects, one trap.** The PDS header is
`by duration for ARI (years):, 1,2,5,…,1000`. The AMS header is
`by duration for AEP:, '1/2,'1/5,…,'1/1000` — AEP as a fraction, with a leading
apostrophe (a spreadsheet text-guard), **and no 1-year column**. Stripping
non-digits from `'1/2` yields `12`, i.e. a plausible-looking but entirely wrong
ARI, and the row would then be one column short of the header. `parse_pfds_csv()`
parses both dialects explicitly and **refuses** any row whose value count does not
match the header (self-tested).

---

## 4. Ground-truthing the scraper (QAQC §D3) — 22 sites, 3,762 values, zero mismatches

The requirement is to hand-verify ≥ 20 sites' fetched values against what the
PFDS **web UI** returns before trusting the scraper at scale.

**How "the web UI" was verified, exactly.** The PFDS page is an ArcGIS/JavaScript
application: the depth table does not exist in the served HTML (`pfds_printpage.html`
is a JS shell), so there is no HTML to diff. The table is drawn client-side from
`cgi-bin/new/cgi_readH5.py?type=pf`, which is the call `getTableVals()` in
`pfds/code/code_gen_16.js` makes. **That payload is what the web UI displays**, so
verification means fetching it and comparing every value against the scripted
`fe_text_mean.csv` path. That is an independent request path in every sense that
matters for scraper correctness — different CGI program, different response
format (Python-literal matrices vs labelled CSV), different parser in this
codebase — while sharing the underlying HDF5 grids, which is precisely the point:
it tests *our* fetching and parsing, not NOAA's science.

**Tier 1 — every published value, 22 sites.** `verify --n 22 --series ams`,
spread across volumes. Each site compares the full 19 durations × 9 ARIs = **171
values**; tolerance was set to **exact** (`--tol-pct 0`), not a percentage.

| Facility | Volume | Values compared | 24 h/100 yr, CSV path | 24 h/100 yr, web-UI backend | Verdict |
|---|---|---|---|---|---|
| MT01692 | 12 | 171 | 4.33 in | 4.33 in | MATCH |
| MT01415 | 12 | 171 | 4.26 in | 4.26 in | MATCH |
| WY01382 | 12 | 171 | 2.79 in | 2.79 in | MATCH |
| OK02134 | 8 | 171 | 9.00 in | 9.00 in | MATCH |
| SD01503 | 8 | 171 | 4.82 in | 4.82 in | MATCH |
| OH00038 | 2 | 171 | 5.96 in | 5.96 in | MATCH |
| MD00040 | 2 | 171 | 8.45 in | 8.45 in | MATCH |
| PA00177 | 2 | 171 | 5.20 in | 5.20 in | MATCH |
| NM00451 | 1 | 171 | 5.35 in | 5.35 in | MATCH |
| NV21132 | 1 | 171 | 5.53 in | 5.53 in | MATCH |
| UT00315 | 1 | 171 | 4.78 in | 4.78 in | MATCH |
| TX01262 | 11 | 171 | 9.86 in | 9.86 in | MATCH |
| TX00608 | 11 | 171 | 9.05 in | 9.05 in | MATCH |
| TX02641 | 11 | 171 | 10.20 in | 10.20 in | MATCH |
| CA00214 | 6 | 171 | 3.82 in | 3.82 in | MATCH |
| CA10164 | 6 | 171 | 9.44 in | 9.44 in | MATCH |
| CA10170 | 6 | 171 | 7.72 in | 7.72 in | MATCH |
| CT00092 | 10 | 171 | 8.72 in | 8.72 in | MATCH |
| MA00676 | 10 | 171 | 7.48 in | 7.48 in | MATCH |
| AL01075 | 9 | 171 | 8.57 in | 8.57 in | MATCH |
| AK00027 | 7 | 171 | 5.91 in | 5.91 in | MATCH |
| HI00102 | 4 | 171 | 11.00 in | 11.00 in | MATCH |

**22 sites, 10 volumes, 3,762 individual values compared, 0 mismatches, maximum
relative difference 0.0000 %.** Full records, including the shape check and the
worst-value detail string for each site, are in
`data/atlas14/summary/groundtruth_verification.csv`.

This also **retires the unlabelled-matrix assumption** in §1.2: if the
`cgi_readH5.py` row order were not the CSV's duration order, the exact match
across 19 durations at 22 sites — including Alaska and Hawaii, whose volumes were
produced by different teams years apart — would be impossible.

**Tier 2 — NOAA's published grids, 8 sites, 4 volumes.** A genuinely independent
distribution channel, sharing no CGI code with either of the above: the static
ArcGIS ASCII grid NOAA publishes for that volume/duration/ARI, sampled at the
dam's cell.

| Facility | Grid | CSV path | Published grid | Diff |
|---|---|---|---|---|
| MT01692 | `inw100yr24ha_ams` | 4.330 in | 4.329 in | 0.02 % |
| MT01415 | `inw100yr24ha_ams` | 4.260 in | 4.259 in | 0.02 % |
| OK02134 | `mw100yr24ha_ams` | 9.000 in | 8.984 in | 0.18 % |
| SD01503 | `mw100yr24ha_ams` | 4.820 in | 4.829 in | 0.19 % |
| OH00038 | `orb100yr24ha_ams` | 5.960 in | 5.961 in | 0.02 % |
| MD00040 | `orb100yr24ha_ams` | 8.450 in | 8.436 in | 0.17 % |
| TX01262 | `tx100yr24ha_ams` | 9.860 in | 9.849 in | 0.11 % |
| TX00608 | `tx100yr24ha_ams` | 9.050 in | 9.053 in | 0.03 % |

All eight agree to **≤ 0.19 %**, which is the expected size of nearest-cell
sampling against the CGI's within-cell interpolation over a 30-arc-second grid —
not a scraper defect.

**Verdict: no mismatches at any tier. The scraper returns what NOAA publishes.**
The parser is additionally covered by an offline self-test
(`b1_atlas14_sampler.py selftest`, 14 assertions, no network) that pins the PDS
and AMS dialects, the no-coverage body, ragged-row rejection, the
`24-hr`-over-`1-day` preference, and the OR/WA Atlas-2 fact.

---

## 5. The 40-site pilot

### 5.1 Design

`frame --pilot --pilot-n 40 --pilot-bor 8` (seed 20260820). Restricted to
facilities the fleet has finished and can be joined unambiguously — by `site_id`
where the DDF has one, otherwise by a facility name that is unique in *both* the
manifest and the DDF, so the fleet's known name collisions can never resolve to
the wrong dam. Drawn for **coverage-class breadth** rather than as a shrunken
version of the full allocation: 3–5 dams from each of the 11 covered volumes plus
5 from the Atlas-2 PNW gap, plus an 8-dam BOR-overlap subsample.

Result: 40 facilities — **35 with Atlas 14, 5 in the Atlas-2 gap** — spanning
11 volumes, 11 climate regions and all four elevation bands. 80 requests
(2 series × 40), 0 parse errors, 10 correctly classified `no_coverage`.

### 5.2 Headline: scatter, not bias

24 h / 100 yr, ours vs Atlas 14, n = 35:

| Duration / T | n | median | mean | p10 | p90 | IQR | median abs | within ±10 % | within ±20 % |
|---|---|---|---|---|---|---|---|---|---|
| 24 h / 100 yr | 35 | −1.76 % | −0.13 % | −26.4 % | +23.1 % | 16.4 pp | 8.7 % | 54 % | 74 % |
| 24 h / 1000 yr | 35 | −4.58 % | −0.01 % | −25.2 % | +30.8 % | 21.0 pp | 10.9 % | 46 % | 74 % |
| 72 h / 100 yr | 35 | −4.06 % | +0.78 % | −28.1 % | +30.9 % | 13.8 pp | 8.4 % | 57 % | 66 % |

![Left: histogram of the percentage difference at 24 h / 100 yr, centred near
zero with a spread from about −32 % to +66 %. Right: the same values as a strip
plot by Atlas 14 project area, showing Alaska high, Puerto Rico and Hawaii low,
and Texas, the Ohio River Basin and the Northeast tightly clustered on
zero.](figures/b1_pilot_diff_distribution.png)

**There is no detectable systematic bias at 24 h / 100 yr.** Median −1.8 %,
bootstrap 95 % CI **−5.3 % to +4.1 %** (4,000 resamples), 14 of 35 differences
positive — a sign test cannot reject a coin flip. The story is **spread**:
half the sites land within ±8.7 %, but the 10th–90th percentile band is 50
percentage points wide and the extremes run −32 % to +66 %. Agreement also
degrades toward the tail — the IQR widens from 16.4 pp at 100 yr to 21.0 pp at
1000 yr, which is what you would expect if the disagreement is dominated by
regional-growth-curve differences rather than by the index flood.

### 5.3 Region-specific structure (weak, small-n)

`pilot_stats_by_volume_24h_100yr.csv`. **Every one of these cells has n ≤ 9 and
most have n ≤ 4 — these are hypotheses for the full run, not findings.**

| Project area | n | median | median abs |
|---|---|---|---|
| Alaska (Vol 7) | 2 | +37.5 % | 37.5 % |
| Southwest (Vols 1 + 6) | 9 | +8.7 % | 18.8 % |
| Northeastern States (Vol 10) | 3 | +0.8 % | 4.1 % |
| Ohio River Basin (Vol 2) | 3 | −1.3 % | 4.2 % |
| Interior Northwest (Vol 12) | 4 | −1.6 % | 10.2 % |
| Texas (Vol 11) | 3 | −3.5 % | 3.5 % |
| Midwestern States (Vol 8) | 4 | −5.2 % | 5.2 % |
| Southeastern States (Vol 9) | 2 | −6.0 % | 6.0 % |
| Hawaiian Islands (Vol 4) | 3 | −10.1 % | 10.2 % |
| Puerto Rico / USVI (Vol 3) | 2 | −18.4 % | 18.4 % |

The suggestive pattern — tight agreement in the dense-gauge, low-relief East
(Vols 2, 10, 11 all inside ±5 %), wide disagreement in Alaska, the arid
Southwest, and the tropical island volumes — is exactly what a gauge-density and
orography story would predict, and exactly what a 2–4-dam-per-cell sample cannot
establish. Do not quote these cells.

### 5.4 What the disagreement tracks

`pilot_decomposition.csv` — Spearman ρ with permutation p-values (20,000
permutations), n = 35. Both of the plan's nominated decompositions are reported
whether or not they came out:

| Variable | vs \|% diff\| | p | vs signed % diff | p |
|---|---|---|---|---|
| Heterogeneity `H1` (24 h) | **+0.53** | **0.0009** | +0.13 | 0.46 |
| Station support `n_stations` (24 h) | −0.28 | 0.10 | −0.21 | 0.23 |
| Elevation proxy (m) | +0.28 | 0.10 | −0.20 | 0.25 |

Only heterogeneity survives, and it survives comfortably (p = 0.0009 uncorrected;
still < 0.01 after a Bonferroni correction for all six tests in the table). Where
the automated region is more heterogeneous, our number diverges further from
Atlas 14 — in either direction, since the signed correlation is null. That is a
coherent, mechanism-shaped result and it aligns with the A3 heterogeneity work
and the Keene/Cascade-transition lesson. It is still n = 35 and still exploratory:
it becomes a finding when the full sample reproduces it.

Station support pointing the expected way (more stations → less disagreement) but
not reaching significance is a genuine null at this size, not a near-miss to be
narrated as support.

### 5.5 The Atlas-2 legacy stratum (n = 5 — indicative only)

`pilot_atlas2_comparison.csv`. Ours vs the 1973 number still in force in OR/WA:

| Facility | State | T | ours | Atlas 2 (1973) | diff |
|---|---|---|---|---|---|
| OR00544 Frog Lake Dam A | OR | 100 | 159.1 mm | 149.9 mm | +6.1 % |
| OR00581 Emigrant | OR | 100 | 131.5 mm | 101.6 mm | +29.5 % |
| OR01340 Carroll Reservoir | OR | 100 | 151.8 mm | 165.1 mm | −8.1 % |
| WA00433 French Canyon Dam | WA | 100 | 135.8 mm | 56.6 mm | +139.8 % |
| WA00443 Horse Spring Coulee Dam | WA | 100 | 71.5 mm | 55.8 mm | +28.3 % |

Four of five sit above the 1973 number, median +28 %, and the 2-yr comparison
leans the same way (median +15 %). That is the direction the plan anticipated —
but **n = 5 with one extreme cannot support a "half a century of data" claim**,
and two competing explanations are wide open:

- **The Atlas 2 side.** These grids are digitisations of hand-drawn 1973
  isopluvial maps. In the Yakima rain shadow, where French Canyon Dam sits, 1973
  map generalisation across the Cascade crest is crude, and 56.6 mm for a 100-yr
  24-h depth is a very low number.
- **Our side.** French Canyon's region is called **homogeneous** (H1 = 0.53,
  49 stations) — the heterogeneity flag does *not* fire — so if the fault is
  ours, our own diagnostics did not catch it. That is worth chasing on its own,
  independent of B1.

The honest reading of §5.5 is: *the PNW stratum is now measurable, it points
upward, and it needs the full sample and per-site scrutiny of the extremes before
anyone quotes a number.*

### 5.6 Limits of a 40-site pilot — read before quoting anything above

1. **n = 35 covered sites.** The 95 % CI on the overall median is ±~5 pp. Any
   subgroup cell here (n = 2–9) is decoration, not evidence.
2. **Partial fleet, biased toward large dams.** The fleet runs largest-storage
   first and is 68.8 % complete, so the frame over-represents big reservoirs.
3. **Not the stratified design.** The pilot deliberately sampled for coverage
   breadth, so it is *not* proportional to the fleet; national aggregates from it
   would be wrong by construction.
4. **The join.** 35 of 40 pilot sites joined by unique name rather than
   `site_id` (the fleet only carries `site_id` for the post-centralisation
   cohort, 39.7 % of DDF facilities). Names were restricted to globally unique
   ones, so a wrong-dam join is excluded — but the coordinate/vintage caveats in
   the QA/QC known-issue register still apply.
5. **Elevation is a proxy.** `config/nid_manifest.csv` has `elevation_m = NA` for
   all 73,303 rows, so the elevation stratum uses the nearest GHCN-D station's
   elevation. It is used to assign a sampling band and for one exploratory
   correlation, and **never** in any comparison arithmetic.
6. **Both sides are point depths**, no areal reduction, and Atlas 14 stops at
   1000 yr — the fleet's 2,000–10,000-yr estimates have no benchmark here.
7. **Neither product is truth.** Atlas 14 is itself a regional L-moments analysis
   with its own vintage, station set and regionalisation choices. A difference is
   a difference, not an error in our number.

---

## 6. Running the full sample when the fleet completes

Prerequisites: fleet at 100 %, the QA/QC integrity layer green on the completed
ledger, and the release assets refreshed.

```bash
# 0. Always first: offline parser test, no network
python analysis/b1_atlas14_sampler.py selftest

# 1. Re-probe coverage (volumes and versions do change between runs)
python analysis/b1_atlas14_sampler.py coverage --per-state 2

# 2. Draw the stratified frame against the COMPLETED fleet.
#    Strata = coverage/volume x climate region x elevation band; allocation is
#    proportional to sqrt(stratum size) with a floor of 3, plus ALL BOR-overlap
#    dams as a census. --n is the target size.
python analysis/b1_atlas14_sampler.py frame --n 4000

# 3. Fetch, politely and resumably. Run it as many times as you like; it never
#    re-requests a (facility, series) already in the ledger. ~2.6 s/request.
python analysis/b1_atlas14_sampler.py fetch --max 500          # repeat
#    ...or, to halve the traffic, fetch only the like-for-like series:
python analysis/b1_atlas14_sampler.py fetch --max 500 --series ams

# 4. Re-run the ground-truthing on the NEW sample (do not inherit this pilot's)
python analysis/b1_atlas14_sampler.py verify --n 30 --series ams --grids \
       --grid-regions inw,mw,orb,tx,se,ne,sw

# 5. The Atlas-2 PNW stratum
python analysis/b1_atlas14_sampler.py atlas2 --unit-check

# 6. Statistics, decomposition and figures
python analysis/b1_atlas14_sampler.py compare --series ams
```

**Cost.** At the default 2 s + jitter, one series over a 4,000-dam frame is
~8,700 s ≈ **2.5 h** of wall-clock; both series ≈ 5 h. Split it across
invocations with `--max`; the ledger makes that free. Do not lower `--sleep`.
Budget a further ~15 min and ~150 MB for the published grids if `--grids` covers
many regions.

**Then, and only then**, promote the results into
`docs/analysis/atlas14_comparison.md` (the B1 artifact named in the plan) and
leave this document as the pilot and endpoint record. The full run must clear
QA/QC §E before publication: pinned input hashes recorded, an independent pass
attempting to refute the headline claim, known-issue propagation, and the
public/private boundary check.

### Where the outputs live

| Path | Tracked? | What |
|---|---|---|
| `data/atlas14/cache/` | no | every raw PFDS response, verbatim |
| `data/atlas14/ledger.csv` | no | resumable fetch ledger, one row per (facility, series) |
| `data/atlas14/verify_ledger.csv` | no | every ground-truthing check |
| `data/atlas14/grids/`, `data/atlas14/fleet_cache/` | no | downloaded NOAA grids; fleet release assets |
| `data/atlas14/summary/*.csv` | **yes** | coverage probe, frame allocation, verification record, comparison tables, decomposition |
| `data/atlas14/summary/full_sample_frame.csv` | no | ~1 MB and only valid against the fleet snapshot it was drawn from; regenerate with `frame` |
| `docs/analysis/figures/b1_*.png` | **yes** | figures |
