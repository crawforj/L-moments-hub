# Integration tests: run the analytical steps on a small synthetic region with a
# KNOWN GEV growth curve and assert the invariants and recovery. Fast (small nsim).

make_cfg <- function() list(
  uncertainty = list(n_sim = 100, conf = 0.90),
  distributions = c("glo", "gev", "gno", "pe3", "gpa"),
  distribution_override = NULL,
  return_periods = c(2, 10, 100, 1000, 10000),
  index_flood = list(method = "nearest"),
  site = list(elevation_m = 1200),
  seed = 42)

synth_region <- function(nS = 20, nY = 120, para = c(50, 15, -0.10), seed = 1) {
  set.seed(seed)
  m <- mean(quagev((seq_len(5000) - 0.5) / 5000, para))
  idx <- seq(40, 60, length.out = nS)
  vals <- lapply(seq_len(nS), function(i)
    data.frame(year = seq_len(nY), value = idx[i] * quagev(runif(nY), para) / m))
  stats::setNames(vals, sprintf("S%02d", seq_len(nS)))
}

test_that("L-moments assemble with no NA and correct site count", {
  rd <- step02_lmoments(synth_region())
  expect_equal(nrow(rd), 20)
  expect_true(all(is.finite(rd$t_3)))
})

test_that("screening keeps a clean homogeneous region and estimation is monotone", {
  cfg <- make_cfg()
  rd  <- step02_lmoments(synth_region())
  scr <- step03_screening(rd, cfg)
  expect_gte(nrow(scr$regdata), 5)
  hom <- step04_homogeneity(scr$regdata, cfg)
  expect_true(hom$H[1] < 2)                    # acceptably homogeneous
  dsel <- step05_distribution(hom$tst, cfg)
  est  <- step06_estimation(hom$regdata, dsel$chosen, cfg, index_flood = 50)
  expect_true(all(diff(est$growth$growth_factor) > 0))   # monotone growth curve
  expect_true(all(est$quantiles$depth_mm > 0))
})

test_that("pipeline recovers the true GEV 10,000-yr growth factor within 12%", {
  cfg  <- make_cfg()
  para <- c(50, 15, -0.10)
  m    <- mean(quagev((seq_len(20000) - 0.5) / 20000, para))
  g_true_10k <- quagev(0.9999, para) / m
  rd   <- step02_lmoments(synth_region(nS = 25, nY = 200, para = para, seed = 7))
  scr  <- step03_screening(rd, cfg)
  hom  <- step04_homogeneity(scr$regdata, cfg)
  dsel <- step05_distribution(hom$tst, cfg)
  expect_identical(dsel$chosen, "gev")         # auto-selects the true family
  est  <- step06_estimation(hom$regdata, "gev", cfg, index_flood = 1)
  g10k <- est$growth$growth_factor[est$growth$T == 10000]
  expect_lt(abs(g10k / g_true_10k - 1), 0.12)
})
