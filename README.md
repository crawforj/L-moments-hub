# L-moments-hub

**Rainfall statistics for every dam in the United States — built to be
checked.**

Every dam is designed around a question that sounds simple and isn't: *how
hard can it rain here?* Not in a bad year — in the worst year in a century,
or ten thousand years. Nobody has records that long, so statisticians pool
observations from many rain gauges in a region and extrapolate — a method
called **regional frequency analysis with L-moments** (Hosking & Wallis,
1997). It is the same family of methods behind NOAA's official rainfall
atlas.

This project runs that method, uniformly and from a single codebase, at
**every dam in the National Inventory of Dams** — about 92,000 facilities —
for 24-hour and 72-hour storms, out to the 1-in-10,000-year event. For
each dam it produces the estimate, the uncertainty around it, a map and
list of every rain gauge used or rejected (with reasons), and a full audit
trail a reviewer can follow decision by decision.

Two things make it more than a big table of numbers:

1. **It runs the analysis more than one defensible way** — and measures how
   much the answers move. That disagreement between reasonable expert
   choices turns out to be one of the most interesting results.
2. **It is being validated against the people you already trust** — NOAA's
   national standard and a peer-reviewed study that became a state's
   dam-safety regulation — with the pass/fail criteria published *before*
   the comparisons run.

> **What this is not.** A screening and research tool, full stop. It flags
> where an expert should look; it does not produce engineering numbers, and
> no result here supports a conclusion about any individual dam's safety.
> Every input is treated as unverified until reviewed
> ([`DATA_SOURCES.md`](DATA_SOURCES.md)).

---

## How you know it's right — the trust ladder

Trust is built in layers, from "the arithmetic is correct" to "independent
experts get the same answers." The lower rungs are done; the upper rungs
are pre-registered and about to execute.

### Already established

- **The core is the reference implementation.** The statistical engine is
  Hosking's own `lmom`/`lmomRFA` R packages — written by the method's
  co-inventor.
- **It reproduces the textbook.** The pipeline reproduces the worked
  examples in Hosking & Wallis (1997) on their own datasets, and its
  final depths match an independent from-scratch hand calculation to
  **0.000%** through the 10,000-year event →
  [`docs/VALIDATION.md`](docs/VALIDATION.md).
- **Run it twice, get the same bits.** Seeded, bit-for-bit reproducible —
  and tested, not assumed: the same dams pushed through two independently
  built pipelines months apart came back **99% byte-identical**, with every
  disagreement traced to a dated, documented config change →
  [`docs/analysis/bor_nid_reproducibility.md`](docs/analysis/bor_nid_reproducibility.md).
  Along the way we found and fixed a cache defect that made results depend
  on processing order — invisible to any project that never runs twice.

### About to execute — pre-registered, thresholds frozen

The full protocol, with acceptance criteria committed to this repository
**before any comparison ran**, is
[`docs/EXTERNAL_VALIDATION_PLAN.md`](docs/EXTERNAL_VALIDATION_PLAN.md).
The git history is the timestamp.

**Tier 1 — do we match the official source?** About 4,000 dams, sampled
across every climate and terrain stratum in the country, checked against
**NOAA Atlas 14**, the national standard. A 35-site pilot already ran: our
typical estimate landed within ~2% of NOAA's at the 100-year storm, with
three-quarters of sites within 20%. Better: disagreement is *predictable* —
where the surrounding gauges behave inconsistently with each other (a
measurable property), differences grow. So the claim under test is not just
"we match the standard" but "we match it, **and we can tell you where to
trust us less**."

**Tier 2 — can we reproduce a published expert's work at their own sites?**
Matching a reference table can happen for the wrong reasons; two errors can
cancel. So the second test re-runs a **peer-reviewed study** with our
pipeline: the 2007 Washington State regional analysis (Wallis, Schaefer,
Barker & Taylor, *HESS*) that the state **adopted as its dam-safety
standard** — one of its authors is the Wallis of Hosking–Wallis. We compare
not just final depths at Washington's ~835 dams but the *shape* of the
frequency curves, the method's fingerprint. Two rules, locked in advance:
the pass/fail thresholds are frozen (≤10% is a match; ≤25% only with a
named cause; beyond that, a discrepancy), and **every unexplained mismatch
is published, listed first**. A validation claiming 100% success reads like
a brochure; one that says "here are the misses, come check them" reads like
science.

