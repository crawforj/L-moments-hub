# Running large batches — a practical guide

This is the "how do I actually run a lot of dams" doc. For what the pipeline
computes and why, see `PLAN.md` and `METHODS.md`; for what the output columns
mean, see `OUTPUT_DATA_DICTIONARY.md`; for data provenance and known
limitations, see `../DATA_SOURCES.md` and `ASSUMPTIONS_AND_LIMITATIONS.md`.
This doc assumes you've already done the one-time setup in `users_guide.md`
(R packages installed, `run_golden.R` / `run_tests.R` passing).

## The three entry points

| Script | Use for | Resumable? |
|---|---|---|
| `run_analysis.R config/<site>.yml` | One facility | No — single run |
| `run_batch.R --manifest <csv>` | A specific list of facilities (a pilot set, a state, a one-off comparison) | No — runs the whole manifest every time |
| `run_nid_tranche.R` | The full 73,303-dam NID fleet | **Yes** — the whole point of this script |

Three manifests already exist: `config/pilot.csv` (8 dams, spans PNW/CA/desert
SW/Rocky Mountain regimes — the fast sanity check), `config/facilities_BOR.csv`
(308 Reclamation-owned dams), `config/nid_manifest.csv` (all 73,303, sorted by
NID storage descending — largest/highest-consequence dams first).

```bash
Rscript run_batch.R --manifest config/pilot.csv          # ~8 facilities, a few minutes
Rscript run_batch.R --manifest config/facilities_BOR.csv # ~308 facilities
Rscript run_nid_tranche.R                                 # next 400 (default) of the full 73,303
```

Any manifest CSV needs `facility_id, name, latitude, longitude, elevation_m`.
Optional columns, read only if present (see `run_batch.R`'s
`gen_configs_from_manifest()`): `search_radius_km`, `region_method` (if
`R/region_methods.R` is on this branch), `drainage_area_mi2` (populated by
`enrich_drainage_area.R` for the BOR/NID manifests — see `../DATA_SOURCES.md`).

## The resumable ledger (`run_nid_tranche.R`)

This is the one you'll actually use for fleet-scale work. It:

1. Reads `data/nid_progress/completed_ids.csv` — every facility ever
   **attempted** (ok or failed), and **never retries one already in there**.
2. Takes the next `LMC_TRANCHE` (env var, default 400) not-yet-done facilities
   off the top of the manifest (largest-storage-first).
3. Runs them, folds the results into the cumulative CSVs under
   `data/nid_progress/` (de-duplicated by natural key, so re-running is always
   safe), and rewrites `progress.md` with a running tally.

```bash
LMC_TRANCHE=150 Rscript run_nid_tranche.R          # a small batch
LMC_TRANCHE=400 LMC_CORES=8 Rscript run_nid_tranche.R  # bigger, more cores (Mac/Linux)
```

**`LMC_CORES` does nothing on Windows.** `run_batch()` only parallelises via
`parallel::mclapply`, which needs `fork()` — unavailable on Windows, so it
silently falls back to serial (`.Platform$OS.type == "windows"` check in
`run_batch.R`). Budget ~15–30 s/facility serially; a 300-facility tranche is
roughly 1.5–3 hours. On Mac/Linux, `LMC_CORES` gives real wall-clock speedup.

## Running unattended (ad hoc, on a desktop)

The nightly cloud cron (see `CLAUDE.md`) is one way this fleet gets worked
through. The other is running it yourself, unattended, on a desktop for a few
hours or overnight. `run_ad_hoc_tranches.ps1` (repo root, Windows) does this:
loops `run_nid_tranche.R`, commits + pushes after every round, stops at a
configured time or when a `STOP_TRANCHES` sentinel file appears.

```powershell
powershell -ExecutionPolicy Bypass -File run_ad_hoc_tranches.ps1
powershell -ExecutionPolicy Bypass -File run_ad_hoc_tranches.ps1 -TrancheSize 150 -StopAt "18:00"
```

Launch it **detached** (a separate window, not tied to your terminal session)
so it survives you closing whatever you launched it from:

```powershell
Start-Process powershell.exe -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','run_ad_hoc_tranches.ps1' -WorkingDirectory (Get-Location)
```

