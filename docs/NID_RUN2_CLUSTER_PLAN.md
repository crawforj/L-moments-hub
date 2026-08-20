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
3. **Run 2 prep** — **COMPLETE as of 2026-08-19** on branch
   `claude/nid-run2-cluster`. What was actually found is recorded under
   each item; several items turned out to hide defects that would have
   damaged run 2 or run 1.

   - [x] **Elevation enrichment for all 73,303 manifest rows** — DONE,
     **fill rate 73,302 / 73,303 = 99.9986%**. Two things had to be
     fixed before the numbers were trustworthy:
     * `elevatr::get_elev_point(src = "aws")` **defaults to `z = 5`**
       (~4 km/pixel) and nobody had pinned it. Benchmarked against 14
       dams of independently known elevation: z=5 gives median |error|
       29 m and **max 294 m** (Taylor Park, CO); z>=8 converges to ~5 m.
       A 294 m error on the attribute the clustering runs on is a real
       mis-clustering risk. Now pinned at **z = 10**.
     * The documented batch-resolution nondeterminism is real:
       `get_elev_raster()` mosaics the bbox of ALL points in a call and
       reprojects, so a point's value depended on its call-mates. New
       `chunked_elevatr_lookup()` bins on a **fixed 1-degree grid**, one
       call per occupied cell (**913 cells**), so a value follows from
       the point's own coordinates alone — reproducible for a given
       (cell_deg, zoom) and invariant to sharding. ~10 min on 6 shards.
     * Also removed `elevatr_lookup()`'s `warning = function(w) NULL`
       handler, which turns one warning into an all-NA result for the
       **entire batch** — silent mass data loss at fleet scale.
     * Spot-checks vs. known elevations (high Colorado, Gulf-coastal
       Florida, Great Plains): **median |error| 4.0 m**, max 63 m. The
       large residuals are all crest-vs-tailwater *definition* at tall
       dams (Grand Coulee -63 m, Shasta -35 m), not DEM error.
     * Unfilled: **1 row, KS00443**, which has no coordinates at all in
       the live NID. It falls back to circular, correctly and logged.
       One row (NE00397) came from a single-point bbox because its
       cell's z=10 mosaic has a nodata pixel at its coordinate.
     * Residual defect left visible, not masked: **AK00061** returns
       -2090 m (Aleutian ocean bathymetry); its coordinate is still
       wrong and the live refresh did not correct it.

   - [x] **CORRECTION — the manifest had to be rebuilt on the LIVE NID
     coordinates.** The first attempt (67369907) built run 2's manifest
     from `config/nid_manifest.csv` **on `main`**, which is the stale
     ~2013 third-party mirror, and sampled the DEM at those coordinates.
     Superseded by f0d45eb2. **`main`'s manifest is stale and must not
     be used as a source for anything** — the authoritative copy is the
     **fleet branch's**, refreshed from the live USACE NID at
     fleet-branch commit `a85ef3d2`. **Run 1 has been using the
     refreshed coordinates all along, and run 2 now does too**, so the
     two-method comparison is not confounded by coordinate vintage.
     Scale: 60,480 rows changed at all, 1,806 by >0.01 deg, **226 by
     >1 deg in lat or lon** (282 by |dlat|+|dlon|, 202 by NID's own
     `coord_drift_km` > 100 km). Worst case TN05102 Tims Ford, **1,111
     km** — lat 25.202 (open Gulf of Mexico) vs 35.19684 (Franklin
     County, TN). Corroborated independently by
     `docs/analysis/nid_coordinate_defects.md`. The correction is
     measurable: spot-check median |error| **8.0 m -> 4.0 m**, and Tims
     Ford went from -3283 m of Gulf bathymetry to 269 m against a 270 m
     reference. Column provenance was verified byte-identical, and
     `drainage_area_mi2` (ARF input, absent from the refresh) was
     carried from the mirror by `facility_id` — id sets identical and
     identically ordered, no duplicates, **all 56,307 non-NA values
     carried, none lost**.

   - [x] **Port the fold-in fix** — DONE, but `c664dd32` **alone was not
     sufficient**. It adds five `append_cum()` calls in
     `run_nid_tranche.R` that read
     `outputs/batch/{stations_used,stations_removed,regional_lmoments,
     gof,growth_curve}.csv` — files written by a *different* run-1-only
     commit, `af7775cd`. Without that writer the five calls are silent
     no-ops (`append_cum_csv` returns NULL for a missing src), run 2
     would publish only **3 of the 8** cumulative tables, and the
     workflow's restore step — which treats any missing asset as an
     inconsistent seed and refuses to run — would have **killed the
     chain on round 2**. Both are now ported.

   - [x] **Template elevation band verified wide on main** — confirmed
     `elevation_band_m: [-100, 6200]` in `config/como.yml`. Of the
     enriched fleet, 0 rows exceed 6200 m and 1 falls below -100 m (the
     AK00061 defect above).

   - [x] **Fresh branch + fresh ledgers** — `claude/nid-run2-cluster`
     cut from `main`. Branching inherited a **stale 453-facility
     ledger** (an old desktop run committed 2026-08-11) plus its
     cumulative CIRCULAR-method tables; left in place run 2 would have
     skipped 453 facilities it never ran under cluster and folded
     circular rows into its own tables. All five files **deleted**, not
     truncated: the workflow's `[ -s completed_ids.csv ]` gate passes a
     zero-byte file, but `run_nid_tranche.R` then calls `read.csv()` on
     it, which **errors** on 0 bytes and would kill round 1. An absent
     file passes both. Rationale is recorded in
     `data/nid_progress/.gitkeep`.

   - [x] **Config**: `region_method = cluster` on all 73,303 rows — the
     `gen_configs_from_manifest()` per-row override (`run_batch.R`,
     verified by reading it). `config/como.yml`'s template default
     **stays `circular`**, so nothing else inherits it silently.

   - [x] **Release-tag isolation (highest-risk item)** — see item 4a
     below. The tag is now bound to the branch, on `main`.

   - [x] **Single distribution family across durations** — see the
     caveats section; new for run 2, off everywhere else.

   - **Cluster caches**: `build_station_clusters()` grid-cell caches are
     method-infrastructure — prewarm optionally; they rebuild on demand.
     (The smoke test exercised and cached three of them.)

