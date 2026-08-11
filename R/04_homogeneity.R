# =============================================================================
# 04_homogeneity.R  —  Define a homogeneous region (H&W step 2)
#
# Objective : test regional homogeneity with the heterogeneity measure H, and
#             iteratively refine region membership until it is acceptably
#             homogeneous. Every add/drop decision is logged (audit trail).
# Inputs    : regdata (post-screening), cfg
# Outputs   : list(regdata = final homogeneous region,
#                  removed  = data.frame of sites dropped for homogeneity,
#                  H        = final c(H1,H2,H3),
#                  status   = "homogeneous" | "acceptably homogeneous" | "heterogeneous",
#                  history  = per-iteration record of n sites and H1,
#                  tst      = final regtst object)
#
# Decision rule (H&W sec. 4.3.4), applied to H1 (based on L-CV):
#   H1 < 1  -> acceptably homogeneous
#   1..2    -> possibly heterogeneous
#   H1 >= 2 -> definitely heterogeneous (region must be revised)
#
# Refinement: greedily remove the single site whose omission most reduces H1,
# stopping when H1 < 1, or no removal improves H1, or floor constraints are hit
# (>= 5 sites and <= 30% of the screened region removed). This is a transparent,
# reproducible stand-in for the expert region revision described in H&W.
# =============================================================================

step04_homogeneity <- function(regdata, cfg) {
  nsim_final  <- cfg$uncertainty$n_sim %||% 500
  nsim_search <- min(200L, nsim_final)          # cheaper sims for the greedy search
  min_sites   <- 5L
  max_drop    <- max(0L, floor(0.30 * nrow(regdata)))
  target_H    <- 1.0                            # aim for acceptably homogeneous

  H1_of <- function(rd, nsim) {
    set.seed(cfg$seed %||% 1L)                  # fixed seed -> comparable H across candidates
    regtst(rd, nsim = nsim)$H[1]
  }

  rd <- regdata
  removed_ids <- character(0)
  history <- data.frame(iter = integer(0), n = integer(0), H1 = numeric(0))
  iter <- 0L
  repeat {
    H1 <- H1_of(rd, nsim_search)
    history <- rbind(history, data.frame(iter = iter, n = nrow(rd), H1 = round(H1, 3)))
    audit_log(sprintf("Homogeneity iter %d: n=%d, H1=%.3f", iter, nrow(rd), H1))
    if (H1 < target_H) break
    if (nrow(rd) <= min_sites || length(removed_ids) >= max_drop) break

    # Leave-one-out: find the site whose removal minimises H1.
    cand_H1 <- vapply(seq_len(nrow(rd)),
                      function(i) H1_of(rd[-i, ], nsim_search), numeric(1))
    best <- which.min(cand_H1)
    if (cand_H1[best] >= H1 - 1e-6) break        # no improvement -> stop

    removed_ids <- c(removed_ids, rd$name[best])
    audit_log(sprintf("  drop '%s' -> H1 %.3f (was %.3f)",
                      rd$name[best], cand_H1[best], H1))
    rd <- rd[-best, ]
    iter <- iter + 1L
  }

  H_final <- regtst(rd, nsim = nsim_final)$H
  status <- if (H_final[1] < 1) "homogeneous" else
            if (H_final[1] < 2) "acceptably homogeneous (H1 in [1,2))" else
            "heterogeneous (H1 >= 2 — review region manually)"
  check_heterogeneity_reported(H_final)
  audit_log(sprintf("Final region: n=%d, H1=%.3f (%s)", nrow(rd), H_final[1], status))

  removed <- if (length(removed_ids))
    data.frame(station_id = removed_ids, name = removed_ids,
               reason = "dropped to achieve homogeneity (greedy H1 reduction)",
               stringsAsFactors = FALSE) else
    data.frame(station_id = character(0), name = character(0), reason = character(0))

  list(regdata = rd, removed = removed, H = H_final, status = status,
       history = history, tst = regtst(rd, nsim = nsim_final))
}
