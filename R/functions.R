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
# screen_qflag(): NA-out observations that FAILED GHCN-Daily quality assurance.
#   value  : numeric vector of daily values
#   qflag  : character vector of GHCN QFLAG codes, aligned to `value`
#            (blank = passed QA; any non-blank letter = a failed QA check)
#   screen : if FALSE (or qflag NULL), return `value` unchanged
#   keep   : QFLAG codes to RETAIN despite being non-blank (default: none, i.e.
#            drop every flagged value) — lets a reviewer keep specific codes
#   -> the value vector with failed-QA entries set to NA; the number screened
#      is attached as attr(,"n_flagged").
#
# NOAA guidance: "if the quality flag is not blank, the observation should be
# considered suspect." For extreme-value frequency analysis a suspect daily
# total (often a spuriously large one) can dominate an annual maximum, so
# failed-QA values are treated as MISSING (NA) — not zero — which then flows
# through the existing completeness gate in build_ams_from_daily().
# ---------------------------------------------------------------------------
screen_qflag <- function(value, qflag, screen = TRUE, keep = character(0)) {
  if (!isTRUE(screen) || is.null(qflag)) return(value)
  q <- trimws(as.character(qflag))
  q[is.na(q)] <- ""                    # a missing/absent flag = passed QA, not flagged
  # (guards the common case where an all-blank QFLAG column is read as logical NA,
  #  which nzchar() would otherwise treat as non-blank and wrongly screen out)
  flagged <- nzchar(q) & !(q %in% keep)
  value[flagged] <- NA_real_
  attr(value, "n_flagged") <- sum(flagged, na.rm = TRUE)
  value
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
read_local_daily <- function(dir, qflag_screen = TRUE, qflag_keep = character(0)) {
  meta_path <- file.path(dir, "stations.csv")
  if (!file.exists(meta_path)) stop("Missing station metadata: ", meta_path)
  meta <- utils::read.csv(meta_path, stringsAsFactors = FALSE)
  daily <- list()
  for (sid in meta$station_id) {
    f <- file.path(dir, paste0(sid, ".csv"))
    if (!file.exists(f)) next
    d <- utils::read.csv(f, stringsAsFactors = FALSE)
    d$date <- as.Date(d$date)
    # If a user-supplied local file carries a GHCN quality flag column, screen
    # it the same way as the download path; otherwise this is a no-op.
    if ("qflag" %in% names(d))
      d$prcp <- as.numeric(screen_qflag(d$prcp, d$qflag, screen = qflag_screen, keep = qflag_keep))
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

# .read_lines_maybe_gz(): readLines that transparently handles a .gz path.
.read_lines_maybe_gz <- function(path) {
  con <- if (grepl("\\.gz$", path)) gzfile(path) else file(path)
  on.exit(close(con))
  readLines(con, warn = FALSE)
}

# parse_ghcn_stations(): fixed-width ghcnd-stations.txt(.gz) -> data.frame.
parse_ghcn_stations <- function(path) {
  ln <- .read_lines_maybe_gz(path)
  data.frame(
    station_id = trimws(substr(ln, 1, 11)),
    lat        = as.numeric(substr(ln, 13, 20)),
    lon        = as.numeric(substr(ln, 22, 30)),
    elev_m     = suppressWarnings(as.numeric(substr(ln, 32, 37))),
    name       = trimws(substr(ln, 42, 71)),
    stringsAsFactors = FALSE)
}

# parse_ghcn_inventory(): fixed-width ghcnd-inventory.txt(.gz) -> data.frame.
parse_ghcn_inventory <- function(path) {
  ln <- .read_lines_maybe_gz(path)
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

  # Prefer the COMMITTED, gzipped inventory (data/ghcn_inventory/*.txt.gz, ~7 MB)
  # so a fresh clone skips the ~47 MB inventory download entirely. Fall back to
  # downloading when it isn't present.
  static <- file.path(getOption("lmc.root", "."), "data", "ghcn_inventory")
  sp_gz <- file.path(static, "ghcnd-stations.txt.gz")
  iv_gz <- file.path(static, "ghcnd-inventory.txt.gz")
  if (!refresh && file.exists(sp_gz) && file.exists(iv_gz)) {
    sp <- sp_gz; iv <- iv_gz
  } else {
    if (getOption("timeout") < 600L) options(timeout = 600L)  # inventory is ~47 MB
    sp <- file.path(cache, "ghcnd-stations.txt")
    iv <- file.path(cache, "ghcnd-inventory.txt")
    ok <- tryCatch({
      if (!file.exists(sp)) utils::download.file(paste0(base, "/ghcnd-stations.txt"),  sp, quiet = TRUE)
      if (!file.exists(iv)) utils::download.file(paste0(base, "/ghcnd-inventory.txt"), iv, quiet = TRUE)
      file.exists(sp) && file.exists(iv) && file.size(sp) > 0 && file.size(iv) > 0
    }, error = function(e) FALSE, warning = function(w) FALSE)
    if (!ok) return(NULL)
  }
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

# ghcn_is_s3(): is this GHCN base the AWS Open-Data S3 mirror? The S3 mirror
# (noaa-ghcn-pds) serves UNCOMPRESSED per-station CSVs WITH a header under
# csv/by_station/, whereas NOAA NCEI serves gzipped headerless CSVs under
# by_station/. The AWS mirror is often reachable where www.ncei.noaa.gov is not.
ghcn_is_s3 <- function(ghcn_base) grepl("noaa-ghcn-pds|s3\\.amazonaws\\.com", ghcn_base)

# download_ghcn_daily(): pull GHCN-Daily for one station, cached on disk.
#   Returns data.frame(date,prcp) or NULL on failure. Supports BOTH the AWS S3
#   mirror (uncompressed .csv, header, csv/by_station/) and NOAA NCEI (gzipped
#   .csv.gz, no header, by_station/); the by_station column layout is identical
#   either way: ID, DATE(YYYYMMDD), ELEMENT, VALUE(tenths mm), MFLAG, QFLAG,
#   SFLAG(, OBS_TIME). Column 6 (QFLAG) non-blank = failed QA.
download_ghcn_daily <- function(station_id, ghcn_base, cache_dir = NULL,
                                qflag_screen = TRUE, qflag_keep = character(0)) {
  # Committed PRCP-only cache (data/ghcn_prcp_cache/<id>.csv.gz) — skip the
  # network entirely on a fresh clone. Stores date,prcp(mm),qflag so quality
  # screening still honours the config on read (see export_prcp_cache()).
  cache_gz <- file.path(getOption("lmc.root", "."), "data", "ghcn_prcp_cache",
                        paste0(station_id, ".csv.gz"))
  if (file.exists(cache_gz)) {
    cc <- tryCatch(utils::read.csv(gzfile(cache_gz), stringsAsFactors = FALSE),
                   error = function(e) NULL)
    if (!is.null(cc) && nrow(cc) && all(c("date", "prcp") %in% names(cc))) {
      q <- if ("qflag" %in% names(cc)) cc$qflag else NULL
      p <- screen_qflag(as.numeric(cc$prcp), q, screen = qflag_screen, keep = qflag_keep)
      return(data.frame(date = as.Date(cc$date), prcp = as.numeric(p)))
    }
  }
  if (getOption("timeout") < 600L) options(timeout = 600L)  # large files over a proxy
  s3  <- ghcn_is_s3(ghcn_base)
  ext <- if (s3) ".csv" else ".csv.gz"
  base <- sub("/$", "", ghcn_base)
  url <- if (s3) sprintf("%s/csv/by_station/%s.csv", base, station_id)
         else    sprintf("%s/by_station/%s.csv.gz", base, station_id)
  fp <- if (!is.null(cache_dir)) {
    dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
    file.path(cache_dir, paste0(station_id, ext))
  } else tempfile(fileext = ext)
  if (is.null(cache_dir) || !file.exists(fp) || file.size(fp) == 0) {
    ok <- tryCatch({ utils::download.file(url, fp, quiet = TRUE, mode = "wb"); TRUE },
                   error = function(e) FALSE, warning = function(w) FALSE)
    if (!ok || !file.exists(fp) || file.size(fp) == 0) return(NULL)
  }
  con <- if (s3) fp else gzfile(fp)        # S3 plain csv vs NCEI gzip
  d <- tryCatch(utils::read.csv(con, header = s3, stringsAsFactors = FALSE),
                error = function(e) NULL)
  if (is.null(d) || !nrow(d)) return(NULL)
  d <- d[d[[3]] == "PRCP", , drop = FALSE]
  if (!nrow(d)) return(NULL)
  prcp <- suppressWarnings(as.numeric(d[[4]])) / 10   # tenths of mm -> mm
  qflag <- if (ncol(d) >= 6) d[[6]] else NULL
  prcp <- screen_qflag(prcp, qflag, screen = qflag_screen, keep = qflag_keep)
  data.frame(date = as.Date(as.character(d[[2]]), "%Y%m%d"),
             prcp = as.numeric(prcp))     # as.numeric drops the n_flagged attr
}

# ---------------------------------------------------------------------------
# export_prcp_cache(): build the committed, PRCP-only station cache from the
# raw downloaded GHCN by_station files. Extracts just the PRCP rows (dropping
# TMAX/TMIN/SNOW/... and shrinking each file ~10x) as date,prcp(mm),qflag and
# writes <id>.csv.gz. This is what makes future reruns skip the station
# downloads; download_ghcn_daily() reads it first. Returns the number written.
# ---------------------------------------------------------------------------
export_prcp_cache <- function(raw_dir, out_dir, overwrite = FALSE) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  files <- list.files(raw_dir, pattern = "\\.csv(\\.gz)?$", full.names = TRUE)
  n <- 0L
  for (f in files) {
    sid <- sub("\\.csv(\\.gz)?$", "", basename(f))
    outf <- file.path(out_dir, paste0(sid, ".csv.gz"))
    if (!overwrite && file.exists(outf)) { n <- n + 1L; next }
    gz <- grepl("\\.gz$", f)
    d <- tryCatch(utils::read.csv(if (gz) gzfile(f) else f, header = !gz,
                                  stringsAsFactors = FALSE), error = function(e) NULL)
    if (is.null(d) || !nrow(d)) next
    d <- d[d[[3]] == "PRCP", , drop = FALSE]
    if (!nrow(d)) next
    out <- data.frame(date = as.Date(as.character(d[[2]]), "%Y%m%d"),
                      prcp = suppressWarnings(as.numeric(d[[4]])) / 10,
                      qflag = if (ncol(d) >= 6) as.character(d[[6]]) else "",
                      stringsAsFactors = FALSE)
    con <- gzfile(outf, "w"); utils::write.csv(out, con, row.names = FALSE); close(con)
    n <- n + 1L
  }
  n
}

# ---------------------------------------------------------------------------
# acquire_station_data(): return daily data for candidate stations, using the
# GHCN auto-download path where configured/available and falling back to local
# bundled data otherwise. Returns the same shape as read_local_daily().
# ---------------------------------------------------------------------------
acquire_station_data <- function(cfg) {
  qflag_screen <- cfg$data$qflag_screen %||% TRUE   # screen failed-QA obs by default
  qflag_keep   <- cfg$data$qflag_keep %||% character(0)
  if (identical(cfg$data$source, "ghcn")) {
    inv <- tryCatch(ghcn_load_inventory(cfg), error = function(e) NULL)
    if (!is.null(inv)) {
      meta <- ghcn_candidates(inv, cfg)          # nearby PRCP stations from inventory
      cache <- file.path(ghcn_cache_dir(cfg), "by_station")
      got <- list(meta = NULL, daily = list())
      for (sid in meta$station_id) {
        dd <- download_ghcn_daily(sid, cfg$data$ghcn_base, cache_dir = cache,
                                  qflag_screen = qflag_screen, qflag_keep = qflag_keep)
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
    message("GHCN download unavailable; falling back to SYNTHETIC demo data.")
  }
  # We reach here either via the GHCN fallback (source == "ghcn", NCEI
  # unreachable) or via an explicit local source. In the fallback case the
  # synthetic set is generated PER SITE and CENTERED on the site, isolated under
  # data/synthetic/<site_id>/, so batch facilities never collide and every
  # facility gets an in-region set offline. Explicit source == "local" honours
  # the user's local_dir.
  synthetic_fallback <- identical(cfg$data$source, "ghcn")

  if (identical(cfg$data$local_format, "ams"))
    return(read_local_ams(cfg$data$local_dir))

  ldir <- if (synthetic_fallback)
    file.path(getOption("lmc.root", "."), "data", "synthetic", cfg$site$id %||% "site")
  else cfg$data$local_dir

  if (!file.exists(file.path(ldir, "stations.csv"))) {
    gen <- file.path(getOption("lmc.root", "."), "R", "make_demo_data.R")
    if (file.exists(gen)) {
      source(gen, local = TRUE)
      message("Generating SYNTHETIC demo data (offline) for ",
              cfg$site$id %||% "site", " at (", cfg$site$latitude, ", ",
              cfg$site$longitude, ").")
      make_demo_data(ldir, center_lat = cfg$site$latitude,
                     center_lon = cfg$site$longitude,
                     radius_km = cfg$region$search_radius_km %||% 200)
    }
  }
  read_local_daily(ldir, qflag_screen = qflag_screen, qflag_keep = qflag_keep)
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
  # Regression of mean AMS on elevation; fall back to the plain regional mean if
  # it can't be applied. The target site's elevation is often blank/NA in the
  # dam inventory (the NID mirror carries no ground elevations — see
  # DATA_SOURCES.md); without it a regression prediction is impossible, so fall
  # back to the regional mean rather than crashing (predict.lm rejects a logical
  # NA). This is the documented default until elevations are enriched.
  site_elev <- suppressWarnings(as.numeric(cfg$site$elevation_m))
  if (length(site_elev) != 1L || !is.finite(site_elev))
    return(mean(means))
  df  <- data.frame(mean_ams = means, elev = suppressWarnings(as.numeric(used_meta$elev_m)))
  fit <- try(stats::lm(mean_ams ~ elev, data = df), silent = TRUE)
  if (inherits(fit, "try-error") || any(is.na(stats::coef(fit))))
    return(mean(means))
  pred <- try(as.numeric(stats::predict(fit,
    newdata = data.frame(elev = site_elev))), silent = TRUE)
  # guard against a failed or implausible (e.g. negative) extrapolation
  if (inherits(pred, "try-error") || !is.finite(pred) || pred <= 0) mean(means) else pred
}

# ---------------------------------------------------------------------------
# elevatr_lookup(): default DEM elevation lookup (metres) via the elevatr
# package. Needs elevatr installed AND network (AWS Terrain Tiles); returns all
# NA when either is unavailable, so callers degrade gracefully offline.
# ---------------------------------------------------------------------------
elevatr_lookup <- function(lat, lon) {
  if (!requireNamespace("elevatr", quietly = TRUE) ||
      !requireNamespace("sf", quietly = TRUE))
    return(rep(NA_real_, length(lat)))
  pts <- data.frame(x = as.numeric(lon), y = as.numeric(lat))
  e <- tryCatch(
    elevatr::get_elev_point(pts, prj = "EPSG:4326", src = "aws"),
    error = function(err) NULL, warning = function(w) NULL)
  if (is.null(e) || is.null(e$elevation)) return(rep(NA_real_, length(lat)))
  as.numeric(e$elevation)
}

# ---------------------------------------------------------------------------
# enrich_elevations(): fill MISSING elevation_m in a facilities manifest from a
# DEM, so the regression index-flood method can use the site elevation (the NID
# dam-inventory mirror carries none — see DATA_SOURCES.md). Existing values are
# preserved; only NA/blank entries are filled.
#   manifest : data.frame with latitude, longitude[, elevation_m]
#   lookup   : function(lat, lon) -> numeric metres, vectorised (default
#              elevatr_lookup). A no-op (keeps NA) when the lookup is
#              unavailable — the index flood then falls back to the regional
#              mean, which is safe (see estimate_index_flood()).
#   -> the manifest with elevation_m filled where possible.
# ---------------------------------------------------------------------------
enrich_elevations <- function(manifest, lookup = elevatr_lookup) {
  if (!"elevation_m" %in% names(manifest)) manifest$elevation_m <- NA_real_
  elev <- suppressWarnings(as.numeric(manifest$elevation_m))
  missing <- is.na(elev)
  if (!any(missing)) { manifest$elevation_m <- elev; return(manifest) }
  got <- tryCatch(lookup(manifest$latitude[missing], manifest$longitude[missing]),
                  error = function(e) rep(NA_real_, sum(missing)))
  got <- suppressWarnings(as.numeric(got))
  if (length(got) != sum(missing)) got <- rep(NA_real_, sum(missing))
  elev[missing] <- got
  manifest$elevation_m <- elev
  n_filled <- sum(missing & !is.na(elev))
  message(sprintf("enrich_elevations: filled %d/%d missing elevations%s.",
                  n_filled, sum(missing),
                  if (n_filled < sum(missing))
                    " (rest unavailable — index-flood uses the regional mean)" else ""))
  manifest
}

# ---------------------------------------------------------------------------
# collect_tail_sensitivity(): flatten a run_analysis() result's per-duration
# tail_sensitivity tables into one data.frame keyed by site/site_id/duration
# (the reviewer's detailed view of the 10,000-yr depth under every candidate
# distribution). Returns NULL if none present.
# ---------------------------------------------------------------------------
collect_tail_sensitivity <- function(res) {
  labs <- names(res$per_duration)
  parts <- lapply(labs, function(lab) {
    t <- res$per_duration[[lab]]$tail_sensitivity
    if (is.null(t) || !nrow(t)) return(NULL)
    data.frame(site = res$cfg$site$name %||% NA_character_,
               site_id = res$cfg$site$id %||% NA_character_,
               duration = lab, t, stringsAsFactors = FALSE)
  })
  parts <- Filter(Negate(is.null), parts)
  if (!length(parts)) return(NULL)
  do.call(rbind, parts)
}

# ---------------------------------------------------------------------------
# load_distribution_review(): read the optional EXPERT distribution-review
# registry (config/distribution_review.csv). Each row records a reviewer's
# chosen distribution for a facility (optionally a specific duration),
# OVERRIDING the automatic |Z|-minimising selection. Returns NULL when the
# file is absent (=> auto-select everywhere, the default for automated runs).
#   Columns: facility_id, duration ("24h"/"72h"/blank=all), distribution,
#            reviewer, date, notes.
# ---------------------------------------------------------------------------
load_distribution_review <- function(path) {
  if (is.null(path) || !file.exists(path)) return(NULL)
  df <- tryCatch(utils::read.csv(path, stringsAsFactors = FALSE, comment.char = "#"),
                 error = function(e) NULL)
  if (is.null(df) || !"facility_id" %in% names(df) || !nrow(df)) return(NULL)
  if (!"duration" %in% names(df)) df$duration <- ""
  if (!"distribution" %in% names(df)) df$distribution <- ""
  if (!"reviewer" %in% names(df)) df$reviewer <- NA_character_
  df$facility_id  <- trimws(as.character(df$facility_id))
  df$duration     <- trimws(as.character(df$duration))
  df$distribution <- tolower(trimws(as.character(df$distribution)))
  df[nzchar(df$facility_id) & nzchar(df$distribution), , drop = FALSE]
}

# ---------------------------------------------------------------------------
# resolve_distribution(): decide the regional distribution for one facility &
# duration by PRECEDENCE — expert review > config override > automatic
# (smallest |Z|). This is the single decision point behind the expert-review
# step: automated runs (empty review registry, no config override) auto-select
# exactly as before; a recorded expert decision wins when present.
#   z_table : data.frame(dist, absZ, ...) sorted by absZ ascending (from step05)
#   cfg     : configuration (may carry distribution_override)
#   site_id, duration : keys to look up in `review`
#   review  : the registry from load_distribution_review() (or NULL)
#   -> list(chosen, source in {expert_review, config_override, auto}, reviewer)
# ---------------------------------------------------------------------------
resolve_distribution <- function(z_table, cfg, site_id, duration, review = NULL) {
  auto <- z_table$dist[1]                       # smallest |Z|
  if (!is.null(review) && nrow(review)) {
    hit <- review[review$facility_id == site_id &
                  (is.na(review$duration) | review$duration == "" |
                   review$duration == duration), , drop = FALSE]
    if (nrow(hit))
      return(list(chosen = hit$distribution[1], source = "expert_review",
                  reviewer = hit$reviewer[1] %||% NA_character_))
  }
  if (!is.null(cfg$distribution_override))
    return(list(chosen = cfg$distribution_override, source = "config_override",
                reviewer = NA_character_))
  list(chosen = auto, source = "auto", reviewer = NA_character_)
}

# ---------------------------------------------------------------------------
# facility_diagnostics(): one-row-per-duration triage summary from a
# run_analysis() result. Surfaces the two things a fleet reviewer must check
# per facility (H&W): region heterogeneity (H1) and goodness-of-fit of the
# chosen distribution (|Z|). `needs_review` flags a facility whose region is
# heterogeneous (H1 >= 2) or whose chosen distribution fits poorly (|Z| > 1.64)
# — exactly the fleet triage rule in docs/PLAN.md sec. 12 / CLAUDE.md step 5.
#   res : the list returned by run_analysis()
#   -> data.frame(site, site_id, duration, n_stations, H1, homog_status,
#                 chosen_dist, chosen_absZ, Z_acceptable, needs_review)
# ---------------------------------------------------------------------------
facility_diagnostics <- function(res) {
  labs <- names(res$per_duration)
  rows <- lapply(labs, function(lab) {
    pd <- res$per_duration[[lab]]
    chosen <- pd$dist_sel$chosen
    absZ <- tryCatch(abs(as.numeric(pd$dist_sel$Z[[chosen]])), error = function(e) NA_real_)
    H1 <- suppressWarnings(as.numeric(pd$H[1]))
    acceptable <- isTRUE(pd$dist_sel$acceptable)
    source <- pd$dist_sel$source %||% "auto"
    # Runner-up = best-fitting candidate other than the chosen one; the |Z|
    # margin to it says how "close" the automatic call was (a small margin means
    # the choice is not clearly best and an expert should weigh the tail).
    tbl <- pd$dist_sel$table
    alt <- if (!is.null(tbl)) tbl[toupper(tbl$dist) != toupper(chosen), , drop = FALSE] else NULL
    runner_up <- if (!is.null(alt) && nrow(alt)) toupper(alt$dist[1]) else NA_character_
    runner_up_absZ <- if (!is.null(alt) && nrow(alt)) alt$absZ[1] else NA_real_
    z_margin <- runner_up_absZ - absZ
    review_recommended <- identical(source, "auto") &&
      (!acceptable || (is.finite(z_margin) && z_margin < 0.5))
    # Tail-choice sensitivity: how far apart are the candidate distributions at
    # the 10,000-yr depth, as a % of the chosen one? A large spread means the
    # distribution choice materially drives the extreme, so review it closely.
    ts <- pd$tail_sensitivity
    chosen_10k <- tryCatch(pd$est$quantiles$depth_mm[pd$est$quantiles$T == 10000][1],
                           error = function(e) NA_real_)
    if (is.null(chosen_10k) || length(chosen_10k) != 1) chosen_10k <- NA_real_
    tail_min <- if (!is.null(ts) && nrow(ts))
      suppressWarnings(min(ts$depth_mm, na.rm = TRUE)) else NA_real_
    tail_max <- if (!is.null(ts) && nrow(ts))
      suppressWarnings(max(ts$depth_mm, na.rm = TRUE)) else NA_real_
    tail_spread_pct <- if (is.finite(chosen_10k) && chosen_10k > 0 &&
                           is.finite(tail_min) && is.finite(tail_max))
      round(100 * (tail_max - tail_min) / chosen_10k, 1) else NA_real_
    data.frame(
      site        = res$cfg$site$name %||% NA_character_,
      site_id     = res$cfg$site$id %||% NA_character_,
      duration    = lab,
      n_stations  = if (!is.null(pd$regdata_final)) nrow(pd$regdata_final) else NA_integer_,
      H1          = round(H1, 3),
      homog_status = pd$homog_status %||% NA_character_,
      chosen_dist = toupper(chosen),
      chosen_absZ = round(absZ, 3),
      Z_acceptable = acceptable,
      selection_source = source,
      reviewer    = pd$dist_sel$reviewer %||% NA_character_,
      runner_up   = runner_up,
      runner_up_absZ = round(runner_up_absZ, 3),
      z_margin    = round(z_margin, 3),
      review_recommended = review_recommended,
      depth_10k_mm = round(chosen_10k, 1),
      tail_min_10k_mm = round(tail_min, 1),
      tail_max_10k_mm = round(tail_max, 1),
      tail_spread_pct = tail_spread_pct,
      needs_review = (isTRUE(H1 >= 2) || !acceptable),
      stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
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
