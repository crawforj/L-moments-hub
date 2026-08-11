# =============================================================================
# functions.R  —  Site-agnostic, reusable helpers (the portable core)
#
# Nothing in this file is specific to Como Dam; every basin-specific value is
# read from the YAML config. These helpers are sourced by 00_setup.R and used
# by the numbered pipeline scripts (01..11). Each function has a short header
# describing its purpose, arguments, and return value.
#
# Method reference: Hosking, J.R.M. & Wallis, J.R. (1997) "Regional Frequency
# Analysis: An Approach Based on L-Moments", Cambridge University Press (H&W).
# =============================================================================

# Null-coalescing operator: a %||% b returns b when a is NULL.
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# ---------------------------------------------------------------------------
# load_config(path): read and lightly validate the YAML configuration.
#   path : path to a config .yml file
#   -> named list of configuration values
# ---------------------------------------------------------------------------
load_config <- function(path) {
  if (!file.exists(path)) stop("Config file not found: ", path)
  cfg <- yaml::read_yaml(path)
  req <- c("site", "region", "durations", "season", "return_periods", "data")
  miss <- setdiff(req, names(cfg))
  if (length(miss)) stop("Config missing required sections: ",
                         paste(miss, collapse = ", "))
  cfg
}

# ---------------------------------------------------------------------------
# haversine_km(): great-circle distance (km) between two lon/lat points.
#   Vectorised over lat2/lon2 so one call gives distance from a site to many
#   stations. Used to apply the region search radius.
# ---------------------------------------------------------------------------
haversine_km <- function(lat1, lon1, lat2, lon2) {
  R <- 6371.0088                       # mean Earth radius, km
  d2r <- pi / 180
  dlat <- (lat2 - lat1) * d2r
  dlon <- (lon2 - lon1) * d2r
  a <- sin(dlat / 2)^2 +
       cos(lat1 * d2r) * cos(lat2 * d2r) * sin(dlon / 2)^2
  2 * R * asin(pmin(1, sqrt(a)))
}

# ---------------------------------------------------------------------------
# in_season(): logical flag for dates inside the [start,end] month window.
#   Handles wrap-around windows (e.g. Nov..Feb) as well as normal ones.
# ---------------------------------------------------------------------------
in_season <- function(dates, start_month, end_month) {
  m <- as.integer(format(dates, "%m"))
  if (start_month <= end_month) {
    m >= start_month & m <= end_month
  } else {                              # wrap-around (e.g. 11..2)
    m >= start_month | m <= end_month
  }
}

# ---------------------------------------------------------------------------
# rolling_sum(): d-day running total over a *calendar-consecutive* daily series.
#   x     : numeric vector ordered by date, with NA for missing days
#   days  : window width (1 = daily, 3 = 72-hour, ...)
#   -> numeric vector, same length; element i is sum of days ending at i,
#      NA if any day in the window is missing.
# ---------------------------------------------------------------------------
rolling_sum <- function(x, days) {
  n <- length(x)
  if (days <= 1) return(x)
  out <- rep(NA_real_, n)
  cs <- cumsum(ifelse(is.na(x), 0, x))
  na_cs <- cumsum(is.na(x))
  for (i in days:n) {
    lo <- i - days + 1
    n_na <- na_cs[i] - (if (lo > 1) na_cs[lo - 1] else 0)
    if (n_na == 0) out[i] <- cs[i] - (if (lo > 1) cs[lo - 1] else 0)
  }
  out
}

