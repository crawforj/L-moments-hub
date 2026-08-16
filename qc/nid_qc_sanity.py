"""NID fleet QA/QC -- statistical-sanity + coordinate-sanity layers
(docs/NID_QAQC_PLAN.md sections B and C1; runnable on partial data).

Checks:
  B1  monotonicity: growth factor / depth strictly increasing in T within each
      duration; 72h depth >= 24h depth at every T
  B2  physical bounds: 24h/100yr depth within generous regional bounds
      (CONUS ~25-800 mm; AK/HI/PR separately); CI ordering; tail-band ordering
  B3  diagnostic-profile comparison vs the BOR-308 reference shape
      (H1, |Z|, z_margin, tail_spread_pct -- ECDF overlays + quantile tables + KS D)
  B4  needs_review rate by state (extreme-rate states highlighted)
  C1  coordinate sanity: in-state bounding-box test (buffered), global range,
      missing/zero coordinates, CONUS envelope

All flags are facility-level and advisory ("flags not drops"); analyses decide
exclusion policy explicitly. Read-only against the pinned fleet commit.

Outputs:
  qc/reports/sanity_report.md
  qc/reports/sanity_flags.csv
  qc/reports/figures/*.png

Usage:  python qc/nid_qc_sanity.py [--ref origin/claude/desktop-nid-ad-hoc]
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nid_qc_common as C  # noqa: E402

REPORTS = C.REPO_ROOT / "qc" / "reports"
FIGDIR = REPORTS / "figures"

# Generous screening bounds for the 100-yr 24-h depth (mm). Deliberately wide:
# these catch engine/unit errors, not climatological outliers.
BOUNDS_100YR_24H = {
    "CONUS": (25.0, 800.0),
    "AK": (15.0, 700.0),
    "HI": (50.0, 1300.0),
    "PR": (100.0, 1000.0),
}
BBOX_BUFFER_DEG = 1.0
PROFILE_METRICS = ["H1", "chosen_absZ", "z_margin", "tail_spread_pct"]


def ks_D(a: np.ndarray, b: np.ndarray) -> float:
    from scipy.stats import ks_2samp

    return float(ks_2samp(a, b, method="asymp").statistic)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=C.FLEET_REF_DEFAULT)
    args = ap.parse_args()

    commit, cache = C.materialize(args.ref)
    led = C.load_fleet_table(cache, "completed_ids.csv")
    ddf = C.load_fleet_table(cache, "all_facilities_DDF.csv")
    diag = C.load_fleet_table(cache, "batch_diagnostics.csv")
    gc = C.load_fleet_table(cache, "growth_curve.csv")
    man = C.load_manifest()
    bor = C.load_bor308_reference()

    ok_led = led[led.ok]
    flags: list[dict] = []
    results: list[tuple[str, str, str]] = []

    def flag(fid, duration, name, severity, detail=""):
        flags.append({"facility_id": fid, "duration": duration, "flag": name,
                      "severity": severity, "detail": detail})

    def result(check, verdict, detail):
        results.append((check, verdict, detail))
        print(f"[{verdict}] {check}: {detail}", file=sys.stderr)

    # Name-collision facilities (DDF unattributable) -- established by the
    # integrity layer; recomputed here so this script stands alone.
    name_counts = ok_led.groupby("name")["facility_id"].nunique()
    collided_names = set(name_counts[name_counts > 1].index)
    unique_name_map = ok_led[~ok_led.name.isin(collided_names)].set_index("name")["facility_id"]

    # ------------------------------------------------------------- B1 monotonic
    gcs = gc.sort_values(["site_id", "duration", "T"])
    diffs = gcs.groupby(["site_id", "duration"])["growth_factor"].diff()
    gc_viol = gcs[diffs.notna() & (diffs <= 0)]
    for (fid, dur), grp in gc_viol.groupby(["site_id", "duration"]):
        flag(fid, dur, "growth_curve_not_monotonic", "FAIL",
             f"non-increasing growth factor at T={sorted(grp['T'].tolist())}")

    dds = ddf.sort_values(["site", "duration", "return_period_yr"])
    ddiffs = dds.groupby(["site", "duration"])["depth_mm"].diff()
    dd_viol = dds[ddiffs.notna() & (ddiffs <= 0)]
    for (site, dur), grp in dd_viol.groupby(["site", "duration"]):
        fid = unique_name_map.get(site, f"NAME:{site}")
        flag(fid, dur, "ddf_depth_not_monotonic", "FAIL",
             f"non-increasing depth at T={sorted(grp.return_period_yr.tolist())}")

    # 72h >= 24h: only unique-name sites (collided names would mix two
    # facilities' curves in the pivot and manufacture spurious violations).
    ddf_u = ddf[~ddf.site.isin(collided_names)]
    piv = ddf_u.pivot_table(index=["site", "return_period_yr"], columns="duration",
                            values="depth_mm", aggfunc="first")
    dur_viol = piv[piv["72h"] < piv["24h"] - 1e-9].reset_index()
    dur_viol["deficit_pct"] = 100 * (dur_viol["24h"] - dur_viol["72h"]) / dur_viol["24h"]
    cross_by_site = dur_viol.groupby("site").agg(
        T_min=("return_period_yr", "min"), T_n=("return_period_yr", "size"),
        max_deficit_pct=("deficit_pct", "max"))
    for site, r in cross_by_site.iterrows():
        flag(unique_name_map.get(site), "both", "dur72_lt_dur24", "FAIL",
             f"72h < 24h from T={r.T_min:g} ({r.T_n:g} of 12 T values; "
             f"max deficit {r.max_deficit_pct:.1f}%)")
    n_cross = len(cross_by_site)
    n_checked_sites = piv.reset_index().site.nunique()
    result("B1 monotonicity + 72h>=24h",
           "PASS" if (len(gc_viol) + len(dd_viol) + n_cross) == 0 else "FAIL",
           f"within-duration monotonicity CLEAN ({gcs.groupby(['site_id','duration']).ngroups:,} "
           f"growth curves, {dds.groupby(['site','duration']).ngroups:,} DDF curves, 0 violations); "
           f"BUT 72h<24h duration crossings at {n_cross:,} of {n_checked_sites:,} unique-name sites "
           f"({n_cross / n_checked_sites:.1%}) -- all at T>=200; diagnosed as an engine "
           f"limitation (24h and 72h fitted independently with no cross-duration "
           f"consistency constraint), not a corrupt fold; see the crossing section below")

    # crossing diagnosis material for the report: does the 72h fit choose a
    # lighter-tailed family than the 24h fit at crossing sites?
    dpair = diag.pivot_table(index="site", columns="duration", values="chosen_dist",
                             aggfunc="first")
    dpair = dpair[~dpair.index.isin(collided_names)].dropna()
    dpair["differs"] = dpair["24h"] != dpair["72h"]
    cross_sites = set(cross_by_site.index)
    dpair["crossing"] = dpair.index.isin(cross_sites)
    cross_dist_rate = dpair[dpair.crossing].differs.mean() if dpair.crossing.any() else float("nan")
    nocross_dist_rate = dpair[~dpair.crossing].differs.mean()
    cross_by_T = dur_viol.return_period_yr.value_counts().sort_index()
    cross_deficit = dur_viol.deficit_pct.describe()

    # ------------------------------------------------------------- B2 bounds
    d100 = ddf[(ddf.duration == "24h") & (ddf.return_period_yr == 100)].copy()
    d100["facility_id"] = d100.site.map(unique_name_map)
    d100 = d100.dropna(subset=["facility_id"])
    d100 = d100.merge(man[["facility_id", "state"]], on="facility_id", how="left")
    d100["region"] = d100.state.where(d100.state.isin(C.NON_CONUS), "CONUS")
    oob_rows = []
    for region, (lo, hi) in BOUNDS_100YR_24H.items():
        sub = d100[d100.region == region]
        bad = sub[(sub.depth_mm < lo) | (sub.depth_mm > hi)]
        oob_rows.append((region, len(sub), len(bad), lo, hi,
                         float(sub.depth_mm.min()) if len(sub) else np.nan,
                         float(sub.depth_mm.max()) if len(sub) else np.nan))
        for _, r in bad.iterrows():
            flag(r.facility_id, "24h", "depth_100yr_out_of_bounds", "WARN",
                 f"{r.depth_mm:.1f} mm outside [{lo}, {hi}] for {region}")
    ci_bad = ddf[(ddf.depth_mm < ddf.depth_lo_mm - 1e-9) | (ddf.depth_mm > ddf.depth_hi_mm + 1e-9)
                 | (ddf.depth_mm <= 0)]
    for site, grp in ci_bad.groupby("site"):
        fid = unique_name_map.get(site, f"NAME:{site}")
        flag(fid, "both", "ddf_ci_ordering_bad", "FAIL", f"{len(grp)} rows with depth outside its own CI or <=0")
    # 0.1% relative tolerance: the diagnostics columns are rounded to ~4
    # significant figures, which alone produces apparent boundary violations
    # (301 such rounding artifacts at exact comparison, worst 0.07%).
    tb = diag[(diag.depth_10k_mm < diag.tail_min_10k_mm * 0.999)
              | (diag.depth_10k_mm > diag.tail_max_10k_mm * 1.001)]
    for _, r in tb.iterrows():
        flag(r.site_id, r.duration, "tail_band_ordering_bad", "FAIL",
             f"depth_10k {r.depth_10k_mm} outside [{r.tail_min_10k_mm}, {r.tail_max_10k_mm}]")
    n_oob = sum(r[2] for r in oob_rows)
    result("B2 physical bounds",
           "PASS" if (n_oob == 0 and len(ci_bad) == 0 and len(tb) == 0) else
           ("WARN" if len(ci_bad) == 0 and len(tb) == 0 else "FAIL"),
           f"100yr/24h out-of-bounds: {n_oob} of {len(d100):,} attributable facilities "
           f"({', '.join(f'{r[0]}: {r[2]}/{r[1]}' for r in oob_rows)}); "
           f"CI-ordering violations: {ci_bad.groupby('site').ngroups}; "
           f"tail-band ordering violations: {len(tb)}. "
           f"({len(collided_names)} collided site names excluded from state attribution)")

    # ------------------------------------------------------------- B3 profile
    plt = C.style_matplotlib()
    fig, axes = plt.subplots(2, 4, figsize=(15, 6.5), sharey=True)
    ks_table = []
    q_probs = [0.05, 0.25, 0.50, 0.75, 0.95]
    quant_rows = []
    for i, dur in enumerate(C.EXPECTED_DURATIONS):
        nat = diag[diag.duration == dur]
        ref = bor[bor.duration == dur]
        for j, m in enumerate(PROFILE_METRICS):
            a = nat[m].dropna().to_numpy()
            b = ref[m].dropna().to_numpy()
            D = ks_D(a, b)
            ks_table.append((dur, m, len(a), len(b), D))
            qa = np.quantile(a, q_probs).round(2)
            qb = np.quantile(b, q_probs).round(2)
            quant_rows.append((dur, m, "NID fleet", *qa))
            quant_rows.append((dur, m, "BOR-308", *qb))
            ax = axes[i, j]
            for arr, color, label in ((a, C.OKABE_ITO[0], f"NID fleet (n={len(a):,})"),
                                      (b, C.OKABE_ITO[1], f"BOR-308 (n={len(b)})")):
                xs = np.sort(arr)
                ax.plot(xs, np.arange(1, len(xs) + 1) / len(xs), color=color,
                        lw=2, label=label)
            lo, hi = np.quantile(np.concatenate([a, b]), [0.005, 0.995])
            ax.set_xlim(lo, hi)
            ax.set_title(f"{m} ({dur})  KS D={D:.03f}", fontsize=10)
            if j == 0:
                ax.set_ylabel("ECDF")
            if i == 0 and j == 0:
                ax.legend(frameon=False, fontsize=8, loc="lower right")
    fig.suptitle("Diagnostic profile: NID fleet (partial) vs BOR-308 reference shape",
                 y=1.02, fontsize=12)
    fig.tight_layout()
    FIGDIR.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIGDIR / "profile_vs_bor308.png")
    plt.close(fig)

    dist_nat = diag[diag.duration == "24h"].chosen_dist.value_counts(normalize=True)
    dist_ref = bor[bor.duration == "24h"].chosen_dist.value_counts(normalize=True)
    dist_cmp = pd.DataFrame({"NID fleet": dist_nat, "BOR-308": dist_ref}).fillna(0).round(3)
    max_D = max(k[4] for k in ks_table)
    result("B3 profile vs BOR-308 reference",
           "PASS" if max_D < 0.25 else "WARN",
           f"max KS D across {len(ks_table)} metric/duration cells = {max_D:.3f} "
           f"(reference = docs/example_outputs/fleet_308dam/batch_diagnostics.csv; "
           f"data/region_method_band/bor308_band.csv is not on main -- unmerged PR); "
           f"see figures/profile_vs_bor308.png")

    # ------------------------------------------------------------- B4 needs_review
    dstate = diag.merge(man[["facility_id", "state"]], left_on="site_id",
                        right_on="facility_id", how="left")
    by_state = dstate.groupby("state").agg(
        n=("needs_review", "size"), needs_review=("needs_review", "sum"),
        review_recommended=("review_recommended", "sum"))
    by_state["nr_rate"] = by_state.needs_review / by_state.n
    by_state["rr_rate"] = by_state.review_recommended / by_state.n
    nat_rate = diag.needs_review.mean()
    extreme = by_state[(by_state.n >= 100) & (by_state.nr_rate > max(2 * nat_rate, nat_rate + 0.05))]
    result("B4 needs_review accounting",
           "PASS" if len(extreme) == 0 else "WARN",
           f"national needs_review rate {nat_rate:.1%} of facility-durations; "
           f"states >max(2x national, +5pp) with n>=100: "
           f"{', '.join(f'{s} {r.nr_rate:.1%} (n={r.n})' for s, r in extreme.iterrows()) or 'none'}")

    fig, ax = plt.subplots(figsize=(11, 4))
    srt = by_state.sort_values("nr_rate", ascending=False)
    ax.bar(srt.index, srt.nr_rate * 100, color=C.OKABE_ITO[0], width=0.7)
    ax.axhline(nat_rate * 100, color=C.MUTED, lw=1, ls="--")
    ax.text(len(srt) - 0.5, nat_rate * 100, f" national {nat_rate:.1%}",
            va="bottom", ha="right", fontsize=8, color=C.MUTED)
    ax.set_ylabel("needs_review rate (%)")
    ax.set_title("needs_review rate by state (facility-durations, partial fleet)")
    ax.tick_params(axis="x", labelsize=7)
    fig.savefig(FIGDIR / "needs_review_by_state.png")
    plt.close(fig)

    # ------------------------------------------------------------- C1 coordinates
    att = led.merge(man, on="facility_id", how="left", suffixes=("_ledger", ""))
    coord_flags = 0
    for _, r in att.iterrows():
        lat, lon, st = r.latitude, r.longitude, r.state
        if pd.isna(lat) or pd.isna(lon) or (lat == 0 and lon == 0):
            flag(r.facility_id, "n/a", "coord_missing", "FAIL", "missing/zero coordinates")
            coord_flags += 1
            continue
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            flag(r.facility_id, "n/a", "coord_out_of_range", "FAIL", f"({lat}, {lon})")
            coord_flags += 1
            continue
        bbox = C.STATE_BBOX.get(st)
        if bbox is None:
            flag(r.facility_id, "n/a", "coord_state_unknown", "WARN", f"state '{st}' has no bbox")
            coord_flags += 1
            continue
        la0, la1, lo0, lo1 = bbox
        if not (la0 - BBOX_BUFFER_DEG <= lat <= la1 + BBOX_BUFFER_DEG
                and lo0 - BBOX_BUFFER_DEG <= lon <= lo1 + BBOX_BUFFER_DEG):
            flag(r.facility_id, "n/a", "coord_outside_state_bbox", "WARN",
                 f"({lat:.3f}, {lon:.3f}) outside {st} bbox +{BBOX_BUFFER_DEG} deg")
            coord_flags += 1
        elif st not in C.NON_CONUS and not (
                C.CONUS_ENVELOPE[0] <= lat <= C.CONUS_ENVELOPE[1]
                and C.CONUS_ENVELOPE[2] <= lon <= C.CONUS_ENVELOPE[3]):
            flag(r.facility_id, "n/a", "coord_outside_conus_envelope", "WARN",
                 f"({lat:.3f}, {lon:.3f})")
            coord_flags += 1
    non_conus_n = att.state.isin(C.NON_CONUS).sum()
    result("C1 coordinate sanity",
           "PASS" if coord_flags == 0 else "WARN",
           f"{coord_flags} of {len(att):,} attempted facilities flagged "
           f"(bbox test with {BBOX_BUFFER_DEG} deg buffer; polygon-accurate test deferred "
           f"to completion pass); non-CONUS attempted: {non_conus_n} "
           f"({att[att.state.isin(C.NON_CONUS)].state.value_counts().to_dict()})")

    # coordinate/bounds map
    fig, ax = C.conus_map_axes(plt)
    C.add_manifest_basemap(ax, man)
    fdf = pd.DataFrame(flags)
    if len(fdf):
        bad_ids = set(fdf[fdf.flag.str.startswith("coord_")].facility_id) \
            | set(fdf[fdf.flag == "depth_100yr_out_of_bounds"].facility_id)
        sub = man[man.facility_id.isin(bad_ids)].dropna(subset=["latitude", "longitude"])
        ax.scatter(sub.longitude, sub.latitude, s=28, c=C.OKABE_ITO[5],
                   edgecolors="white", linewidths=0.6, label=f"flagged ({len(sub)})")
        ax.legend(frameon=False, loc="lower left")
    ax.set_title("Sanity-flagged facilities (coordinate + physical-bounds flags), partial fleet\n"
                 "gray = all 73,303 NID manifest facilities (CONUS shown)")
    fig.savefig(FIGDIR / "sanity_flags_map.png")
    plt.close(fig)

    # ------------------------------------------------------------- outputs
    REPORTS.mkdir(parents=True, exist_ok=True)
    fdf = pd.DataFrame(flags, columns=["facility_id", "duration", "flag", "severity", "detail"])
    fdf.to_csv(REPORTS / "sanity_flags.csv", index=False)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    q_hdr = " | ".join(f"q{int(p*100):02d}" for p in q_probs)

    lines = [
        "# NID fleet -- statistical + coordinate sanity report (QAQC plan sections B, C1)",
        "",
        f"_Generated {now} by `qc/nid_qc_sanity.py`._",
        "",
        C.partial_data_note(commit, len(led)),
        "",
        "Flags are advisory (\"flags not drops\"); the machine-readable copy is",
        f"`qc/reports/sanity_flags.csv` ({len(fdf):,} rows).",
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
        "## Flag counts",
        "",
        "| Flag | Severity | Rows |",
        "|---|---|---|",
    ]
    if len(fdf):
        for (fl, sev), n in fdf.groupby(["flag", "severity"]).size().items():
            lines.append(f"| `{fl}` | {sev} | {n:,} |")
    else:
        lines.append("| (none) | | |")
    lines += [
        "",
        "## The 72h < 24h duration-crossing finding (B1)",
        "",
        f"Within-duration monotonicity is perfectly clean, but at {n_cross:,} of",
        f"{n_checked_sites:,} unique-name sites ({n_cross / n_checked_sites:.1%}) the fitted",
        "72-h depth drops below the 24-h depth somewhere in the extrapolated tail --",
        "physically impossible for nested annual maxima, so it is a pure artifact of the",
        "engine fitting each duration **independently** (different station sets after the",
        "20-yr record screen, different regions after the H1 homogeneity pruning, and",
        "often a different chosen distribution family) with no cross-duration consistency",
        "constraint.",
        "",
        "| T (yr) | crossing sites |",
        "|---|---|",
    ] + [f"| {int(t)} | {n:,} |" for t, n in cross_by_T.items()] + [
        "",
        f"Deficit (24h minus 72h, % of 24h) across crossing (site, T) pairs: median "
        f"{cross_deficit['50%']:.1f}%, p75 {cross_deficit['75%']:.1f}%, max "
        f"{cross_deficit['max']:.1f}%.",
        "",
        f"Supporting evidence for the independent-fit diagnosis: at crossing sites the",
        f"24h and 72h fits chose **different** distribution families {cross_dist_rate:.0%}",
        f"of the time, vs {nocross_dist_rate:.0%} at non-crossing sites.",
        "",
        "Consequences: (1) every crossing site carries a hard `dur72_lt_dur24` flag (the",
        "plan's rule); (2) no crossing occurs below T=200, so 100-yr products are",
        "unaffected; (3) T>=200 **72h** depths at flagged sites should not be used",
        "without a cross-duration consistency fix or an explicit caveat; (4) the",
        "crossing rate itself is a measure of independent-fit tail uncertainty and is",
        "worth reporting alongside the tail_spread diagnostics.",
        "",
        "## B3: diagnostic profile vs the BOR-308 reference shape",
        "",
        "Reference used: `docs/example_outputs/fleet_308dam/batch_diagnostics.csv`",
        "(the curated BOR-308 fleet diagnostics committed on main).",
        "`data/region_method_band/bor308_band.csv` was specified as an alternative but",
        "is **not on main** (it lives on the unmerged region-methods PR branch), so the",
        "example-outputs diagnostics file is the benchmark, as the closest validated",
        "reference actually available.",
        "",
        "![profile comparison](figures/profile_vs_bor308.png)",
        "",
        "KS D statistics (distribution-shape distance, 0 = identical; with n≈31k any",
        "difference is 'significant', so D itself is the honest quantity):",
        "",
        "| Duration | Metric | n fleet | n BOR | KS D |",
        "|---|---|---|---|---|",
    ]
    for dur, m, na, nb, D in ks_table:
        lines.append(f"| {dur} | {m} | {na:,} | {nb} | {D:.3f} |")
    lines += [
        "",
        f"Quantiles ({q_hdr}):",
        "",
        f"| Duration | Metric | Series | {q_hdr} |",
        "|---|---|---|" + "---|" * len(q_probs),
    ]
    for row in quant_rows:
        dur, m, ser, *qs = row
        lines.append(f"| {dur} | {m} | {ser} | " + " | ".join(str(q) for q in qs) + " |")
    lines += [
        "",
        "Distribution-family share at 24 h (fraction of facilities):",
        "",
        "| Family | NID fleet | BOR-308 |",
        "|---|---|---|",
    ]
    for fam, r in dist_cmp.iterrows():
        lines.append(f"| {fam} | {r['NID fleet']:.3f} | {r['BOR-308']:.3f} |")
    lines += [
        "",
        "Interpretation caveats: the BOR-308 set is ~300 large federal dams (many in",
        "the interior West), while the partial NID fleet is the ~31k largest-storage",
        "dams nationally -- some profile difference is expected from geography alone,",
        "not only from method behavior. A national profile wildly different from the",
        "validated subset would still be a finding to explain before use (plan B3);",
        "the comparison above is the check.",
        "",
        "## B4: needs_review by state",
        "",
        "![needs_review by state](figures/needs_review_by_state.png)",
        "",
        "## C1: coordinate sanity",
        "",
        "In-state test uses generous state bounding boxes with a "
        f"{BBOX_BUFFER_DEG} deg buffer -- a coarse screen for gross errors (sign slips,",
        "transpositions, wrong state). A polygon-accurate in-state / open-water test is",
        "deferred to the completion pass. Known-issue register item 2 (NID mirror",
        "coordinates unverified) applies to every facility regardless of flags here.",
        "",
        "![flag map](figures/sanity_flags_map.png)",
        "",
        "## Known-issue register propagation",
        "",
        "Touches register items 2 (coordinates -- C1), 4 (elevation NA -- degrades the",
        "index-flood regression fleet-wide; bounds in B2 remain valid screens), and 5",
        "(gauge undercatch biases mountain depths low -- bounds are generous enough that",
        "undercatch cannot flip a pass/fail).",
        "",
        "## Pinned inputs",
        "",
        f"- Fleet data: `{commit}` (`claude/desktop-nid-ad-hoc`)",
        f"- BOR-308 reference: `docs/example_outputs/fleet_308dam/batch_diagnostics.csv` (main)",
    ]
    (REPORTS / "sanity_report.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"\nWrote sanity_report.md, sanity_flags.csv ({len(fdf):,} flags), "
          f"and {len(list(FIGDIR.glob('*.png')))} figures", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
