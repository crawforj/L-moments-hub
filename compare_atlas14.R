#!/usr/bin/env Rscript
# =============================================================================
# compare_atlas14.R  —  External cross-check: pipeline DDF vs NOAA Atlas 14.
#
# NOAA Atlas 14 (Precipitation-Frequency Data Server, PFDS) is the U.S.
# authoritative point-precipitation-frequency standard, itself an L-moments
# regional analysis. Comparing our depths to Atlas 14 at a dam's coordinates is
# the single most valuable EXTERNAL validation (see docs/VALIDATION.md). This
# script automates that comparison for one or many facilities.
#
# IMPORTANT: Atlas 14 is served from hdsc.nws.noaa.gov (a .gov host). Some
# environments (including the one this repo was built in) block .gov egress, so
# the live fetch will fail there -- run this from a network that can reach
# https://hdsc.nws.noaa.gov/pfds/. The script degrades gracefully offline and
# has a --selftest mode that verifies the parser with NO network.
#
# Usage:
#   Rscript compare_atlas14.R --selftest                 # offline parser test
#   Rscript compare_atlas14.R --lat 46.0583 --lon -114.2306 --id COMO_DAM
#   Rscript compare_atlas14.R --ddf data/nid_progress/all_facilities_DDF.csv \
#                             --manifest config/nid_manifest.csv [--max 50]
#
# Notes:
#   - Atlas 14 depths are point estimates; so are ours. Neither includes areal
#     reduction. Compare like-for-like.
#   - Atlas 14 tops out at the 1000-year ARI; we compare only overlapping return
#     periods (2..1000 yr). The 24h 100-yr depth is the headline comparison.
#   - Atlas 14 does NOT cover every state (e.g. parts of the NW/MT were added
#     later; some regions use older TP-40/Atlas 2). A 404/empty result means "no
#     Atlas 14 here", not a failure of our estimate.
#   - Coverage/units: this fetches the "mean" partial-duration-series depths in
#     english units (inches) and converts to mm.
# =============================================================================
suppressWarnings(suppressMessages({ ok <- requireNamespace("utils", quietly = TRUE) }))

IN2MM <- 25.4
`%||%` <- function(a, b) if (is.null(a) || length(a) != 1 || is.na(a) || !nzchar(as.character(a))) b else a

# ---- argument parsing (tiny) ----------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
getarg <- function(flag, default = NULL) {
  i <- match(flag, args); if (is.na(i) || i == length(args)) return(default); args[i + 1]
}
has <- function(flag) flag %in% args

# ---- Atlas 14 CSV parser ---------------------------------------------------
# The PFDS "fe_text_mean.csv" export is a small text block: some header lines,
# then a matrix whose first column is the duration label and whose remaining
# columns are depths (inches) by ARI. The ARI header row contains the years.
# We parse defensively: find the ARI header, then read duration rows.
parse_atlas14_csv <- function(txt) {
  lines <- unlist(strsplit(txt, "\n", fixed = TRUE))
  lines <- trimws(lines)
  # ARI header: a line listing return periods (contains several of these tokens)
  ari_line <- grep("(^|[^0-9])(1|2|5|10|25|50|100|200|500|1000)([^0-9]|$).*\\b(100|1000)\\b",
                   lines)
  # Prefer a line that mentions "ARI" or "years"; else the first numeric-heavy row.
  hdr_i <- {
    cand <- grep("ARI|year", lines, ignore.case = TRUE)
    cand <- cand[cand %in% ari_line]
    if (length(cand)) cand[1] else if (length(ari_line)) ari_line[1] else NA
  }
  if (is.na(hdr_i)) stop("could not locate the ARI header row in Atlas 14 output")
  split_csv <- function(s) trimws(unlist(strsplit(s, ",", fixed = TRUE)))
  hdr <- split_csv(lines[hdr_i])
  aris <- suppressWarnings(as.numeric(gsub("[^0-9.]", "", hdr)))
  ari_cols <- which(is.finite(aris) & aris >= 1)
  if (!length(ari_cols)) stop("no ARI columns parsed")
  out <- list()
  for (li in (hdr_i + 1):length(lines)) {
    row <- split_csv(lines[li]); if (!length(row) || row[1] == "") next
    dur <- row[1]
    if (!grepl("(min|hr|day)", dur, ignore.case = TRUE)) next
    vals <- suppressWarnings(as.numeric(gsub("[^0-9.]", "", row)))
    for (c in ari_cols) if (is.finite(vals[c]))
      out[[length(out) + 1]] <- data.frame(duration = dur, ari_yr = aris[c],
                                            depth_in = vals[c], stringsAsFactors = FALSE)
  }
  if (!length(out)) stop("no duration rows parsed")
  d <- do.call(rbind, out); d$depth_mm <- d$depth_in * IN2MM; d
}

# ---- normalise a duration label to a comparable key ("24h","72h") ----------
# Vectorised: accepts a scalar or a vector of duration labels.
dur_key <- function(x) {
  x <- tolower(as.character(x))
  out <- rep(NA_character_, length(x))
  out[grepl("24[ -]?hr|1[ -]?day", x)] <- "24h"
  out[grepl("48[ -]?hr|2[ -]?day", x)] <- "48h"
  out[grepl("72[ -]?hr|3[ -]?day", x)] <- "72h"
  out
}

# ---- live fetch (network) --------------------------------------------------
fetch_atlas14 <- function(lat, lon) {
  url <- sprintf(paste0("https://hdsc.nws.noaa.gov/cgi-bin/hdsc/new/",
                        "fe_text_mean.csv?lat=%s&lon=%s&data=depth&units=english&series=pds"),
                 lat, lon)
  txt <- tryCatch(paste(readLines(url, warn = FALSE), collapse = "\n"),
                  error = function(e) NULL)
  if (is.null(txt) || !nzchar(txt)) return(NULL)
  tryCatch(parse_atlas14_csv(txt), error = function(e) NULL)
}

