# =============================================================================
# 09_plots.R  —  Diagnostic and result plots (deliverables)
#
# Objective : produce, for one duration,
#   (a) the L-moment ratio diagram (L-skewness vs L-kurtosis) with candidate
#       distribution curves, site points and the regional average — the visual
#       basis for distribution selection;
#   (b) the regional growth curve with candidate distributions overlaid and the
#       pooled at-site (scaled) data points — "station data relative to
#       distributions";
#   (c) the depth-duration-frequency curve with the Monte-Carlo uncertainty band.
# Inputs    : regdata_final, ams_used (named list), dist_sel, est, unc, cfg, label
# Outputs   : figure paths (PNG) under outputs/figures/
# =============================================================================

# Gumbel reduced variate y = -log(-log(F)); a straight line here => Gumbel.
gumbel_rv <- function(F) -log(-log(F))

step09_plots <- function(regdata_final, ams_used, dist_sel, est, unc, cfg,
                         label, out_dir) {
  id <- cfg$site$id
  figs <- character(0)

  # ---- (a) L-moment ratio diagram ------------------------------------------
  fa <- file.path(out_dir, "figures", sprintf("%s_%s_lmoment_ratio_diagram.png", id, label))
  grDevices::png(fa, width = 1200, height = 1050, res = 150)
  lmom::lmrd(distributions = "GLO GEV GPA GNO PE3",
             xlim = range(c(regdata_final$t_3, 0)) + c(-0.05, 0.05),
             ylim = range(c(regdata_final$t_4, 0.1)) + c(-0.05, 0.08),
             main = sprintf("L-moment ratio diagram — %s (%s)", cfg$site$name, label))
  lmom::lmrdpoints(regdata_final$t_3, regdata_final$t_4,
                   pch = 16, col = "grey40")
  # regional average (record-length weighted)
  wt <- regdata_final$n / sum(regdata_final$n)
  rt3 <- sum(wt * regdata_final$t_3); rt4 <- sum(wt * regdata_final$t_4)
  lmom::lmrdpoints(rt3, rt4, pch = 18, col = "red", cex = 2.2)
  graphics::legend("bottomright", c("sites", "regional average"),
                   pch = c(16, 18), col = c("grey40", "red"), bty = "n")
  grDevices::dev.off()
  figs <- c(figs, fa)

  # ---- (b) growth curve vs candidate distributions + pooled data -----------
  Fg <- c(seq(0.02, 0.98, by = 0.02), 0.99, 0.995, 0.999, 0.9999)
  yg <- gumbel_rv(Fg)
  fb <- file.path(out_dir, "figures", sprintf("%s_%s_growth_curve_fit.png", id, label))
  grDevices::png(fb, width = 1200, height = 1050, res = 150)
  graphics::par(mar = c(5, 4, 6, 2) + 0.1)      # extra top margin for the RP axis
  # candidate growth curves
  cand <- cfg$distributions
  cols <- grDevices::hcl.colors(length(cand), "Dark3")
  gc_cand <- lapply(cand, function(d) regquant(Fg, regfit(regdata_final, d)))
  ylim <- range(unlist(gc_cand), na.rm = TRUE)
  plot(yg, gc_cand[[1]], type = "n", ylim = ylim,
       xlab = "Gumbel reduced variate  -log(-log F)",
       ylab = "Growth factor  q(F)  (site data / site mean)")
  graphics::title(main = sprintf("Regional growth curve & candidate fits\n%s (%s)",
                                 cfg$site$name, label), line = 3.2)
  # pooled at-site scaled data points (each site's AMS / its mean)
  for (sid in names(ams_used)) {
    v <- sort(ams_used[[sid]]$value); v <- v / mean(v)
    points(gumbel_rv(cunnane_pp(length(v))), v, pch = 1, col = "grey70", cex = 0.6)
  }
  for (i in seq_along(cand))
    lines(yg, gc_cand[[i]], col = cols[i], lwd = 2,
          lty = ifelse(cand[i] == dist_sel, 1, 3))
  # secondary axis: return period ticks
  Tticks <- c(2, 10, 100, 1000, 10000)
  graphics::axis(3, at = gumbel_rv(rp_to_prob(Tticks)), labels = Tticks)
  graphics::mtext("Return period (yr)", side = 3, line = 2.2, cex = 0.9)
  graphics::legend("topleft",
    legend = c(paste0(toupper(cand), ifelse(cand == dist_sel, " (chosen)", "")),
               "pooled site data"),
    col = c(cols, "grey70"), lwd = c(rep(2, length(cand)), NA),
    lty = c(ifelse(cand == dist_sel, 1, 3), NA),
    pch = c(rep(NA, length(cand)), 1), bty = "n", cex = 0.9)
  grDevices::dev.off()
  figs <- c(figs, fb)

  # ---- (c) depth-duration-frequency with uncertainty band ------------------
  fc <- file.path(out_dir, "figures", sprintf("%s_%s_ddf_with_bounds.png", id, label))
  grDevices::png(fc, width = 1200, height = 1050, res = 150)
  graphics::par(mar = c(5, 4, 6, 2) + 0.1)      # extra top margin for the RP axis
  yT <- gumbel_rv(unc$F)
  plot(yT, unc$depth_mm, type = "n",
       ylim = range(c(unc$depth_lo, unc$depth_hi)),
       xlab = "Gumbel reduced variate  -log(-log F)",
       ylab = "Precipitation depth (mm)")
  graphics::title(main = sprintf("Depth-frequency, %s duration\n%s", label, cfg$site$name),
                  line = 3.2)
  graphics::polygon(c(yT, rev(yT)), c(unc$depth_lo, rev(unc$depth_hi)),
                    col = grDevices::adjustcolor("steelblue", 0.2), border = NA)
  lines(yT, unc$depth_mm, col = "steelblue", lwd = 2)
  points(yT, unc$depth_mm, pch = 16, col = "steelblue", cex = 0.7)
  Tticks <- c(2, 10, 100, 1000, 10000)
  graphics::axis(3, at = gumbel_rv(rp_to_prob(Tticks)), labels = Tticks)
  graphics::mtext("Return period (yr)", side = 3, line = 2.2, cex = 0.9)
  graphics::legend("topleft",
    c(sprintf("%s estimate", toupper(dist_sel)),
      sprintf("%g%% Monte-Carlo band", round((cfg$uncertainty$conf %||% 0.9) * 100))),
    col = c("steelblue", grDevices::adjustcolor("steelblue", 0.35)),
    lwd = c(2, 8), bty = "n")
  grDevices::dev.off()
  figs <- c(figs, fc)

  audit_log(sprintf("Plots written for %s: ratio diagram, growth-curve fit, DDF.", label))
  figs
}
