# =============================================================================
# arf.R  —  Areal Reduction Factor (ARF)
#
# Reclamation reviewer question: "Is an areal reduction factor (ARF) computed
# and applied to the curve?" It was not -- docs/ASSUMPTIONS_AND_LIMITATIONS.md
# said so explicitly ("no areal reduction factor... converting to basin-average
# design rainfall requires an ARF the pipeline does not apply"). This file adds
# it as an OPTIONAL, additive step: point depths (depth_mm) are never replaced,
# only a second depth_areal_mm is added alongside them where a drainage area is
# known for the site (see enrich_drainage_area.R, cfg$site$drainage_area_mi2).
#
# Default method: Leclerc & Schaake (1972), a widely-cited general-purpose
# ARF-area-duration curve (reproduced e.g. in Allen & DeGaetano 2005, J.
# Hydrologic Engrg., and multiple ARF re-evaluation studies):
#   ARF = 1 - exp(-1.1 * t^0.25) + exp(-1.1 * t^0.25 - 0.003863 * A)
#     t = storm duration, HOURS
#     A = drainage area,  SQUARE KILOMETRES
# This is a national-average curve (not derived for any specific region), and
# the literature notes it was fit up to roughly the 100-yr return period, so
# using it out to the 10,000-yr tail here is an extrapolation like the rest of
# this pipeline's tail estimates. It is a documented, swappable DEFAULT, not an
# authoritative regional answer -- flagged for expert review in docs/PLAN.md;
# region-specific curves (e.g. NOAA Atlas 14 volume-specific, or a curve
# Reclamation prefers) should replace it via cfg$arf$method once chosen.
# =============================================================================

MI2_TO_KM2 <- 2.58999

# leclerc_schaake_arf(area_km2, duration_hr): dimensionless ARF in (0, 1].
# Vectorised over duration_hr; area_km2 is a single site-level scalar.
leclerc_schaake_arf <- function(area_km2, duration_hr) {
  if (!is.finite(area_km2) || area_km2 <= 0) return(rep(1, length(duration_hr)))
  t <- duration_hr
  arf <- 1 - exp(-1.1 * t^0.25) + exp(-1.1 * t^0.25 - 0.003863 * area_km2)
  pmin(1, pmax(0, arf))
}

# compute_arf(area_km2, duration_hr, cfg): dispatches on cfg$arf$method
# (default "leclerc_schaake" -- the only method implemented so far; see the
# module docstring for how to add a region-specific curve later).
compute_arf <- function(area_km2, duration_hr, cfg) {
  method <- cfg$arf$method %||% "leclerc_schaake"
  if (!identical(method, "leclerc_schaake"))
    stop("Unknown arf.method: '", method, "' (supported: leclerc_schaake)")
  leclerc_schaake_arf(area_km2, duration_hr)
}

# site_drainage_area_km2(cfg): the site's drainage area in km2, or NA if not
# configured -- callers must treat NA as "ARF not applicable to this site"
# (graceful degrade; most facilities in the fleet manifests DO have a value
# from enrich_drainage_area.R, but not all -- see its coverage report).
site_drainage_area_km2 <- function(cfg) {
  mi2 <- suppressWarnings(as.numeric(cfg$site$drainage_area_mi2))
  if (length(mi2) != 1L || !is.finite(mi2) || mi2 <= 0) return(NA_real_)
  mi2 * MI2_TO_KM2
}
