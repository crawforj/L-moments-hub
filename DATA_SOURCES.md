# Data Sources &mdash; REVIEW REQUIRED

> **⚠️ Both the weather data and the dam-inventory data used by this project are
> UNVERIFIED and must be independently reviewed before any result is used for
> engineering or dam-safety decisions.** This section documents exactly what was
> used, its provenance, and its known limitations.

## 1. Weather / precipitation data (GHCN-Daily) — REVIEW REQUIRED

- **Source:** NOAA Global Historical Climatology Network &ndash; Daily
  (GHCN-Daily), element `PRCP`, at `data.ghcn_base`. **Default base is now the
  AWS Open-Data S3 mirror** (`noaa-ghcn-pds.s3.amazonaws.com`), which serves the
  identical NOAA data and is reachable in environments where `www.ncei.noaa.gov`
  is blocked; the NCEI base is still supported (the reader auto-detects the
  gzipped-headerless NCEI layout vs. the uncompressed-with-header S3 layout).
- **How it is used:** station discovery from the GHCN inventory by
  radius/elevation/record-length; daily totals aggregated to seasonal 1-day and
  3-day annual maxima with a fixed-interval correction.
- **Review items before operational use:**
  - Station record completeness and gaps (this pipeline applies a completeness
    gate). **GHCN quality-flag (QFLAG) screening is now implemented** — any
    observation with a non-blank QFLAG (failed a NOAA QA check) is treated as
    missing before the annual maxima are computed; toggle with
    `data.qflag_screen` (default `true`) and retain specific codes with
    `data.qflag_keep`. Confirm the retained/dropped flag set is appropriate for
    the region.
  - Fixed-interval correction factors (defaults ~1.13 for 1-day, ~1.03 for 3-day)
    should be confirmed for the region and gauge reporting times.
  - Trans-boundary / short-record stations, station moves, and unit consistency.
  - Whether daily-gauge maxima are adequate, or sub-daily/hourly data are needed.
- **Real data now runs in this environment** via the AWS S3 mirror above; Como
  was executed on real GHCN observations (a homogeneous ~36–41-station region,
  H1 &lt; 1, good-fitting distribution). Where no network is available the
  pipeline still falls back to a clearly-labelled **synthetic** dataset
  (`R/make_demo_data.R`); synthetic results are **not** valid for any real
  decision, and real results still require the review in this document plus the
  sign-off in `docs/audit_guide.md`.
- **Season matters:** the default annual-maximum window is the **full calendar
  year** (the true annual maximum). A seasonal window (e.g. April–July) biases
  precipitation-frequency estimates low — measured ~12–14% at 24h and up to
  ~54% at 72h for Como — so restrict the season only for a season-specific study.

## 2. Dam inventory / facility list (National Inventory of Dams) — REVIEW REQUIRED

- **File:** `config/facilities_BOR.csv` (Bureau of Reclamation-owned dams).
- **Provenance:** filtered from a **third-party GitHub mirror** of the USACE
  National Inventory of Dams (`nid_data/all_dams_data.csv` in the public repo
  `lcford2/predict-release`). Records here carry NID submit dates around **2013**,
  i.e. this is an **older NID snapshot**, not the current authoritative NID.
- **Selection:** rows whose `Owner_Name`/`Fed_Owner` indicate Bureau of
  Reclamation, with valid latitude/longitude, de-duplicated by `NID_ID`, sorted by
  storage. 308 facilities across the 17 western states.
- **Known limitations / review items:**
  - **Coordinates and ownership are unverified** against the current NID
    (`https://nid.sec.usace.army.mil`) or Reclamation RISE (`https://data.usbr.gov`).
    Re-pull from an authoritative source and reconcile before operational use.
  - **No ground elevation.** The NID provides structure heights, not site MSL
    elevation, so `elevation_m` in the manifest is blank. Enrich from a DEM (e.g.
    the R `elevatr` package) or an authoritative source. Until then, set the fleet
    `index_flood.method: "nearest"` so results do not depend on site elevation.
  - Facility names/IDs are NID identifiers, which may differ from Reclamation's
    internal naming.
  - The list may include off-stream, diversion, or non-analysis structures that
    should be excluded for precipitation-frequency work.

## 3. Recommended verification before a fleet run

1. Re-pull the dam inventory from the **current NID** and/or **Reclamation RISE**;
   reconcile coordinates, ownership, and add ground elevations.
2. Confirm GHCN station availability and quality for each region; enable QFLAG
   screening if required.
3. Validate Como on **real** data (`run_golden.R` + `run_analysis.R` with
   `data.source: "ghcn"`) and sign off per `docs/audit_guide.md`.
4. Run a small pilot batch and review each region map + homogeneity log before the
   full fleet.

## 4. Software packages

`lmom` and `lmomRFA` (Hosking) are the reference L-moment engines; where CRAN is
unreachable they are built from the public CRAN GitHub mirrors
(`github.com/cran/lmom`, `github.com/cran/lmomRFA`). Mapping/plotting use
`ggplot2`, `sf`, `maps`. These are code dependencies, not data, but their versions
are recorded in each run's provenance manifest.
