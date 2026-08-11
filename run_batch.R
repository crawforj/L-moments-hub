#!/usr/bin/env Rscript
# =============================================================================
# run_batch.R  —  Run the analysis for MANY facilities (e.g. the Bureau of
#                 Reclamation fleet), Como being the primary validated test site.
#
# Usage : Rscript run_batch.R [config/facilities/*.yml ...]
#         Rscript run_batch.R --manifest config/facilities.csv
#
# Each facility is described by its own YAML config (copy config/como.yml and
# edit site coordinates / parameters). This runner:
#   1. optionally generates per-facility configs from a manifest CSV
#      (facility_id, name, latitude, longitude, elevation_m[, search_radius_km]),
#   2. runs run_analysis() for each config in isolation,
#   3. collects the headline DDF tables into outputs/batch/all_facilities_DDF.csv,
#   4. writes a batch status log (success / failure per facility) for audit.
#
# Design intent: Como is validated first (run_golden.R + run_analysis.R). Once
# its results are reviewed and signed off, the SAME code runs unchanged across
# the fleet — only the per-facility config differs.
# =============================================================================
suppressWarnings(for (loc in c("C.UTF-8", "en_US.UTF-8", "C.utf8"))
  if (!is.na(Sys.setlocale("LC_CTYPE", loc)) && Sys.setlocale("LC_CTYPE", loc) != "") break)

root <- tryCatch(dirname(sub("--file=", "",
  grep("--file=", commandArgs(FALSE), value = TRUE)[1])), error = function(e) ".")
if (is.na(root) || root == "") root <- "."
source(file.path(root, "run_analysis.R"))
suppressMessages(library(parallel))                 # base R; mclapply fan-out

# gen_configs_from_manifest(): write one YAML per facility from a manifest CSV,
# inheriting all non-site defaults from a template config (config/como.yml).
gen_configs_from_manifest <- function(manifest_csv,
                                      template = file.path(root, "config", "como.yml"),
                                      out_dir = file.path(root, "config", "facilities")) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  message("\n=========================== DATA REVIEW REQUIRED ===========================\n",
          " Weather source (GHCN-Daily) AND the dam inventory (facility coordinates,\n",
          " ownership, elevations) are UNVERIFIED and must be reviewed before any\n",
          " engineering use. The bundled BOR manifest derives from a third-party NID\n",
          " mirror (vintage ~2013) and carries NO ground elevations. See DATA_SOURCES.md.\n",
          "============================================================================\n")
  m <- utils::read.csv(manifest_csv, stringsAsFactors = FALSE)
  tmpl <- yaml::read_yaml(template)
  paths <- character(0)
  for (i in seq_len(nrow(m))) {
    cfg <- tmpl
    cfg$site$name <- m$name[i]
    cfg$site$id   <- m$facility_id[i]
    cfg$site$latitude  <- m$latitude[i]
    cfg$site$longitude <- m$longitude[i]
    cfg$site$elevation_m <- m$elevation_m[i]
    if (!is.null(m$search_radius_km) && !is.na(m$search_radius_km[i]))
      cfg$region$search_radius_km <- m$search_radius_km[i]
    p <- file.path(out_dir, paste0(m$facility_id[i], ".yml"))
    yaml::write_yaml(cfg, p)
    paths <- c(paths, p)
  }
  message(sprintf("Generated %d facility configs in %s.", length(paths), out_dir))
  paths
}

# prewarm_ghcn_cache(): download the global GHCN inventory ONCE (cached) before
# fanning out, so parallel workers reuse it instead of each downloading it.
prewarm_ghcn_cache <- function(config_paths) {
  for (cp in config_paths) {
    cfg <- tryCatch(load_config(cp), error = function(e) NULL)
    if (!is.null(cfg) && identical(cfg$data$source, "ghcn")) {
      message("Pre-warming shared GHCN inventory cache from ", basename(cp), " ...")
      inv <- tryCatch(ghcn_load_inventory(cfg), error = function(e) NULL)
      if (is.null(inv))
        message("  (inventory download unavailable; facilities will fall back per config)")
      else message(sprintf("  inventory ready: %d PRCP stations cached.", nrow(inv)))
      return(invisible(TRUE))
    }
  }
  invisible(FALSE)
}

# prefetch_all_stations(): download the UNION of candidate stations across all
# facilities up front (in parallel), so the per-facility workers do zero network
# I/O. No-op when GHCN is unreachable (workers then fall back per config).
prefetch_all_stations <- function(config_paths, cores) {
  cfgs <- Filter(Negate(is.null), lapply(config_paths, function(cp)
    tryCatch(load_config(cp), error = function(e) NULL)))
  ghcn_cfgs <- Filter(function(c) identical(c$data$source, "ghcn"), cfgs)
  if (!length(ghcn_cfgs)) return(invisible(0L))
  inv <- tryCatch(ghcn_load_inventory(ghcn_cfgs[[1]]), error = function(e) NULL)
  if (is.null(inv)) { message("Prefetch skipped (inventory unavailable)."); return(invisible(0L)) }
  ids <- unique(unlist(lapply(ghcn_cfgs, function(c)
    ghcn_candidates(inv, c)$station_id)))
  cache <- file.path(ghcn_cache_dir(ghcn_cfgs[[1]]), "by_station")
  base  <- ghcn_cfgs[[1]]$data$ghcn_base
  message(sprintf("Prefetching %d unique stations across %d facilities on %d core(s) ...",
                  length(ids), length(ghcn_cfgs), cores))
  dl <- function(sid) { !is.null(download_ghcn_daily(sid, base, cache_dir = cache)) }
  got <- if (cores > 1 && .Platform$OS.type != "windows")
    unlist(parallel::mclapply(ids, dl, mc.cores = cores))
  else vapply(ids, dl, logical(1))
  message(sprintf("Prefetch complete: %d/%d stations cached under %s.",
                  sum(got), length(ids), cache))
  invisible(sum(got))
}

