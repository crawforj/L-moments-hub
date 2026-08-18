# Tests for join_region_band() (R/functions.R) -- the region-method ensemble
# band annotation added to batch diagnostics (docs/CLUSTER_FLEET_RESULTS.md,
# "Ensemble band now shipped"). The join must be graceful: no band table on
# disk means the diagnostics table passes through UNCHANGED.

.toy_diag <- function() {
  data.frame(
    site     = c("HOOVER", "HOOVER", "COMO DAM"),
    site_id  = c("NV10122", "NV10122", "COMO_DAM"),
    duration = c("24h", "72h", "24h"),
    H1       = c(0.9, 0.3, 0.5),
    depth_10k_mm = c(130.2, 125.9, 88.0),
    needs_review = c(FALSE, FALSE, FALSE),
    stringsAsFactors = FALSE)
}

.toy_band_csv <- function(path) {
  band <- data.frame(
    site     = c("HOOVER", "HOOVER", "HOOVER", "OWYHEE"),
    site_id  = c("NV10122", "NV10122", "NV10122", "OR00585"),
    duration = c("24h", "24h", "72h", "24h"),
    return_period_yr = c(100, 10000, 10000, 10000),
    depth_circular_mm = c(80.1, 130.2, 125.9, 60.0),
    depth_cluster_mm  = c(90.0, 177.7, 140.0, 61.0),
    band_pct = c(11.0, 26.7, 10.1, 1.6),
    band_source = c("two_method", "two_method", "two_method", "identical_fallback"),
    stringsAsFactors = FALSE)
  utils::write.csv(band, path, row.names = FALSE)
  path
}

test_that("join_region_band is a graceful no-op when the band table is absent", {
  diag <- .toy_diag()
  out <- join_region_band(diag, band_csv = tempfile("no_such_band_", fileext = ".csv"))
  expect_identical(out, diag)              # bitwise unchanged: no new columns
})

test_that("join_region_band is a no-op on a malformed band table (missing columns)", {
  bad <- tempfile("bad_band_", fileext = ".csv")
  utils::write.csv(data.frame(site = "HOOVER", spread = 12), bad, row.names = FALSE)
  diag <- .toy_diag()
  expect_message(out <- join_region_band(diag, band_csv = bad), "unannotated")
  expect_identical(out, diag)
})

test_that("join_region_band annotates by site_id x duration at T=10,000 only", {
  band_csv <- .toy_band_csv(tempfile("band_", fileext = ".csv"))
  diag <- .toy_diag()
  out <- join_region_band(diag, band_csv = band_csv)

  # Pre-existing columns and row order preserved; two columns appended.
  expect_identical(out[, names(diag)], diag)
  expect_identical(setdiff(names(out), names(diag)),
                   c("region_band_pct_10k", "region_band_review"))

  # T=10,000 rows joined (NOT the T=100 row: 11.0 must not leak in).
  expect_equal(out$region_band_pct_10k, c(26.7, 10.1, NA))
  # Review flag: >15% TRUE, <=15% FALSE, no-comparison rows FALSE (not NA),
  # so downstream isTRUE_vec()-style filters stay NA-safe.
  expect_identical(out$region_band_review, c(TRUE, FALSE, FALSE))
})

test_that("join_region_band handles an empty diagnostics table", {
  band_csv <- .toy_band_csv(tempfile("band_", fileext = ".csv"))
  empty <- .toy_diag()[0, ]
  expect_identical(join_region_band(empty, band_csv = band_csv), empty)
})
