#!/usr/bin/env Rscript
# =============================================================================
# enrich_manifest_elevations.R  —  Durably fill elevation_m in the BOR-308 and
#                                   pilot-8 facility manifests from a DEM.
#
# Why: `region.method: cluster` (Ward's-method cluster analysis, added in
# response to a Reclamation reviewer calling region-building "one of the most
# influential points in the L-moments analysis" -- see R/region_methods.R)
# clusters on site attributes including elevation. Every facility in
# config/facilities_BOR.csv and config/pilot.csv has elevation_m = NA, so
# `cluster` has silently fallen back to `circular` (logged, not errored) for
# every facility except Como (hand-set elevation) -- see
# docs/REGION_METHOD_SENSITIVITY.md and docs/ASSUMPTIONS_AND_LIMITATIONS.md
# section B item 5.
#
# enrich_elevations() (R/functions.R) already does the DEM lookup (elevatr ::
# get_elev_point, AWS Terrain Tiles, no auth) and is wired into
# run_batch.R's gen_configs_from_manifest() behind LMC_ENRICH_ELEV=1 -- but
# only enriches the manifest IN MEMORY for that one run; it is never written
# back to the CSV, so every future run re-does the same DEM lookups. This
# script closes that gap: it fills elevation_m in place, once, durably.
#
# Scope: config/facilities_BOR.csv (308 rows) and config/pilot.csv (8 rows)
# ONLY. Deliberately does NOT touch config/nid_manifest.csv (73,303 rows) --
# a much larger DEM-lookup cost/scope decision reserved for the project
# owner.
#
# Usage: Rscript enrich_manifest_elevations.R
# Effect: rewrites config/facilities_BOR.csv and config/pilot.csv IN PLACE,
#         filling elevation_m where it was missing. Every other column/row is
#         preserved exactly (read.csv -> mutate elevation_m only -> write.csv,
#         same pattern as enrich_drainage_area.R).
# =============================================================================

root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
root <- normalizePath(root)

source(file.path(root, "R", "functions.R"))

enrich_one <- function(path) {
  m <- utils::read.csv(path, stringsAsFactors = FALSE)
  elev_before <- suppressWarnings(as.numeric(m$elevation_m))
  n_missing_before <- sum(is.na(elev_before))

  t0 <- Sys.time()
  m2 <- enrich_elevations(m)
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  elev_after <- suppressWarnings(as.numeric(m2$elevation_m))
  n_have <- sum(!is.na(elev_after))
  utils::write.csv(m2, path, row.names = FALSE)

  message(sprintf(
    "%s: %d/%d facilities (%.1f%%) now have a real elevation_m (was %d missing) -- %.1fs.",
    basename(path), n_have, nrow(m2), 100 * n_have / nrow(m2), n_missing_before, elapsed))
  invisible(m2)
}

enrich_one(file.path(root, "config", "facilities_BOR.csv"))
enrich_one(file.path(root, "config", "pilot.csv"))
message("\nDone. Source: elevatr::get_elev_point(src = \"aws\") -- AWS Terrain Tiles DEM, ",
        "public point lookup, no auth. NOT run against config/nid_manifest.csv (73,303 rows) ",
        "-- that remains a separate, larger cost/scope decision for the project owner. ",
        "See docs/ASSUMPTIONS_AND_LIMITATIONS.md section B item 5.")
