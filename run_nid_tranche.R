#!/usr/bin/env Rscript
# =============================================================================
# run_nid_tranche.R  —  Resumable, incremental driver for the FULL National
#                       Inventory of Dams (NID) fleet (~73k dams).
#
# The NID fleet is far too large to run in one ephemeral session (~weeks of
# compute). This driver processes ONE tranche per invocation and records
# progress in a COMMITTED ledger, so nightly runs resume automatically where
# the last one stopped, and no facility is ever computed twice.
#
# Usage : Rscript run_nid_tranche.R
# Env   : LMC_TRANCHE  how many not-yet-done facilities to run this pass (default 400)
#         LMC_CORES    worker cores for run_batch (default: detectCores()-1)
#         LMC_MANIFEST manifest CSV (default config/nid_manifest.csv)
#
# Ordering: the manifest is pre-sorted by NID storage (largest/highest-
# consequence dams first), so tranches work down from the biggest dams.
#
# Persistent state (committed, under data/nid_progress/):
#   completed_ids.csv       one row per ATTEMPTED facility (ok or failed) -> skip set
#   all_facilities_DDF.csv  cumulative depth-duration-frequency, all tranches
#   batch_diagnostics.csv   cumulative per site x duration triage
#   tail_sensitivity.csv    cumulative 10,000-yr depth under each candidate
#   progress.md             human-readable running tally
# The GHCN station cache (data/ghcn_prcp_cache/) is extended each pass so the
# downloaded data is reused (and committed) instead of re-fetched.
# =============================================================================
suppressWarnings(for (loc in c("C.UTF-8", "en_US.UTF-8", "C.utf8"))
  if (!is.na(Sys.setlocale("LC_CTYPE", loc)) && Sys.setlocale("LC_CTYPE", loc) != "") break)

root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
source(file.path(root, "run_batch.R"))   # defines run_batch(), gen_configs_from_manifest()

prog_dir <- file.path(root, "data", "nid_progress")
dir.create(prog_dir, showWarnings = FALSE, recursive = TRUE)
ledger_path <- file.path(prog_dir, "completed_ids.csv")

manifest_csv <- Sys.getenv("LMC_MANIFEST", file.path(root, "config", "nid_manifest.csv"))
tranche_n    <- as.integer(Sys.getenv("LMC_TRANCHE", "400"))

man <- utils::read.csv(manifest_csv, stringsAsFactors = FALSE)
man$facility_id <- trimws(as.character(man$facility_id))

done_ids <- character(0)
if (file.exists(ledger_path))
  done_ids <- as.character(utils::read.csv(ledger_path, stringsAsFactors = FALSE)$facility_id)

todo <- man[!(man$facility_id %in% done_ids), , drop = FALSE]
message(sprintf("NID fleet: %d total | %d done | %d remaining.",
                nrow(man), length(done_ids), nrow(todo)))
if (!nrow(todo)) { message("All NID facilities complete. Nothing to do."); quit(save = "no", status = 0) }

tranche <- utils::head(todo, max(1L, tranche_n))
message(sprintf("This tranche: %d facilities (largest remaining by storage first).", nrow(tranche)))

# Write the tranche's manifest and generate its per-facility configs.
tr_csv <- file.path(prog_dir, "_tranche_current.csv")
utils::write.csv(tranche, tr_csv, row.names = FALSE)
cfgs <- gen_configs_from_manifest(tr_csv)

# Run the tranche (run_batch writes its CSVs to outputs/batch/).
status <- run_batch(cfgs)

