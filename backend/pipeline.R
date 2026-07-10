# =============================================================================
# pipeline.R -- orchestrates the full AERMOD-ready met build for ANY US site.
#
# It reuses the tested MDEQ AERMET/AERMINUTE engine (R/engine.R, a bundled copy
# of AERMET.R) unchanged, and overrides just three seams so the engine works for
# an arbitrary station with on-demand AERSURFACE:
#   * find_exe             -> resolve bundled binaries from <app_root>/bin
#   * fetch_aersurface_file-> run AERSURFACE on-demand (NLCD WCS) instead of
#                             copying a pre-made file
#   * get_icao_from_igra   -> tolerant upper-air ICAO labelling for any site
# =============================================================================

# APP_ROOT (repo root) must be defined before this file is sourced -- see
# R/bootstrap.R, which sources stations.R, aersurface_runner.R and engine.R
# (with AERMET_SOURCE_ONLY = TRUE) before this file so the overrides below win.
if (!exists("APP_ROOT")) stop("APP_ROOT must be set before sourcing pipeline.R (use R/bootstrap.R)")

`%||%` <- function(a, b) if (is.null(a)) b else a

# Per-run context read by the overridden seams (single-threaded Shiny session).
pipeline_env <- new.env()

# ---- Seam 1: binaries live in <app_root>/bin (OS-aware; see bin_candidates) ---
find_exe <- function(tool, station_dir, root_directory) {
  for (p in bin_candidates(pipeline_env$app_root, tool))
    if (file.exists(p)) return(normalizePath(p))
  stop(sprintf(paste0("%s executable not found in %s/bin for %s. ",
       "Linux users: compile %s 26135 from EPA source and place it as bin/%s_26135_linux."),
       tool, pipeline_env$app_root, os_tag(), tool, tool))
}

# ---- Seam 2: AERSURFACE on demand --------------------------------------------
fetch_aersurface_file <- function(station_code, root_directory, start_year, end_year) {
  ctx <- pipeline_env
  aers_dir <- file.path(root_directory, station_code, "aersurface")
  sfc <- run_aersurface(icao = ctx$icao, name = ctx$name, lat = ctx$lat, lon = ctx$lon,
                        aers_dir = aers_dir, app_root = ctx$app_root,
                        opts = ctx$aers_opts, progress = ctx$progress %||% function(m, f) {})
  dest_name <- basename(sfc)
  dest <- file.path(root_directory, station_code, dest_name)
  file.copy(sfc, dest, overwrite = TRUE)
  dest_name
}

# ---- Seam 3: tolerant upper-air ICAO labelling -------------------------------
get_icao_from_igra <- function(ua_station_id, cache_dir = NULL) {
  igra <- tryCatch(get_igra_info(cache_dir), error = function(e) NULL)
  isd  <- tryCatch(get_isd_history(cache_dir), error = function(e) NULL)
  if (!is.null(igra) && !is.null(isd)) {
    ua <- igra[igra$igra_id == ua_station_id, ]
    cand <- isd[!is.na(isd$icao) & isd$icao != "", ]
    if (nrow(ua) > 0 && nrow(cand) > 0) {
      d <- abs(cand$lat - ua$lat[1]) + abs(cand$lon - ua$lon[1])
      hit <- cand$icao[which.min(d)]
      if (length(hit) == 1 && !is.na(hit) && nzchar(hit)) return(hit)
    }
  }
  paste0("UA", substr(ua_station_id, nchar(ua_station_id) - 4, nchar(ua_station_id)))
}

# =============================================================================
# Public entry point
# =============================================================================
# icao       : 4-letter ICAO of any active US ASOS station
# y1, y2     : start / end year of the met window
# output_root: parent folder for the run output (a per-run subfolder is created)
# aers_opts  : list(moisture, snow, arid, airport, zoradius, nlcd_year) or NULL
# progress   : function(message, fraction) for a Shiny progress bar
#
# Returns a list: station metadata, output_dir, zip_path, sfc_file, completeness.
run_full_pipeline <- function(icao, y1, y2, output_root,
                              aers_opts = NULL,
                              progress = function(m, f) {}) {
  icao <- toupper(icao); y1 <- as.integer(y1); y2 <- as.integer(y2)
  stopifnot(y2 >= y1)
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  cache_dir <- file.path(output_root, "cache")

  progress("Resolving station metadata ...", 0.02)
  surf <- load_surface_stations(cache_dir)
  igra <- load_igra_stations(cache_dir)
  st   <- resolve_station(icao, surf, igra)

  # Merge user options over latitude-based defaults
  opts <- default_aersurface_opts(st$lat)
  if (!is.null(aers_opts)) opts <- modifyList(opts, aers_opts)

  # Per-run output folder = <output_root>/<ICAO>_<y1>_<y2>
  run_dir <- file.path(output_root, sprintf("%s_%d_%d", icao, y1, y2))
  dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)

  # Publish context for the overridden seams
  pipeline_env$icao      <- icao
  pipeline_env$name      <- st$name
  pipeline_env$lat       <- st$lat
  pipeline_env$lon       <- st$lon
  pipeline_env$aers_opts <- opts
  pipeline_env$app_root  <- APP_ROOT
  pipeline_env$progress  <- progress

  progress(sprintf("Starting AERMET build for %s (%s) | UA: %s, %.0f km",
                   icao, st$name, st$ua_station_id, st$ua_dist_km), 0.05)

  # Drive the tested engine: it calls our overridden seams internally.
  paths <- process_aermet_complete(
    station_code   = icao,
    station_id     = st$station_id,
    start_year     = y1,
    end_year       = y2,
    root_directory = run_dir,
    ua_station_id  = st$ua_station_id)

  progress("Packaging output ...", 0.97)
  zip_path <- tryCatch(zip_met_files(paths, y1, y2), error = function(e) NA_character_)

  # Report any 1-minute ASOS months that were unavailable at NCEI (e.g. isolated
  # archive gaps). Only months up to the current month are expected.
  onemin_dir <- file.path(paths$station_dir, "1min")
  present <- if (dir.exists(onemin_dir)) basename(list.files(onemin_dir, pattern = "\\.dat$")) else character(0)
  now <- Sys.Date(); cy <- as.integer(format(now, "%Y")); cm <- as.integer(format(now, "%m"))
  missing <- character(0)
  for (yr in y1:y2) for (mo in 1:12) {
    if (yr > cy || (yr == cy && mo > cm)) next
    if (!any(grepl(sprintf("%d%02d", yr, mo), present)))
      missing <- c(missing, sprintf("%d-%02d", yr, mo))
  }
  if (length(missing))
    progress(sprintf("NOTE: 1-min ASOS not available at NCEI for: %s",
                     paste(missing, collapse = ", ")), 0.99)

  progress("Done.", 1.0)
  list(station = st, output_dir = normalizePath(run_dir),
       station_dir = paths$station_dir,
       zip_path = if (is.na(zip_path)) NA else normalizePath(zip_path),
       missing_asos_months = missing,
       icao = icao, years = c(y1, y2))
}
