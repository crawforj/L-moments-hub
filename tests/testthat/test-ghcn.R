# Offline tests for GHCN inventory parsing, candidate selection, and daily-file
# caching. The network paths are exercised via a local fixture (no NOAA needed).

test_that("parse_ghcn_stations reads fixed-width fields", {
  # columns per GHCN spec: ID 1-11, LAT 13-20, LON 22-30, ELEV 32-37, NAME 42-71
  ln <- c("USC00242347  46.0600 -114.2300 1240.0 MT COMO STATION                 ",
          "USC00240000  47.0000 -113.0000  900.0 MT OTHER STATION                ")
  f <- tempfile(); writeLines(ln, f)
  s <- parse_ghcn_stations(f)
  expect_equal(s$station_id, c("USC00242347", "USC00240000"))
  expect_equal(s$lat, c(46.06, 47.00))
  expect_equal(s$elev_m, c(1240, 900))
  expect_true(grepl("COMO", s$name[1]))
})

test_that("ghcn_candidates filters by radius, elevation, record length and caps count", {
  inv <- data.frame(
    station_id = sprintf("S%03d", 1:5),
    name = paste("st", 1:5),
    lat = c(46.06, 46.10, 46.20, 60.00, 46.05),   # #4 far away
    lon = c(-114.23, -114.20, -114.10, -140.0, -114.25),
    elev_m = c(1200, 1500, 200, 1300, 1400),      # #3 below band
    first_year = c(1950, 1960, 1970, 1980, 2015),
    last_year  = c(2020, 2020, 2020, 2020, 2020),
    stringsAsFactors = FALSE)
  inv$n_years_avail <- inv$last_year - inv$first_year + 1  # #5 too short (6 yr)
  cfg <- list(site = list(latitude = 46.06, longitude = -114.23),
              region = list(search_radius_km = 175, elevation_band_m = c(600, 2600),
                            min_record_years = 20, max_stations = 10))
  cand <- ghcn_candidates(inv, cfg)
  expect_setequal(cand$station_id, c("S001", "S002"))   # drops far, low-elev, short
  cfg$region$max_stations <- 1                          # cap keeps nearest only
  expect_equal(nrow(ghcn_candidates(inv, cfg)), 1)
})

test_that("download_ghcn_daily reads a cached .csv.gz without network", {
  cache <- tempfile(); dir.create(cache)
  gz <- file.path(cache, "S001.csv.gz")
  con <- gzfile(gz, "w")
  writeLines(c("S001,20000515,PRCP,401,,,",   # 40.1 mm
               "S001,20000516,TMAX,150,,,",    # ignored element
               "S001,20010610,PRCP,252,,,"), con)
  close(con)
  d <- download_ghcn_daily("S001", ghcn_base = "unused", cache_dir = cache)
  expect_equal(nrow(d), 2)                     # only PRCP rows
  expect_equal(d$prcp, c(40.1, 25.2))          # tenths mm -> mm
})
