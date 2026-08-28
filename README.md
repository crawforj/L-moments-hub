# L-moments-hub

**Rainfall statistics for every dam in the United States — built to be checked.**

Every dam is designed around a question that sounds simple and isn't: *how hard
can it rain here?* Not in a bad year — in the worst year in a century, or ten
thousand. Nobody has records that long, so statisticians pool observations from
many rain gauges and extrapolate. That method is **regional frequency analysis
with L-moments** (Hosking & Wallis, 1997), and it is the same family of methods
behind NOAA's official rainfall atlas.

This project runs it, uniformly and from a single codebase, at **every dam in
the National Inventory of Dams** — about 92,000 facilities — for 24-hour and
72-hour storms, out to the 1-in-10,000-year event. For each dam it produces the
estimate, its uncertainty, a map of every gauge used or rejected with reasons,
and an audit trail a reviewer can follow decision by decision.

What makes it more than a large table of numbers is that **it runs the analysis
more than one defensible way and measures how much the answers move** — then
checks itself against independent references under criteria published before the
comparisons ran.

> **What this is not.** A screening and research tool, full stop. It flags where
> an expert should look; it does not produce engineering numbers, and no result
> here supports a conclusion about any individual dam's safety. Every input is
> unverified until reviewed — see [`DATA_SOURCES.md`](DATA_SOURCES.md).

---

## The finding

Two standard, defensible ways of grouping rain gauges into a region move the
10,000-year rainfall depth by a **median of 15%** — and the standard
homogeneity test approves both, so the statistics cannot arbitrate between them.
Distribution-family choice is a comparable lever, and largest exactly where
goodness-of-fit cannot separate the leading candidates.

The confidence interval normally published alongside these estimates captures
**neither** effect, because it is computed with the region and the family held
fixed. That gap — between reported uncertainty and actual uncertainty — is the
scientific core of the project.

→ [`docs/CLUSTER_FLEET_RESULTS.md`](docs/CLUSTER_FLEET_RESULTS.md) ·
[`docs/analysis/method_diagnostics.md`](docs/analysis/method_diagnostics.md)

## How you know it's right

**The engine is the reference implementation.** Hosking's own `lmom` /
`lmomRFA` R packages, written by the method's co-inventor. The pipeline
reproduces the worked examples in Hosking & Wallis (1997) on their own data, and
its depths match an independent from-scratch hand calculation to **0.000%**
through the 10,000-year event → [`docs/VALIDATION.md`](docs/VALIDATION.md).

**Run it twice, get the same bits.** Seeded and bit-for-bit reproducible —
tested, not assumed. The same dams pushed through two independently built
pipelines months apart came back **99% byte-identical**, every disagreement
traced to a dated config change. Along the way we found and fixed a cache defect
that made results depend on processing order — invisible to any project that
never runs twice →
[`docs/analysis/bor_nid_reproducibility.md`](docs/analysis/bor_nid_reproducibility.md).

## External validation — both tiers complete

Acceptance criteria were committed to this repository **before any comparison
ran**; the git history is the timestamp
([`docs/EXTERNAL_VALIDATION_PLAN.md`](docs/EXTERNAL_VALIDATION_PLAN.md)). They
have not been adjusted since.

**Tier 1 — do we match the national standard? Yes.** ~4,000 dams sampled across
61 climate, terrain and coverage strata, checked against **NOAA Atlas 14**. All
four pre-registered targets met: median difference **−2.6%** at the 100-year
storm, **92% of sites within 20%**, and — the criterion that mattered most —
disagreement is *predictable*, rising measurably where the surrounding gauges
are inconsistent with each other. The fetch harness was ground-truthed against
NOAA's own backend at 21 sites: exact to 0.0000%.

**Tier 2 — can we reproduce a published expert's work? No, and that is the more
useful result.** We re-ran the 2007 Washington State regional analysis (Wallis,
Schaefer, Barker & Taylor, *HESS*) that the state adopted as its **dam-safety
standard**. Our depths came out 21–32% high, well outside the frozen ≤10%
threshold. Rather than argue, we tested both against a third party — the
observed record at each dam's nearest long-running gauge. **Washington's numbers
were right; ours were biased high.**

**What that bias turned out to be.** It is *regional*, not systemic: fleet-wide
our index-flood step is unbiased to **0.2%**, but Washington and Oregon are the
two worst states in the country — and are the only two with no Atlas 14
coverage, i.e. precisely where nobody had a modern reference to check against.
The mechanism is that we predict local rainfall from **elevation**, which fails
where a windward slope and a rain shadow sit at the same height. We can now
measure the conditions under which our own estimates should be distrusted, which
is worth more than a clean pass would have been.

A validation claiming 100% success reads like a brochure. This one is written
so the misses come first.

## Where the project stands

| Stage | Scope | Status |
|---|---|---|
| Single dam (Como Dam, MT) | full audit trail, portable config | ✅ validated on real data |
| Bureau of Reclamation fleet | 308 dams, both region methods | ✅ complete |
| National run 1 — circular regions | full inventory | ✅ complete, QC-gated, name-collision defects repaired |
| National run 2 — cluster regions | full inventory, second method | ✅ complete |
| **Controlled national comparison** | both methods, one variable apart | 🔄 running |
| External validation, Tiers 1–2 | Atlas 14 · Washington State | ✅ complete (above) |

The controlled comparison is the one that matters scientifically: the two
national runs differ in several settings, so their difference is a *compound*
effect. The run in progress re-does one method under the other's exact
configuration, so the difference is attributable to the region-method choice
alone.

