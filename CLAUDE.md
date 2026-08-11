# CLAUDE.md — orientation & next steps for this repo

This file orients a fresh Claude Code session (e.g. on desktop) taking over this
work. Read `docs/PLAN.md` for the full design and `DATA_SOURCES.md` for data
provenance and the **data-review requirements**.

## What this project is

Regional precipitation-frequency analysis by **L-moments** (Hosking & Wallis
1997), in R. Primary test site **Como Dam, Montana**; portable to any basin via
one YAML config, and built to scale to the **Bureau of Reclamation fleet**
(`run_batch.R`, `config/facilities_BOR.csv` — 308 BOR dams).

## Current state (working & pushed)

- Full pipeline `R/00..11` runs end-to-end: GHCN acquisition (with offline
  synthetic fallback), seasonal windowing (default **April–July**), L-moments,
  discordancy screening, iterative heterogeneity-based region definition,
  distribution selection (ratio diagram + Z-stat), index-flood estimation to the
  **10,000-yr** return period, Monte-Carlo bounds, maps, plots, CSV deliverables,
  an HTML audit report, and a provenance manifest.
- **Validated:** `Rscript run_golden.R` → ALL PASS (recovers a known GEV growth
  curve; auto-selects GEV; Cascades benchmark anchor). `Rscript run_tests.R` →
  30/30. `Rscript run_analysis.R config/como.yml` produces all deliverables.
- GHCN inventory caching + candidate discovery, parallel batch (`LMC_CORES`), and
  a cross-facility prefetch are implemented.
- **This cloud sandbox blocks NOAA NCEI and CRAN**, so all runs here used
  **synthetic** data and packages were built from the CRAN GitHub mirrors. On a
  networked desktop, real data and normal installs work.

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
2. **Validate Como on REAL data.** In `config/como.yml` keep `data.source: "ghcn"`,
   confirm the exact dam coordinates, run `Rscript run_analysis.R config/como.yml`,
   open `outputs/report_COMO_DAM.html`, and sign off per `docs/audit_guide.md`.
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
