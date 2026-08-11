# =============================================================================
# region_methods.R  —  Pluggable homogeneous-region candidate-pool construction
#
# Reclamation reviewer feedback: the pipeline only builds a candidate region by
# circular geographic radius (H&W 1997's "geographical convenience" approach).
# This file adds "cluster analysis" (H&W sec. 9.2.3) as a second, configurable
# method, selected via cfg$region$method ("circular" | "cluster", default
# "circular" so every existing config is unaffected).
#
# Two dispatch points, each preserving the EXACT return shape of the circular
# function it replaces, so nothing downstream (03_screening.R, 04_homogeneity.R,
# 08_mapping.R, run_batch.R's collection) needs to know which method ran:
#   select_region_candidates(inv, cfg)  — pre-download pool, replaces the call
#                                          to ghcn_candidates() in
#                                          acquire_station_data() (functions.R).
#   filter_region_candidates(meta, cfg) — post-acquisition audited re-filter,
#                                          replaces the call to
#                                          filter_candidates() in
#                                          01_data_acquisition.R.
#
# Cluster analysis follows H&W (1997) sec. 9.2.3 directly via lmomRFA's own
# cluagg()/cluinf()/clukm() (Hosking's package, already a dependency, ships a
# worked example that is this exact method) — Ward's-method hierarchical
# clustering on standardized site attributes, optionally refined by k-means.
#
# Graceful degrade: any failure to build a usable cluster region (too few
# stations in the geographic prefilter pool, a resulting cluster below the
# 5-site floor, a package/compute error) falls back to the circular method
# with the reason logged via audit_log() — the 73k-dam fleet batch must never
# start failing dams it used to handle fine just because a facility's local
# station geometry doesn't support clustering.
# =============================================================================

# ---------------------------------------------------------------------------
# select_region_candidates() / filter_region_candidates(): dispatchers.
# ---------------------------------------------------------------------------
select_region_candidates <- function(inv, cfg) {
  method <- cfg$region$method %||% "circular"
  if (identical(method, "cluster")) return(cluster_candidates(inv, cfg))
  if (!identical(method, "circular"))
    stop("Unknown region.method: '", method, "' (supported: circular, cluster)")
  ghcn_candidates(inv, cfg)
}

filter_region_candidates <- function(meta, cfg) {
  method <- cfg$region$method %||% "circular"
  if (identical(method, "cluster")) return(filter_candidates_cluster(meta, cfg))
  if (!identical(method, "circular"))
    stop("Unknown region.method: '", method, "' (supported: circular, cluster)")
  filter_candidates(meta, cfg)
}

# ---------------------------------------------------------------------------
# filter_candidates_cluster(): post-acquisition audited filter for the cluster
# method. The candidate pool was already chosen by cluster membership (not
# geographic radius) at select_region_candidates() time, so — unlike
# filter_candidates() — this does NOT reapply cfg$region$search_radius_km
# (that would silently defeat the point of clustering). It re-checks the
# elevation band as a safety/audit backstop, matching filter_candidates()'s
# existing redundant pre+post pattern.
# ---------------------------------------------------------------------------
filter_candidates_cluster <- function(meta, cfg) {
  meta$distance_km <- haversine_km(cfg$site$latitude, cfg$site$longitude,
                                   meta$lat, meta$lon)
  band <- cfg$region$elevation_band_m
  off_elev <- meta$elev_m < band[1] | meta$elev_m > band[2]
  off_elev[is.na(off_elev)] <- TRUE   # unknown elevation -> can't confirm in-band, drop it
  removed <- data.frame(
    station_id  = meta$station_id[off_elev],
    name        = meta$name[off_elev],
    lat         = meta$lat[off_elev],
    lon         = meta$lon[off_elev],
    elev_m      = meta$elev_m[off_elev],
    distance_km = round(meta$distance_km[off_elev], 1),
    reason      = rep("outside elevation band", sum(off_elev)),
    stringsAsFactors = FALSE)
  list(kept = meta[!off_elev, ], removed = removed, meta_all = meta)
}

# ---------------------------------------------------------------------------
# cluster_cache_dir() / .cluster_pool_key(): per-reference-pool cache so
# clustering runs ONCE for a broad geographic area, not once per facility —
# reclustering thousands of stations for each of 73k dams is wasted compute.
# The reference pool is a coarse lat/lon grid cell sized to the prefilter
# radius (no US-state boundary lookup / new geospatial dependency needed);
# nearby facilities sharing a grid cell reuse the cached clustering.
# ---------------------------------------------------------------------------
cluster_cache_dir <- function() {
  d <- file.path(getOption("lmc.root", "."), "data", "cluster_cache")
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  d
}

