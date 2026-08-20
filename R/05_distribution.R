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

# ---------------------------------------------------------------------------
# choose_single_family(): pick ONE distribution family for a facility across
# ALL durations, instead of letting each duration select independently.
#
# WHY (run 2 only; run 1 keeps per-duration selection, see
# docs/NID_RUN2_CLUSTER_PLAN.md). Fitting each duration independently lets the
# 24-h and 72-h growth curves cross in the extrapolated tail: ~15% of fleet
# facilities report a 72-h depth BELOW their 24-h depth at T >= 200, which is
# physically impossible (a 72-h window contains its worst 24 h).
# docs/analysis/cross_duration_consistency.md shows the mechanism is strictly
# directional family selection -- a crossing occurs iff the 24-h fit picks a
# HEAVIER-tailed family than the 72-h fit (ordered pair 24h=GLO/72h=GEV crosses
# 93.8% of the time, 2,777 of 2,961 sites; every mirrored ordering crosses
# 0.0%). Forcing one family per facility removes ~71% of crossings at source.
# NOAA reached the same diagnosis independently and adopted a single family
# across durations for exactly this reason (Atlas 14 Vol. 2 sec. 4.6.3, and
# Vol. 9 sec. 4.6.3 on discontinuities at rare frequencies).
#
# AGGREGATION RULE: MINIMAX -- choose the candidate minimizing the MAXIMUM |Z|
# across durations, i.e. the family whose WORST-fitting duration fits best.
# Deliberately not the sum/mean of |Z|, for two reasons:
#   1. It preserves the meaning of the H&W acceptance threshold. Z^DIST is
#      approximately N(0,1) under the hypothesis that the candidate fits, and
#      |Z| <= 1.64 is the acceptance rule (H&W sec. 5.2.3). Under minimax the
#      selected family is acceptable at EVERY duration iff its score is
#      <= 1.64, so the reported `acceptable` flag keeps its usual reading. A
#      sum or mean can select a family that fits one duration superbly and
#      fails the other badly, and no threshold on the aggregate detects that.
#   2. A sum implicitly treats the per-duration Z's as independent evidence to
#      be pooled. They are not independent -- the durations share stations and
#      overlapping data windows -- so the pooled statistic has no distribution
#      to justify it. The maximum needs no independence assumption.
# Ties (exactly equal max |Z|) break on mean |Z|, then on the order of
# cfg$distributions, so the choice is deterministic.
#
#   z_list : named list, duration label -> named numeric vector of Z by dist
#            (i.e. the `Z` element of each step05_distribution() result)
#   cand   : candidate distribution codes (cfg$distributions)
#   -> list(chosen, score, per_duration_absZ, table) or NULL when no candidate
#      has a finite score at every duration (caller then keeps per-duration
#      selection, with the reason logged).
# ---------------------------------------------------------------------------
choose_single_family <- function(z_list, cand) {
  if (!length(z_list) || !length(cand)) return(NULL)
  # rows = candidate, cols = duration; NA/non-finite -> Inf (family unusable
  # at that duration, so it can never win a minimax).
  M <- vapply(z_list, function(Z) {
    v <- suppressWarnings(abs(as.numeric(Z[cand])))
    v[!is.finite(v)] <- Inf
    v
  }, numeric(length(cand)))
  M <- matrix(M, nrow = length(cand),
              dimnames = list(cand, names(z_list)))
  worst <- apply(M, 1, max)
  if (!any(is.finite(worst))) return(NULL)
  avg <- apply(M, 1, function(r) if (all(is.finite(r))) mean(r) else Inf)
  ord <- order(worst, avg, seq_along(cand))       # deterministic tie-break
  best <- cand[ord[1]]
  tbl <- data.frame(dist = cand, max_absZ = round(worst, 3),
                    mean_absZ = round(avg, 3), stringsAsFactors = FALSE)
  tbl <- tbl[ord, ]
  list(chosen = best, score = worst[ord[1]],
       per_duration_absZ = M[ord[1], , drop = TRUE], table = tbl)
}
