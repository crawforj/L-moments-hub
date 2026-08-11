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
