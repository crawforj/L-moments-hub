# =============================================================================
# build_band_table.R — build the region-method ensemble band table
# (data/region_method_band/bor308_band.csv) from the two fleet runs compared in
# docs/CLUSTER_FLEET_RESULTS.md:
#
#   circular : outputs/batch/all_facilities_DDF.csv
#              (fresh elevation-consistent circular baseline, 2026-08-14,
#               config/facilities_BOR_circular.csv, 297/308 ok)
#   cluster  : outputs/batch/cluster_full308/all_facilities_DDF_cluster308.csv
#              (config/facilities_BOR_cluster.csv, 2026-08-14, 292/308 ok)
#   fallback : outputs/batch/cluster_full308/fallback_outcome.json
#              (per-facility: did cluster genuinely engage, or fall back to
#               circular — fallback facilities are region-identical to the
#               baseline by construction, so their band is 0)
#
# outputs/ is gitignored (machine-local); this script + the committed CSV are
# the durable record. Re-run: Rscript data/region_method_band/build_band_table.R
# from the repo root (requires both fleet runs on disk).
#
# Band semantics: band_pct = 100 * |circular - cluster| / max(circular, cluster)
# — the regionalization-choice uncertainty component, complementary to (and
# excluded from) the per-run Monte-Carlo bounds. See
# docs/CLUSTER_FLEET_RESULTS.md ("Ensemble band now shipped").
# =============================================================================

root <- "."
if (!file.exists(file.path(root, "run_batch.R")))
  stop("Run from the repo root (run_batch.R not found).")

circ <- utils::read.csv(file.path(root, "outputs", "batch", "all_facilities_DDF.csv"),
                        stringsAsFactors = FALSE)
clus <- utils::read.csv(file.path(root, "outputs", "batch", "cluster_full308",
                                  "all_facilities_DDF_cluster308.csv"),
                        stringsAsFactors = FALSE)
fb <- jsonlite::fromJSON(file.path(root, "outputs", "batch", "cluster_full308",
                                   "fallback_outcome.json"))

man <- utils::read.csv(file.path(root, "config", "facilities_BOR_cluster.csv"),
                       stringsAsFactors = FALSE)

# The DDF outputs key on facility NAME only; 3 names are duplicated in the
# manifest (PATHFINDER DIKE, GLENDO DIKE NO. 1, SCOGGINS — 2 facility_ids
# each), making a name join 1:many-ambiguous. Excluded, matching the
# exclusion already applied in docs/CLUSTER_FLEET_RESULTS.md.
dup_names <- unique(man$name[duplicated(man$name)])
message("Excluding duplicate-name facilities: ", paste(dup_names, collapse = ", "))
man  <- man[!man$name %in% dup_names, ]
circ <- circ[!circ$site %in% dup_names, ]
clus <- clus[!clus$site %in% dup_names, ]

keep <- c("site", "duration", "return_period_yr", "depth_mm")
m <- merge(setNames(circ[, keep], c("site", "duration", "return_period_yr", "depth_circular_mm")),
           setNames(clus[, keep], c("site", "duration", "return_period_yr", "depth_cluster_mm")),
           by = c("site", "duration", "return_period_yr"))   # inner join: both runs succeeded

m$site_id <- man$facility_id[match(m$site, man$name)]
m$band_pct <- round(100 * abs(m$depth_circular_mm - m$depth_cluster_mm) /
                    pmax(m$depth_circular_mm, m$depth_cluster_mm), 2)
status <- unlist(fb)[m$site]
m$band_source <- ifelse(status == "fallback", "identical_fallback", "two_method")
if (anyNA(m$band_source)) stop("Facility missing from fallback_outcome.json: ",
                               paste(unique(m$site[is.na(m$band_source)]), collapse = ", "))

m <- m[order(m$site, m$duration, m$return_period_yr),
       c("site", "site_id", "duration", "return_period_yr",
         "depth_circular_mm", "depth_cluster_mm", "band_pct", "band_source")]

out <- file.path(root, "data", "region_method_band", "bor308_band.csv")
utils::write.csv(m, out, row.names = FALSE)

# ---- summary (sanity checks mirror docs/CLUSTER_FLEET_RESULTS.md) ----------
t10 <- m[m$return_period_yr == 10000, ]
gc10 <- t10[t10$band_source == "two_method", ]
fb10 <- t10[t10$band_source == "identical_fallback", ]
message(sprintf("Wrote %s: %d rows (%d facilities x duration x T).", out, nrow(m),
                length(unique(m$site))))
message(sprintf("T=10,000 two_method (n=%d): median %.1f%%, mean %.1f%%, max %.1f%%, >15%%: %d (%.1f%%)",
                nrow(gc10), median(gc10$band_pct), mean(gc10$band_pct), max(gc10$band_pct),
                sum(gc10$band_pct > 15), 100 * mean(gc10$band_pct > 15)))
message(sprintf("T=10,000 identical_fallback (n=%d): max band %.2f%% (must be ~0 by construction)",
                nrow(fb10), max(fb10$band_pct)))