To stop it early: close the window, or drop an empty file named
`STOP_TRANCHES` in the repo root (checked after each tranche finishes and
commits — it won't interrupt a tranche mid-run).

**Mac/Linux equivalent** (same idea, no `.ps1` needed):

```bash
while [ "$(date +%s)" -lt "$(date -d 'tomorrow 07:00' +%s)" ]; do
  LMC_TRANCHE=300 Rscript run_nid_tranche.R
  git add data/nid_progress/ data/ghcn_prcp_cache/
  git diff --cached --quiet || git commit -m "NID ad-hoc tranche" && git push
  [ -f STOP_TRANCHES ] && rm STOP_TRANCHES && break
done
```

### Before you walk away: a checklist

- [ ] **`data.use_local_fallback` is `false`** in whatever config template
  the manifest uses (see the next section — this bit us for real).
- [ ] `run_golden.R` and `run_tests.R` pass on the current code before you
  trust it to run unattended for hours.
- [ ] You're on a feature branch, not `main` — the loop commits every round;
  review before merging (see "Reviewing the results" below).
- [ ] The machine won't sleep: `powercfg /query SCHEME_CURRENT SUB_SLEEP
  STANDBYIDLE` — AC setting should be `0` (never). It stays plugged in.
- [ ] You know how to check it's alive: `Get-Process | Where
  ProcessName -match Rscript` should show CPU time climbing, not stuck at 0.

## Never run unattended with synthetic fallback on

This is the one real incident worth learning from. `config.data.source: "ghcn"`
has a fallback: if the GHCN download fails for a facility,
`acquire_station_data()` (in `R/functions.R`) generates a **SYNTHETIC**
site-centered dataset instead — controlled by `data.use_local_fallback`
(default was `true`). The pipeline still runs to completion and the facility
is still recorded as `ok` in the ledger, **indistinguishable from a real
result** unless you go looking.

During an early overnight run, ~110 of 753 attempted facilities (~15%) did
exactly this — undetected until someone asked "why did some of these look
like they ran on fake data?" `config/como.yml`'s template now ships with
`use_local_fallback: false`, so a GHCN failure correctly **fails the
facility** (visible in `batch_status.csv` / re-attempted next tranche)
instead of faking a result. `run_ad_hoc_tranches.ps1` warns you at startup if
the config it's about to use still has it on.

**If you ever suspect this happened** (or inherit a ledger you don't trust):

```r
# From the repo root, in R:
synth_dirs <- list.files("data/synthetic")               # facilities that fell back
ledger <- read.csv("data/nid_progress/completed_ids.csv")
contaminated <- intersect(synth_dirs, ledger$facility_id) # actually committed as "ok"
```

Cross-reference against the ledger, not just `data/synthetic/` alone — that
directory also picks up facilities from a tranche that was killed mid-run and
never committed (harmless, `data/synthetic/` is gitignored, nothing to clean
up in git for those). For genuinely contaminated, committed facilities: strip
their `facility_id`s from `completed_ids.csv` and their rows from the four
cumulative tables that carry a `site`/`site_id` key
(`batch_diagnostics.csv`, `tail_sensitivity.csv` by `site_id`;
`all_facilities_DDF.csv` by `site` name — watch for name collisions between a
contaminated and a clean facility before filtering by name alone). They'll be
correctly re-attempted the next tranche.

## Interrupting a run safely

`run_nid_tranche.R` only writes/commits results at the very end of a full
tranche — nothing is folded into the ledger mid-run. **Killing the Rscript
process at any point loses only that tranche's in-progress compute, never
already-committed data**, and the next tranche will simply re-select the same
facilities (since the ledger was never updated). This is exactly why it's
safe to interrupt a run to pick up a code/config fix and restart — no
git-level cleanup needed for the ledger itself.

## Reviewing and merging the results

The ad-hoc loop commits directly to whatever branch you point it at — it does
**not** push to `main`. Treat it like any other branch: when you're happy with
a stretch of progress, open a PR (`gh pr create`) for review before merging,
same as the code-change PRs in this repo's history. Nothing about running the
batch requires merging immediately or at all — the branch is safe to leave
open and keep extending.

## Analyzing the results afterward

Everything you need for fleet-wide analysis is centrally committed as plain
CSVs under `data/nid_progress/` (not LFS — clonable and analyzable with
nothing but a CSV reader):

- `all_facilities_DDF.csv` — headline depths, every facility × duration ×
  return period.
- `batch_diagnostics.csv` — **start here for triage**: `needs_review == TRUE`
  flags a facility whose region is heterogeneous (H1 ≥ 2) or whose
  distribution fit is poor (|Z| > 1.645).
- `tail_sensitivity.csv` — how much the 10,000-yr depth depends on which
  distribution was chosen.
- `stations_used.csv` / `stations_removed.csv` — every station's disposition,
  fleet-wide (which gauges get reused across regions, why stations were
  dropped).
- `regional_lmoments.csv`, `gof.csv`, `growth_curve.csv` — the per-station and
  per-distribution detail behind the headline numbers.

Full column definitions: `OUTPUT_DATA_DICTIONARY.md`.

**What's NOT centrally stored**: the rendered HTML audit report and PNG region
map/plots per facility — those stay in the local (gitignored) `outputs/`
directory on whichever machine ran the batch (~35GB extrapolated to the full
fleet; a deliberate call to avoid that cost on a public repo — see git log
around 2026-08-11 for the reasoning). To pull up a specific dam's full visual
report on demand:

```bash
Rscript run_batch.R --manifest config/facilities_BOR.csv  # or a 1-row manifest
                                                             # for just that facility
Rscript run_analysis.R config/facilities/<FACILITY_ID>.yml
# -> outputs/report_<FACILITY_ID>.html, outputs/figures/<FACILITY_ID>_region_map.png
```

`config/facilities/` is regenerated from the manifest each time (gitignored),
so this is always available even though it isn't kept around by default.
