# User's Guide

Regional precipitation-frequency analysis by L-moments (Hosking & Wallis 1997).
This guide covers installation, configuration, running, interpreting the outputs,
switching basins, and the known caveats.

---

## 1. Installation

The pipeline needs R (>= 3.5) and these packages:

| Required | Optional (mapping/plots) |
|---|---|
| `lmom`, `lmomRFA`, `yaml`, `jsonlite` | `ggplot2`, `sf`, `maps`, `rnaturalearthdata` |

**Standard (networked) install:**
```r
install.packages(c("lmom","lmomRFA","yaml","jsonlite","ggplot2","sf","maps"))
```

**Offline / restricted networks.** This applied to the original cloud sandbox
this repo was built in (blocked CRAN, NOAA NCEI, and `.gov` hosts); a
networked desktop machine may have none of these restrictions — confirmed
2026-08-11 (CRAN, the GHCN S3 mirror, NOAA Atlas 14, and the live NID service
are all directly reachable from a normal desktop). Don't assume a limitation
below still applies before checking. Where CRAN *is* blocked but GitHub is reachable,
`lmom` and `lmomRFA` can be built from their public CRAN mirrors:
```bash
git clone --depth 1 https://github.com/cran/lmom     && R CMD INSTALL lmom
git clone --depth 1 https://github.com/cran/lmomRFA  && R CMD INSTALL lmomRFA
```
On Debian/Ubuntu the remaining packages are available as system binaries
(`apt-get install r-cran-yaml r-cran-jsonlite r-cran-ggplot2 r-cran-sf r-cran-maps`).
A Fortran compiler (`gfortran`) is required to build `lmom`.

The pipeline forces a UTF-8 locale at startup; no manual locale setup is needed.

---

## 2. Configuration

Everything basin-specific lives in one YAML file (`config/como.yml`). Key blocks:

- **`site`** — name, id (used in filenames), latitude, longitude, elevation_m.
- **`region`** — `search_radius_km`, `elevation_band_m`, `min_record_years`,
  `min_year_completeness`.
- **`durations`** — list of `{label, days, fixed_interval_factor}`. Defaults are
  24-hour (1-day, ×1.13) and 72-hour (3-day, ×1.03). The factor corrects fixed
  calendar-day totals toward true clock-hour depths (WMO-No.1045 / Hershfield).
- **`season`** — `start_month`/`end_month`; **default 1–12 (full calendar
  year = true annual maximum)**, which is what precipitation-frequency for
  spillway design needs. Restrict to a season (e.g. 4–7 for the Bitterroot
  snowmelt/rain-on-snow season) only for a season-specific study — it biases the
  estimates low. Wrap-around windows
  (e.g. 11–2) are supported.
- **`distributions`** — candidates for the *Z*-test; `distribution_override` forces
  a choice (`null` = automatic).
- **`return_periods`** — includes 10000 (AEP 1e-4).
- **`index_flood.method`** — `"regression"` (mean AMS ~ elevation) or `"nearest"`.
- **`uncertainty`** — `n_sim`, `conf` (bound level).
- **`data`** — `source` (`"ghcn"` auto-download or `"local"`),
  `use_local_fallback` (⚠️ **must be `false`** for any run whose results
  might be trusted — left `true`, a GHCN download failure silently
  substitutes synthetic data and still reports the facility as successful;
  see §7 and `docs/batch_runs_guide.md`), `local_format` (`"daily"` or
  `"ams"`), `local_dir`.
- **`seed`** — RNG seed for reproducible screening/simulation.

Keep configs ASCII to be safe on minimal hosts.

---

## 3. Running

```bash
Rscript run_golden.R                     # validate against known truth first
Rscript run_analysis.R config/como.yml   # the analysis
Rscript run_tests.R                      # unit + integration tests
```

**Data source.** With `data.source: "ghcn"` the pipeline downloads GHCN-Daily from
NOAA NCEI for the station inventory in `local_dir/stations.csv`. If NOAA is
unreachable (or `use_local_fallback: true` and no data are present), it generates a
**synthetic, clearly-labelled demo dataset** so the pipeline runs offline — those
results are for demonstration only. To use your own data, drop either daily files
(`<station_id>.csv` with `date,prcp`, plus `stations.csv`) or pre-built annual
maxima (`ams.csv` with `station_id,year,value`) into `local_dir` and set
`local_format` accordingly.

---

## 4. Outputs (in `outputs/`)

