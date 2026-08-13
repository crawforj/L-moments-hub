# =============================================================================
# qc_ghcnm_crosscheck.R  —  Reconcile GHCN-Daily against GHCN-Monthly
#
# Answers a real, previously-undocumented gap (see DATA_SOURCES.md sec.1):
# this pipeline trusts GHCN-Daily's own QFLAG-based QA, but never checked
# whether the digital daily archive agrees with an INDEPENDENTLY-sourced
# monthly record. GHCN-Daily's automated QA catches internal-consistency
# problems (impossible values, duplicates); it does not guarantee agreement
# with what was actually printed in the original station publications.
#
# GHCN-Monthly (a separately-maintained NOAA product, not derived from this
# project's GHCN-Daily pull) tags every station-month with a SOURCE flag.
# Critically, many station-months have source flag "D" ("All sources within
# GHCN daily") -- comparing those against our own GHCN-Daily aggregation
# would just be comparing GHCN-Daily against itself, not an independent
# check. Only non-"D" sources (H=USHCN, M=Monthly Climatic Data for the
# World -- the actual historical published bulletins, S=GSOD, R=International)
# are genuinely independent, and this script only cross-checks those.
#
# Separately (regardless of source), GHCN-Monthly runs its OWN quality
# control and flags outliers (O), world-record exceedances (R), spatial
# inconsistency vs. neighbors (T), and day-count inconsistency for
# daily-sourced records (S) -- these are NOAA's own institutional QC
# signals and are surfaced here even when this script can't independently
# recompute them.
#
# This is a REVIEW tool, not an auto-correction: it writes a CSV of flagged
# station-months for a human to look at, same discipline as this project's
# discordancy/distribution-review worklists. It does not modify any GHCN
# cache file or fleet result.
#
# Requires the GHCN-Monthly precipitation archive extracted locally (NOT
# committed -- ~130,000 station files, too large; public/free/refetchable):
#   curl -o ghcnm_prcp.tar.gz -A "Mozilla/5.0" \
#     https://www.ncei.noaa.gov/data/ghcnm/v4/precipitation/archive/ghcn-m_v4.00.00_prcp_s16970101_e20260731_c20260804.tar.gz
#   tar xzf ghcnm_prcp.tar.gz -C <ghcnm_dir>
# (the archive filename/date-range changes each month; check
# https://www.ncei.noaa.gov/data/ghcnm/v4/precipitation/archive/ for the
# current one.)
#
# Usage:
#   Rscript qc_ghcnm_crosscheck.R --ghcnm-dir <path> [--limit N] [--tol-pct 15]
#
# Output: data/qc/ghcnm_crosscheck_flagged.csv
# =============================================================================

suppressWarnings(for (loc in c("C.UTF-8", "en_US.UTF-8", "C.utf8"))
  if (!is.na(Sys.setlocale("LC_CTYPE", loc)) && Sys.setlocale("LC_CTYPE", loc) != "") break)
root <- normalizePath(dirname(sub("--file=", "", grep("--file=", commandArgs(FALSE), value = TRUE)[1])), mustWork = FALSE)
if (!nzchar(root)) root <- "."
source(file.path(root, "R", "functions.R"))

REL_TOL_DEFAULT <- 15    # percent; below this, a digitization-era rounding/
                          # unit-quirk difference isn't worth a human's time
MIN_MM_FOR_PCT_CHECK <- 10  # percent-based tolerance is meaningless for
                             # near-zero months; use an absolute floor instead
ABS_TOL_MM <- 5

parse_ghcnm_station_file <- function(path) {
  d <- tryCatch(
    utils::read.csv(path, header = FALSE, stringsAsFactors = FALSE, strip.white = TRUE,
                    col.names = c("station_id", "name", "lat", "lon", "elev",
                                  "yyyymm", "value_tenths_mm", "mflag", "qcflag",
                                  "sflag", "source_index")),
    error = function(e) NULL)
  if (is.null(d) || !nrow(d)) return(NULL)
  d$year <- as.integer(substr(d$yyyymm, 1, 4))
  d$month <- as.integer(substr(d$yyyymm, 5, 6))
  d$value_mm <- ifelse(d$value_tenths_mm == -1, NA, d$value_tenths_mm / 10)  # -1 = trace
  d
}

