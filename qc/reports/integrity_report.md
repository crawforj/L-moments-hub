# NID fleet -- integrity report (QAQC plan section A)

_Generated 2026-08-26 13:48 UTC by `qc/nid_qc_integrity.py`._

**Partial data.** Input pinned to fleet-branch commit `7c323846bc7d074eb5f37c2c835b9ef4ae7ebfea` (`claude/desktop-nid-ad-hoc`), N = 73,303 of 73,303 facilities attempted (100.0%). The fleet runs largest-storage-first, so this partial sample over-represents large dams; refresh every artifact at fleet completion before treating any number here as final.

This layer is the mechanical completion gate: it re-runs incrementally against
any newer fleet-branch commit and must pass in full before the analysis plan's
Phase B artifacts are produced from completed data.

## Verdicts

| Check | Verdict | Detail |
|---|---|---|
| A5 LFS/parse/truncation | **PASS** | all LFS pointers resolved; all CSVs parse end-to-end with a trailing newline and no embedded duplicate header rows |
| A6 schema stability | **PASS** | all column sets match the expected schema; no embedded mid-file header changes (any tranche-level schema drift would surface as duplicate-header or ragged rows in the cumulative append-only files -- none found) |
| A1 ledger<->manifest | **PASS** | 73,303 attempted = 73,277 ok + 26 failed (exact); 0 ids missing from manifest; 0 duplicates |
| A2 orphans + DDF row-count | **WARN** | diag: 0 missing / 0 orphan / 0 bad-duration; DDF: 0 sites with row-count != 24, T-set matches, durations ['24h', '72h']; DDF fully site_id-keyed (post-repair): 1 ok facilities missing rows, 0 with row-count != 24; 14727 facilities share a name with another (3380 names) but attribution is exact by id |
| A2c tail_sensitivity coverage | **PASS** | 0 ok facilities lack tail_sensitivity rows; 0 are exactly the non-surviving members of name-collision groups (the fold-in dedupes this file by site NAME despite it carrying site_id -- exactly 1 member per collided name retains rows; fold-in bug to fix before completion); 0 unexplained |
| A2b aux-table coverage | **PASS** | 0 ok facilities lack growth_curve/gof/stations rows; 0 are the pre-centralization cohort (completed before af7775cd), 0 completed in the transition-window tranche (e594ba02) -- 0 unexplained. gof coverage matches growth_curve: True |
| A3 synthetic-incident purge audit | **PASS** | purge diff reproduced from history: 99 ids removed at f36fc328 (expected 99); of those, 99 re-attempted post-fix (99 ok), 0 still pending re-attempt; 545 pre-fix results survive in the current ledger, of which 394 are the cloud-cohort (retroactively unauditable, flagged WARN) and 151 were audited clean locally; use_local_fallback=false in all 2 post-fix versions of config/como.yml: True |
| A4 code-version uniformity | **WARN** | 6 non-tranche commits touched code/config/workflow inside the run window; 3 are ANALYSIS-RELEVANT fixes (aeff8601 synthetic guard, 603224c3 elevation band, a85ef3d2 manifest refresh) -- affected cohorts flagged per-facility (643 narrow-band, 650 old-manifest, 394 cloud-unauditable); zero pipeline-code changes after the first GHA tranche (04b849d6, 2026-08-12) other than storage/tooling; 0 unclassified: [] |

## Facility-level flags

Machine-readable copy: `qc/reports/integrity_flags.csv` (1,938 rows).

| Flag | Severity | Facilities |
|---|---|---|
| `ddf_missing` | FAIL | 1 |
| `narrow_elevation_band` | WARN | 643 |
| `synthetic_cloud_unauditable` | WARN | 394 |
| `old_manifest_vintage` | INFO | 650 |
| `synthetic_prefix_audited_clean` | INFO | 151 |
| `synthetic_purged_rerun_ok` | INFO | 99 |

**Hard-fail facilities: 1** -- excluded from all analyses.
**Warn facilities: 643** -- usable with the caveat attached to their flag;
Phase-A analyses report their handling explicitly.

## Synthetic-incident audit trail (section A3)

How the purge was verified, entirely from ledger + git history (all commits below
are on `claude/desktop-nid-ad-hoc`; they are immutable history, so this audit is
reproducible byte-for-byte):

1. Ledger membership was reconstructed at four historical commits: the cloud-cohort
   tranche `ccdeabde` (453 attempted), the last pre-fix tranche
   `27587ac8` (753), the purge `f36fc328`
   (654), and the pinned data commit `7c323846` (73,303).
2. The set difference (last pre-fix tranche) - (purge) reproduces exactly the
   **99 purged facility_ids** the purge commit message claims (99).
3. Of the 99, **99 have since been re-attempted post-fix**
   (99 ok, 0 failed),
   0 not yet re-attempted (still pending, not contaminated).
4. **545 surviving results predate the fix without re-run.**
   These were deliberately retained: 151 were audited clean against
   `data/synthetic/` in the local session (rounds 1-2), and 394
   belong to the initial cloud-sandbox cohort whose `data/synthetic/` was never
   committed -- **retroactively unauditable** (the purge commit's stated known gap).
   Those 394 carry a `synthetic_cloud_unauditable` WARN flag and are
   listed for re-run consideration before completion.
5. The fallback guard is verified still active: every post-fix revision of
   `config/como.yml` on the branch (2 versions) has
   `use_local_fallback: false`.

## Mid-run commit audit (section A4)

| Commit | Date (UTC) | Classification | Subject |
|---|---|---|---|
| `c664dd32` | 2026-08-16 | ANALYSIS-RELEVANT (fix) | Fix fleet fold-in: key cumulative per-facility ledgers by site_id, not dam name |
| `19d87743` | 2026-08-13 | NOT analysis-relevant | Add GHCN-Daily vs GHCN-Monthly reconciliation tool + document the gap |
| `a85ef3d2` | 2026-08-11 | ANALYSIS-RELEVANT (input vintage) | Refresh dam manifests from the LIVE current NID; add prefetch progress heartbeat |
| `603224c3` | 2026-08-11 | ANALYSIS-RELEVANT (fix) | Fix elevation_band_m: was silently zeroing candidate stations for ~87% of the country |
| `af7775cd` | 2026-08-11 | NOT analysis-relevant | Centralize fleet-wide per-facility tables; enable LFS for GHCN cache going forward |
| `aeff8601` | 2026-08-11 | ANALYSIS-RELEVANT (fix) | Temporarily block silent synthetic-data fallback in fleet batch runs |

Affected cohorts (per-facility flags in the CSV):

- `narrow_elevation_band` (643): succeeded under the pre-603224c3
  elevation band [600, 2600] m -- an elevation-restricted candidate pool. Candidates
  for re-run at completion; Como's re-validation shifted depths ~4-5% under the fix.
- `old_manifest_vintage` (650): ran against the pre-refresh NID manifest.
- `synthetic_cloud_unauditable` (394): see A3.

## Known-issue register propagation

This report touches register items 1 (synthetic incident -- A3), 3 (pre-rebase
circular-only run -- inherent to every facility here), 4 (elevation NA fleet-wide),
and 6 (timeout-era tranches never wrote partial results -- corroborated by the
A2 row-count check finding zero partial facilities).

## Pinned inputs

- Fleet data: `7c323846bc7d074eb5f37c2c835b9ef4ae7ebfea` (`claude/desktop-nid-ad-hoc`)
- Manifest: `config/nid_manifest.csv` on main (73,303 rows)
- Attempted 73,303 / ok 73,277 / failed 26; progress.md agrees: yes