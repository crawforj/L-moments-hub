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

# gen_configs_from_manifest(): write one YAML per facility from a manifest CSV,
# inheriting all non-site defaults from a template config (config/como.yml).
gen_configs_from_manifest <- function(manifest_csv,
                                      template = file.path(root, "config", "como.yml"),
                                      out_dir = file.path(root, "config", "facilities")) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
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

run_batch <- function(config_paths) {
  outb <- file.path(root, "outputs", "batch")
  dir.create(outb, showWarnings = FALSE, recursive = TRUE)
  status <- data.frame(config = character(0), site = character(0),
                       ok = logical(0), message = character(0),
                       stringsAsFactors = FALSE)
  all_ddf <- list()
  for (cp in config_paths) {
    res <- tryCatch(run_analysis(cp), error = function(e) e)
    if (inherits(res, "error")) {
      status <- rbind(status, data.frame(config = cp, site = NA,
        ok = FALSE, message = conditionMessage(res)))
      message("FACILITY FAILED: ", cp, " — ", conditionMessage(res))
    } else {
      all_ddf[[cp]] <- res$ddf
      status <- rbind(status, data.frame(config = cp, site = res$cfg$site$name,
        ok = TRUE, message = "ok"))
    }
  }
  if (length(all_ddf))
    utils::write.csv(do.call(rbind, all_ddf),
                     file.path(outb, "all_facilities_DDF.csv"), row.names = FALSE)
  utils::write.csv(status, file.path(outb, "batch_status.csv"), row.names = FALSE)
  message(sprintf("\nBatch complete: %d ok, %d failed. See %s.",
                  sum(status$ok), sum(!status$ok), outb))
  invisible(status)
}

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
