"""Phase B1 -- NOAA Atlas 14 comparison sampler (docs/NID_ANALYSIS_PLAN.md B1).

Fleet-scale infrastructure for the flagship EXTERNAL validation: compare this
project's uniform L-moments precipitation-frequency estimates against NOAA's
official Atlas 14 point estimates across thousands of NID dams, and ground-truth
the scraper before anyone trusts a number that came out of it (QAQC plan D3).

WHY PYTHON AND NOT R
--------------------
`compare_atlas14.R` stays exactly what it is: the single-facility operator tool
that the expert-review checklist points at. This is a different artifact --
fleet-scale sampling infrastructure -- and it belongs with the other Phase-A/B
analyses, which are all Python (`analysis/a1..a3`, `qc/nid_qc_*.py`) and share
`qc/nid_qc_common.py` for manifest loading, the pinned-input discipline and the
figure style. It also has to read the fleet's cumulative tables, which since
fleet commit 934e89ba are gzipped **GitHub release assets** (tag
`nid-run1-data`), not files in the tree -- pandas reads those directly.
Nothing here edits, imports or duplicates the R tool; the CSV parser below was
written independently and is cross-checked against a second NOAA endpoint
(see `verify`), which is a stronger test than sharing one parser would be.

ENDPOINT CONTRACT (verified live 2026-08-20; see docs/analysis/atlas14_pilot.md)
-------------------------------------------------------------------------------
  scripted path   GET https://hdsc.nws.noaa.gov/cgi-bin/new/fe_text_mean.csv
                      ?lat=&lon=&data=depth&units=english&series={pds|ams}
  web-UI backend  GET https://hdsc.nws.noaa.gov/cgi-bin/new/cgi_readH5.py
                      ?lat=&lon=&type=pf&data=depth&units=english&series=...
  NOTE the path moved: `/cgi-bin/hdsc/new/` (still used by compare_atlas14.R and
  by NOAA's own commented-out JS) now 301-redirects to `/cgi-bin/new/`. Both
  work; this tool requests the current path directly.
  No-coverage is served as **HTTP 200** with a body of
  `result = 'none'; ErrorMsg = 'Error 3.0: Selected location is not within a
  project area';` -- it is NOT a 404, and it must never be conflated with a
  network failure.

USAGE
-----
  python analysis/b1_atlas14_sampler.py selftest             # offline, no network
  python analysis/b1_atlas14_sampler.py coverage             # probe coverage/volumes
  python analysis/b1_atlas14_sampler.py frame --pilot        # build the ~40-site frame
  python analysis/b1_atlas14_sampler.py fetch --max 120      # polite resumable fetch
  python analysis/b1_atlas14_sampler.py verify --n 20        # QAQC D3 ground-truthing
  python analysis/b1_atlas14_sampler.py compare              # pilot difference stats

Raw responses, ledgers and fleet extracts live under `data/atlas14/` (gitignored
except `data/atlas14/summary/`, which carries the committed summary tables).
"""

from __future__ import annotations

import argparse
import ast
import gzip
import hashlib
import io
import json
import random
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "qc"))
import nid_qc_common as C  # noqa: E402

# --------------------------------------------------------------------------- paths
DATA = C.REPO_ROOT / "data" / "atlas14"
CACHE = DATA / "cache"
FLEET_CACHE = DATA / "fleet_cache"
SUMMARY = DATA / "summary"
LEDGER = DATA / "ledger.csv"
VERIFY_LEDGER = DATA / "verify_ledger.csv"
DOCS = C.REPO_ROOT / "docs" / "analysis"
FIGS = DOCS / "figures"

FLEET_RELEASE_TAG = "nid-run1-data"
FLEET_REPO = "crawforj/L-moments-hub"

# --------------------------------------------------------------------------- endpoints
PFDS_CGI = "https://hdsc.nws.noaa.gov/cgi-bin/new/"
CSV_URL = PFDS_CGI + "fe_text_mean.csv"      # scripted path (primary)
H5_URL = PFDS_CGI + "cgi_readH5.py"          # web-UI backend (verification path)
GRID_BASE = "https://hdsc.nws.noaa.gov/pub/hdsc/data/"
USER_AGENT = (
    "L-moments-hub/B1-atlas14-sampler (research comparison of regional L-moments "
    "PF estimates vs NOAA Atlas 14; https://github.com/crawforj/L-moments-hub)"
)
IN2MM = 25.4
NO_COVERAGE_MARK = "not within a project area"

# Rate-limiting / robustness defaults. The eventual full sample is thousands of
# queries against a single NOAA host; these are deliberately conservative.
DEFAULT_SLEEP_S = 2.0
DEFAULT_JITTER_S = 0.6
DEFAULT_MAX_PER_RUN = 250
RETRY_BACKOFF_S = (5, 20, 60)
TIMEOUT_S = 60

# --------------------------------------------------------------------------- coverage
# NOAA's OWN state -> project-region / volume table, lifted verbatim from the
# PFDS web client (https://hdsc.nws.noaa.gov/pfds/code/general_16.js, `var
# states`), retrieved 2026-08-20. Values are (region_code, volume_from_js).
# CAUTION: the JS `Vol` field is the documentation-PDF volume and disagrees with
# the server for Colorado (JS says 1, the server reports Volume 8 / Midwestern
# States). The authoritative volume for any point is the one the *server* prints
# in the response header, which is what the ledger records; this table is used
# only for (a) the coverage map and (b) sampling strata before any fetch.
NOAA_STATE_REGION = {
    "AK": ("ak", 7), "AL": ("se", 9), "AR": ("se", 9), "AZ": ("sw", 1),
    "CA": ("sw", 6), "CO": ("mw", 8), "CT": ("ne", 10), "DC": ("orb", 2),
    "DE": ("orb", 2), "FL": ("se", 9), "GA": ("se", 9), "HI": ("hi", 4),
    "IA": ("mw", 8), "ID": ("inw", 12), "IL": ("orb", 2), "IN": ("orb", 2),
    "KS": ("mw", 8), "KY": ("orb", 2), "LA": ("se", 9), "MA": ("ne", 10),
    "MD": ("orb", 2), "ME": ("ne", 10), "MI": ("mw", 8), "MN": ("mw", 8),
    "MO": ("mw", 8), "MS": ("se", 9), "MT": ("inw", 12), "NC": ("orb", 2),
    "ND": ("mw", 8), "NE": ("mw", 8), "NH": ("ne", 10), "NJ": ("orb", 2),
    "NM": ("sw", 1), "NV": ("sw", 1), "NY": ("ne", 10), "OH": ("orb", 2),
    "OK": ("mw", 8), "PA": ("orb", 2), "PR": ("pr", 3), "RI": ("ne", 10),
    "SC": ("orb", 2), "SD": ("mw", 8), "TN": ("orb", 2), "TX": ("tx", 11),
    "UT": ("sw", 1), "VA": ("orb", 2), "VI": ("pr", 3), "VT": ("ne", 10),
    "WI": ("mw", 8), "WV": ("orb", 2), "WY": ("inw", 12),
}
# The two states NOAA's own table omits: no NOAA Atlas 14 anywhere in them.
# The current official product there is NOAA Atlas 2 (1973); NOAA still serves
# those grids at /pub/hdsc/data/{oregon,washington}/na2_{or,wa}_*.zip.
ATLAS2_STATES = {"OR", "WA"}
ATLAS2_LABEL = "NONE (NOAA Atlas 2, 1973)"

VOLUME_NAME = {
    1: "Vol 1 Semiarid Southwest", 2: "Vol 2 Ohio River Basin",
    3: "Vol 3 Puerto Rico / USVI", 4: "Vol 4 Hawaiian Islands",
    5: "Vol 5 Selected Pacific Islands", 6: "Vol 6 California",
    7: "Vol 7 Alaska", 8: "Vol 8 Midwestern States",
    9: "Vol 9 Southeastern States", 10: "Vol 10 Northeastern States",
    11: "Vol 11 Texas", 12: "Vol 12 Interior Northwest",
}

# NOAA/NCEI nine CONUS climate regions (+ non-contiguous), by state.
CLIMATE_REGION = {}
for _reg, _sts in {
    "Northeast": "CT DE ME MD MA NH NJ NY PA RI VT DC",
    "Upper Midwest": "IA MI MN WI",
    "Ohio Valley": "IL IN KY MO OH TN WV",
    "Southeast": "AL FL GA NC SC VA",
    "Northern Rockies & Plains": "MT NE ND SD WY",
    "South": "AR KS LA MS OK TX",
    "Southwest": "AZ CO NM UT",
    "Northwest": "ID OR WA",
    "West": "CA NV",
    "Alaska": "AK", "Hawaii": "HI", "Caribbean": "PR VI",
}.items():
    for _s in _sts.split():
        CLIMATE_REGION[_s] = _reg

ELEV_BANDS = [(-1e9, 300.0, "lowland <300 m"), (300.0, 900.0, "300-900 m"),
              (900.0, 1800.0, "900-1800 m"), (1800.0, 1e9, "montane >=1800 m")]

# Durations the readH5 response returns, in row order, for the CONUS volumes.
# readH5 returns an UNLABELLED matrix, so this order is an assumption -- and it
# is exactly the assumption the `verify` command tests against the labelled CSV.
READH5_DURATIONS_CONUS = [
    "5-min", "10-min", "15-min", "30-min", "60-min", "2-hr", "3-hr", "6-hr",
    "12-hr", "24-hr", "2-day", "3-day", "4-day", "7-day", "10-day", "20-day",
    "30-day", "45-day", "60-day",
]

# Categorical colours. Okabe-Ito minus black and minus the low-contrast yellow,
# extended with two further hues so all eight CONUS volumes are distinguishable;
# BLACK IS RESERVED for the no-Atlas-14 stratum on every B1 figure.
CAT_COLORS = ["#0072B2", "#E69F00", "#009E73", "#CC79A7", "#56B4E9", "#D55E00",
              "#6A3D9A", "#8C6D31"]
VOL_COLORS = {
    "Vol 1 Semiarid Southwest": "#0072B2", "Vol 2 Ohio River Basin": "#56B4E9",
    "Vol 6 California": "#D55E00", "Vol 8 Midwestern States": "#E69F00",
    "Vol 9 Southeastern States": "#009E73", "Vol 10 Northeastern States": "#CC79A7",
    "Vol 11 Texas": "#6A3D9A", "Vol 12 Interior Northwest": "#8C6D31",
}

