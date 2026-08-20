#!/usr/bin/env python3
"""BOR-308 vs NID-fleet reproducibility cross-check (QA/QC plan D2, analysis plan B4).

The same physical Bureau of Reclamation dams were run through this pipeline
TWICE, months of code-churn apart, from two different manifests:

  * the **BOR-308 batch** (`docs/example_outputs/fleet_308dam/`, run 2026-08-11
    from `config/facilities_BOR.csv` when that manifest still carried
    `elevation_m = NA` fleet-wide), plus a second, elevation-ENRICHED circular
    baseline re-run on 2026-08-14 whose depths survive in
    `data/region_method_band/bor308_band.csv` (`depth_circular_mm`);
  * the **national NID fleet** (`claude/desktop-nid-ad-hoc`, run 2026-08-11
    onward from `config/nid_manifest.csv`, `elevation_m = NA` fleet-wide),
    which processes largest-storage-first, so the big BOR dams are long done.

Comparing the matched facilities is a reproducibility statement: agreement is
evidence the pipeline is deterministic and manifest-independent, disagreement
is a finding. This script builds that comparison and attributes the
differences to the KNOWN input differences between the runs rather than
asserting a cause.

Design notes
------------
* **Crosswalk is ID-keyed, never name-keyed.** Both manifests carry the NID
  `facility_id`; 1,174 duplicate dam names nationally (and 3 duplicate-name
  pairs inside BOR-308 alone) make a name join unsafe. Name-keyed *outputs*
  are recovered only via a verified fingerprint (below), and everything that
  cannot be verified is reported as unmatched, not fuzzy-matched.
* **Name-keyed DDF recovery.** Both runs' `all_facilities_DDF.csv` are keyed by
  dam NAME with no usable `site_id` for the early cohort (known-issue register
  item 8). Their `batch_diagnostics.csv` IS site_id-keyed and carries
  `depth_10k_mm`, so each name's contiguous 24-row DDF block is matched to a
  site_id by its (24h, 72h) T=10,000-yr depth pair. A block is accepted only
  when EXACTLY ONE candidate block matches both durations.
* **Cohorts.** Facilities that completed before the fleet's elevation-band fix
  (`603224c3`, band `[600, 2600]` -> `[-100, 6200]`) ran the SAME candidate
  pool rule as both BOR runs; later ones did not. Membership is read from the
  fleet ledger at `manifest_refresh` (`a85ef3d2`), the first ledger state after
  both the band fix and the manifest refresh.

Re-run
------
    python qc/nid_bor_crosscheck.py                 # uses the pinned inputs
    python qc/nid_bor_crosscheck.py --fleet-ref origin/claude/desktop-nid-ad-hoc

The NID cumulative tables are published as gzipped assets on the *live*
pre-release tag `nid-run1-data`, which is re-clobbered after every tranche
round. The MD5s of the exact snapshot used for the committed report are pinned
below; a re-run against a newer snapshot prints a loud WARNING and records the
new digests, it does not silently pretend to be the same analysis.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import re
import subprocess
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nid_qc_common import (  # noqa: E402
    KEY_COMMITS,
    OKABE_ITO,
    REPO_ROOT,
    ledger_at,
    read_table,
    style_matplotlib,
)

# --------------------------------------------------------------------------
# Pinned inputs (the snapshot the committed report was generated from).
# --------------------------------------------------------------------------
FLEET_COMMIT_PIN = "b63d8180746aee55239b3b5fa683c078fa5a9940"
RELEASE_TAG = "nid-run1-data"
RELEASE_REPO = "crawforj/L-moments-hub"
ASSET_MD5_PIN = {
    "all_facilities_DDF.csv.gz": "7692f87ecae15fb3c36b41fc1a93799c",
    "batch_diagnostics.csv.gz": "62e42f1d862bce352c8d8f493abb0d78",
    "stations_used.csv.gz": "7809f51141a233db5037bc6041e484cd",
    "stations_removed.csv.gz": "5b19a6bcfe12ddfa5740f29c661deb21",
}
ASSETS = list(ASSET_MD5_PIN)
NID_STATE_PIN = {"completed_rows": 50451, "uploaded_at": "2026-08-20T03:23:19Z"}
FLEET_TOTAL = 73303

# The elevation band in force for BOTH BOR runs and for the pre-`603224c3`
# slice of the NID fleet (config/como.yml at the time; widened on main only on
# 2026-08-18, commit ca9a22ff).
NARROW_BAND_M = (600.0, 2600.0)

EXPECTED_T = [2, 5, 10, 25, 50, 100, 200, 500, 1000, 2000, 5000, 10000]
DURATIONS = ["24h", "72h"]
CANON_BLOCK = [(d, t) for d in DURATIONS for t in EXPECTED_T]
HEADLINE_T = [100, 10000]

BOR_MANIFEST = REPO_ROOT / "config" / "facilities_BOR.csv"
BOR_PRE_DDF = REPO_ROOT / "docs" / "example_outputs" / "fleet_308dam" / "all_facilities_DDF.csv"
BOR_PRE_DIAG = REPO_ROOT / "docs" / "example_outputs" / "fleet_308dam" / "batch_diagnostics.csv"
BOR_POST_BAND = REPO_ROOT / "data" / "region_method_band" / "bor308_band.csv"
GHCN_STATIONS = REPO_ROOT / "data" / "ghcn_inventory" / "ghcnd-stations.txt.gz"

OUT_CSV = REPO_ROOT / "qc" / "reports" / "bor_nid_crosscheck.csv"
FIG_DIR = REPO_ROOT / "docs" / "analysis" / "figures"
ASSET_CACHE = REPO_ROOT / "qc" / "_cache" / "nid_release"


# --------------------------------------------------------------------------
# Input acquisition
# --------------------------------------------------------------------------
def md5(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_assets(assets_dir: Path, skip_download: bool) -> dict[str, str]:
    """Download (unless already present) the release assets; return their MD5s."""
    assets_dir.mkdir(parents=True, exist_ok=True)
    missing = [a for a in ASSETS if not (assets_dir / a).exists()]
    if missing and not skip_download:
        print(f"  downloading {len(missing)} release asset(s) from {RELEASE_TAG} ...",
              file=sys.stderr)
        subprocess.run(
            ["gh", "release", "download", RELEASE_TAG, "--repo", RELEASE_REPO]
            + sum([["--pattern", a] for a in missing], [])
            + ["--dir", str(assets_dir)],
            check=True,
        )
    digests = {}
    drift = []
    for a in ASSETS:
        p = assets_dir / a
        if not p.exists():
            raise SystemExit(f"missing release asset {p} (re-run without --skip-download)")
        digests[a] = md5(p)
        if digests[a] != ASSET_MD5_PIN[a]:
            drift.append(a)
    if drift:
        print("\n  *** WARNING: release-asset snapshot differs from the pinned one ***",
              file=sys.stderr)
        for a in drift:
            print(f"      {a}: pinned {ASSET_MD5_PIN[a]}  now {digests[a]}", file=sys.stderr)
        print("      The tag is re-clobbered every tranche round; numbers below will\n"
              "      not match the committed report. Re-pin deliberately.\n", file=sys.stderr)
    return digests


def read_gz(assets_dir: Path, name: str, usecols=None) -> pd.DataFrame:
    with gzip.open(assets_dir / name, "rb") as f:
        raw = f.read()
    return pd.read_csv(io.BytesIO(raw), dtype=str, keep_default_na=False,
                       na_values=[], usecols=usecols)


def git_text(commit: str, path: str) -> str:
    return subprocess.run(["git", "-C", str(REPO_ROOT), "show", f"{commit}:{path}"],
                          capture_output=True, check=True).stdout.decode("utf-8", "replace")


# --------------------------------------------------------------------------
# Name-keyed DDF -> site_id recovery (verified, never fuzzy)
# --------------------------------------------------------------------------
def resolve_ddf_blocks(ddf: pd.DataFrame, diag: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Attribute each 24-row DDF name-block to a site_id via its T=10,000 fingerprint.

    Returns (resolved_long, unresolved_report). `resolved_long` carries a
    `facility_id` column; `unresolved_report` says why each failure failed.
    """
    ddf = ddf.copy()
    ddf["row"] = np.arange(len(ddf))
    fp = diag.set_index(["site_id", "duration"])["depth_10k_mm"]
    by_name = {n: g.sort_values("row") for n, g in ddf.groupby("site")}
    kept, failed = [], []
    for sid, dg in diag.groupby("site_id"):
        name = dg["site"].iloc[0]
        g = by_name.get(name)
        if g is None or len(g) % len(CANON_BLOCK):
            failed.append((sid, name, "no_clean_name_block"))
            continue
        blocks = [g.iloc[i:i + 24] for i in range(0, len(g), 24)]
        # every accepted block must have the canonical (duration, T) layout and
        # be contiguous in the file -- otherwise the fold-in appended
        # interleaved rows and block attribution is not defensible.
        if any(list(zip(b["duration"], b["return_period_yr"])) != CANON_BLOCK
               or b["row"].max() - b["row"].min() != 23 for b in blocks):
            failed.append((sid, name, "non_canonical_block_layout"))
            continue
        try:
            want = {d: float(fp.loc[(sid, d)]) for d in DURATIONS}
        except KeyError:
            failed.append((sid, name, "no_10k_fingerprint"))
            continue
        hit = [b for b in blocks
               if all(abs(float(b.loc[(b["duration"] == d) & (b["return_period_yr"] == 10000),
                                      "depth_mm"].iloc[0]) - want[d]) < 0.06 for d in DURATIONS)]
        if len(hit) == 1:
            b = hit[0].copy()
            b["facility_id"] = sid
            kept.append(b)
        else:
            failed.append((sid, name, f"{len(hit)}_fingerprint_matches"))
    resolved = pd.concat(kept) if kept else pd.DataFrame()
    return resolved, pd.DataFrame(failed, columns=["facility_id", "name", "reason"])


