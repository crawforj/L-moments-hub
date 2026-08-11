# =============================================================================
# 00_setup.R  —  Load packages, source helpers, read config, set the seed.
#
# Sourced first by run_analysis.R / run_golden.R. Defines setup_analysis(),
# which returns the configuration list and prepares the output directories.
# =============================================================================

.here <- function(...) file.path(getOption("lmc.root", "."), ...)

# Load required packages, erroring with an actionable message if one is missing.
load_packages <- function() {
  needed <- c("lmom", "lmomRFA", "yaml", "jsonlite")
  optional <- c("ggplot2", "sf", "rnaturalearth", "rnaturalearthdata", "maps")
  for (p in needed) {
    if (!requireNamespace(p, quietly = TRUE))
      stop("Required package '", p, "' is not installed. See docs/users_guide.md ",
           "(section 'Installation').")
    suppressMessages(library(p, character.only = TRUE))
  }
  # Optional packages enable mapping/plots; absence degrades gracefully.
  for (p in optional)
    if (requireNamespace(p, quietly = TRUE))
      suppressMessages(library(p, character.only = TRUE))
  invisible(TRUE)
}

# setup_analysis(config_path): returns cfg and creates output folders.
setup_analysis <- function(config_path) {
  load_packages()
  cfg <- load_config(config_path)
  # Optional expert distribution-review registry (empty/absent => auto-select).
  cfg$distribution_review <- load_distribution_review(
    .here("config", "distribution_review.csv"))
  set.seed(cfg$seed %||% 1L)                 # reproducible screening/simulation
  for (d in c("outputs", "outputs/figures", "outputs/tables",
              "outputs/provenance", "data/processed"))
    dir.create(.here(d), showWarnings = FALSE, recursive = TRUE)
  cfg
}
