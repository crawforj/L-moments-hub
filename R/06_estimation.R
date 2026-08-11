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

# ---------------------------------------------------------------------------
# tail_sensitivity(): how much does the DISTRIBUTION CHOICE move the extreme
# tail? Fits EVERY candidate distribution to the same regional L-moments and
# reports the growth factor and depth at the target return period(s), so a
# reviewer can see the spread at the 10,000-yr extrapolation (where the
# candidates diverge most and the choice matters most — H&W ch. 5). Pure over
# lmomRFA::regfit/regquant; a candidate that fails to fit is skipped (NA).
#   regdata     : the final region (regdata object)
#   candidates  : character vector of distribution codes
#   index_flood : site index flood (mm)
#   T           : return period(s), years (default 10000)
#   -> data.frame(dist, T, growth_factor, depth_mm), one row per dist x T.
# ---------------------------------------------------------------------------
tail_sensitivity <- function(regdata, candidates, index_flood, T = 10000) {
  Fv <- rp_to_prob(T)
  rows <- lapply(candidates, function(d) {
    q <- tryCatch(as.numeric(regquant(Fv, regfit(regdata, d))),
                  error = function(e) rep(NA_real_, length(Fv)))
    data.frame(dist = toupper(d), T = T, growth_factor = round(q, 4),
               depth_mm = round(index_flood * q, 2), stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  out[order(out$T, out$depth_mm), ]
}