monthly_totals_from_daily_cache <- function(cache_gz, min_complete = 0.9) {
  cc <- tryCatch(utils::read.csv(gzfile(cache_gz), stringsAsFactors = FALSE), error = function(e) NULL)
  if (is.null(cc) || !nrow(cc) || !all(c("date", "prcp") %in% names(cc))) return(NULL)
  cc$date <- as.Date(cc$date)
  # Same QFLAG screening this project already applies before computing annual
  # maxima -- comparing against GHCN-Monthly should use the same screened
  # series the fleet actually analyzed, not a different, unscreened one.
  q <- if ("qflag" %in% names(cc)) cc$qflag else NULL
  cc$prcp <- as.numeric(screen_qflag(as.numeric(cc$prcp), q, screen = TRUE))
  cc$year <- as.integer(format(cc$date, "%Y"))
  cc$month <- as.integer(format(cc$date, "%m"))
  cc$days_in_month <- lubridate_days_in_month(cc$year, cc$month)
  agg <- stats::aggregate(prcp ~ year + month, data = cc, FUN = function(x) sum(x, na.rm = TRUE))
  present <- stats::aggregate(prcp ~ year + month, data = cc, FUN = function(x) sum(!is.na(x)))
  names(present)[3] <- "days_present"
  m <- merge(agg, present, by = c("year", "month"))
  dim <- stats::aggregate(days_in_month ~ year + month, data = cc, FUN = function(x) x[1])
  m <- merge(m, dim, by = c("year", "month"))
  m <- m[m$days_present / m$days_in_month >= min_complete, ]
  names(m)[names(m) == "prcp"] <- "our_monthly_mm"
  m
}

lubridate_days_in_month <- function(year, month) {
  # Avoid adding lubridate as a dependency for one calculation.
  nxt <- ifelse(month == 12, as.Date(paste0(year + 1, "-01-01")),
                as.Date(paste0(year, "-", month + 1, "-01")))
  as.integer(as.Date(nxt) - as.Date(paste0(year, "-", month, "-01")))
}

check_one_station <- function(station_id, cache_gz, ghcnm_dir, tol_pct) {
  ours <- monthly_totals_from_daily_cache(cache_gz)
  if (is.null(ours) || !nrow(ours)) return(NULL)

  ghcnm_path <- file.path(ghcnm_dir, paste0(station_id, ".csv"))
  if (!file.exists(ghcnm_path)) return(NULL)  # not every GHCN-Daily station is in GHCN-Monthly
  ghcnm <- parse_ghcnm_station_file(ghcnm_path)
  if (is.null(ghcnm)) return(NULL)

  m <- merge(ours, ghcnm, by = c("year", "month"))
  if (!nrow(m)) return(NULL)

  flagged <- list()

  # 1. Independent-source cross-check: only where GHCN-Monthly's value did
  #    NOT itself come from GHCN-Daily.
  indep <- m[!is.na(m$sflag) & m$sflag != "D" & !is.na(m$value_mm), ]
  if (nrow(indep)) {
    indep$pct_diff <- 100 * (indep$our_monthly_mm - indep$value_mm) / pmax(indep$value_mm, 0.1)
    indep$abs_diff_mm <- abs(indep$our_monthly_mm - indep$value_mm)
    bad <- indep[(indep$value_mm >= MIN_MM_FOR_PCT_CHECK & abs(indep$pct_diff) > tol_pct) |
                 (indep$value_mm < MIN_MM_FOR_PCT_CHECK & indep$abs_diff_mm > ABS_TOL_MM), ]
    if (nrow(bad))
      flagged[["independent_source_mismatch"]] <- data.frame(
        station_id = station_id, year = bad$year, month = bad$month,
        our_monthly_mm = round(bad$our_monthly_mm, 1), ghcnm_mm = round(bad$value_mm, 1),
        pct_diff = round(bad$pct_diff, 1), ghcnm_source_flag = bad$sflag,
        ghcnm_qc_flag = bad$qcflag, reason = "independent_source_mismatch")
  }

  # 2. NOAA's own institutional QC flags, regardless of source -- surfaced
  #    even when we can't independently verify the number ourselves.
  noaa_flagged <- m[!is.na(m$qcflag) & m$qcflag %in% c("O", "R", "T", "S"), ]
  if (nrow(noaa_flagged))
    flagged[["noaa_institutional_flag"]] <- data.frame(
      station_id = station_id, year = noaa_flagged$year, month = noaa_flagged$month,
      our_monthly_mm = round(noaa_flagged$our_monthly_mm, 1), ghcnm_mm = round(noaa_flagged$value_mm, 1),
      pct_diff = NA, ghcnm_source_flag = noaa_flagged$sflag,
      ghcnm_qc_flag = noaa_flagged$qcflag, reason = "noaa_institutional_flag")

  if (!length(flagged)) return(NULL)
  do.call(rbind, flagged)
}

