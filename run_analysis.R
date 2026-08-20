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
for (f in c("functions.R", "region_methods.R", "arf.R", "checks.R", "00_setup.R",
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

  # PHASE A -- region building and goodness-of-fit, per duration. Split out
  # from estimation so the distribution family can optionally be resolved
  # ACROSS durations before any depth is estimated (see phase A/B note below).
  phaseA <- list()
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

    phaseA[[lab]] <- list(dur = dur, ams_list = ams_list, scr = scr, hom = hom,
                          rd_final = rd_final, dsel = dsel)
  }

  # ---- optional: ONE distribution family across all durations -------------
  # Independent per-duration selection lets the 24-h and 72-h growth curves
  # cross in the extrapolated tail (72-h depth below 24-h depth, which is
  # physically impossible). See choose_single_family() in R/05_distribution.R
  # for the mechanism, the evidence, and why the aggregation is minimax.
  # Config-gated and OFF by default, so run 1, the golden fixture and the BOR
  # sets are bit-for-bit unaffected.
  if (isTRUE(as.logical(cfg$distribution_single_family %||% FALSE)) &&
      length(phaseA) > 1) {
    # An explicit human/config decision still wins: if any duration resolved
    # via expert review or a config override, that is a deliberate choice and
    # the consistency rule must not silently overrule it.
    forced <- Filter(function(p) !identical(p$dsel$source, "auto"), phaseA)
    if (length(forced)) {
      audit_log(sprintf(
        "Single-family: NOT applied -- %s resolved via %s, which takes precedence.",
        paste(names(forced), collapse = ", "),
        paste(unique(vapply(forced, function(p) p$dsel$source, character(1))), collapse = "/")))
    } else {
      sf <- choose_single_family(lapply(phaseA, function(p) p$dsel$Z),
                                 cfg$distributions)
      if (is.null(sf)) {
        audit_log("Single-family: no candidate has a finite |Z| at every duration; keeping per-duration selection.")
      } else {
        was <- vapply(phaseA, function(p) toupper(p$dsel$chosen), character(1))
        audit_log(sprintf(
          "Single-family: %s across all durations (minimax |Z|=%.3f; per-duration |Z| %s). Per-duration picks were %s.",
          toupper(sf$chosen), sf$score,
          paste(sprintf("%s=%.3f", names(sf$per_duration_absZ),
                        sf$per_duration_absZ), collapse = ", "),
          paste(sprintf("%s=%s", names(was), was), collapse = ", ")))
        for (lab in names(phaseA)) {
          Z <- phaseA[[lab]]$dsel$Z
          phaseA[[lab]]$dsel$chosen <- sf$chosen
          phaseA[[lab]]$dsel$acceptable <- isTRUE(abs(Z[sf$chosen]) <= 1.64)
          phaseA[[lab]]$dsel$source <- "single_family"
          phaseA[[lab]]$dsel$single_family <- sf$table
        }
      }
    }
  }

  # PHASE B -- estimation, uncertainty, plots and tables, per duration.
  for (lab in names(phaseA)) {
    pa       <- phaseA[[lab]]
    dur      <- pa$dur
    ams_list <- pa$ams_list
    scr      <- pa$scr
    hom      <- pa$hom
    rd_final <- pa$rd_final
    dsel     <- pa$dsel

    used_ids  <- rd_final$name
    used_meta <- meta_all[match(used_ids, meta_all$station_id), ]
    idxfl <- estimate_index_flood(used_meta, rd_final$l_1, cfg)

    est <- step06_estimation(rd_final, dsel$chosen, cfg, idxfl)
    # Distribution-choice sensitivity at the extreme tail (all candidates).
    tail_sens <- tail_sensitivity(rd_final, cfg$distributions, idxfl, T = 10000)
    unc <- step07_uncertainty(rd_final, est, cfg)

    ams_used <- ams_list[used_ids]
    figs <- step09_plots(rd_final, ams_used, dsel$chosen, est, unc, cfg, lab, out_dir)

    # Areal Reduction Factor (optional, additive): converts the point depth
    # toward a basin-average depth when a drainage area is configured for the
    # site (see R/arf.R, enrich_drainage_area.R). NEVER replaces depth_mm --
    # only adds depth_areal_mm alongside it. NA area -> arf_factor NA, no
    # areal column populated (graceful degrade; most facilities lack no data).
    area_km2 <- site_drainage_area_km2(cfg)
    arf_factor <- if (is.finite(area_km2)) compute_arf(area_km2, dur$days * 24, cfg) else NA_real_
    depth_areal_mm <- if (is.finite(area_km2)) unc$depth_mm * arf_factor else rep(NA_real_, length(unc$depth_mm))
    if (is.finite(area_km2))
      audit_log(sprintf("ARF [%s]: area=%.1f km2 (%.1f mi2), factor=%.4f (method=%s).",
                        lab, area_km2, cfg$site$drainage_area_mi2, arf_factor,
                        cfg$arf$method %||% "leclerc_schaake"))

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
      D = scr$D, Dcrit = scr$Dcrit,
      arf_area_km2 = area_km2, arf_factor = arf_factor, depth_areal_mm = depth_areal_mm)
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
