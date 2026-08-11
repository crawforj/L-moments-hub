#!/usr/bin/env Rscript
# =============================================================================
# refresh_nid_live.R  —  Refresh the dam manifests from the CURRENT, live NID
#
# config/facilities_BOR.csv and config/nid_manifest.csv were built from a
# third-party ~2013 NID mirror (see DATA_SOURCES.md). The current NID is
# publicly queryable, no auth, via USACE's ESRI FeatureServer -- confirmed
# reachable from this machine 2026-08-11. This script:
#   1. Pulls the full current NID (paginated, ~92,600 dams) from the live
#      service.
#   2. For every facility_id already in our manifests, refreshes coordinates,
#      river name, storage, and drainage area from the live record, and adds
#      operational_status / nid_data_updated / coord_drift_km columns.
#   3. Reports (does NOT silently add) facility_ids present in the live NID
#      but not in our manifests, and facility_ids in our manifests not found
#      live -- both are scope decisions for a human, not this script.
#   4. Flags which ALREADY-COMPLETED ledger facilities (data/nid_progress/
#      completed_ids.csv) drifted enough to be worth re-running, and requeues
#      only those -- everything else is left alone (graceful: this should not
#      invalidate hours of correct, already-committed work over sub-km GPS
#      precision differences).
#
# Usage: Rscript refresh_nid_live.R [--requeue-drift-km 5] [--apply]
#   Without --apply, this is a DRY RUN: prints the diff report, writes
#   nothing. Review the report before re-running with --apply.
# =============================================================================
source("R/functions.R")

args <- commandArgs(trailingOnly = TRUE)
getarg <- function(flag, default) {
  i <- match(flag, args)
  if (is.na(i) || i == length(args)) return(default)
  args[i + 1]
}
APPLY <- "--apply" %in% args
DRIFT_KM <- as.numeric(getarg("--requeue-drift-km", "5"))

FS <- "https://geospatial.sec.usace.army.mil/dls/rest/services/NID/National_Inventory_of_Dams_Public_Service/FeatureServer/0/query"
FIELDS <- paste(c("NIDID", "NAME", "STATE", "LATITUDE", "LONGITUDE",
                  "RIVER_OR_STREAM", "DRAINAGE_AREA", "NID_STORAGE",
                  "OPERATIONAL_STATUS", "DATA_UPDATED"), collapse = ",")

# ---- 1. Paginated pull of the full live NID ---------------------------------
cache_dir <- "data/raw/nid_live"
dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
cache_path <- file.path(cache_dir, "nid_current.csv")

pull_live_nid <- function(page_size = 2000) {
  cnt_url <- paste0(FS, "?where=1%3D1&returnCountOnly=true&f=json")
  total <- jsonlite::fromJSON(cnt_url)$count
  message(sprintf("Live NID: %d total records. Pulling in pages of %d ...", total, page_size))
  pages <- list()
  offset <- 0L
  repeat {
    url <- sprintf("%s?where=1%%3D1&outFields=%s&resultOffset=%d&resultRecordCount=%d&returnGeometry=false&f=json",
                   FS, FIELDS, offset, page_size)
    j <- jsonlite::fromJSON(url, flatten = TRUE)
    feats <- j$features
    if (is.null(feats) || !NROW(feats)) break
    pages[[length(pages) + 1]] <- feats
    offset <- offset + nrow(feats)
    message(sprintf("  ... %d / %d", offset, total))
    Sys.sleep(0.15)   # light rate-limit courtesy on a public government service
    if (nrow(feats) < page_size) break
  }
  out <- do.call(rbind, pages)
  names(out) <- sub("^attributes\\.", "", names(out))
  out
}

if (file.exists(cache_path)) {
  message("Using cached live NID pull: ", cache_path, " (delete to force a fresh pull)")
  live <- utils::read.csv(cache_path, stringsAsFactors = FALSE)
} else {
  live <- pull_live_nid()
  utils::write.csv(live, cache_path, row.names = FALSE)
}
live$NIDID <- trimws(live$NIDID)
live <- live[!duplicated(live$NIDID), ]
message(sprintf("Live NID pull: %d unique facilities.", nrow(live)))