main <- function() {
  args <- commandArgs(trailingOnly = TRUE)
  get_arg <- function(flag, default = NULL) {
    i <- which(args == flag)
    if (length(i) && i < length(args)) args[i + 1] else default
  }
  ghcnm_dir <- get_arg("--ghcnm-dir")
  if (is.null(ghcnm_dir)) stop("Usage: Rscript qc_ghcnm_crosscheck.R --ghcnm-dir <path> [--limit N] [--tol-pct 15]")
  limit <- get_arg("--limit")
  tol_pct <- as.numeric(get_arg("--tol-pct", REL_TOL_DEFAULT))

  cache_dir <- file.path(root, "data", "ghcn_prcp_cache")
  files <- list.files(cache_dir, pattern = "\\.csv\\.gz$", full.names = TRUE)
  if (!is.null(limit)) files <- files[seq_len(min(as.integer(limit), length(files)))]
  station_ids <- sub("\\.csv\\.gz$", "", basename(files))

  message(sprintf("Cross-checking %d cached stations against GHCN-Monthly (%s)...", length(files), ghcnm_dir))
  results <- list()
  n_checked <- 0L
  n_no_ghcnm <- 0L
  for (i in seq_along(files)) {
    r <- tryCatch(check_one_station(station_ids[i], files[i], ghcnm_dir, tol_pct),
                  error = function(e) NULL)
    if (!is.null(r)) results[[station_ids[i]]] <- r
    if (file.exists(file.path(ghcnm_dir, paste0(station_ids[i], ".csv")))) n_checked <- n_checked + 1L
    else n_no_ghcnm <- n_no_ghcnm + 1L
    if (i %% 500 == 0) message(sprintf("  %d/%d stations processed...", i, length(files)))
  }

  out_dir <- file.path(root, "data", "qc")
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  out_path <- file.path(out_dir, "ghcnm_crosscheck_flagged.csv")
  if (length(results)) {
    all_flagged <- do.call(rbind, results)
    utils::write.csv(all_flagged, out_path, row.names = FALSE)
    message(sprintf("\n%d station-months flagged across %d stations (of %d matched in GHCN-Monthly, %d not present there).",
                    nrow(all_flagged), length(results), n_checked, n_no_ghcnm))
    message(sprintf("  independent_source_mismatch: %d", sum(all_flagged$reason == "independent_source_mismatch")))
    message(sprintf("  noaa_institutional_flag:      %d", sum(all_flagged$reason == "noaa_institutional_flag")))
  } else {
    utils::write.csv(data.frame(), out_path, row.names = FALSE)
    message("\nNo discrepancies flagged.")
  }
  message(sprintf("Wrote %s", out_path))
}

if (sys.nframe() == 0) main()