TARGET_T = [100, 1000]      # headline comparison return periods
TARGET_DUR = ["24h", "72h"]  # fleet durations


# ============================================================ duration handling
def dur_key(label: str) -> str | None:
    """Atlas 14 duration label -> the fleet's duration key ('24h'/'72h').

    Order matters: several volumes publish BOTH '24-hr' and '1-day'. Atlas 14's
    n-day depths are true n x 24 h maxima and its '24-hr' is the same quantity,
    but where a volume publishes both we take the hour-labelled one, which is
    what the PFDS UI headlines. '2-day'/'48-hr' is deliberately NOT mapped: the
    fleet has no 48 h duration.
    """
    s = str(label).strip().lower().rstrip(":")
    if re.fullmatch(r"24[\s-]?hr|24[\s-]?hour|1[\s-]?day", s):
        return "24h"
    if re.fullmatch(r"72[\s-]?hr|72[\s-]?hour|3[\s-]?day", s):
        return "72h"
    return None


def _dur_rank(label: str) -> int:
    """Prefer an hour-labelled duration over the day-labelled synonym."""
    return 0 if re.search(r"hr|hour", str(label).lower()) else 1


# ==================================================================== parsers
class PFDSNoCoverage(Exception):
    """The point is outside every Atlas 14 project area (an HTTP-200 answer)."""


class PFDSParseError(Exception):
    pass


_HDR_KEYS = {
    "data type": "data_type", "time series type": "series_type",
    "project area": "project_area", "latitude": "resp_lat",
    "longitude": "resp_lon", "station name": "station_name",
    "location name (esri maps)": "location_name", "elevation (usgs)": "resp_elev",
}


def parse_pfds_csv(txt: str) -> dict:
    """Parse an `fe_text_mean.csv` response into metadata + a tidy depth table.

    Handles BOTH header dialects the server emits:
      PDS  `by duration for ARI (years):, 1,2,5,...,1000`
      AMS  `by duration for AEP:, '1/2,'1/5,...,'1/1000`   (no 1-yr; note the
           leading apostrophe -- a naive strip-non-digits turns "'1/2" into 12).
    """
    if NO_COVERAGE_MARK in txt:
        raise PFDSNoCoverage(txt.strip().splitlines()[1][:160] if "\n" in txt else txt[:160])
    lines = [ln.rstrip() for ln in txt.replace("\r\n", "\n").split("\n")]
    meta: dict = {"units": None, "volume": None, "version": None}

    for ln in lines[:15]:
        s = ln.strip()
        if not s:
            continue
        m = re.match(r"Point precipitation frequency estimates \((.+?)\)", s)
        if m:
            meta["units"] = m.group(1)
            continue
        m = re.match(r"NOAA Atlas (\d+) Volume (\d+) Version (\d+)", s)
        if m:
            meta["atlas"], meta["volume"], meta["version"] = (
                int(m.group(1)), int(m.group(2)), int(m.group(3)))
            continue
        if ":" in s and not s.lower().startswith("by duration"):
            k, v = s.split(":", 1)
            key = _HDR_KEYS.get(k.strip().lower())
            if key:
                meta[key] = v.strip()

    hdr_i = next((i for i, ln in enumerate(lines)
                  if ln.strip().lower().startswith("by duration")), None)
    if hdr_i is None:
        raise PFDSParseError("no 'by duration for ...' header row")
    hdr = [c.strip() for c in lines[hdr_i].split(",")]
    meta["header_dialect"] = "AEP" if "aep" in hdr[0].lower() else "ARI"

    aris: list[float] = []
    for tok in hdr[1:]:
        tok = tok.strip().lstrip("'").strip()
        if not tok:
            continue
        m = re.fullmatch(r"1/(\d+(?:\.\d+)?)", tok)       # AMS: AEP as 1/T
        if m:
            aris.append(float(m.group(1)))
            continue
        m = re.fullmatch(r"(\d+(?:\.\d+)?)", tok)          # PDS: ARI in years
        if m:
            aris.append(float(m.group(1)))
            continue
        raise PFDSParseError(f"unparsable ARI/AEP token {tok!r}")
    if not aris:
        raise PFDSParseError("no ARI columns parsed")

    rows = []
    for ln in lines[hdr_i + 1:]:
        s = ln.strip()
        if not s or "," not in s:
            if rows and not s:
                continue
            continue
        cells = [c.strip() for c in s.split(",")]
        label = cells[0].rstrip(":").strip()
        if not re.fullmatch(r"\d+[\s-]?(min|hr|hour|day)s?", label.lower()):
            continue
        vals = cells[1:]
        if len(vals) != len(aris):
            raise PFDSParseError(
                f"row {label!r}: {len(vals)} values vs {len(aris)} ARI columns")
        for ari, v in zip(aris, vals):
            if v in ("", "-9", "NA"):
                continue
            rows.append({"duration": label, "ari_yr": ari, "value": float(v)})
    if not rows:
        raise PFDSParseError("no duration rows parsed")

    df = pd.DataFrame(rows)
    unit_txt = (meta.get("units") or "").lower()
    if "millimeter" in unit_txt:
        df["depth_mm"] = df["value"]
    elif "inch" in unit_txt and "hour" not in unit_txt:
        df["depth_mm"] = df["value"] * IN2MM
    else:
        raise PFDSParseError(f"unexpected/unsupported units {meta.get('units')!r}")
    return {"meta": meta, "table": df}


def parse_readh5(txt: str) -> dict:
    """Parse the web UI's own `cgi_readH5.py` payload (JS-ish assignments).

    Returns metadata plus the mean/upper/lower matrices as nested float lists.
    The matrices are UNLABELLED (row = duration in fixed order, column = ARI).
    """
    if "result = 'none'" in txt or NO_COVERAGE_MARK in txt:
        raise PFDSNoCoverage("readH5: not within a project area")
    out: dict = {}
    for name in ("quantiles", "upper", "lower"):
        m = re.search(rf"^\s*{name}\s*=\s*(\[.*?\]);", txt, re.S | re.M)
        if not m:
            if name == "quantiles":
                raise PFDSParseError("readH5: no `quantiles` matrix")
            continue
        lit = ast.literal_eval(m.group(1))
        out[name] = [[float(v) for v in row] for row in lit]
    for name in ("lat", "lon", "type", "ser", "datatype", "unit", "region",
                 "reg", "volume", "version", "file"):
        m = re.search(rf"^\s*{name}\s*=\s*'([^']*)';", txt, re.M)
        if m:
            out[name] = m.group(1)
    return out


# ================================================================ HTTP client
class PFDSClient:
    """Polite, cached, retrying HTTP client for the PFDS CGI endpoints."""

    def __init__(self, sleep_s: float = DEFAULT_SLEEP_S, jitter_s: float = DEFAULT_JITTER_S,
                 offline: bool = False):
        import requests  # imported lazily so `selftest` needs no requests

        self.sleep_s = sleep_s
        self.jitter_s = jitter_s
        self.offline = offline
        self._last = 0.0
        self.s = requests.Session()
        self.s.headers.update({"User-Agent": USER_AGENT})
        self.n_requests = 0

    def _throttle(self) -> None:
        wait = self.sleep_s + random.uniform(0, self.jitter_s) - (time.monotonic() - self._last)
        if wait > 0:
            time.sleep(wait)
        self._last = time.monotonic()

    def get(self, url: str, params: dict, cache_name: str) -> tuple[str, dict]:
        """Return (text, provenance). Cached responses cost no request."""
        CACHE.mkdir(parents=True, exist_ok=True)
        path = CACHE / cache_name
        if path.exists() and path.stat().st_size > 0:
            txt = path.read_text(encoding="utf-8", errors="replace")
            return txt, {"source": "cache", "http_status": "", "cache_file": path.name,
                         "sha256": hashlib.sha256(txt.encode()).hexdigest()[:16]}
        if self.offline:
            raise RuntimeError(f"offline and no cached response for {cache_name}")
        last_err = None
        for attempt in range(len(RETRY_BACKOFF_S) + 1):
            self._throttle()
            try:
                r = self.s.get(url, params=params, timeout=TIMEOUT_S)
                self.n_requests += 1
                if r.status_code == 200:
                    path.write_text(r.text, encoding="utf-8")
                    return r.text, {"source": "network", "http_status": 200,
                                    "cache_file": path.name,
                                    "sha256": hashlib.sha256(r.text.encode()).hexdigest()[:16]}
                if r.status_code in (400, 404):        # a real, non-retryable answer
                    return r.text, {"source": "network", "http_status": r.status_code,
                                    "cache_file": "", "sha256": ""}
                last_err = f"HTTP {r.status_code}"
            except Exception as e:                      # noqa: BLE001 - network is messy
                last_err = f"{type(e).__name__}: {e}"
            if attempt < len(RETRY_BACKOFF_S):
                back = RETRY_BACKOFF_S[attempt]
                print(f"    retry in {back}s ({last_err})", file=sys.stderr)
                time.sleep(back)
        raise RuntimeError(f"giving up after {len(RETRY_BACKOFF_S) + 1} attempts: {last_err}")

    def fetch_csv(self, fid: str, lat: float, lon: float, series: str) -> tuple[str, dict]:
        return self.get(CSV_URL,
                        {"lat": f"{lat:.4f}", "lon": f"{lon:.4f}", "data": "depth",
                         "units": "english", "series": series},
                        f"{fid}_{series}_mean.csv.txt")

    def fetch_h5(self, fid: str, lat: float, lon: float, series: str) -> tuple[str, dict]:
        return self.get(H5_URL,
                        {"lat": f"{lat:.4f}", "lon": f"{lon:.4f}", "type": "pf",
                         "data": "depth", "units": "english", "series": series},
                        f"{fid}_{series}_readH5.txt")


# =================================================================== ledgers
LEDGER_COLS = [
    "facility_id", "name", "state", "lat", "lon", "series", "status",
    "http_status", "atlas", "volume", "version", "project_area", "series_type",
    "data_type", "units", "n_rows", "depth24h_100yr_mm", "depth24h_1000yr_mm",
    "depth72h_100yr_mm", "cache_file", "sha256", "source", "fetched_utc", "note",
]
VERIFY_COLS = [
    "facility_id", "lat", "lon", "series", "method", "n_values_compared",
    "n_mismatch", "max_abs_reldiff_pct", "csv_24h_100yr_in", "ref_24h_100yr_in",
    "verdict", "detail", "checked_utc",
]


