# 308-dam fleet validation (real GHCN data)

Curated summary artifacts from a full-fleet batch run of `run_batch.R` over the
308-facility dam inventory, using **real** GHCN-Daily precipitation pulled from
the AWS Open-Data S3 mirror (`noaa-ghcn-pds`), full-year season, QFLAG quality
screening on, distributions auto-selected (expert review off for automated runs).

This is a frozen, curated copy of the run's fleet-level CSVs so the validation
evidence lives in the repo. The full per-facility outputs (308 HTML reports and
their tables/figures) are reproducible from code + config and are intentionally
not tracked (see the repo `.gitignore`).

## Run outcome

- **305 of 308 facilities succeeded.** The 3 failures are data-availability, not
  code: each sits in a sparse-gauge area that could not assemble the 5-station
  minimum region ("have 0/2/3 stations"). These are correctly reported as failed
  rather than forced.
- Region homogeneity (Hosking & Wallis H1), across 610 site x duration models:
  580 homogeneous, 26 acceptably homogeneous (H1 in [1,2)), 4 heterogeneous
  (H1 >= 2, flagged for manual region review).
- Auto-selected distribution mix: GEV 352, GLO 185, GNO 53, PE3 20.
- Goodness-of-fit: 495 of 610 models have an acceptable |Z| (<= 1.64); the
  115 that do not are surfaced for expert distribution review.
- Expert review is recommended on 230 model rows; 116 rows across 95 facilities
  are flagged `needs_review` (heterogeneous region and/or poor GoF).

## Headline depth-duration-frequency (real data, mm)

| Facility (climate)      | 24h 100yr | 24h 10,000yr | 72h 100yr | 72h 10,000yr |
|-------------------------|-----------|--------------|-----------|--------------|
| Como (MT, mid-montane)  | 63.4      | 97.7         | 104.6     | 209.3        |
| Hoover (NV, arid)       | 95.8      | 264.7        | 113.0     | 286.6        |
| Glen Canyon (AZ, arid)  | 76.4      | 146.0        | 105.9     | 310.1        |
| Shasta (CA, wet)        | 178.3     | 394.3        | 292.3     | 464.6        |

The gradient is physically sensible: the wet Northern-California site (Shasta)
carries the deepest storms, the arid Southwest sites sit lower at the 100-yr
point but fan out hard in the extreme tail (intense convective regime), and the
montane Como site is mid-range.

## Files

| File | What it is |
|------|-----------|
| `batch_status.csv`       | one row per facility: config, site, ok/failed, message |
| `all_facilities_DDF.csv` | depth-duration-frequency table for every facility x duration x return period, with Monte-Carlo bounds |
| `batch_diagnostics.csv`  | per site x duration triage: n_stations, H1, homogeneity, chosen distribution, |Z|, runner-up + margin, tail spread, `needs_review` |
| `tail_sensitivity.csv`   | 10,000-yr depth under every candidate distribution (how much the extreme tail hinges on the distribution choice) |

## Reproduce

```sh
Rscript run_batch.R config/manifest.csv   # writes the same CSVs to outputs/batch/
```

The GHCN inventory and the PRCP station cache are committed under
`data/ghcn_inventory/` and `data/ghcn_prcp_cache/`, so a rerun serves the same
stations offline without re-downloading.
