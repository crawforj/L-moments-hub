# =============================================================================
# make_demo_data.R  —  Generate synthetic, seeded demo DAILY precipitation data
#
# PURPOSE: this sandbox (and any offline run) cannot reach NOAA NCEI, so this
# script fabricates a realistic, reproducible daily dataset for stations around
# Como Dam. It lets the FULL pipeline (seasonal windowing, duration sums,
# screening, homogeneity, estimation) run end-to-end with no network. It is NOT
# real observed data and must NOT be used for engineering decisions — replace it
# by setting data.source: "ghcn" in the config where NOAA is reachable.
#
# The generator deliberately includes: a homogeneous core of stations, one
# heavy-tailed DISCORDANT station, one SHORT-record station, and one station
# OUTSIDE the search radius — so the screening/region steps have something to do.
#
# make_demo_data(dir): writes stations.csv and <station_id>.csv (date,prcp).
# =============================================================================

make_demo_data <- function(dir = "data/external",
                           years = 1981:2020, seed = 4321,
                           center_lat = 46.06, center_lon = -114.23,
                           radius_km = 200) {
  set.seed(seed)
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)

  # Station network centered on the requested site (defaults to Como Dam). The
  # network is placed relative to (center_lat, center_lon) and the search radius
  # so that ANY facility's config produces an in-region synthetic set offline
  # (km offsets -> degrees; longitude scaled by latitude). elev in metres.
  km2dlat <- 1 / 111.0
  km2dlon <- 1 / (111.320 * cos(center_lat * pi / 180))
  r <- radius_km
  core <- data.frame(
    station_id = sprintf("DEMO%02d", 1:14),
    name = paste("core gauge", 1:14),
    lat = center_lat + stats::runif(14, -0.55 * r, 0.55 * r) * km2dlat,
    lon = center_lon + stats::runif(14, -0.55 * r, 0.55 * r) * km2dlon,
    elev_m = round(stats::runif(14, 950, 2100)),
    scale = stats::runif(14, 0.85, 1.30),   # sets each site's index flood
    kind = "core", stringsAsFactors = FALSE)

  special <- data.frame(
    station_id = c("DEMO15", "DEMO16", "DEMO17"),
    name = c("Heavy-tail outlier gauge", "Short-record gauge", "Distant gauge (out of region)"),
    lat = center_lat + c(0.25 * r, -0.30 * r, 1.40 * r) * km2dlat,   # 'far' beyond radius
    lon = center_lon + c(0.20 * r, -0.15 * r, 0.20 * r) * km2dlon,
    elev_m = c(1500, 1300, 1100),
    scale = c(1.15, 1.0, 1.2),
    kind = c("discordant", "short", "far"), stringsAsFactors = FALSE)

  meta <- rbind(core, special)
  utils::write.csv(meta[, c("station_id", "name", "lat", "lon", "elev_m")],
                   file.path(dir, "stations.csv"), row.names = FALSE)

  # Monthly wet-day occurrence probability (spring snowmelt/rain season peak).
  p_month <- c(0.12, 0.12, 0.18, 0.30, 0.34, 0.30, 0.28, 0.20, 0.16, 0.15, 0.13, 0.12)

  gen_station <- function(row) {
    yrs <- years
    if (row$kind == "short") yrs <- utils::tail(years, 12)   # too few years -> removed
    dates <- seq(as.Date(sprintf("%d-01-01", min(yrs))),
                 as.Date(sprintf("%d-12-31", max(yrs))), by = "day")
    m <- as.integer(format(dates, "%m"))
    wet <- stats::rbinom(length(dates), 1, p_month[m])
    # wet-day amount: gamma; discordant station has a heavier tail (smaller shape)
    shape <- if (row$kind == "discordant") 0.55 else 0.80
    amt <- stats::rgamma(length(dates), shape = shape, scale = row$scale * 9)
    prcp <- round(ifelse(wet == 1, amt, 0), 1)
    data.frame(date = dates, prcp = prcp)
  }

  for (i in seq_len(nrow(meta))) {
    d <- gen_station(meta[i, ])
    utils::write.csv(d, file.path(dir, paste0(meta$station_id[i], ".csv")),
                     row.names = FALSE)
  }
  message(sprintf("Demo data written for %d stations to %s (SYNTHETIC — not real observations).",
                  nrow(meta), dir))
  invisible(meta)
}
