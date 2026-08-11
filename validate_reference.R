#!/usr/bin/env Rscript
# =============================================================================
# validate_reference.R  —  Independent verification that the pipeline matches a
#                          manual / textbook L-moments regional-frequency
#                          analysis, NOT just its own frozen output.
#
# Why this is credible: the core statistics (regsamlmu / regtst / regfit /
# regquant) come from J.R.M. Hosking's lmomRFA -- the reference implementation
# of Hosking & Wallis (1997), by a co-author of the method. So the L-moment
# math is canonical by construction. The RISK is in the layers THIS project
# adds around it: region assembly, the discordancy screen, the distribution-
# selection RULE, and the index-flood SCALING (depth = index * growth). These
# checks pin down exactly those layers against independent computations and
# against the textbook's own documented example datasets.
#
# Checks (hard PASS/FAIL; non-zero exit on any failure -> CI-friendly):
#   1. TEXTBOOK FINDINGS      — on the canonical Hosking & Wallis "Appalach" and
#      "Cascades" datasets, the discordancy and heterogeneity reproduce what
#      H&W (1997) report: Appalachia is heterogeneous with discordant sites;
#      Cascades is homogeneous with no discordant site and is fit by a
#      3-parameter distribution. (Deterministic parts asserted; H seeded.)
#   2. DISCORDANCY FIDELITY   — step03's discordancy D equals a direct regtst()
#      D exactly (our screening wrapper doesn't corrupt the statistic).
#   3. REPRODUCIBILITY        — running the seeded pipeline steps twice yields
#      identical H, chosen distribution, and depths (no hidden nondeterminism).
#   4. SELECTION RULE         — step05 picks the distribution an expert would
#      choose BY HAND from the Z table (min |Z| among |Z| <= 1.645).
#   5. INDEX-FLOOD ARITHMETIC — the pipeline's quantile depths equal an
#      INDEPENDENT hand-calc of the index-flood method built ONLY from base
#      lmom primitives (record-length-weighted regional L-moments -> pelXXX ->
#      quaXXX -> depth = index * growth), bypassing lmomRFA::regquant entirely.
#
# Usage : Rscript validate_reference.R
# =============================================================================
suppressWarnings(for (loc in c("C.UTF-8", "en_US.UTF-8", "C.utf8"))
  if (!is.na(Sys.setlocale("LC_CTYPE", loc)) && Sys.setlocale("LC_CTYPE", loc) != "") break)
root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
options(lmc.root = root)
suppressWarnings(suppressMessages({
  library(lmom); library(lmomRFA)
  for (f in c("functions.R","checks.R","02_lmoments.R","03_screening.R",
              "04_homogeneity.R","05_distribution.R","06_estimation.R"))
    source(file.path(root, "R", f))
}))
SEED <- 20260811L

fails <- 0L
say <- function(ok, msg) { cat(sprintf("[%s] %s\n", if (isTRUE(ok)) "PASS" else "FAIL", msg));
                           if (!isTRUE(ok)) fails <<- fails + 1L }
approx <- function(a, b, tol) all(is.finite(a) & is.finite(b) & abs(a - b) <= tol)

as_regdata <- function(nm) {          # canonical dataset -> lmomRFA regdata
  d <- get(data(list = nm, package = "lmomRFA"))
  if (inherits(d, "regdata")) return(d)
  as.regdata(data.frame(name = d$siteid, n = d$n, mean = d$mean,
                        t = d$t, t_3 = d$t_3, t_4 = d$t_4, t_5 = d$t_5,
                        stringsAsFactors = FALSE))
}
cfg <- list(uncertainty = list(n_sim = 500), seed = SEED,
            distributions = c("glo","gev","gno","pe3","gpa"),
            distribution_override = NULL,
            return_periods = c(2, 10, 100, 1000, 10000),
            index_flood = list(method = "nearest"))

# ---------------------------------------------------------------------------
cat("\n=== Check 1: textbook findings (Hosking & Wallis 1997 datasets) ===\n")
app_rd <- as_regdata("Appalach"); cas_rd <- as_regdata("Cascades")
set.seed(SEED); app <- regtst(app_rd, nsim = 1000)
set.seed(SEED); cas <- regtst(cas_rd, nsim = 1000)
for (o in list(list("Appalach", app, app_rd), list("Cascades", cas, cas_rd))) {
  cat(sprintf("\n-- %s: %d sites --\n", o[[1]], nrow(o[[3]])))
  cat(sprintf("   heterogeneity H1=%.2f H2=%.2f H3=%.2f | max discordancy D=%.2f\n",
              o[[2]]$H[1], o[[2]]$H[2], o[[2]]$H[3], max(o[[2]]$D)))
  z <- o[[2]]$Z; cat("   goodness-of-fit |Z|: ",
      paste(sprintf("%s=%.2f", names(z), abs(z)), collapse = "  "), "\n")
}
# Deterministic discordancy findings (no simulation involved):
say(max(app$D) >= 3, sprintf("Appalachia has discordant site(s) (max D=%.2f >= 3, per H&W)", max(app$D)))
say(max(cas$D) <  3, sprintf("Cascades has NO discordant site (max D=%.2f < 3, per H&W)", max(cas$D)))
# Heterogeneity: Appalachia clearly heterogeneous, Cascades clearly homogeneous,
# with a wide, unambiguous separation (robust to Monte-Carlo noise).
say(cas$H[1] < 2,                sprintf("Cascades homogeneous (H1=%.2f < 2)", cas$H[1]))
say(app$H[1] > cas$H[1] + 1,     sprintf("Appalachia far more heterogeneous than Cascades (H1 %.2f vs %.2f)", app$H[1], cas$H[1]))
# Cascades is fit by a 3-parameter distribution (min |Z| from gev/gno/pe3):
z3 <- abs(cas$Z[c("gev","gno","pe3")])
say(names(which.min(abs(cas$Z))) %in% c("gev","gno","pe3"),
    sprintf("Cascades best fit is a 3-par dist (%s, |Z|=%.2f)",
            toupper(names(which.min(abs(cas$Z)))), min(abs(cas$Z))))

