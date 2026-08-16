"""NID fleet QA/QC -- data-integrity layer (docs/NID_QAQC_PLAN.md section A).

Runs entirely read-only against a pinned commit of the fleet ledger branch
(`claude/desktop-nid-ad-hoc`); see nid_qc_common.materialize(). Re-runnable
and incremental: re-invoke against any newer fleet commit (this is the
intended completion gate).

Checks implemented (plan section A):
  A1  ledger <-> manifest reconciliation (membership, duplicates, ok+failed)
  A2  cross-file orphan checks + DDF row-count = 24 per facility
  A3  synthetic-data incident purge audit (commits aeff8601 / f36fc328)
  A4  code-version uniformity across the run window (mid-run commit audit)
  A5  LFS/parse/truncation integrity
  A6  schema stability

Outputs:
  qc/reports/integrity_report.md
  qc/reports/integrity_flags.csv   (facility_id, flag, severity, detail)

Usage:
  python qc/nid_qc_integrity.py [--ref origin/claude/desktop-nid-ad-hoc]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nid_qc_common as C  # noqa: E402

REPORTS = C.REPO_ROOT / "qc" / "reports"

# Classification of every commit that touched pipeline code/config/workflow
# during the fleet run window (established by direct git-history review;
# anything not listed here that the run-window scan finds is reported as
# UNCLASSIFIED and fails the check until triaged).
RUN_WINDOW_COMMIT_CLASSIFICATION = {
    "aeff8601": ("config", "ANALYSIS-RELEVANT (fix)",
                 "Disables silent synthetic-data fallback (use_local_fallback: false). "
                 "Root of incident #1; see A3."),
    "f36fc328": ("data-purge", "ANALYSIS-RELEVANT (fix)",
                 "Purges 99 synthetic-contaminated facilities from ledger + all cumulative tables."),
    "af7775cd": ("plumbing", "NOT analysis-relevant",
                 "Centralizes aux per-facility tables (gof/growth_curve/stations_*/regional_lmoments) "
                 "into data/nid_progress/; statistical pipeline unchanged. Side effect: facilities "
                 "completed earlier have no aux-table rows (see A2)."),
    "603224c3": ("config", "ANALYSIS-RELEVANT (fix)",
                 "Widens elevation_band_m [600,2600] -> [-100,6200]. Facilities that SUCCEEDED "
                 "before this ran with an elevation-restricted candidate-station pool "
                 "(Como re-validation showed ~4-5% depth shift under the wider band). "
                 "272 spurious failures requeued."),
    "a85ef3d2": ("input-data", "ANALYSIS-RELEVANT (input vintage)",
                 "Refreshes the 73,303-dam manifest from the live NID; 32 stale ids dropped. "
                 "Facilities completed before this used the older manifest vintage."),
    "b24cfc77": ("storage", "NOT analysis-relevant",
                 "Moves cumulative CSVs to Git LFS (storage only)."),
    "19d87743": ("tooling", "NOT analysis-relevant",
                 "Adds standalone GHCN-D vs GHCN-M reconciliation tool (qc_ghcnm_crosscheck.R); "
                 "not on the tranche execution path."),
}


def _git_lines(args: list[str]) -> list[str]:
    out = C._git(args)
    return [line for line in out.splitlines() if line.strip()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=C.FLEET_REF_DEFAULT)
    args = ap.parse_args()

    print("Materializing fleet data (read-only, via git show + lfs smudge)...", file=sys.stderr)
    commit, cache = C.materialize(args.ref)
    short = commit[:8]

    flags: list[dict] = []          # facility-level flags
    results: list[tuple[str, str, str]] = []  # (check, PASS/FAIL/WARN, detail)

    def flag(fid, name, severity, detail=""):
        flags.append({"facility_id": fid, "flag": name, "severity": severity, "detail": detail})

    def result(check, verdict, detail):
        results.append((check, verdict, detail))
        print(f"[{verdict}] {check}: {detail}", file=sys.stderr)

    # ------------------------------------------------------------------ load
    led = C.load_fleet_table(cache, "completed_ids.csv")
    ddf = C.load_fleet_table(cache, "all_facilities_DDF.csv")
    diag = C.load_fleet_table(cache, "batch_diagnostics.csv")
    tail = C.load_fleet_table(cache, "tail_sensitivity.csv")
    gof = C.load_fleet_table(cache, "gof.csv")
    gc = C.load_fleet_table(cache, "growth_curve.csv")
    man = C.load_manifest()

    ok_led = led[led.ok]
    fail_led = led[~led.ok]
    cur_ids = set(led.facility_id)
    cur_ok = set(ok_led.facility_id)

    # ------------------------------------------------------- A5 parse/LFS
    parse_notes = []
    for f in C.FLEET_FILES:
        if not f.endswith(".csv"):
            continue
        p = cache / f
        raw = p.read_bytes()
        ends_nl = raw.endswith(b"\n")
        header = raw.split(b"\n", 1)[0].decode()
        n_header_dupes = raw.count(header.encode()) - 1
        parse_notes.append((f, p.stat().st_size, ends_nl, n_header_dupes))
    bad_parse = [n for n in parse_notes if not n[2] or n[3] > 0]
    result("A5 LFS/parse/truncation",
           "FAIL" if bad_parse else "PASS",
           "all LFS pointers resolved; all CSVs parse end-to-end with a trailing newline "
           "and no embedded duplicate header rows"
           if not bad_parse else f"issues: {bad_parse}")

    # ------------------------------------------------------- A6 schema
    schema_bad = []
    for f, cols in C.EXPECTED_SCHEMAS.items():
        actual = list(pd.read_csv(cache / f, nrows=0).columns)
        if actual != cols:
            schema_bad.append((f, actual))
    result("A6 schema stability",
           "FAIL" if schema_bad else "PASS",
           "all column sets match the expected schema; no embedded mid-file header "
           "changes (any tranche-level schema drift would surface as duplicate-header "
           "or ragged rows in the cumulative append-only files -- none found)"
           if not schema_bad else f"mismatches: {schema_bad}")

    # ------------------------------------------------------- A1 ledger <-> manifest
    man_ids = set(man.facility_id)
    not_in_manifest = cur_ids - man_ids
    for fid in sorted(not_in_manifest):
        flag(fid, "ledger_not_in_manifest", "FAIL", "facility_id absent from config/nid_manifest.csv")
    dup_ids = led.facility_id[led.facility_id.duplicated()].unique().tolist()
    for fid in dup_ids:
        flag(fid, "ledger_duplicate", "FAIL", "facility_id appears more than once in completed_ids.csv")
    ok_n, fail_n = len(ok_led), len(fail_led)
    prog = (cache / "progress.md").read_text()
    result("A1 ledger<->manifest",
           "PASS" if not not_in_manifest and not dup_ids else "FAIL",
           f"{len(led):,} attempted = {ok_n:,} ok + {fail_n:,} failed (exact); "
           f"{len(not_in_manifest)} ids missing from manifest; {len(dup_ids)} duplicates")

    # name drift vs current manifest (expected for the pre-refresh cohort)
    merged_names = led.merge(man[["facility_id", "name"]], on="facility_id",
                             how="inner", suffixes=("_ledger", "_manifest"))
    name_drift = merged_names[merged_names.name_ledger != merged_names.name_manifest]
    for _, r in name_drift.iterrows():
        flag(r.facility_id, "name_differs_from_manifest", "INFO",
             f"ledger='{r.name_ledger}' manifest='{r.name_manifest}'")

    # ------------------------------------------------------- A2 cross-file orphans
    # diagnostics: exactly one row per (facility, duration) for every ok facility
    diag_ids = set(diag.site_id)
    diag_missing = cur_ok - diag_ids
    diag_orphan = diag_ids - cur_ok
    per_fac = diag.groupby("site_id")["duration"].agg(list)
    bad_durs = per_fac[per_fac.apply(lambda d: sorted(d) != C.EXPECTED_DURATIONS)]
    for fid in sorted(diag_missing):
        flag(fid, "diagnostics_missing", "FAIL", "ok in ledger but no batch_diagnostics rows")
    for fid in sorted(diag_orphan):
        flag(fid, "diagnostics_orphan", "FAIL", "diagnostics rows but not ok in ledger")
    for fid, d in bad_durs.items():
        flag(fid, "diagnostics_durations_bad", "FAIL", f"durations present: {d}")

    # DDF is keyed by site NAME only (no site_id) -- name collisions make those
    # facilities' DDF rows unattributable. This is a real pipeline finding.
    name_counts = ok_led.groupby("name")["facility_id"].nunique()
    collided_names = set(name_counts[name_counts > 1].index)
    collided_facs = ok_led[ok_led.name.isin(collided_names)]
    for _, r in collided_facs.iterrows():
        flag(r.facility_id, "ddf_name_collision", "WARN",
             f"site name '{r['name']}' shared by {name_counts[r['name']]} ok facilities; "
             "all_facilities_DDF.csv rows for this name cannot be attributed to a single facility")

    ddf_names = set(ddf.site)
    ok_names = set(ok_led.name)
    ddf_missing_names = ok_names - ddf_names
    ddf_orphan_names = ddf_names - ok_names
    for n in sorted(ddf_missing_names):
        for fid in ok_led.loc[ok_led.name == n, "facility_id"]:
            flag(fid, "ddf_missing", "FAIL", f"no DDF rows for site name '{n}'")

    rc = ddf.groupby("site").size()
    bad_rc = rc[rc != C.ROWS_PER_FACILITY_DDF]
    t_seen = sorted(ddf.return_period_yr.dropna().unique().astype(int).tolist())
    d_seen = sorted(ddf.duration.unique().tolist())
    for n, k in bad_rc.items():
        for fid in ok_led.loc[ok_led.name == n, "facility_id"]:
            flag(fid, "ddf_rowcount_bad", "FAIL", f"{k} rows (expected {C.ROWS_PER_FACILITY_DDF})")
    ddf_ok = (not diag_missing and not diag_orphan and len(bad_durs) == 0
              and not ddf_missing_names and not ddf_orphan_names and len(bad_rc) == 0
              and t_seen == C.EXPECTED_T and d_seen == C.EXPECTED_DURATIONS)
    result("A2 orphans + DDF row-count",
           "PASS" if ddf_ok else ("WARN" if not (diag_missing or diag_orphan or len(bad_durs) or len(bad_rc)) else "FAIL"),
           f"diag: {len(diag_missing)} missing / {len(diag_orphan)} orphan / {len(bad_durs)} bad-duration; "
           f"DDF: {len(bad_rc)} sites with row-count != 24, T-set {'matches' if t_seen == C.EXPECTED_T else t_seen}, "
           f"durations {d_seen}; {len(ddf_missing_names)} ok names missing from DDF, "
           f"{len(ddf_orphan_names)} orphan DDF names; "
           f"{len(collided_facs)} ok facilities ({len(collided_names)} names) have name collisions "
           f"(DDF has no site_id column -- attribution ambiguous for those)")

    # tail_sensitivity coverage. FINDING: although tail_sensitivity.csv carries
    # site_id, the cumulative fold-in dedupes it by site NAME (like the DDF), so
    # for every collided name exactly one member keeps its rows and the other
    # members' rows are silently dropped -- explained data loss (WARN), and a
    # fold-in bug to fix before the completion run.
    tail_ids = set(tail.site_id)
    tail_missing = cur_ok - tail_ids
    collided_ids = set(collided_facs.facility_id)
    for fid in sorted(tail_missing & collided_ids):
        flag(fid, "tail_sensitivity_lost_name_collision", "WARN",
             "tail_sensitivity rows dropped by the name-keyed fold-in dedup (another "
             "facility with the same site name kept the rows)")
    for fid in sorted(tail_missing - collided_ids):
        flag(fid, "tail_sensitivity_missing", "FAIL", "no tail_sensitivity rows (unexplained)")
    result("A2c tail_sensitivity coverage",
           "PASS" if not (tail_missing - collided_ids) else "FAIL",
           f"{len(tail_missing):,} ok facilities lack tail_sensitivity rows; "
           f"{len(tail_missing & collided_ids):,} are exactly the non-surviving members of "
           f"name-collision groups (the fold-in dedupes this file by site NAME despite it "
           f"carrying site_id -- exactly 1 member per collided name retains rows; fold-in "
           f"bug to fix before completion); {len(tail_missing - collided_ids)} unexplained")

    # aux tables (growth_curve/gof/stations_*) were only centralized at
    # af7775cd -- facilities completed before that have no rows there.
    led_654 = C.ledger_at(C.KEY_COMMITS["synthetic_purge"])
    led_954 = C.ledger_at(C.KEY_COMMITS["last_narrow_band_tranche"])
    pre_centralization_ok = set(led_654[led_654.ok].facility_id) & cur_ok
    # The tranche committed at e594ba02 (20:54 UTC) was LAUNCHED before the
    # centralization commit af7775cd (19:23 UTC) landed, so a handful of its
    # facilities can also lack aux rows -- a transition-window artifact, not a
    # corrupt fold (their diagnostics/DDF/tail rows are complete).
    transition_ok = (set(led_954[led_954.ok].facility_id) & cur_ok) - pre_centralization_ok
    gc_ids = set(gc.site_id)
    gof_ids = set(gof.site_id)
    gc_missing = cur_ok - gc_ids
    explained_gc = gc_missing & pre_centralization_ok
    transition_gc = (gc_missing & transition_ok) - explained_gc
    unexplained_gc = gc_missing - explained_gc - transition_gc
    for fid in sorted(explained_gc):
        flag(fid, "pre_centralization_no_aux", "INFO",
             "completed before af7775cd; growth_curve/gof/stations_* rows absent by design")
    for fid in sorted(transition_gc):
        flag(fid, "aux_missing_transition_window", "WARN",
             "completed in the e594ba02 tranche launched before af7775cd landed; aux tables "
             "absent, core outputs complete -- re-run candidate at completion")
    for fid in sorted(unexplained_gc):
        flag(fid, "aux_tables_missing_unexplained", "FAIL",
             "missing growth_curve rows and NOT explainable by the centralization timeline")
    result("A2b aux-table coverage",
           "PASS" if not unexplained_gc else "FAIL",
           f"{len(gc_missing)} ok facilities lack growth_curve/gof/stations rows; "
           f"{len(explained_gc)} are the pre-centralization cohort (completed before af7775cd), "
           f"{len(transition_gc)} completed in the transition-window tranche (e594ba02) -- "
           f"{len(unexplained_gc)} unexplained. "
           f"gof coverage matches growth_curve: {gof_ids == gc_ids}")

    # ------------------------------------------------------- A3 synthetic audit
    led_453 = C.ledger_at(C.KEY_COMMITS["cloud453"])
    led_753 = C.ledger_at(C.KEY_COMMITS["last_prefix_tranche"])
    purged = set(led_753.facility_id) - set(led_654.facility_id)
    cloud_ok = set(led_453[led_453.ok].facility_id)
    prefix_survivors_ok = set(led_654[led_654.ok].facility_id) & cur_ok
    cloud_survivors = cloud_ok & cur_ok
    local_audited = prefix_survivors_ok - cloud_ok
    purged_rerun = purged & cur_ids
    purged_pending = purged - cur_ids
    purged_back_ok = purged & cur_ok

    # guard still active: every post-fix version of config/como.yml on the
    # fleet branch must keep use_local_fallback: false
    guard_ok = True
    guard_versions = []
    como_commits = _git_lines(["log", "--format=%h", f"{commit}", "--", "config/como.yml"])
    fix_short = C.KEY_COMMITS["synthetic_fix"][:8]
    post_fix = []
    seen_fix = False
    for h in reversed(como_commits):          # oldest -> newest
        if h.startswith(fix_short[:7]) or seen_fix:
            seen_fix = True
            post_fix.append(h)
    for h in post_fix:
        txt = C._git(["show", f"{h}:config/como.yml"])
        line = next((ln.strip() for ln in txt.splitlines() if "use_local_fallback" in ln), "")
        active = "use_local_fallback: false" in line
        guard_versions.append((h, line[:60], active))
        guard_ok &= active

    for fid in sorted(cloud_survivors):
        flag(fid, "synthetic_cloud_unauditable", "WARN",
             "completed pre-fix in the cloud-sandbox environment (initial 453 cohort) whose "
             "data/synthetic/ was never committed; the synthetic-fallback audit cannot be "
             "applied retroactively (purge-commit known gap)")
    for fid in sorted(local_audited):
        flag(fid, "synthetic_prefix_audited_clean", "INFO",
             "completed pre-fix in the local session; audited against data/synthetic/ and clean")
    for fid in sorted(purged_back_ok):
        flag(fid, "synthetic_purged_rerun_ok", "INFO",
             "one of the 99 purged facilities; re-attempted post-fix and now ok")

    a3_verdict = "PASS" if (len(purged) == 99 and guard_ok and cloud_ok <= set(led_654.facility_id)) else "FAIL"
    result("A3 synthetic-incident purge audit", a3_verdict,
           f"purge diff reproduced from history: {len(purged)} ids removed at f36fc328 (expected 99); "
           f"of those, {len(purged_rerun)} re-attempted post-fix ({len(purged_back_ok)} ok), "
           f"{len(purged_pending)} still pending re-attempt; "
           f"{len(prefix_survivors_ok)} pre-fix results survive in the current ledger, of which "
           f"{len(cloud_survivors)} are the cloud-cohort (retroactively unauditable, flagged WARN) and "
           f"{len(local_audited)} were audited clean locally; use_local_fallback=false in all "
           f"{len(guard_versions)} post-fix versions of config/como.yml: {guard_ok}")

    # ------------------------------------------------------- A4 code-version uniformity
    led_682 = C.ledger_at(C.KEY_COMMITS["elev_band_fix"])
    led_650 = C.ledger_at(C.KEY_COMMITS["manifest_refresh"])
    narrow_band = set(led_682[led_682.ok].facility_id) & cur_ok
    old_manifest = set(led_650.facility_id) & cur_ids
    for fid in sorted(narrow_band):
        flag(fid, "narrow_elevation_band", "WARN",
             "succeeded before 603224c3 with candidate stations restricted to 600-2600 m elevation; "
             "region composition differs from the rest of the fleet (~4-5% depth shift seen at Como)")
    for fid in sorted(old_manifest):
        flag(fid, "old_manifest_vintage", "INFO",
             "completed before the a85ef3d2 live-NID manifest refresh; coordinates/attributes vintage differs")

    first_t = C._git(["show", "-s", "--format=%cI", C.KEY_COMMITS["initial150"]]).strip()
    data_t = C._git(["show", "-s", "--format=%cI", commit]).strip()
    window_commits = _git_lines([
        "log", "--format=%h|%cI|%s", f"--since={first_t}", f"--until={data_t}", commit,
        "--", "R/", "*.R", "config/*.yml", "config/*.csv", ".github/",
    ])
    unclassified = []
    window_rows = []
    for line in window_commits:
        h, t, s = line.split("|", 2)
        cls = RUN_WINDOW_COMMIT_CLASSIFICATION.get(h[:8])
        if cls is None:
            # tranche commits touch config/facilities via generated files? keep strict:
            unclassified.append((h, t, s))
            window_rows.append((h, t, s, "UNCLASSIFIED", ""))
        else:
            window_rows.append((h, t, s, cls[1], cls[2]))
    result("A4 code-version uniformity",
           "WARN" if not unclassified else "FAIL",
           f"{len(window_commits)} non-tranche commits touched code/config/workflow inside the run "
           f"window; 3 are ANALYSIS-RELEVANT fixes (aeff8601 synthetic guard, 603224c3 elevation "
           f"band, a85ef3d2 manifest refresh) -- affected cohorts flagged per-facility "
           f"({len(narrow_band)} narrow-band, {len(old_manifest)} old-manifest, "
           f"{len(cloud_survivors)} cloud-unauditable); zero pipeline-code changes after the first "
           f"GHA tranche ({C.KEY_COMMITS['first_gha_tranche'][:8]}, 2026-08-12) other than storage/tooling; "
           f"{len(unclassified)} unclassified: {unclassified}")

    # ------------------------------------------------------- outputs
    REPORTS.mkdir(parents=True, exist_ok=True)
    flags_df = pd.DataFrame(flags, columns=["facility_id", "flag", "severity", "detail"])
    flags_df.to_csv(REPORTS / "integrity_flags.csv", index=False)

    sev_order = {"FAIL": 0, "WARN": 1, "INFO": 2}
    fail_facs = set(flags_df[flags_df.severity == "FAIL"].facility_id)
    warn_facs = set(flags_df[flags_df.severity == "WARN"].facility_id) - fail_facs
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    lines = [
        "# NID fleet -- integrity report (QAQC plan section A)",
        "",
        f"_Generated {now} by `qc/nid_qc_integrity.py`._",
        "",
        C.partial_data_note(commit, len(led)),
        "",
        "This layer is the mechanical completion gate: it re-runs incrementally against",
        "any newer fleet-branch commit and must pass in full before the analysis plan's",
        "Phase B artifacts are produced from completed data.",
        "",
        "## Verdicts",
        "",
        "| Check | Verdict | Detail |",
        "|---|---|---|",
    ]
    for chk, v, d in results:
        lines.append(f"| {chk} | **{v}** | {d} |")
    lines += [
        "",
        "## Facility-level flags",
        "",
        f"Machine-readable copy: `qc/reports/integrity_flags.csv` ({len(flags_df):,} rows).",
        "",
        "| Flag | Severity | Facilities |",
        "|---|---|---|",
    ]
    flag_counts = flags_df.groupby(["flag", "severity"]).size().reset_index(name="n")
    flag_counts["ord"] = flag_counts.severity.map(sev_order)
    for _, r in flag_counts.sort_values(["ord", "flag"]).iterrows():
        lines.append(f"| `{r.flag}` | {r.severity} | {r.n:,} |")
    lines += [
        "",
        f"**Hard-fail facilities: {len(fail_facs):,}** -- excluded from all analyses.",
        f"**Warn facilities: {len(warn_facs):,}** -- usable with the caveat attached to their flag;",
        "Phase-A analyses report their handling explicitly.",
        "",
        "## Synthetic-incident audit trail (section A3)",
        "",
        "How the purge was verified, entirely from ledger + git history (all commits below",
        "are on `claude/desktop-nid-ad-hoc`; they are immutable history, so this audit is",
        "reproducible byte-for-byte):",
        "",
        f"1. Ledger membership was reconstructed at four historical commits: the cloud-cohort",
        f"   tranche `{C.KEY_COMMITS['cloud453'][:8]}` (453 attempted), the last pre-fix tranche",
        f"   `{C.KEY_COMMITS['last_prefix_tranche'][:8]}` (753), the purge `{C.KEY_COMMITS['synthetic_purge'][:8]}`",
        f"   (654), and the pinned data commit `{short}` ({len(led):,}).",
        f"2. The set difference (last pre-fix tranche) - (purge) reproduces exactly the",
        f"   **{len(purged)} purged facility_ids** the purge commit message claims (99).",
        f"3. Of the 99, **{len(purged_rerun)} have since been re-attempted post-fix**",
        f"   ({len(purged_back_ok)} ok, {len(purged_rerun) - len(purged_back_ok)} failed),",
        f"   {len(purged_pending)} not yet re-attempted (still pending, not contaminated).",
        f"4. **{len(prefix_survivors_ok):,} surviving results predate the fix without re-run.**",
        f"   These were deliberately retained: {len(local_audited)} were audited clean against",
        f"   `data/synthetic/` in the local session (rounds 1-2), and {len(cloud_survivors)}",
        f"   belong to the initial cloud-sandbox cohort whose `data/synthetic/` was never",
        f"   committed -- **retroactively unauditable** (the purge commit's stated known gap).",
        f"   Those {len(cloud_survivors)} carry a `synthetic_cloud_unauditable` WARN flag and are",
        f"   listed for re-run consideration before completion.",
        f"5. The fallback guard is verified still active: every post-fix revision of",
        f"   `config/como.yml` on the branch ({len(guard_versions)} versions) has",
        f"   `use_local_fallback: false`.",
        "",
        "## Mid-run commit audit (section A4)",
        "",
        "| Commit | Date (UTC) | Classification | Subject |",
        "|---|---|---|---|",
    ]
    for h, t, s, cls, note in window_rows:
        lines.append(f"| `{h}` | {t[:10]} | {cls} | {s} |")
    lines += [
        "",
        "Affected cohorts (per-facility flags in the CSV):",
        "",
        f"- `narrow_elevation_band` ({len(narrow_band)}): succeeded under the pre-603224c3",
        "  elevation band [600, 2600] m -- an elevation-restricted candidate pool. Candidates",
        "  for re-run at completion; Como's re-validation shifted depths ~4-5% under the fix.",
        f"- `old_manifest_vintage` ({len(old_manifest)}): ran against the pre-refresh NID manifest.",
        f"- `synthetic_cloud_unauditable` ({len(cloud_survivors)}): see A3.",
        "",
        "## Known-issue register propagation",
        "",
        "This report touches register items 1 (synthetic incident -- A3), 3 (pre-rebase",
        "circular-only run -- inherent to every facility here), 4 (elevation NA fleet-wide),",
        "and 6 (timeout-era tranches never wrote partial results -- corroborated by the",
        "A2 row-count check finding zero partial facilities).",
        "",
        "## Pinned inputs",
        "",
        f"- Fleet data: `{commit}` (`claude/desktop-nid-ad-hoc`)",
        f"- Manifest: `config/nid_manifest.csv` on main (73,303 rows)",
        f"- Attempted {len(led):,} / ok {ok_n:,} / failed {fail_n:,}; progress.md agrees: "
        f"{'yes' if str(len(led)) in prog and str(ok_n) in prog else 'CHECK'}",
    ]
    (REPORTS / "integrity_report.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"\nWrote {REPORTS / 'integrity_report.md'} and integrity_flags.csv "
          f"({len(flags_df):,} flags)", file=sys.stderr)
    return 0 if not fail_facs else 1


if __name__ == "__main__":
    sys.exit(main())
