"""Phase A1 -- the failure atlas / gauge-desert map (docs/NID_ANALYSIS_PLAN.md).

Public-safe: maps where the regional L-moments METHOD fails for lack of
usable stations, and where station support is thin -- national monitoring-gap
material. Contains no per-dam vulnerability content (failure = the method
produced nothing for that facility).

Verification discipline (QAQC plan section E): failures should cluster where
stations are sparse almost by construction, so the headline "failures cluster"
claim is tested against BOTH a uniform spatial null and a station-sparsity-
weighted null; only clustering beyond the sparsity-weighted null would indicate
anything more than the obvious.

Outputs: docs/analysis/failure_atlas.md + docs/analysis/figures/a1_*.png

Usage:  python analysis/a1_failure_atlas.py [--ref origin/claude/desktop-nid-ad-hoc]
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
GRID_DEG = 1.0
N_NULL = 2000
RNG = np.random.default_rng(31250)


def mean_nn_km(lat: np.ndarray, lon: np.ndarray) -> float:
    """Mean nearest-neighbour great-circle distance (km) within a point set."""
    la = np.radians(lat)
    lo = np.radians(lon)
    x = np.cos(la) * np.cos(lo)
    y = np.cos(la) * np.sin(lo)
    z = np.sin(la)
    pts = np.stack([x, y, z], axis=1)
    d = pts @ pts.T
    np.fill_diagonal(d, -2.0)
    nn = np.arccos(np.clip(d.max(axis=1), -1, 1)) * 6371.0
    return float(nn.mean())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", default=C.FLEET_REF_DEFAULT)
    args = ap.parse_args()

    commit, cache = C.materialize(args.ref)
    led = C.load_fleet_table(cache, "completed_ids.csv")
    diag = C.load_fleet_table(cache, "batch_diagnostics.csv")
    man = C.load_manifest()

    # ---------------------------------------------------------------- QC gate
    qc_flags = pd.read_csv(C.REPO_ROOT / "qc" / "reports" / "integrity_flags.csv")
    hard_fail = set(qc_flags[qc_flags.severity == "FAIL"].facility_id)
    san_flags = pd.read_csv(C.REPO_ROOT / "qc" / "reports" / "sanity_flags.csv")
    coord_bad = set(san_flags[san_flags.flag.str.startswith("coord_")].facility_id)
    led_q = led[~led.facility_id.isin(hard_fail)]
    pass_rate = len(led_q) / len(led)

    att = led_q.merge(man, on="facility_id", how="left", suffixes=("_l", ""))
    att_m = att[~att.facility_id.isin(coord_bad)].dropna(subset=["latitude", "longitude"])
    fails = att_m[~att_m.ok]
    oks = att_m[att_m.ok]

    d24 = diag[diag.duration == "24h"][["site_id", "n_stations"]]
    oks = oks.merge(d24, left_on="facility_id", right_on="site_id", how="left")

    # ------------------------------------------------ failure-rate accounting
    fail_rate = len(fails) / len(att_m)
    by_state = att_m.groupby("state").agg(n=("ok", "size"), failed=("ok", lambda s: (~s).sum()))
    by_state["rate"] = by_state.failed / by_state.n
    fail_states = by_state[by_state.failed > 0].sort_values("failed", ascending=False)

    # ------------------------------------------------ clustering vs two nulls
    obs = mean_nn_km(fails.latitude.to_numpy(), fails.longitude.to_numpy())
    coords = att_m[["latitude", "longitude"]].to_numpy()
    k = len(fails)

    def null_stat(weights=None):
        stats = np.empty(N_NULL)
        p = None
        if weights is not None:
            p = weights / weights.sum()
        for i in range(N_NULL):
            idx = RNG.choice(len(coords), size=k, replace=False, p=p)
            stats[i] = mean_nn_km(coords[idx, 0], coords[idx, 1])
        return stats

    null_uniform = null_stat()
    # station-sparsity weight: inverse of local station support. For ok
    # facilities use their own 24h n_stations; for failed ones (which have no
    # diagnostics) use the nearest ok facility's n_stations.
    from scipy.spatial import cKDTree

    ok_xy = np.radians(oks[["latitude", "longitude"]].to_numpy())
    tree = cKDTree(ok_xy)
    att_xy = np.radians(att_m[["latitude", "longitude"]].to_numpy())
    _, nearest = tree.query(att_xy, k=1)
    local_n = oks.n_stations.to_numpy()[nearest]
    own = att_m.merge(d24, left_on="facility_id", right_on="site_id", how="left").n_stations.to_numpy()
    local_n = np.where(np.isnan(own), local_n, own)
    w_sparse = 1.0 / (1.0 + local_n)
    null_sparse = null_stat(w_sparse)

    p_uniform = float((null_uniform <= obs).mean())
    p_sparse = float((null_sparse <= obs).mean())

    # ------------------------------------------------ gauge-desert aggregation
    oks["cell_lat"] = (oks.latitude // GRID_DEG) * GRID_DEG
    oks["cell_lon"] = (oks.longitude // GRID_DEG) * GRID_DEG
    cells = oks.groupby(["cell_lat", "cell_lon"]).agg(
        n_fac=("facility_id", "size"), mean_stations=("n_stations", "mean")).reset_index()
    sparse_cells = cells[(cells.n_fac >= 5)].nsmallest(15, "mean_stations")

    fails_cells = fails.copy()
    fails_cells["cell_lat"] = (fails_cells.latitude // GRID_DEG) * GRID_DEG
    fails_cells["cell_lon"] = (fails_cells.longitude // GRID_DEG) * GRID_DEG
    fail_cell_counts = fails_cells.groupby(["cell_lat", "cell_lon", "state"]).size() \
        .reset_index(name="failures").sort_values("failures", ascending=False)

    # ---------------------------------------------------------------- figures
    plt = C.style_matplotlib()

    fig, ax = C.conus_map_axes(plt)
    C.add_manifest_basemap(ax, man)
    ax.scatter(fails.longitude, fails.latitude, s=42, c=C.OKABE_ITO[5], marker="x",
               linewidths=1.8, label=f"method failures ({len(fails)})")
    ax.legend(frameon=False, loc="lower left")
    ax.set_title("A1: facilities where the regional method FAILED (too few usable stations)\n"
                 f"partial fleet, {len(att_m):,} attempted; gray = all 73,303 NID facilities")
    FIGS.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIGS / "a1_failure_map.png")
    plt.close(fig)

    fig, ax = C.conus_map_axes(plt)
    conus_cells = cells[(cells.cell_lat >= C.CONUS_ENVELOPE[0]) & (cells.cell_lat <= C.CONUS_ENVELOPE[1])
                        & (cells.cell_lon >= C.CONUS_ENVELOPE[2]) & (cells.cell_lon <= C.CONUS_ENVELOPE[3])]
    sc = ax.scatter(conus_cells.cell_lon + GRID_DEG / 2, conus_cells.cell_lat + GRID_DEG / 2,
                    c=conus_cells.mean_stations, cmap="Blues", s=34, marker="s", linewidths=0)
    cb = fig.colorbar(sc, ax=ax, shrink=0.7, label="mean stations per region (24h)")
    cb.outline.set_visible(False)
    fails_conus = fails[~fails.state.isin(C.NON_CONUS)]
    n_noncon = len(fails) - len(fails_conus)
    ax.scatter(fails_conus.longitude, fails_conus.latitude, s=42, c=C.OKABE_ITO[5], marker="x",
               linewidths=1.8,
               label=f"failures ({len(fails_conus)} CONUS; +{n_noncon} AK/HI/PR not shown)")
    ax.set_xlim(C.CONUS_ENVELOPE[2] - 1, C.CONUS_ENVELOPE[3] + 1)
    ax.set_ylim(C.CONUS_ENVELOPE[0] - 1, C.CONUS_ENVELOPE[1] + 1)
    ax.legend(frameon=False, loc="lower left")
    ax.set_title("A1: station support per 1-degree cell (successful facilities) with failures overlaid\n"
                 "darker = better-gauged; failures should sit in light cells")
    fig.savefig(FIGS / "a1_station_support.png")
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(8, 4))
    for arr, color, label in ((null_uniform, C.OKABE_ITO[0], "uniform null"),
                              (null_sparse, C.OKABE_ITO[1], "sparsity-weighted null")):
        ax.hist(arr, bins=40, alpha=0.55, color=color, label=label)
    ax.axvline(obs, color=C.OKABE_ITO[5], lw=2)
    ax.text(obs, ax.get_ylim()[1] * 0.95, f" observed {obs:.0f} km", color=C.OKABE_ITO[5],
            va="top", fontsize=9)
    ax.set_xlabel(f"mean nearest-neighbour distance among {k} failures (km)")
    ax.set_ylabel("null draws")
    ax.legend(frameon=False)
    ax.set_title("A1 null check: is failure clustering more than station sparsity explains?")
    fig.savefig(FIGS / "a1_clustering_null.png")
    plt.close(fig)

    # ---------------------------------------------------------------- report
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    stations_lo = oks.n_stations.quantile(0.05)
    lines = [
        "# A1 -- Failure atlas and gauge-desert map",
        "",
        f"_Generated {now} by `analysis/a1_failure_atlas.py`. Public-safe per the analysis",
        "plan's boundary: failure locations are method-failure facts (the pipeline produced",
        "NOTHING for these facilities), not vulnerability rankings; monitoring-gap",
        "candidates are aggregated to 1-degree cells and states, never per dam._",
        "",
        C.partial_data_note(commit, len(led)),
        "",
        "## QC gate",
        "",
        f"- Integrity hard-fail facilities excluded: {len(hard_fail)} "
        f"(pass rate {pass_rate:.2%}).",
        f"- {len(coord_bad)} facilities with coordinate flags (`qc/reports/sanity_flags.csv`)",
        "  excluded from all map layers -- their plotted position would be wrong.",
        "- Register items touched: 7 (failures are reported, not silent -- this analysis IS",
        "  that item), 2 (coordinates unverified), 6 (timeout tranches never wrote partial",
        "  rows, so the failure set is complete for attempted facilities).",
        "",
        "## Headline numbers",
        "",
        f"- Failures: **{len(fails)} of {len(att_m):,} attempted ({fail_rate:.2%})** at this",
        "  stage of the run. This is far below the ~15% the BOR-308 subset saw, for two",
        "  reasons that must temper every conclusion below: (1) the fleet runs",
        "  largest-storage-first, and large dams sit disproportionately in well-gauged",
        "  basins; (2) 272 early \"failures\" were the elevation-band config bug",
        "  (fixed in `603224c3`) and were requeued -- they are not method failures.",
        f"- Per-facility failure *reasons* are *not* in the committed ledger (only ok",
        "  TRUE/FALSE); progress.md attributes failures to \"too-few-stations etc.\".",
        "  **Recommendation for the completion pass: persist the per-facility failure",
        "  reason** the way the BOR-308 run's `batch_status.csv` did.",
        "",
        "## Where the method fails",
        "",
        "![failure map](figures/a1_failure_map.png)",
        "",
        "Failures by state (all states with >=1 failure):",
        "",
        "| State | attempted | failed | rate |",
        "|---|---|---|---|",
    ]
    for st, r in fail_states.iterrows():
        lines.append(f"| {st} | {int(r.n):,} | {int(r.failed)} | {r.rate:.2%} |")
    ne_fail = int(fail_states.reindex(["NH", "MA", "CT", "ME", "VT", "RI"]).failed.sum())
    ak_rate = by_state.loc["AK", "rate"] if "AK" in by_state.index else 0
    lines += [
        "",
        "Reading (at this commit):",
        "",
        f"- **Alaska is the standout gauge desert**: {ak_rate:.0%} of attempted AK",
        "  facilities fail outright -- consistent with GHCN-Daily's thin AK coverage and",
        "  the 20-yr record screen.",
        "- **Honest negative on the BOR Oklahoma pattern**: 6 of 8 BOR-308 failures were",
        f"  in OK, but at fleet scale OK's failure rate is only "
        f"{fail_states.loc['OK'].rate:.2%} of {int(fail_states.loc['OK'].n):,} attempted -- "
        f"~{fail_states.loc['OK'].rate / fail_rate:.1f}x the national {fail_rate:.2%}, a",
        "  modest elevation, not a hot spot. The BOR-subset concentration now looks like",
        "  small-N coincidence amplified by the BOR manifest's OK exposure rather than a",
        "  dramatic regional data gap; re-test at completion.",
        f"- **An unexpected New England cluster** ({ne_fail} failures across NH/MA/CT and",
        "  neighbors) sits in a region that is NOT gauge-sparse on the support map --",
        "  candidate explanations are the 20-yr 72h-completeness screen thinning dense",
        "  but short-record station sets, or aggressive discordancy pruning; this is the",
        "  first thing to investigate when per-facility failure reasons are persisted.",
        "",
        "## Is the clustering real, or just station sparsity?",
        "",
        "**The null the plan demands:** failures occur where usable stations are sparse",
        "*almost by construction* (too-few-stations is the dominant failure mode), so",
        "\"failures cluster\" is not by itself a finding. Observed mean nearest-neighbour",
        f"distance among the {k} failures: **{obs:.0f} km**.",
        "",
        f"- vs a **uniform** null (random {k}-subsets of attempted facilities,",
        f"  {N_NULL} draws): one-sided p = {p_uniform:.3f}"
        f" ({'clustered beyond uniform' if p_uniform < 0.05 else 'NOT significantly clustered beyond uniform'}).",
        f"- vs a **station-sparsity-weighted** null (draw probability proportional to",
        f"  1/(1+local station count)): one-sided p = {p_sparse:.3f}"
        f" ({'clustering EXCEEDS what sparsity alone explains' if p_sparse < 0.05 else 'clustering does NOT exceed what sparsity alone explains'}).",
        "",
        "![clustering null](figures/a1_clustering_null.png)",
        "",
        f"With only {k} failures the power of this test is low; it will be re-run at",
        "completion when the failure set is an order of magnitude larger. Spatial-pattern",
        "caveat: facilities within ~175 km share candidate stations, so failure events are",
        "not independent observations -- p-values here are descriptive, not inferential.",
        "",
        "## Gauge deserts (aggregate monitoring-gap candidates)",
        "",
        "![station support](figures/a1_station_support.png)",
        "",
        f"Station support among successes: median {oks.n_stations.median():.0f} stations",
        f"per 24h region, 5th percentile {stations_lo:.0f}. The lowest-support 1-degree",
        "cells (>=5 facilities) -- candidate monitoring gaps, aggregate only:",
        "",
        "| cell (lat, lon) | facilities | mean stations |",
        "|---|---|---|",
    ]
    for _, r in sparse_cells.iterrows():
        lines.append(f"| ({r.cell_lat:.0f}, {r.cell_lon:.0f}) | {int(r.n_fac)} | {r.mean_stations:.1f} |")
    lines += [
        "",
        "Failure concentrations by 1-degree cell:",
        "",
        "| cell (lat, lon) | state | failures |",
        "|---|---|---|",
    ] + [f"| ({r.cell_lat:.0f}, {r.cell_lon:.0f}) | {r.state} | {int(r.failures)} |"
         for _, r in fail_cell_counts.head(10).iterrows()] + [
        "",
        "## Pinned inputs",
        "",
        f"- Fleet data: `{commit}` (`claude/desktop-nid-ad-hoc`)",
        "- QC: `qc/reports/integrity_flags.csv`, `qc/reports/sanity_flags.csv` at the same commit",
    ]
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "failure_atlas.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"A1 done: {len(fails)} failures, p_uniform={p_uniform:.3f}, p_sparse={p_sparse:.3f}",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
