# NID fleet progress

- Facilities attempted: **682 / 73303** (0.9%)
- Succeeded: 643 | failed (genuinely too-few-stations etc.): 39
- Cache stations now: 4814

- **272 facilities requeued 2026-08-11**: failed under the old elevation_band_m:
  [600,2600] filter (Como-Montana-specific), which had ZERO real coverage
  reason -- confirmed real GHCN stations exist nearby but all outside that
  band. Band widened to [-100,6200]; these will be re-attempted fresh.

Resumable: each run does the next tranche (largest remaining dams first) and
records progress here + in data/nid_progress/. See docs for the schedule.