def _read_ledger(path: Path, cols: list[str]) -> pd.DataFrame:
    """Resumable-run ledger reader (mirrors run_nid_tranche.R / qc conventions)."""
    if path.exists() and path.stat().st_size > 0:
        df = pd.read_csv(path, dtype=str, keep_default_na=False, na_values=[])
        for c in cols:
            if c not in df.columns:
                df[c] = ""
        return df[cols]
    return pd.DataFrame(columns=cols)


def _append_ledger(path: Path, rows: list[dict], cols: list[str]) -> None:
    """Append-and-rewrite: the ledger is the single source of 'already done'."""
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    prev = _read_ledger(path, cols)
    new = pd.DataFrame(rows).reindex(columns=cols).astype(str)
    pd.concat([prev, new], ignore_index=True).to_csv(path, index=False)


# Statuses that represent a real ANSWER from the reference and are therefore
# genuinely done. Anything else (notably `fetch_error`, i.e. the server was
# briefly unavailable) must return to the worklist so it retries.
_TERMINAL_STATUSES = {"ok", "no_coverage"}


def _done_keys(path: Path, cols: list[str]) -> set[tuple[str, str]]:
    """Keys that need no further fetching.

    A transient failure is NOT an answer. Before 2026-08-27 this returned every
    ledger row regardless of status, so a burst of HTTP 503s became permanent
    holes: 101 pairs, ALL Virginia, were silently dropped from a stratified
    sample and would never have been retried. In a stratified design a hole
    with that geography biases the stratum -- it is not random attrition.
    Rows whose status is not terminal are now excluded here, so the next fetch
    round picks them up. Re-fetching an already-answered pair is cheap; losing
    one silently is not.
    """
    led = _read_ledger(path, cols)
    if led.empty:
        return set()
    key = "method" if "method" in cols and path == VERIFY_LEDGER else "series"
    if "status" in led.columns:
        led = led[led["status"].astype(str).str.strip().isin(_TERMINAL_STATUSES)]
        if led.empty:
            return set()
    return set(zip(led.facility_id, led[key]))


# ============================================================== fleet inputs
def _fleet_asset(asset: str) -> Path:
    """Download (once) an asset of the pinned fleet release tag.

    Since fleet commit 934e89ba the cumulative tables are release assets, not
    files in the tree, so `qc/nid_qc_common.materialize()` cannot reach them.
    """
    FLEET_CACHE.mkdir(parents=True, exist_ok=True)
    dest = FLEET_CACHE / asset
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    # The canonical asset carries the repaired table since 2026-08-27.
    print(f"  downloading {asset} from release {FLEET_RELEASE_TAG} ...", file=sys.stderr)
    subprocess.run(["gh", "release", "download", FLEET_RELEASE_TAG, "-R", FLEET_REPO,
                    "-p", asset, "-D", str(FLEET_CACHE), "--clobber"], check=True)
    return dest


def load_fleet_diag() -> pd.DataFrame:
    """Per-facility method diagnostics (station support, heterogeneity)."""
    p = _fleet_asset("batch_diagnostics.csv.gz")
    with gzip.open(p, "rb") as fh:
        df = pd.read_csv(io.BytesIO(fh.read()), dtype=str, keep_default_na=False,
                         na_values=[])
    for c in ("n_stations", "H1", "tail_spread_pct"):
        df[c] = pd.to_numeric(df[c].replace({"NA": None, "": None}), errors="coerce")
    df["site_id"] = df["site_id"].replace({"NA": ""})
    return df[df.duration == "24h"]


def load_fleet_ddf() -> pd.DataFrame:
    p = _fleet_asset("all_facilities_DDF.csv.gz")
    with gzip.open(p, "rb") as fh:
        df = pd.read_csv(io.BytesIO(fh.read()), dtype=str, keep_default_na=False, na_values=[])
    for c in ("return_period_yr", "depth_mm", "depth_lo_mm", "depth_hi_mm", "rel_rmse"):
        df[c] = pd.to_numeric(df[c].replace({"NA": None, "": None}), errors="coerce")
    df["site_id"] = df["site_id"].replace({"NA": ""})
    return df


def fleet_pin() -> dict:
    """Provenance of the fleet inputs (QAQC plan E1: pinned inputs)."""
    state = json.loads(_fleet_asset("nid_state.json").read_bytes())
    ddf = FLEET_CACHE / "all_facilities_DDF.csv.gz"
    if ddf.exists():
        state["ddf_sha256"] = hashlib.sha256(ddf.read_bytes()).hexdigest()[:16]
    state["release_tag"] = FLEET_RELEASE_TAG
    return state


# ============================================================== stratification
def _ghcn_elev_lookup(man: pd.DataFrame) -> pd.Series:
    """Elevation PROXY for stratification only: nearest GHCN-D station's elevation.

    `config/nid_manifest.csv` carries elevation_m = NA for all 73,303 rows and no
    branch has filled it, so the elevation stratum needs a source. GHCN-D's
    station inventory ships with the repo (`data/ghcn_inventory/`), needs no
    network, and is the very population the method draws its regions from.
    It is a PROXY -- used to assign a sampling band and nothing else. No
    comparison arithmetic anywhere in this script touches it.
    """
    path = C.REPO_ROOT / "data" / "ghcn_inventory" / "ghcnd-stations.txt.gz"
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as fh:
        recs = [(float(ln[12:20]), float(ln[21:30]), float(ln[31:37]))
                for ln in fh if ln[38:40].strip() == "" or True]
    st = np.array([r for r in recs if -90 <= r[0] <= 90 and -180 <= r[1] <= 180
                   and r[2] > -400])
    slat, slon, selev = st[:, 0], st[:, 1], st[:, 2]
    out = np.full(len(man), np.nan)
    lat = man.latitude.to_numpy(dtype=float)
    lon = man.longitude.to_numpy(dtype=float)
    # Chunked brute-force nearest neighbour on a local flat-earth approximation
    # (adequate: we only need an elevation band, not a distance).
    for i0 in range(0, len(man), 2000):
        i1 = min(i0 + 2000, len(man))
        dlat = lat[i0:i1, None] - slat[None, :]
        dlon = (lon[i0:i1, None] - slon[None, :]) * np.cos(np.radians(lat[i0:i1, None]))
        out[i0:i1] = selev[np.argmin(dlat ** 2 + dlon ** 2, axis=1)]
    return pd.Series(out, index=man.index)


def elev_band(e: float) -> str:
    if not np.isfinite(e):
        return "unknown"
    for lo, hi, lab in ELEV_BANDS:
        if lo <= e < hi:
            return lab
    return "unknown"


def coverage_label(state: str) -> str:
    if state in ATLAS2_STATES:
        return ATLAS2_LABEL
    rv = NOAA_STATE_REGION.get(state)
    return VOLUME_NAME.get(rv[1], f"Vol {rv[1]}") if rv else "unmapped"


def build_frame(n_target: int, pilot: bool, seed: int = 20260820,
                pilot_bor: int = 8) -> pd.DataFrame:
    """Stratified sample frame: (coverage/volume x climate region x elevation band),
    plus **every** BOR-overlap dam that the fleet has finished.

    Strata are allocated proportional to the square root of stratum size (a
    compromise between proportional allocation, which starves the small strata
    that the analysis most needs -- Atlas 2 PNW, Vol 12, Hawaii -- and equal
    allocation, which would over-weight them), with a floor of 3 per stratum.
    """
    rng = np.random.default_rng(seed)
    man = C.load_manifest()
    ddf = load_fleet_ddf()

    # ---- which facilities does the fleet actually have a usable 24h result for?
    d = ddf[(ddf.duration == "24h") & (ddf.return_period_yr == 100)]
    with_id = d[d.site_id != ""][["site_id", "site"]].drop_duplicates()
    have_ids = set(with_id.site_id)
    # Name-join fallback for the pre-`site_id` cohort, restricted to names that
    # are unique in BOTH the manifest and the DDF -- the fleet's known name
    # collisions are excluded rather than guessed at.
    dup_ddf = set(d.site[d.site.duplicated()])
    man_names = man.name.value_counts()
    uniq_names = set(man_names[man_names == 1].index)
    by_name = d[(d.site_id == "") & (~d.site.isin(dup_ddf)) & (d.site.isin(uniq_names))]
    name2id = man.set_index("name").facility_id
    have_by_name = {name2id[s]: s for s in by_name.site if s in name2id.index}

    frame = man[man.facility_id.isin(have_ids | set(have_by_name))].copy()
    frame["join_via"] = np.where(frame.facility_id.isin(have_ids), "site_id", "unique_name")
    frame = frame.dropna(subset=["latitude", "longitude"])
    frame = frame[frame.latitude.between(-90, 90) & frame.longitude.between(-180, 180)]

    frame["coverage"] = frame.state.map(coverage_label)
    frame["climate_region"] = frame.state.map(CLIMATE_REGION).fillna("other")
    frame["elev_proxy_m"] = _ghcn_elev_lookup(frame)
    frame["elev_band"] = frame.elev_proxy_m.map(elev_band)
    frame["stratum"] = (frame.coverage + " | " + frame.climate_region + " | " + frame.elev_band)

    bor = set(pd.read_csv(C.REPO_ROOT / "config" / "facilities_BOR.csv").facility_id)
    frame["is_bor"] = frame.facility_id.isin(bor)

    take = frame[frame.is_bor].copy()
    take["draw_reason"] = "BOR-overlap census"
    if pilot:
        # The ~300-dam BOR census belongs to the FULL run; a pilot that swallowed
        # it would not be a pilot. Keep a token BOR subsample so the join path
        # and the second-method overlap are both exercised.
        take = take.sample(min(pilot_bor, len(take)), random_state=seed).copy()
        take["draw_reason"] = "pilot: BOR-overlap subsample"
        n_target = max(0, n_target - len(take))

    pool = frame[~frame.is_bor]
    sizes = pool.groupby("stratum").size()
    if pilot:
        # Pilot: breadth over depth -- a handful from as many distinct COVERAGE
        # classes as possible, Atlas-2 PNW included, rather than a scaled-down
        # version of the full allocation.
        per_cov = max(1, round(n_target / max(1, pool.coverage.nunique())))
        picks = []
        for cov, grp in pool.groupby("coverage"):
            k = min(len(grp), per_cov)
            picks.append(grp.sample(k, random_state=int(rng.integers(1 << 30))))
        chosen = pd.concat(picks) if picks else pool.head(0)
        if len(chosen) > n_target:
            chosen = chosen.sample(n_target, random_state=seed)
        chosen = chosen.copy()
        chosen["draw_reason"] = "pilot: coverage-class breadth"
    else:
        w = np.sqrt(sizes.astype(float))
        alloc = (w / w.sum() * n_target).round().astype(int).clip(lower=3)
        alloc = alloc.clip(upper=sizes)
        picks = []
        for stratum, k in alloc.items():
            grp = pool[pool.stratum == stratum]
            picks.append(grp.sample(min(int(k), len(grp)),
                                    random_state=int(rng.integers(1 << 30))))
        chosen = pd.concat(picks).copy()
        chosen["draw_reason"] = "stratified: coverage x climate x elevation"

    out = pd.concat([take, chosen], ignore_index=True).drop_duplicates("facility_id")
    cols = ["facility_id", "name", "state", "latitude", "longitude", "coverage",
            "climate_region", "elev_proxy_m", "elev_band", "stratum", "is_bor",
            "join_via", "draw_reason"]
    return out[cols].sort_values(["coverage", "state", "facility_id"]).reset_index(drop=True)


