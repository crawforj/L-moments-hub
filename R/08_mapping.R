# =============================================================================
# 08_mapping.R  —  Map of the region (deliverable)
#
# Objective : map the analysis region — stations used vs removed, the target
#             dam, and the search-radius boundary — on a state/county base.
# Inputs    : used_meta, removed_meta (station_id,name,lat,lon,elev_m,...), cfg
# Outputs   : outputs/figures/<id>_region_map.png and .pdf
# Notes     : uses ggplot2 + the 'maps' package (no heavy geospatial stack);
#             falls back to a base-graphics scatter if ggplot2/maps are absent.
# =============================================================================

# radius_circle(): approximate lon/lat polygon at a given radius (km) from a point.
radius_circle <- function(lat0, lon0, radius_km, npts = 180) {
  bearings <- seq(0, 2 * pi, length.out = npts)
  R <- 6371.0088
  d <- radius_km / R
  lat0r <- lat0 * pi / 180; lon0r <- lon0 * pi / 180
  lat <- asin(sin(lat0r) * cos(d) + cos(lat0r) * sin(d) * cos(bearings))
  lon <- lon0r + atan2(sin(bearings) * sin(d) * cos(lat0r),
                       cos(d) - sin(lat0r) * sin(lat))
  data.frame(lon = lon * 180 / pi, lat = lat * 180 / pi)
}

step08_map <- function(used_meta, removed_meta, cfg, out_dir) {
  site <- cfg$site
  method <- cfg$region$method %||% "circular"
  # search_radius_km is retained as a universal outer bound for every method
  # (see config schema in docs/PLAN.md), so the circle is always drawable —
  # but it only means "the candidate boundary" for the circular method itself;
  # for other methods it's shown as context, not the actual selection rule.
  circ <- radius_circle(site$latitude, site$longitude, cfg$region$search_radius_km)

  pts <- rbind(
    data.frame(lon = used_meta$lon, lat = used_meta$lat, status = "used"),
    if (nrow(removed_meta))
      data.frame(lon = removed_meta$lon, lat = removed_meta$lat, status = "removed")
  )

  png_path <- file.path(out_dir, "figures", paste0(cfg$site$id, "_region_map.png"))
  pdf_path <- file.path(out_dir, "figures", paste0(cfg$site$id, "_region_map.pdf"))

  have_gg <- requireNamespace("ggplot2", quietly = TRUE) &&
             requireNamespace("maps", quietly = TRUE)
  if (have_gg) {
    xr <- range(c(pts$lon, circ$lon)); yr <- range(c(pts$lat, circ$lat))
    pad_x <- diff(xr) * 0.08 + 0.3; pad_y <- diff(yr) * 0.08 + 0.3
    states  <- ggplot2::map_data("state")
    county  <- ggplot2::map_data("county")
    g <- ggplot2::ggplot() +
      ggplot2::geom_polygon(data = county,
        ggplot2::aes(long, lat, group = group),
        fill = "grey97", colour = "grey85", linewidth = 0.2) +
      ggplot2::geom_polygon(data = states,
        ggplot2::aes(long, lat, group = group),
        fill = NA, colour = "grey55", linewidth = 0.4) +
      ggplot2::geom_path(data = circ, ggplot2::aes(lon, lat),
        colour = "steelblue", linetype = "dashed", linewidth = 0.6,
        alpha = if (method == "circular") 1 else 0.35) +
      ggplot2::geom_point(data = pts,
        ggplot2::aes(lon, lat, colour = status, shape = status),
        size = 2.2, stroke = 0.8) +
      ggplot2::geom_point(ggplot2::aes(site$longitude, site$latitude),
        colour = "black", fill = "red", shape = 24, size = 3.4) +
      ggplot2::annotate("text", x = site$longitude, y = site$latitude,
        label = paste0("  ", site$name), hjust = 0, size = 3.2, fontface = "bold") +
      ggplot2::scale_colour_manual(values = c(used = "#1b7837", removed = "#b2182b")) +
      ggplot2::scale_shape_manual(values = c(used = 16, removed = 4)) +
      ggplot2::coord_quickmap(xlim = xr + c(-pad_x, pad_x),
                              ylim = yr + c(-pad_y, pad_y)) +
      ggplot2::labs(
        title = paste0("Analysis region — ", site$name, " (region.method: ", method, ")"),
        subtitle = if (method == "circular")
          sprintf("%d stations used, %d removed; dashed = %g km search radius",
                  nrow(used_meta), nrow(removed_meta), cfg$region$search_radius_km)
        else
          sprintf("%d stations used, %d removed; faint dashed = %g km outer bound (not the selection rule for '%s')",
                  nrow(used_meta), nrow(removed_meta), cfg$region$search_radius_km, method),
        x = "Longitude", y = "Latitude", colour = "Station", shape = "Station") +
      ggplot2::theme_minimal(base_size = 11)
    ggplot2::ggsave(png_path, g, width = 8, height = 7, dpi = 150)
    ggplot2::ggsave(pdf_path, g, width = 8, height = 7)
  } else {
    grDevices::png(png_path, width = 1200, height = 1050, res = 150)
    plot(pts$lon, pts$lat, type = "n", xlab = "Longitude", ylab = "Latitude",
         main = paste0("Analysis region — ", site$name, " (", method, ")"), asp = 1)
    lines(circ$lon, circ$lat, col = if (method == "circular") "steelblue" else "grey75", lty = 2)
    used_i <- pts$status == "used"
    points(pts$lon[used_i], pts$lat[used_i], pch = 16, col = "#1b7837")
    points(pts$lon[!used_i], pts$lat[!used_i], pch = 4, col = "#b2182b")
    points(site$longitude, site$latitude, pch = 17, col = "red", cex = 1.6)
    legend("topright", c("used", "removed", site$name),
           pch = c(16, 4, 17), col = c("#1b7837", "#b2182b", "red"), bty = "n")
    grDevices::dev.off()
  }
  audit_log(sprintf("Region map written: %s", png_path))
  png_path
}
