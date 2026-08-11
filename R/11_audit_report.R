# =============================================================================
# 11_audit_report.R  —  Rendered human-review / audit report (audit layer 9.4)
#
# Objective : assemble a single self-contained HTML report that walks a reviewer
#             through every H&W step with the diagnostics, decision log, tables,
#             figures, and provenance inline — the primary artifact for human
#             review and sign-off (see docs/audit_guide.md).
# Inputs    : results, manifest, table_paths, out_dir
# Outputs   : outputs/report_<id>.html
#
# Implementation note: the report is built with base R string templating (no
# Quarto/pandoc dependency) so it renders anywhere the pipeline runs. Figures
# are embedded as base64 so the HTML file is portable on its own.
# =============================================================================

.img64 <- function(path) {
  if (!file.exists(path)) return("")
  raw <- readBin(path, "raw", file.info(path)$size)
  sprintf('<img src="data:image/png;base64,%s" style="max-width:100%%;height:auto;border:1px solid #ddd;margin:8px 0">',
          jsonlite::base64_enc(raw))
}

.tbl_html <- function(df, digits = 3, max_rows = 60) {
  if (is.null(df) || !nrow(df)) return("<p><em>(none)</em></p>")
  df <- utils::head(df, max_rows)
  num <- vapply(df, is.numeric, logical(1))
  df[num] <- lapply(df[num], function(x) formatC(x, format = "g", digits = digits))
  hdr <- paste0("<th>", names(df), "</th>", collapse = "")
  rows <- apply(df, 1, function(r) paste0("<td>", r, "</td>", collapse = ""))
  paste0("<table><thead><tr>", hdr, "</tr></thead><tbody>",
         paste0("<tr>", rows, "</tr>", collapse = ""), "</tbody></table>")
}

