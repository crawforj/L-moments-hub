# =============================================================================
# 05_distribution.R  —  Distribution selection (H&W step 3)
#
# Objective : choose the regional frequency distribution using the Z-statistic
#             goodness-of-fit measure, with the L-moment ratio diagram produced
#             separately (09_plots.R) as the visual companion.
# Inputs    : tst (a regtst object for the final region), cfg
# Outputs   : list(chosen = distribution code,
#                  Z = named vector of Z^DIST,
#                  table = data.frame(dist, Z, absZ, acceptable),
#                  acceptable = logical for the chosen dist)
# Rule      : |Z^DIST| <= 1.64 indicates acceptable fit; among the candidates
#             the smallest |Z| is chosen (H&W sec. 5.2.3). A config override
#             (distribution_override) forces a specific choice.
# =============================================================================

step05_distribution <- function(tst, cfg) {
  cand <- cfg$distributions
  Z <- tst$Z
  check_gof_reported(Z, cand)

  absZ <- abs(Z[cand])
  table <- data.frame(
    dist       = cand,
    Z          = round(Z[cand], 3),
    absZ       = round(absZ, 3),
    acceptable = absZ <= 1.64,
    stringsAsFactors = FALSE)
  table <- table[order(table$absZ), ]

  if (!is.null(cfg$distribution_override)) {
    chosen <- cfg$distribution_override
    audit_log(sprintf("Distribution overridden by config: %s.", toupper(chosen)))
  } else {
    chosen <- table$dist[1]
    audit_log(sprintf("Distribution selected: %s (|Z|=%.3f%s).",
                      toupper(chosen), table$absZ[1],
                      ifelse(table$acceptable[1], "", " — NOTE |Z|>1.64")))
  }
  list(chosen = chosen, Z = Z, table = table,
       acceptable = isTRUE(abs(Z[chosen]) <= 1.64))
}
