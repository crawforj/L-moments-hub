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

- ☐ Understood these are **point** depths with **no areal reduction**; ARF applied
  downstream if a basin-average design rainfall is needed.

## Disposition

- ☐ **Accepted** for the stated use (with any noted caveats)
- ☐ **Accepted with conditions**: `________________________________`
- ☐ **Rejected / rework** (reason): `________________________________`

Reviewer signature: `__________________________`   Date: `__________`