# ---------------------------------------------------------------------------
# build_ams_from_daily(): annual-maximum series for one station & duration.
#   daily        : data.frame(date <Date>, prcp <numeric mm>) — may have gaps
#   days         : duration in days
#   factor       : fixed-interval (constraint) correction multiplier
#   season       : list(start_month, end_month)
#   min_complete : required fraction of in-season days present in a year
#   -> data.frame(year, value) of corrected annual maxima (in-season)
#
# The d-day running sum is computed on the full calendar series (so windows may
# start just before the season), then the maximum is taken over windows whose
# END date falls inside the seasonal window. This follows the standard
# fixed-interval AMS construction (H&W ch. 2; WMO-No.1045).
# ---------------------------------------------------------------------------
build_ams_from_daily <- function(daily, days, factor, season, min_complete) {
  daily <- daily[order(daily$date), ]
  # Fill to a continuous daily grid so rolling windows are calendar-correct.
  full <- data.frame(date = seq(min(daily$date), max(daily$date), by = "day"))
  daily <- merge(full, daily, by = "date", all.x = TRUE)
  daily$roll <- rolling_sum(daily$prcp, days)
  daily$year <- as.integer(format(daily$date, "%Y"))
  daily$inseason <- in_season(daily$date, season$start_month, season$end_month)

  yrs <- sort(unique(daily$year))
  rows <- lapply(yrs, function(y) {
    idx <- daily$year == y & daily$inseason
    days_present <- sum(!is.na(daily$prcp[idx]))
    days_possible <- sum(idx)
    if (days_possible == 0) return(NULL)
    if (days_present / days_possible < min_complete) return(NULL)  # completeness gate
    v <- suppressWarnings(max(daily$roll[idx], na.rm = TRUE))
    if (!is.finite(v)) return(NULL)
    data.frame(year = y, value = v * factor)
  })
  do.call(rbind, rows)
}

# ---------------------------------------------------------------------------
# read_local_daily(): load bundled/user daily station data (offline path).
#   dir : directory containing stations.csv + <station_id>.csv (date,prcp)
#   -> list(meta = data.frame, daily = named list of data.frame(date,prcp))
# ---------------------------------------------------------------------------
read_local_daily <- function(dir) {
  meta_path <- file.path(dir, "stations.csv")
  if (!file.exists(meta_path)) stop("Missing station metadata: ", meta_path)
  meta <- utils::read.csv(meta_path, stringsAsFactors = FALSE)
  daily <- list()
  for (sid in meta$station_id) {
    f <- file.path(dir, paste0(sid, ".csv"))
    if (!file.exists(f)) next
    d <- utils::read.csv(f, stringsAsFactors = FALSE)
    d$date <- as.Date(d$date)
    daily[[sid]] <- d[, c("date", "prcp")]
  }
  list(meta = meta, daily = daily)
}

# ---------------------------------------------------------------------------
# read_local_ams(): load pre-built annual-maximum series (offline path).
#   dir : directory with stations.csv + ams.csv(station_id,year,value)
#   -> list(meta, ams = named list of data.frame(year,value))
# ---------------------------------------------------------------------------
read_local_ams <- function(dir) {
  meta <- utils::read.csv(file.path(dir, "stations.csv"), stringsAsFactors = FALSE)
  a <- utils::read.csv(file.path(dir, "ams.csv"), stringsAsFactors = FALSE)
  ams <- lapply(split(a[, c("year", "value")], a$station_id), function(x)
    x[order(x$year), ])
  list(meta = meta, ams = ams)
}

# ---------------------------------------------------------------------------
# GHCN-Daily inventory + caching helpers
#
# The global station metadata (ghcnd-stations.txt) and per-element period of
# record (ghcnd-inventory.txt) are downloaded ONCE and cached (parsed to an RDS)
# so that many facilities reuse them. Per-station daily files are also cached on
# disk so nearby facilities share downloads. All requires network to NOAA NCEI.
# ---------------------------------------------------------------------------

ghcn_cache_dir <- function(cfg)
  cfg$data$ghcn_cache_dir %||% file.path(getOption("lmc.root", "."), "data", "raw", "ghcn")

# parse_ghcn_stations(): fixed-width ghcnd-stations.txt -> data.frame.
parse_ghcn_stations <- function(path) {
  ln <- readLines(path, warn = FALSE)
  data.frame(
    station_id = trimws(substr(ln, 1, 11)),
    lat        = as.numeric(substr(ln, 13, 20)),
    lon        = as.numeric(substr(ln, 22, 30)),
    elev_m     = suppressWarnings(as.numeric(substr(ln, 32, 37))),
    name       = trimws(substr(ln, 42, 71)),
    stringsAsFactors = FALSE)
}

