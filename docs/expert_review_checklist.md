# Per-facility expert review & sign-off checklist

A concrete, copy-per-dam form for the reviewing flood hydrologist. The pipeline
produces first-pass regional DDF estimates; **no facility's numbers are valid for
engineering use until this checklist is completed and signed.** It complements
the process narrative in [`audit_guide.md`](audit_guide.md); the method it checks
is in [`METHODS.md`](METHODS.md); the caveats are in
[`ASSUMPTIONS_AND_LIMITATIONS.md`](ASSUMPTIONS_AND_LIMITATIONS.md).

For fleet runs, triage first by the batch diagnostics
([`OUTPUT_DATA_DICTIONARY.md`](OUTPUT_DATA_DICTIONARY.md)): every row with
`needs_review = TRUE` or `review_recommended = TRUE`, every `failed` facility,
and every dam you intend to actually rely on, gets a completed form.

---

## Facility

- Facility / NID ID: `__________`   Name: `______________________`
- Reviewer: `____________`   Date: `__________`
- Run manifest reviewed (`run_manifest_<id>.json`, seed + code state): ☐

## 1. Inventory & location  (largest risk — see Limitations §A)

- ☐ **Coordinates verified** against an authoritative source (current NID
  `nid.sec.usace.army.mil`, Reclamation RISE `data.usbr.gov`, or a map). The
  region map (`figures/<id>_region_map.png`) places the dam where it actually is.
- ☐ Dam is a real analysis target (not an off-stream / diversion / administrative
  structure that should be excluded).
- ☐ Site elevation supplied if the elevation-regression index-flood transfer is
  intended (else `nearest` is used — confirm acceptable).

## 2. Region composition  (Limitations §B5)

- ☐ Region map inspected: stations are **climatologically consistent** with the
  dam — no region spanning a **continental divide, major rain-shadow, or climate
  boundary**; radius not reaching into an unrelated regime.
- ☐ Station count adequate (well above the 5-site minimum) and record lengths
  reasonable. Used/removed lists (`stations_used_…csv`, `stations_removed_…csv`)
  and their drop reasons make sense.
- ☐ Discordant sites removed (`Dᵢ ≥ D_crit`) are genuinely atypical, not real
  signal being discarded.
- ☐ **Region-building method confirmed** (`region.method` in `config/<id>.yml`:
  `circular`, the default geographic-radius pool, or `cluster`, H&W 1997 sec.
  9.2.3 Ward's-method clustering on standardized site attributes — see
  `R/region_methods.R`). If `cluster`, check the audit log for a
  nearest-vs-runner-up centroid note (`"borderline — close call"` means this
  facility sits near a cluster boundary — read that result more cautiously)
  and confirm it didn't silently fall back to `circular` (also logged, e.g.
  too few stations in a cluster).
- ☐ **Region-choice sensitivity understood.** The Reclamation reviewer who
  raised this called region construction "one of the most influential points
  in the L-moments analysis" — verify that's true or false for *this*
  facility, don't assume Como's result transfers. Run
  `Rscript compare_regions.R config/<id>.yml circular,cluster` and check
  `outputs/tables/<id>_region_method_spread.csv`'s `spread_pct` column. (Como's
  own verified run — `docs/REGION_METHOD_SENSITIVITY.md` — found **18-22%**
  spread at the design-relevant T=10,000-yr tail, shrinking to 3.7-10.5% by
  T=100 yr: a reference point, not this facility's answer, and large enough
  that it should never be assumed negligible.) A large spread means the
  method choice materially changes the design value and deserves explicit
  sign-off on which method's result is being relied on; subjective
  (covariate-based) and objective (L-moment-ratio) partitioning — the other
  two approaches H&W (1997) describes — are **not yet implemented**
  (deferred, pending Reclamation-set thresholds — see Limitations §B5), so
  `circular` vs `cluster` is the full comparison available today.
