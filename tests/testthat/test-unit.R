# Unit tests for the portable helper functions (fast, no simulation).

test_that("haversine_km is zero at a point and ~111 km per degree latitude", {
  expect_equal(haversine_km(46, -114, 46, -114), 0)
  expect_true(abs(haversine_km(46, -114, 47, -114) - 111.19) < 1.0)
})

test_that("in_season handles normal and wrap-around windows", {
  d <- as.Date(c("2000-03-15", "2000-05-10", "2000-08-01", "2000-12-20"))
  expect_equal(in_season(d, 4, 7), c(FALSE, TRUE, FALSE, FALSE))   # Apr–Jul
  expect_equal(in_season(d, 11, 2), c(FALSE, FALSE, FALSE, TRUE))  # Nov–Feb wrap
})

test_that("rolling_sum sums d-day windows and propagates missing days", {
  x <- c(1, 2, 3, 4, 5)
  expect_equal(rolling_sum(x, 1), x)
  expect_equal(rolling_sum(x, 3)[3:5], c(6, 9, 12))
  xn <- c(1, NA, 3, 4, 5)
  expect_true(is.na(rolling_sum(xn, 3)[3]))   # window contains an NA
  expect_equal(rolling_sum(xn, 3)[5], 12)     # window 3..5 complete
})

test_that("build_ams_from_daily extracts seasonal annual maxima", {
  dates <- seq(as.Date("2000-01-01"), as.Date("2001-12-31"), by = "day")
  daily <- data.frame(date = dates, prcp = 0)
  daily$prcp[daily$date == as.Date("2000-05-15")] <- 40   # in season (Apr–Jul)
  daily$prcp[daily$date == as.Date("2000-09-15")] <- 99   # out of season -> ignored
  daily$prcp[daily$date == as.Date("2001-06-10")] <- 25
  ams <- build_ams_from_daily(daily, days = 1, factor = 1,
                              season = list(start_month = 4, end_month = 7),
                              min_complete = 0)
  expect_equal(ams$value[ams$year == 2000], 40)  # not 99 (out of season)
  expect_equal(ams$value[ams$year == 2001], 25)
})

test_that("cunnane_pp is increasing and inside (0,1)", {
  p <- cunnane_pp(10)
  expect_true(all(diff(p) > 0) && all(p > 0 & p < 1))
})

test_that("return-period <-> probability conversions invert", {
  Ts <- c(2, 10, 100, 10000)
  expect_equal(prob_to_rp(rp_to_prob(Ts)), Ts)
  expect_equal(rp_to_prob(10000), 0.9999)
})

test_that("estimate_index_flood regression predicts at the site elevation", {
  meta <- data.frame(elev_m = c(1000, 1500, 2000), distance_km = c(5, 10, 15))
  means <- c(30, 40, 50)                       # linear in elevation
  cfg <- list(site = list(elevation_m = 1250),
              index_flood = list(method = "regression"))
  expect_equal(estimate_index_flood(meta, means, cfg), 35, tolerance = 1e-6)
})

test_that("estimate_index_flood falls back to the regional mean when site elevation is missing", {
  meta <- data.frame(elev_m = c(1000, 1500, 2000), distance_km = c(5, 10, 15))
  means <- c(30, 40, 50)
  # Blank site elevation (the common dam-inventory case) must NOT crash the
  # regression path; it falls back to the regional mean (= 40).
  for (e in list(NA, NA_real_, NULL, "")) {
    cfg <- list(site = list(elevation_m = e), index_flood = list(method = "regression"))
    expect_equal(estimate_index_flood(meta, means, cfg), 40, tolerance = 1e-6)
  }
})

