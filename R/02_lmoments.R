# =============================================================================
# 02_lmoments.R  —  At-site sample L-moments -> regional data object
#
# Objective : compute sample L-moments (mean, L-CV t, L-skew t_3, L-kurt t_4)
#             for each station's AMS and assemble the lmomRFA "regdata" object.
# Inputs    : ams_list -> named list of data.frame(year, value) for one duration
# Outputs   : a regdata data.frame (columns name,n,l_1,t,t_3,t_4,t_5)
# Reference : H&W ch. 2 (L-moments), computed by lmomRFA::regsamlmu().
# =============================================================================

step02_lmoments <- function(ams_list) {
  vals <- lapply(ams_list, function(s) s$value)
  vals <- vals[vapply(vals, length, integer(1)) > 0]
  if (length(vals) < 5)
    stop("Need at least 5 stations to form a region; have ", length(vals), ".")
  rd <- regsamlmu(vals)            # name,n,l_1(mean),t(L-CV),t_3,t_4,t_5
  check_no_na_lmoments(rd)
  audit_log(sprintf("Computed at-site L-moments for %d stations.", nrow(rd)))
  rd
}