- ☐ **Confirmed `cluster` actually ran, not silently fell back.** `cluster`
  requires the facility's config to carry a real `elevation_m` — if it's
  missing, the audit log shows `"site attributes (e.g. elevation)
  unavailable; falling back to circular"` and `region.method: cluster`
  silently produces the identical circular result with no error. As of
  2026-08-14, **neither fleet manifest has real elevation data for any
  facility** (`config/facilities_BOR.csv`, `config/nid_manifest.csv` — see
  Limitations §B5), so this fallback is the default outcome fleet-wide today,
  not a rare edge case — do not assume `cluster` ran just because it was
  configured.

## 3. Homogeneity  (METHODS §7)

- ☐ `H₁` acceptable (`< 1` homogeneous; `1–2` review; `≥ 2` = **not homogeneous**,
  region must be revised/subdivided before use). Value: `H₁ = ______`
- ☐ If heterogeneous, region redefined and re-run, or facility deferred.

## 4. Distribution choice  (METHODS §8)

- ☐ Chosen distribution has an **acceptable fit** (`|Z| ≤ 1.645`). Chosen:
  `______`  `|Z| = ______`  (if `|Z| > 1.645`, this is `needs_review`).
- ☐ L-moment ratio diagram (`figures/<id>_…_lmoment_ratio_diagram.png`) and
  growth-curve fit plot inspected; the choice is visually defensible.
- ☐ **Tail-sensitivity** reviewed (`tail_sensitivity.csv`): if candidates diverge
  widely at 10,000-yr, the extreme tail is model-dependent — record the spread
  and consider reporting a range. If overriding the auto-choice, record the
  decision in `config/distribution_review.csv` and re-run.

## 5. AMS, season, durations  (METHODS §4)

- ☐ Season correct for the design question (default full-year annual maxima;
  confirm a restricted season was **not** used unless intended — it biases low).
- ☐ Durations (24 h / 72 h default) match the design need; fixed-interval factors
  acceptable. Add durations if required.

## 6. Estimates & uncertainty  (METHODS §9–10, Limitations §C–D)

- ☐ Growth curve monotonic; depths physically plausible vs regional climatology.
- ☐ **Index flood / at-site mean (ASM) reviewed** (`index_flood_asm_mm` in the
  DDF table and audit report — the H&W at-site mean, transferred to this
  site). Confirm which transfer method was used (`index_flood.method` in
  `config/<id>.yml`: `regression` — elevation regression on the region's
  station means, the default — or `nearest` — nearest station's mean).
  Elevation-regression silently falls back to the plain regional mean when
  the site has no elevation on file (common — the NID mirror carries no
  ground elevations, see `DATA_SOURCES.md`); confirm that's not silently
  happening here when a real elevation should be available.
- ☐ Monte-Carlo bounds reviewed **and** their limits understood (they exclude
  model-selection, regionalization, and input-data error — true uncertainty is
  wider).
- ☐ **External cross-check vs NOAA Atlas 14** at the site for at least the 24-h
  100-yr depth (and others as needed). Run `compare_atlas14.R` from a network
  where Atlas 14 (`hdsc.nws.noaa.gov/pfds`) is reachable. Agreement / discrepancy:
  `____________`. Investigate any large discrepancy before use.
- ☐ For extreme-event / dam-safety use, results compared against PMP-based
  methods (HMR / site-specific) as the primary basis; L-moment DDF used as a
  cross-check, not the sole basis, at very rare AEPs.

## 7. Areal / point

- ☐ Understood `depth_mm` is always the **point** depth.
- ☐ Where `depth_areal_mm` is populated, confirmed the drainage area
  (`arf_area_km2` / `config/*.csv`'s `drainage_area_mi2`) and reviewed whether
  the default Leclerc & Schaake (1972) ARF curve (`R/arf.R`, general
  national-average, not region-specific) is appropriate here, or should be
  swapped for a Reclamation-preferred curve (`arf.method` in the config).
- ☐ Where `depth_areal_mm` is `NA` (no drainage area on file), applied an ARF
  downstream if a basin-average design rainfall is needed.

## Disposition

- ☐ **Accepted** for the stated use (with any noted caveats)
- ☐ **Accepted with conditions**: `________________________________`
- ☐ **Rejected / rework** (reason): `________________________________`

Reviewer signature: `__________________________`   Date: `__________`
