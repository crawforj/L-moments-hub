# NID fleet progress

- Facilities attempted: **654 / 73303** (0.9%)
- Succeeded: 545 | failed (too-few-stations etc.): 109
- Cache stations now: 4664

- **99 facilities purged 2026-08-11**: silently used SYNTHETIC data due to a GHCN
  download failure, recorded as successful. use_local_fallback is now false
  in the batch template, so these will be correctly re-attempted (real data
  or an honest failure) on the next tranche.

Resumable: each run does the next tranche (largest remaining dams first) and
records progress here + in data/nid_progress/. See docs for the schedule.