# ---- compare one facility --------------------------------------------------
compare_one <- function(id, lat, lon, our) {
  a14 <- fetch_atlas14(lat, lon)
  if (is.null(a14)) {
    cat(sprintf("  %-14s (%.4f, %.4f): Atlas 14 unavailable (no coverage or no network)\n",
                id, as.numeric(lat), as.numeric(lon)))
    return(NULL)
  }
  a14$dk <- vapply(a14$duration, dur_key, character(1))
  a14 <- a14[!is.na(a14$dk), ]
  our$dk <- our$duration
  m <- merge(our, a14, by.x = c("dk", "return_period_yr"),
             by.y = c("dk", "ari_yr"), suffixes = c("_ours", "_a14"))
  if (!nrow(m)) { cat(sprintf("  %-14s: no overlapping duration/ARI with Atlas 14\n", id)); return(NULL) }
  m$pct_diff <- round(100 * (m$depth_mm_ours - m$depth_mm) / m$depth_mm, 1)
  m$facility_id <- id
  res <- m[order(m$dk, m$return_period_yr),
           c("facility_id","dk","return_period_yr","depth_mm_ours","depth_mm","pct_diff")]
  names(res) <- c("facility_id","duration","return_period_yr","ours_mm","atlas14_mm","pct_diff")
  print(res, row.names = FALSE)
  res
}

# ---- self-test (offline): prove the parser on an embedded sample -----------
selftest <- function() {
  sample <- paste(
    "Point precipitation frequency estimates (inches) - NOAA Atlas 14",
    "Latitude: 46.0583  Longitude: -114.2306",
    "by duration for ARI (years):, 1, 2, 5, 10, 25, 50, 100, 200, 500, 1000",
    "5-min:, 0.10, 0.12, 0.15, 0.18, 0.22, 0.25, 0.29, 0.33, 0.38, 0.42",
    "24-hr:, 1.10, 1.35, 1.72, 2.02, 2.44, 2.78, 3.14, 3.52, 4.05, 4.48",
    "3-day:, 1.40, 1.70, 2.14, 2.50, 3.00, 3.40, 3.82, 4.26, 4.86, 5.35",
    sep = "\n")
  d <- parse_atlas14_csv(sample)
  d24_100 <- d$depth_mm[dur_key(d$duration) %in% "24h" & d$ari_yr == 100]
  okp <- length(d24_100) == 1 && abs(d24_100 - 3.14 * IN2MM) < 1e-6 &&
         all(c("24h","72h") %in% unique(vapply(d$duration, dur_key, character(1))))
  cat(sprintf("[%s] parser self-test: 24h-100yr = %.1f mm (expected %.1f); durations parsed OK\n",
              if (okp) "PASS" else "FAIL", d24_100, 3.14 * IN2MM))
  quit(save = "no", status = if (okp) 0L else 1L)
}

# ---- main ------------------------------------------------------------------
if (has("--selftest")) selftest()

ddf_path <- getarg("--ddf")
our_all <- if (!is.null(ddf_path) && file.exists(ddf_path))
  utils::read.csv(ddf_path, stringsAsFactors = FALSE) else NULL

results <- list()
if (!is.null(getarg("--lat")) && !is.null(getarg("--lon"))) {
  id <- getarg("--id", "SITE"); lat <- getarg("--lat"); lon <- getarg("--lon")
  our <- if (!is.null(our_all)) our_all[toupper(our_all$site) == toupper(id) |
                                        our_all$site == id, ] else NULL
  if (is.null(our) || !nrow(our)) {
    cat("No pipeline DDF rows for this id in --ddf; fetching Atlas 14 only.\n")
    a <- fetch_atlas14(lat, lon)
    if (is.null(a)) cat("Atlas 14 unavailable (no coverage or no network).\n") else print(a)
  } else results[[id]] <- compare_one(id, lat, lon, our)
} else if (!is.null(our_all) && !is.null(getarg("--manifest"))) {
  man <- utils::read.csv(getarg("--manifest"), stringsAsFactors = FALSE)
  ids <- unique(our_all$site); maxn <- as.integer(getarg("--max", "25"))
  cat(sprintf("Comparing up to %d facilities to NOAA Atlas 14...\n", maxn))
  for (nm in utils::head(ids, maxn)) {
    row <- man[toupper(man$name) == toupper(nm), ][1, ]
    if (is.na(row$latitude)) next
    results[[nm]] <- compare_one(row$facility_id %||% nm, row$latitude, row$longitude,
                                 our_all[our_all$site == nm, ])
  }
} else {
  cat("Usage: --selftest | --lat L --lon L [--id ID --ddf FILE] |",
      "--ddf FILE --manifest FILE [--max N]\n")
  quit(save = "no", status = 2L)
}

res <- do.call(rbind, Filter(Negate(is.null), results))
if (!is.null(res) && nrow(res)) {
  out <- "outputs/atlas14_comparison.csv"; dir.create("outputs", showWarnings = FALSE)
  utils::write.csv(res, out, row.names = FALSE)
  h24 <- res[res$duration == "24h" & res$return_period_yr == 100, ]
  if (nrow(h24))
    cat(sprintf("\n24h-100yr vs Atlas 14: median abs diff %.1f%% across %d facilities. Wrote %s.\n",
                stats::median(abs(h24$pct_diff)), nrow(h24), out))
} else cat("\nNo comparisons produced (Atlas 14 unreachable here, or no coverage).\n")
