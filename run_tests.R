#!/usr/bin/env Rscript
# =============================================================================
# run_tests.R  —  Run the testthat unit + integration suite.
# Usage : Rscript run_tests.R      (exit non-zero on any failure; CI-friendly)
# =============================================================================
suppressWarnings(for (loc in c("C.UTF-8", "en_US.UTF-8", "C.utf8"))
  if (!is.na(Sys.setlocale("LC_CTYPE", loc)) && Sys.setlocale("LC_CTYPE", loc) != "") break)

root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
root <- normalizePath(root)   # test_dir() changes the working directory while running
                               # tests, so a relative "." root would resolve to the
                               # wrong place inside a test -- make it absolute up front.
options(lmc.root = root)

suppressMessages({library(lmom); library(lmomRFA); library(testthat)})
for (f in c("functions.R", "region_methods.R", "make_demo_data.R", "checks.R", "00_setup.R",
            "01_data_acquisition.R", "02_lmoments.R", "03_screening.R",
            "04_homogeneity.R", "05_distribution.R", "06_estimation.R",
            "07_uncertainty.R"))
  source(file.path(root, "R", f))

rep <- test_dir(file.path(root, "tests", "testthat"), reporter = "summary",
                stop_on_failure = FALSE)
df <- as.data.frame(rep)
fails <- sum(df$failed) + sum(df$error)
cat(sprintf("\nTOTAL: %d passed, %d failed/error.\n", sum(df$passed), fails))
if (fails > 0) quit(status = 1)
