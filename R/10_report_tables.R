# =============================================================================
# 10_report_tables.R  —  Write deliverable CSV tables + station lists
#
# Objective : persist every numeric deliverable as a documented CSV in
#             outputs/tables/, including the station-used and station-removed
#             lists, regional L-moments, the goodness-of-fit table, the growth
#             curves, and the depth-duration-frequency quantiles with bounds.
# Inputs    : results (assembled by run_analysis.R), out_dir
# Outputs   : named list of written file paths
# =============================================================================

step10_tables <- function(results, out_dir) {
  cfg <- results$cfg
  id  <- cfg$site$id
  tdir <- file.path(out_dir, "tables")
  written <- character(0)
  wr <- function(df, name) {
    p <- file.path(tdir, name)
    utils::write.csv(df, p, row.names = FALSE)
    written <<- c(written, p); p
  }

  # Combined DDF across durations (headline deliverable).
  idxfl_method <- cfg$index_flood$method %||% "regression"
  arf_method <- cfg$arf$method %||% "leclerc_schaake"
  ddf <- do.call(rbind, lapply(names(results$per_duration), function(lab) {
    pd <- results$per_duration[[lab]]
    u <- pd$unc
    data.frame(site = cfg$site$name, duration = lab,
               return_period_yr = u$T, AEP = round(1 - u$F, 6),
               depth_mm = round(u$depth_mm, 2),
               depth_lo_mm = round(u$depth_lo, 2),
               depth_hi_mm = round(u$depth_hi, 2),
               rel_rmse = round(u$rel_rmse, 3),
               # ASM = at-site mean annual maximum, i.e. the H&W index flood
               # transferred to this (ungauged) site — see estimate_index_flood()
               # in functions.R. Constant within a duration, repeated per row so
               # the headline DDF table is self-contained for a reviewer.
               index_flood_asm_mm = round(pd$est$index_flood, 2),
               index_flood_method = idxfl_method,
               # ARF: additive, NEVER replaces depth_mm (still the point depth).
               # NA whenever the facility has no configured drainage area — see
               # R/arf.R and enrich_drainage_area.R.
               depth_areal_mm = round(pd$depth_areal_mm, 2),
               arf_factor = round(pd$arf_factor, 4),
               arf_area_km2 = round(pd$arf_area_km2, 1),
               arf_method = ifelse(is.finite(pd$arf_factor), arf_method, NA_character_))
  }))
  wr(ddf, sprintf("quantiles_DDF_%s.csv", id))

  # Master station disposition table (used per duration + removal reason).
  wr(results$stations_master, sprintf("stations_master_%s.csv", id))

  # Per-duration detail.
  for (lab in names(results$per_duration)) {
    pd <- results$per_duration[[lab]]
    wr(pd$used_table,    sprintf("stations_used_%s_%s.csv", id, lab))
    wr(pd$removed_table, sprintf("stations_removed_%s_%s.csv", id, lab))
    wr(data.frame(station = pd$regdata_final$name, n = pd$regdata_final$n,
                  mean = round(pd$regdata_final$l_1, 3),
                  Lcv = round(pd$regdata_final$t, 4),
                  Lskew = round(pd$regdata_final$t_3, 4),
                  Lkurt = round(pd$regdata_final$t_4, 4)),
       sprintf("regional_Lmoments_%s_%s.csv", id, lab))
    wr(pd$dist_sel$table, sprintf("gof_Zstatistic_%s_%s.csv", id, lab))
    wr(pd$est$growth,     sprintf("growth_curve_%s_%s.csv", id, lab))
    wr(pd$homog_history,  sprintf("homogeneity_history_%s_%s.csv", id, lab))
  }

  audit_log(sprintf("Wrote %d deliverable tables to %s.", length(written), tdir))
  list(paths = written, ddf = ddf)
}
