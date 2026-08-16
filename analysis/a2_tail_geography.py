"""Phase A2 -- tail-behavior geography (docs/NID_ANALYSIS_PLAN.md).

Where does extreme rainfall have heavy tails? Maps the chosen distribution
family, an empirical tail index (Q10000/Q100 growth-factor ratio), and the
choice-STABILITY layer (z_margin: small margin = the family choice was a
coin flip). Public-safe: aggregate distribution-family geography, no per-dam
vulnerability content.

Tail index source: growth_curve.csv is keyed by site_id, so the ratio
Q10000/Q100 = growth_factor(10000)/growth_factor(100) is exact per facility
(the index flood cancels) and immune to the DDF's name-collision ambiguity.
The 519 pre-centralization facilities lack growth curves; those with unique
site names are backfilled from the DDF depth ratio, the remainder excluded.

Usage:  python analysis/a2_tail_geography.py [--ref origin/claude/desktop-nid-ad-hoc]
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qc"))
import nid_qc_common as C  # noqa: E402

OUT = C.REPO_ROOT / "docs" / "analysis"
FIGS = OUT / "figures"
DUR = "24h"
Z_COINFLIP = 0.2  # |Z| margin below which the family choice is a coin flip

FAMILY_COLORS = {  # fixed categorical assignment (Okabe-Ito), never re-ordered
    "GEV": C.OKABE_ITO[0],
    "GLO": C.OKABE_ITO[1],
    "GNO": C.OKABE_ITO[2],
    "PE3": C.OKABE_ITO[3],
    "GPA": C.OKABE_ITO[5],
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=C.FLEET_REF_DEFAULT)
    args = ap.parse_args()

    commit, cache = C.materialize(args.ref)
    led = C.load_fleet_table(cache, "completed_ids.csv")
    diag = C.load_fleet_table(cache, "batch_diagnostics.csv")
    gc = C.load_fleet_table(cache, "growth_curve.csv")
    ddf = C.load_fleet_table(cache, "all_facilities_DDF.csv")
    man = C.load_manifest()
    bor = C.load_bor308_reference()

    # ---------------------------------------------------------------- QC gate
    qc_flags = pd.read_csv(C.REPO_ROOT / "qc" / "reports" / "integrity_flags.csv")
    hard_fail = set(qc_flags[qc_flags.severity == "FAIL"].facility_id)
    san = pd.read_csv(C.REPO_ROOT / "qc" / "reports" / "sanity_flags.csv")
    coord_bad = set(san[san.flag.str.startswith("coord_")].facility_id)
    ok_led = led[led.ok & ~led.facility_id.isin(hard_fail)]
    pass_rate = len(ok_led) / led.ok.sum()

    d = diag[diag.duration == DUR].copy()
    d = d[d.site_id.isin(set(ok_led.facility_id))]

    # ------------------------------------------------------------- tail index
    g = gc[(gc.duration == DUR) & gc["T"].isin([100, 10000])]
    piv = g.pivot_table(index="site_id", columns="T", values="growth_factor", aggfunc="first")
    ratio = (piv[10000] / piv[100]).rename("tail_ratio")
    # backfill pre-centralization facilities from DDF via unique names
    name_counts = ok_led.groupby("name")["facility_id"].nunique()
    unique_names = ok_led[ok_led.name.isin(name_counts[name_counts == 1].index)]
    missing = set(ok_led.facility_id) - set(ratio.index)
    umap = unique_names.set_index("name")["facility_id"]
    dd = ddf[(ddf.duration == DUR) & ddf.return_period_yr.isin([100, 10000])]
    dpiv = dd.pivot_table(index="site", columns="return_period_yr", values="depth_mm",
                          aggfunc="first")
    dratio = (dpiv[10000] / dpiv[100]).rename("tail_ratio")
    dratio.index = dratio.index.map(umap)
    backfill = dratio[dratio.index.notna() & dratio.index.isin(missing)]
    n_backfill = len(backfill)
    ratio = pd.concat([ratio, backfill])
    ratio = ratio[~ratio.index.duplicated()]

    d = d.merge(ratio, left_on="site_id", right_index=True, how="left")
    d = d.merge(man[["facility_id", "latitude", "longitude", "state"]],
                left_on="site_id", right_on="facility_id", how="left")
    d_map = d[~d.site_id.isin(coord_bad)].dropna(subset=["latitude", "longitude"])
    d_conus = d_map[~d_map.state.isin(C.NON_CONUS)]

    # ---------------------------------------------------------------- figures
    plt = C.style_matplotlib()

    # 1. chosen distribution family (categorical map, small multiples to avoid
    #    5-way overplotting of 30k points)
    fig, axes = plt.subplots(2, 3, figsize=(15, 7.5))
    fams = d_conus.chosen_dist.value_counts().index.tolist()
    order = [f for f in FAMILY_COLORS if f in fams]
    for ax, fam in zip(axes.flat, order):
        C.add_manifest_basemap(ax, man)
        ax.set_aspect(1.25)
        ax.grid(False); ax.set_xticks([]); ax.set_yticks([])
        for s in ax.spines.values():
            s.set_visible(False)
        sub = d_conus[d_conus.chosen_dist == fam]
        ax.scatter(sub.longitude, sub.latitude, s=2.5, c=FAMILY_COLORS[fam],
                   linewidths=0, rasterized=True)
        ax.set_title(f"{fam}  (n={len(sub):,}, {len(sub) / len(d_conus):.0%})", fontsize=11)
    for ax in axes.flat[len(order):]:
        ax.axis("off")
    fig.suptitle(f"A2: chosen distribution family, {DUR} (CONUS, partial fleet)", y=0.99)
    fig.tight_layout()
    FIGS.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIGS / "a2_family_maps.png")
    plt.close(fig)

    # 2. empirical tail index map (sequential single hue)
    fig, ax = C.conus_map_axes(plt)
    C.add_manifest_basemap(ax, man)
    sub = d_conus.dropna(subset=["tail_ratio"])
    vmin, vmax = sub.tail_ratio.quantile([0.02, 0.98])
    sc = ax.scatter(sub.longitude, sub.latitude, s=3, c=sub.tail_ratio.clip(vmin, vmax),
                    cmap="Oranges", linewidths=0, rasterized=True)
    cb = fig.colorbar(sc, ax=ax, shrink=0.7,
                      label="Q10000 / Q100 growth-factor ratio (24h)")
    cb.outline.set_visible(False)
    ax.set_title("A2: empirical tail heaviness -- 10,000-yr to 100-yr depth ratio (24h)\n"
                 f"n={len(sub):,} facilities; color clipped to 2-98% "
                 f"[{vmin:.2f}, {vmax:.2f}]")
    fig.savefig(FIGS / "a2_tail_ratio_map.png")
    plt.close(fig)

    # 3. choice-stability layer
    fig, ax = C.conus_map_axes(plt)
    C.add_manifest_basemap(ax, man)
    unstable = d_conus[d_conus.z_margin < Z_COINFLIP]
    ax.scatter(unstable.longitude, unstable.latitude, s=3, c=C.OKABE_ITO[3],
               linewidths=0, rasterized=True,
               label=f"z_margin < {Z_COINFLIP} ({len(unstable):,}, "
                     f"{len(unstable) / len(d_conus):.0%})")
    ax.legend(frameon=False, loc="lower left")
    ax.set_title("A2: choice-instability layer -- facilities whose family choice is a\n"
                 f"coin flip (runner-up within {Z_COINFLIP} |Z|), {DUR}, CONUS")
    fig.savefig(FIGS / "a2_instability_map.png")
    plt.close(fig)

    # ------------------------------------------------------------- statistics
    fam_share = d.chosen_dist.value_counts(normalize=True)
    bor_share = bor[bor.duration == DUR].chosen_dist.value_counts(normalize=True)
    ratio_by_state = d.dropna(subset=["tail_ratio"]).groupby("state").agg(
        n=("tail_ratio", "size"), med=("tail_ratio", "median"))
    heavy = ratio_by_state[ratio_by_state.n >= 100].nlargest(8, "med")
    light = ratio_by_state[ratio_by_state.n >= 100].nsmallest(8, "med")
    unstable_rate = float((d.z_margin < Z_COINFLIP).mean())
    unstable_heavy = d[d.z_margin < Z_COINFLIP].chosen_dist.value_counts(normalize=True)
    # instability vs family involvement: which family pairs are coin flips?
    pairs = d[d.z_margin < Z_COINFLIP].groupby(["chosen_dist", "runner_up"]).size() \
        .sort_values(ascending=False).head(6)

    # ---------------------------------------------------------------- report
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# A2 -- Tail-behavior geography",
        "",
        f"_Generated {now} by `analysis/a2_tail_geography.py`. Public-safe: aggregate",
        "distribution-family geography and depth *ratios*; no per-dam depth rankings._",
        "",
        C.partial_data_note(commit, len(led)),
        "",
        "## QC gate",
        "",
        f"- Facilities passing integrity QC: {len(ok_led):,} of {led.ok.sum():,} ok",
        f"  ({pass_rate:.2%}); {len(coord_bad)} coordinate-flagged facilities dropped from",
        "  map layers (kept in national statistics -- their diagnostics are position-",
        "  independent, only their dots would be misplaced).",
        f"- Tail index computed from growth curves (site_id-exact) for "
        f"{len(ratio) - n_backfill:,} facilities + {n_backfill} pre-centralization",
        "  facilities backfilled via unique-name DDF ratios; the remaining",
        f"  {len(set(ok_led.facility_id)) - len(ratio):,} (collided-name pre-centralization) excluded.",
        "- The 72h<24h crossing flag (sanity report) does not touch this analysis: all",
        f"  quantities here are {DUR}-only and within-duration monotonicity is clean.",
        "- Register items: 3 (circular-only regions -- family choice could shift under the",
        "  region-method band; the instability layer below is the honest cousin of that",
        "  caveat), 5 (undercatch biases mountain depths low; ratios are less exposed than",
        "  absolute depths).",
        "",
        "## Distribution-family geography",
        "",
        "![family maps](figures/a2_family_maps.png)",
        "",
        "| Family | NID fleet share | BOR-308 share |",
        "|---|---|---|",
    ]
    for fam in FAMILY_COLORS:
        lines.append(f"| {fam} | {fam_share.get(fam, 0):.3f} | {bor_share.get(fam, 0):.3f} |")
    lines += [
        "",
        "## Empirical tail heaviness (Q10000/Q100, 24h)",
        "",
        "![tail ratio](figures/a2_tail_ratio_map.png)",
        "",
        f"National median ratio {d.tail_ratio.median():.2f} "
        f"(p05 {d.tail_ratio.quantile(0.05):.2f}, p95 {d.tail_ratio.quantile(0.95):.2f}).",
        "",
        "Heaviest / lightest tails by state (median ratio, n>=100):",
        "",
        "| Heaviest | median | n | | Lightest | median | n |",
        "|---|---|---|---|---|---|---|",
    ]
    for (hs, hr), (ls, lr) in zip(heavy.iterrows(), light.iterrows()):
        lines.append(f"| {hs} | {hr.med:.2f} | {int(hr.n):,} | | {ls} | {lr.med:.2f} | {int(lr.n):,} |")
    lines += [
        "",
        "Reading (at this commit): the heavy-tail geography is led by **Florida** and the",
        "**coastal Northeast** (CT/MA/VT/NJ) -- both consistent with tropical-system",
        "extremes riding on a moderate everyday climate -- with sub-state hot spots the",
        "state medians dilute: the central-Texas flash-flood alley, the Missouri Ozarks,",
        "and a strong Hudson-Valley/Berkshires blob are all visible on the map. Interior",
        "and Gulf-inland states (GA, MS, AR, ID, NM) run light. **Michigan's high median",
        "is unexpected** and worth a targeted look in the D1 review sample -- it may be a",
        "lake-effect / short-record artifact rather than climate signal. Note also that",
        "tail ratio and chosen family are entangled (GLO is the heaviest-tailed family),",
        "so family-choice instability (below) propagates into this map.",
        "",
        "## Choice stability",
        "",
        "![instability](figures/a2_instability_map.png)",
        "",
        f"**{unstable_rate:.0%} of facilities chose their distribution family by a margin",
        f"of less than {Z_COINFLIP} |Z|** -- for these the family label on the map above is",
        "close to arbitrary, and (per the BOR region-method work) they carry the largest",
        "method sensitivity in the extrapolated tail. Most frequent coin-flip pairs",
        "(chosen vs runner-up):",
        "",
        "| Chosen | Runner-up | n |",
        "|---|---|---|",
    ] + [f"| {c} | {r} | {n:,} |" for (c, r), n in pairs.items()] + [
        "",
        "## Verification notes (QAQC plan section E)",
        "",
        "- **Spatial-autocorrelation caveat**: facilities within ~175 km share candidate",
        "  stations, so neighboring facilities' family choices and ratios are strongly",
        "  dependent by construction. Apparent regional coherence on these maps is partly",
        "  that sharing; no significance is claimed for any spatial pattern here, and",
        "  none should be inferred until a station-blocked test is run at completion.",
        "- **Selection caveat**: largest-storage-first ordering means sparsely-dammed",
        "  (often mountainous) areas are already sampled while small-dam-dense areas",
        "  (e.g. the Southeast) are under-sampled at 42.6%.",
        "- The family-share difference vs BOR-308 is expected from geography (BOR is",
        "  interior-West-heavy); the sanity report's profile comparison carries the",
        "  distribution-level view.",
        "",
        "## Pinned inputs",
        "",
        f"- Fleet data: `{commit}` (`claude/desktop-nid-ad-hoc`)",
        "- QC: `qc/reports/integrity_flags.csv`, `qc/reports/sanity_flags.csv`",
    ]
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "tail_geography.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"A2 done: {len(d):,} facilities, unstable {unstable_rate:.0%}, "
          f"median ratio {d.tail_ratio.median():.2f}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