Other findings that survive their own QC, each pinned to a data snapshot:

- **Gauge deserts, mapped.** Where the method cannot produce an estimate it
  fails geographically — Alaska above 20%, the national rate under 0.1% →
  [`failure_atlas.md`](docs/analysis/failure_atlas.md)
- **A federal coverage gap.** Oregon and Washington are the only states never
  covered by NOAA Atlas 14; the 1973 predecessor stops at the 100-year storm →
  [`atlas14_pilot.md`](docs/analysis/atlas14_pilot.md)
- **A physical-consistency check that bites.** In the far tail ~15% of sites
  show 72-hour depths below 24-hour depths — impossible, and traced to each
  duration picking its own distribution family →
  [`cross_duration_consistency.md`](docs/analysis/cross_duration_consistency.md)

## What it produces, per dam

For 24-hour and 72-hour storms, out to the 10,000-year return period: DDF tables
and curves with Monte-Carlo bounds; a map of the gauge region showing stations
used and removed with reasons; the L-moment ratio diagram behind the
distribution choice; triage diagnostics and a tail-sensitivity table; and a
self-contained HTML audit report with a provenance manifest.

Real examples from real runs: [`docs/example_outputs/`](docs/example_outputs/)

| ![Como region](docs/example_outputs/figures/COMO_DAM_region_map.png) | ![Como 24h DDF with bounds](docs/example_outputs/figures/COMO_DAM_24h_ddf_with_bounds.png) |
|:--:|:--:|
| The region: gauges used vs removed | 24-hour depth-frequency curve with bounds |

## The method in one paragraph

Screen the surrounding gauges and discard statistical misfits (discordancy);
test that the survivors are similar enough to pool (heterogeneity); choose a
distribution from five candidates by goodness-of-fit; scale the pooled regional
curve by the site's typical annual maximum (the index-flood step); attach
uncertainty by Monte-Carlo simulation. Every one of those steps is a judgment
call, every call is logged, and measuring how much they matter is half the point
→ [`docs/METHODS.md`](docs/METHODS.md).

## Run it yourself

```bash
# R packages
Rscript -e 'install.packages(c("lmom","lmomRFA","yaml","jsonlite","ggplot2","sf","maps"))'

# Verify against known answers first
Rscript run_golden.R && Rscript run_tests.R && Rscript validate_reference.R

# One dam (real GHCN-Daily via NOAA's AWS mirror)
Rscript run_analysis.R config/como.yml

# A fleet
Rscript run_batch.R --manifest config/facilities_BOR.csv   # 308-dam BOR fleet
Rscript run_nid_tranche.R                                  # next resumable NID tranche
```

The national sweep is built for machines that come and go: resumable tranches,
largest dams first, a committed ledger so no dam is computed twice, and
cumulative tables shipped as compressed release assets with a consistency
manifest that fails loudly on any ledger/asset disagreement.

> **⚠️ Data review required.** GHCN-Daily and the dam inventory are
> **unverified** inputs and must be reviewed before any engineering use —
> [`DATA_SOURCES.md`](DATA_SOURCES.md).

## Documentation

### Start here

[`VALIDATION.md`](docs/VALIDATION.md) (how it is verified) ·
[`EXTERNAL_VALIDATION_PLAN.md`](docs/EXTERNAL_VALIDATION_PLAN.md) (the frozen
criteria) · [`ASSUMPTIONS_AND_LIMITATIONS.md`](docs/ASSUMPTIONS_AND_LIMITATIONS.md)
(read before trusting any number)

### Method and outputs

[`METHODS.md`](docs/METHODS.md) ·
[`OUTPUT_DATA_DICTIONARY.md`](docs/OUTPUT_DATA_DICTIONARY.md) ·
[`expert_review_checklist.md`](docs/expert_review_checklist.md)

### The region-method question

[`REGION_METHOD_SENSITIVITY.md`](docs/REGION_METHOD_SENSITIVITY.md) ·
[`CLUSTER_FLEET_RESULTS.md`](docs/CLUSTER_FLEET_RESULTS.md)

### Fleet operations

[`NID_QAQC_PLAN.md`](docs/NID_QAQC_PLAN.md) ·
[`NID_ANALYSIS_PLAN.md`](docs/NID_ANALYSIS_PLAN.md) ·
[`NID_COMPLETION_RUNBOOK.md`](docs/NID_COMPLETION_RUNBOOK.md)

### Findings (`docs/analysis/`)

[`failure_atlas`](docs/analysis/failure_atlas.md) ·
[`tail_geography`](docs/analysis/tail_geography.md) ·
[`method_diagnostics`](docs/analysis/method_diagnostics.md) ·
[`atlas14_pilot`](docs/analysis/atlas14_pilot.md) ·
[`cross_duration_consistency`](docs/analysis/cross_duration_consistency.md) ·
[`bor_nid_reproducibility`](docs/analysis/bor_nid_reproducibility.md) ·
[`nid_coordinate_defects`](docs/analysis/nid_coordinate_defects.md)

## License

**Code:** MIT ([`LICENSE`](LICENSE)) — provided "as is", which reinforces the
screening framing: results are not valid for engineering decisions without
expert review.

**Data is not covered by the MIT license.** GHCN-Daily precipitation is a
NOAA/NCEI public-domain product retrieved via the AWS Open-Data mirror; the dam
inventory derives from the USACE National Inventory of Dams. Attribute the
original providers — see [`DATA_SOURCES.md`](DATA_SOURCES.md).
