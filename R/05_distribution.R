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

step05_distribution <- function(tst, cfg, duration_label = NULL, review = NULL) {
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

  # Precedence: expert review > config override > automatic (smallest |Z|).
  # Automated runs (no review registry, no override) auto-select as before.
  res <- resolve_distribution(table, cfg, cfg$site$id %||% "",
                              duration_label %||% "", review)
  chosen <- res$chosen
  audit_log(sprintf("Distribution [%s]: %s via %s (|Z|=%.3f%s).",
                    duration_label %||% "-", toupper(chosen), res$source,
                    abs(Z[chosen]),
                    ifelse(abs(Z[chosen]) <= 1.64, "", " - NOTE |Z|>1.64")))
  list(chosen = chosen, Z = Z, table = table,
       acceptable = isTRUE(abs(Z[chosen]) <= 1.64),
       source = res$source, reviewer = res$reviewer)
}
