# Tests for R/region_methods.R -- the pluggable region-construction dispatcher
# added for Reclamation reviewer feedback (see docs/PLAN.md region section).
# All cluster tests point lmc.root at a tempdir so the cache never touches the
# real repo's data/cluster_cache/.

.with_temp_root <- function(expr) {
  old <- getOption("lmc.root")
  td <- tempfile("lmc_root_"); dir.create(td)
  options(lmc.root = td)
  on.exit(options(lmc.root = old))
  force(expr)
}

.toy_inv <- function(n = 40, center_lat = 46.06, center_lon = -114.23) {
  set.seed(1)
  data.frame(
    station_id = sprintf("S%03d", seq_len(n)),
    name = paste("station", seq_len(n)),
    lat = center_lat + stats::rnorm(n, 0, 1.2),
    lon = center_lon + stats::rnorm(n, 0, 1.2),
    elev_m = round(1000 + stats::rnorm(n, 0, 300)),
    first_year = 1980L, last_year = 2020L,
    n_years_avail = 41L, stringsAsFactors = FALSE)
}

.toy_cfg <- function(method = "circular", extra_region = list()) {
  list(site = list(latitude = 46.06, longitude = -114.23, elevation_m = 1240),
       region = utils::modifyList(list(
         method = method, search_radius_km = 175,
         elevation_band_m = c(600, 2600), min_record_years = 20,
         max_stations = 60), extra_region))
}

test_that("dispatchers default to circular and match the direct functions", {
  inv <- .toy_inv()
  cfg <- .toy_cfg()                      # no explicit method -> "circular" via %||%
  cfg$region$method <- NULL
  a <- select_region_candidates(inv, cfg)
  b <- ghcn_candidates(inv, cfg)
  expect_equal(a, b)

  meta <- a; meta$distance_km <- 1
  f1 <- filter_region_candidates(meta, cfg)
  f2 <- filter_candidates(meta, cfg)
  expect_equal(f1, f2)
})

test_that("an unknown region.method errors clearly, at both dispatch points", {
  inv <- .toy_inv(); cfg <- .toy_cfg(method = "bogus")
  expect_error(select_region_candidates(inv, cfg), "Unknown region.method")
  expect_error(filter_region_candidates(inv, cfg), "Unknown region.method")
})

test_that("filter_candidates_cluster handles zero removals without erroring (regression)", {
  # All stations comfortably inside the elevation band -> off_elev is all FALSE.
  # This used to crash: a scalar reason = "..." can't recycle against 0-length
  # column vectors inside data.frame().
  meta <- data.frame(station_id = c("A", "B"), name = c("a", "b"),
                     lat = c(46.0, 46.1), lon = c(-114.2, -114.3),
                     elev_m = c(1200, 1300), stringsAsFactors = FALSE)
  cfg <- .toy_cfg(method = "cluster")
  out <- filter_candidates_cluster(meta, cfg)
  expect_equal(nrow(out$kept), 2)
  expect_equal(nrow(out$removed), 0)
  expect_true(all(c("station_id", "name", "lat", "lon", "elev_m", "distance_km", "reason") %in%
                  names(out$removed)))
})

test_that("filter_candidates_cluster drops out-of-band and NA-elevation stations, with a reason", {
  meta <- data.frame(station_id = c("A", "B", "C"), name = c("a", "b", "c"),
                     lat = c(46.0, 46.1, 46.2), lon = c(-114.2, -114.3, -114.4),
                     elev_m = c(1200, 100, NA), stringsAsFactors = FALSE)
  cfg <- .toy_cfg(method = "cluster")
  out <- filter_candidates_cluster(meta, cfg)
  expect_setequal(out$kept$station_id, "A")
  expect_setequal(out$removed$station_id, c("B", "C"))
  expect_true(all(out$removed$reason == "outside elevation band"))
})

test_that("cluster method falls back to circular when the prefilter pool is too small", {
  .with_temp_root({
    inv <- .toy_inv(n = 6)               # well under the default min_pool_stations (15)
    cfg <- .toy_cfg(method = "cluster")
    got <- select_region_candidates(inv, cfg)
    expect_equal(got, ghcn_candidates(inv, cfg))
  })
})

test_that("cluster method returns a valid, capped candidate set with a plausible pool", {
  .with_temp_root({
    inv <- .toy_inv(n = 120)
    cfg <- .toy_cfg(method = "cluster")
    cfg$region$max_stations <- 12
    got <- select_region_candidates(inv, cfg)
    expect_true(is.data.frame(got))
    expect_setequal(names(got), c("station_id", "name", "lat", "lon", "elev_m"))
    expect_lte(nrow(got), 12)
    expect_gte(nrow(got), 5)
    expect_true(all(got$station_id %in% inv$station_id))
  })
})

test_that("build_station_clusters caches per reference-pool key (second call is a cache hit)", {
  .with_temp_root({
    inv <- .toy_inv(n = 120)
    cfg <- .toy_cfg(method = "cluster")
    b1 <- build_station_clusters(inv, cfg)
    expect_true(!is.null(b1))
    cache_files <- list.files(file.path(getOption("lmc.root"), "data", "cluster_cache"))
    expect_length(cache_files, 1)
    b2 <- build_station_clusters(inv, cfg)   # should read the cache, not recompute
    expect_equal(b1$n_clusters, b2$n_clusters)
    cache_files2 <- list.files(file.path(getOption("lmc.root"), "data", "cluster_cache"))
    expect_length(cache_files2, 1)            # still just the one cached pool
  })
})

test_that("gen_configs_from_manifest honours an optional region_method column", {
  real_root <- getOption("lmc.root", ".")
  # run_batch.R computes its OWN root from commandArgs (designed for direct
  # `Rscript run_batch.R` invocation, not source()-ing mid-test where
  # testthat has changed the working directory) -- setwd() for the source()
  # call only, so its relative root resolves correctly.
  old_wd <- getwd(); setwd(real_root); on.exit(setwd(old_wd), add = TRUE)
  source(file.path(real_root, "run_batch.R"), local = FALSE)
  scratch <- tempfile("manifest_test_"); dir.create(scratch)
  man <- data.frame(
    facility_id = c("F1", "F2"), name = c("Dam One", "Dam Two"),
    latitude = c(46.0, 47.0), longitude = c(-114.0, -113.0),
    elevation_m = c(1200, 1300), region_method = c("cluster", ""),
    stringsAsFactors = FALSE)
  mcsv <- file.path(scratch, "manifest.csv"); utils::write.csv(man, mcsv, row.names = FALSE)
  outd <- file.path(scratch, "facilities")
  paths <- gen_configs_from_manifest(mcsv,
    template = file.path(real_root, "config", "como.yml"), out_dir = outd)
  c1 <- yaml::read_yaml(paths[1]); c2 <- yaml::read_yaml(paths[2])
  expect_equal(c1$region$method, "cluster")
  expect_equal(c2$region$method, "circular")   # blank cell -> template default unchanged
})
