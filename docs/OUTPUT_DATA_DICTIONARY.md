# Output data dictionary

Column definitions for every CSV the pipeline writes, so a reviewer can read the
results without the code. Units are millimetres (mm) for depths unless noted.
Method and symbol definitions: [`METHODS.md`](METHODS.md). All depths are **point**
precipitation with the fixed-interval factor applied and **no** areal reduction.

Fleet runs write these to `outputs/batch/` (single run) and accumulate them in
`data/nid_progress/` (resumable NID run). Curated copies are in
[`example_outputs/fleet_308dam/`](example_outputs/fleet_308dam/).

---

## `all_facilities_DDF.csv` — depth–duration–frequency, all facilities

One row per facility × duration × return period.

| Column | Meaning |
|---|---|
| `site` | facility name |
| `duration` | duration label (`24h`, `72h`) |
| `return_period_yr` | return period `T` in years |
| `AEP` | annual exceedance probability = 1/`T` |
| `depth_mm` | estimated precipitation depth (the central estimate) |
| `depth_lo_mm` | lower Monte-Carlo bound (at `conf`, default 90%) |
| `depth_hi_mm` | upper Monte-Carlo bound |
| `rel_rmse` | relative RMSE of the quantile (Monte-Carlo) — a per-point precision measure |

The per-facility file `quantiles_DDF_<id>.csv` has the **same columns** for one dam.

## `batch_diagnostics.csv` — per-facility triage (read this to prioritise review)

One row per facility × duration.

| Column | Meaning |
|---|---|
| `site` | facility name |
| `site_id` | facility / NID ID |
| `duration` | duration label |
| `n_stations` | gauges in the final homogeneous region |
| `H1` | heterogeneity `H₁` (`<1` homogeneous, `1–2` review, `≥2` heterogeneous) |
| `homog_status` | text interpretation of `H₁` |
| `chosen_dist` | selected distribution (GLO/GEV/GNO/PE3/GPA) |
| `chosen_absZ` | `|Z|` of the chosen distribution (`≤1.645` = acceptable fit) |
| `Z_acceptable` | TRUE if `chosen_absZ ≤ 1.645` |
| `selection_source` | how it was chosen: `auto`, `config_override`, or `expert_review` |
| `reviewer` | expert who set an `expert_review` choice (else blank) |
| `runner_up` | second-best distribution by `|Z|` |
| `runner_up_absZ` | `|Z|` of the runner-up |
| `z_margin` | `runner_up_absZ − chosen_absZ` (small = a close call worth expert eyes) |
| `review_recommended` | TRUE if the choice is a close call or a poor fit (expert should confirm) |
| `depth_10k_mm` | 10,000-yr depth under the **chosen** distribution |
| `tail_min_10k_mm` | smallest 10,000-yr depth across **all** candidate distributions |
| `tail_max_10k_mm` | largest 10,000-yr depth across all candidates |
| `tail_spread_pct` | `100 × (tail_max − tail_min) / depth_10k` — extreme-tail model sensitivity |
| `needs_review` | TRUE if `H₁ ≥ 2` **or** `|Z| > 1.645` — the facility fails an automatic quality gate |

## `batch_status.csv` — success/failure per facility

One row per facility attempted.

| Column | Meaning |
|---|---|
| `config` | path to the facility's generated config (its basename is the facility ID) |
| `site` | facility name (`NA` if it failed before naming) |
| `ok` | TRUE = analysed successfully; FALSE = failed |
| `message` | `ok`, or the failure reason (e.g. "Need at least 5 stations to form a region; have 3") |

## `tail_sensitivity.csv` — distribution-choice sensitivity at the extreme tail

One row per facility × duration × candidate distribution.

| Column | Meaning |
|---|---|
| `site` | facility name |
| `site_id` | facility / NID ID |
| `duration` | duration label |
| `dist` | candidate distribution (GLO/GEV/GNO/PE3/GPA) |
| `T` | return period (years); the tail table is reported at `T = 10000` |
| `growth_factor` | dimensionless regional growth factor `q(F)` under this distribution |
| `depth_mm` | `index_flood × growth_factor` — the depth if this distribution were chosen |

Use this to see how much the rare-event depth hinges on the distribution choice.

## `data/nid_progress/completed_ids.csv` — resumable ledger (NID run)

One row per facility **attempted** across all tranches (so it is never retried).

| Column | Meaning |
|---|---|
| `facility_id` | NID ID |
| `name` | dam name |
| `ok` | TRUE = analysed successfully; FALSE = failed (recorded so it is skipped, not retried) |

## Per-facility station lists

`stations_used_<id>_<dur>.csv` (and `stations_removed_<id>_<dur>.csv`, which adds
a `reason` column):

| Column | Meaning |
|---|---|
| `station_id` | GHCN station ID |
| `name` | GHCN station name |
| `lat`, `lon` | station coordinates (decimal degrees) |
| `elev_m` | station elevation (m) |
| `distance_km` | great-circle distance to the dam |
| `n_years` | valid annual maxima contributed |
| `mean_mm` | at-site mean annual maximum (the site index flood) |
| `reason` | *(removed list only)* why the station was dropped (geography, short record, discordant, etc.) |

## Provenance

`run_manifest_<id>.json` records the config used, code/pipeline state, RNG seed,
station disposition, and timestamps for exact reproduction. See
[`audit_guide.md`](audit_guide.md).