.cluster_pool_key <- function(cfg) {
  cc <- cfg$region$cluster %||% list()
  radius <- cc$prefilter_radius_km %||% 600
  cell_deg <- max(1, radius / 111)          # ~111 km per degree latitude
  gx <- floor(cfg$site$longitude / cell_deg)
  gy <- floor(cfg$site$latitude  / cell_deg)
  attrs <- paste(sort(cc$attributes %||% c("lat", "lon", "elev_m")), collapse = "-")
  algo  <- cc$algorithm %||% "ward"
  sprintf("grid_%d_%d_r%g_%s_%s", gx, gy, radius, attrs, algo)
}

# ---------------------------------------------------------------------------
# .cluster_attribute_matrix(): standardized (divide by sample sd), optionally
# weighted attribute matrix for clustering — mirrors H&W (1997) sec. 9.2.3 /
# the lmomRFA::cluagg() worked example (standardize each attribute, then
# apply an expert weight; H&W upweight log-area 3x for Appalachia).
# ---------------------------------------------------------------------------
.cluster_attribute_matrix <- function(df, attrs, weights) {
  m <- as.matrix(df[, attrs, drop = FALSE])
  storage.mode(m) <- "double"
  sds <- apply(m, 2, stats::sd, na.rm = TRUE)
  sds[!is.finite(sds) | sds == 0] <- 1
  means <- apply(m, 2, mean, na.rm = TRUE)
  std <- sweep(sweep(m, 2, means, "-"), 2, sds, "/")
  w <- vapply(attrs, function(a) (weights[[a]] %||% 1), numeric(1))
  std <- sweep(std, 2, w, "*")
  list(matrix = std, means = means, sds = sds, weights = w)
}

# choose_n_clusters(): explicit cfg override, else a target-mean-cluster-size
# heuristic (aim for the pool's mean cluster size to land near the middle of
# region.cluster.target_size). No statistical rule is authoritative here —
# flagged as an expert-review item in the plan; this heuristic is a
# reproducible starting point, not a validated final answer.
choose_n_clusters <- function(N, cfg) {
  cc <- cfg$region$cluster %||% list()
  explicit <- cc$n_clusters
  if (!is.null(explicit)) return(max(2L, min(N - 1L, as.integer(explicit))))
  target <- cc$target_size %||% c(15, 60)
  mid <- mean(as.numeric(target))
  max(2L, min(N - 1L, round(N / mid)))
}

# ---------------------------------------------------------------------------
# build_station_clusters(inv, cfg, refresh=FALSE): cluster the geographic
# prefilter pool around the site (H&W sec. 9.2.3 via lmomRFA::cluagg/cluinf,
# optionally refined by clukm), cached per reference-pool grid cell.
#   -> list(pool = data.frame(...,cluster), centroids = matrix[ncluster x nattr],
#           attrs, means, sds, weights)  or NULL if the pool is too small
#           (caller falls back to circular).
# ---------------------------------------------------------------------------
build_station_clusters <- function(inv, cfg, refresh = FALSE) {
  cc <- cfg$region$cluster %||% list()
  key <- .cluster_pool_key(cfg)
  cache_path <- file.path(cluster_cache_dir(), paste0("clusters_", key, ".rds"))
  if (!refresh && file.exists(cache_path)) return(readRDS(cache_path))

  radius <- cc$prefilter_radius_km %||% 600
  min_pool <- cc$min_pool_stations %||% 15L
  inv$distance_km <- haversine_km(cfg$site$latitude, cfg$site$longitude, inv$lat, inv$lon)
  pool <- inv[inv$distance_km <= radius &
              inv$n_years_avail >= cfg$region$min_record_years, ]
  pool <- pool[!is.na(pool$elev_m), ]

  if (nrow(pool) < min_pool) {
    audit_log(sprintf(
      "Cluster region: only %d stations in the %g km prefilter pool (< %d minimum); caching NULL (fallback).",
      nrow(pool), radius, min_pool))
    saveRDS(NULL, cache_path)
    return(NULL)
  }

  attrs <- cc$attributes %||% c("lat", "lon", "elev_m")
  attrs <- intersect(attrs, names(pool))     # silently drop an unavailable covariate (e.g. "map" pre-Phase-2)
  weights <- cc$weights %||% list()
  am <- .cluster_attribute_matrix(pool, attrs, weights)

  nclust <- choose_n_clusters(nrow(pool), cfg)
  algo <- cc$algorithm %||% "ward"
  cl <- tryCatch(lmomRFA::cluagg(am$matrix, method = "ward.D"), error = function(e) NULL)
  if (is.null(cl)) {
    audit_log("Cluster region: cluagg() failed; caching NULL (fallback).")
    saveRDS(NULL, cache_path)
    return(NULL)
  }
  inf <- lmomRFA::cluinf(cl$merge, nclust = nclust)
  assign <- inf$assign

  centroids <- do.call(rbind, lapply(sort(unique(assign)), function(k)
    colMeans(am$matrix[assign == k, , drop = FALSE])))
  rownames(centroids) <- sort(unique(assign))

  if (identical(algo, "ward_kmeans")) {
    km <- tryCatch(lmomRFA::clukm(am$matrix, assign), error = function(e) NULL)
    if (!is.null(km)) { assign <- km$cluster; centroids <- km$centers }
  }

  pool$cluster <- assign
  out <- list(pool = pool, centroids = centroids, attrs = attrs,
             means = am$means, sds = am$sds, weights = am$weights,
             n_clusters = length(unique(assign)))
  saveRDS(out, cache_path)
  audit_log(sprintf("Cluster region: built %d clusters from %d stations (pool key %s), sizes %s.",
                    out$n_clusters, nrow(pool), key,
                    paste(table(assign), collapse = ",")))
  out
}