# parse_ghcn_inventory(): fixed-width ghcnd-inventory.txt -> data.frame.
parse_ghcn_inventory <- function(path) {
  ln <- readLines(path, warn = FALSE)
  data.frame(
    station_id = trimws(substr(ln, 1, 11)),
    element    = trimws(substr(ln, 32, 35)),
    first_year = suppressWarnings(as.integer(substr(ln, 37, 40))),
    last_year  = suppressWarnings(as.integer(substr(ln, 42, 45))),
    stringsAsFactors = FALSE)
}

# ghcn_load_inventory(): download (once, cached) and return the merged PRCP
# station inventory: station_id, name, lat, lon, elev_m, first_year, last_year,
# n_years_avail. Returns NULL if the download fails (caller falls back).
ghcn_load_inventory <- function(cfg, refresh = FALSE) {
  cache <- ghcn_cache_dir(cfg)
  dir.create(cache, showWarnings = FALSE, recursive = TRUE)
  rds <- file.path(cache, "inventory_prcp.rds")
  if (!refresh && file.exists(rds)) return(readRDS(rds))
  base <- cfg$data$ghcn_base
  sp <- file.path(cache, "ghcnd-stations.txt")
  iv <- file.path(cache, "ghcnd-inventory.txt")
  ok <- tryCatch({
    if (!file.exists(sp)) utils::download.file(paste0(base, "/ghcnd-stations.txt"),  sp, quiet = TRUE)
    if (!file.exists(iv)) utils::download.file(paste0(base, "/ghcnd-inventory.txt"), iv, quiet = TRUE)
    file.exists(sp) && file.exists(iv) && file.size(sp) > 0 && file.size(iv) > 0
  }, error = function(e) FALSE, warning = function(w) FALSE)
  if (!ok) return(NULL)
  stations <- parse_ghcn_stations(sp)
  inv <- parse_ghcn_inventory(iv)
  prcp <- inv[inv$element == "PRCP", c("station_id", "first_year", "last_year")]
  merged <- merge(stations, prcp, by = "station_id")
  merged$n_years_avail <- merged$last_year - merged$first_year + 1
  saveRDS(merged, rds)
  merged
}

# ghcn_candidates(): select candidate PRCP stations near the site from the
# inventory (radius + elevation band + minimum years of record), capped at the
# nearest region$max_stations to bound the download volume.
ghcn_candidates <- function(inv, cfg) {
  inv$distance_km <- haversine_km(cfg$site$latitude, cfg$site$longitude,
                                  inv$lat, inv$lon)
  band <- cfg$region$elevation_band_m
  keep <- inv$distance_km <= cfg$region$search_radius_km &
          !is.na(inv$elev_m) & inv$elev_m >= band[1] & inv$elev_m <= band[2] &
          (inv$n_years_avail >= cfg$region$min_record_years)
  cand <- inv[keep, ]
  cand <- cand[order(cand$distance_km), ]
  max_st <- cfg$region$max_stations %||% 60L
  if (nrow(cand) > max_st) cand <- cand[seq_len(max_st), ]
  cand[, c("station_id", "name", "lat", "lon", "elev_m")]
}

