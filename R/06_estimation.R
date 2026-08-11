# =============================================================================
# 06_estimation.R  —  Index-flood quantile estimation (H&W step 4)
#
# Objective : fit the chosen regional distribution, form the regional growth
#             curve q(F), and produce site quantiles Q(F) = index_flood * q(F)
#             for the configured return periods (out to 10,000 yr / AEP 1e-4).
# Inputs    : regdata (final region), dist (chosen), cfg, used_meta, index_flood
# Outputs   : list(rfd, growth = data.frame(T,F,growth_factor),
#                  quantiles = data.frame(T,F,depth_mm), index_flood, para)
# Reference : H&W ch. 6 (regional growth curve and index-flood estimation),
#             computed by lmomRFA::regfit() and regquant().
# =============================================================================

step06_estimation <- function(regdata, dist, cfg, index_flood) {
  rfd  <- regfit(regdata, dist)                 # regional growth curve fit
  Tvec <- sort(unique(cfg$return_periods))
  Fvec <- rp_to_prob(Tvec)                      # F = 1 - 1/T
  gc   <- regquant(Fvec, rfd)                   # growth factors q(F), mean = 1

  check_monotone_increasing(gc, "regional growth curve q(F)")
  check_positive(gc, "growth factors")

  depth <- index_flood * gc                     # at-site quantiles Q(F)
  check_positive(depth, "quantile depths")

  growth <- data.frame(T = Tvec, F = round(Fvec, 6),
                       growth_factor = as.numeric(gc))
  quantiles <- data.frame(T = Tvec, F = round(Fvec, 6),
                          depth_mm = as.numeric(depth))

  audit_log(sprintf("Estimation: %s fitted; index flood = %.2f mm; q(1e-4/AEP)=%.3f.",
                    toupper(dist), index_flood, gc[length(gc)]))
  list(rfd = rfd, growth = growth, quantiles = quantiles,
       index_flood = index_flood, para = rfd$para, dist = dist)
}