def numify(df: pd.DataFrame, cols: list[str]) -> pd.DataFrame:
    for c in cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c].replace({"NA": None, "": None}), errors="coerce")
    return df


def haversine_km(lat1, lon1, lat2, lon2):
    r = 6371.0088
    p1, p2 = np.radians(lat1), np.radians(lat2)
    dp, dl = p2 - p1, np.radians(lon2 - lon1)
    a = np.sin(dp / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(dl / 2) ** 2
    return 2 * r * np.arcsin(np.sqrt(a))


def ghcn_station_elevations() -> pd.DataFrame:
    rec = []
    with gzip.open(GHCN_STATIONS, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            rec.append((line[0:11].strip(), line[31:37].strip()))
    st = pd.DataFrame(rec, columns=["station_id", "elev_m"])
    st["elev_m"] = pd.to_numeric(st["elev_m"], errors="coerce")
    return st


def completion_rank_dates(fleet_commit: str) -> pd.Series:
    """Map fleet-ledger rank -> estimated completion time.

    The tranche commit subjects carry 'Facilities attempted: N / 73303', giving
    a dated (rank, time) series. Only usable ABOVE the last ledger rewrite
    (the requeues at `elev_band_fix` / `manifest_refresh` reorder early ranks),
    so ranks <= 1050 are returned as NaT.
    """
    log = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "log", "--format=%cI%x09%s", fleet_commit,
         "--", "data/nid_progress/completed_ids.csv"],
        capture_output=True, check=True, text=True).stdout.splitlines()
    pts = set()
    for line in log:
        when, _, subj = line.partition("\t")
        m = re.search(r"attempted[^0-9]*([0-9,]+)\s*/\s*%d" % FLEET_TOTAL, subj)
        if m:
            pts.add((pd.Timestamp(when).tz_convert("UTC").value,
                     int(m.group(1).replace(",", ""))))
    pts = sorted(pts, key=lambda x: x[1])
    n = np.array([p[1] for p in pts])
    ts = np.array([p[0] for p in pts])
    return pd.Series({"n": n, "ts": ts})


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fleet-ref", default=FLEET_COMMIT_PIN,
                    help="fleet-branch commit/ref for completed_ids.csv (default: pinned)")
    ap.add_argument("--assets-dir", type=Path, default=ASSET_CACHE)
    ap.add_argument("--skip-download", action="store_true")
    ap.add_argument("--out-csv", type=Path, default=OUT_CSV)
    ap.add_argument("--fig-dir", type=Path, default=FIG_DIR)
    ap.add_argument("--no-figures", action="store_true")
    args = ap.parse_args()

    fleet_commit = subprocess.run(["git", "-C", str(REPO_ROOT), "rev-parse", args.fleet_ref],
                                  capture_output=True, check=True, text=True).stdout.strip()
    print("=" * 78)
    print("BOR-308 vs NID-fleet reproducibility cross-check (QAQC D2 / analysis B4)")
    print("=" * 78)
    print(f"fleet commit : {fleet_commit}")
    digests = fetch_assets(args.assets_dir, args.skip_download)
    for a in ASSETS:
        print(f"asset        : {a}  md5={digests[a]}"
              + ("" if digests[a] == ASSET_MD5_PIN[a] else "   <-- DRIFTED FROM PIN"))

    # ---------------- inputs ----------------
    bor_man = read_table(BOR_MANIFEST, "nid_manifest.csv")
    nid_man = read_table(REPO_ROOT / "config" / "nid_manifest.csv", "nid_manifest.csv")
    ledger = pd.read_csv(io.StringIO(git_text(fleet_commit, "data/nid_progress/completed_ids.csv")),
                         dtype=str, keep_default_na=False, na_values=[])
    ledger["ok"] = ledger["ok"].map({"TRUE": True, "FALSE": False})
    ledger["nid_rank"] = np.arange(1, len(ledger) + 1)

    nid_diag = numify(read_gz(args.assets_dir, "batch_diagnostics.csv.gz"),
                      ["n_stations", "H1", "depth_10k_mm", "tail_spread_pct"])
    nid_ddf = numify(read_gz(args.assets_dir, "all_facilities_DDF.csv.gz"),
                     ["return_period_yr", "depth_mm"])
    bor_pre_diag = read_table(BOR_PRE_DIAG, "batch_diagnostics.csv")
    bor_pre_ddf = read_table(BOR_PRE_DDF, "all_facilities_DDF.csv")
    bor_post = numify(read_table(BOR_POST_BAND, "bor308_band.csv"),
                      ["return_period_yr", "depth_circular_mm"])

    # ---------------- 1. crosswalk ----------------
    print("\n--- 1. facility crosswalk (ID-keyed) ---")
    xw = bor_man.merge(ledger[["facility_id", "name", "ok", "nid_rank"]]
                       .rename(columns={"name": "name_nid", "ok": "nid_ok"}),
                       on="facility_id", how="left")
    matched = xw[xw["nid_ok"].notna()].copy()
    print(f"BOR-308 manifest facilities            : {len(bor_man)}")
    print(f"  matched on NID facility_id           : {len(matched)} "
          f"({len(matched)/len(bor_man):.1%})")
    print(f"  matched AND ok in the NID run        : {int(matched['nid_ok'].sum())}")
    print(f"  not yet reached by the NID fleet     : {len(xw) - len(matched)} "
          f"(all small-storage; fleet runs largest-first)")
    print(f"  fuzzy / name-coordinate fallbacks    : 0 (not needed)")
    nm = matched[matched["name"] != matched["name_nid"]]
    print(f"  ID matches whose NAME differs        : {len(nm)} "
          f"-> {sorted(nm['facility_id'])}")
    j = matched.merge(nid_man[["facility_id", "latitude", "longitude"]],
                      on="facility_id", suffixes=("", "_nidman"))
    j["coord_shift_km"] = haversine_km(j["latitude"], j["longitude"],
                                       j["latitude_nidman"], j["longitude_nidman"])
    shifted = j[j["coord_shift_km"] > 1e-6]
    print(f"  ID matches whose COORDINATES differ  : {len(shifted)} "
          f"(max {shifted['coord_shift_km'].max():.2f} km) -> manifest vintage drift")
    # name ambiguity that a name-keyed join WOULD have hit
    ledger_name_ct = ledger["name"].value_counts()
    amb = matched["name_nid"].map(ledger_name_ct).fillna(0) > 1
    print(f"  would have been AMBIGUOUS on a name join: {int(amb.sum())} "
          f"({amb.mean():.1%}) -- ID keying avoids all of them")

    ok_ids = set(matched.loc[matched["nid_ok"] == True, "facility_id"])  # noqa: E712
    bor_failed = ok_ids - set(bor_pre_diag["site_id"])
    print(f"  matched but FAILED in the BOR-308 run  : {len(bor_failed)} "
          f"{sorted(bor_failed)} -> no BOR depths to compare against")
    print(f"  comparable facilities                  : {len(ok_ids - bor_failed)}")

    # ---------------- 2. depth extraction ----------------
    print("\n--- 2. depth extraction ---")
    nd = nid_diag[nid_diag["site_id"].isin(ok_ids)]
    nid_res, nid_fail = resolve_ddf_blocks(nid_ddf[nid_ddf["site"].isin(set(nd["site"]))], nd)
    print(f"NID    : {nd['site_id'].nunique()} facilities with site_id-keyed diagnostics "
          f"(T=10,000 yr layer)")
    print(f"         {nid_res['facility_id'].nunique()} with a VERIFIED full-T DDF block; "
          f"{len(nid_fail)} unresolved {dict(nid_fail['reason'].value_counts()) if len(nid_fail) else {}}")
    pre_res, pre_fail = resolve_ddf_blocks(bor_pre_ddf, bor_pre_diag)
    print(f"BOR-pre: {bor_pre_diag['site_id'].nunique()} facilities with diagnostics; "
          f"{pre_res['facility_id'].nunique()} with a VERIFIED full-T DDF block; "
          f"{len(pre_fail)} unresolved")
    print(f"BOR-post (elevation-enriched circular baseline): "
          f"{bor_post['site_id'].nunique()} facilities")

    nid_long = (nid_res[["facility_id", "duration", "return_period_yr", "depth_mm"]]
                .rename(columns={"depth_mm": "depth_nid"}))
    pre_long = (pre_res[["facility_id", "duration", "return_period_yr", "depth_mm"]]
                .rename(columns={"depth_mm": "depth_bor_pre"}))
    post_long = (bor_post[["site_id", "duration", "return_period_yr", "depth_circular_mm"]]
                 .rename(columns={"site_id": "facility_id",
                                  "depth_circular_mm": "depth_bor_post"}))
    long = (nid_long.merge(pre_long, on=["facility_id", "duration", "return_period_yr"])
                    .merge(post_long, on=["facility_id", "duration", "return_period_yr"],
                           how="left"))
    long = long[long["facility_id"].isin(ok_ids)]
    print(f"full-T comparison set: {long['facility_id'].nunique()} facilities x "
          f"{len(DURATIONS)} durations x {len(EXPECTED_T)} return periods = {len(long)} pairs")

    # ---------------- 3. cohorts + band binding ----------------
    narrow_ids = set(ledger_at(KEY_COMMITS["manifest_refresh"]).query("ok")["facility_id"])
    long["cohort"] = np.where(long["facility_id"].isin(narrow_ids), "narrow_band", "wide_band")

    st_elev = ghcn_station_elevations()
    cand = pd.concat([
        read_gz(args.assets_dir, "stations_used.csv.gz",
                usecols=["site_id", "duration", "station_id"]),
        read_gz(args.assets_dir, "stations_removed.csv.gz",
                usecols=["site_id", "duration", "station_id"]),
    ])
    cand = cand[cand["site_id"].isin(ok_ids)].merge(st_elev, on="station_id", how="left")
    band_bound = (cand.assign(out=(cand["elev_m"] < NARROW_BAND_M[0])
                              | (cand["elev_m"] > NARROW_BAND_M[1]))
                      .groupby("site_id")["out"].any().rename("band_bound"))
    long = long.merge(band_bound, left_on="facility_id", right_index=True, how="left")

    # ---------------- 4. distributions ----------------
    def dist_block(df, ref, tag):
        d = df.dropna(subset=[ref]).copy()
        d["rd"] = 100.0 * (d["depth_nid"] - d[ref]) / d[ref]
        print(f"\n  {tag}")
        print("    cohort        T      dur   n    median      |median|   IQR                "
              "p90|.|   max|.|    <1%    <5%")
        for coh in ["ALL", "narrow_band", "wide_band"]:
            s = d if coh == "ALL" else d[d["cohort"] == coh]
            for t in HEADLINE_T:
                for dur in DURATIONS:
                    x = s.loc[(s["return_period_yr"] == t) & (s["duration"] == dur), "rd"]
                    if not len(x):
                        continue
                    print(f"    {coh:<12s} {t:<6d} {dur}  {len(x):<4d} "
                          f"{x.median():+8.2f}%  {x.abs().median():7.2f}%  "
                          f"[{x.quantile(.25):+7.2f},{x.quantile(.75):+7.2f}]  "
                          f"{x.abs().quantile(.9):7.2f}% {x.abs().max():8.2f}%  "
                          f"{(x.abs() < 1).mean():.3f}  {(x.abs() < 5).mean():.3f}")

    print("\n--- 3. depth-difference distributions (NID relative to BOR) ---")
    dist_block(long, "depth_bor_pre",
               "NID vs BOR-PRE  (elevation NA in BOTH -> same index-flood path)")
    dist_block(long, "depth_bor_post",
               "NID vs BOR-POST (BOR elevation-enriched -> different index-flood path)")

    # ---------------- 5. scale vs shape decomposition ----------------
    print("\n--- 4. scale (index flood) vs shape (region/growth curve) decomposition ---")
    print("    depth(T) = index_flood x growth(T): an index-flood-only difference is a")
    print("    CONSTANT ratio across T; a region/growth-curve difference is not.")
    print("    comparison                                   n   |ln scale| p50/p90   "
          "shape spread across T p50/p90/max   frac shape<1%")

    def decomp(df, ref, tag):
        d = df.dropna(subset=[ref]).copy()
        d["r"] = d["depth_nid"] / d[ref]
        g = d.groupby(["facility_id", "duration"])["r"].agg(scale="median", lo="min", hi="max")
        g["shape_pct"] = 100.0 * (g["hi"] - g["lo"]) / g["scale"]
        ls = np.abs(np.log(g["scale"]))
        print(f"    {tag:<42s} {len(g):<4d} {ls.median():.4f}/{ls.quantile(.9):.4f}        "
              f"{g['shape_pct'].median():7.3f}/{g['shape_pct'].quantile(.9):7.3f}/"
              f"{g['shape_pct'].max():7.3f}%   {(g['shape_pct'] < 1).mean():.3f}")
        return g

    dec = {}
    dec[("narrow_band", "pre")] = decomp(long[long.cohort == "narrow_band"], "depth_bor_pre",
                                         "narrow cohort vs BOR-pre (all matched)")
    dec[("narrow_band", "post")] = decomp(long[long.cohort == "narrow_band"], "depth_bor_post",
                                          "narrow cohort vs BOR-post (elevation only)")
    dec[("wide_band", "pre")] = decomp(long[long.cohort == "wide_band"], "depth_bor_pre",
                                       "wide cohort vs BOR-pre (elev band only)")
    dec[("wide_band", "post")] = decomp(long[long.cohort == "wide_band"], "depth_bor_post",
                                        "wide cohort vs BOR-post (band + elevation)")
    # the BOR-internal control: post/pre is elevation enrichment ALONE
    inter = pre_long.merge(post_long, on=["facility_id", "duration", "return_period_yr"])
    inter["r"] = inter["depth_bor_post"] / inter["depth_bor_pre"]
    gi = inter.groupby(["facility_id", "duration"])["r"].agg(scale="median", lo="min", hi="max")
    gi["shape_pct"] = 100.0 * (gi["hi"] - gi["lo"]) / gi["scale"]
    lsi = np.abs(np.log(gi["scale"]))
    print(f"    {'BOR-post vs BOR-pre (BOR-internal control)':<42s} {len(gi):<4d} "
          f"{lsi.median():.4f}/{lsi.quantile(.9):.4f}        "
          f"{gi['shape_pct'].median():7.3f}/{gi['shape_pct'].quantile(.9):7.3f}/"
          f"{gi['shape_pct'].max():7.3f}%   {(gi['shape_pct'] < 1).mean():.3f}")

    # ---------------- 6. exact reproduction + causal 2x2 ----------------
    print("\n--- 5. exact reproduction and cause attribution ---")
    long["exact"] = (long["depth_nid"] - long["depth_bor_pre"]).abs() < 1e-9
    fac = long.groupby(["facility_id", "cohort"])["exact"].all().reset_index()
    fac = fac.merge(band_bound, left_on="facility_id", right_index=True, how="left")
    for coh in ["narrow_band", "wide_band"]:
        s = fac[fac["cohort"] == coh]
        print(f"  {coh:<12s}: {int(s['exact'].sum())}/{len(s)} facilities reproduce BOR-pre "
              f"BYTE-IDENTICALLY at all {len(CANON_BLOCK)} depths ({s['exact'].mean():.3f})")
    w = fac[fac["cohort"] == "wide_band"]
    print("\n  wide cohort 2x2 -- did the [600,2600] m band actually BIND on the candidate pool?")
    print(pd.crosstab(w["exact"], w["band_bound"], dropna=False).to_string())
    nb = w[w["band_bound"] == False]  # noqa: E712
    print(f"  band-INSENSITIVE wide-cohort controls: {len(nb)} facilities, "
          f"{int(nb['exact'].sum())} byte-identical ({nb['exact'].mean():.3f})")
    exc = sorted(nb.loc[~nb["exact"], "facility_id"])
    print(f"  residual (band-insensitive but NOT identical): {exc}")
    for f in exc:
        s = long[long["facility_id"] == f]
        rd = 100.0 * (s["depth_nid"] - s["depth_bor_pre"]) / s["depth_bor_pre"]
        nb_ = bor_pre_diag[bor_pre_diag["site_id"] == f][["duration", "n_stations"]]
        nn_ = nd[nd["site_id"] == f][["duration", "n_stations"]]
        print(f"    {f}: max|rel diff| {rd.abs().max():.2f}%  n_stations BOR "
              f"{nb_['n_stations'].tolist()} -> NID {nn_['n_stations'].tolist()}")
    nrw = fac[fac["cohort"] == "narrow_band"]
    print(f"  narrow-cohort non-identical: "
          f"{sorted(nrw.loc[~nrw['exact'], 'facility_id'])} "
          f"(cross-reference the coordinate-shift list above)")

    # ---------------- 7. per-facility report ----------------
    print("\n--- 6. writing per-facility report ---")
    rank = completion_rank_dates(fleet_commit)
    est = np.interp(ledger["nid_rank"], rank["n"], rank["ts"])
    ledger["est_completed_utc"] = pd.to_datetime(est.astype("int64"), utc=True)
    ledger.loc[ledger["nid_rank"] <= 1050, "est_completed_utc"] = pd.NaT

    wide = long.pivot_table(index=["facility_id", "duration"], columns="return_period_yr",
                            values=["depth_nid", "depth_bor_pre", "depth_bor_post"])
    wide.columns = [f"{a}_T{int(b)}" for a, b in wide.columns]
    keep = [c for c in wide.columns if c.endswith(("_T100", "_T10000"))]
    wide = wide[keep].reset_index()

    scale_shape = []
    for (coh_ref, tag) in [("depth_bor_pre", "pre"), ("depth_bor_post", "post")]:
        d = long.dropna(subset=[coh_ref]).copy()
        d["r"] = d["depth_nid"] / d[coh_ref]
        g = d.groupby(["facility_id", "duration"])["r"].agg(**{
            f"scale_ratio_{tag}": "median", f"_lo_{tag}": "min", f"_hi_{tag}": "max"})
        g[f"shape_spread_{tag}_pct"] = (100.0 * (g[f"_hi_{tag}"] - g[f"_lo_{tag}"])
                                        / g[f"scale_ratio_{tag}"])
        scale_shape.append(g[[f"scale_ratio_{tag}", f"shape_spread_{tag}_pct"]])
    ss = scale_shape[0].join(scale_shape[1], how="outer").reset_index()

    exact_fac = long.groupby(["facility_id", "duration"])["exact"].all().rename(
        "exact_all_T_vs_bor_pre").reset_index()

    # the 10,000-yr layer covers EVERY matched facility (site_id-keyed diagnostics
    # on both sides), including those whose full-T DDF block could not be verified.
    base = (matched[["facility_id", "name", "name_nid", "state", "latitude", "longitude",
                     "elevation_m", "nid_storage_acreft", "nid_rank"]]
            .rename(columns={"name": "name_bor", "elevation_m": "elevation_m_bor"}))
    base = base.merge(j[["facility_id", "coord_shift_km"]], on="facility_id", how="left")
    base = base.merge(ledger[["facility_id", "est_completed_utc"]], on="facility_id", how="left")
    base["cohort"] = np.where(base["facility_id"].isin(narrow_ids), "narrow_band", "wide_band")
    base = base.merge(band_bound, left_on="facility_id", right_index=True, how="left")
    base["match_key"] = "nid_facility_id"

    rep = (nd[["site_id", "duration", "n_stations", "H1", "chosen_dist", "depth_10k_mm"]]
           .rename(columns={"site_id": "facility_id", "n_stations": "n_stations_nid",
                            "H1": "H1_nid", "chosen_dist": "chosen_dist_nid",
                            "depth_10k_mm": "depth_10k_nid_diag"}))
    repb = (bor_pre_diag[["site_id", "duration", "n_stations", "H1", "chosen_dist", "depth_10k_mm"]]
            .rename(columns={"site_id": "facility_id", "n_stations": "n_stations_bor_pre",
                             "H1": "H1_bor_pre", "chosen_dist": "chosen_dist_bor_pre",
                             "depth_10k_mm": "depth_10k_bor_pre_diag"}))
    out = (rep.merge(repb, on=["facility_id", "duration"], how="inner")
              .merge(base, on="facility_id", how="left")
              .merge(wide, on=["facility_id", "duration"], how="left")
              .merge(ss, on=["facility_id", "duration"], how="left")
              .merge(exact_fac, on=["facility_id", "duration"], how="left"))
    out["fullT_resolved"] = out["depth_nid_T100"].notna()
    for t in HEADLINE_T:
        for ref in ["pre", "post"]:
            a, b = f"depth_nid_T{t}", f"depth_bor_{ref}_T{t}"
            out[f"reldiff_T{t}_vs_{ref}_pct"] = 100.0 * (out[a] - out[b]) / out[b]
    out["reldiff_T10000_diag_vs_pre_pct"] = (
        100.0 * (out["depth_10k_nid_diag"] - out["depth_10k_bor_pre_diag"])
        / out["depth_10k_bor_pre_diag"])
    cols = ["facility_id", "name_bor", "name_nid", "state", "latitude", "longitude",
            "elevation_m_bor", "nid_storage_acreft", "duration", "match_key",
            "coord_shift_km", "cohort", "band_bound", "nid_rank", "est_completed_utc",
            "fullT_resolved", "n_stations_bor_pre", "n_stations_nid",
            "H1_bor_pre", "H1_nid", "chosen_dist_bor_pre", "chosen_dist_nid",
            "depth_nid_T100", "depth_bor_pre_T100", "depth_bor_post_T100",
            "depth_nid_T10000", "depth_bor_pre_T10000", "depth_bor_post_T10000",
            "depth_10k_nid_diag", "depth_10k_bor_pre_diag",
            "reldiff_T100_vs_pre_pct", "reldiff_T10000_vs_pre_pct",
            "reldiff_T100_vs_post_pct", "reldiff_T10000_vs_post_pct",
            "reldiff_T10000_diag_vs_pre_pct",
            "scale_ratio_pre", "shape_spread_pre_pct",
            "scale_ratio_post", "shape_spread_post_pct", "exact_all_T_vs_bor_pre"]
    out = out[cols].sort_values(["facility_id", "duration"])
    for c in out.select_dtypes("float").columns:
        out[c] = out[c].round(4)
    args.out_csv.parent.mkdir(parents=True, exist_ok=True)
    out.to_csv(args.out_csv, index=False)
    print(f"  wrote {args.out_csv.relative_to(REPO_ROOT)}  "
          f"({len(out)} rows = {out['facility_id'].nunique()} facilities x duration)")

    # the site_id-keyed T=10,000 layer covers all matched facilities
    x = out["reldiff_T10000_diag_vs_pre_pct"].dropna()
    print(f"\n  T=10,000 yr layer on ALL {out['facility_id'].nunique()} matched facilities "
          f"(site_id-keyed diagnostics, no name join anywhere):")
    for coh in ["narrow_band", "wide_band"]:
        s = out.loc[out["cohort"] == coh, "reldiff_T10000_diag_vs_pre_pct"].dropna()
        print(f"    {coh:<12s} n={len(s):<4d} |median|={s.abs().median():6.2f}%  "
              f"frac|.|<0.05%={(s.abs() < 0.05).mean():.3f}  "
              f"frac|.|<1%={(s.abs() < 1).mean():.3f}  max|.|={s.abs().max():.2f}%")
    print(f"    {'ALL':<12s} n={len(x):<4d} |median|={x.abs().median():6.2f}%  "
          f"frac|.|<0.05%={(x.abs() < 0.05).mean():.3f}")

    if not args.no_figures:
        make_figures(long, fac, gi, out, args.fig_dir)
    print("\ndone.")
    return 0