# download_ghcn_daily(): pull GHCN-Daily for one station, cached on disk.
#   Returns data.frame(date,prcp) or NULL on failure. Cached .csv.gz is reused.
download_ghcn_daily <- function(station_id, ghcn_base, cache_dir = NULL) {
  gz <- if (!is.null(cache_dir)) {
    dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
    file.path(cache_dir, paste0(station_id, ".csv.gz"))
  } else tempfile(fileext = ".csv.gz")
  if (is.null(cache_dir) || !file.exists(gz) || file.size(gz) == 0) {
    url <- sprintf("%s/by_station/%s.csv.gz", ghcn_base, station_id)
    ok <- tryCatch({ utils::download.file(url, gz, quiet = TRUE, mode = "wb"); TRUE },
                   error = function(e) FALSE, warning = function(w) FALSE)
    if (!ok || !file.exists(gz) || file.size(gz) == 0) return(NULL)
  }
  d <- tryCatch(utils::read.csv(gzfile(gz), header = FALSE, stringsAsFactors = FALSE),
                error = function(e) NULL)
  if (is.null(d) || !nrow(d)) return(NULL)
  # GHCN by_station schema: ID, YYYYMMDD, ELEMENT, VALUE(tenths mm), ...
  d <- d[d[[3]] == "PRCP", , drop = FALSE]
  if (!nrow(d)) return(NULL)
  data.frame(date = as.Date(as.character(d[[2]]), "%Y%m%d"),
             prcp = d[[4]] / 10)          # tenths of mm -> mm
}

# ---------------------------------------------------------------------------
# acquire_station_data(): return daily data for candidate stations, using the
# GHCN auto-download path where configured/available and falling back to local
# bundled data otherwise. Returns the same shape as read_local_daily().
# ---------------------------------------------------------------------------
acquire_station_data <- function(cfg) {
  if (identical(cfg$data$source, "ghcn")) {
    inv <- tryCatch(ghcn_load_inventory(cfg), error = function(e) NULL)
    if (!is.null(inv)) {
      meta <- ghcn_candidates(inv, cfg)          # nearby PRCP stations from inventory
      cache <- file.path(ghcn_cache_dir(cfg), "by_station")
      got <- list(meta = NULL, daily = list())
      for (sid in meta$station_id) {
        dd <- download_ghcn_daily(sid, cfg$data$ghcn_base, cache_dir = cache)
        if (!is.null(dd)) got$daily[[sid]] <- dd
      }
      if (length(got$daily)) {
        got$meta <- meta[meta$station_id %in% names(got$daily), ]
        message("GHCN: ", length(got$daily), " stations acquired (cache ", cache, ").")
        return(got)
      }
    }
    if (!isTRUE(cfg$data$use_local_fallback))
      stop("GHCN download failed and use_local_fallback is FALSE.")
    message("GHCN download unavailable; using local fallback data in ",
            cfg$data$local_dir, ".")
  }
  if (identical(cfg$data$local_format, "ams"))
    return(read_local_ams(cfg$data$local_dir))
  # Daily local path: if no data present, generate the seeded synthetic demo set
  # so the pipeline is runnable immediately after a fresh clone (offline).
  if (!file.exists(file.path(cfg$data$local_dir, "stations.csv"))) {
    gen <- file.path(getOption("lmc.root", "."), "R", "make_demo_data.R")
    if (file.exists(gen)) {
      source(gen, local = TRUE)
      message("No local data found; generating SYNTHETIC demo data (offline).")
      make_demo_data(cfg$data$local_dir)
    }
  }
  read_local_daily(cfg$data$local_dir)
}

# ---------------------------------------------------------------------------
# filter_candidates(): apply the region search radius and elevation band.
#   meta : station metadata with station_id, name, lat, lon, elev_m
#   cfg  : configuration
#   -> list(kept = meta subset + distance_km, removed = data.frame(reason))
# ---------------------------------------------------------------------------
filter_candidates <- function(meta, cfg) {
  meta$distance_km <- haversine_km(cfg$site$latitude, cfg$site$longitude,
                                   meta$lat, meta$lon)
  band <- cfg$region$elevation_band_m
  too_far <- meta$distance_km > cfg$region$search_radius_km
  off_elev <- meta$elev_m < band[1] | meta$elev_m > band[2]
  drop <- too_far | off_elev
  removed <- data.frame(
    station_id  = meta$station_id[drop],
    name        = meta$name[drop],
    lat         = meta$lat[drop],
    lon         = meta$lon[drop],
    elev_m      = meta$elev_m[drop],
    distance_km = round(meta$distance_km[drop], 1),
    reason      = ifelse(too_far[drop],
                         sprintf("outside %g km radius", cfg$region$search_radius_km),
                         "outside elevation band"),
    stringsAsFactors = FALSE)
  kept <- meta[!drop, ]
  list(kept = kept, removed = removed, meta_all = meta)
}

