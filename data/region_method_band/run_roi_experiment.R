# =============================================================================
# run_roi_experiment.R — the region-of-influence (roi) experiment
# (docs/CLUSTER_FLEET_RESULTS.md, "The roi experiment").
#
# Hypothesis: the circular-vs-cluster spread concentrates in SMALL cluster
# regions (<18 stations: mean 26.7% vs >28 stations: 16.3% — a variance
# failure mode where each donor station has outsized leverage). `assignment:
# "roi"` (R/region_methods.R) ranks the whole prefilter pool by standardized
# attribute-space distance and takes the nearest N — no hard cluster
# boundaries, region size pinned near max_stations — so IF small-pool
# variance drives the spread, roi should collapse it at the worst facilities.
#
# Design: the 15 worst genuine-cluster facilities by T=10,000 yr band from
# data/region_method_band/bor308_band.csv, each re-run under region.method:
# cluster + region.cluster.assignment: "roi", compared against BOTH the
# circular baseline and the hard-cluster result (depths from the committed
# band table, so all three legs share the same elevation-consistent method).
#
# Run from the repo root:
#   Rscript data/region_method_band/run_roi_experiment.R
# Writes data/region_method_band/bor_roi_experiment.csv (committed).
# =============================================================================

root <- "."
if (!file.exists(file.path(root, "run_batch.R")))
  stop("Run from the repo root (run_batch.R not found).")
# run_batch.R / run_analysis.R derive THEIR root from Rscript's --file=
# argument, which here points at data/region_method_band/ — shadow
# commandArgs while sourcing so they resolve root to "." (the cwd, i.e. the
# repo root; also keeps run_batch.R's CLI block from firing), then unshadow.
commandArgs <- function(...) character(0)
source(file.path(root, "run_batch.R"))
rm(commandArgs)

# 15 worst genuine-cluster facilities by max T=10,000yr band across durations
# (from bor308_band.csv, band_source == "two_method"). Note FRENCH CANYON DAM
# (WA00433) and FRENCH CANYON (WA82901) are two manifest entries for what is
# evidently the same structure — both kept, and they act as an internal
# replication check on the method.
roi_ids <- c("CA10136",  # BRADBURY            94.6%
             "UT10117",  # BOR DEER CREEK      67.0%
             "ND00151",  # JAMESTOWN DAM       66.7%
             "CA10164",  # LAURO               65.2%
             "OR00098",  # OCHOCO              62.8%
             "WA00275",  # ROZA DIVERSION DAM  62.7%
             "UT10119",  # EAST CANYON         61.8%
             "WA00433",  # FRENCH CANYON DAM   60.3%
             "WA82901",  # FRENCH CANYON       60.3%
             "CO01660",  # MARYS LAKE DIKE 1   60.3%
             "ID00261",  # RESERVOIR A         60.1%
             "UT10131",  # BOR WANSHIP         58.2%
             "UT10116",  # BOR CAUSEY          55.7%
             "OR00585",  # ANDERSON-ROSE DIV.  55.4%
             "CO01670")  # WILLOW CREEK        53.9%

man <- utils::read.csv(file.path(root, "config", "facilities_BOR_cluster.csv"),
                       stringsAsFactors = FALSE)
sel <- man[match(roi_ids, man$facility_id), ]
if (anyNA(sel$facility_id)) stop("facility_id(s) missing from the manifest.")
tmp_man <- tempfile("roi_manifest_", fileext = ".csv")
utils::write.csv(sel, tmp_man, row.names = FALSE)

# Generate per-facility configs via the standard manifest path (inherits the
# cluster region_method from the manifest column), then override ONLY the
# cluster assignment rule to "roi". config/facilities/ is gitignored.
cfg_dir <- file.path(root, "config", "facilities", "roi_experiment")
paths <- gen_configs_from_manifest(tmp_man, out_dir = cfg_dir)
for (p in paths) {
  cfg <- yaml::read_yaml(p)
  cfg$region$cluster$assignment <- "roi"
  yaml::write_yaml(cfg, p)
}

