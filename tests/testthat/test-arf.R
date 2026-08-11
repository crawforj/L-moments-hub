# Tests for R/arf.R -- the Areal Reduction Factor added for Reclamation
# reviewer feedback ("is an ARF computed and applied?").

test_that("leclerc_schaake_arf returns 1 for zero/negligible area (no reduction)", {
  expect_equal(leclerc_schaake_arf(0, 24), 1)
  expect_equal(leclerc_schaake_arf(NA_real_, 24), 1)
})

test_that("leclerc_schaake_arf decreases monotonically with area, for fixed duration", {
  areas <- c(1, 10, 100, 1000, 10000)
  arfs <- vapply(areas, leclerc_schaake_arf, numeric(1), duration_hr = 24)
  expect_true(all(diff(arfs) < 0))
  expect_true(all(arfs > 0 & arfs <= 1))
})

test_that("leclerc_schaake_arf is vectorised over duration for a fixed area", {
  out <- leclerc_schaake_arf(146.1, c(24, 72))
  expect_length(out, 2)
  # A longer duration spreads the same area's storm more evenly -> less reduction.
  expect_gt(out[2], out[1])
})

test_that("compute_arf matches the known Como-scale figure and rejects unknown methods", {
  cfg <- list(arf = list(method = "leclerc_schaake"))
  got <- compute_arf(146.1, 24, cfg)
  expect_equal(round(got, 4), 0.9622)   # cross-checked against a manual run_analysis.R run

  cfg2 <- list(arf = list(method = "bogus"))
  expect_error(compute_arf(146.1, 24, cfg2), "Unknown arf.method")

  cfg3 <- list()                        # no arf block -> default method, no error
  expect_equal(compute_arf(146.1, 24, cfg3), got)
})

test_that("site_drainage_area_km2 converts mi2 -> km2 and degrades gracefully", {
  expect_equal(round(site_drainage_area_km2(list(site = list(drainage_area_mi2 = 56.4))), 1), 146.1)
  expect_true(is.na(site_drainage_area_km2(list(site = list()))))
  expect_true(is.na(site_drainage_area_km2(list(site = list(drainage_area_mi2 = NA)))))
  expect_true(is.na(site_drainage_area_km2(list(site = list(drainage_area_mi2 = -5)))))
})
