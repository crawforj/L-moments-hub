"""One-time deterministic repair of legacy NA-site_id rows in all_facilities_DDF.csv.

Background (2026-08-26). The 2026-08-16 fold-in fix (c664dd32) made new DDF rows
carry site_id, and the 15,340-facility remediation re-ran every member of every
collided name. What NEITHER did was touch the legacy rows written before the fix:
692,256 rows (37.9% of the table) still had site_id=NA. Those legacy rows are
why the completion integrity gate failed A2 with 15,280 ddf_rowcount_bad
facilities: a re-run facility's name now carries BOTH its new id-keyed rows and
the old NA rows, so per-name row counts exceed 24.

Every NA row is resolvable deterministically from the ledger:

  STALE     - every ok facility bearing this name has id-keyed rows already
              (i.e. the name's members were all re-run). The NA rows are the
              pre-fix values of one of them; they are superseded duplicates.
              -> DELETE.
  BACKFILL  - the name maps to exactly ONE ok facility in the ledger.
              Attribution is unambiguous regardless of run vintage.
              -> SET site_id.
  UNRESOLVABLE - the name maps to >1 ok facility and at least one member lacks
              id-keyed rows (its remediation never produced rows). The NA rows
              could belong to any member; pre-fix name-keyed dedup destroyed
              the information. -> DELETE rows, QUEUE the missing members for
              re-run (they end with no DDF rows at all, which is honest).

Verification (hard assertions, script fails loudly rather than write bad data):
  - every ok facility except the queued ones ends with exactly 24 rows
  - no NA site_id remains
  - row arithmetic reconciles exactly

Usage: python qc/nid_qc_repair_ddf.py <cache_dir>
Writes: <cache_dir>/all_facilities_DDF.repaired.csv
        qc/reports/ddf_repair_report.md
        qc/reports/ddf_repair_rerun_queue.csv
"""
from __future__ import annotations

import csv
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

CACHE = Path(sys.argv[1])
REPORTS = Path(__file__).resolve().parent / "reports"
REPORTS.mkdir(parents=True, exist_ok=True)

# ---- ledger: name -> ok facility ids -------------------------------------
name2ok: dict[str, set[str]] = defaultdict(set)
n_ok = 0
with open(CACHE / "completed_ids.csv", newline="", encoding="utf-8", errors="replace") as f:
    for r in csv.DictReader(f):
        ok = str(r.get("ok", "TRUE")).strip().upper() not in ("FALSE", "0", "NO")
        if ok:
            name2ok[(r.get("name") or "").strip()].add(r["facility_id"].strip())
            n_ok += 1

# ---- pass 1: which facilities already have id-keyed rows ------------------
ids_with_rows: set[str] = set()
src = CACHE / "all_facilities_DDF.csv"
with open(src, newline="", encoding="utf-8", errors="replace") as f:
    rdr = csv.DictReader(f)
    header = rdr.fieldnames
    assert header is not None and "site_id" in header, f"no site_id column in {header}"
    for r in rdr:
        sid = (r.get("site_id") or "").strip()
        if sid not in ("", "NA"):
            ids_with_rows.add(sid)

# ---- classify names, then rewrite in one streaming pass -------------------
decision: dict[str, tuple[str, str | None]] = {}   # name -> (action, backfill_id)
rerun_queue: set[str] = set()
for nm, ids in name2ok.items():
    missing = ids - ids_with_rows
    if not missing:
        decision[nm] = ("stale", None)
    elif len(ids) == 1:
        decision[nm] = ("backfill", next(iter(ids)))
    else:
        decision[nm] = ("drop_unresolvable", None)
        rerun_queue |= missing

stats = Counter()
dst = CACHE / "all_facilities_DDF.repaired.csv"
per_fac = Counter()
with open(src, newline="", encoding="utf-8", errors="replace") as f, \
     open(dst, "w", newline="", encoding="utf-8") as g:
    rdr = csv.DictReader(f)
    w = csv.DictWriter(g, fieldnames=header, quoting=csv.QUOTE_ALL)
    w.writeheader()
    for r in rdr:
        sid = (r.get("site_id") or "").strip()
        if sid not in ("", "NA"):
            stats["kept_id_keyed"] += 1
            per_fac[sid] += 1
            w.writerow(r)
            continue
        nm = (r.get("site") or "").strip()
        action, bid = decision.get(nm, ("orphan_name", None))
        stats[action] += 1
        if action == "backfill":
            r["site_id"] = bid
            per_fac[bid] += 1
            w.writerow(r)
        # stale / drop_unresolvable / orphan_name -> row not written

# ---- hard verification ----------------------------------------------------
assert stats["orphan_name"] == 0, f"rows under names absent from ok-ledger: {stats['orphan_name']}"

all_ok_ids = set().union(*name2ok.values()) if name2ok else set()
expect_full = all_ok_ids - rerun_queue
bad_counts = {fid: c for fid, c in per_fac.items() if c != 24}
missing_fac = expect_full - set(per_fac)
assert not bad_counts, f"{len(bad_counts)} facilities without exactly 24 rows, e.g. {list(bad_counts.items())[:5]}"
assert not missing_fac, f"{len(missing_fac)} ok facilities have no rows and are not queued: {sorted(missing_fac)[:5]}"

total_written = sum(stats[k] for k in ("kept_id_keyed", "backfill"))
assert total_written == 24 * len(expect_full), (total_written, 24 * len(expect_full))

# ---- outputs --------------------------------------------------------------
with open(REPORTS / "ddf_repair_rerun_queue.csv", "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["facility_id", "reason"])
    for fid in sorted(rerun_queue):
        w.writerow([fid, "collided name; pre-fix rows unattributable; no post-fix rows"])

now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
report = f"""# DDF legacy-row repair report

_Generated {now} by `qc/nid_qc_repair_ddf.py` against `{CACHE.name}`._

| quantity | rows |
|---|---:|
| input rows (excl. header) | {sum(stats.values()):,} |
| kept: already id-keyed | {stats['kept_id_keyed']:,} |
| repaired: site_id backfilled (unique-name owner) | {stats['backfill']:,} |
| deleted: stale pre-fix duplicates (all members re-run) | {stats['stale']:,} |
| deleted: unresolvable (collided name, member missing rows) | {stats['drop_unresolvable']:,} |
| **output rows** | **{total_written:,}** |

Verification: {len(expect_full):,} ok facilities x 24 rows = {24 * len(expect_full):,}
== output rows (exact). No NA site_id remains. Facilities re-queued (end with
zero rows, honestly): {sorted(rerun_queue)}.

The repair touches ONLY row membership and the site_id field of backfilled
rows; no depth value is modified anywhere.
"""
(REPORTS / "ddf_repair_report.md").write_text(report, encoding="utf-8")
print(report)
print(f"wrote {dst}")
