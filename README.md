# L-moments-como

Regional precipitation-frequency analysis by **L-moments** (Hosking &amp; Wallis,
1997), implemented in R. Primary test site: **Como Dam**, Bitterroot Valley,
Montana. The pipeline is **portable** — point it at a different config to analyse
any other basin, and it is designed to scale to the full Bureau of Reclamation
fleet (`run_batch.R`).

## What it produces

For each configured duration (default **24-hour** and **72-hour**) and out to the
**10,000-year** return period (annual exceedance probability 1e-4):

- a **homogeneous region** defined by the discordancy measure *Dᵢ* and the
  heterogeneity measure *H* (iteratively refined, every decision logged);
- a **map** of the region (stations used vs removed, dam, search radius);
- **lists** of stations **used** and stations **removed** (with reasons);
- an **L-moment ratio diagram** and a **growth-curve fit plot** showing the
  station data against the candidate distributions (basis for the choice);
- **depth-duration-frequency** tables and curves with **Monte-Carlo uncertainty
  bounds**;
- a self-contained **HTML audit report** and a **provenance manifest** for review.

## Method (Hosking &amp; Wallis 1997)

1. **Screening** — discordancy *Dᵢ* flags/removes anomalous stations.
2. **Homogeneity** — heterogeneity *H* defines an acceptably homogeneous region.
3. **Distribution choice** — L-moment ratio diagram + *Z*-statistic goodness-of-fit
   (GLO / GEV / GNO / PE3 / GPA).
4. **Estimation** — index-flood regional growth curve; site quantiles
   *Q(F) = index_flood × q(F)*; uncertainty by parametric bootstrap.

Built on Hosking's own **`lmom`** and **`lmomRFA`** packages (the reference
implementation of the book).

## Quick start

```bash
# Install R packages (see docs/users_guide.md for offline/CRAN-mirror options)
Rscript -e 'install.packages(c("lmom","lmomRFA","yaml","jsonlite","ggplot2","sf","maps"))'

# Validate the pipeline against a known-answer golden dataset
Rscript run_golden.R

# Run the analysis for Como Dam (auto-downloads GHCN-Daily where reachable;
# otherwise generates a labelled SYNTHETIC demo dataset so it runs offline)
Rscript run_analysis.R config/como.yml

# Unit + integration tests
Rscript run_tests.R
```

Outputs are written to `outputs/` (figures, tables, `report_<id>.html`,
`provenance/`). Example outputs are in `docs/example_outputs/`.

## Analyse another basin / the BOR fleet

Copy `config/como.yml`, edit the `site:` block (and any parameters), then:

```bash
Rscript run_analysis.R config/mybasin.yml           # one basin
Rscript run_batch.R --manifest config/facilities.csv # many facilities
```

> **⚠️ Data review required.** Both the **weather source** (GHCN-Daily) and the
> **dam inventory** (`config/facilities_BOR.csv` — 308 BOR dams, coordinates from
> a third-party ~2013 NID mirror, no ground elevations) are **UNVERIFIED** and
> must be reviewed before any engineering use — see **`DATA_SOURCES.md`**.
> This sandbox also cannot reach NOAA NCEI or CRAN, so demo runs use **synthetic**
> data (clearly labelled) and packages are built from the public CRAN GitHub
> mirrors. On a networked machine set `data.source: "ghcn"` for real observations.
> **Synthetic or unverified-inventory results are not valid for engineering decisions.**

See **`docs/PLAN.md`** for the full design, **`docs/users_guide.md`** to run it,
and **`docs/audit_guide.md`** for the reviewer sign-off checklist.