# ---------------------------------------------------------------------------
# cunnane_pp(): Cunnane plotting positions for n ordered observations.
#   Used to place empirical points on growth-curve / DDF plots.
# ---------------------------------------------------------------------------
cunnane_pp <- function(n) (seq_len(n) - 0.4) / (n + 0.2)

# ---------------------------------------------------------------------------
# rp_to_prob() / prob_to_rp(): convert between return period T (years) and
# non-exceedance probability F for an annual-maximum series (F = 1 - 1/T).
# ---------------------------------------------------------------------------
rp_to_prob <- function(T) 1 - 1 / T
prob_to_rp <- function(F) 1 / (1 - F)

# ---------------------------------------------------------------------------
# estimate_index_flood(): transfer the index flood (mean AMS) to the target
# (ungauged) site from the regional gauges.
#   used_meta : metadata for stations used (must include elev_m)
#   means     : at-site mean AMS for the used stations (same order)
#   cfg       : configuration (site, index_flood$method)
#   -> scalar index flood (mm) at the site
# ---------------------------------------------------------------------------
estimate_index_flood <- function(used_meta, means, cfg) {
  method <- cfg$index_flood$method %||% "regression"
  if (method == "nearest") {
    j <- which.min(used_meta$distance_km)
    return(means[j])
  }
  # regression of mean AMS on elevation; fall back to plain mean if degenerate
  df  <- data.frame(mean_ams = means, elev = used_meta$elev_m)
  fit <- try(stats::lm(mean_ams ~ elev, data = df), silent = TRUE)
  if (inherits(fit, "try-error") || any(is.na(stats::coef(fit))))
    return(mean(means))
  pred <- as.numeric(stats::predict(fit,
    newdata = data.frame(elev = cfg$site$elevation_m)))
  # guard against an implausible (e.g. negative) extrapolation
  if (!is.finite(pred) || pred <= 0) mean(means) else pred
}

# ---------------------------------------------------------------------------
# write_manifest(): record run provenance for audit/reproducibility.
#   Writes outputs/provenance/run_manifest_<id>.json capturing config, package
#   versions, sessionInfo, seed, git commit (if available), and station spans.
# ---------------------------------------------------------------------------
write_manifest <- function(cfg, config_path, regdata, out_dir, stamp) {
  git_sha <- tryCatch(trimws(system2("git", c("rev-parse", "HEAD"),
                                     stdout = TRUE, stderr = FALSE)),
                      error = function(e) NA_character_)
  si <- sessionInfo()
  pkgs <- c("lmom", "lmomRFA", "yaml", "ggplot2", "sf")
  vers <- sapply(pkgs, function(p)
    tryCatch(as.character(packageVersion(p)), error = function(e) NA))
  manifest <- list(
    site = cfg$site$name,
    run_id = stamp,
    generated_at = stamp,
    git_commit = if (length(git_sha)) git_sha[1] else NA,
    config_file = config_path,
    config = cfg,
    r_version = R.version.string,
    package_versions = as.list(vers),
    seed = cfg$seed,
    n_stations_used = if (!is.null(regdata)) nrow(regdata) else NA,
    station_record_lengths = if (!is.null(regdata))
      stats::setNames(regdata$n, regdata$name) else NULL
  )
  dir.create(file.path(out_dir, "provenance"), showWarnings = FALSE, recursive = TRUE)
  jsonlite::write_json(manifest,
                       file.path(out_dir, "provenance",
                                 paste0("run_manifest_", cfg$site$id, ".json")),
                       auto_unbox = TRUE, pretty = TRUE, digits = 8)
  invisible(manifest)
}
