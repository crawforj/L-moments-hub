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

test_that("facility_diagnostics summarises H1/|Z| and flags facilities needing review", {
  mk <- function(H1, chosen, Z, acceptable, nstat) list(
    cfg = list(site = list(name = "X", id = "X01")),
    per_duration = list("24h" = list(
      regdata_final = data.frame(n = rep(30, nstat)),
      H = c(H1, 0, 0), homog_status = "ok",
      dist_sel = list(chosen = chosen, Z = Z, acceptable = acceptable))))
  # homogeneous + good fit -> no review
  d1 <- facility_diagnostics(mk(0.4, "gev", c(gev = 0.9, gno = 1.2), TRUE, 18))
  expect_equal(d1$n_stations, 18)
  expect_equal(d1$chosen_dist, "GEV")
  expect_equal(d1$chosen_absZ, 0.9)
  expect_false(d1$needs_review)
  # heterogeneous region (H1 >= 2) -> review
  expect_true(facility_diagnostics(mk(2.4, "gev", c(gev = 0.5), TRUE, 20))$needs_review)
  # poor fit (|Z| > 1.64 / not acceptable) -> review
  expect_true(facility_diagnostics(mk(0.3, "pe3", c(pe3 = 2.10), FALSE, 15))$needs_review)
})