rows <- list()
for (p in paths) {
  message("\n==== roi run: ", basename(p), " ====")
  n0 <- length(.audit_log_env$entries)
  res <- tryCatch(run_analysis(p), error = function(e) e)
  if (inherits(res, "error")) {
    message("ROI RUN FAILED: ", basename(p), " -- ", conditionMessage(res))
    next
  }
  # Did roi actually engage, or did cluster_candidates() fall back to the
  # circular method for this site (e.g. the attribute-nearest neighborhood
  # lies outside region.elevation_band_m)? A fallback run's depths equal the
  # circular baseline BY CONSTRUCTION and must not be read as "roi agrees
  # with circular" — record it so the comparison can separate the two.
  new_log <- .audit_log_env$entries[seq_len(length(.audit_log_env$entries)) > n0]
  engaged <- !any(grepl("falling back to circular", new_log, fixed = TRUE))
  diag <- facility_diagnostics(res)
  d10 <- res$ddf[res$ddf$return_period_yr == 10000, c("site", "duration", "depth_mm")]
  names(d10)[3] <- "depth_roi_mm"
  d10$site_id <- res$cfg$site$id
  d10$n_stations_roi <- diag$n_stations[match(d10$duration, diag$duration)]
  d10$roi_engaged <- engaged
  rows[[length(rows) + 1]] <- d10
}
roi <- do.call(rbind, rows)

# Compare against BOTH prior methods at T=10,000 (depths from the committed
# band table — same elevation-consistent index-flood method on every leg).
band <- utils::read.csv(file.path(root, "data", "region_method_band", "bor308_band.csv"),
                        stringsAsFactors = FALSE)
b10 <- band[band$return_period_yr == 10000,
            c("site_id", "duration", "depth_circular_mm", "depth_cluster_mm", "band_pct")]
m <- merge(roi, b10, by = c("site_id", "duration"))

pct <- function(a, b) round(100 * abs(a - b) / pmax(a, b), 2)
m$roi_vs_circular_pct <- pct(m$depth_roi_mm, m$depth_circular_mm)
m$roi_vs_cluster_pct  <- pct(m$depth_roi_mm, m$depth_cluster_mm)
lo <- pmin(m$depth_circular_mm, m$depth_cluster_mm)
hi <- pmax(m$depth_circular_mm, m$depth_cluster_mm)
m$roi_within_band <- m$depth_roi_mm >= lo & m$depth_roi_mm <= hi
m$roi_closer_to <- ifelse(m$roi_vs_circular_pct <= m$roi_vs_cluster_pct,
                          "circular", "cluster")

m <- m[order(-m$band_pct, m$site, m$duration),
       c("site", "site_id", "duration", "roi_engaged", "n_stations_roi",
         "depth_circular_mm", "depth_cluster_mm", "depth_roi_mm",
         "band_pct", "roi_vs_circular_pct", "roi_vs_cluster_pct",
         "roi_within_band", "roi_closer_to")]
out <- file.path(root, "data", "region_method_band", "bor_roi_experiment.csv")
utils::write.csv(m, out, row.names = FALSE)

message(sprintf("\nWrote %s (%d rows).", out, nrow(m)))
message(sprintf("roi fell back to circular (excluded from the roi verdict): %s",
                paste(unique(m$site[!m$roi_engaged]), collapse = ", ") %||% "none"))
e <- m[m$roi_engaged, ]
message(sprintf("ENGAGED rows (n=%d): circular-vs-cluster band median %.1f%%",
                nrow(e), stats::median(e$band_pct)))
message(sprintf("roi vs circular: median %.1f%% | roi vs cluster: median %.1f%%",
                stats::median(e$roi_vs_circular_pct), stats::median(e$roi_vs_cluster_pct)))
message(sprintf("roi within the two-method band: %d/%d rows; closer to circular: %d, to cluster: %d",
                sum(e$roi_within_band), nrow(e),
                sum(e$roi_closer_to == "circular"), sum(e$roi_closer_to == "cluster")))
message(sprintf("roi region sizes (engaged): %s",
                paste(sort(unique(e$n_stations_roi)), collapse = ", ")))
