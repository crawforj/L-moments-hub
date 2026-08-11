# Audit &amp; Human-Review Guide

This analysis is intended to be **reproducible, traceable, and defensible** to an
independent reviewer. This guide explains how to review a run and sign off.

## Review artifacts

For any run, the reviewer works from three things:

1. **`outputs/report_<id>.html`** — the assembled report: region map, discordancy/
   heterogeneity decision log, station lists, *Z*-statistic table, ratio diagram,
   growth-curve fit, depth-frequency curves and tables, and caveats.
2. **`outputs/provenance/run_manifest_<id>.json`** — git commit, R and package
   versions, the exact config used, seed, and station record spans.
3. **`outputs/provenance/audit_log_<id>.txt`** — the ordered log of every
   invariant check that passed and every station add/drop decision, with values.

## The five audit layers

1. **Reproducibility & provenance** — `renv`-style pinned environment intent, a
   fixed seed, and a per-run manifest. Re-running the same config + commit
   reproduces the numbers.
2. **Embedded invariant checks** (`R/checks.R`) — the pipeline halts if any
   invariant fails (no NA L-moments; monotone quantiles/growth curve; positive
   depths; station counts reconcile; a *Z* value for every candidate;
   heterogeneity computed). Passed checks appear in the audit log.
3. **Golden-dataset validation** (`run_golden.R`) — the same code is run on a
   known-answer case:
   - *synthetic known-truth*: stations simulated from a known GEV regional growth
     curve; the pipeline must auto-select GEV and recover the growth curve
     (≤ 8% for T ≤ 1000) and the 10,000-yr growth factor (≤ 12%). Scorecard in
     `golden/golden_scorecard.csv`.
   - *benchmark determinism*: `regtst()` on the packaged `Cascades` example must
     reproduce frozen reference statistics (`golden/cascades_reference.json`).
4. **Human-review report** (`R/11_audit_report.R`) — the narrative walk-through.
5. **Tests** (`run_tests.R`) — unit tests for helpers and integration tests for
   the analytical chain.

## Reviewer checklist (sign-off)

- [ ] `Rscript run_golden.R` prints **ALL PASS**.
- [ ] `Rscript run_tests.R` reports **0 failed/error**.
- [ ] Provenance manifest records the expected git commit, config, and seed.
- [ ] Region status is *homogeneous* or *acceptably homogeneous*; the homogeneity
      history and each station drop are justified in the log.
- [ ] Stations-used and stations-removed lists are complete and reconcile with the
      candidate count (checked automatically; confirm the reasons are sensible).
- [ ] The chosen distribution has `|Z| ≤ 1.64`; the growth-curve plot shows the
      data are consistent with it and you accept the tail behaviour at 10,000 yr.
- [ ] **Distribution selection reviewed.** Automated runs auto-select the
      smallest-`|Z|` distribution; `outputs/batch/batch_diagnostics.csv` lists,
      per facility-duration, the `selection_source` (auto / expert_review /
      config_override), the runner-up and the `z_margin`, and flags
      `review_recommended` (poor fit or a close call). For any flagged facility,
      an expert should weigh the candidates' 10,000-yr tail behaviour and, if
      overriding the automatic pick, record the decision in
      `config/distribution_review.csv` (`facility_id, duration, distribution,
      reviewer, date, notes`) so it is applied and audit-logged on future runs.
- [ ] The 10,000-yr depths and their uncertainty band are reasonable; the band
      width is acknowledged in any downstream use.
- [ ] **Data provenance is real** (GHCN, not the synthetic demo) for any result
      used in an engineering decision.

## What would fail an audit

- A run whose report shows a *heterogeneous* region (H1 ≥ 2) without documented
  manual region revision.
- A chosen distribution with `|Z| > 1.64` and no justification.
- Results produced from the synthetic demo data (the report and README label this;
  never sign off synthetic results for engineering use).
- `run_golden.R` or `run_tests.R` failing on the review machine.
