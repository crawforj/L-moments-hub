# CLAUDE.md — orientation & next steps for this repo

This file orients a fresh Claude Code session (e.g. on desktop) taking over this
work. Read `docs/PLAN.md` for the full design, `DATA_SOURCES.md` for data
provenance and the **data-review requirements**, and `docs/batch_runs_guide.md`
before running or resuming any large batch — it covers the resumable ledger,
running unattended, and (importantly) a real incident worth reading before you
repeat it.

## What this project is

Regional precipitation-frequency analysis by **L-moments** (Hosking & Wallis
1997), in R. Primary test site **Como Dam, Montana**; portable to any basin via
one YAML config. Scaled from Como → the **308-dam Bureau of Reclamation fleet**
(`run_batch.R`, `config/facilities_BOR.csv`) → the **full National Inventory of
Dams, 73,303 dams** (`run_nid_tranche.R`, `config/nid_manifest.csv`). Being
handed off to Reclamation flood-hydrology experts as a research/triage tool —
and actively getting their feedback (see "Reclamation review" below).

### NID full-fleet run — TWO resumable paths, same ledger

`run_nid_tranche.R` processes the NID in tranches (largest dams first), skipping
any facility already in the committed ledger `data/nid_progress/completed_ids.csv`
and folding results into cumulative CSVs there + extending the committed GHCN
cache. It is **resumable across ephemeral sessions**, and now runs from two
places:

1. **Nightly cloud cron** (`create_trigger`, fires ~07:00 UTC), pushing to
   `claude/autonomous-dev-qflag-elevation`, merged to `main` via PR when ready.
2. **Desktop ad hoc** (`run_ad_hoc_tranches.ps1`, Windows), for pushing through
   a lot of the fleet in one sitting on a machine that isn't network-restricted.
   Pushes to `claude/desktop-nid-ad-hoc`. **Read `docs/batch_runs_guide.md`
   before running this** — it has the pre-flight checklist and the synthetic-
   fallback incident writeup.

Env knobs: `LMC_TRANCHE` (default 400; the ad hoc script defaults to 300),
`LMC_CORES`. **`LMC_CORES` does nothing on Windows** — `run_batch()`'s
parallelism needs `fork()`, unavailable on Windows, so it silently falls back
to serial (~15–30s/facility). Real speedup only on Mac/Linux.

**Git LFS note:** the GHCN cache (`data/ghcn_prcp_cache/`, `data/ghcn_inventory/`)
is still committed as regular Git objects (~220MB and growing). A local desktop
*can* reach `lfs.github.com` (unlike the original cloud sandbox that built this
repo), so LFS tracking was tried 2026-08-11 — reverted for now after it left
already-committed files showing as perpetually "modified" (a filter-diff
artifact, not real changes); a proper `git lfs migrate import` + force-push is
still the right fix, just deserves its own deliberate pass. See `DATA_SOURCES.md`
§2c.

## Current state (working & pushed)

- Full pipeline `R/00..11` runs end-to-end: GHCN acquisition, seasonal
  windowing (default **full calendar year**), L-moments, discordancy
  screening, iterative heterogeneity-based region definition, distribution
  selection (ratio diagram + Z-stat), index-flood estimation to the
  **10,000-yr** return period, Monte-Carlo bounds, maps, plots, CSV
  deliverables, an HTML audit report, and a provenance manifest.
- **Validated:** `Rscript run_golden.R` → ALL PASS. `Rscript run_tests.R` →
  **80/80 PASS** (grew from an original 30 as region/ARF/fleet-table work
  landed — exact count depends on branch; `claude/desktop-nid-ad-hoc` is 80).
  `Rscript validate_reference.R` → ALL PASS. See `docs/VALIDATION.md`.