# ---------------------------------------------------------------------------
# cluster_candidates(inv, cfg): select_region_candidates() implementation for
# region.method == "cluster". Assigns the (ungauged) target site to a cluster
# by nearest standardized-attribute centroid ("nearest_cluster", default) or
# ranks the whole prefilter pool by attribute-space distance and takes the
# nearest N ("roi" — region-of-influence, avoids hard cluster-boundary
# artifacts). Falls back to the circular method, with the reason logged, when
# clustering isn't usable for this site.
# ---------------------------------------------------------------------------
cluster_candidates <- function(inv, cfg) {
  cc <- cfg$region$cluster %||% list()
  built <- tryCatch(build_station_clusters(inv, cfg), error = function(e) {
    audit_log(sprintf("Cluster region: build_station_clusters() errored (%s); falling back to circular.",
                      conditionMessage(e)))
    NULL
  })
  if (is.null(built)) {
    audit_log("Cluster region: falling back to circular method for this site.")
    return(ghcn_candidates(inv, cfg))
  }

  site_raw <- c(lat = cfg$site$latitude, lon = cfg$site$longitude,
               elev_m = suppressWarnings(as.numeric(cfg$site$elevation_m)))
  site_att <- built$attrs
  if (any(!is.finite(site_raw[site_att]))) {
    audit_log("Cluster region: site attributes (e.g. elevation) unavailable; falling back to circular.")
    return(ghcn_candidates(inv, cfg))
  }
  site_std <- ((site_raw[site_att] - built$means[site_att]) / built$sds[site_att]) *
              built$weights[site_att]

  assignment <- cc$assignment %||% "nearest_cluster"
  pool <- built$pool

  if (identical(assignment, "roi")) {
    am <- .cluster_attribute_matrix(pool, built$attrs, cc$weights %||% list())
    d <- sqrt(rowSums(sweep(am$matrix, 2, site_std, "-")^2))
    ord <- order(d)
    n <- min(length(ord), cfg$region$max_stations %||% 60L)
    members <- pool[ord[seq_len(n)], ]
  } else {
    dctr <- sqrt(rowSums(sweep(built$centroids, 2, site_std, "-")^2))
    best <- as.integer(names(dctr)[which.min(dctr)]) %||% which.min(dctr)
    top2 <- sort(dctr)[1:min(2, length(dctr))]
    if (length(top2) == 2)
      audit_log(sprintf("Cluster region: nearest centroid dist=%.3f, runner-up dist=%.3f (%s).",
                        top2[1], top2[2],
                        if (top2[2] - top2[1] < 0.15 * top2[1]) "borderline — close call" else "clear choice"))
    members <- pool[pool$cluster == best, ]
    min_sites <- 5L
    if (nrow(members) < min_sites) {
      audit_log(sprintf("Cluster region: assigned cluster has only %d stations (< %d floor); falling back to circular.",
                        nrow(members), min_sites))
      return(ghcn_candidates(inv, cfg))
    }
  }

  band <- cfg$region$elevation_band_m
  members <- members[!is.na(members$elev_m) &
                     members$elev_m >= band[1] & members$elev_m <= band[2], ]
  if (nrow(members) < 5L) {
    audit_log("Cluster region: fewer than 5 members remain after the elevation-band check; falling back to circular.")
    return(ghcn_candidates(inv, cfg))
  }

  members$distance_km <- haversine_km(cfg$site$latitude, cfg$site$longitude,
                                      members$lat, members$lon)
  members <- members[order(members$distance_km), ]
  max_st <- cfg$region$max_stations %||% 60L
  if (nrow(members) > max_st) members <- members[seq_len(max_st), ]
  members[, c("station_id", "name", "lat", "lon", "elev_m")]
}
