# NID coordinate defects — verification, provenance, and disposition

_Follow-up item 3 of `docs/NID_COMPLETION_RUNBOOK.md` §4; known-issue register
item 9 (`docs/NID_QAQC_PLAN.md` §F). Written 2026-08-19. Read-only investigation;
no coordinate in any repo data file was edited._

## Headline: the defects are ours, not the NID's

The spatial-coherence gate (`qc/nid_qc_sanity.py`, check C1) flagged 12
facilities whose coordinates fall outside their own state's buffered bounding
box. The runbook queued this as "report upstream to NID if a channel exists."

**No upstream report is warranted.** All 12 coordinates are **correct in the live
authoritative NID**, verified individually against the public USACE NID API on
2026-08-19. The bad coordinates come from the **stale ~2013 third-party mirror**
(`lcford2/predict-release`, see `DATA_SOURCES.md` §2a) that seeded
`config/nid_manifest.csv` **on `main`**.

Three further facts follow from the verification and change the disposition
completely:

1. The fleet branch's manifest **already carries the corrected live coordinates**
   — refreshed at fleet-branch commit `a85ef3d2` (2026-08-11, "Refresh dam
   manifests from the LIVE current NID"), which also added a `coord_drift_km`
   column recording exactly how far each mirror coordinate had moved.
2. **The fleet results for these 12 dams are not affected.** All 12 were
   processed long after the refresh (they are small-storage dams, and the fleet
   runs largest-storage-first), and their station pools sit on the _correct_
   locations — verified below.
3. The 12 flags are therefore **false positives of the QC layer**, caused by
   `qc/nid_qc_common.py` reading `config/nid_manifest.csv` from the `main`
   working tree (stale mirror) rather than the fleet branch's refreshed manifest
   that the run actually used.

The residual real issue is a repo-hygiene one: `main`'s manifest is stale and the
QC layer reads it. That is dispositioned in "What to do instead" below.

## Evidence, per dam

`stale` = `config/nid_manifest.csv` on `main`. `live` = USACE NID API,
`GET https://nid.sec.usace.army.mil/api/dams/{NIDID}/inventory`, fetched
2026-08-19 (HTTP 200 for all 12). `drift` = `coord_drift_km` as computed by
`refresh_nid_live.R` at fleet-branch commit `a85ef3d2`. `pool` = median
(lat, lon) of the 24-h candidate stations the fleet actually used for that
facility, from `stations_used.csv` at release tag `nid-run1-data`.

| NID ID | Name (live) | stale lat, lon | live lat, lon | drift km | live county, state | station pool used | evidence the stale value is wrong |
|---|---|---|---|---|---|---|---|
| OR00183 | Hult Pond Dam | 44.140, −111.110 | 44.240, −123.495 | 987 | Lane, OR | 44.40, −123.26 | −111.110 at that latitude is **Fremont County, Idaho**; Oregon's east edge is ≈ −116.5 |
| OR00567 | Duncan Reservoir - Dam | 43.070, −111.110 | 43.071, −120.944 | 798 | Lake, OR | 43.04, −121.59 | same placeholder longitude; latitude matches live to 0.001° |
| OR00569 | Mud Lake | 42.210, −111.110 | 42.212, −119.717 | 709 | Lake, OR | 42.24, −120.18 | same placeholder longitude; latitude matches live to 0.002° |
| OR00572 | Round Valley | 42.140, −111.110 | 42.139, −121.072 | 821 | Klamath, OR | 42.23, −121.13 | same; river "Trib Gerber Res" is in Klamath Co. OR, ≈ −121.1 |
| OR00573 | Upper Midway | 42.110, −111.110 | 42.115, −121.026 | 818 | Klamath, OR | 42.21, −121.13 | same; river "Trib Lost River" is Klamath Co. OR |
| OR00574 | Dog Hollow | 42.110, −111.110 | 42.113, −121.104 | 824 | Klamath, OR | 42.21, −121.13 | same; river "E. Branch Lost River" is Klamath Co. OR |
| OR00728 | Lucky | 42.120, −111.110 | 42.124, −119.997 | 733 | Lake, OR | 42.21, −120.56 | same placeholder longitude |
| OR00757 | Big | 42.160, −111.110 | 42.155, −120.011 | 733 | Lake, OR | 42.21, −120.63 | same placeholder longitude |
| TN05102 | Tims Ford Dam | 25.202, −86.278 | 35.197, −86.279 | 1,111 | Franklin, TN | 35.20, −86.44 | point is open Gulf of Mexico — **no US census geography returns for it**, nearest land is Dry Tortugas FL ≈ 349 km away; longitude agrees with live to 4 decimals, latitude differs only in the tens digit (3→2) |
| ND00145 | Garrison Dam / Snake Creek Embankment | 41.607, −101.267 | 47.499, −101.413 | 655 | Mercer, ND | 47.43, −101.40 | 41.607 N is in western Nebraska; longitude agrees to 0.15°, latitude differs in the ones digit (7→1). See the sub-structure note below |
| GA01721 | Butler Reservoir | 33.427, −88.847 | 33.426, −82.099 | 626 | Richmond, GA | 33.53, −82.02 | −88.847 at that latitude is **Oktibbeha County, Mississippi** (Starkville); Butler Creek is in Richmond Co. (Augusta), GA at ≈ −81.94 to −82.01 |
| GA01728 | Soil Erosion Lake | 33.423, −88.172 | 33.422, −82.120 | 562 | Richmond, GA | 33.53, −82.02 | −88.172 at that latitude is **Pickens County, Alabama**; same Butler Creek, Richmond Co., GA |

### Error signatures

The stale values are **not random noise** — three distinct corruption modes are
visible, and each one preserves the coordinate component it did not damage:

- **Constant-fill longitude (the Oregon 8).** Latitudes match live to 0.001–0.005°
  while every longitude is the identical constant **−111.110**. The true live
  longitudes span −119.7 to −123.5, so this is not a transcription slip; it is a
  missing-value fill. `−111.110` is a repeating-digit sentinel that happens to
  land in **Idaho** — Bear Lake County at 42.11 N, Fremont County at 44.14 N
  (the Idaho–Wyoming line is at −111.047, ~5 km east).
- **Single-digit latitude corruption (TN05102, ND00145).** Longitude survives to
  4 and 2 decimals respectively; one latitude digit is wrong (35→25, 47→41).
- **Longitude tens-digit corruption (the Georgia pair).** Latitude survives to
  3 decimals; longitude reads −88.x where live reads −82.x. (The decimal parts
  also differ, which is consistent with an independent later re-survey between
  the 2013 mirror and today — so the digit substitution is the _plausible_
  signature, not a proven one.)

### Sub-structure note: ND00145

The live NID carries Garrison Dam as one dam ID with separate structure rows.
The headline `ND00145` coordinate (47.4986, −101.4128) is the **main dam**, in
Mercer County; the Snake Creek Embankment is structure `ND00145S002` at
(47.6005, −101.2634) in **McLean County**, ~11 km NE, corroborated by USGS gauge
06337930 "Lake Sakakawea in Snake Creek Pumping Plant" at (47.6117, −101.2681).
Our manifest row is named for the embankment but keyed to the dam ID, so:

- the stale longitude (−101.2673) actually matches the **embankment**, which
  reinforces the read that only the latitude was corrupted (47.6 → 41.6);
- the refreshed manifest and the `coord_drift_km` figure use the **main dam**
  coordinate, so ND00145 sits ~11 km and one county off the structure it is
  named for even after the refresh. Immaterial at a ~120 km station-search
  radius, but worth recording rather than discovering later.

### The Oregon placeholder is larger than the 8 flagged dams

`config/nid_manifest.csv` on `main` has **15 rows** at longitude −111.110:
**14 Oregon dams** plus **NM00074** (Piedra Lumbre Det Dam 07, whose −111.110
lands in Coconino County, Arizona). Only 8 flagged because only 8 have been
attempted so far — the flagged 8 are precisely the 8 largest by NID storage
(228–2,719 acre-ft) and the 7 unflagged are the smallest (43–184 acre-ft), which
is exactly what largest-storage-first ordering predicts. **At fleet completion the
same false-positive class will grow from 8 to 15** unless the manifest source is
fixed first.

(OR00107 and NM00074 return HTTP 404 from the live NID API — those NIDIDs no
longer exist upstream. That is a mirror-vintage artifact too, not a defect to
report.)

### The bounding-box screen catches only a small fraction of the drift

`coord_drift_km` on the fleet-branch manifest quantifies the whole problem, not
just the 12 that happened to cross a state line:

| mirror-vs-live coordinate drift | facilities | % of matched |
|---|---|---|
| > 0.1 km | 10,894 | 14.9% |
| > 1 km | 2,142 | 2.9% |
| > 10 km | 541 | 0.74% |
| > 100 km | **202** | 0.28% |
| > 500 km | 21 | 0.03% |

(66,349 of 73,303 manifest rows matched a live NID record; 6,954 did not.)

Georgia alone has **81** facilities with >100 km drift in the stale mirror, of
which the bbox screen flagged **2**. The bbox test is a gross-error screen, as
documented — this table is the honest measure of the stale mirror's coordinate
quality, and it is the number to cite, not "12".

## Exclusion policy — and why it should be revisited

Current behaviour (unchanged by this document):

- `qc/nid_qc_sanity.py` C1 emits `coord_outside_state_bbox` as a **WARN**, not a
  drop — flags, not drops, per `NID_QAQC_PLAN.md`.
- `analysis/a2_tail_geography.py` and `analysis/a3_heterogeneity.py` drop the
  coordinate-flagged facilities **from map layers only**, keeping them in
  national statistics on the stated grounds that "their diagnostics are
  position-independent, only their dots would be misplaced."
- Register item 9 says the per-facility results are "suspect (wrong station
  pool)".

