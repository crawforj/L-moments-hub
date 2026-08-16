"""Phase A3 -- heterogeneity hot-spots (docs/NID_ANALYSIS_PLAN.md).

Where do sharp climate gradients defeat automated region formation -- the
national version of the Keene/Cascade-transition lesson?

Two layers, because the engine *forces* homogeneity where it can:
  1. residual heterogeneity -- facilities whose FINAL region still has H1 >= 1
     (the pruning gave up);
  2. forced-homogenization intensity -- how many stations the greedy H1
     reduction had to discard to reach a homogeneous region. A region that
     looks homogeneous only after heavy pruning sits on a gradient just as
     surely as one that stays heterogeneous.

Public-safe: method-diagnostic geography only. Writes the A3 section of
docs/analysis/method_diagnostics.md.

Usage:  python analysis/a3_heterogeneity.py [--ref origin/claude/desktop-nid-ad-hoc]
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qc"))
import nid_qc_common as C  # noqa: E402

OUT = C.REPO_ROOT / "docs" / "analysis"
FIGS = OUT / "figures"
GRID_DEG = 1.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=C.FLEET_REF_DEFAULT)
    args = ap.parse_args()

    commit, cache = C.materialize(args.ref)
    led = C.load_fleet_table(cache, "completed_ids.csv")
    diag = C.load_fleet_table(cache, "batch_diagnostics.csv")
    srem = C.load_fleet_table(cache, "stations_removed.csv")
    sused = C.load_fleet_table(cache, "stations_used.csv")
    man = C.load_manifest()

    qc_flags = pd.read_csv(C.REPO_ROOT / "qc" / "reports" / "integrity_flags.csv")
    hard_fail = set(qc_flags[qc_flags.severity == "FAIL"].facility_id)
    san = pd.read_csv(C.REPO_ROOT / "qc" / "reports" / "sanity_flags.csv")
    coord_bad = set(san[san.flag.str.startswith("coord_")].facility_id)
    ok_ids = set(led[led.ok].facility_id) - hard_fail

    # facility-level H1 (worst duration), plus per-duration counts
    d = diag[diag.site_id.isin(ok_ids)].copy()
    h1 = d.groupby("site_id").agg(H1_max=("H1", "max"),
                                  needs_review=("needs_review", "any")).reset_index()

    # forced-homogenization intensity (24h): greedy drops / candidate pool
    greedy = srem[srem.reason.str.startswith("dropped to achieve homogeneity")]
    g24 = greedy[greedy.duration == "24h"].groupby("site_id").size().rename("greedy_drops")
    used24 = sused[sused.duration == "24h"].groupby("site_id").size().rename("n_used")
    forced = pd.concat([g24, used24], axis=1).fillna({"greedy_drops": 0})
    forced["drop_frac"] = forced.greedy_drops / (forced.greedy_drops + forced.n_used)
    h1 = h1.merge(forced, left_on="site_id", right_index=True, how="left")

    h1 = h1.merge(man[["facility_id", "latitude", "longitude", "state"]],
                  left_on="site_id", right_on="facility_id", how="left")
    h1m = h1[~h1.site_id.isin(coord_bad)].dropna(subset=["latitude", "longitude"])
    h1c = h1m[~h1m.state.isin(C.NON_CONUS)]

    n_resid = int((h1.H1_max >= 1).sum())
    n_h2 = int((h1.H1_max >= 2).sum())
    aux_n = int(h1.greedy_drops.notna().sum())
    forced_any = float((h1.greedy_drops > 0).mean())
    forced_heavy = h1[h1.drop_frac >= 0.15]

    # ---------------------------------------------------------------- figure
    plt = C.style_matplotlib()
    fig, axes = plt.subplots(1, 2, figsize=(16, 5.5))
    for ax in axes:
        ax.set_aspect(1.25); ax.grid(False); ax.set_xticks([]); ax.set_yticks([])
        for s in ax.spines.values():
            s.set_visible(False)
        C.add_manifest_basemap(ax, man)

    ax = axes[0]
    mid = h1c[(h1c.H1_max >= 1) & (h1c.H1_max < 2)]
    hot = h1c[h1c.H1_max >= 2]
    ax.scatter(mid.longitude, mid.latitude, s=14, c=C.OKABE_ITO[1], linewidths=0,
               label=f"residual 1 <= H1 < 2 ({len(mid):,})")
    ax.scatter(hot.longitude, hot.latitude, s=26, c=C.OKABE_ITO[5], marker="^",
               linewidths=0, label=f"residual H1 >= 2 ({len(hot):,})")
    ax.legend(frameon=False, loc="lower left", fontsize=8)
    ax.set_title("Residual heterogeneity after pruning (worst duration)", fontsize=11)

    ax = axes[1]
    sub = h1c.dropna(subset=["drop_frac"])
    heavy = sub[sub.drop_frac >= 0.15]
    ax.scatter(heavy.longitude, heavy.latitude, s=6, c=C.OKABE_ITO[0], linewidths=0,
               rasterized=True,
               label=f">=15% of pool discarded to force homogeneity ({len(heavy):,})")
    ax.legend(frameon=False, loc="lower left", fontsize=8)
    ax.set_title("Forced-homogenization intensity (24h greedy drops)", fontsize=11)
    fig.suptitle("A3: where automated region formation struggles (partial fleet, CONUS)", y=1.0)
    fig.tight_layout()
    FIGS.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIGS / "a3_heterogeneity_maps.png")
    plt.close(fig)

    # hot-spot aggregation (aggregate cells only, per publication boundary)
    sub = h1c.dropna(subset=["drop_frac"]).copy()
    sub["cell_lat"] = (sub.latitude // GRID_DEG) * GRID_DEG
    sub["cell_lon"] = (sub.longitude // GRID_DEG) * GRID_DEG
    cells = sub.groupby(["cell_lat", "cell_lon"]).agg(
        n=("site_id", "size"), mean_dropfrac=("drop_frac", "mean"),
        state=("state", lambda s: s.mode().iat[0])).reset_index()
    hotcells = cells[cells.n >= 10].nlargest(12, "mean_dropfrac")

    # ---------------------------------------------------------------- report
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# Method diagnostics -- national fleet",
        "",
        "_Aggregate method-diagnostic geography for the NID fleet run. Public-safe:",
        "no per-dam vulnerability content. Sections are added as Phase-A/B analyses",
        "complete; QC context lives in `qc/reports/`._",
        "",
        "## A3 -- Heterogeneity hot-spots",
        "",
        f"_Generated {now} by `analysis/a3_heterogeneity.py`._",
        "",
        C.partial_data_note(commit, len(led)),
        "",
        "### QC gate",
        "",
        f"- {len(ok_ids):,} ok facilities pass integrity QC ({len(ok_ids) / led.ok.sum():.2%});",
        f"  {len(coord_bad)} coordinate-flagged facilities excluded from map layers.",
        f"- Forced-homogenization layer covers the {aux_n:,} facilities with station-audit",
        "  files (the 519 pre-centralization facilities lack them; integrity report A2b).",
        "- Register items: 3 (circular-only regions -- a different region method would",
        "  change WHERE pruning is needed), 2 (bad coordinates put facilities on the",
        "  wrong side of a gradient; the C1 flags matter most exactly here).",
        "",
        "### The two-layer picture",
        "",
        "The engine greedily prunes discordant stations until H1 < 1, so *final* H1 is",
        "homogeneous almost everywhere -- ",
        f"only {n_resid:,} facilities ({n_resid / len(h1):.1%}) retain H1 >= 1 in their worst",
        f"duration and just {n_h2} exceed 2. Residual H1 alone would therefore say \"no",
        "problem\", which is exactly the Keene lesson in reverse: **where the gradient is",
        "sharp, the cost shows up as discarded stations, not as a bad final statistic.**",
        f"Nationally {forced_any:.0%} of facilities needed at least one greedy drop at 24h,",
        f"and {len(forced_heavy):,} discarded >=15% of their candidate pool to reach",
        "homogeneity.",
        "",
        "![heterogeneity maps](figures/a3_heterogeneity_maps.png)",
        "",
        "### Hot-spot cells (aggregate, >=10 facilities)",
        "",
        "| cell (lat, lon) | state (mode) | facilities | mean pool fraction discarded |",
        "|---|---|---|---|",
    ] + [f"| ({r.cell_lat:.0f}, {r.cell_lon:.0f}) | {r.state} | {int(r.n)} | {r.mean_dropfrac:.1%} |"
         for _, r in hotcells.iterrows()] + [
        "",
        "### Alignment with known climate gradients (qualitative)",
        "",
        "Read against a physical map (at this commit):",
        "",
        "- **Forced homogenization is almost entirely a mountain-West phenomenon**: the",
        "  northern Rockies (MT/ID/WY densest), the Colorado Rockies and Wasatch, the",
        "  Great Basin ranges, and the Cascade/Sierra and coastal-California transitions.",
        "  East of about the 100th meridian heavy pruning is rare -- the Cascade-",
        "  transition lesson generalizes: sharp orographic gradients are what defeat",
        "  circular region formation.",
        "- **Residual heterogeneity has a second, eastern mode the pruning layer lacks**:",
        "  besides the same mountain-West belt, clusters sit over the Cumberland Plateau",
        "  (southern TN / northern AL), the Missouri Ozarks, the Adirondack/Green-Mountain",
        "  area, and peninsular Florida. There the pool is large and pruning mild, yet",
        "  H1 stays above 1 -- suggesting mixed storm populations (tropical vs frontal,",
        "  lake-effect) rather than terrain, a different failure mode deserving its own",
        "  review attention.",
        "- The flat interior (central plains, upper Midwest) is quiet in both layers.",
        "",
        "This is a qualitative overlay; **no spatial statistic is claimed**: facilities",
        "within ~175 km share candidate stations, so neighboring drop fractions are",
        "dependent by construction, and a station-blocked test belongs to the completion",
        "pass.",
        "",
        "### Use for review prioritization",
        "",
        "These hot-spots are where per-facility expert review (checklist sections 2-3,",
        "region-map inspection for divide-crossing and rain-shadow violations) matters",
        "most; the D1 stratified sample should oversample high-drop-fraction cells, and",
        f"the {n_resid:,} residual-H1 facilities plus the {len(forced_heavy):,} heavy-pruning",
        "facilities are natural members of its high-H1 stratum.",
        "",
        "### Pinned inputs",
        "",
        f"- Fleet data: `{commit}` (`claude/desktop-nid-ad-hoc`)",
        "- QC: `qc/reports/integrity_flags.csv`, `qc/reports/sanity_flags.csv`",
    ]
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "method_diagnostics.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"A3 done: residual H1>=1 at {n_resid:,} facilities; forced drops at "
          f"{forced_any:.0%}; heavy pruning {len(forced_heavy):,}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
