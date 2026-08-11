# Validation

How we know the pipeline produces a correct regional precipitation-frequency
analysis — and not merely a self-consistent one. This document is written for a
reviewer (e.g. a Reclamation flood-hydrology expert) who wants to trust, or
independently reproduce, the numbers before any engineering use.

## The core is a reference implementation, by construction

The L-moment statistics themselves are **not reimplemented here**. Every core
quantity is computed by **`lmomRFA`**, written by **J.R.M. Hosking** — a
co-author of *Hosking & Wallis (1997), Regional Frequency Analysis: An Approach
Based on L-Moments* — the canonical text this method comes from:

| Quantity | Routine | H&W reference |
|---|---|---|
| At-site sample L-moments | `regsamlmu()` | ch. 2 |
| Discordancy `D_i` | `regtst()` | sec. 3.2.4 |
| Heterogeneity `H1/H2/H3` | `regtst()` | sec. 4.3 |
| Goodness-of-fit `Z^DIST` | `regtst()` | sec. 5.2.3 |
| Regional growth curve + quantiles | `regfit()`, `regquant()` | ch. 6 (index-flood) |

So the risk is **not** in the L-moment math. It is in the layers this project
adds around that math:

1. **Region assembly** — which GHCN stations form each dam's region (geographic
   radius, elevation band, record length).
2. **Data extraction** — turning daily GHCN precipitation into annual maxima for
   each duration, with QFLAG quality screening.
3. **The distribution-selection rule** — how a single distribution is chosen
   from the `Z` table.
4. **Index-flood scaling** — turning the dimensionless growth curve into site
   depths, `depth = index_flood x growth_factor`.
5. **Plumbing** — durations, seeding, the download cache.

The validation below targets exactly those added layers.

## Three standing validation scripts

| Script | What it proves | Reference |
|---|---|---|
| `run_golden.R` | The full pipeline recovers a **known** GEV growth curve from synthetic data (within tolerance) and auto-selects the true family; a frozen Cascades `regtst` anchor detects any drift. | synthetic known-answer + regression anchor |
| `run_tests.R` | Unit + integration tests (`testthat`): L-moment assembly, discordancy screen, homogeneity `H1<2` on a homogeneous region, distribution auto-selection recovering the true family, monotone growth curve, 10,000-yr growth factor recovered within 12%, tail sensitivity, facility diagnostics, QFLAG screening, offline cache, site-aware demo data. | internal invariants + known-answer |
| `validate_reference.R` | The added layers match an **independent / textbook** analysis, not our own output. Detailed below. | Hosking & Wallis (1997) datasets + from-scratch hand-calc |

Run all three:

```sh
Rscript run_tests.R            # unit + integration
Rscript run_golden.R           # synthetic known-answer + Cascades anchor
Rscript validate_reference.R   # textbook + independent cross-checks (this doc)
```

Each exits non-zero on any failure, so they double as CI gates.

## `validate_reference.R` — the five cross-checks

All five currently **PASS**. Each is either deterministic or run under the same
fixed seed (`20260811`) the pipeline uses, so results are reproducible.

### 1. Textbook findings on the canonical H&W datasets

`lmomRFA` ships the two datasets used as worked examples in Hosking & Wallis
(1997): **Appalach** (104 Appalachian streamflow gauges) and **Cascades** (19
Pacific-Northwest precipitation sites). Running `regtst` on them reproduces the
book's documented characterizations:

| Dataset | Result | H&W says |
|---|---|---|
| Appalachia | H1 = **2.08** (heterogeneous), max discordancy D = **16.18** (discordant sites present) | a heterogeneous region containing discordant sites |
| Cascades | H1 = **0.53** (homogeneous), max D = **2.63** (none discordant), best fit **GNO** \|Z\|=**1.50** | a homogeneous region well fit by a 3-parameter distribution |

Asserted: Appalachia has discordant sites (max D ≥ 3) and is far more
heterogeneous than Cascades; Cascades is homogeneous (H1 < 2), has no discordant
site, and its best fit is a 3-parameter distribution (GEV/GNO/PE3).

### 2. Discordancy fidelity

`step03_screening()`'s discordancy `D` equals a direct `regtst()` `D`
**exactly** (to 1e-9) — the screening wrapper passes the statistic through
without corrupting it.

### 3. Reproducibility

Running the seeded `step03 -> step04 -> step05 -> step06` chain **twice** yields
identical results (H1 = 0.5690, chosen = GNO, depths = [41.77, 62.16, 75.74] mm
at the 2/100/10,000-yr return periods). There is no hidden nondeterminism; a
given input + seed always gives the same answer.

### 4. Selection rule = expert hand-pick

The expert rule (H&W sec. 5.2.3) is: among candidate distributions with
\|Z\| ≤ 1.645, choose the smallest \|Z\|. Recomputing that **by hand** from the
`Z` table selects the same distribution `step05_distribution()` chose (GNO).

### 5. Index-flood arithmetic — independent hand-calc

The most important check on **our** code. The pipeline computes depths via
`lmomRFA::regfit`/`regquant`. This check recomputes the growth curve **from
scratch using only base `lmom` primitives** — record-length-weighted regional
L-moments -> `pelXXX()` (parameter estimation) -> `quaXXX()` (quantiles) ->
`depth = index x growth` — completely bypassing `regquant`. The two agree to
**0.000%** at every return period, including the 10,000-yr depth:

| Return period | Hand-calc depth (mm) | Pipeline depth (mm) | Difference |
|---|---|---|---|
| 2-yr | 41.77 | 41.77 | 0.000% |
| 10-yr | 52.67 | 52.67 | 0.000% |
| 100-yr | 62.16 | 62.16 | 0.000% |
| 1,000-yr | 69.48 | 69.48 | 0.000% |
| 10,000-yr | 75.74 | 75.74 | 0.000% |

This proves the index-flood scaling layer — the arithmetic this project owns —
is exact.

## What is NOT yet validated — and the recommended expert step

These checks prove the **method is implemented correctly**. They do **not**
prove the **inputs are right** for any specific dam, nor that the result matches
an official product. Before engineering use, an expert should still:

1. **Cross-check against NOAA Atlas 14.** For any dam in an Atlas 14-covered
   state, compare the pipeline's 24-hour 100-year (and other) depths to the
   official NOAA Atlas 14 point estimate at the dam's coordinates
   (`https://hdsc.nws.noaa.gov/pfds/`). Atlas 14 is the U.S. authoritative
   precipitation-frequency standard and is itself an L-moments regional
   analysis, so it is the natural external benchmark. *(This environment blocks
   `.gov` hosts, so this step must be run where Atlas 14 is reachable; it is the
   single most valuable external check to add.)*
2. **Verify the dam inventory.** Coordinates, ownership, and (absent) ground
   elevations in the NID-derived manifest are **unverified** (see
   `DATA_SOURCES.md`). A wrong coordinate silently analyzes the wrong region.
3. **Confirm station regions.** Spot-check that each region's stations are
   climatologically appropriate (not across a divide / rain-shadow), and review
   the `needs_review` and distribution-review worklists the batch produces.
4. **Confirm the season and durations** match the design question (the default
   is full-year annual maxima at 24h/72h).

## Reproducing from scratch

`docs/example_outputs/` holds a curated single-facility example (Como) and the
308-dam BOR fleet summary. `data/ghcn_prcp_cache/` and `data/ghcn_inventory/`
hold the committed GHCN data so a rerun serves the same stations offline. See
`docs/users_guide.md` and `docs/audit_guide.md` for the full run and audit
procedures.