test_that("enrich_elevations fills only missing elevations and no-ops offline", {
  man <- data.frame(name = c("a", "b", "c"),
                    latitude = c(46, 47, 48), longitude = c(-114, -115, -116),
                    elevation_m = c(1200, NA, NA))
  # mock DEM: returns 900 + 100*index for the requested (missing) points
  mock <- function(lat, lon) 900 + 100 * seq_along(lat)
  out <- enrich_elevations(man, lookup = mock)
  expect_equal(out$elevation_m, c(1200, 1000, 1100))   # existing kept, missing filled
  # offline / unavailable lookup -> missing stay NA (safe; index-flood uses mean)
  off <- enrich_elevations(man, lookup = function(lat, lon) rep(NA_real_, length(lat)))
  expect_equal(off$elevation_m, c(1200, NA, NA))
  # a manifest with no elevation_m column gains one
  man2 <- data.frame(latitude = 46, longitude = -114)
  expect_true("elevation_m" %in% names(enrich_elevations(man2, lookup = function(a, b) 1500)))
})

test_that("resolve_distribution: expert review > config override > auto", {
  zt <- data.frame(dist = c("gev", "gno", "glo"), absZ = c(0.3, 0.9, 1.5),
                   stringsAsFactors = FALSE)
  # automatic: smallest |Z|
  a <- resolve_distribution(zt, cfg = list(), site_id = "X01", duration = "72h", review = NULL)
  expect_equal(a$chosen, "gev"); expect_equal(a$source, "auto")
  # config override
  c1 <- resolve_distribution(zt, cfg = list(distribution_override = "pe3"),
                             site_id = "X01", duration = "72h", review = NULL)
  expect_equal(c1$chosen, "pe3"); expect_equal(c1$source, "config_override")
  # expert review wins for the matching facility+duration, over the config override
  rev <- data.frame(facility_id = "X01", duration = "72h", distribution = "glo",
                    reviewer = "R", stringsAsFactors = FALSE)
  e <- resolve_distribution(zt, cfg = list(distribution_override = "pe3"),
                            site_id = "X01", duration = "72h", review = rev)
  expect_equal(e$chosen, "glo"); expect_equal(e$source, "expert_review")
  # blank duration applies to all durations
  revall <- data.frame(facility_id = "X01", duration = "", distribution = "gno",
                       reviewer = "R", stringsAsFactors = FALSE)
  expect_equal(resolve_distribution(zt, list(), "X01", "24h", revall)$chosen, "gno")
  # non-matching facility falls back to auto
  expect_equal(resolve_distribution(zt, list(), "OTHER", "72h", rev)$source, "auto")
})

test_that("load_distribution_review reads rows, skips comments, NULL when empty/absent", {
  f <- tempfile(fileext = ".csv")
  writeLines(c("# a comment", "facility_id,duration,distribution,reviewer,date,notes",
               "COMO_DAM,72h,GLO,R,2026-01-01,note"), f)
  rv <- load_distribution_review(f)
  expect_equal(nrow(rv), 1)
  expect_equal(rv$distribution, "glo")            # lower-cased
  expect_equal(rv$facility_id, "COMO_DAM")
  # header + comments only -> NULL (auto-select everywhere)
  g <- tempfile(fileext = ".csv")
  writeLines(c("# only comments", "facility_id,duration,distribution,reviewer,date,notes"), g)
  expect_null(load_distribution_review(g))
  expect_null(load_distribution_review(tempfile()))   # absent file
})

