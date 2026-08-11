#!/usr/bin/env Rscript
# =============================================================================
# run_analysis.R  —  Master pipeline for regional precipitation frequency
#                    analysis by L-moments (Hosking & Wallis 1997).
#
# Usage : Rscript run_analysis.R [config/como.yml]
#
# Runs the full pipeline (steps 00..11) for the site named in the config and
# writes all deliverables to outputs/. Portable: point it at a different config
# to analyse a different basin (see docs/users_guide.md, and run_batch.R to
# process many facilities).
# =============================================================================

# Ensure a UTF-8 locale so config/source files read correctly on minimal hosts.
suppressWarnings(for (loc in c("C.UTF-8", "en_US.UTF-8", "C.utf8"))
  if (!is.na(Sys.setlocale("LC_CTYPE", loc)) && Sys.setlocale("LC_CTYPE", loc) != "") break)

suppressWarnings(suppressMessages({
  root <- tryCatch(dirname(sub("--file=", "",
    grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
  if (is.na(root) || root == "") root <- "."
}))
options(lmc.root = root)
for (f in c("functions.R", "checks.R", "00_setup.R",
            "01_data_acquisition.R", "02_lmoments.R", "03_screening.R",
            "04_homogeneity.R", "05_distribution.R", "06_estimation.R",
            "07_uncertainty.R", "08_mapping.R", "09_plots.R",
            "10_report_tables.R", "11_audit_report.R"))
  source(file.path(root, "R", f))

# ---- run_analysis(): execute the whole pipeline for one config -------------
run_analysis <- function(config_path = "config/como.yml") {
  cfg <- setup_analysis(config_path)
  out_dir <- file.path(root, "outputs")
  stamp <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  audit_log(sprintf("=== %s : %s ===", cfg$site$name, stamp))

  s1 <- step01_acquire(cfg)
  meta_all <- s1$meta_all

  per_duration <- list()
  used_any <- character(0)
  last_regdata <- NULL

  for (dur in cfg$durations) {
    lab <- dur$label
    audit_log(sprintf("--- Duration %s ---", lab))
    ams_list <- s1$ams[[lab]]

    rd0 <- step02_lmoments(ams_list)
    scr <- step03_screening(rd0, cfg)
    hom <- step04_homogeneity(scr$regdata, cfg)
    rd_final <- hom$regdata
    last_regdata <- rd_final

    dsel <- step05_distribution(hom$tst, cfg, duration_label = lab,
                                review = cfg$distribution_review)

    used_ids  <- rd_final$name
    used_meta <- meta_all[match(used_ids, meta_all$station_id), ]
    idxfl <- estimate_index_flood(used_meta, rd_final$l_1, cfg)

    est <- step06_estimation(rd_final, dsel$chosen, cfg, idxfl)
    # Distribution-choice sensitivity at the extreme tail (all candidates).
    tail_sens <- tail_sensitivity(rd_final, cfg$distributions, idxfl, T = 10000)
    unc <- step07_uncertainty(rd_final, est, cfg)

    ams_used <- ams_list[used_ids]
    figs <- step09_plots(rd_final, ams_used, dsel$chosen, est, unc, cfg, lab, out_dir)

    # Reconcile station counts for this duration (audit invariant 9.2).
    n_cand_dur <- nrow(meta_all)
    used_table <- data.frame(
      station_id = used_meta$station_id, name = used_meta$name,
      lat = used_meta$lat, lon = used_meta$lon, elev_m = used_meta$elev_m,
      distance_km = round(used_meta$distance_km, 1),
      n_years = rd_final$n, mean_mm = round(rd_final$l_1, 2),
      stringsAsFactors = FALSE)

    removed_table <- rbind(
      s1$removed_geo[, c("station_id", "name", "reason")],
      if (nrow(s1$removed_short)) s1$removed_short[, c("station_id", "name", "reason")] else NULL,
      if (nrow(scr$removed)) scr$removed[, c("station_id", "name", "reason")] else NULL,
      if (nrow(hom$removed)) hom$removed[, c("station_id", "name", "reason")] else NULL)
    removed_table <- unique(removed_table)
    check_station_reconcile(n_cand_dur, nrow(used_table),
                            nrow(meta_all) - nrow(used_table))

    per_duration[[lab]] <- list(
      regdata_final = rd_final, dist_sel = dsel, est = est, unc = unc,
      tail_sensitivity = tail_sens,
      H = hom$H, homog_status = hom$status, homog_history = hom$history,
      ams_used = ams_used, figs = figs,
      used_table = used_table, removed_table = removed_table,
      D = scr$D, Dcrit = scr$Dcrit)
    used_any <- union(used_any, used_ids)
  }

  # Master station disposition (used in >=1 duration vs removed) + map.
  used_union_meta <- meta_all[meta_all$station_id %in% used_any, ]
  removed_union_meta <- meta_all[!(meta_all$station_id %in% used_any), ]
  master <- meta_all[, c("station_id", "name", "lat", "lon", "elev_m", "distance_km")]
  master$distance_km <- round(master$distance_km, 1)
  for (lab in names(per_duration))
    master[[paste0("used_", lab)]] <-
      ifelse(master$station_id %in% per_duration[[lab]]$used_table$station_id, "Y", "N")
  master$disposition <- ifelse(master$station_id %in% used_any, "used", "removed")

  map_path <- step08_map(used_union_meta, removed_union_meta, cfg, out_dir)

  results <- list(cfg = cfg, per_duration = per_duration,
                  stations_master = master, map_path = map_path, ddf = NULL)

  tab <- step10_tables(results, out_dir)
  results$ddf <- tab$ddf

  manifest <- write_manifest(cfg, config_path, last_regdata, out_dir, stamp)
  report <- step11_report(results, manifest, out_dir)
  audit_log_write(file.path(out_dir, "provenance",
                            paste0("audit_log_", cfg$site$id, ".txt")))

  message("\nDONE. Headline results:")
  print(results$ddf[results$ddf$return_period_yr %in% c(100, 1000, 10000), ])
  message("\nReport: ", report)
  invisible(results)
}

# Command-line entry point — runs ONLY when this file is the script Rscript was
# given (not when it is source()d by run_golden.R / run_batch.R / tests).
.invoked_as_main <- function(fname) {
  fa <- grep("--file=", commandArgs(FALSE), value = TRUE)
  length(fa) > 0 && basename(sub("--file=", "", fa[1])) == fname
}
if (.invoked_as_main("run_analysis.R")) {
  args <- commandArgs(trailingOnly = TRUE)
  cfgp <- if (length(args) >= 1) args[1] else file.path(root, "config", "como.yml")
  run_analysis(cfgp)
}
