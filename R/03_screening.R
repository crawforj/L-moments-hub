# =============================================================================
# 03_screening.R  —  Discordancy screening (H&W step 1)
#
# Objective : flag and remove stations whose sample L-moment ratios are grossly
#             discordant with the group, using the discordancy measure Di.
# Inputs    : regdata, cfg
# Outputs   : list(regdata = kept sites,
#                  removed  = data.frame(station_id,name,Di,Dcrit,reason),
#                  D, Dcrit)
# Rule      : a site is discordant when Di >= Dcrit (critical value depends on
#             the number of sites; supplied by lmomRFA::regtst). H&W sec. 3.2.4.
# =============================================================================

step03_screening <- function(regdata, cfg) {
  nsim <- cfg$uncertainty$n_sim %||% 500
  tst  <- regtst(regdata, nsim = nsim)
  Di   <- tst$D
  # regtst returns Dcrit as c(10%, 5%) critical values (capped at 3 and 4;
  # H&W sec. 3.2.4). Use the standard HW discordancy flag: the <=3 value.
  Dcrit <- tst$Dcrit[1]
  disc <- Di >= Dcrit

  removed <- data.frame(
    station_id = regdata$name[disc],
    name       = regdata$name[disc],
    Di         = round(Di[disc], 3),
    Dcrit      = rep(round(Dcrit, 3), sum(disc)),
    reason     = rep(sprintf("discordant (Di >= Dcrit = %.3f)", Dcrit), sum(disc)),
    stringsAsFactors = FALSE)

  kept <- regdata[!disc, ]
  audit_log(sprintf("Discordancy screening: Dcrit=%.3f, removed %d of %d sites.",
                    Dcrit, sum(disc), nrow(regdata)))
  check_that(nrow(kept) >= 5,
             "at least 5 stations remain after discordancy screening")
  list(regdata = kept, removed = removed, D = Di, Dcrit = Dcrit)
}