test_that("append_cum_csv: site_id-keyed fold-in survives name collisions and mixed schema", {
  td <- tempfile(); dir.create(td)
  src <- file.path(td, "src.csv"); dst <- file.path(td, "dst.csv")
  keys <- c("site_id", "duration", "return_period_yr")
  fb   <- c("site", "duration", "return_period_yr")

  # -- historical cumulative file: OLD schema, NO site_id column, and two
  #    DIFFERENT facilities that share one dam name (the national-collision case)
  old <- data.frame(site = c("MILL POND DAM", "LAKE DAM"),
                    duration = "24h", return_period_yr = 100,
                    depth_mm = c(50, 60), stringsAsFactors = FALSE)
  utils::write.csv(old, dst, row.names = FALSE)

  # -- new tranche output: NEW schema WITH site_id; one facility whose NAME
  #    collides with a historical row, plus two same-named facilities with
  #    DISTINCT site_ids (must BOTH survive)
  new <- data.frame(site_id = c("TX001", "GA002", "MI003"),
                    site = c("MILL POND DAM", "MILL POND DAM", "OTTER DAM"),
                    duration = "24h", return_period_yr = 100,
                    depth_mm = c(70, 80, 90), stringsAsFactors = FALSE)
  utils::write.csv(new, src, row.names = FALSE)

  append_cum_csv(src, dst, keys, fallback_key_cols = fb)
  out <- utils::read.csv(dst, stringsAsFactors = FALSE)

  # No rows lost: 2 historical + 3 new = 5 (nothing collapsed across schemas)
  expect_equal(nrow(out), 5)
  expect_true("site_id" %in% names(out))
  # duplicate-named facilities with distinct site_ids BOTH survive
  expect_equal(sum(out$site == "MILL POND DAM" & !is.na(out$site_id)), 2)
  expect_setequal(out$site_id[!is.na(out$site_id)], c("TX001", "GA002", "MI003"))
  # historical NA-site_id rows keep their legacy name key: both survive, and
  # the name-colliding new row did NOT overwrite the historical MILL POND DAM
  hist <- out[is.na(out$site_id), ]
  expect_equal(nrow(hist), 2)
  expect_setequal(hist$site, c("MILL POND DAM", "LAKE DAM"))
  expect_equal(hist$depth_mm[hist$site == "MILL POND DAM"], 50)

  # -- idempotent: folding the SAME tranche again changes nothing
  append_cum_csv(src, dst, keys, fallback_key_cols = fb)
  out2 <- utils::read.csv(dst, stringsAsFactors = FALSE)
  reord <- function(d) { d <- d[order(d$site, d$depth_mm), ]; rownames(d) <- NULL; d }
  expect_equal(reord(out2), reord(out))

  # -- re-run of one facility replaces (not duplicates) its row
  upd <- new; upd$depth_mm[upd$site_id == "TX001"] <- 71
  utils::write.csv(upd, src, row.names = FALSE)
  append_cum_csv(src, dst, keys, fallback_key_cols = fb)
  out3 <- utils::read.csv(dst, stringsAsFactors = FALSE)
  expect_equal(nrow(out3), 5)
  expect_equal(out3$depth_mm[!is.na(out3$site_id) & out3$site_id == "TX001"], 71)

  # -- all-NA-key rows must NOT collapse together even with many of them
  many_na <- data.frame(site = paste0("DAM_", 1:4), duration = "72h",
                        return_period_yr = 500, depth_mm = 1:4,
                        stringsAsFactors = FALSE)
  dst2 <- file.path(td, "dst2.csv"); utils::write.csv(many_na, dst2, row.names = FALSE)
  src2 <- file.path(td, "src2.csv")
  utils::write.csv(data.frame(site_id = "Z9", site = "DAM_9", duration = "72h",
                              return_period_yr = 500, depth_mm = 9,
                              stringsAsFactors = FALSE), src2, row.names = FALSE)
  append_cum_csv(src2, dst2, keys, fallback_key_cols = fb)
  expect_equal(nrow(utils::read.csv(dst2)), 5)      # 4 legacy + 1 new, none merged

  # -- primary-keyed table WITHOUT fallback (e.g. tail_sensitivity carries
  #    site_id throughout): same-name/different-id rows both survive
  src3 <- file.path(td, "src3.csv"); dst3 <- file.path(td, "dst3.csv")
  utils::write.csv(data.frame(site = "MILL POND DAM", site_id = "TX001",
                              duration = "24h", dist = "GEV", depth_mm = 1,
                              stringsAsFactors = FALSE), dst3, row.names = FALSE)
  utils::write.csv(data.frame(site = "MILL POND DAM", site_id = "GA002",
                              duration = "24h", dist = "GEV", depth_mm = 2,
                              stringsAsFactors = FALSE), src3, row.names = FALSE)
  append_cum_csv(src3, dst3, c("site_id", "duration", "dist"),
                 fallback_key_cols = c("site", "duration", "dist"))
  expect_equal(nrow(utils::read.csv(dst3)), 2)
  unlink(td, recursive = TRUE)
})
