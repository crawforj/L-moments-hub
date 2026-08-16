"""Shared plumbing for the NID fleet QA/QC layer (docs/NID_QAQC_PLAN.md).

Reads the live fleet ledger from the `claude/desktop-nid-ad-hoc` branch
STRICTLY read-only: every file is extracted with `git show <commit>:<path>`
(LFS pointers are resolved with `git lfs smudge`) into a local cache keyed
by the pinned commit hash. Nothing here ever writes to `data/nid_progress/`
in any working tree, and nothing here touches the fleet branch itself.

Re-runnable / incremental: point `--ref` at any newer fleet-branch commit
and the scripts re-materialize and re-audit from scratch. The cache dir
(`qc/_cache/`) is gitignored.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pandas as pd

REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_ROOT = REPO_ROOT / "qc" / "_cache"

FLEET_REF_DEFAULT = "origin/claude/desktop-nid-ad-hoc"
PROGRESS_DIR = "data/nid_progress"

# Cumulative fleet output files (all under data/nid_progress/ on the fleet branch).
FLEET_FILES = [
    "completed_ids.csv",
    "all_facilities_DDF.csv",
    "batch_diagnostics.csv",
    "tail_sensitivity.csv",
    "gof.csv",
    "growth_curve.csv",
    "stations_used.csv",
    "stations_removed.csv",
    "regional_lmoments.csv",
    "progress.md",
]

# ---------------------------------------------------------------------------
# Key commits on the fleet branch (immutable history; established by direct
# inspection of `git log`/`git show` on origin/claude/desktop-nid-ad-hoc,
# 2026-08-16). These anchor the incident/cohort audits in nid_qc_integrity.py.
# ---------------------------------------------------------------------------
KEY_COMMITS = {
    # First tranche ever committed (153 attempted). 2026-08-11 13:36 UTC.
    "initial150": "3c5e76226f78f943aaf2a2b51b3eabdd7de9a7d4",
    # "Medium tranche" -> 453 attempted. This cohort (initial 150 + 300) ran in
    # the cloud-sandbox environment whose data/synthetic/ was never committed,
    # so the synthetic-fallback audit CANNOT be applied to it retroactively
    # (stated explicitly in the purge commit message). 2026-08-11 14:20 UTC.
    "cloud453": "ccdeabdedb4977219dcf74e7a5230faeaac1cbcc",
    # Last tranche committed BEFORE the synthetic-fallback fix (753 attempted).
    "last_prefix_tranche": "27587ac8a8c28646ad80b72b29581a805e647ed3",
    # The fix: use_local_fallback -> false. 2026-08-11 17:49 UTC.
    "synthetic_fix": "aeff8601d72b4946393eec65b71962b180c4fcc1",
    # The purge: 99 contaminated "ok" facilities removed from ledger + all
    # cumulative tables (99x2 diag, 99x2x5 tail, 99x2x12 DDF rows).
    # 2026-08-11 18:37 UTC.
    "synthetic_purge": "f36fc32862f1becc5810186e0eefcd03d2ad6439",
    # Centralized the per-facility aux tables (gof/growth_curve/stations_*/
    # regional_lmoments) into data/nid_progress/. Facilities completed before
    # this commit have NO rows in those aux files. 2026-08-11 19:23 UTC.
    "centralize_tables": "af7775cde1ef4ae377962a6ea20b7553c1edc085",
    # Last tranche run under the NARROW elevation band [600, 2600] m
    # (954 attempted at this point). 2026-08-11 20:54 UTC.
    "last_narrow_band_tranche": "e594ba02df4ba27ad9063ad6115df7d074dd47c4",
    # elevation_band_m widened [600,2600] -> [-100,6200]; 272 spurious
    # failures requeued (ledger 954 -> 682). Facilities that SUCCEEDED before
    # this ran with an elevation-restricted candidate-station pool.
    # 2026-08-11 21:14 UTC.
    "elev_band_fix": "603224c312e888bcf2b206ed7d0224f2cb519042",
    # Manifest refreshed from the live NID; 32 stale facility_ids removed from
    # the ledger (682 -> 650). Facilities completed before this ran against
    # the OLD manifest vintage (coordinates/attributes may differ).
    # 2026-08-11 21:40 UTC.
    "manifest_refresh": "a85ef3d2ceb1bb03dddf06632da1b88ef20e5a08",
    # First GitHub-Actions tranche. 2026-08-12 04:13 UTC.
    "first_gha_tranche": "04b849d6d3da34bf424750f26c7e8de3778b8123",
    # Cumulative CSVs moved to Git LFS (storage only). 2026-08-13 14:52 UTC.
    "lfs_move": "b24cfc77cbec7435029acd31eb0201663bfbc0a6",
}

EXPECTED_T = [2, 5, 10, 25, 50, 100, 200, 500, 1000, 2000, 5000, 10000]
EXPECTED_DURATIONS = ["24h", "72h"]
ROWS_PER_FACILITY_DDF = len(EXPECTED_T) * len(EXPECTED_DURATIONS)  # 24

EXPECTED_SCHEMAS = {
    "completed_ids.csv": ["facility_id", "name", "ok"],
    "all_facilities_DDF.csv": [
        "site", "duration", "return_period_yr", "AEP", "depth_mm",
        "depth_lo_mm", "depth_hi_mm", "rel_rmse",
    ],
    "batch_diagnostics.csv": [
        "site", "site_id", "duration", "n_stations", "H1", "homog_status",
        "chosen_dist", "chosen_absZ", "Z_acceptable", "selection_source",
        "reviewer", "runner_up", "runner_up_absZ", "z_margin",
        "review_recommended", "depth_10k_mm", "tail_min_10k_mm",
        "tail_max_10k_mm", "tail_spread_pct", "needs_review",
    ],
    "tail_sensitivity.csv": [
        "site", "site_id", "duration", "dist", "T", "growth_factor", "depth_mm",
    ],
    "gof.csv": ["site", "site_id", "duration", "dist", "Z", "absZ", "acceptable"],
    "growth_curve.csv": ["site", "site_id", "duration", "T", "F", "growth_factor"],
    "stations_used.csv": [
        "site", "site_id", "duration", "station_id", "name", "lat", "lon",
        "elev_m", "distance_km", "n_years", "mean_mm",
    ],
    "stations_removed.csv": [
        "site", "site_id", "duration", "station_id", "name", "reason",
    ],
}

# BOR-308 reference profile (validated subset), committed on main.
# NOTE: data/region_method_band/bor308_band.csv is NOT on main (it lives on the
# unmerged region-methods PR branch), so the reference shape used by the
# sanity layer is docs/example_outputs/fleet_308dam/batch_diagnostics.csv.
BOR308_DIAG = REPO_ROOT / "docs" / "example_outputs" / "fleet_308dam" / "batch_diagnostics.csv"

MANIFEST_PATH = REPO_ROOT / "config" / "nid_manifest.csv"

# ---------------------------------------------------------------------------
# Approximate state bounding boxes (degrees), generous outer envelopes of each
# state's true extent. Used with an additional buffer for the coarse
# coordinate-sanity screen (QAQC plan C1). A polygon-accurate in-state test is
# deferred to the completion pass; this screen targets gross errors (sign
# slips, digit transpositions, wrong-state coordinates).
# (lat_min, lat_max, lon_min, lon_max)
# ---------------------------------------------------------------------------
STATE_BBOX = {
    "AL": (30.1, 35.1, -88.6, -84.8), "AK": (51.0, 71.5, -180.0, -129.9),
    "AZ": (31.2, 37.1, -115.0, -108.9), "AR": (32.9, 36.6, -94.7, -89.6),
    "CA": (32.4, 42.1, -124.5, -114.0), "CO": (36.9, 41.1, -109.2, -102.0),
    "CT": (40.9, 42.1, -73.8, -71.7), "DE": (38.4, 39.9, -75.8, -74.9),
    "FL": (24.4, 31.1, -87.7, -79.9), "GA": (30.3, 35.1, -85.7, -80.7),
    "HI": (18.8, 22.3, -160.3, -154.7), "ID": (41.9, 49.1, -117.3, -110.9),
    "IL": (36.9, 42.6, -91.6, -87.4), "IN": (37.7, 41.8, -88.2, -84.7),
    "IA": (40.3, 43.6, -96.7, -90.1), "KS": (36.9, 40.1, -102.1, -94.5),
    "KY": (36.4, 39.2, -89.6, -81.9), "LA": (28.9, 33.1, -94.1, -88.7),
    "ME": (42.9, 47.5, -71.1, -66.8), "MD": (37.8, 39.8, -79.5, -74.9),
    "MA": (41.2, 42.9, -73.6, -69.8), "MI": (41.6, 48.4, -90.5, -82.3),
    "MN": (43.4, 49.5, -97.3, -89.4), "MS": (30.1, 35.1, -91.7, -88.0),
    "MO": (35.9, 40.7, -95.8, -89.0), "MT": (44.3, 49.1, -116.1, -103.9),
    "NE": (39.9, 43.1, -104.1, -95.2), "NV": (34.9, 42.1, -120.1, -113.9),
    "NH": (42.6, 45.4, -72.6, -70.5), "NJ": (38.8, 41.4, -75.6, -73.8),
    "NM": (31.2, 37.1, -109.1, -102.9), "NY": (40.4, 45.1, -79.8, -71.8),
    "NC": (33.7, 36.7, -84.4, -75.4), "ND": (45.8, 49.1, -104.1, -96.5),
    "OH": (38.3, 42.0, -84.9, -80.4), "OK": (33.5, 37.1, -103.1, -94.3),
    "OR": (41.9, 46.3, -124.6, -116.4), "PA": (39.6, 42.3, -80.6, -74.6),
    "PR": (17.8, 18.6, -67.4, -65.1), "RI": (41.1, 42.1, -71.9, -71.1),
    "SC": (32.0, 35.3, -83.4, -78.4), "SD": (42.4, 45.9, -104.1, -96.4),
    "TN": (34.9, 36.7, -90.4, -81.6), "TX": (25.7, 36.6, -106.7, -93.4),
    "UT": (36.9, 42.1, -114.1, -108.9), "VT": (42.6, 45.1, -73.5, -71.4),
    "VA": (36.5, 39.5, -83.7, -75.1), "WA": (45.5, 49.1, -124.9, -116.9),
    "WV": (37.1, 40.7, -82.7, -77.7), "WI": (42.4, 47.1, -92.9, -86.7),
    "WY": (40.9, 45.1, -111.1, -104.0),
}
NON_CONUS = {"AK", "HI", "PR"}
CONUS_ENVELOPE = (24.3, 49.5, -125.0, -66.8)  # lat_min, lat_max, lon_min, lon_max


def _git(args: list[str], binary: bool = False):
    """Run git in the repo root; return stdout (text or bytes)."""
    res = subprocess.run(
        ["git", "-C", str(REPO_ROOT)] + args,
        capture_output=True,
        check=True,
    )
    return res.stdout if binary else res.stdout.decode("utf-8", errors="replace")


def resolve_commit(ref: str) -> str:
    return _git(["rev-parse", ref]).strip()


def git_show_bytes(commit: str, path: str) -> bytes:
    """`git show commit:path`, resolving Git LFS pointers to real content."""
    raw = _git(["show", f"{commit}:{path}"], binary=True)
    if raw.startswith(b"version https://git-lfs.github.com/spec/v1"):
        res = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "lfs", "smudge"],
            input=raw,
            capture_output=True,
            check=True,
        )
        raw = res.stdout
    return raw


def materialize(ref: str = FLEET_REF_DEFAULT, files: list[str] | None = None) -> tuple[str, Path]:
    """Extract fleet files at `ref` into qc/_cache/<short12>/ (idempotent).

    Returns (full_commit_hash, cache_dir).
    """
    commit = resolve_commit(ref)
    cache = CACHE_ROOT / commit[:8]
    cache.mkdir(parents=True, exist_ok=True)
    for f in files or FLEET_FILES:
        dest = cache / f
        if dest.exists() and dest.stat().st_size > 0:
            continue
        data = git_show_bytes(commit, f"{PROGRESS_DIR}/{f}")
        dest.write_bytes(data)
        print(f"  materialized {f} ({len(data):,} bytes)", file=sys.stderr)
    return commit, cache


# Column typing per file. Facility/site names are read as literal strings
# (keep_default_na=False) because real dam names like "NA" would otherwise be
# silently converted to missing values; numerics/booleans are then converted
# explicitly, with R's "NA" sentinel coerced to NaN only where it belongs.
_TABLE_TYPES: dict[str, dict[str, list[str]]] = {
    "completed_ids.csv": {"bool": ["ok"]},
    "all_facilities_DDF.csv": {
        "num": ["return_period_yr", "AEP", "depth_mm", "depth_lo_mm", "depth_hi_mm", "rel_rmse"],
    },
    "batch_diagnostics.csv": {
        "num": ["n_stations", "H1", "chosen_absZ", "runner_up_absZ", "z_margin",
                "depth_10k_mm", "tail_min_10k_mm", "tail_max_10k_mm", "tail_spread_pct"],
        "bool": ["Z_acceptable", "review_recommended", "needs_review"],
        "na_str": ["reviewer", "selection_source", "runner_up"],
    },
    "tail_sensitivity.csv": {"num": ["T", "growth_factor", "depth_mm"]},
    "gof.csv": {"num": ["Z", "absZ"], "bool": ["acceptable"]},
    "growth_curve.csv": {"num": ["T", "F", "growth_factor"]},
    "stations_used.csv": {"num": ["lat", "lon", "elev_m", "distance_km", "n_years", "mean_mm"]},
    "stations_removed.csv": {},
    "nid_manifest.csv": {
        "num": ["latitude", "longitude", "elevation_m", "nid_storage_acreft", "drainage_area_mi2"],
    },
}


def _apply_types(df: pd.DataFrame, fname: str) -> pd.DataFrame:
    spec = _TABLE_TYPES.get(fname, {})
    for c in spec.get("num", []):
        if c in df.columns:
            df[c] = pd.to_numeric(df[c].replace({"": None, "NA": None}), errors="coerce")
    for c in spec.get("bool", []):
        if c in df.columns:
            df[c] = df[c].map({"TRUE": True, "FALSE": False})
    for c in spec.get("na_str", []):
        if c in df.columns:
            df[c] = df[c].replace({"NA": None, "": None})
    return df


def read_table(path: Path, fname: str | None = None) -> pd.DataFrame:
    """CSV reader that never mangles a dam named 'NA' into a missing value."""
    fname = fname or path.name
    df = pd.read_csv(path, dtype=str, keep_default_na=False, na_values=[])
    return _apply_types(df, fname)


def load_fleet_table(cache: Path, fname: str) -> pd.DataFrame:
    return read_table(cache / fname, fname)


def ledger_at(commit: str) -> pd.DataFrame:
    """completed_ids.csv as of an arbitrary historical fleet-branch commit."""
    import io

    data = git_show_bytes(commit, f"{PROGRESS_DIR}/completed_ids.csv")
    df = pd.read_csv(io.BytesIO(data), dtype=str, keep_default_na=False, na_values=[])
    return _apply_types(df, "completed_ids.csv")


def load_manifest() -> pd.DataFrame:
    return read_table(MANIFEST_PATH, "nid_manifest.csv")


def load_bor308_reference() -> pd.DataFrame:
    return read_table(BOR308_DIAG, "batch_diagnostics.csv")


# ---------------------------------------------------------------------------
# Figure style (light docs surface; colorblind-safe Okabe-Ito for categorical
# identity; single-hue ramps for magnitude).
# ---------------------------------------------------------------------------
OKABE_ITO = [
    "#0072B2",  # blue
    "#E69F00",  # orange
    "#009E73",  # green
    "#CC79A7",  # magenta
    "#56B4E9",  # sky
    "#D55E00",  # vermillion
    "#F0E442",  # yellow
    "#000000",  # black
]
INK = "#1a1a2e"
MUTED = "#6b7280"
GRID = "#e5e7eb"
BASE_GRAY = "#d4d4d8"  # background facility layer on maps


def style_matplotlib():
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "axes.edgecolor": GRID,
        "axes.labelcolor": INK,
        "axes.titlecolor": INK,
        "axes.grid": True,
        "grid.color": GRID,
        "grid.linewidth": 0.6,
        "xtick.color": MUTED,
        "ytick.color": MUTED,
        "text.color": INK,
        "font.size": 10,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "savefig.dpi": 150,
        "savefig.bbox": "tight",
        "savefig.facecolor": "white",
    })
    return plt


def conus_map_axes(plt, figsize=(11, 7)):
    """Bare CONUS map axes: no ticks/grid, equal-ish aspect at mid-latitudes."""
    fig, ax = plt.subplots(figsize=figsize)
    ax.set_aspect(1.25)  # ~1/cos(38 deg): keeps CONUS from looking squashed
    ax.grid(False)
    ax.set_xticks([])
    ax.set_yticks([])
    for s in ax.spines.values():
        s.set_visible(False)
    return fig, ax


def add_manifest_basemap(ax, manifest: pd.DataFrame, conus_only: bool = True):
    """All-manifest facility layer in light gray -- the 73k dam locations
    trace the national outline, giving a self-contained basemap with no
    external boundary data."""
    m = manifest.dropna(subset=["latitude", "longitude"])
    if conus_only:
        m = m[~m["state"].isin(NON_CONUS)]
        m = m[
            m.latitude.between(CONUS_ENVELOPE[0], CONUS_ENVELOPE[1])
            & m.longitude.between(CONUS_ENVELOPE[2], CONUS_ENVELOPE[3])
        ]
    ax.scatter(m.longitude, m.latitude, s=1, c=BASE_GRAY, linewidths=0, rasterized=True)
    ax.set_xlim(CONUS_ENVELOPE[2] - 1, CONUS_ENVELOPE[3] + 1)
    ax.set_ylim(CONUS_ENVELOPE[0] - 1, CONUS_ENVELOPE[1] + 1)


def partial_data_note(commit: str, attempted: int, total: int = 73303) -> str:
    return (
        f"**Partial data.** Input pinned to fleet-branch commit `{commit}` "
        f"(`claude/desktop-nid-ad-hoc`), N = {attempted:,} of {total:,} facilities "
        f"attempted ({attempted / total:.1%}). The fleet runs largest-storage-first, "
        f"so this partial sample over-represents large dams; refresh every artifact "
        f"at fleet completion before treating any number here as final."
    )