# ==================================================================== commands
def cmd_frame(a) -> int:
    frame = build_frame(a.n if not a.pilot else a.pilot_n, pilot=a.pilot, seed=a.seed,
                        pilot_bor=a.pilot_bor)
    SUMMARY.mkdir(parents=True, exist_ok=True)
    path = SUMMARY / ("pilot_sample_frame.csv" if a.pilot else "full_sample_frame.csv")
    frame.to_csv(path, index=False)
    # The full frame is ~1 MB and is only valid against the fleet snapshot it was
    # drawn from, so it stays gitignored; the compact allocation IS committed so
    # the design is reviewable without the row-level file.
    alloc = frame.groupby(["coverage", "climate_region", "elev_band"]).agg(
        n=("facility_id", "size"), n_bor=("is_bor", "sum")).reset_index()
    alloc.to_csv(SUMMARY / f"{'pilot' if a.pilot else 'full'}_frame_allocation.csv",
                 index=False)
    print(f"frame: {len(frame)} facilities -> {path}")
    print(frame.coverage.value_counts().to_string())
    print(f"  BOR-overlap included: {int(frame.is_bor.sum())}")
    return 0


def _ledger_row(fid, rec, series, txt, prov, parsed, err) -> dict:
    row = {c: "" for c in LEDGER_COLS}
    row.update({
        "facility_id": fid, "name": rec["name"], "state": rec["state"],
        "lat": f"{rec['latitude']:.4f}", "lon": f"{rec['longitude']:.4f}",
        "series": series, "http_status": prov.get("http_status", ""),
        "cache_file": prov.get("cache_file", ""), "sha256": prov.get("sha256", ""),
        "source": prov.get("source", ""),
        "fetched_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    if err is not None:
        row["status"] = err[0]
        row["note"] = err[1][:200]
        return row
    meta, tbl = parsed["meta"], parsed["table"]
    row.update({
        "status": "ok", "atlas": meta.get("atlas", ""), "volume": meta.get("volume", ""),
        "version": meta.get("version", ""), "project_area": meta.get("project_area", ""),
        "series_type": meta.get("series_type", ""), "data_type": meta.get("data_type", ""),
        "units": meta.get("units", ""), "n_rows": len(tbl),
    })
    tbl = tbl.copy()
    tbl["dk"] = tbl.duration.map(dur_key)
    tbl["rank"] = tbl.duration.map(_dur_rank)
    for dk, T, col in (("24h", 100, "depth24h_100yr_mm"), ("24h", 1000, "depth24h_1000yr_mm"),
                       ("72h", 100, "depth72h_100yr_mm")):
        sel = tbl[(tbl.dk == dk) & (tbl.ari_yr == T)].sort_values("rank")
        if len(sel):
            row[col] = f"{sel.depth_mm.iloc[0]:.2f}"
    return row


def cmd_fetch(a) -> int:
    path = SUMMARY / ("pilot_sample_frame.csv" if a.pilot else "full_sample_frame.csv")
    if not path.exists():
        print(f"no sample frame at {path}; run `frame` first", file=sys.stderr)
        return 2
    frame = pd.read_csv(path)
    series_list = [s.strip() for s in a.series.split(",") if s.strip()]
    done = _done_keys(LEDGER, LEDGER_COLS)
    todo = [(r, s) for _, r in frame.iterrows() for s in series_list
            if (r.facility_id, s) not in done]
    if not todo:
        print("nothing to do: every (facility, series) in the frame is already in the ledger")
        return 0
    todo = todo[: a.max]
    print(f"fetching {len(todo)} (facility, series) pairs "
          f"[{len(done)} already in ledger; cap --max {a.max}; sleep {a.sleep}s]")

    cli = PFDSClient(sleep_s=a.sleep, jitter_s=a.jitter)
    rows, n_cov, n_none, n_err = [], 0, 0, 0
    try:
        for i, (rec, series) in enumerate(todo, 1):
            fid = rec.facility_id
            try:
                txt, prov = cli.fetch_csv(fid, rec.latitude, rec.longitude, series)
            except Exception as e:                        # noqa: BLE001
                rows.append(_ledger_row(fid, rec, series, "", {}, None, ("fetch_error", str(e))))
                n_err += 1
                continue
            try:
                parsed = parse_pfds_csv(txt)
                rows.append(_ledger_row(fid, rec, series, txt, prov, parsed, None))
                n_cov += 1
            except PFDSNoCoverage as e:
                rows.append(_ledger_row(fid, rec, series, txt, prov, None,
                                        ("no_coverage", str(e))))
                n_none += 1
            except PFDSParseError as e:
                rows.append(_ledger_row(fid, rec, series, txt, prov, None,
                                        ("parse_error", str(e))))
                n_err += 1
            if i % 10 == 0 or i == len(todo):
                print(f"  {i}/{len(todo)}  ok={n_cov} no-coverage={n_none} err={n_err}")
    finally:
        _append_ledger(LEDGER, rows, LEDGER_COLS)
        print(f"ledger += {len(rows)} rows -> {LEDGER}  ({cli.n_requests} network requests)")
    return 0


def cmd_verify(a) -> int:
    """QAQC plan D3: ground-truth the scraper against what the PFDS web UI shows.

    The PFDS web UI (hdsc.nws.noaa.gov/pfds/) is an ArcGIS/JS application: its
    table is not in the HTML, it is drawn client-side from
    `cgi-bin/new/cgi_readH5.py?type=pf` (see pfds/code/code_gen_16.js,
    getTableVals()). So "what the web UI returns" IS that payload, and this
    command fetches it and compares EVERY value against the scripted
    `fe_text_mean.csv` path -- different CGI program, different response format
    (Python-literal matrices vs labelled CSV text), different code path on the
    server, same point. Where `--grids` is given it adds a third, fully
    independent channel: NOAA's own published ArcGIS ASCII grid for that
    volume/duration/ARI, downloaded from /pub/hdsc/data/ and sampled at the
    dam's cell -- a static distributed product that shares no CGI code at all.
    """
    led = _read_ledger(LEDGER, LEDGER_COLS)
    ok = led[(led.status == "ok") & (led.series == a.series)]
    if ok.empty:
        print("no successfully-fetched sites in the ledger for that series", file=sys.stderr)
        return 2
    # spread the verification set over volumes rather than taking the first N
    ok = ok.sample(frac=1.0, random_state=a.seed)
    sel = ok.groupby("volume", group_keys=False).head(max(1, a.n // max(1, ok.volume.nunique()) + 1))
    if len(sel) < a.n:
        sel = pd.concat([sel, ok[~ok.facility_id.isin(sel.facility_id)]]).head(a.n)
    sel = sel.head(a.n)

    done = _done_keys(VERIFY_LEDGER, VERIFY_COLS)
    cli = PFDSClient(sleep_s=a.sleep, jitter_s=a.jitter)
    rows = []
    try:
        for _, r in sel.iterrows():
            if (r.facility_id, "cgi_readH5") in done:
                continue
            lat, lon = float(r.lat), float(r.lon)
            csv_txt = (CACHE / r.cache_file).read_text(encoding="utf-8", errors="replace")
            csv_parsed = parse_pfds_csv(csv_txt)
            ctab = csv_parsed["table"]
            try:
                h5_txt, _ = cli.fetch_h5(r.facility_id, lat, lon, a.series)
                h5 = parse_readh5(h5_txt)
            except Exception as e:                        # noqa: BLE001
                rows.append({"facility_id": r.facility_id, "lat": r.lat, "lon": r.lon,
                             "series": a.series, "method": "cgi_readH5",
                             "n_values_compared": 0, "n_mismatch": "", "verdict": "ERROR",
                             "detail": str(e)[:160],
                             "checked_utc": datetime.now(timezone.utc).isoformat(timespec="seconds")})
                continue

            # CSV row order = readH5 row order is the assumption under test.
            durs = list(dict.fromkeys(ctab.duration))
            aris = sorted(ctab.ari_yr.unique())
            dur_note = ("" if durs == READH5_DURATIONS_CONUS
                        else f"; NON-STANDARD duration list: {'|'.join(durs)}")
            q = h5["quantiles"]
            shape_ok = (len(q) == len(durs) and all(len(rw) == len(aris) for rw in q))
            n_cmp = n_bad = 0
            worst, worst_txt = 0.0, ""
            if shape_ok:
                lut = {(d, t): v for d, t, v in zip(ctab.duration, ctab.ari_yr, ctab.value)}
                for di, dlab in enumerate(durs):
                    for ai, T in enumerate(aris):
                        cv = lut.get((dlab, T))
                        hv = q[di][ai]
                        if cv is None:
                            continue
                        n_cmp += 1
                        rel = abs(hv - cv) / max(abs(cv), 1e-9) * 100
                        if rel > worst:
                            worst, worst_txt = rel, f"{dlab}/{T:g}yr csv={cv} readH5={hv}"
                        if rel > a.tol_pct:
                            n_bad += 1
                verdict = "MATCH" if n_bad == 0 else "MISMATCH"
                detail = (f"{len(durs)}x{len(aris)} matrix; worst {worst:.4f}% "
                          f"({worst_txt}); vol={h5.get('volume')} "
                          f"region={h5.get('region')}{dur_note}")
            else:
                verdict = "SHAPE_MISMATCH"
                detail = (f"csv {len(durs)}x{len(aris)} vs readH5 "
                          f"{len(q)}x{len(q[0]) if q else 0}")
            sel24 = ctab[(ctab.duration.map(dur_key) == "24h") & (ctab.ari_yr == 100)]
            sel24 = sel24.assign(rk=sel24.duration.map(_dur_rank)).sort_values("rk")
            csv24 = f"{sel24.value.iloc[0]:.3f}" if len(sel24) else ""
            ref24 = ""
            if shape_ok:
                lbl = sel24.duration.iloc[0] if len(sel24) else None
                if lbl in durs and 100.0 in aris:
                    ref24 = f"{q[durs.index(lbl)][aris.index(100.0)]:.3f}"
            rows.append({
                "facility_id": r.facility_id, "lat": r.lat, "lon": r.lon,
                "series": a.series, "method": "cgi_readH5", "n_values_compared": n_cmp,
                "n_mismatch": n_bad, "max_abs_reldiff_pct": f"{worst:.5f}",
                "csv_24h_100yr_in": csv24, "ref_24h_100yr_in": ref24,
                "verdict": verdict, "detail": detail,
                "checked_utc": datetime.now(timezone.utc).isoformat(timespec="seconds")})
            print(f"  {r.facility_id:<10} vol{r.volume:<3} {verdict:<14} "
                  f"n={n_cmp:<4} worst={worst:.4f}%")
    finally:
        _append_ledger(VERIFY_LEDGER, rows, VERIFY_COLS)

    if a.grids:
        rows2 = verify_against_grids(sel, cli, a)
        _append_ledger(VERIFY_LEDGER, rows2, VERIFY_COLS)

    v = _read_ledger(VERIFY_LEDGER, VERIFY_COLS)
    v = v.drop_duplicates(["facility_id", "method"], keep="last")
    SUMMARY.mkdir(parents=True, exist_ok=True)
    v.to_csv(SUMMARY / "groundtruth_verification.csv", index=False)
    print(v.groupby(["method", "verdict"]).size().to_string())
    return 0


# region code -> ASCII-grid filename stem on /pub/hdsc/data/
GRID_REGION_DIR = {"inw": "inw", "mw": "mw", "orb": "orb", "se": "se", "ne": "ne",
                   "sw": "sw", "tx": "tx", "ak": "ak", "hi": "hi", "pr": "pr"}


def _download(url: str, dest: Path, sleep_s: float = DEFAULT_SLEEP_S) -> bool:
    import requests

    if dest.exists() and dest.stat().st_size > 0:
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"  downloading {url}", file=sys.stderr)
    r = requests.get(url, timeout=600, headers={"User-Agent": USER_AGENT})
    if r.status_code != 200:
        print(f"    unavailable (HTTP {r.status_code})", file=sys.stderr)
        return False
    dest.write_bytes(r.content)
    time.sleep(sleep_s)
    return True


def read_asc_grid(zip_path: Path) -> tuple[dict, np.ndarray, str]:
    """Read the single ArcInfo-ASCII grid inside a PFDS grid zip."""
    import zipfile

    with zipfile.ZipFile(zip_path) as z:
        asc = next(n for n in z.namelist() if n.lower().endswith(".asc"))
        with z.open(asc) as fh:
            hdr = {}
            for _ in range(6):
                k, v = fh.readline().decode().split()
                hdr[k.lower()] = float(v)
            grid = np.loadtxt(fh)
    return hdr, grid, asc


def sample_asc(hdr: dict, grid: np.ndarray, lat: float, lon: float) -> float:
    """Nearest-cell value, or NaN outside the grid / on NODATA."""
    cs, x0, y0 = hdr["cellsize"], hdr["xllcorner"], hdr["yllcorner"]
    nrows, ncols = int(hdr["nrows"]), int(hdr["ncols"])
    col = int((lon - x0) / cs)
    row = int(nrows - 1 - (lat - y0) / cs)
    if not (0 <= row < nrows and 0 <= col < ncols):
        return float("nan")
    v = grid[row, col]
    return float("nan") if v == hdr["nodata_value"] else float(v)


# ---------------------------------------------------------------- NOAA Atlas 2
# The Atlas-2 legacy stratum (NID_ANALYSIS_PLAN B1: "quantify what half a century
# of data does to the official number"). Oregon and Washington have NO Atlas 14
# at all; NOAA's own state pages say the current official product there is
#   OR -> NOAA Atlas 2, Volume 10 (1973)
#   WA -> NOAA Atlas 2, Volume  9 (1973)
# "Precipitation-Frequency Atlas of the Western United States", which publishes
# only the 6-hr and 24-hr durations at T = 2, 5, 10, 25, 50, 100 yr -- so the
# ONLY quantiles this project overlaps there are 24 h at T = 2 and T = 100, and
# there is no 1000-yr or 72-h Atlas 2 benchmark to compare against at all.
# There is no Atlas 2 point-query CGI; the published 15-arc-second ASCII grids
# are the machine-readable form.
ATLAS2_GRIDS = {
    "OR": ("oregon", "na2_or", "NOAA Atlas 2 Vol 10 (1973), Oregon"),
    "WA": ("washington", "na2_wa", "NOAA Atlas 2 Vol 9 (1973), Washington"),
}
ATLAS2_T = [2, 100]
# The Atlas 2 .asc headers carry no units. Scale inferred as 1e-5 inch from the
# value range (1.70-14.50 in over Oregon for 100-yr/24-h, which is the range the
# published Volume 10 isopluvials show) and CHECKED at the Oregon/Idaho border
# against the Atlas 14 Volume 12 CGI on the Idaho side -- see
# `atlas2 --unit-check`, whose result is written to the summary directory.
ATLAS2_SCALE_TO_IN = 1e-5


def verify_against_grids(sel: pd.DataFrame, cli, a) -> list[dict]:
    """Third channel: sample NOAA's published 100-yr/24-h ASCII grid at the dam.

    Grids are `<reg><T>yr24ha.zip` (PDS) / `..._ams.zip` (AMS) under
    /pub/hdsc/data/<reg>/, ArcInfo ASCII, 30 arc-second, values in
    THOUSANDTHS OF AN INCH. Nearest-cell sampling; the CGI does bilinear-ish
    interpolation inside the same cell grid, so a sub-cell difference is
    expected and is reported, not hidden.
    """
    GRIDS = DATA / "grids"
    GRIDS.mkdir(parents=True, exist_ok=True)
    out = []
    by_reg: dict[str, pd.DataFrame] = {}
    led = sel.copy()
    led["reg"] = led.project_area.map({
        "Interior Northwest": "inw", "Midwestern States": "mw",
        "Ohio River Basin": "orb", "Southeastern States": "se",
        "Northeastern States": "ne", "Southwest": "sw", "Texas": "tx",
        "Alaska": "ak", "Hawaiian Islands": "hi",
        "Puerto Rico and U.S. Virgin Islands": "pr"})
    want = {r.strip() for r in a.grid_regions.split(",") if r.strip()}
    for reg, grp in led.dropna(subset=["reg"]).groupby("reg"):
        if want and reg not in want:
            continue
        by_reg[reg] = grp.head(a.grid_sites_per_region)

    for reg, grp in by_reg.items():
        stem = f"{reg}100yr24ha" + ("_ams" if a.series == "ams" else "")
        zpath = GRIDS / f"{stem}.zip"
        if not _download(f"{GRID_BASE}{GRID_REGION_DIR.get(reg, reg)}/{stem}.zip",
                         zpath, a.sleep):
            continue
        hdr, grid, asc = read_asc_grid(zpath)
        for _, r in grp.iterrows():
            lat, lon = float(r.lat), float(r.lon)
            gin = sample_asc(hdr, grid, lat, lon) / 1000.0
            csv_in = float(r.depth24h_100yr_mm) / IN2MM if r.depth24h_100yr_mm else np.nan
            rel = abs(gin - csv_in) / csv_in * 100 if np.isfinite(gin) and np.isfinite(csv_in) else np.nan
            verdict = ("NODATA" if not np.isfinite(gin)
                       else "MATCH" if rel <= a.grid_tol_pct else "MISMATCH")
            out.append({
                "facility_id": r.facility_id, "lat": r.lat, "lon": r.lon,
                "series": a.series, "method": f"published_grid:{stem}",
                "n_values_compared": 1, "n_mismatch": int(verdict == "MISMATCH"),
                "max_abs_reldiff_pct": f"{rel:.4f}" if np.isfinite(rel) else "",
                "csv_24h_100yr_in": f"{csv_in:.3f}" if np.isfinite(csv_in) else "",
                "ref_24h_100yr_in": f"{gin:.3f}" if np.isfinite(gin) else "",
                "verdict": verdict,
                "detail": f"nearest 30-arcsec cell of {asc} (thousandths of an inch)",
                "checked_utc": datetime.now(timezone.utc).isoformat(timespec="seconds")})
            print(f"  {r.facility_id:<10} grid {stem:<16} {verdict:<9} "
                  f"csv={csv_in:.3f} grid={gin:.3f} in  ({rel:.2f}%)")
    return out


def cmd_atlas2(a) -> int:
    """Atlas-2 legacy stratum: sample NOAA's published 1973 grids in OR/WA.

    Everywhere else in this analysis the benchmark is a live CGI point query;
    in Oregon and Washington no such service exists, because no Atlas 14 study
    covers them. The benchmark there is the 1973 Atlas 2 grid NOAA still ships,
    so 'no coverage' becomes a measurable *stratum* instead of a hole.
    """
    frame = pd.read_csv(SUMMARY / ("pilot_sample_frame.csv" if a.pilot
                                   else "full_sample_frame.csv"))
    sub = frame[frame.state.isin(ATLAS2_GRIDS)]
    GRIDS = DATA / "grids"
    rows, checks = [], []
    for st, grp in sub.groupby("state"):
        subdir, stem, label = ATLAS2_GRIDS[st]
        for T in ATLAS2_T:
            name = f"{stem}_{T}yr24hr"
            z = GRIDS / f"{name}.zip"
            if not _download(f"{GRID_BASE}{subdir}/{name}.zip", z, a.sleep):
                continue
            hdr, grid, asc = read_asc_grid(z)
            if T == 100:
                v = grid[grid != hdr["nodata_value"]]
                checks.append({"grid": asc, "min_in": v.min() * ATLAS2_SCALE_TO_IN,
                               "max_in": v.max() * ATLAS2_SCALE_TO_IN,
                               "median_in": float(np.median(v)) * ATLAS2_SCALE_TO_IN,
                               "cellsize_deg": hdr["cellsize"]})
            for _, r in grp.iterrows():
                depth_in = sample_asc(hdr, grid, r.latitude, r.longitude) * ATLAS2_SCALE_TO_IN
                rows.append({
                    "facility_id": r.facility_id, "name": r["name"], "state": st,
                    "lat": r.latitude, "lon": r.longitude, "source": label,
                    "grid": asc, "duration": "24h", "return_period_yr": T,
                    "atlas2_in": round(depth_in, 3) if np.isfinite(depth_in) else "",
                    "atlas2_mm": round(depth_in * IN2MM, 2) if np.isfinite(depth_in) else "",
                    "sampled_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
    if a.unit_check:
        checks += _atlas2_unit_check(a)
    SUMMARY.mkdir(parents=True, exist_ok=True)
    tag = "pilot" if a.pilot else "full"
    out = pd.DataFrame(rows)
    out.to_csv(SUMMARY / f"{tag}_atlas2_pnw.csv", index=False)
    if checks:
        pd.DataFrame(checks).to_csv(SUMMARY / "atlas2_grid_unit_check.csv", index=False)
        print(pd.DataFrame(checks).to_string(index=False))
    print(f"{len(out)} Atlas 2 samples over {out.facility_id.nunique() if len(out) else 0} "
          f"facilities -> {SUMMARY}")
    return 0


def _atlas2_unit_check(a) -> list[dict]:
    """Cross-border scale check for the undocumented Atlas 2 grid units.

    Precipitation frequency is continuous across a state line; the *products*
    are not. Sampling the Oregon Atlas 2 grid a few km west of the Oregon/Idaho
    border and querying the Atlas 14 Volume 12 CGI a few km east must give the
    same order of magnitude if (and only if) the assumed 1e-5-inch scale is
    right -- a factor-of-10 error would be unmissable. The residual difference
    is a real 1973-vs-modern difference, not an error, and is reported as such.
    """
    cli = PFDSClient(sleep_s=a.sleep, jitter_s=a.jitter)
    z = DATA / "grids" / "na2_or_100yr24hr.zip"
    if not _download(f"{GRID_BASE}oregon/na2_or_100yr24hr.zip", z, a.sleep):
        return []
    hdr, grid, asc = read_asc_grid(z)
    out = []
    for i, lat in enumerate((42.5, 43.5, 44.5, 45.5)):
        or_in = sample_asc(hdr, grid, lat, -117.10) * ATLAS2_SCALE_TO_IN   # OR side
        txt, _ = cli.fetch_csv(f"BORDERCHK_{i}", lat, -116.90, "pds")      # ID side
        try:
            t = parse_pfds_csv(txt)["table"]
            sel = t[(t.duration.map(dur_key) == "24h") & (t.ari_yr == 100)]
            id_in = float(sel.sort_values(
                by="duration", key=lambda s: s.map(_dur_rank)).value.iloc[0])
        except (PFDSNoCoverage, PFDSParseError, IndexError):
            continue
        out.append({"grid": f"border check {lat:.1f}N", "min_in": round(or_in, 3),
                    "max_in": round(id_in, 3), "median_in": round(or_in / id_in, 3),
                    "cellsize_deg": hdr["cellsize"],
                    "note": f"OR Atlas 2 @-117.10 = {or_in:.2f} in vs "
                            f"ID Atlas 14 V12 @-116.90 = {id_in:.2f} in; ratio "
                            f"{or_in / id_in:.2f}"})
        print(f"  border {lat:.1f}N: Atlas 2 (OR) {or_in:.2f} in vs "
              f"Atlas 14 V12 (ID) {id_in:.2f} in -> ratio {or_in / id_in:.2f}")
    return out


def cmd_coverage(a) -> int:
    """Empirically probe which states/regions Atlas 14 actually covers."""
    man = C.load_manifest()
    rng = np.random.default_rng(a.seed)
    cli = PFDSClient(sleep_s=a.sleep, jitter_s=a.jitter)
    rows = []
    states = sorted(set(man.state.dropna()) | ATLAS2_STATES)
    if a.states:
        states = [s.strip().upper() for s in a.states.split(",")]
    for st in states:
        grp = man[(man.state == st)].dropna(subset=["latitude", "longitude"])
        if grp.empty:
            continue
        pts = grp.sample(min(a.per_state, len(grp)), random_state=int(rng.integers(1 << 30)))
        for _, p in pts.iterrows():
            fid = f"COV_{p.facility_id}"
            try:
                txt, prov = cli.fetch_csv(fid, p.latitude, p.longitude, "pds")
                parsed = parse_pfds_csv(txt)
                m = parsed["meta"]
                rows.append({"state": st, "facility_id": p.facility_id,
                             "lat": p.latitude, "lon": p.longitude, "covered": True,
                             "atlas": m.get("atlas"), "volume": m.get("volume"),
                             "version": m.get("version"),
                             "project_area": m.get("project_area"),
                             "series_type": m.get("series_type"), "units": m.get("units"),
                             "n_durations": parsed["table"].duration.nunique(),
                             "durations": "|".join(dict.fromkeys(parsed["table"].duration))})
            except PFDSNoCoverage:
                rows.append({"state": st, "facility_id": p.facility_id,
                             "lat": p.latitude, "lon": p.longitude, "covered": False,
                             "atlas": "", "volume": "", "version": "",
                             "project_area": ATLAS2_LABEL, "series_type": "",
                             "units": "", "n_durations": 0, "durations": ""})
            except Exception as e:                        # noqa: BLE001
                rows.append({"state": st, "facility_id": p.facility_id,
                             "lat": p.latitude, "lon": p.longitude, "covered": None,
                             "project_area": f"ERROR {e}"})
    df = pd.DataFrame(rows)
    SUMMARY.mkdir(parents=True, exist_ok=True)
    path = SUMMARY / "coverage_probe.csv"
    if path.exists():
        df = pd.concat([pd.read_csv(path), df], ignore_index=True).drop_duplicates(
            subset=["facility_id"], keep="last")
    df.to_csv(path, index=False)
    print(df.groupby(["state"]).agg(n=("covered", "size"),
                                    covered=("covered", "sum")).to_string())
    print(f"-> {path}")
    return 0


# ==================================================================== compare
def _ours_lookup(ddf: pd.DataFrame, frame: pd.DataFrame, ts: list[int]):
    """(facility_id, duration, T) -> our depth in mm, or NaN.

    Two join paths, in order of trustworthiness:
      1. `site_id` -- unambiguous, present for the post-centralization cohort;
      2. facility NAME -- only for names the sample frame already restricted to
         globally unique ones, so the fleet's known name collisions can never
         resolve to the wrong dam here.
    """
    d = ddf[ddf.duration.isin(TARGET_DUR) & ddf.return_period_yr.isin(ts)]
    by_id = d[d.site_id != ""].drop_duplicates(
        ["site_id", "duration", "return_period_yr"]).set_index(
        ["site_id", "duration", "return_period_yr"]).depth_mm
    name2id = frame.set_index("name").facility_id.to_dict()
    dn = d[d.site_id == ""].copy()
    dn["fid"] = dn.site.map(name2id)
    by_name = dn.dropna(subset=["fid"]).drop_duplicates(
        ["fid", "duration", "return_period_yr"]).set_index(
        ["fid", "duration", "return_period_yr"]).depth_mm

    def get(fid: str, dk: str, T: int) -> float:
        key = (fid, dk, T)
        v = by_id.get(key, by_name.get(key, np.nan))
        return float(v) if np.isscalar(v) and np.isfinite(v) else np.nan

    return get


def _atlas2_compare(tag: str, ours_at) -> pd.DataFrame | None:
    """PNW stratum: our estimate vs the 1973 Atlas 2 number still in force."""
    path = SUMMARY / f"{tag}_atlas2_pnw.csv"
    if not path.exists():
        return None
    a2 = pd.read_csv(path)
    rows = []
    for _, r in a2.iterrows():
        if not np.isfinite(pd.to_numeric(r.atlas2_mm, errors="coerce")):
            continue
        ours = ours_at(r.facility_id, "24h", int(r.return_period_yr))
        if not np.isfinite(ours):
            continue
        rows.append({"facility_id": r.facility_id, "name": r["name"], "state": r.state,
                     "benchmark": r.source, "duration": "24h",
                     "return_period_yr": int(r.return_period_yr),
                     "ours_mm": round(ours, 2), "atlas2_mm": round(float(r.atlas2_mm), 2),
                     "pct_diff": round(100 * (ours - float(r.atlas2_mm))
                                       / float(r.atlas2_mm), 2)})
    out = pd.DataFrame(rows)
    out.to_csv(SUMMARY / f"{tag}_atlas2_comparison.csv", index=False)
    return out if len(out) else None


def cmd_compare(a) -> int:
    led = _read_ledger(LEDGER, LEDGER_COLS)
    led = led[led.series == a.series]
    if led.empty:
        print("empty ledger for that series", file=sys.stderr)
        return 2
    frame = pd.read_csv(SUMMARY / ("pilot_sample_frame.csv" if a.pilot
                                   else "full_sample_frame.csv"))
    ddf = load_fleet_ddf()
    pin = fleet_pin()

    ours_at = _ours_lookup(ddf, frame, TARGET_T + ATLAS2_T)

    recs = []
    ok = led[led.status == "ok"]
    for _, r in ok.iterrows():
        fr = frame[frame.facility_id == r.facility_id]
        if fr.empty:
            continue
        fr = fr.iloc[0]
        for dk, T, col in (("24h", 100, "depth24h_100yr_mm"),
                           ("24h", 1000, "depth24h_1000yr_mm"),
                           ("72h", 100, "depth72h_100yr_mm")):
            a14 = r[col]
            if not a14:
                continue
            ours = ours_at(r.facility_id, dk, T)
            if not np.isfinite(ours):
                continue
            a14 = float(a14)
            recs.append({
                "facility_id": r.facility_id, "name": r["name"], "state": r.state,
                "coverage": fr.coverage, "climate_region": fr.climate_region,
                "elev_band": fr.elev_band, "is_bor": bool(fr.is_bor),
                "volume": r.volume, "version": r.version, "project_area": r.project_area,
                "duration": dk, "return_period_yr": T,
                "ours_mm": round(float(ours), 2), "atlas14_mm": round(a14, 2),
                "pct_diff": round(100 * (ours - a14) / a14, 2)})
    cmp_df = pd.DataFrame(recs)
    if len(cmp_df):
        # Station support / heterogeneity per facility, so disagreement can be
        # decomposed against method conditions rather than geography alone.
        diag = load_fleet_diag()
        dmap = pd.concat([
            diag[diag.site_id != ""].set_index("site_id")[["n_stations", "H1"]],
            diag[diag.site_id == ""].assign(
                fid=lambda d: d.site.map(frame.set_index("name").facility_id.to_dict())
            ).dropna(subset=["fid"]).set_index("fid")[["n_stations", "H1"]],
        ])
        dmap = dmap[~dmap.index.duplicated()]
        cmp_df = cmp_df.join(dmap, on="facility_id")
    SUMMARY.mkdir(parents=True, exist_ok=True)
    tag = "pilot" if a.pilot else "full"
    cmp_df.to_csv(SUMMARY / f"{tag}_comparison.csv", index=False)

    if cmp_df.empty:
        print("no overlapping facilities between the ledger and the fleet DDF")
        return 1

    def stats(g: pd.DataFrame) -> pd.Series:
        p = g.pct_diff
        return pd.Series({
            "n": len(g), "median_pct": round(p.median(), 2),
            "mean_pct": round(p.mean(), 2),
            "p10_pct": round(p.quantile(.10), 2), "p90_pct": round(p.quantile(.90), 2),
            "iqr_pct": round(p.quantile(.75) - p.quantile(.25), 2),
            "median_abs_pct": round(p.abs().median(), 2),
            "frac_within_10pct": round((p.abs() <= 10).mean(), 3),
            "frac_within_20pct": round((p.abs() <= 20).mean(), 3),
            "frac_ours_higher": round((p > 0).mean(), 3)})

    head = cmp_df[(cmp_df.duration == "24h") & (cmp_df.return_period_yr == 100)]
    tables = {
        "overall": cmp_df.groupby(["duration", "return_period_yr"]).apply(
            stats, include_groups=False).reset_index(),
        "by_volume_24h_100yr": head.groupby("project_area").apply(
            stats, include_groups=False).reset_index(),
        "by_climate_24h_100yr": head.groupby("climate_region").apply(
            stats, include_groups=False).reset_index(),
        "by_elev_24h_100yr": head.groupby("elev_band").apply(
            stats, include_groups=False).reset_index(),
    }
    for k, t in tables.items():
        if "n" in t.columns:
            t["n"] = t["n"].astype(int)
        t.to_csv(SUMMARY / f"{tag}_stats_{k}.csv", index=False)
        print(f"\n== {k} ==\n{t.to_string(index=False)}")

    st = _series_type_check(tag)
    if st is not None:
        print(f"\n== series-type check (PDS vs AMS at the same points) ==\n"
              f"{st.to_string(index=False)}")

    head = head.merge(frame[["facility_id", "elev_proxy_m"]], on="facility_id", how="left")
    dec = _decomposition(head, tag)
    print(f"\n== disagreement decomposition (24h/100yr, Spearman + permutation p) ==\n"
          f"{dec.to_string(index=False)}")

    a2 = _atlas2_compare(tag, ours_at)
    if a2 is not None:
        print("\n== Atlas-2 legacy stratum (OR/WA: no Atlas 14 exists) ==\n"
              f"{a2.to_string(index=False)}")
        print(a2.groupby('return_period_yr').pct_diff.describe()[
            ['count', 'mean', '50%', 'min', 'max']].to_string())

    boot = _bootstrap_median_ci(head.pct_diff.to_numpy())
    print(f"\n24h/100yr: median {head.pct_diff.median():+.2f}% "
          f"(bootstrap 95% CI {boot[0]:+.2f} .. {boot[1]:+.2f}), "
          f"n = {len(head)}; sign test {int((head.pct_diff > 0).sum())}/{len(head)} positive")

    _pilot_figure(cmp_df, head, tag)
    print(f"\nfleet pin: {pin}")
    return 0


def _spearman_perm(x: np.ndarray, y: np.ndarray, n: int = 20000,
                   seed: int = 20260820) -> tuple[float, float]:
    """Spearman rho with a permutation p-value (no scipy dependency).

    Permutation rather than the asymptotic t-approximation because these
    samples are small and the differences are not remotely normal.
    """
    m = np.isfinite(x) & np.isfinite(y)
    x, y = x[m], y[m]
    if len(x) < 5:
        return float("nan"), float("nan")

    def rho(u, v):
        ru = pd.Series(u).rank().to_numpy()
        rv = pd.Series(v).rank().to_numpy()
        return float(np.corrcoef(ru, rv)[0, 1])

    obs = rho(x, y)
    rng = np.random.default_rng(seed)
    null = np.array([rho(x, rng.permutation(y)) for _ in range(n)])
    return obs, float((np.abs(null) >= abs(obs)).mean())


def _decomposition(head: pd.DataFrame, tag: str) -> pd.DataFrame:
    """Is disagreement structured by method conditions, or just noise?

    Plan B1 asks for disagreement decomposed by station density and terrain.
    Both tests are reported whatever they say -- a null result here is a
    result, and reporting only the significant one would be the exact failure
    mode the QA/QC plan's independent-verification pass exists to prevent.
    """
    rows = []
    for var, label in (("H1", "heterogeneity H1 (24h)"),
                       ("n_stations", "station support (24h)"),
                       ("elev_proxy_m", "elevation proxy (m)")):
        if var not in head.columns:
            continue
        r_abs, p_abs = _spearman_perm(head[var].to_numpy(dtype=float),
                                      head.pct_diff.abs().to_numpy(dtype=float))
        r_sgn, p_sgn = _spearman_perm(head[var].to_numpy(dtype=float),
                                      head.pct_diff.to_numpy(dtype=float))
        rows.append({"variable": var, "label": label,
                     "n": int(np.isfinite(head[var].to_numpy(dtype=float)).sum()),
                     "spearman_vs_abs_diff": round(r_abs, 3), "perm_p_abs": round(p_abs, 4),
                     "spearman_vs_signed_diff": round(r_sgn, 3),
                     "perm_p_signed": round(p_sgn, 4)})
    out = pd.DataFrame(rows)
    out.to_csv(SUMMARY / f"{tag}_decomposition.csv", index=False)
    return out


def _bootstrap_median_ci(x: np.ndarray, n: int = 4000, seed: int = 20260820) -> tuple:
    rng = np.random.default_rng(seed)
    meds = np.median(rng.choice(x, size=(n, len(x)), replace=True), axis=1)
    return tuple(np.percentile(meds, [2.5, 97.5]))


def _series_type_check(tag: str) -> pd.DataFrame | None:
    """Does the partial-duration / annual-maximum choice change the answer?

    NOAA converts its PDS quantiles to AMS with fixed Langbein factors that go
    to 1 as T grows, so the two series should coincide at the return periods
    this analysis headlines. This quantifies that on the sample actually
    fetched instead of asserting it -- it is the evidence behind picking
    `--series ams` (the like-for-like match to the fleet's AMS pipeline)
    without having to re-fetch everything if that choice is ever revisited.
    """
    led = _read_ledger(LEDGER, LEDGER_COLS)
    ok = led[led.status == "ok"]
    if not {"ams", "pds"} <= set(ok.series):
        return None
    rows = []
    for col, lab in (("depth24h_100yr_mm", "24h / 100yr"),
                     ("depth24h_1000yr_mm", "24h / 1000yr"),
                     ("depth72h_100yr_mm", "72h / 100yr")):
        a = ok[ok.series == "ams"].set_index("facility_id")[col]
        p = ok[ok.series == "pds"].set_index("facility_id")[col]
        j = pd.concat([pd.to_numeric(a, errors="coerce").rename("ams"),
                       pd.to_numeric(p, errors="coerce").rename("pds")],
                      axis=1).dropna()
        rel = (j.ams - j.pds).abs() / j.pds * 100
        rows.append({"quantile": lab, "n_sites": len(j),
                     "n_bitwise_identical": int((j.ams == j.pds).sum()),
                     "max_abs_pct_diff": round(float(rel.max()), 3),
                     "median_abs_pct_diff": round(float(rel.median()), 3)})
    out = pd.DataFrame(rows)
    out.to_csv(SUMMARY / f"{tag}_series_type_check.csv", index=False)
    return out


def _pilot_figure(cmp_df: pd.DataFrame, head: pd.DataFrame, tag: str) -> None:
    plt = C.style_matplotlib()
    fig, axes = plt.subplots(1, 2, figsize=(13, 4.8))
    ax = axes[0]
    ax.hist(head.pct_diff, bins=np.arange(-60, 65, 5), color=C.OKABE_ITO[0],
            edgecolor="white", linewidth=.6)
    ax.axvline(0, color=C.INK, lw=1)
    ax.axvline(head.pct_diff.median(), color=C.OKABE_ITO[5], lw=1.6, ls="--",
               label=f"median {head.pct_diff.median():+.1f}%")
    ax.set_xlabel("(L-moments - Atlas 14) / Atlas 14, 24 h 100 yr  [%]")
    ax.set_ylabel("facilities")
    ax.legend(frameon=False, fontsize=9)
    ax.set_title("Difference distribution", fontsize=11)

    ax = axes[1]
    grp = head.groupby("project_area").pct_diff
    labs = [k for k, _ in grp]
    ax.axvline(0, color=C.INK, lw=1)
    jrng = np.random.default_rng(20260820)
    for i, (k, v) in enumerate(grp):
        ax.scatter(v, np.full(len(v), i) + jrng.uniform(-.13, .13, len(v)),
                   s=26, color=CAT_COLORS[i % len(CAT_COLORS)], alpha=.85, linewidths=0)
        ax.scatter([v.median()], [i], marker="|", s=420, color=C.INK, linewidths=1.6)
    ax.set_yticks(range(len(labs)))
    ax.set_yticklabels(labs, fontsize=8)
    ax.set_xlabel("% difference, 24 h 100 yr")
    ax.set_title("By Atlas 14 project area (bar = median)", fontsize=11)
    fig.suptitle(f"B1 {tag}: uniform L-moments vs NOAA Atlas 14 "
                 f"(n = {len(head)} facilities)", y=1.02)
    fig.tight_layout()
    FIGS.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIGS / f"b1_{tag}_diff_distribution.png")
    plt.close(fig)

    # Coverage map: every NID dam, coloured by the Atlas 14 volume its state
    # falls in, with the Atlas-2 legacy states called out.
    man = C.load_manifest()
    man = man.dropna(subset=["latitude", "longitude"])
    man = man[~man.state.isin(C.NON_CONUS)]
    man["coverage"] = man.state.map(coverage_label)
    fig, ax = C.conus_map_axes(plt, figsize=(11, 6.4))
    covs = [c for c in sorted(man.coverage.unique()) if c != ATLAS2_LABEL]
    for i, cov in enumerate(covs):
        m = man[man.coverage == cov]
        ax.scatter(m.longitude, m.latitude, s=1.2, linewidths=0, rasterized=True,
                   color=VOL_COLORS.get(cov, CAT_COLORS[i % len(CAT_COLORS)]),
                   label=f"{cov} ({len(m):,})")
    # Black is RESERVED for "no Atlas 14 anywhere" -- it is the headline stratum
    # and must not collide with a volume colour.
    m = man[man.coverage == ATLAS2_LABEL]
    ax.scatter(m.longitude, m.latitude, s=3.0, linewidths=0, rasterized=True,
               color="#000000", label=f"{ATLAS2_LABEL} ({len(m):,})")
    ax.set_xlim(-126, -66); ax.set_ylim(23.5, 50.5)
    ax.legend(frameon=False, fontsize=7.5, loc="lower left", ncol=2, markerscale=6)
    ax.set_title("NID dams by NOAA Atlas 14 coverage (CONUS); black = no Atlas 14",
                 fontsize=11)
    fig.tight_layout()
    fig.savefig(FIGS / "b1_coverage_map.png")
    plt.close(fig)


# ==================================================================== selftest
_SAMPLE_PDS = """Point precipitation frequency estimates (inches)
NOAA Atlas 14 Volume 12 Version 2
Data type: Precipitation depth
Time series type: Partial duration
Project area: Interior Northwest
Location name (ESRI Maps): None
Station Name: None
Latitude: 46.0583 Degree
Longitude: -114.2306 Degree
Elevation (USGS): None None


PRECIPITATION FREQUENCY ESTIMATES
by duration for ARI (years):, 1,2,5,10,25,50,100,200,500,1000
5-min:, 0.115,0.166,0.243,0.303,0.379,0.432,0.480,0.524,0.575,0.608
24-hr:, 1.20,1.37,1.64,1.85,2.13,2.34,2.55,2.75,3.00,3.18
3-day:, 1.60,1.81,2.16,2.44,2.82,3.11,3.39,3.67,4.04,4.30

Date/time (GMT):  Thu Aug 20 03:27:42 2026
"""
_SAMPLE_AMS = _SAMPLE_PDS.replace(
    "Time series type: Partial duration", "Time series type: Annual maximum").replace(
    "by duration for ARI (years):, 1,2,5,10,25,50,100,200,500,1000",
    "by duration for AEP:, '1/2,'1/5,'1/10,'1/25,'1/50,'1/100,'1/200,'1/500,'1/1000").replace(
    "5-min:, 0.115,0.166,0.243,0.303,0.379,0.432,0.480,0.524,0.575,0.608",
    "5-min:, 0.141,0.234,0.299,0.378,0.431,0.480,0.524,0.575,0.608").replace(
    "24-hr:, 1.20,1.37,1.64,1.85,2.13,2.34,2.55,2.75,3.00,3.18",
    "24-hr:, 1.29,1.60,1.83,2.13,2.34,2.55,2.75,3.00,3.18").replace(
    "3-day:, 1.60,1.81,2.16,2.44,2.82,3.11,3.39,3.67,4.04,4.30",
    "3-day:, 1.71,2.10,2.41,2.81,3.10,3.39,3.67,4.04,4.30")
_SAMPLE_NONE = ("\nresult = 'none';\nErrorMsg =  'Error 3.0: Selected location is not "
                "within a project area';\n")
_SAMPLE_H5 = ("\nresult = 'values';\nquantiles = [['1.20', '1.37'], ['1.60', '1.81']];\n"
              "upper = [['1.4', '1.6'], ['1.8', '2.0']];\nvolume = '12';\n"
              "region = 'Interior Northwest';\nser = 'pds';\n")


def cmd_selftest(a) -> int:
    fails = []

    def check(name, cond, extra=""):
        print(f"[{'PASS' if cond else 'FAIL'}] {name}{(' -- ' + extra) if extra else ''}")
        if not cond:
            fails.append(name)

    p = parse_pfds_csv(_SAMPLE_PDS)
    t = p["table"]
    v = t[(t.duration == "24-hr") & (t.ari_yr == 100)].depth_mm.iloc[0]
    check("PDS: 24h/100yr depth", abs(v - 2.55 * IN2MM) < 1e-9, f"{v:.3f} mm")
    check("PDS: header metadata", (p["meta"]["volume"] == 12
                                   and p["meta"]["series_type"] == "Partial duration"
                                   and p["meta"]["header_dialect"] == "ARI"))
    check("PDS: 1-yr ARI present", 1.0 in set(t.ari_yr))

    q = parse_pfds_csv(_SAMPLE_AMS)
    qt = q["table"]
    check("AMS: AEP header dialect", q["meta"]["header_dialect"] == "AEP")
    check("AMS: no 1-yr, T parsed from '1/T'",
          1.0 not in set(qt.ari_yr) and {2.0, 100.0, 1000.0} <= set(qt.ari_yr))
    a100 = qt[(qt.duration == "24-hr") & (qt.ari_yr == 100)].value.iloc[0]
    p100 = t[(t.duration == "24-hr") & (t.ari_yr == 100)].value.iloc[0]
    check("AMS==PDS at 100 yr (NOAA's Langbein conversion -> 1)", a100 == p100,
          f"{a100} in")
    a2 = qt[(qt.duration == "24-hr") & (qt.ari_yr == 2)].value.iloc[0]
    p2 = t[(t.duration == "24-hr") & (t.ari_yr == 2)].value.iloc[0]
    check("AMS!=PDS at 2 yr", a2 != p2, f"ams {a2} vs pds {p2} in")

    try:
        parse_pfds_csv(_SAMPLE_NONE)
        check("no-coverage body raises PFDSNoCoverage", False)
    except PFDSNoCoverage:
        check("no-coverage body raises PFDSNoCoverage", True)

    # a truncated row must be REFUSED, not silently mis-aligned
    bad = _SAMPLE_PDS.replace("24-hr:, 1.20,1.37,1.64,1.85,2.13,2.34,2.55,2.75,3.00,3.18",
                              "24-hr:, 1.20,1.37,1.64")
    try:
        parse_pfds_csv(bad)
        check("ragged row rejected", False)
    except PFDSParseError:
        check("ragged row rejected", True)

    h = parse_readh5(_SAMPLE_H5)
    check("readH5 matrices + metadata",
          h["quantiles"][0][0] == 1.20 and h["volume"] == "12" and len(h["upper"]) == 2)
    try:
        parse_readh5(_SAMPLE_NONE)
        check("readH5 no-coverage raises", False)
    except PFDSNoCoverage:
        check("readH5 no-coverage raises", True)

    check("dur_key mapping", dur_key("24-hr") == "24h" and dur_key("1-day") == "24h"
          and dur_key("3-day") == "72h" and dur_key("2-day") is None
          and dur_key("60-min") is None)
    check("hour label preferred over day synonym",
          _dur_rank("24-hr") < _dur_rank("1-day"))
    check("Atlas 2 states are OR+WA and absent from NOAA's own table",
          ATLAS2_STATES == {"OR", "WA"}
          and not (ATLAS2_STATES & set(NOAA_STATE_REGION)))

    print(f"\n{len(fails)} failure(s)" if fails else "\nall parser self-tests passed")
    return 1 if fails else 0


# ======================================================================== main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def polite(p):
        p.add_argument("--sleep", type=float, default=DEFAULT_SLEEP_S,
                       help="minimum seconds between network requests")
        p.add_argument("--jitter", type=float, default=DEFAULT_JITTER_S)
        return p

    s = sub.add_parser("selftest", help="offline parser tests (no network)")
    s.set_defaults(func=cmd_selftest)

    s = polite(sub.add_parser("coverage", help="probe Atlas 14 coverage by state"))
    s.add_argument("--per-state", type=int, default=2)
    s.add_argument("--states", default="", help="comma-separated subset")
    s.add_argument("--seed", type=int, default=20260820)
    s.set_defaults(func=cmd_coverage)

    s = sub.add_parser("frame", help="build the stratified sample frame")
    s.add_argument("--n", type=int, default=4000, help="full-run target size")
    s.add_argument("--pilot", action="store_true")
    s.add_argument("--pilot-n", type=int, default=40)
    s.add_argument("--pilot-bor", type=int, default=8,
                   help="BOR-overlap dams in the PILOT (the full run takes all ~300)")
    s.add_argument("--seed", type=int, default=20260820)
    s.set_defaults(func=cmd_frame)

    s = polite(sub.add_parser("fetch", help="polite, resumable PFDS fetch"))
    s.add_argument("--pilot", action="store_true")
    s.add_argument("--series", default="ams,pds")
    s.add_argument("--max", type=int, default=DEFAULT_MAX_PER_RUN,
                   help="hard cap on (facility, series) pairs fetched this invocation")
    s.set_defaults(func=cmd_fetch)

    s = polite(sub.add_parser("verify", help="QAQC D3 ground-truthing"))
    s.add_argument("--n", type=int, default=20)
    s.add_argument("--series", default="ams")
    s.add_argument("--tol-pct", type=float, default=0.0,
                   help="tolerance for an exact-value match (default: exact)")
    s.add_argument("--grids", action="store_true",
                   help="additionally sample NOAA's published ASCII grids")
    s.add_argument("--grid-sites-per-region", type=int, default=3)
    s.add_argument("--grid-regions", default="",
                   help="restrict the published-grid check to these region codes "
                        "(e.g. inw,mw,orb); empty = every region in the sample")
    s.add_argument("--grid-tol-pct", type=float, default=3.0)
    s.add_argument("--seed", type=int, default=20260820)
    s.set_defaults(func=cmd_verify)

    s = polite(sub.add_parser("atlas2", help="sample NOAA's 1973 Atlas 2 grids in OR/WA"))
    s.add_argument("--pilot", action="store_true")
    s.add_argument("--unit-check", action="store_true",
                   help="cross-border scale check against Atlas 14 Vol 12")
    s.set_defaults(func=cmd_atlas2)

    s = sub.add_parser("compare", help="L-moments vs Atlas 14 difference statistics")
    s.add_argument("--pilot", action="store_true")
    s.add_argument("--series", default="ams")
    s.set_defaults(func=cmd_compare)

    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    raise SystemExit(main())