# ---- fold this tranche's results into the committed cumulative ledgers ------
outb <- file.path(root, "outputs", "batch")
append_cum <- function(src_name, key_cols) {
  src <- file.path(outb, src_name); dst <- file.path(prog_dir, src_name)
  if (!file.exists(src)) return(invisible())
  new <- utils::read.csv(src, stringsAsFactors = FALSE)
  if (file.exists(dst)) {
    old <- utils::read.csv(dst, stringsAsFactors = FALSE)
    both <- rbind(old, new[, names(old), drop = FALSE])
  } else both <- new
  # de-dup on the natural key so a re-run never double-counts
  k <- do.call(paste, c(both[, intersect(key_cols, names(both)), drop = FALSE], sep = "\r"))
  both <- both[!duplicated(k, fromLast = TRUE), , drop = FALSE]
  utils::write.csv(both, dst, row.names = FALSE)
}
append_cum("all_facilities_DDF.csv", c("site", "duration", "return_period_yr"))
append_cum("batch_diagnostics.csv",  c("site_id", "duration"))
append_cum("tail_sensitivity.csv",   c("site", "duration", "dist"))
# Fleet-wide "tables" data (see collect_fleet_tables() in R/functions.R) --
# the small structured per-facility detail (station lists, regional
# L-moments, GOF, growth curve) that used to only exist in the local
# outputs/tables/ dir. Folded into data/nid_progress/ the same resumable,
# de-duplicated way as the three lines above.
append_cum("stations_used.csv",      c("site_id", "duration", "station_id"))
append_cum("stations_removed.csv",   c("site_id", "duration", "station_id"))
append_cum("regional_lmoments.csv",  c("site_id", "duration", "station"))
append_cum("gof.csv",                c("site_id", "duration", "dist"))
append_cum("growth_curve.csv",       c("site_id", "duration", "T"))

# Record EVERY attempted facility (ok or failed) so it is never retried.
attempted <- data.frame(
  facility_id = tranche$facility_id,
  name        = tranche$name,
  ok          = tranche$facility_id %in%
                 sub("\\.yml$", "", basename(status$config[status$ok])),
  stringsAsFactors = FALSE)
# map ok via the site name run_batch reports (config path carries the id)
ok_ids <- sub("\\.ya?ml$", "", basename(as.character(status$config[isTRUE_vec(status$ok)])))
attempted$ok <- attempted$facility_id %in% ok_ids
if (file.exists(ledger_path)) {
  prev <- utils::read.csv(ledger_path, stringsAsFactors = FALSE)
  attempted <- rbind(prev, attempted[, names(prev), drop = FALSE])
  attempted <- attempted[!duplicated(attempted$facility_id, fromLast = TRUE), , drop = FALSE]
}
utils::write.csv(attempted, ledger_path, row.names = FALSE)

# Extend the committed PRCP cache with any stations this tranche downloaded.
n_new <- tryCatch(export_prcp_cache(file.path(root, "data", "raw", "ghcn", "by_station"),
                                    file.path(root, "data", "ghcn_prcp_cache"),
                                    overwrite = FALSE), error = function(e) NA)

n_done <- nrow(attempted); n_ok <- sum(attempted$ok)
pct <- round(100 * n_done / nrow(man), 1)
writeLines(c(
  "# NID fleet progress",
  "",
  sprintf("- Facilities attempted: **%d / %d** (%.1f%%)", n_done, nrow(man), pct),
  sprintf("- Succeeded: %d | failed (too-few-stations etc.): %d", n_ok, n_done - n_ok),
  sprintf("- Cache stations now: %d", length(list.files(file.path(root, "data", "ghcn_prcp_cache"),
                                                        pattern = "\\.csv\\.gz$"))),
  sprintf("- Last tranche: %d facilities", nrow(tranche)),
  "",
  "Resumable: each run does the next tranche (largest remaining dams first) and",
  "records progress here + in data/nid_progress/. See docs for the schedule."),
  file.path(prog_dir, "progress.md"))

message(sprintf("\nNID tranche done. Cumulative: %d/%d attempted (%.1f%%), %d ok. New cache stations: %s.",
                n_done, nrow(man), pct, n_ok, ifelse(is.na(n_new), "n/a", n_new)))