The station-pool column in the table above **refutes the "wrong station pool"
part of item 9 for all 12 facilities.** Every pool sits on the live location:
OR00572's stations centre at (42.23, −121.13) in Klamath County, not at
−111.11; TN05102's at (35.20, −86.44) in Franklin County, not in the Gulf;
ND00145's at (47.43, −101.40) in Mercer County, not in Nebraska; the Georgia
pair's at (33.53, −82.02) near Augusta, not in Mississippi. These 12 results are
**as good as any other facility's**, and the map-layer exclusion is currently
discarding good data on the strength of a stale lookup table.

**No local coordinate edit is proposed or made.** The register's item-2 policy
(upstream data stays upstream) still holds, and it is satisfied here by _syncing
from upstream_, not by hand-patching values.

## What to do instead of reporting upstream — a decision for the owner

Ordered cheapest-first; all are outside this document's file ownership and none
has been executed.

1. **Point the QC layer at the manifest the fleet actually ran against.**
   `qc/nid_qc_common.py:MANIFEST_PATH` resolves to `config/nid_manifest.csv` in
   the `main` working tree. The fleet branch's refreshed manifest is the correct
   input for auditing fleet output. This alone clears all 12 flags and prevents
   the completion-pass growth to 15.
2. **Sync `main`'s `config/nid_manifest.csv` from fleet-branch `a85ef3d2`**  —
   **time-sensitive.** As of 2026-08-19 the run-2 prep work (elevation
   enrichment, `region_method`) is being layered onto `main`'s manifest while it
   still carries the stale coordinates, including all 15 `−111.110` rows. If
   run 2 launches from this file, the 202 >100 km drift facilities will run
   against wrong station pools for real — which is the failure run 1 avoided
   only because the fleet branch was refreshed. Merge the live coordinates
   before run-2 launch. Also commit
   `refresh_nid_live.R` to `main` (it exists only on the fleet branch
   today, so `main` cannot currently reproduce the refresh). Update
   `DATA_SOURCES.md` §2a, which still describes the manifest as the ~2013 mirror.
