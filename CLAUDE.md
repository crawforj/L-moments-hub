# CLAUDE.md — orientation & next steps for this repo

This file orients a fresh Claude Code session (e.g. on desktop) taking over this
work. Read `docs/PLAN.md` for the full design and `DATA_SOURCES.md` for data
provenance and the **data-review requirements**.

## What this project is

Regional precipitation-frequency analysis by **L-moments** (Hosking & Wallis
1997), in R. Primary test site **Como Dam, Montana**; portable to any basin via
one YAML config. Scaled from Como → the **308-dam Bureau of Reclamation fleet**
(`run_batch.R`, `config/facilities_BOR.csv`) → the **full National Inventory of
Dams, 73,303 dams** (`run_nid_tranche.R`, `config/nid_manifest.csv`). Being
handed off to Reclamation flood-hydrology experts as a research/triage tool.

### NID full-fleet run (resumable, nightly)

`run_nid_tranche.R` processes the NID in tranches (largest dams first), skipping
any facility already in the committed ledger `data/nid_progress/completed_ids.csv`
and folding results into cumulative CSVs there + extending the committed GHCN
cache. It is **resumable across ephemeral sessions**: a nightly cron
(`create_trigger`, fires ~07:00 UTC) spins up a fresh session, rebuilds R per the
env note below, loops tranches committing after each, and pushes to
`claude/autonomous-dev-qflag-elevation`. Env knobs: `LMC_TRANCHE` (default 400),
`LMC_CORES`. Do a small batch with `LMC_TRANCHE=150 Rscript run_nid_tranche.R`.

**Git LFS note:** the growing GHCN cache is committed as **regular** Git objects,
not LFS — this environment blocks `lfs.github.com`. Convert later from an
unrestricted env (see `DATA_SOURCES.md` §2b). Do not attempt LFS here.

## Current state (working & pushed)

- Full pipeline `R/00..11` runs end-to-end: GHCN acquisition (with offline
  synthetic fallback), seasonal windowing (default **full calendar year**; a
  season can be configured for season-specific studies), L-moments,
  discordancy screening, iterative heterogeneity-based region definition,
  distribution selection (ratio diagram + Z-stat), index-flood estimation to the
  **10,000-yr** return period, Monte-Carlo bounds, maps, plots, CSV deliverables,
  an HTML audit report, and a provenance manifest.
- **Validated:** `Rscript run_golden.R` → ALL PASS (recovers a known GEV growth
  curve; auto-selects GEV; Cascades benchmark anchor). `Rscript run_tests.R` →
  ALL PASS. `Rscript validate_reference.R` → ALL PASS (reproduces the Hosking &
  Wallis Appalach/Cascades textbook findings, and confirms the index-flood
  scaling equals an independent base-`lmom` hand-calc to 0.000%). See
  `docs/VALIDATION.md`. `Rscript run_analysis.R config/como.yml` produces all
  deliverables.
- GHCN inventory caching + candidate discovery, parallel batch (`LMC_CORES`), and
  a cross-facility prefetch are implemented.
- **Como has been run on REAL GHCN data** (not just synthetic): the default
  `ghcn_base` is the AWS Open-Data S3 mirror (`noaa-ghcn-pds.s3.amazonaws.com`),
  reachable where `www.ncei.noaa.gov` is blocked. Real Como region: homogeneous
  (~36–41 stations, H1 &lt; 1), 24h 100-yr ≈ 60 mm / 10,000-yr ≈ 93 mm, 72h
  100-yr ≈ 89 mm / 10,000-yr ≈ 179 mm (all-year AMS). Still needs the human
  review + sign-off in `docs/audit_guide.md` before engineering use.
- **Environment note:** on a fresh cloud sandbox, install R with
  `apt-get install -y r-base-core gfortran r-cran-{yaml,jsonlite,ggplot2,sf,maps,testthat}`
  and build `lmom`/`lmomRFA` from the GitHub CRAN mirrors
  (`git clone https://github.com/cran/lmom && R CMD INSTALL lmom`, same for
  `lmomRFA`). CRAN itself is blocked; GitHub and the AWS S3 GHCN mirror are not.

## Environment setup (desktop, networked)

