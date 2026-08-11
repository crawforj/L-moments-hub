# =============================================================================
# 07_uncertainty.R  —  Monte-Carlo error bounds on the growth curve / quantiles
#
# Objective : quantify sampling uncertainty of the regional growth curve and the
#             site quantiles, emphasised at the extreme (10,000-yr) tail.
# Inputs    : regdata (final region), est (from step06), cfg
# Outputs   : data.frame(T, F, growth_factor, gc_lo, gc_hi,
#                        depth_mm, depth_lo, depth_hi, rel_rmse)
#
# Method    : parametric bootstrap following H&W Table 6.1 / eqs. (6.15),(6.18).
#             For each of n_sim replicate regions we simulate each site's
#             growth-curve sample (mean 1) from the fitted regional distribution,
#             re-estimate the regional L-moments and growth curve, and collect
#             the simulated growth curves. Reported bounds are the conf-level
#             percentiles of the simulated growth curves; rel_rmse is the
#             relative root-mean-square error of the estimator.
#
# NOTE: this transparent bootstrap replaces lmomRFA::regsimq(), which fails with
# a numerical-integration error in the installed package version. Using the same
# regfit()/regquant() estimation path keeps the uncertainty consistent with the
# point estimate and fully auditable.
# =============================================================================

step07_uncertainty <- function(regdata, est, cfg) {
  dist  <- est$dist
  nrep  <- cfg$uncertainty$n_sim %||% 500
  conf  <- cfg$uncertainty$conf %||% 0.90
  lowp  <- (1 - conf) / 2
  highp <- 1 - lowp

  Tvec  <- est$growth$T
  Fvec  <- est$growth$F
  gc_hat <- est$growth$growth_factor
  qfun  <- get(paste0("qua", dist))             # e.g. quagev
  para  <- est$para
  n     <- regdata$n

  set.seed(cfg$seed %||% 1L)
  sims <- matrix(NA_real_, nrep, length(Fvec))
  for (r in seq_len(nrep)) {
    sim_vals <- lapply(n, function(ni) qfun(runif(ni), para))
    rd <- regsamlmu(sim_vals)
    rf <- tryCatch(regfit(rd, dist), error = function(e) NULL)
    if (!is.null(rf)) sims[r, ] <- regquant(Fvec, rf)
  }

  gc_lo <- apply(sims, 2, stats::quantile, probs = lowp,  na.rm = TRUE)
  gc_hi <- apply(sims, 2, stats::quantile, probs = highp, na.rm = TRUE)
  rel_rmse <- sqrt(colMeans((sims / matrix(gc_hat, nrep, length(Fvec),
                                           byrow = TRUE) - 1)^2, na.rm = TRUE))

  mu <- est$index_flood
  out <- data.frame(
    T = Tvec, F = Fvec,
    growth_factor = gc_hat, gc_lo = as.numeric(gc_lo), gc_hi = as.numeric(gc_hi),
    depth_mm = mu * gc_hat, depth_lo = mu * as.numeric(gc_lo),
    depth_hi = mu * as.numeric(gc_hi), rel_rmse = as.numeric(rel_rmse))

  audit_log(sprintf("Uncertainty: %d-rep bootstrap; 10,000-yr rel-RMSE=%.3f, %d%% band [%.1f, %.1f] mm.",
                    nrep, out$rel_rmse[nrow(out)], round(conf * 100),
                    out$depth_lo[nrow(out)], out$depth_hi[nrow(out)]))
  out
}