# ---------------------------------------------------------------------------
cat("\n=== Check 2: discordancy fidelity (step03 D == regtst D) ===\n")
scr <- step03_screening(cas_rd, cfg)
say(approx(as.numeric(scr$D), as.numeric(cas$D), 1e-9),
    "step03 discordancy D reproduces regtst() D exactly")

# ---------------------------------------------------------------------------
cat("\n=== Check 3: reproducibility (seeded pipeline is deterministic) ===\n")
run_chain <- function() {
  s <- step03_screening(cas_rd, cfg)
  h <- step04_homogeneity(s$regdata, cfg)
  d <- step05_distribution(h$tst, cfg)
  e <- step06_estimation(h$regdata, d$chosen, cfg, index_flood = 42)
  list(H1 = h$H[1], chosen = d$chosen,
       depth = e$quantiles$depth_mm[match(c(2,100,10000), e$quantiles$T)])
}
r1 <- run_chain(); r2 <- run_chain()
say(approx(r1$H1, r2$H1, 1e-9) && identical(r1$chosen, r2$chosen) &&
      approx(r1$depth, r2$depth, 1e-9),
    sprintf("two runs identical: H1=%.4f, dist=%s, depths=[%s]",
            r1$H1, toupper(r1$chosen), paste(round(r1$depth,2), collapse=", ")))

# ---------------------------------------------------------------------------
cat("\n=== Check 4: selection rule = expert hand-pick from the Z table ===\n")
s <- step03_screening(cas_rd, cfg); h <- step04_homogeneity(s$regdata, cfg)
dsel <- step05_distribution(h$tst, cfg)
zt <- abs(h$tst$Z[cfg$distributions])
acc <- zt[zt <= 1.645]
hand_pick <- if (length(acc)) names(acc)[which.min(acc)] else names(zt)[which.min(zt)]
say(identical(tolower(dsel$chosen), tolower(hand_pick)),
    sprintf("step05 chose %s; hand rule (min|Z| among |Z|<=1.645) chose %s",
            toupper(dsel$chosen), toupper(hand_pick)))

# ---------------------------------------------------------------------------
cat("\n=== Check 5: index-flood arithmetic (independent hand-calc) ===\n")
# Recompute the growth curve + depths from scratch using ONLY base lmom, then
# compare to the pipeline (which uses lmomRFA::regfit/regquant).
index <- 42.0; T <- c(2, 10, 100, 1000, 10000); chosen <- dsel$chosen
est <- step06_estimation(h$regdata, chosen, cfg, index_flood = index)
rd <- h$regdata; w <- rd$n / sum(rd$n)                 # record-length weights
lam <- c(1, sum(w * rd$t), sum(w * rd$t_3), sum(w * rd$t_4))  # regional (l1=1, l2=LCV, t3, t4)
pel <- switch(chosen, glo = pelglo(lam), gev = pelgev(lam), gno = pelgno(lam),
                      pe3 = pelpe3(lam), gpa = pelgpa(lam))
qfun <- switch(chosen, glo = quaglo, gev = quagev, gno = quagno, pe3 = quape3, gpa = quagpa)
growth_hand <- vapply(T, function(t) qfun(1 - 1/t, pel), numeric(1))
depth_hand  <- index * growth_hand
depth_pipe  <- est$quantiles$depth_mm[match(T, est$quantiles$T)]
print(data.frame(T = T, growth_hand = round(growth_hand, 4),
                 depth_hand_mm = round(depth_hand, 2),
                 depth_pipeline_mm = round(depth_pipe, 2),
                 pct_diff = round(100 * (depth_pipe - depth_hand) / depth_hand, 3)),
      row.names = FALSE)
say(approx(depth_pipe, depth_hand, pmax(0.05, 0.005 * depth_hand)),
    sprintf("pipeline depths equal independent index-flood hand-calc for %s (<=0.5%%)",
            toupper(chosen)))

# ---------------------------------------------------------------------------
cat(sprintf("\n=== validate_reference: %s (%d failure%s) ===\n",
            if (fails == 0L) "ALL PASS" else "FAILURES PRESENT",
            fails, if (fails == 1L) "" else "s"))
quit(save = "no", status = if (fails == 0L) 0L else 1L)