```bash
Rscript -e 'install.packages(c("lmom","lmomRFA","yaml","jsonlite","ggplot2","sf","maps"))'
Rscript run_golden.R      # expect ALL PASS
Rscript run_tests.R       # expect 30/30
```
If CRAN is restricted, see `docs/users_guide.md` §1 (GitHub CRAN mirrors +
`gfortran`).

## Next steps (priority order)

1. **Make the repo public** if desired — GitHub → Settings → General → Danger
   Zone → Change visibility. (The cloud session could not do this; no repo-admin.)
2. **Validate Como on REAL data — DONE (ran on real GHCN via the S3 mirror);
   still needs human sign-off.** `Rscript run_analysis.R config/como.yml`
   produces `outputs/report_COMO_DAM.html` from real observations. Remaining:
   confirm the exact dam coordinates, review the region map / homogeneity log,
   and sign off per `docs/audit_guide.md`. (Consider whether the ~110 km /
   756–2515 m region should be tightened for a valley-specific estimate, and
   note the 72h tail is GLO-driven — sensitivity-check GEV/PE3 at the 10,000-yr
   extrapolation.)
3. **Review the data sources** (`DATA_SOURCES.md`): 
   - Re-pull the **dam inventory** from the current NID
     (`https://nid.sec.usace.army.mil`) and/or Reclamation RISE
     (`https://data.usbr.gov`); reconcile coordinates/ownership in
     `config/facilities_BOR.csv`.
   - **Add ground elevations** (the NID mirror has none). `enrich_elevations()`
     is now built (`R/functions.R`): fills missing `elevation_m` from a DEM via
     the `elevatr` package — enable in the batch with `LMC_ENRICH_ELEV=1`
     (needs `elevatr` + network; safe no-op offline). Or set the fleet
     `index_flood.method: "nearest"`. Either way the pipeline no longer crashes
     on blank elevations (the regression method falls back to the regional mean).
   - ~~Consider enabling GHCN quality-flag (QFLAG) screening~~ **DONE** —
     `screen_qflag()` in `R/functions.R` NA-outs failed-QA observations on both
     the GHCN download and local-CSV paths; config `data.qflag_screen` (default
     true) / `data.qflag_keep`; covered by `tests/testthat/test-ghcn.R`.
4. **Pilot batch** — a ready-made 8-dam manifest is provided in
   **`config/pilot.csv`** (Grand Coulee, Hungry Horse, Shasta, Hoover, Glen Canyon,
   Flaming Gorge, Elephant Butte, Owyhee — spanning Pacific NW, California, desert
   Southwest, and Rocky Mountain regimes). Run
   `LMC_CORES=8 Rscript run_batch.R --manifest config/pilot.csv`, then review each
   region map and homogeneity history; tune `search_radius_km`, `elevation_band_m`,
   and `season` as needed. (Elevations are blank pending DEM enrichment; index-flood
   falls back to the regional mean until then, or set `index_flood.method: "nearest"`.)
   **The batch machinery now runs end-to-end OFFLINE** (all 8 pilot facilities:
   8 ok, 0 failed): the synthetic fallback is site-centered and isolated per
   facility under `data/synthetic/<id>/`, so you can dry-run the whole fleet
   pipeline before wiring real GHCN data. (Offline results are SYNTHETIC — for
   machinery validation only, never engineering use.)
5. **Full fleet:** `LMC_CORES=8 Rscript run_batch.R --manifest config/facilities_BOR.csv`.
   Results collect in `outputs/batch/`. **The batch now auto-writes
   `outputs/batch/batch_diagnostics.csv`** (one row per facility-duration with
   H1, chosen distribution, `|Z|`, and a `needs_review` flag) and prints the
   flagged list — triage the facilities flagged *heterogeneous* (H1 ≥ 2) or with
   chosen `|Z| > 1.64` for manual region revision.
   Expected runtime: compute ~15–30 s/facility; wall-clock dominated by first-time
   GHCN downloads (cached + prefetched, so re-runs are fast).

## Ground rules

- **Do not use synthetic-demo or unverified-inventory results for engineering
  decisions** — both are flagged in `DATA_SOURCES.md` and must be reviewed first.
- Keep configs ASCII; the pipeline forces a UTF-8 locale at startup.
- After any environment/package change, re-run `run_golden.R` and `run_tests.R`.
- Generated `outputs/` and downloaded `data/` are git-ignored; `golden/` is frozen
  on purpose (regression anchor).
