# =============================================================================
# checks.R  —  Embedded invariant assertions (audit layer 9.2)
#
# These guards are called at defined points in the pipeline. Each halts the run
# with a clear, specific message if an invariant is violated, so a silent numeric
# error cannot reach the published output. Passed checks are logged to build an
# audit trail (see audit_log()).
# =============================================================================

.audit_log_env <- new.env(parent = emptyenv())
.audit_log_env$entries <- character(0)

# audit_log(msg): append a timestamped line to the in-memory audit trail and echo.
audit_log <- function(msg) {
  line <- sprintf("[%s] %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), msg)
  .audit_log_env$entries <- c(.audit_log_env$entries, line)
  message(line)
  invisible(line)
}

# audit_log_write(path): flush the audit trail to a text file.
audit_log_write <- function(path) {
  writeLines(.audit_log_env$entries, path)
  invisible(path)
}

# check_that(cond, msg): assert cond is TRUE, else stop with msg. Logs on pass.
check_that <- function(cond, msg) {
  if (!isTRUE(cond)) stop("INVARIANT FAILED: ", msg, call. = FALSE)
  audit_log(paste0("OK  - ", msg))
  invisible(TRUE)
}

# check_no_na_lmoments(regdata): L-moment ratios must be finite for every site.
check_no_na_lmoments <- function(regdata) {
  cols <- intersect(c("l_1", "t", "t_3", "t_4"), names(regdata))
  ok <- all(is.finite(as.matrix(regdata[, cols])))
  check_that(ok, "no NA/Inf in at-site L-moments")
}

# check_station_reconcile(n_candidate, n_used, n_removed): counts must balance.
check_station_reconcile <- function(n_candidate, n_used, n_removed) {
  check_that(n_candidate == n_used + n_removed,
             sprintf("station counts reconcile (candidates %d = used %d + removed %d)",
                     n_candidate, n_used, n_removed))
}

# check_monotone_increasing(v, what): quantiles/growth curve must not decrease.
check_monotone_increasing <- function(v, what) {
  check_that(all(diff(v) >= -1e-8),
             sprintf("%s is monotone non-decreasing", what))
}

# check_heterogeneity_reported(H): H1 must be finite and reported.
check_heterogeneity_reported <- function(H) {
  check_that(is.finite(H[1]), "heterogeneity H1 computed and finite")
}

# check_gof_reported(Z, dists): a Z statistic exists for every candidate dist.
check_gof_reported <- function(Z, dists) {
  check_that(all(dists %in% names(Z)) && all(is.finite(Z[dists])),
             "goodness-of-fit Z reported for every candidate distribution")
}

# check_positive(v, what): depths/growth factors must be positive.
check_positive <- function(v, what) {
  check_that(all(v > 0), sprintf("%s are all positive", what))
}