# run_batch(): run many facilities, in parallel where possible. Each facility
# writes site-id-keyed outputs (no collisions). Results and a per-facility
# success/failure status are collected for audit.
run_batch <- function(config_paths, cores = NULL, prefetch = TRUE) {
  outb <- file.path(root, "outputs", "batch")
  dir.create(outb, showWarnings = FALSE, recursive = TRUE)
  prewarm_ghcn_cache(config_paths)                 # shared inventory cache

  if (is.null(cores)) {
    env <- Sys.getenv("LMC_CORES", "")
    cores <- if (nzchar(env)) as.integer(env)
             else max(1L, min(parallel::detectCores() - 1L, length(config_paths)))
  }
  cores <- max(1L, cores)
  if (isTRUE(prefetch)) prefetch_all_stations(config_paths, cores)   # workers do zero network I/O
  message(sprintf("Running %d facilities on %d core(s)%s.",
                  length(config_paths), cores,
                  if (.Platform$OS.type == "windows" && cores > 1)
                    " (Windows: serial fallback)" else ""))

  run_one <- function(cp) {
    res <- tryCatch(run_analysis(cp), error = function(e) e)
    if (inherits(res, "error"))
      list(ok = FALSE, config = cp, site = NA, message = conditionMessage(res),
           ddf = NULL, diag = NULL)
    else
      list(ok = TRUE, config = cp, site = res$cfg$site$name, message = "ok",
           ddf = res$ddf, diag = tryCatch(facility_diagnostics(res), error = function(e) NULL))
  }

  results <- if (cores > 1 && .Platform$OS.type != "windows")
    parallel::mclapply(config_paths, run_one, mc.cores = cores, mc.preschedule = FALSE)
  else lapply(config_paths, run_one)

  status <- do.call(rbind, lapply(results, function(r)
    data.frame(config = r$config, site = r$site %||% NA, ok = r$ok,
               message = r$message, stringsAsFactors = FALSE)))
  all_ddf <- Filter(Negate(is.null), lapply(results, function(r) r$ddf))
  for (r in results) if (!r$ok) message("FACILITY FAILED: ", r$config, " -- ", r$message)

  if (length(all_ddf))
    utils::write.csv(do.call(rbind, all_ddf),
                     file.path(outb, "all_facilities_DDF.csv"), row.names = FALSE)
  utils::write.csv(status, file.path(outb, "batch_status.csv"), row.names = FALSE)

  # Per-facility triage diagnostics: heterogeneity (H1) + chosen-distribution
  # fit (|Z|), with a needs_review flag (H1 >= 2 or |Z| > 1.64). This is the
  # fleet triage list (docs/PLAN.md sec. 12): review these before trusting a
  # facility's numbers.
  all_diag <- Filter(Negate(is.null), lapply(results, function(r) r$diag))
  if (length(all_diag)) {
    diag_df <- do.call(rbind, all_diag)
    utils::write.csv(diag_df, file.path(outb, "batch_diagnostics.csv"), row.names = FALSE)
    review <- diag_df[isTRUE_vec(diag_df$needs_review), , drop = FALSE]
    message(sprintf("Diagnostics: %d/%d facility-durations flagged for review (H1>=2 or |Z|>1.64).",
                    nrow(review), nrow(diag_df)))
    if (nrow(review))
      for (i in seq_len(nrow(review)))
        message(sprintf("  REVIEW: %-16s %-4s  H1=%.2f  %s |Z|=%.2f",
                        review$site[i], review$duration[i], review$H1[i],
                        review$chosen_dist[i], review$chosen_absZ[i]))
  }

  message(sprintf("\nBatch complete: %d ok, %d failed. See %s.",
                  sum(status$ok), sum(!status$ok), outb))
  invisible(status)
}

# isTRUE_vec(): vectorised isTRUE (NA/logical-safe) for row filtering.
isTRUE_vec <- function(x) !is.na(x) & x

# ---- CLI -------------------------------------------------------------------
.invoked_as_main <- function(fname) {
  fa <- grep("--file=", commandArgs(FALSE), value = TRUE)
  length(fa) > 0 && basename(sub("--file=", "", fa[1])) == fname
}
if (.invoked_as_main("run_batch.R")) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) >= 2 && args[1] == "--manifest") {
    cfgs <- gen_configs_from_manifest(args[2])
  } else if (length(args) >= 1) {
    cfgs <- args
  } else {
    cfgs <- list.files(file.path(root, "config", "facilities"),
                       pattern = "\\.ya?ml$", full.names = TRUE)
    if (!length(cfgs)) stop("No facility configs. Pass config paths or --manifest <csv>.")
  }
  run_batch(cfgs)
}
