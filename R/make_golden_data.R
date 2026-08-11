# =============================================================================
# make_golden_data.R  —  Generate the synthetic known-truth GOLDEN dataset
#
# PURPOSE: create a region of stations whose data are drawn from a KNOWN GEV
# regional growth curve with KNOWN site index floods, so the pipeline can be
# scored on whether it recovers the truth (audit layer 9.3b). Deterministic
# (fixed seed); outputs are frozen in golden/ and used by run_golden.R and the
# regression test.
#
# Writes: golden/stations.csv, golden/ams.csv, golden/expected.json
# =============================================================================

make_golden_data <- function(config_path = "config/golden.yml",
                             out_dir = "golden") {
  cfg <- yaml::read_yaml(config_path)
  tr  <- cfg$golden_truth
  para <- as.numeric(tr$gev_param)          # c(xi, alpha, k) growth-curve shape
  nS   <- tr$n_sites
  nY   <- tr$years_per_site
  idx  <- if (!is.null(tr$index_floods)) as.numeric(tr$index_floods)
          else seq(tr$index_flood_min, tr$index_flood_max, length.out = nS)
  stopifnot(length(idx) == nS)

  # Theoretical mean of GEV(para): numerically, so growth curve g(F)=Q(F)/m has mean 1.
  pp <- (seq_len(20000) - 0.5) / 20000
  m  <- mean(quagev(pp, para))

  set.seed(tr$seed %||% 12345)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  # Station metadata (coordinates are nominal; golden case ignores geography).
  meta <- data.frame(
    station_id = sprintf("GOLD%02d", seq_len(nS)),
    name = paste("Golden site", seq_len(nS)),
    lat = 46.0 + stats::runif(nS, -0.5, 0.5),
    lon = -114.0 + stats::runif(nS, -0.5, 0.5),
    elev_m = round(stats::runif(nS, 1000, 1600)),
    stringsAsFactors = FALSE)
  utils::write.csv(meta, file.path(out_dir, "stations.csv"), row.names = FALSE)

  # Annual-maximum series: value_ij = index_i * quagev(u, para) / m  (mean ~ index_i).
  ams <- do.call(rbind, lapply(seq_len(nS), function(i) {
    y <- quagev(stats::runif(nY), para) / m
    data.frame(station_id = meta$station_id[i],
               year = seq_len(nY),
               value = round(idx[i] * y, 4))
  }))
  utils::write.csv(ams, file.path(out_dir, "ams.csv"), row.names = FALSE)

  # Expected (truth) growth factors at the configured return periods.
  Tvec <- sort(unique(cfg$return_periods))
  Fvec <- 1 - 1 / Tvec
  g_true <- quagev(Fvec, para) / m
  expected <- list(
    distribution = tr$distribution,
    theoretical_mean = m,
    return_period_yr = Tvec,
    growth_factor_true = as.numeric(g_true),
    q10000_growth_true = as.numeric(g_true[Tvec == 10000]),
    index_floods_true = idx,
    tolerance = tr$tolerance)
  jsonlite::write_json(expected, file.path(out_dir, "expected.json"),
                       auto_unbox = TRUE, pretty = TRUE, digits = 8)
  message(sprintf("Golden data written: %d sites x %d yr; theoretical mean=%.4f.",
                  nS, nY, m))
  invisible(expected)
}
