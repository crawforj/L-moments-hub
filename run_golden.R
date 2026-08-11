#!/usr/bin/env Rscript
# =============================================================================
# run_golden.R  —  Golden-dataset validation, run SIDE-BY-SIDE with the site
#
# Runs the IDENTICAL pipeline on a known-answer case and scores the output, so a
# reviewer can confirm the machinery is correct and defensible (audit 9.3):
#   (a) synthetic known-truth : stations simulated from a KNOWN GEV regional
#       growth curve; the pipeline must recover the growth curve / 10,000-yr
#       factor within tolerance AND auto-select GEV.
#   (b) benchmark determinism : regtst() on the packaged Cascades example must
#       reproduce frozen reference statistics exactly (regression anchor).
#
# Usage : Rscript run_golden.R
# Exit  : non-zero if any golden check fails (CI-friendly).
# =============================================================================

root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
source(file.path(root, "run_analysis.R"))                 # brings in run_analysis() + steps
source(file.path(root, "R", "make_golden_data.R"))
load_packages()                                           # lmom/lmomRFA needed before data-gen

fail <- 0L
say  <- function(ok, msg) {
  cat(sprintf("[%s] %s\n", if (ok) "PASS" else "FAIL", msg))
  if (!ok) fail <<- fail + 1L
}

# ---- Ensure golden data exist (frozen; regenerate deterministically if absent)
if (!all(file.exists(file.path(root, "golden",
                               c("ams.csv", "stations.csv", "expected.json")))))
  make_golden_data(file.path(root, "config", "golden.yml"),
                   file.path(root, "golden"))
expected <- jsonlite::read_json(file.path(root, "golden", "expected.json"),
                                simplifyVector = TRUE)

# ---- (a) Synthetic known-truth recovery -----------------------------------
cat("\n=== Golden (a): synthetic known-truth recovery ===\n")
res <- run_analysis(file.path(root, "config", "golden.yml"))
pd  <- res$per_duration[[1]]
gc  <- pd$est$growth
gf_true <- expected$growth_factor_true[match(gc$T, expected$return_period_yr)]
rel_err <- abs(gc$growth_factor - gf_true) / gf_true

tol <- expected$tolerance
say(identical(pd$dist_sel$chosen, expected$distribution),
    sprintf("distribution auto-selected = %s (truth %s)",
            toupper(pd$dist_sel$chosen), toupper(expected$distribution)))
say(max(rel_err[gc$T <= 1000]) <= tol$growth_curve_rel,
    sprintf("growth curve within %.0f%% for T<=1000 (max err %.1f%%)",
            100 * tol$growth_curve_rel, 100 * max(rel_err[gc$T <= 1000])))
q10k_err <- rel_err[gc$T == 10000]
say(q10k_err <= tol$q_10000_rel,
    sprintf("10,000-yr growth factor within %.0f%% (err %.1f%%, est %.3f vs true %.3f)",
            100 * tol$q_10000_rel, 100 * q10k_err,
            gc$growth_factor[gc$T == 10000], expected$q10000_growth_true))

scorecard <- data.frame(T = gc$T, estimated = round(gc$growth_factor, 4),
                        truth = round(gf_true, 4), rel_err = round(rel_err, 4))
utils::write.csv(scorecard, file.path(root, "golden", "golden_scorecard.csv"),
                 row.names = FALSE)
cat("Scorecard written: golden/golden_scorecard.csv\n"); print(scorecard)

# ---- (b) Benchmark determinism on packaged Cascades example ----------------
cat("\n=== Golden (b): benchmark determinism (Cascades) ===\n")
data(Cascades, package = "lmomRFA")
set.seed(20260811)
tst <- regtst(Cascades, nsim = 500)
observed <- list(H = round(as.numeric(tst$H), 4),
                 Z = round(as.numeric(tst$Z), 4),
                 Dmax = round(max(tst$D), 4))
ref_path <- file.path(root, "golden", "cascades_reference.json")
if (!file.exists(ref_path)) {
  jsonlite::write_json(observed, ref_path, auto_unbox = TRUE, pretty = TRUE, digits = 8)
  say(TRUE, "froze Cascades reference (first run establishes the regression anchor)")
} else {
  ref <- jsonlite::read_json(ref_path, simplifyVector = TRUE)
  ok <- isTRUE(all.equal(observed$H, as.numeric(ref$H), tolerance = 1e-3)) &&
        isTRUE(all.equal(observed$Z, as.numeric(ref$Z), tolerance = 1e-3)) &&
        isTRUE(all.equal(observed$Dmax, as.numeric(ref$Dmax), tolerance = 1e-3))
  say(ok, sprintf("Cascades regtst reproduces frozen reference (H1=%.3f, max|Z-ref|<=1e-3)",
                  observed$H[1]))
}

cat(sprintf("\n=== GOLDEN VALIDATION: %s (%d failure%s) ===\n",
            if (fail == 0) "ALL PASS" else "FAILURES PRESENT",
            fail, if (fail == 1) "" else "s"))
if (fail > 0) quit(status = 1)