3a. **Smoke test evidence (2026-08-19, 3 facilities, run locally).**
   Tuttle Creek KS, Gavins Point NE, Dillon CO, from the corrected
   manifest via `run_nid_tranche.R`:
   - **Cluster genuinely engages** — 3 real assignments
     (`nearest centroid dist=0.244/0.317/0.198`, all "clear choice"),
     and **zero** `site attributes (e.g. elevation) unavailable`
     fallbacks, which is the entire point of the enrichment.
   - **`site_id` is in the DDF output** — 72/72 rows, 3 distinct ids.
   - **The fold-in keys correctly** — all **8** cumulative tables
     written and folded, each carrying `site_id` with 3 distinct ids,
     and re-folding the same batch leaves the row count unchanged
     (idempotent, 72 -> 72).

4. **Launch run 2** on the same self-chaining workflow. **Exact command:**

   ```
   gh workflow run nid-batch.yml --repo crawforj/L-moments-hub \
     -f branch=claude/nid-run2-cluster \
     -f release_tag=nid-run2-data
   ```

   Do **not** run this until run 1 has finished and been archived
   (steps 1-2 above). Expected faster than run 1: the GHCN station
   cache (~18k stations, committed) is warm — station downloads were a
   large share of run-1 cost. Genuine new cost: cluster builds + any new
   stations the different regions pull in. Still expect **multi-day**,
   not multi-week.

4a. **How run 1's archived data is protected from run 2.** Each run keeps
   its ~950MB of cumulative tables as assets on its own release tag, and
   uploads use `gh release upload --clobber`, so a run writing the wrong
   tag would **destroy** the other run's dataset. The tag was hard-coded
   `nid-run1-data` in both the restore and upload steps. It is now a
   `workflow_dispatch` input (`release_tag`, default `nid-run1-data`)
   **plus** a "Resolve release tag" step that binds tag to branch:

   | branch | tag |
   |---|---|
   | `claude/desktop-nid-ad-hoc` | `nid-run1-data` |
   | `claude/nid-run2-cluster` | `nid-run2-data` |

   **The binding, not the default, is the protection.** The chain step
   deliberately propagates only `branch`, so any input it omits reverts
   to the DEFAULT in every successor — a plain `release_tag` input would
   have had run 2's *first chained successor* silently start writing run
   1's tag. Fixed twice over: the chain now propagates the resolved tag
   explicitly (it is an identity, not a tuning knob), and the binding
   would correct it regardless. A contradicting tag is a hard failure,
   as is an unbound branch requesting either reserved tag; because the
   resolve step runs before `restore`, and the chain step requires
   `steps.restore.outcome == 'success'`, a bad tag **pauses** the fleet
   instead of looping. Verified against all nine branch/tag
   combinations: run 1 resolves to `nid-run1-data` with the default,
   with the input absent, and refuses to run with a contradicting tag.
   Note this took effect immediately — `workflow_dispatch` takes the
   workflow file from the **default branch**, so the live run-1 chain
   picked it up on its next hop.
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
  stays true and documented for that dataset). **Done 2026-08-19**, at
  99.9986% fill — see item 3.

