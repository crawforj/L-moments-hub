# NID fleet completion runbook

**Date armed:** 2026-08-16. **Trigger:** all 73,303 facilities attempted
(projected ~2026-08-22/23; an automated watcher exists in the operating
session, but this runbook is self-contained — anyone/any session can
execute it from here). Steps are **ordered**; each gates the next.

## 0. Context in one paragraph

The fleet is a self-chaining GitHub Actions batch on branch
`claude/desktop-nid-ad-hoc`. At ~42.6% (commit `b7207450`), QC gates
built per `NID_QAQC_PLAN.md` found and fixed two live fold-in bugs
(fix = fleet-branch commit `c664dd32`, 2026-08-16T20:42:56Z — the cohort
boundary; production pickup verified same hour). Phase-A analyses ran on
the partial data (`docs/analysis/`). Everything below finishes the job.

## 1. Re-run the QC gate on the full ledger

```bash
python qc/nid_qc_integrity.py   # vs the completion-state fleet commit
python qc/nid_qc_sanity.py
```

Pass criteria: no NEW integrity failures beyond the registered cohorts;
sanity flag rates stable vs the partial run. **Any new failure class
stops this runbook** until dispositioned in the known-issue register.

## 2. Remediation re-run (the flagged cohorts)

`qc/reports/rerun_cohort.csv` — **4,087 facilities** (union of: DDF
name-collision damage 3,728; tail-sensitivity dropped rows 2,554, a
strict subset; unauditable early-cloud cohort 394; overlaps accounted).
Mechanics: remove exactly these facility_ids' rows from
`data/nid_progress/completed_ids.csv` on the fleet branch (commit that
edit in a tranche-push gap, same discipline as the `c664dd32` fix), and
let the self-chain re-process them under post-fix code (~15 h at
observed rates). The fixed fold-in replaces their cumulative rows by
site_id key. Then **re-run step 1** — the re-run cohort must come back
clean and the name-collision flags must clear.

Consider folding in (same re-run, zero extra cost if desired): the 643
narrow-elevation-band and 650 old-manifest-vintage cohort facilities
(integrity_flags.csv) — **optional**, decide explicitly, they are
documented cohorts rather than data loss.

## 3. Refresh Phase-A + republish

```bash
python analysis/a1_failure_atlas.py
python analysis/a2_tail_geography.py
python analysis/a3_heterogeneity.py
```

Update the three `docs/analysis/*.md` (new pinned commit, N=73,303
framing, remove partial-data caveats), regenerate figures, and refresh
the mobile atlas artifact (operating-session task; the artifact URL is
held by the project owner's session — republish same file path/URL).
Re-check each partial-data finding honestly: the largest-first bias is
gone at completion, so **sparsely-dammed-region findings (A1 especially)
may genuinely change** — report reversals as findings.

## 4. Specific follow-ups queued from the partial run

1. **New England failure cluster** (12 failures, well-gauged region,
   unexplained — `failure_atlas.md`): pull those facilities' station
   audit files and find the actual reason before the full-fleet A1
   refresh ships.
2. **72h<24h crossings at T≥200** (15.7% of facilities; per-duration
   fits have no cross-duration constraint): methods item — document in
   `docs/ASSUMPTIONS_AND_LIMITATIONS.md` §C and decide (owner/reviewer)
   whether to add a post-hoc consistency adjustment or carry as caveat.
   100-yr products unaffected.
3. **Coordinate defects** (register items 9): 8 OR placeholder-longitude
   dams + TN05102 — excluded from spatial products by the gate; report
   upstream to NID if a channel exists.
4. **Cross-check vs BOR-308** (QAQC §D2): run the matched-facility
   comparison at completion — the reproducibility statement.
5. **Stratified deep-review sample** (QAQC §D1): draw the ~75–100
   facility sample AFTER remediation (step 2) so it samples the final
   dataset.

## 5. Phase B start (analysis plan)

B1 Atlas 14 stratified comparison first (build the polite sampler; hand
verify ≥20 PFDS values first per QAQC §D3). B2 blocked on a TP-40
source decision; B3 blocked on the owner's rebase/sample decision.

## 6. Communication

At completion + gate-pass: brief note to the USBR contact (the analysis
plan's public-safe findings only), and refresh the repo README fleet
table (currently says ~30,000/41%).

## Standing decisions still parked with the owner

- Rebase the fleet branch onto main (region-method band / ASM / cluster)
  — B3's sample quantifies the cost either way.
- Full-NID elevation enrichment.
- PR #10 (ensemble band + roi) review.