- **Real GHCN data, confirmed current**: the AWS S3 mirror
  (`noaa-ghcn-pds.s3.amazonaws.com`) serves observations through days-ago, not
  a stale snapshot — spot-checked 2026-08-11. The local per-station cache
  never auto-refreshes once downloaded, but this doesn't affect results: any
  year under 90% seasonal completeness (`min_year_completeness`) is dropped
  from the AMS anyway, so a partially-elapsed current year never contaminates
  the statistics.
- **Dam inventory refreshed from the LIVE NID** (2026-08-11, `refresh_nid_live.R`
  — see `DATA_SOURCES.md` §2b): USACE's NID ESRI FeatureServer is public, no
  auth, reachable from a desktop. 285/308 (BOR) and 66,350/73,303 (full)
  facility_ids matched and refreshed (coordinates/river/storage/drainage
  area); caught real errors (e.g. several Oregon dams off by ~700km in the old
  2013 mirror). Ground elevation is still absent from NID entirely (not a
  mirror-staleness issue) — DEM enrichment (`enrich_elevations()`) remains the
  path.
- **Fleet-wide analysis tables are now centrally committed**, not just local:
  `data/nid_progress/{stations_used,stations_removed,regional_lmoments,gof,
  growth_curve}.csv` fold in the same resumable way as the original DDF/
  diagnostics/tail-sensitivity CSVs (`collect_fleet_tables()` in
  `R/functions.R`). See `docs/OUTPUT_DATA_DICTIONARY.md`.
- **`data.use_local_fallback` must be `false` for any run whose results might
  be trusted.** Left `true` (the old default), a GHCN download failure
  silently substitutes SYNTHETIC data and still records the facility as `ok` —
  this actually happened (~110 + ~99 facilities across two incidents,
  2026-08-11, cleaned up). `config/como.yml`'s template now ships `false`.
  Full writeup: `docs/batch_runs_guide.md`, "Never run unattended with
  synthetic fallback on."
- `region.elevation_band_m` was `[600, 2600]` (fine for Como's ~1240m
  Montana site) and, copied unchanged into every fleet facility's config,
  silently zeroed the candidate station pool for any low-elevation facility —
  confirmed **87.5% of fleet failures** were this, not real data gaps.
  Widened to `[-100, 6200]`; Como re-validated homogeneous under the new band.
- GHCN inventory caching + candidate discovery, parallel batch (`LMC_CORES`,
  Mac/Linux only), and a cross-facility prefetch are implemented — the
  prefetch now prints a progress heartbeat (used to go silent for up to an
  hour on a large tranche, looked stalled).
