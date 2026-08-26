# DDF legacy-row repair report

_Generated 2026-08-26 13:43 UTC by `qc/nid_qc_repair_ddf.py` against `7c323846`._

| quantity | rows |
|---|---:|
| input rows (excl. header) | 1,828,200 |
| kept: already id-keyed | 1,135,944 |
| repaired: site_id backfilled (unique-name owner) | 622,680 |
| deleted: stale pre-fix duplicates (all members re-run) | 69,552 |
| deleted: unresolvable (collided name, member missing rows) | 24 |
| **output rows** | **1,758,624** |

Verification: 73,276 ok facilities x 24 rows = 1,758,624
== output rows (exact). No NA site_id remains. Facilities re-queued (end with
zero rows, honestly): ['CA01230'].

The repair touches ONLY row membership and the site_id field of backfilled
rows; no depth value is modified anywhere.
