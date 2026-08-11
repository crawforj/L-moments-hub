# NID fleet progress

- Facilities attempted: **650 / 73303** (0.9%)
- Succeeded: 643 | failed (genuinely too-few-stations etc.): ~7 (net of requeues below)
- Cache stations now: 4814

- **272 facilities requeued 2026-08-11**: failed under the old elevation_band_m:
  [600,2600] filter (Como-Montana-specific), which had ZERO real coverage
  reason -- confirmed real GHCN stations exist nearby but all outside that
  band. Band widened to [-100,6200]; these will be re-attempted fresh.
- **32 facilities requeued 2026-08-11**: refresh_nid_live.R pulled the
  CURRENT National Inventory of Dams (live, public, no-auth ESRI service --
  our config/*.csv manifests were a ~2013 third-party mirror) and found these
  32 already-completed facilities had coordinates that drifted >5km between
  the old and current NID -- e.g. several Oregon dams whose old longitude
  (-111.110, actually in Idaho) was a data error in the 2013 mirror, corrected
  in the live NID. Manifests refreshed (coordinates, river, storage, drainage
  area, + new operational_status/nid_data_updated/coord_drift_km columns);
  these 32 will be re-attempted at their corrected locations.

Resumable: each run does the next tranche (largest remaining dams first) and
records progress here + in data/nid_progress/. See docs for the schedule.
