# Example outputs — Como Dam (SYNTHETIC demo data)

These artifacts were produced by `Rscript run_analysis.R config/como.yml` in an
offline environment, so they are built on the **synthetic demo dataset** (NOAA
NCEI was unreachable). They illustrate the deliverables and format only and are
**not valid for engineering use**. Re-run with `data.source: "ghcn"` on a
networked machine for real results.

- `report_COMO_DAM.html` — full human-review report
- `figures/` — region map, L-moment ratio diagram, growth-curve fit, DDF with bounds
- `quantiles_DDF_COMO_DAM.csv` — headline depths (24h & 72h) to 10,000 yr with bounds
- `stations_used_*` / `stations_removed_*` — station lists
- `run_manifest_COMO_DAM.json` — provenance