# --------------------------------------------------------------------------
# Figures (repo house style: Okabe-Ito categorical, light surface)
# --------------------------------------------------------------------------
def make_figures(long: pd.DataFrame, fac: pd.DataFrame, gi: pd.DataFrame,
                 out: pd.DataFrame, fig_dir: Path) -> None:
    plt = style_matplotlib()
    fig_dir.mkdir(parents=True, exist_ok=True)

    # ---- figure 1: ECDF of |relative difference| by cohort, at both headline T
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.6), sharey=True)
    for ax, t in zip(axes, HEADLINE_T):
        for i, (coh, lab) in enumerate([
                ("narrow_band", "matched elevation band (NID pre-fix cohort)"),
                ("wide_band", "widened elevation band (NID post-fix cohort)")]):
            s = long[(long["cohort"] == coh) & (long["return_period_yr"] == t)
                     & (long["duration"] == "24h")]
            v = np.sort((100.0 * (s["depth_nid"] - s["depth_bor_pre"])
                         / s["depth_bor_pre"]).abs().values)
            if not len(v):
                continue
            zero = int((v < 1e-9).sum())
            ax.step(np.maximum(v, 1e-3), np.arange(1, len(v) + 1) / len(v),
                    where="post", lw=2, color=OKABE_ITO[i],
                    label=f"{lab}\n  n={len(v)}, exact agreement for {zero} ({zero/len(v):.0%})")
        ax.set_xscale("log")
        ax.set_xlim(1e-3, 400)
        ax.set_xlabel("|NID - BOR| / BOR  (%, log scale)")
        ax.set_title(f"T = {t:,} yr, 24 h", fontsize=11)
        ax.axvline(1, color="#9ca3af", ls=":", lw=1)
        ax.annotate("exact\nagreement", xy=(1.2e-3, 0.03), fontsize=7.5, color="#6b7280",
                    ha="left", va="bottom")
    axes[0].set_ylabel("fraction of facilities at or below")
    axes[0].legend(loc="upper left", bbox_to_anchor=(0.02, 0.93), fontsize=7.5, frameon=False)
    fig.text(0.5, -0.06, "Facilities that agree exactly (relative difference 0.000%) are drawn "
             "at the left axis limit, which a log scale cannot otherwise show.",
             ha="center", fontsize=8, color="#6b7280")
    fig.suptitle("NID fleet vs BOR-308: depth agreement splits cleanly on the elevation-band cohort",
                 fontsize=12, y=1.02)
    fig.savefig(fig_dir / "bor_nid_reldiff_ecdf.png")
    plt.close(fig)

    # ---- figure 2: scale vs shape decomposition
    fig, ax = plt.subplots(figsize=(8.0, 6.4))
    series = [
        (long[long.cohort == "narrow_band"], "depth_bor_pre", OKABE_ITO[0],
         "NID narrow cohort vs BOR-pre\n(every known input matched)"),
        (long[long.cohort == "narrow_band"], "depth_bor_post", OKABE_ITO[1],
         "NID narrow cohort vs BOR-post\n(elevation enrichment only)"),
        (long[long.cohort == "wide_band"], "depth_bor_pre", OKABE_ITO[5],
         "NID wide cohort vs BOR-pre\n(elevation band differs)"),
    ]
    FLOOR = 5e-3
    for df, ref, col, lab in series:
        d = df.dropna(subset=[ref]).copy()
        d["r"] = d["depth_nid"] / d[ref]
        g = d.groupby(["facility_id", "duration"])["r"].agg(s="median", lo="min", hi="max")
        g["shape"] = 100.0 * (g["hi"] - g["lo"]) / g["s"]
        pinned = int(((100 * np.abs(np.log(g["s"])) < FLOOR) & (g["shape"] < FLOOR)).sum())
        note = f"\n  {pinned} of {len(g)} identical (pinned at the axis corner)" if pinned else ""
        ax.scatter(np.maximum(100 * np.abs(np.log(g["s"])), FLOOR),
                   np.maximum(g["shape"], FLOOR), s=18, alpha=0.6,
                   color=col, linewidths=0, label=f"{lab}  (n={len(g)}){note}")
    ax.scatter(np.maximum(100 * np.abs(np.log(gi["scale"])), FLOOR),
               np.maximum(gi["shape_pct"], FLOOR), s=18, alpha=0.6,
               color=OKABE_ITO[2], linewidths=0, marker="^",
               label=f"BOR-post vs BOR-pre, internal control\n(elevation enrichment only)  (n={len(gi)})")
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("SCALE component: |ln(depth ratio)| x 100  (index-flood difference)")
    ax.set_ylabel("SHAPE component: spread of the depth ratio across T (%)\n(region / growth-curve difference)")
    ax.axhline(1, color="#9ca3af", ls=":", lw=1)
    ax.annotate("above this line the two runs disagree about the SHAPE\n"
                "of the frequency curve, not just its magnitude",
                xy=(6e-3, 0.18), fontsize=7.5, color="#6b7280", va="bottom")
    ax.set_title("Elevation changes only the scale; the station pool changes the shape too",
                 fontsize=11)
    ax.legend(fontsize=7.5, frameon=False, loc="upper center",
              bbox_to_anchor=(0.5, -0.16), ncol=2, handletextpad=0.4,
              columnspacing=1.4, labelspacing=0.9)
    fig.savefig(fig_dir / "bor_nid_scale_shape.png")
    plt.close(fig)
    print(f"  wrote {(fig_dir / 'bor_nid_reldiff_ecdf.png').relative_to(REPO_ROOT)}")
    print(f"  wrote {(fig_dir / 'bor_nid_scale_shape.png').relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    raise SystemExit(main())