- `figures/<id>_region_map.png|pdf` — the region map.
- `figures/<id>_<dur>_lmoment_ratio_diagram.png` — L-moment ratio diagram.
- `figures/<id>_<dur>_growth_curve_fit.png` — station data vs candidate distributions.
- `figures/<id>_<dur>_ddf_with_bounds.png` — depth-frequency with uncertainty band.
- `tables/quantiles_DDF_<id>.csv` — headline depths by duration × return period, with bounds.
- `tables/stations_used_*` / `stations_removed_*` / `stations_master_*` — station lists.
- `tables/regional_Lmoments_*`, `gof_Zstatistic_*`, `growth_curve_*`, `homogeneity_history_*`.
- `report_<id>.html` — the human-review/audit report (open in a browser).
- `provenance/run_manifest_<id>.json`, `provenance/audit_log_<id>.txt` — reproducibility record.

---

## 5. Interpreting results

- **Region status** — `H1 < 1` homogeneous; `1–2` acceptably homogeneous (review);
  `≥ 2` heterogeneous (revise the region). The homogeneity history table shows each
  refinement step.
- **Distribution choice** — smallest `|Z|` (≤ 1.64 acceptable). The growth-curve
  plot shows how the candidates diverge in the tail — important at 10,000 yr.
- **Expert distribution review (optional override).** Automated runs
  **auto-select** the smallest-`|Z|` distribution. To override that with a
  reviewer's judgement for a facility, add a row to
  `config/distribution_review.csv` (`facility_id, duration, distribution,
  reviewer, date, notes`; blank `duration` = all durations). Precedence is
  **expert review > `distribution_override` in the config > automatic**. The
  batch worklist (`outputs/batch/batch_diagnostics.csv` and the run log) shows
  `selection_source`, the runner-up, the `z_margin`, and a `review_recommended`
  flag for auto picks that fit poorly or are a close call — the shortlist an
  expert should look at first. Leave the registry empty (header only) to
  auto-select everywhere.
- **Quantiles** — `depth_mm` with `depth_lo/hi` (Monte-Carlo band) and `rel_rmse`.
  The band widens at long return periods; treat the 10,000-yr value as uncertain.

---

## 6. Another basin, the BOR fleet, or the full NID

Copy `config/como.yml`, edit the `site` block, run `run_analysis.R config/yours.yml`.
For a specific list of facilities, list them in a manifest CSV (`facility_id,
name, latitude, longitude, elevation_m[, search_radius_km]`) and run
`Rscript run_batch.R --manifest config/yourlist.csv`. Results are collected in
`outputs/batch/` (`all_facilities_DDF.csv`, `batch_status.csv`,
`batch_diagnostics.csv`, `tail_sensitivity.csv`, and — as of 2026-08-11 —
`stations_used.csv`, `stations_removed.csv`, `regional_lmoments.csv`,
`gof.csv`, `growth_curve.csv`).

For the **full 73,303-dam NID fleet**, use `run_nid_tranche.R` instead of
`run_batch.R` directly — it's resumable (never recomputes a facility) and
folds every one of the files above into cumulative, centrally-committed
versions under `data/nid_progress/`. **Read
[`docs/batch_runs_guide.md`](batch_runs_guide.md) before running this at
scale** — it covers the resumable ledger in depth, running unattended
overnight, a pre-flight checklist, and a real incident (silent synthetic-data
fallback) worth knowing about before you repeat it. `refresh_nid_live.R`
(same doc) refreshes the dam manifests from the current, live NID.

**Parallelism.** `run_batch.R` fans out across cores with `parallel::mclapply`
(Unix/macOS; Windows runs serially). Control the core count with the `LMC_CORES`
environment variable, e.g. `LMC_CORES=8 Rscript run_batch.R --manifest ...`.
Per-facility errors are captured in `batch_status.csv` without aborting the batch.

**GHCN caching.** In `data.source: "ghcn"` mode the global station inventory
(`ghcnd-stations.txt` + `ghcnd-inventory.txt`) is downloaded once and cached
(parsed to `data/raw/ghcn/inventory_prcp.rds`); candidate stations are then chosen
from it by radius + elevation band + record length (capped at `region.max_stations`,
default 60). Per-station daily files are cached under `data/raw/ghcn/by_station/`,
so nearby facilities reuse downloads. The batch pre-warms the shared inventory
cache once before fanning out. Point `data.ghcn_cache_dir` at a shared location to
reuse the cache across runs.

---

## 7. Caveats

- The 10,000-yr depth extrapolates far beyond the record; regional pooling extends
  the effective length but the tail is model-dependent — see the uncertainty band
  and the candidate-distribution comparison plot.
- GHCN daily totals are fixed calendar-day; the fixed-interval factors only
  approximate true 24/72-hr clock depths.
- The dam is ungauged; the index flood is transferred from regional gauges.
- **`data.use_local_fallback: true` silently fakes results on a GHCN
  failure** — the facility still reports `ok` in the batch/ledger, with no
  visible difference from a real result unless you check
  `data/synthetic/<id>/` for that facility. Set it `false` for anything that
  might be reviewed; this already caused a real incident at fleet scale (see
  `docs/batch_runs_guide.md`).
- Always run `run_golden.R` after changing the environment or packages.