step11_report <- function(results, manifest, out_dir) {
  cfg <- results$cfg; id <- cfg$site$id
  css <- "body{font-family:system-ui,Arial,sans-serif;max-width:1000px;margin:2rem auto;padding:0 1rem;color:#222;line-height:1.5}
h1{border-bottom:3px solid #1b7837}h2{border-bottom:1px solid #ccc;margin-top:2rem}
table{border-collapse:collapse;margin:8px 0;font-size:13px}th,td{border:1px solid #ccc;padding:3px 8px;text-align:right}
th{background:#f0f0f0}code,pre{background:#f6f8fa;padding:2px 4px;border-radius:3px}
.note{background:#fff8e1;border-left:4px solid #ffb300;padding:8px 12px;margin:10px 0}
.ok{color:#1b7837}.status{font-weight:bold}"

  parts <- c(sprintf("<h1>Regional Precipitation Frequency Analysis — %s</h1>", cfg$site$name),
    sprintf("<p>Method: Hosking &amp; Wallis (1997) L-moment regional frequency analysis. Run ID <code>%s</code>. Generated <code>%s</code>.</p>",
            manifest$run_id, manifest$generated_at),
    "<div class='note'>This report is the human-review artifact. Each section maps to a step in <code>docs/PLAN.md</code>. See <code>docs/audit_guide.md</code> for the reviewer sign-off checklist.</div>")

  # Provenance
  parts <- c(parts, "<h2>1. Provenance</h2>",
    .tbl_html(data.frame(
      item = c("Site", "Config file", "Git commit", "R version",
               "lmom / lmomRFA", "Seed", "Stations used"),
      value = c(cfg$site$name, manifest$config_file,
                manifest$git_commit %||% "NA", manifest$r_version,
                paste(manifest$package_versions$lmom, "/", manifest$package_versions$lmomRFA),
                as.character(cfg$seed), as.character(manifest$n_stations_used))),
      max_rows = 20))

  # Per-duration sections
  for (lab in names(results$per_duration)) {
    pd <- results$per_duration[[lab]]
    parts <- c(parts, sprintf("<h2>2. Duration: %s</h2>", lab),
      "<h3>2a. Homogeneous region (discordancy &amp; heterogeneity)</h3>",
      sprintf("<p class='status'>Region status: <span class='ok'>%s</span> — final H1 = %.3f, %d stations.</p>",
              pd$homog_status, pd$H[1], nrow(pd$regdata_final)),
      sprintf("<p>At-site mean annual maximum (<b>ASM</b> / index flood), transferred to this ungauged site: <b>%.2f mm</b> (transfer method: <code>%s</code>).</p>",
              pd$est$index_flood, cfg$index_flood$method %||% "regression"),
      if (is.finite(pd$arf_factor))
        sprintf("<p><b>Areal Reduction Factor (ARF)</b>: %.4f (drainage area %.1f km&sup2; / %.1f mi&sup2;, method: <code>%s</code>). 100-yr point depth %.1f mm &rarr; areal-reduced %.1f mm.</p>",
                pd$arf_factor, pd$arf_area_km2, cfg$site$drainage_area_mi2,
                cfg$arf$method %||% "leclerc_schaake",
                pd$unc$depth_mm[pd$unc$T == 100][1], pd$depth_areal_mm[pd$unc$T == 100][1])
      else
        "<p><b>Areal Reduction Factor (ARF)</b>: not applied — no drainage area configured for this site (see DATA_SOURCES.md / enrich_drainage_area.R). All reported depths are point depths.</p>",
      "<p>Heterogeneity iteration history (each row = one greedy refinement step):</p>",
      .tbl_html(pd$homog_history),
      "<h3>2b. Stations used</h3>", .tbl_html(pd$used_table),
      "<h3>2c. Stations removed (with reason)</h3>", .tbl_html(pd$removed_table),
      "<h3>2d. Distribution selection (Z-statistic)</h3>",
      sprintf("<p>Chosen: <b>%s</b> (|Z| = %.3f, %s).</p>", toupper(pd$dist_sel$chosen),
              abs(pd$dist_sel$Z[pd$dist_sel$chosen]),
              ifelse(pd$dist_sel$acceptable, "acceptable |Z|&le;1.64", "NOTE |Z|>1.64")),
      .tbl_html(pd$dist_sel$table),
      .img64(pd$figs[grep("lmoment_ratio", pd$figs)][1]),
      "<h3>2e. Station data relative to distributions</h3>",
      .img64(pd$figs[grep("growth_curve", pd$figs)][1]),
      "<h3>2f. Depth-frequency to 10,000 yr with uncertainty</h3>",
      .img64(pd$figs[grep("ddf_with_bounds", pd$figs)][1]),
      .tbl_html(data.frame(T_yr = pd$unc$T, AEP = round(1 - pd$unc$F, 6),
                           depth_mm = round(pd$unc$depth_mm, 1),
                           lo = round(pd$unc$depth_lo, 1),
                           hi = round(pd$unc$depth_hi, 1),
                           rel_rmse = round(pd$unc$rel_rmse, 3))))
  }

  # Map + headline table
  parts <- c(parts, "<h2>3. Region map</h2>", .img64(results$map_path),
    "<h2>4. Headline results (all durations)</h2>", .tbl_html(results$ddf, max_rows = 40),
    "<h2>5. Caveats</h2>",
    "<div class='note'><ul>",
    "<li>10,000-yr depths extrapolate far beyond the observed record; the reported Monte-Carlo band and the growth-curve comparison plot show the model sensitivity.</li>",
    "<li>Daily gauge totals are fixed calendar-day; fixed-interval factors only approximate true clock-hour depths.</li>",
    "<li>The site index flood is transferred from regional gauges (the dam is ungauged), adding uncertainty.</li>",
    "<li><code>depth_mm</code> is always the POINT depth. <code>depth_areal_mm</code> (where present) applies an Areal Reduction Factor (R/arf.R) on top of it — a general national-average curve (Leclerc &amp; Schaake 1972), not a region-specific one; treat it as a documented default pending expert review, not a final answer.</li>",
    "</ul></div>")

  html <- paste0("<!doctype html><html><head><meta charset='utf-8'><title>RFA report — ",
                 cfg$site$name, "</title><style>", css, "</style></head><body>",
                 paste(parts, collapse = "\n"), "</body></html>")
  out <- file.path(out_dir, sprintf("report_%s.html", id))
  writeLines(html, out)
  audit_log(sprintf("Audit report written: %s", out))
  out
}
