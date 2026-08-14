# Cluster vs. circular region method — fleet-wide result (all 308 BOR dams)

`docs/REGION_METHOD_SENSITIVITY.md` answered "does region-building method
matter" for two hand-picked facilities (Como, Hoover). This page answers it
for the **whole BOR-308 fleet**, now that elevation is real for every
facility (see `docs/ASSUMPTIONS_AND_LIMITATIONS.md` §B5) and `cluster` can
actually run instead of silently falling back to `circular`.

## Run

- **Circular baseline**: the pre-existing fleet run in the main clone,
  `C:\dev\L-moments-hub\outputs\batch\all_facilities_DDF_full308.csv`
  (`region.method: circular`, the manifest default).
- **Cluster run**: `Rscript run_batch.R --manifest
  config/facilities_BOR_cluster.csv` (a copy of `facilities_BOR.csv` with
  `region_method: cluster` added per row — `facilities_BOR.csv` itself was
  deliberately left untouched; promoting `cluster` to the fleet *default* is
  a separate decision, not made here). Run 2026-08-14, ~35 sec/facility
  (faster than the 10-dam timing test predicted), full 308 in ~3.1 hours.
  **292/308 (94.8%) succeeded**; 16 failed for legitimate, unrelated reasons
  (8 transient GHCN download errors, 8 genuine too-few-stations-for-a-region
  cases) — not a `cluster`-specific failure mode, comparable to this
  project's usual fleet failure rate.

## Headline result: the reviewer's concern is real for most of the fleet, not a Como-specific curiosity

Comparing every successfully-completed facility × duration combination
(578 total) at the two return periods a dam-safety screen cares about most:

| Return period | Median spread | Mean spread | Max spread |
|---|---:|---:|---:|
| T = 100 yr | 12.2% | 16.4% | 95.3% |
| T = 10,000 yr | 17.5% | 22.0% | 93.8% |

**Distribution of T=10,000yr spread across all 578 combinations:**

| Spread | Count | % of fleet |
|---|---:|---:|
| < 5% | 92 | 15.9% |
| 5-15% | 160 | 27.7% |
| 15-30% | 155 | 26.8% |
| 30-50% | 131 | 22.7% |
| > 50% | 40 | 6.9% |

**62.8% of dam×duration combinations (363/578) show a >15% spread at
either T=100 or T=10,000 yr.** This is materially larger and more
widespread than the two-facility spot check suggested (Como: 18-22%,
Hoover: 27-48%) — those weren't outliers, but they also weren't
representative of the tail of the distribution, where some dams move by
70-95% depending on which region-building method is used.

**Top 15 by T=10,000yr spread:**

| Facility | Duration | T=100 spread | T=10,000 spread |
|---|---|---:|---:|
| Bradbury | 24h | 95.3% | 93.8% |
| Jamestown Dam | 24h | 71.2% | 76.0% |
| Adahl-Jones Project | 24h | 69.5% | 73.5% |
| Lauro | 24h | 77.7% | 71.1% |
| Little Panoche Detention | 72h | 49.7% | 70.8% |
| BOR Deer Creek | 72h | 67.2% | 67.9% |
| Upper Wheeler Saddle Dam | 72h | 52.8% | 66.9% |
| Upper Wheeler Saddle Dam | 24h | 50.6% | 64.9% |
| East Canyon | 24h | 55.6% | 62.4% |
| Ochoco | 72h | 54.8% | 62.3% |
| Reservoir A | 72h | 27.3% | 61.3% |
| San Justo | 72h | 40.8% | 60.7% |
| Jamestown Dam | 72h | 56.7% | 60.4% |
| Westside Deten Dk 3 | 24h | 55.0% | 60.3% |
| West Side Detention Dike No. 2 | 24h | 56.1% | 60.0% |

## Reading this honestly

- **This is not evidence that `cluster` is "more correct" than `circular`,
  or vice versa.** Both methods pass the same homogeneity test per facility
  (see the per-facility spot checks in `REGION_METHOD_SENSITIVITY.md` — both
  Como region variants and both Hoover region variants were "homogeneous" by
  the pipeline's own H1 statistic). A large spread means the *choice*
  matters, not that one number is right and the other wrong — that
  determination needs a reviewing hydrologist looking at which station pool
  is actually climatologically appropriate for each specific dam, exactly
  what `expert_review_checklist.md`'s region-composition section now asks
  for.
- **No obvious single driver identified yet.** The top-spread facilities
  span multiple states/regions (CA, ND, others) — this wasn't run down to a
  root cause (e.g. sparse-station areas, coastal/orographic transitions,
  small drainage areas) in this pass; that's a natural next analysis if
  useful, not done here to avoid scope creep on what was asked.
- **Every one of the 292 completed facilities now has both a `circular` and
  a `cluster` result on file** — `outputs/batch/all_facilities_DDF.csv` in
  this worktree (cluster) and the main clone's
  `all_facilities_DDF_full308.csv` (circular) — so any facility's specific
  comparison can be pulled directly rather than re-run.
- **This still isn't the full H&W (1997) picture.** Subjective and
  objective partitioning remain unimplemented (see
  `ASSUMPTIONS_AND_LIMITATIONS.md` §B5) — this result is "circular vs. one
  alternative," not "circular vs. every alternative the reviewer raised."

## What this means for the fleet-default decision

`docs/REGION_METHOD_SENSITIVITY.md`'s Part A Phase 4 ("promote `cluster` to
the fleet default, if Reclamation signs off") was written before this
fleet-scale result existed. This result doesn't resolve that decision — it
sharpens the stakes of it: with 62.8% of the fleet showing a >15% tail
spread between methods, *not* picking a reviewed default (or flagging
per-facility which method's result is being relied on) means a large
fraction of BOR dam screenings are silently sitting on an unreviewed
methodological choice. That's a call for the project owner / Reclamation,
not something resolved by this batch run.
