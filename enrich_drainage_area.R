#!/usr/bin/env Rscript
# =============================================================================
# enrich_drainage_area.R  —  Add watershed drainage area to the dam manifests
#
# Reclamation reviewer question: "Is an areal reduction factor (ARF) computed
# and applied?" It was not (docs/ASSUMPTIONS_AND_LIMITATIONS.md item 7 says so
# explicitly) -- an ARF needs the dam's contributing drainage area, which
# config/facilities_BOR.csv and config/nid_manifest.csv did not carry.
#
# The SAME third-party NID mirror already used to build those two manifests
# (lcford2/predict-release, see DATA_SOURCES.md sec. 2) carries a
# `Drainage_Area` column (square miles, per the standard NID schema) that was
# simply not selected when the manifests were originally built. This script
# re-derives it from that identical source and joins it on by NID_ID, so no
# new external data source is introduced.
#
# Usage: Rscript enrich_drainage_area.R
# Effect: rewrites config/facilities_BOR.csv and config/nid_manifest.csv IN
#         PLACE, adding a drainage_area_mi2 column (NA where the mirror has no
#         value -- unchanged, still UNVERIFIED like every other manifest field;
#         see DATA_SOURCES.md).
# =============================================================================

root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
root <- normalizePath(root)

NID_MIRROR_URL <- "https://raw.githubusercontent.com/lcford2/predict-release/master/nid_data/all_dams_data.csv"
cache_dir <- file.path(root, "data", "raw", "nid_mirror")
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
cache_path <- file.path(cache_dir, "all_dams_data.csv")

if (!file.exists(cache_path)) {
  message("Downloading the NID mirror (same source as the existing manifests) ...")
  if (getOption("timeout") < 300L) options(timeout = 300L)
  utils::download.file(NID_MIRROR_URL, cache_path, quiet = TRUE, mode = "wb")
}
raw <- utils::read.csv(cache_path, stringsAsFactors = FALSE)
da <- data.frame(
  facility_id = trimws(as.character(raw$NID_ID)),
  drainage_area_mi2 = suppressWarnings(as.numeric(raw$Drainage_Area)),
  stringsAsFactors = FALSE)
da <- da[!duplicated(da$facility_id), ]

enrich_one <- function(path) {
  m <- utils::read.csv(path, stringsAsFactors = FALSE)
  m$facility_id <- trimws(as.character(m$facility_id))
  m$drainage_area_mi2 <- da$drainage_area_mi2[match(m$facility_id, da$facility_id)]
  utils::write.csv(m, path, row.names = FALSE)
  n_have <- sum(!is.na(m$drainage_area_mi2))
  message(sprintf("%s: %d/%d facilities (%.1f%%) got a drainage_area_mi2 value.",
                  basename(path), n_have, nrow(m), 100 * n_have / nrow(m)))
  invisible(m)
}

enrich_one(file.path(root, "config", "facilities_BOR.csv"))
enrich_one(file.path(root, "config", "nid_manifest.csv"))
message("\nDone. Values are from the same UNVERIFIED ~2013 NID mirror as the rest of the ",
       "manifest -- see DATA_SOURCES.md. Re-run enrich_elevations()-style review before ",
       "engineering use.")