3. **Rewrite known-issue register item 9** from "upstream NID coordinate defects"
   to "stale-mirror coordinate defects on `main`, corrected upstream, refreshed
   on the fleet branch" — and carry the >100 km drift count (202) as the scope
   figure rather than 12.
4. **Restore the 12 to map layers** in the Phase-A refresh (runbook §3), using
   live coordinates.
5. **Re-run candidates: none.** Item 9 lists these as re-run candidates "if
   upstream fixes coordinates". Upstream never had them wrong and the fleet
   already used the right ones, so no re-run is owed.

## Is there an upstream reporting channel? (yes — documented for completeness)

Researched 2026-08-19. We are not using it, because there is nothing to report;
recorded here so the question does not have to be re-answered.

- **Channel: `NID@usace.army.mil`.** A mailto, published four ways — the
  site-footer "Feedback" link ("Notice something wrong about your location, map,
  or the dam details?"), the footer "Helpdesk" link, the Contact Us page
  (`https://nid.sec.usace.army.mil/nid/#/help/contact-us`, whose entire content is
  that address), and the API spec's `info.description` at
  `https://nid.sec.usace.army.mil/api/developer/json`. **There is no web form, no
  ticket system, and no public issue tracker.**
  Both nid.sec.usace.army.mil front-ends are JavaScript SPAs, so these strings
  were read out of the deployed application bundles
  (`/_astro/Footer.BgpEZsLr.js`; `/nid/app.384f773c542033050b60.js`) rather than
  from server-rendered HTML — plain fetches of `/faq`, `/contact`, `/about`
  return 404 because the content sits behind hash routes.
- **USACE is explicitly not the data owner.** NID FAQ, "Data in the NID":
  "USACE does some quality assurance on the data provided; however, **the agency
  regulating the particular dam is responsible for the data and its
  correctness**." Since November 2021 state and federal regulators enter data
  directly.
- **Route corrections by the record's `sourceAgency` field, not by the NID ID's
  state prefix.** The prefix is misleading: TN05102 (Tims Ford) is submitted by
  the **Tennessee Valley Authority**, not TDEC; the 14 Oregon dams are submitted
  by the **Bureau of Land Management** (state regulator OWRD); ND00145 by
  **USACE Omaha District**; the Georgia pair by the **US Army** (Fort
  Eisenhower). A correction mailed to a state dam-safety office for any of these
  would go to the wrong desk.
- **No coordinate-accuracy specification is published.** The NID data dictionary
  defines latitude/longitude only as "at dam centerline as a single value in
  decimal degrees" — no datum, no accuracy or precision requirement, no
  "not surveyed" caveat — and the QA process is nowhere documented beyond the
  FAQ's "some quality assurance". That gap is worth noting in any future
  coordinate-quality discussion; it is not a defect to file.

### Draft message — HOLD, do not send

Nothing here is currently sendable, because every defect we found is in our own
stale copy. This template is kept only so that a genuine future finding can be
reported without re-deriving the routing. **Fill in a real, live-NID-verified
defect before using it; delete this section if item 9 is closed out.**

> **To:** `NID@usace.army.mil` (cc: the record's `sourceAgency` dam-safety contact)
> **Subject:** Possible coordinate error in NID record \<NIDID\> (\<Dam Name\>, \<State\>)
>
> Hello,
>
> While using the public NID API for a research-scale precipitation-frequency
> screening study, we found a record whose published coordinates appear to place
> the dam outside its listed state.
>
> - NID ID: \<NIDID\> — \<Dam Name\>, \<County\>, \<State\>
> - Published coordinates: \<lat\>, \<lon\> (retrieved from
>   `https://nid.sec.usace.army.mil/api/dams/<NIDID>/inventory` on \<date\>)
> - Observation: that point falls in \<state / open water\>, approximately
>   \<N\> km from the listed county.
> - Supporting detail from the same record: the listed river (\<riverName\>) and
>   county (\<county\>) are consistent with a location near \<lat', lon'\>.
>
> We have not modified the data and are not requesting anything beyond your
> awareness; we understand from the NID FAQ that the regulating agency is
> responsible for record correctness, so we have copied \<sourceAgency\>.
>
> Happy to provide the full list if a bulk check would be useful.
>
> \<name\>, \<affiliation\>

## Provenance

- Live NID: `https://nid.sec.usace.army.mil/api/dams/{NIDID}/inventory`, all 12
  fetched 2026-08-19, HTTP 200. Live `submitDate` values for these records are
  2021-06-15 to 2024-01-17, i.e. every one predates this investigation — the
  upstream data has been correct for years.
- Stale manifest: `config/nid_manifest.csv` on `main` (last touched by
  `d3211831`), sourced per `DATA_SOURCES.md` §2a.
- Refreshed manifest + `coord_drift_km`: fleet branch
  `claude/desktop-nid-ad-hoc` at `a85ef3d2`.
- Station pools: `stations_used.csv` from release tag `nid-run1-data`
  (`nid_state.json`: 50,451 facilities attempted, uploaded 2026-08-20T03:23Z).
- Flags reproduced from `qc/reports/sanity_flags.csv` and
  `qc/reports/sanity_report.md` §C1.
- **Independent corroboration of the live coordinates** (i.e. not the NID API
  alone), fetched 2026-08-19: NID national bulk CSV
  `https://nid.sec.usace.army.mil/api/nation/csv`; USGS NWIS stations 06337930
  (Snake Creek Pumping Plant) and 02196925 (Butler Creek at GA 56, near Augusta,
  GA, at 33.384, −82.003); USBR Gerber Dam project page
  (`https://www.usbr.gov/projects/index.php?id=73`, 42.2017, −121.1283);
  BLM Hult Dam & Reservoir page; GNIS Butler Creek, Richmond County GA
  (feature 312100). County/land determinations for the stale points from the
  FCC Census Area API (`https://geo.fcc.gov/api/census/area`), which returns an
  empty result set for the Tims Ford stale point — i.e. it is not in any US
  census geography, confirming open water.
- NID channel research: strings read from the deployed SPA bundles
  `https://nid.sec.usace.army.mil/_astro/Footer.BgpEZsLr.js` and
  `https://nid.sec.usace.army.mil/nid/app.384f773c542033050b60.js`, and from the
  API spec at `https://nid.sec.usace.army.mil/api/developer/json`, 2026-08-19.
- Register items touched: **9** (rewritten — see above), **2** (NID mirror
  unverified — this document is the first systematic verification of it and
  confirms the caveat was well placed).
