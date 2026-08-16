# NID fleet output — QA/QC plan

**Date:** 2026-08-16. **Status: plan; §A can run now on partial data.**
Companion to `NID_ANALYSIS_PLAN.md` — this is the gate in front of it.
Principle carried from the whole program: **a control group proved the
BOR region-method comparison clean; a proxy flag was overturned by
measurement; a "dead" gage turned out alive.** QC here is not a
checklist formality — it is where several of this project's most
important findings have actually come from.

## A. Data-integrity layer (mechanical; script `qc/nid_qc_integrity.R` or py)

1. **Ledger ↔ manifest reconciliation.** Every `completed_ids.csv` row
   maps to exactly one manifest facility; no duplicates (the BOR-side
   duplicate-launch incidents make this a real risk, not a formality);
   attempted = ok + failed exactly.
2. **Cross-file orphan check.** Facilities present in
   `all_facilities_DDF.csv` but absent from `batch_diagnostics.csv` (or
   vice versa), and DDF row-count per facility = exactly
   durations × return periods (24 rows). Partial-facility rows = corrupt
   tranche fold-in → re-run those facilities.
3. **Synthetic-data incident audit (known issue #1).** Early in the run,
   ~110 facilities silently used synthetic fallback data and were purged
   (commits `aeff8601`/`f36fc328`). Re-verify the purge: no facility in
   the final ledger predates the fix without a post-fix re-run; the
   fallback block is still active in the workflow (`use_local_fallback`
   guard). This is the single most dangerous known failure mode —
   fabricated-but-plausible results.
4. **Code-version uniformity.** The fleet branch was deliberately never
   rebased, but confirm zero *analysis-relevant* code changes landed on
   the branch mid-run (git log of `R/` on the fleet branch across the run
   window); document any, with affected-tranche ranges.
5. **LFS integrity**: every LFS pointer resolves; file sizes sane; final
   ledgers parse clean end-to-end (the truncation check that has already
   been run once on `completed_ids.csv`, repeated at completion).
6. **Schema stability** across all tranches (column sets identical; no
   silent type drift).

## B. Statistical-sanity layer (per facility, automated flags not drops)

1. **Monotonicity**: depth strictly increasing in T within each duration;
   72-h ≥ 24-h at every T. Any violation = hard flag (engine bug or
   corrupt fold).
2. **Physical bounds**: 24-h/100-yr depth within generous CONUS bounds
   (~25–800 mm; AK/HI/territories separately); index flood positive and
   consistent with the depth scale. Out-of-bounds → facility-level review
   flag with the region map.
3. **Diagnostic-profile review**: national distributions of H1, |Z|,
   z_margin, tail_spread_pct — compared against the BOR-308 profile as
   the reference shape. A national profile that differs wildly from the
   validated subset's is itself a finding to explain before use.
4. **`needs_review` accounting**: rate by state/region; any region with
   an extreme rate gets a targeted look before its facilities feed any
   analysis.

## C. Spatial-coherence layer (catches input errors statistics can't)

1. **Coordinate sanity**: every facility inside its NID state (buffered);
   none in open water/outside CONUS grid unless flagged as AK/HI/PR.
   (Known issue #2: coordinates are an unverified NID mirror; the BOR
   subset found real errors — Glen Anne's 100× drainage-area slip.)
2. **Neighbor-consistency test**: for dams within ~10 km of each other
   (shared stations, near-identical climate), large depth divergence at
   the same T flags a bad coordinate, bad elevation band, or unstable
   region — the fleet-scale version of the control-group trick. Emit a
   ranked divergence list for review.
3. **Region-footprint spot audit**: for a stratified sample (see D1),
   inspect the region maps for divide-crossing/rain-shadow violations —
   the checklist's §2, sampled.

## D. Human-review layer (sampling, not exhaustive)

1. **Stratified deep-review sample**: ~75–100 facilities stratified by
   (Atlas 14 volume region × H1 tercile × station-count tercile ×
   needs_review flag), each walked through the full
   `expert_review_checklist.md` sections 1–5. Goal: an estimated
   *defect rate with confidence bounds* for the fleet, not per-dam
   certification. Findings feed fixes; the sample re-audits after any fix.
2. **Golden anchors**: Como (the validated reference) + the BOR-308
   overlap set. **BOR-vs-NID cross-check**: the same physical dams ran
   through both pipelines with different manifests months apart —
   systematic depth comparison at matched facilities; disagreement beyond
   tolerance (input-vintage differences aside) = investigation, agreement
   = a publishable reproducibility statement (analysis plan B4).
3. **External anchor**: the deep-review sample's Atlas 14 comparisons
   double as ground-truthing for the B1 mega-comparison scraper (hand-
   verify ≥20 PFDS values against the web UI before trusting it at scale).

## E. QC of the analyses themselves (from the analysis plan)

For **every** analysis artifact:
1. **Pinned inputs**: the ledger commit hash the analysis ran against,
   recorded in the artifact; re-runs must reproduce byte-identical
   summary tables.
2. **Independent verification pass**: a second pass (separate session or
   adversarial sub-review) attempts to refute each artifact's headline
   claim before it's published — the same discipline that caught the
   region-method confound. Specifically: any claimed spatial pattern gets
   tested against a null (spatial autocorrelation ≠ signal); any trend
   claim gets a significance test and a first/last-decade sanity split
   (the snow-eater intensity non-finding is the model: report
   disagreements with expectations, don't smooth them).
3. **Known-issue propagation**: each artifact lists which register items
   (below) touch it, explicitly.
4. **Publication-safety review**: checked against the analysis plan's
   public/private boundary before any commit to this public repo.

## F. Known-issue register (carried into every downstream use)

| # | Issue | Status |
|---|---|---|
| 1 | Synthetic-fallback incident (~110 facilities, purged) | verify purge (§A3) |
| 2 | NID mirror coordinates/attributes unverified; real errors found in BOR subset | permanent caveat + §C1/C2 |
| 3 | Fleet ran pre-rebase: circular region only, no ASM, no region-method band | rebase decision open; B3 sample quantifies the cost |
| 4 | Elevation `NA` fleet-wide in the NID manifest → index-flood regression silently degrades to regional mean | permanent caveat until enrichment decision |
| 5 | Gauge undercatch biases mountain depths low; stationarity assumed (snow-eater work shows the direction of that error) | permanent caveat |
| 6 | GHA timeout-era tranches (pre-fix) wasted compute but, by design, never wrote partial results | verified design; re-verify via §A2 |
| 7 | ~15% failure rate in sparse-gauge regions (BOR-observed) — failures are *reported*, not silent | becomes analysis A1 |

## Sequencing

1. **Now (partial data)**: build + run §A and §B scripts against the
   current ledger; they become the automatic completion gate and also run
   incrementally on each remaining tranche batch.
2. **At completion**: full A–C pass; then D1 sampling + D2 anchors.
3. **Per analysis**: §E, always.

Nothing in the analysis plan proceeds on data that hasn't passed A–C;
nothing publishes without E. QC findings are findings — they get written
up with the same prominence as results, because in this program they have
repeatedly *been* the results.