# ---- 2. Refresh a manifest against the live pull -----------------------------
refresh_manifest <- function(path) {
  m <- utils::read.csv(path, stringsAsFactors = FALSE)
  m$facility_id <- trimws(m$facility_id)
  hit <- match(m$facility_id, live$NIDID)
  found <- !is.na(hit)

  m$coord_drift_km <- NA_real_
  m$coord_drift_km[found] <- haversine_km(m$latitude[found], m$longitude[found],
                                          live$LATITUDE[hit[found]], live$LONGITUDE[hit[found]])
  m$operational_status <- NA_character_
  m$operational_status[found] <- live$OPERATIONAL_STATUS[hit[found]]
  m$nid_data_updated <- NA_character_
  m$nid_data_updated[found] <- live$DATA_UPDATED[hit[found]]

  old_da <- if ("drainage_area_mi2" %in% names(m)) m$drainage_area_mi2 else NA_real_
  old_storage <- m$nid_storage_acreft

  if (APPLY) {
    m$latitude[found] <- live$LATITUDE[hit[found]]
    m$longitude[found] <- live$LONGITUDE[hit[found]]
    m$river[found] <- ifelse(nzchar(live$RIVER_OR_STREAM[hit[found]]),
                             live$RIVER_OR_STREAM[hit[found]], m$river[found])
    m$nid_storage_acreft[found] <- ifelse(!is.na(live$NID_STORAGE[hit[found]]),
                                          live$NID_STORAGE[hit[found]], m$nid_storage_acreft[found])
    if ("drainage_area_mi2" %in% names(m))
      m$drainage_area_mi2[found] <- ifelse(!is.na(live$DRAINAGE_AREA[hit[found]]),
                                           live$DRAINAGE_AREA[hit[found]], m$drainage_area_mi2[found])
  }

  not_found <- m$facility_id[!found]
  cat(sprintf("\n=== %s ===\n", basename(path)))
  cat(sprintf("  %d / %d facilities matched in the live NID.\n", sum(found), nrow(m)))
  cat(sprintf("  %d not found live (kept unchanged, flagged) -- e.g.: %s\n",
              length(not_found), paste(utils::head(not_found, 5), collapse = ", ")))
  drift <- m$coord_drift_km[found]
  cat(sprintf("  Coordinate drift: median %.3f km, max %.1f km, %d facilities > %g km.\n",
              stats::median(drift, na.rm = TRUE), max(drift, na.rm = TRUE),
              sum(drift > DRIFT_KM, na.rm = TRUE), DRIFT_KM))
  da_delta <- abs(old_da[found] - live$DRAINAGE_AREA[hit[found]])
  cat(sprintf("  Drainage area changed (>10%% or newly available): %d facilities.\n",
              sum(is.na(old_da[found]) & !is.na(live$DRAINAGE_AREA[hit[found]]) |
                  (da_delta / pmax(old_da[found], 1)) > 0.10, na.rm = TRUE)))
  cat("  operational_status distribution among matched:\n")
  print(table(m$operational_status[found], useNA = "ifany"))

  if (APPLY) {
    utils::write.csv(m, path, row.names = FALSE)
    cat(sprintf("  WROTE %s\n", path))
  }
  m
}

bor <- refresh_manifest("config/facilities_BOR.csv")
nid <- refresh_manifest("config/nid_manifest.csv")

live_ids <- unique(live$NIDID)
our_ids <- unique(nid$facility_id)
new_in_live <- setdiff(live_ids, our_ids)
cat(sprintf("\n=== Scope note (not acted on) ===\n"))
cat(sprintf("%d facility_ids exist in the live NID but are NOT in our manifest\n", length(new_in_live)))
cat("(current manifest is a filtered ~2013 snapshot; adding these would expand fleet\n")
cat("scope beyond the current 73,303 and is a separate decision -- not done here).\n")

# ---- 3. Requeue already-completed facilities with material drift ------------
if (APPLY && file.exists("data/nid_progress/completed_ids.csv")) {
  ledger <- utils::read.csv("data/nid_progress/completed_ids.csv", stringsAsFactors = FALSE)
  ledger$facility_id <- trimws(ledger$facility_id)
  drifted <- nid$facility_id[!is.na(nid$coord_drift_km) & nid$coord_drift_km > DRIFT_KM]
  to_requeue <- intersect(ledger$facility_id, drifted)
  cat(sprintf("\n=== Requeue ===\n%d already-attempted facilities drifted > %g km -- requeuing.\n",
              length(to_requeue), DRIFT_KM))
  if (length(to_requeue)) {
    n0 <- nrow(ledger)
    ledger2 <- ledger[!(ledger$facility_id %in% to_requeue), ]
    utils::write.csv(ledger2, "data/nid_progress/completed_ids.csv", row.names = FALSE)
    cat(sprintf("completed_ids.csv: %d -> %d rows (removed %d)\n", n0, nrow(ledger2), n0 - nrow(ledger2)))
  }
} else if (!APPLY) {
  cat("\n(Dry run -- pass --apply to write the refreshed manifests and requeue drifted facilities.)\n")
}