- **Environment note:** on a fresh cloud sandbox, install R with
  `apt-get install -y r-base-core gfortran r-cran-{yaml,jsonlite,ggplot2,sf,maps,testthat}`
  and build `lmom`/`lmomRFA` from the GitHub CRAN mirrors
  (`git clone https://github.com/cran/lmom && R CMD INSTALL lmom`, same for
  `lmomRFA`). CRAN itself is blocked there; GitHub and the AWS S3 GHCN mirror
  are not. **A desktop machine may have none of these restrictions** — confirm
  before assuming a limitation from the original build environment still
  applies (it's how the NID refresh and LFS investigation above happened).

## Environment setup (desktop, networked)

```bash
Rscript -e 'install.packages(c("lmom","lmomRFA","yaml","jsonlite","ggplot2","sf","maps","testthat"))'
Rscript run_golden.R      # expect ALL PASS
Rscript run_tests.R       # expect 80/80 (this branch)
```
If CRAN is restricted, see `docs/users_guide.md` §1 (GitHub CRAN mirrors +
`gfortran`).

## Reclamation review

The repo was shared with Bureau of Reclamation staff (Amanda Stone,
astone@usbr.gov) 2026-08-11. Feedback so far, and status:

- Region-building should offer more than circular radius (subjective/
  covariate, objective/L-CV threshold, cluster analysis) — **cluster analysis
  implemented** (H&W sec. 9.2.3 via `lmomRFA::cluagg/cluinf/clukm`,
  `region.method: cluster`). PR #2 **merged to `main` 2026-08-11.** Subjective/
  objective partitioning deferred pending expert-set thresholds.
- Does the pipeline develop an at-site mean (ASM) and apply an areal
  reduction factor (ARF)? ASM was already computed internally, now exposed;
  ARF added (Leclerc & Schaake 1972 default, swappable). Same PR #2, same
  merge status.
- **Confirmed 2026-08-13, still true: none of this has reached the active
  fleet branch.** `claude/desktop-nid-ad-hoc` (where the NID fleet batch and
  the completed 308-facility BOR batch have been running) branched off
  *before* PR #2 merged and was never rebased — every fleet/BOR result to
  date used only the original circular region method, with no ASM/ARF. `main`
  has the improvement; the branch actually doing the work doesn't. Rebasing
  mid-fleet-run needs a deliberate decision (re-scoring already-completed
  facilities under a new default is its own pass, not a silent side effect
  of merging — see the original region-methods plan) — flagged, not done.
- **New 2026-08-13**, answering a direct question about digital-vs-published
  data quality: `qc_ghcnm_crosscheck.R` reconciles this project's GHCN-Daily
  monthly totals against GHCN-Monthly (independently-sourced station-months
  only) and surfaces GHCN-Monthly's own institutional QC flags. See
  `DATA_SOURCES.md` §1 and the script's own header comment.

## Next steps (priority order)

1. **Reconcile `main` (has PR #2's region-clustering/ASM/ARF) with
   `claude/desktop-nid-ad-hoc`** (has the fleet-run fixes: synthetic-fallback
   block, elevation-band widening, live NID refresh, fleet-wide tables, LFS
   migration). PR #2 itself merged 2026-08-11 -- confirmed 2026-08-13 the
   fleet branch still never got it. Rebasing the fleet branch onto main is
   the mechanical part; the real decision is whether/when to re-score
   already-completed facilities under the new region method (a deliberate
   `--rebuild-region` pass, not automatic).
2. **Make the repo public** if desired — GitHub → Settings → General → Danger
   Zone → Change visibility. (Already public as of the Reclamation outreach.)
3. **Ground elevations** — still the one gap no data source fixes: neither the
   old mirror nor the live NID carries site MSL elevation. `enrich_elevations()`
   (`R/functions.R`) fills it from a DEM via `elevatr` (`LMC_ENRICH_ELEV=1`,
   needs network; safe no-op offline). Until then, `index_flood.method:
   "nearest"` avoids depending on it.
4. **~25,000 live NID facility_ids aren't in our manifest** (`refresh_nid_live.R`
   reports, doesn't auto-add — see `DATA_SOURCES.md` §2b). Deciding whether to
   expand fleet scope is a separate call, not yet made.
5. **Full fleet, resumable:** `Rscript run_nid_tranche.R` (or
   `run_ad_hoc_tranches.ps1` for an unattended stretch) — see
   `docs/batch_runs_guide.md` for the full how-to, including the pre-flight
   checklist. As of 2026-08-11: ~650-700/73,303 attempted (check
   `data/nid_progress/progress.md` for the current number — it moves fast
   during an active run).

## Ground rules

- **Do not use synthetic-demo or unverified-inventory results for engineering
  decisions** — both are flagged in `DATA_SOURCES.md` and must be reviewed first.
- **`data.use_local_fallback` must be `false`** for any batch run whose results
  might be trusted or reviewed — see "Current state" above. This is not
  optional; it already caused a real, cleaned-up incident once.
- Keep configs ASCII; the pipeline forces a UTF-8 locale at startup.
- After any environment/package change, re-run `run_golden.R` and `run_tests.R`.
- Generated `outputs/` and downloaded `data/raw/`, `data/synthetic/` are
  git-ignored; `golden/` is frozen on purpose (regression anchor);
  `data/nid_progress/`, `data/ghcn_prcp_cache/`, `data/ghcn_inventory/` ARE
  committed (the resumable ledger + reusable cache).
