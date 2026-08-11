#!/usr/bin/env Rscript
# =============================================================================
# compare_regions.R  —  How much does the region-BUILDING method move the DDF
#                        curve, for one facility?
#
# Reclamation reviewer feedback called region construction "one of the most
# influential points in the L-moments analysis" and asked for alternatives to
# the current circular-radius method (see R/region_methods.R). This script
# answers that directly: run the SAME facility's full pipeline once per
# region.method, and report how the region (station count, H1, chosen
# distribution, depth at each return period) moves — the same "run every
# candidate, diff the tail" idea as tail_sensitivity.csv, one level up
# (candidate REGIONS instead of candidate distributions).
#
# Usage:
#   Rscript compare_regions.R config/como.yml circular,cluster
#   Rscript compare_regions.R config/como.yml                    # methods default to circular,cluster
#
# Deliberately NOT part of run_batch.R / run_nid_tranche.R — this is an
# expert-invoked comparison tool, not a nightly-cron step, so the 73k-dam
# fleet batch stays cost-neutral (see docs/PLAN.md region section, Phase 1).
# =============================================================================
suppressWarnings(for (loc in c("C.UTF-8", "en_US.UTF-8", "C.utf8"))
  if (!is.na(Sys.setlocale("LC_CTYPE", loc)) && Sys.setlocale("LC_CTYPE", loc) != "") break)

root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
root <- normalizePath(root)
setwd(root)
source(file.path(root, "run_analysis.R"))

# compare_regions(config_path, methods): runs run_analysis() once per method
# (each writing to its own outputs/<id>_<method>/... via a temp per-method
# config so runs never clobber each other), and returns the combined
# sensitivity table (also written to outputs/tables/).
compare_regions <- function(config_path, methods = c("circular", "cluster")) {
  base_cfg <- yaml::read_yaml(config_path)
  base_id  <- base_cfg$site$id %||% "SITE"
  tmp_dir  <- file.path(root, "config", "_compare_regions_tmp")
  dir.create(tmp_dir, showWarnings = FALSE, recursive = TRUE)

  rows <- list()
  for (method in methods) {
    cfg <- base_cfg
    cfg$region$method <- method
    cfg$site$id <- paste0(base_id, "__", method)
    cfg_path <- file.path(tmp_dir, paste0(cfg$site$id, ".yml"))
    yaml::write_yaml(cfg, cfg_path)

    message(sprintf("\n=== region.method = %s ===", method))
    res <- tryCatch(run_analysis(cfg_path), error = function(e) {
      message("  FAILED: ", conditionMessage(e)); NULL
    })
    if (is.null(res)) next

    for (lab in names(res$per_duration)) {
      pd <- res$per_duration[[lab]]
      rows[[length(rows) + 1]] <- data.frame(
        facility = base_cfg$site$name, duration = lab, method = method,
        n_stations = nrow(pd$regdata_final), H1 = round(pd$H[1], 3),
        homog_status = pd$homog_status, chosen_dist = toupper(pd$dist_sel$chosen),
        index_flood_asm_mm = round(pd$est$index_flood, 2),
        T = pd$unc$T, depth_mm = round(pd$unc$depth_mm, 2),
        stringsAsFactors = FALSE)
    }
  }
  if (!length(rows)) stop("No method produced results -- nothing to compare.")
  out <- do.call(rbind, rows)

  # Spread across methods, per duration x return period -- the "how much does
  # this decision move the number" summary (same intent as tail_sensitivity's
  # tail_spread_pct, one level up).
  spread <- do.call(rbind, lapply(split(out, list(out$duration, out$T)), function(g) {
    if (!nrow(g)) return(NULL)
    data.frame(duration = g$duration[1], T = g$T[1],
               depth_min_mm = min(g$depth_mm), depth_max_mm = max(g$depth_mm),
               spread_pct = round(100 * (max(g$depth_mm) - min(g$depth_mm)) / max(g$depth_mm), 1))
  }))
  spread <- spread[order(spread$duration, spread$T), ]

  tdir <- file.path(root, "outputs", "tables")
  dir.create(tdir, showWarnings = FALSE, recursive = TRUE)
  out_path <- file.path(tdir, sprintf("%s_region_method_sensitivity.csv", base_id))
  spread_path <- file.path(tdir, sprintf("%s_region_method_spread.csv", base_id))
  utils::write.csv(out, out_path, row.names = FALSE)
  utils::write.csv(spread, spread_path, row.names = FALSE)
  message(sprintf("\nWrote %s\nWrote %s", out_path, spread_path))
  message("\nSpread across methods (biggest is where the choice matters most):")
  print(spread[order(-spread$spread_pct), ], row.names = FALSE)
  invisible(list(detail = out, spread = spread))
}

.invoked_as_main <- function(fname) {
  fa <- grep("--file=", commandArgs(FALSE), value = TRUE)
  length(fa) > 0 && basename(sub("--file=", "", fa[1])) == fname
}
if (.invoked_as_main("compare_regions.R")) {
  args <- commandArgs(trailingOnly = TRUE)
  cfgp <- if (length(args) >= 1) args[1] else file.path(root, "config", "como.yml")
  methods <- if (length(args) >= 2) strsplit(args[2], ",")[[1]] else c("circular", "cluster")
  compare_regions(cfgp, methods)
}
