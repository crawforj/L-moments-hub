#!/usr/bin/env Rscript
# =============================================================================
# enrich_manifest_elevations.R  —  Durably fill elevation_m in a facility
#                                   manifest from a DEM.
#
# Why: `region.method: cluster` (Ward's-method cluster analysis, added in
# response to a Reclamation reviewer calling region-building "one of the most
# influential points in the L-moments analysis" -- see R/region_methods.R)
# clusters on site attributes including elevation. A manifest whose
# elevation_m is NA makes `cluster` silently fall back to `circular` (logged,
# not errored -- see cluster_candidates(): "site attributes (e.g. elevation)
# unavailable") for every such facility, i.e. the whole method becomes a
# no-op. That is exactly what happened on the BOR-308 set -- see
# docs/REGION_METHOD_SENSITIVITY.md and docs/ASSUMPTIONS_AND_LIMITATIONS.md
# section B item 5.
#
# enrich_elevations() (R/functions.R) does the DEM lookup and is wired into
# run_batch.R's gen_configs_from_manifest() behind LMC_ENRICH_ELEV=1 -- but
# only enriches the manifest IN MEMORY for that one run; it is never written
# back to the CSV, so every future run re-does the same DEM lookups. This
# script closes that gap: it fills elevation_m in place, once, durably.
#
# Usage:
#   Rscript enrich_manifest_elevations.R                    # BOR-308 + pilot-8
#   Rscript enrich_manifest_elevations.R config/nid_manifest.csv
#   Rscript enrich_manifest_elevations.R --zoom 10 --cell 1 <path> [<path> ...]
#
# Effect: rewrites each manifest IN PLACE, filling elevation_m where it was
#         missing. Every other column/row is preserved exactly (read.csv ->
#         mutate elevation_m only -> write.csv, same pattern as
#         enrich_drainage_area.R; verified byte-identical round-trip on the
#         73,303-row NID manifest).
#
# ---------------------------------------------------------------------------
# CHUNKING AND RESOLUTION (recorded, because both are result-affecting)
# ---------------------------------------------------------------------------
# The lookup is chunked_elevatr_lookup() (R/functions.R), NOT the bare
# elevatr_lookup(), for two reasons measured on 2026-08-19:
#
#   * RESOLUTION. elevatr::get_elev_point(src = "aws") defaults to z = 5
#     (~4 km/pixel). Benchmarked against 14 dams of independently known
#     elevation, z = 5 gave median |error| 29 m and max 294 m (Taylor Park,
#     CO -- a 294 m error on an attribute the clustering runs on). z = 8 and
#     above converge to ~5 m median. Default here is z = 10.
#
#       z= 5 : median |err| 29.0 m , max 294 m
#       z= 8 : median |err|  5.0 m , max  50 m
#       z=10 : median |err|  7.0 m , max  66 m
#       z=12 : median |err|  5.5 m , max  41 m
#
#     (the residual at z >= 8 is dominated by reference-definition mismatch --
#     crest vs pool vs tailwater at the published coordinate -- not by DEM
#     error, so z = 10 is effectively converged for this purpose.)
#
#   * BATCH NONDETERMINISM. get_elev_raster() mosaics the tiles covering the
#     bounding box of ALL points in one call and reprojects to the points'
#     CRS, so a point's value depends on which other points shared its call.
#     chunked_elevatr_lookup() bins points onto a FIXED lat/lon grid
#     (--cell, default 1 degree) and issues one call per occupied cell, so a
#     point's bbox -- and its value -- follow from its own coordinates alone.
#     Results are reproducible for a given (cell_deg, zoom) and are unchanged
#     by how the work is split across processes.
#
# Recorded settings for the NID run-2 enrichment: cell_deg = 1, zoom = 10,
# 913 occupied cells over 73,303 rows.
# =============================================================================

root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
root <- normalizePath(root)

source(file.path(root, "R", "functions.R"))

args <- commandArgs(TRUE)
get_opt <- function(flag, default) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  val <- as.numeric(args[i + 1]); args <<- args[-c(i, i + 1)]
  if (is.na(val)) default else val
}
ZOOM <- get_opt("--zoom", 10)
CELL <- get_opt("--cell", 1)
paths <- args[!startsWith(args, "--")]
if (!length(paths))
  paths <- file.path(root, "config", c("facilities_BOR.csv", "pilot.csv"))

enrich_one <- function(path) {
  m <- utils::read.csv(path, stringsAsFactors = FALSE)
  elev_before <- suppressWarnings(as.numeric(m$elevation_m))
  n_missing_before <- sum(is.na(elev_before))
  if (!n_missing_before) {
    message(sprintf("%s: already fully populated (%d rows) -- nothing to do.",
                    basename(path), nrow(m)))
    return(invisible(m))
  }

  n_cells <- length(unique(paste(floor(as.numeric(m$latitude) / CELL),
                                 floor(as.numeric(m$longitude) / CELL))))
  message(sprintf("%s: %d rows, %d missing, %d occupied %g-deg cells at zoom %g ...",
                  basename(path), nrow(m), n_missing_before, n_cells, CELL, ZOOM))

  t0 <- Sys.time()
  m2 <- enrich_elevations(m, lookup = function(lat, lon)
    chunked_elevatr_lookup(lat, lon, zoom = ZOOM, cell_deg = CELL))
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

  elev_after <- suppressWarnings(as.numeric(m2$elevation_m))
  n_have <- sum(!is.na(elev_after))
  utils::write.csv(m2, path, row.names = FALSE)

  message(sprintf(
    "%s: %d/%d facilities (%.2f%%) now have a real elevation_m (was %d missing) -- %.1fs.",
    basename(path), n_have, nrow(m2), 100 * n_have / nrow(m2), n_missing_before, elapsed))
  invisible(m2)
}

for (p in paths) enrich_one(p)

message("\nDone. Source: elevatr::get_elev_point(src = \"aws\", z = ", ZOOM,
        ") -- AWS Terrain Tiles DEM, public, no auth; chunked on a fixed ",
        CELL, "-degree grid. See the header of this file for the resolution ",
        "benchmark and the batch-determinism rationale.")
