# NID run 2 — cluster region method (decision record + plan)

**Decision (project owner, 2026-08-17):** after the first NID run
completes (circular method, current fleet branch), run the full NID fleet
a **second time under `region.method: cluster`** — and **keep both result
sets permanently**. No rebase-in-place, no overwriting: the national
dataset becomes a two-method ensemble, matching the approach validated on
the BOR-308 (`docs/CLUSTER_FLEET_RESULTS.md`) where the method choice
moved 10,000-yr depths by median ~15% and the pair proved more valuable
than either alone.

## Sequencing (strict)

1. **Run 1 finishes** (circular; ~2026-08-22) → completion runbook
   executes (`NID_COMPLETION_RUNBOOK.md`): QC gate, 4,087-facility
   remediation, Phase-A refresh. Run 1 is final only after that.
2. **Archive run 1 immutably**: git-tag the fleet branch at its final
   commit (`nid-run1-circular-final`) AND copy the completed ledgers to
   `data/nid_runs/run1_circular/` on main — both methods' outputs then
   live side-by-side under method-labeled paths, no ambiguity about
   which method produced what.
3. **Run 2 prep** (each item is required, not optional):
   - **Elevation enrichment for all 73,303 manifest rows** — entailed by
     this decision: cluster clusters on site elevation and silently
     falls back to circular wherever `elevation_m` is NA (the exact
     fleet-wide no-op bug found on the BOR set). Same
     `enrich_manifest_elevations.R` path; batch the elevatr calls and
     record the batch-resolution nondeterminism caveat. Persist into the
     manifest used by run 2.
   - **Port the fold-in fix**: commit `c664dd32` (site_id keying,
     mixed-schema `append_cum_csv`) lives on the run-1 fleet branch
     ONLY; run 2's branch must carry it from day one (cut run 2's
     branch from current `main` + cherry-pick/merge the fix, then verify
     with the existing mixed-schema regression test).
   - **Template elevation band verified wide on main** (fixed 2026-08-18:
     main's como.yml still carried the pre-`603224c3` Montana band
     [600,2600] that zeroed candidate pools for ~87% of the country --
     caught during failure-cohort diagnosis, ported before it could
     poison run 2's branch cut).
   - **Fresh branch + fresh ledgers**: new branch (e.g.
     `claude/nid-run2-cluster`) from main (which has cluster, band, ASM,
     ARF); ledger dir starts empty (`data/nid_progress/` on that branch)
     — resumability semantics identical to run 1.
   - **Config**: `region_method: cluster` per manifest row (the
     `gen_configs_from_manifest()` override column, as in the BOR
     cluster run) — template default stays circular so nothing else
     inherits the change silently.
   - **Cluster caches**: `build_station_clusters()` grid-cell caches are
     method-infrastructure — prewarm optionally; they rebuild on demand.
4. **Launch run 2** on the same self-chaining workflow (`-f
   branch=claude/nid-run2-cluster`). Expected faster than run 1: the
   GHCN station cache (~18k stations, committed) is warm — station
   downloads were a large share of run-1 cost. Genuine new cost: cluster
   builds + any new stations the different regions pull in. Still
   expect **multi-day**, not multi-week.
5. **At run-2 completion**: same QC gates (they are method-agnostic),
   then the national two-method comparison — the fleet-scale analogue of
   `CLUSTER_FLEET_RESULTS.md`, with the band table generalized to all
   ~73k facilities, and analysis plan B3 (national uncertainty
   structure) satisfied by census rather than sample.

## What this supersedes

- The "rebase the fleet branch?" question (runbook §"standing decisions",
  memory, todo lists): **resolved** — no rebase; run 1 stays pristine on
  its frozen branch, run 2 gets current methods on a fresh branch.
- Analysis plan **B3**'s sampled two-method estimate: superseded by the
  full run-2 census (keep the sample idea only if run 2 is ever
  cancelled).
- The full-NID elevation-enrichment "open decision": **entailed yes**,
  as run-2 prep (it also retroactively benefits nothing in run 1 —
  run 1's index-flood used the regional-mean fallback throughout, which
  stays true and documented for that dataset).

## Known caveats to carry into run 2's docs from day one

- Run 1 vs run 2 differ in MORE than region method: run 2 also gains
  ASM exposure, ARF columns, real-elevation index-flood regression, and
  the band infrastructure. The two-method comparison must either
  (a) attribute differences honestly to the full method-set delta, or
  (b) include a controlled sub-comparison (re-run a sample of run-2
  facilities under circular on the run-2 branch) to isolate the
  region-method component — the same confound lesson the BOR comparison
  learned the hard way. **Plan for (b): a ~500-facility circular
  control sample on the run-2 branch, giving a clean same-code
  comparison axis.**
- Cluster on a 73k-national manifest will fall back to circular in
  sparse-station geographies by design (the BOR run saw 84/308) —
  fallback rates by region are themselves a run-2 finding, not a bug.