**Tier 3 — the disagreement is the finding.** Washington's team made
certain judgment calls; NOAA made different ones; we made ours. All
defensible — and at the very rare storms dam safety cares about, the
resulting numbers can differ by 15–30%. Because this project computes
results multiple ways at tens of thousands of dams, it can **measure how
much expert judgment moves the answer, and map where it matters**. The
within-project version is already quantified: switching between two
standard region-building methods moves the 10,000-year depth by a median of
15% ([`docs/CLUSTER_FLEET_RESULTS.md`](docs/CLUSTER_FLEET_RESULTS.md)) —
while the usual statistical test happily approves both choices
([`docs/analysis/method_diagnostics.md`](docs/analysis/method_diagnostics.md)).
The published confidence interval captures neither. That gap between
reported and actual uncertainty is the scientific core of the project.

---

## Where the project stands

| Stage | Scope | Status |
|---|---|---|
| 1. Single dam (Como Dam, MT) | full audit trail, portable config | ✅ validated on real data |
| 2. Bureau of Reclamation fleet | 308 dams, both region methods | ✅ complete |
| 3. **National run 1** (circular regions) | the full National Inventory of Dams (~92,000 dams) | 🔄 initial pass complete; a post-completion QC gate found early results filed under ambiguous dam *names* (many dams share names) — those are being recomputed, keyed by ID, as the run extends across the full inventory |
| 4. **National run 2** (cluster regions) | same inventory, second method | 🔄 finishing — kept as a full independent dataset for the Tier 3 comparison |
| 5. External validation | Tiers 1–2 above | armed; fires when stage 3's recomputation lands |

