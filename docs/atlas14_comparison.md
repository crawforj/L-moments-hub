# NOAA Atlas 14 comparison protocol

The strongest **external** check on this pipeline is to compare its depths to
**NOAA Atlas 14**, the U.S. authoritative point-precipitation-frequency standard
(itself an L-moments regional analysis). `validate_reference.R` proves the method
reproduces the Hosking & Wallis textbook and an independent hand-calc; Atlas 14
is the complementary check that the **answer for a real site** lands where the
official product does. Run this before relying on any facility.

## Why it isn't run automatically here

Atlas 14 is served from `hdsc.nws.noaa.gov` (a `.gov` host). The environment this
repo was built in blocks `.gov` egress, so the fetch fails there by design. Run
`compare_atlas14.R` from a network that can reach `https://hdsc.nws.noaa.gov/pfds/`
— **confirmed reachable from a normal networked desktop 2026-08-11** (HTTP 200),
so this is genuinely runnable there, not just a documented aspiration. Hasn't
yet been run at fleet scale. The script degrades gracefully (reports
"unavailable") when it cannot connect, and its CSV parser is verified offline
via `--selftest`.

## How to run

```bash
# 0. Offline sanity check of the parser (no network needed)
Rscript compare_atlas14.R --selftest

# 1. One facility by coordinates, against our computed DDF
Rscript compare_atlas14.R --lat 46.0583 --lon -114.2306 --id COMO_DAM \
        --ddf data/nid_progress/all_facilities_DDF.csv

# 2. Many facilities: join the fleet DDF to the manifest coordinates
Rscript compare_atlas14.R --ddf data/nid_progress/all_facilities_DDF.csv \
        --manifest config/nid_manifest.csv --max 50
```

Output: a per-facility table of `ours_mm` vs `atlas14_mm` with `pct_diff` at each
overlapping duration/ARI, and `outputs/atlas14_comparison.csv`. The headline is
the **24-hour 100-year** depth.

## Interpreting the result

- **Both are point depths** with no areal reduction — a like-for-like comparison.
- **Overlap only to the 1000-year ARI** (Atlas 14's maximum). Our 2,000–10,000-yr
  estimates have no Atlas 14 counterpart; agreement at 100–1000 yr builds
  confidence but does not validate the far tail (use the tail-sensitivity table
  and PMP-based methods for that).
- **Expected agreement:** for a well-formed region in Atlas 14-covered terrain,
  24h-100yr depths within roughly ±10–20% are reassuring. Larger gaps warrant
  investigation before use — likely causes: a mis-located dam, a region crossing
  a climate/orographic boundary, gauge undercatch, a different season, or Atlas
  14 incorporating radar/short-duration data we do not.
- **No coverage ≠ failure.** Atlas 14 does not cover every area (e.g. some
  Northwest/Montana areas were added late; a few regions still rely on older
  TP-40 / NOAA Atlas 2). "Atlas 14 unavailable" means no benchmark exists there,
  not that our estimate is wrong.

Record the comparison result on the facility's
[`expert_review_checklist.md`](expert_review_checklist.md) (section 6).