## Known caveats to carry into run 2's docs from day one

- Run 1 vs run 2 differ in MORE than region method: run 2 also gains
  ASM exposure, ARF columns, real-elevation index-flood regression,
  the band infrastructure, and — added 2026-08-19 — **one distribution
  family per facility across all durations** (next bullet). The
  two-method comparison must either
  (a) attribute differences honestly to the full method-set delta, or
  (b) include a controlled sub-comparison (re-run a sample of run-2
  facilities under circular on the run-2 branch) to isolate the
  region-method component — the same confound lesson the BOR comparison
  learned the hard way. **Plan for (b): a ~500-facility circular
  control sample on the run-2 branch, giving a clean same-code
  comparison axis.**
- **Single distribution family across durations — a deliberate run-1 vs
  run-2 methodological difference.** Run 1 fits each duration
  independently, which lets the 24-h and 72-h growth curves cross in the
  extrapolated tail: ~15% of facilities report a 72-h depth BELOW their
  24-h depth at T>=200, which is physically impossible. Per
  `docs/analysis/cross_duration_consistency.md` the mechanism is
  strictly directional family selection — a crossing occurs iff the 24-h
  fit picks a heavier-tailed family than the 72-h fit (24h=GLO/72h=GEV
  crosses 93.8% of the time; every mirrored ordering crosses 0.0%), and
  forcing one family per facility removes ~71% of crossings at source.
  NOAA adopted the same policy for Atlas 14 for the same reason (Vol. 2
  and Vol. 9 sec. 4.6.3). **Run 2 turns this on fleet-wide** via the
  manifest's `single_family` column; the template default
  (`distribution_single_family`) stays FALSE so run 1, the BOR sets and
  the golden fixture are untouched. Selection is **minimax |Z|** (the
  family whose worst-fitting duration fits best), which keeps the
  |Z| <= 1.64 acceptance rule meaningful and avoids pooling
  non-independent per-duration statistics — see `choose_single_family()`
  in `R/05_distribution.R` for the full justification. Expert-review and
  config overrides still take precedence.
  **Consequence for the two-method comparison: it must NOT attribute
  family-consistency effects to the region method.** This delta changes
  tail depths directly — in the 3-facility smoke test the flag turned a
  T=10,000 72h/24h ratio of 0.748 (a crossing) into 1.103 (no crossing)
  at one facility. The ~500-facility controlled sub-comparison in the
  bullet above must therefore hold BOTH the region method and this flag
  fixed to isolate either one.
  Honest cost: consistency can mean accepting a worse fit at one
  duration. Where no single family is acceptable at both, the
  per-duration `acceptable` flag goes FALSE and flows into
  `needs_review` — surfaced, not hidden.
- Cluster on a 73k-national manifest will fall back to circular in
  sparse-station geographies by design (the BOR run saw 84/308) —
  fallback rates by region are themselves a run-2 finding, not a bug.
  Run 2 also carries **one facility (KS00443) with no coordinates at
  all** in the live NID, which will fall back for that reason.
- **`main`'s `config/nid_manifest.csv` is the stale ~2013 third-party
  mirror and must not be used as a source for anything.** The
  authoritative manifest is the fleet branch's live-NID refresh
  (`a85ef3d2`), which run 1 and run 2 both use. See
  `docs/analysis/nid_coordinate_defects.md`.
- The live-NID refresh updated storage values without re-sorting, so the
  manifest is **no longer strictly ordered by `nid_storage_acreft`**
  (7,126 inversions) — `run_nid_tranche.R`'s "largest remaining dams
  first" is now only approximate. This affects run 1 and run 2
  identically (both use the same file) and is immaterial to the final
  dataset, since every facility is processed eventually. Left unsorted
  deliberately, so run 2's tranche order matches run 1's.