Live tally: [`progress.md` on the fleet branch](https://github.com/crawforj/L-moments-hub/blob/claude/desktop-nid-ad-hoc/data/nid_progress/progress.md).
Operational detail: [`docs/NID_COMPLETION_RUNBOOK.md`](docs/NID_COMPLETION_RUNBOOK.md),
[`docs/NID_QAQC_PLAN.md`](docs/NID_QAQC_PLAN.md).

Findings so far that survive their own QC (all pinned to data snapshots, all
on partial-through-full data as noted in each doc):

- **Gauge deserts, mapped.** Where the method cannot produce an estimate at
  all, it fails geographically — Alaska above 20%, the national rate under
  0.1% → [`docs/analysis/failure_atlas.md`](docs/analysis/failure_atlas.md)
- **A federal coverage gap.** Oregon and Washington are the only two states
  never covered by NOAA Atlas 14; the 1973 predecessor stops at the
  100-year storm. (Washington built and codified its own deeper standard —
  the Tier 2 reference above; Oregon's update is in progress) →
  [`docs/analysis/atlas14_pilot.md`](docs/analysis/atlas14_pilot.md)
- **A physical-consistency check that bites.** In the far tail, ~15% of
  sites show 72-hour depths below 24-hour depths — impossible physically,
  and traced to a specific, fixable modelling choice (each duration picking
  its own distribution family) →
  [`docs/analysis/cross_duration_consistency.md`](docs/analysis/cross_duration_consistency.md)

---

## What it produces, per dam

For 24-hour and 72-hour storms, out to the 10,000-year return period:

- depth-duration-frequency tables and curves with Monte-Carlo uncertainty
  bounds;
- a map of the gauge region — stations used vs removed, each removal with a
  reason;
- the L-moment ratio diagram and growth-curve fit behind the distribution
  choice;
- per-facility triage diagnostics (region homogeneity, fit quality,
  `needs_review` flags) and a distribution tail-sensitivity table;
- a self-contained HTML audit report and a provenance manifest.

Real examples from real runs, including the full single-dam deliverable set
and a 308-dam fleet summary:
[`docs/example_outputs/`](docs/example_outputs/)

| ![Como region](docs/example_outputs/figures/COMO_DAM_region_map.png) | ![Como 24h DDF with bounds](docs/example_outputs/figures/COMO_DAM_24h_ddf_with_bounds.png) |
|:--:|:--:|
| The region: gauges used vs removed | 24-hour depth-frequency curve with uncertainty bounds |

## How the method works, in one paragraph

Screen the surrounding rain gauges and discard statistical misfits
(discordancy); test that the survivors are similar enough to pool
(heterogeneity); choose a probability distribution from five candidates by
goodness-of-fit; scale the pooled regional curve by the site's typical
annual maximum (the index-flood step); attach uncertainty by Monte-Carlo
simulation. Every one of those steps involves a judgment call, every
judgment is logged, and measuring how much the calls matter is half the
point → [`docs/METHODS.md`](docs/METHODS.md).

## Run it yourself

```bash
# Install R packages
Rscript -e 'install.packages(c("lmom","lmomRFA","yaml","jsonlite","ggplot2","sf","maps"))'

# Verify the pipeline against known answers first
Rscript run_golden.R && Rscript run_tests.R && Rscript validate_reference.R

# One dam (real GHCN-Daily weather via NOAA's AWS mirror; offline hosts fall
# back to a clearly LABELLED synthetic demo set)
Rscript run_analysis.R config/como.yml

# A fleet: copy the config, point it at a manifest
Rscript run_batch.R --manifest config/facilities_BOR.csv   # 308-dam BOR fleet
Rscript run_nid_tranche.R                                  # next resumable tranche of the full NID
```

The national sweep is engineered for an ephemeral machine: resumable
tranches, largest dams first, a committed ledger so no dam is ever computed
twice, and a self-chaining CI job that carries the fleet forward
unattended. Large cumulative tables ship as compressed release assets
(tag `nid-run1-data`) with a consistency manifest that fails loudly on any
ledger/asset disagreement.

> **⚠️ Data review required.** The weather source (GHCN-Daily) and the dam
> inventory are **unverified** inputs and must be reviewed before any
> engineering use — see [`DATA_SOURCES.md`](DATA_SOURCES.md). Synthetic or
> unverified-inventory results are never valid for engineering decisions.

## Documentation

**Start here**
- [`docs/VALIDATION.md`](docs/VALIDATION.md) — how the pipeline is verified
- [`docs/EXTERNAL_VALIDATION_PLAN.md`](docs/EXTERNAL_VALIDATION_PLAN.md) — the pre-registered trust tiers (frozen thresholds)
- [`docs/ASSUMPTIONS_AND_LIMITATIONS.md`](docs/ASSUMPTIONS_AND_LIMITATIONS.md) — read before trusting any number

**Method & outputs**
- [`docs/METHODS.md`](docs/METHODS.md) — equations, thresholds, choices
- [`docs/OUTPUT_DATA_DICTIONARY.md`](docs/OUTPUT_DATA_DICTIONARY.md) — every output column defined
- [`docs/expert_review_checklist.md`](docs/expert_review_checklist.md) — per-facility sign-off form

**The region-method question** (raised by a Reclamation reviewer, then quantified)
- [`docs/REGION_METHOD_SENSITIVITY.md`](docs/REGION_METHOD_SENSITIVITY.md) — single-facility comparisons
- [`docs/CLUSTER_FLEET_RESULTS.md`](docs/CLUSTER_FLEET_RESULTS.md) — the clean fleet-wide measurement, its confound, and how the confound was caught

**National fleet operations**
- [`docs/NID_QAQC_PLAN.md`](docs/NID_QAQC_PLAN.md) — QC gates + known-issue register
- [`docs/NID_ANALYSIS_PLAN.md`](docs/NID_ANALYSIS_PLAN.md) — analysis roadmap, incl. the public/private publication boundary
- [`docs/NID_COMPLETION_RUNBOOK.md`](docs/NID_COMPLETION_RUNBOOK.md) · [`docs/NID_RUN2_CLUSTER_PLAN.md`](docs/NID_RUN2_CLUSTER_PLAN.md)

**Findings** (`docs/analysis/`, each pinned to a data snapshot)
- [`failure_atlas.md`](docs/analysis/failure_atlas.md) · [`tail_geography.md`](docs/analysis/tail_geography.md) · [`method_diagnostics.md`](docs/analysis/method_diagnostics.md) · [`atlas14_pilot.md`](docs/analysis/atlas14_pilot.md) · [`cross_duration_consistency.md`](docs/analysis/cross_duration_consistency.md) · [`bor_nid_reproducibility.md`](docs/analysis/bor_nid_reproducibility.md) · [`nid_coordinate_defects.md`](docs/analysis/nid_coordinate_defects.md)

## License

**Code:** MIT ([`LICENSE`](LICENSE)) — provided "as is", which reinforces
the screening framing: results are not valid for engineering decisions
without expert review.

**Data is not covered by the MIT license.** GHCN-Daily precipitation is a
NOAA/NCEI public-domain product retrieved via the AWS Open-Data mirror; the
dam inventory derives from the USACE National Inventory of Dams. Attribute
the original providers, and see [`DATA_SOURCES.md`](DATA_SOURCES.md) for
provenance and the unverified-data caveats.
