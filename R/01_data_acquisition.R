# =============================================================================
# 01_data_acquisition.R  —  Acquire station data and build annual-maximum series
#
# Objective : obtain daily (or pre-built AMS) precipitation for candidate
#             stations, apply the region/quality filters, and construct the
#             seasonal, fixed-interval-corrected annual-maximum series (AMS) for
#             each requested duration.
# Inputs    : cfg (configuration)
# Outputs   : state$ams   -> per-duration named list of data.frame(year,value)
#             state$meta  -> station metadata used at this stage
#             state$removed_geo -> stations removed by radius/elevation/length
# Reference : H&W ch. 2 (data and index-flood series construction).
# =============================================================================

step01_acquire <- function(cfg) {
  raw <- acquire_station_data(cfg)                 # GHCN or local fallback
  meta <- raw$meta

  # Region + elevation filter (records the geographic removals).
  filt <- filter_candidates(meta, cfg)
  kept_ids <- filt$kept$station_id
  removed_geo <- filt$removed

  durations <- cfg$durations
  ams_by_dur <- list()
  short_records <- list()

  for (dur in durations) {
    per_station <- list()
    for (sid in kept_ids) {
      if (!is.null(raw$ams)) {
        # Pre-built AMS path (golden / user-supplied): apply the correction only.
        a <- raw$ams[[sid]]
        if (is.null(a)) next
        s <- data.frame(year = a$year, value = a$value * dur$fixed_interval_factor)
      } else {
        # Daily path: seasonal, duration-window annual maxima.
        d <- raw$daily[[sid]]
        if (is.null(d) || nrow(d) == 0) next
        s <- build_ams_from_daily(d, dur$days, dur$fixed_interval_factor,
                                  cfg$season, cfg$region$min_year_completeness)
      }
      if (is.null(s) || nrow(s) < cfg$region$min_record_years) {
        short_records[[sid]] <- data.frame(
          station_id = sid,
          name = filt$kept$name[filt$kept$station_id == sid],
          reason = sprintf("record < %d yr for %s duration",
                           cfg$region$min_record_years, dur$label),
          stringsAsFactors = FALSE)
        next
      }
      per_station[[sid]] <- s
    }
    ams_by_dur[[dur$label]] <- per_station
  }

  removed_short <- if (length(short_records))
    unique(do.call(rbind, short_records)) else
    data.frame(station_id = character(0), name = character(0),
               reason = character(0))

  audit_log(sprintf("Acquired data: %d candidate stations after region filter; %d durations.",
                    length(kept_ids), length(durations)))

  list(cfg = cfg, meta = filt$kept, meta_all = filt$meta_all, ams = ams_by_dur,
       removed_geo = removed_geo, removed_short = removed_short,
       n_candidates = nrow(meta))
}
