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

test_that("screen_qflag NAs failed-QA values, keeps blanks and retained codes", {
  v <- c(10, 20, 30, 40)
  q <- c("", " ", "G", "X")                    # blank/space pass; G,X are failed-QA
  out <- screen_qflag(v, q)                    # default: drop every non-blank flag
  expect_equal(as.numeric(out), c(10, 20, NA, NA))
  expect_equal(attr(out, "n_flagged"), 2L)
  # keep = "G" retains that code but still drops X
  expect_equal(as.numeric(screen_qflag(v, q, keep = "G")), c(10, 20, 30, NA))
  # screen = FALSE or NULL qflag is a no-op
  expect_equal(screen_qflag(v, q, screen = FALSE), v)
  expect_equal(screen_qflag(v, NULL), v)
})

test_that("download_ghcn_daily screens QFLAG'd observations (col 6)", {
  cache <- tempfile(); dir.create(cache)
  gz <- file.path(cache, "S002.csv.gz")
  con <- gzfile(gz, "w")
  writeLines(c("S002,20000515,PRCP,401,,,",    # clean -> 40.1 mm
               "S002,20010610,PRCP,999,,G,",   # failed QA (QFLAG=G) -> screened to NA
               "S002,20020712,PRCP,252,,,"),   # clean -> 25.2 mm
             con); close(con)
  d <- download_ghcn_daily("S002", ghcn_base = "unused", cache_dir = cache)
  expect_equal(nrow(d), 3)                      # all PRCP rows returned
  expect_equal(d$prcp, c(40.1, NA, 25.2))       # the G-flagged value is NA
  # with screening disabled the flagged value passes through (999 tenths -> 99.9)
  d2 <- download_ghcn_daily("S002", ghcn_base = "unused", cache_dir = cache,
                            qflag_screen = FALSE)
  expect_equal(d2$prcp, c(40.1, 99.9, 25.2))
})

test_that("download_ghcn_daily reads the AWS S3 mirror format (header row, uncompressed)", {
  expect_true(ghcn_is_s3("https://noaa-ghcn-pds.s3.amazonaws.com"))
  expect_false(ghcn_is_s3("https://www.ncei.noaa.gov/pub/data/ghcn/daily"))
  cache <- tempfile(); dir.create(cache)
  # S3 by_station schema HAS a header and an OBS_TIME column; QFLAG is still col 6.
  writeLines(c("ID,DATE,ELEMENT,DATA_VALUE,M_FLAG,Q_FLAG,S_FLAG,OBS_TIME",
               "USX,20000515,PRCP,401,,,6,",     # clean -> 40.1 mm
               "USX,20010610,PRCP,999,,G,6,",    # failed QA -> NA
               "USX,20000516,TMAX,150,,,6,"),    # ignored element
             file.path(cache, "USX.csv"))
  d <- download_ghcn_daily("USX", "https://noaa-ghcn-pds.s3.amazonaws.com", cache_dir = cache)
  expect_equal(nrow(d), 2)                        # PRCP rows only, header consumed
  expect_equal(d$prcp, c(40.1, NA))               # tenths->mm; G-flagged screened
})

test_that("make_demo_data centers on the requested site (offline batch works anywhere)", {
  # A non-Como facility (Grand Coulee, WA) must still get an in-region set.
  d <- tempfile(); site <- list(latitude = 47.96, longitude = -118.98)
  meta <- make_demo_data(d, center_lat = site$latitude, center_lon = site$longitude,
                         radius_km = 200)
  st <- utils::read.csv(file.path(d, "stations.csv"), stringsAsFactors = FALSE)
  cfg <- list(site = site,
              region = list(search_radius_km = 200, elevation_band_m = c(600, 2600)))
  filt <- filter_candidates(st, cfg)
  expect_gte(nrow(filt$kept), 12)                       # a usable region forms
  expect_true("DEMO17" %in% filt$removed$station_id)    # the 'far' gauge is excluded
  # stations are actually near the requested site, not Como
  expect_lt(max(filt$kept$distance_km), 200)
})
