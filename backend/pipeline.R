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

RUNNER_VERSION <- "1.4"   # app version (app.R shows it; stamped into each dataset README)

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
                        opts = ctx$aers_opts, nlcd_cache_dir = ctx$nlcd_cache_dir,
                        progress = ctx$progress %||% function(m, f) {})
  # Deliver it under the name the engine's verification report and met report PDF
  # look for (<id>_<nlcd year>_aers_sfc.txt, as in MDEQ production); under any other
  # name both documents say "AERSURFACE file not found" and omit the monthly table.
  dest_name <- sprintf("%s_%s_aers_sfc.txt", tolower(station_code),
                       as.character(ctx$aers_opts$nlcd_year %||% 2021))
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

# ---- Seam 4: the station's own UTC -> local standard time offset -------------
# GHCNh and IGRA are stamped in UTC.  AERMET subtracts the LOCATION keyword's
# tadjust from each reported hour to get local standard time, positive west of
# Greenwich; for GHCNh "the value is the same as the time zone for the station
# (e.g., a value of 5 for the Eastern time zone)" (AERMET User's Guide 26135,
# EPA-454/B-26-005, Sec. 3.3.4 and Appendix A p. A-8; UPPERAIR Sec. 3.4.4.1 and
# p. A-29).  The engine writes 6 (US Central, correct for MDEQ's stations) on both
# lines for every station.
#
# Both lines get the SURFACE station's value.  With upper air present AERMET 26135
# sets its PBL clock from the upper-air tadjust (mod_pbl.f90: pblgmt2lst =
# upgmt2lst(1)) and uses it to compute sunrise at the surface site for the
# convective boundary layer, and it converts the 00Z/12Z sounding window with the
# same value -- so the upper-air line must be on the surface station's clock.
#
# Source of the value, in order: a value the user entered; the station's own
# 1-minute ASOS file (LST in columns 22-23, UTC in 26-27, AERMINUTE User's Guide
# EPA-454/B-26-006 Sec. 3 Fig. 1 -- LST there is standard time all year); the
# state, when it lies wholly in one time zone.  Otherwise stop and ask.

# Standard-time offsets (hours west of UTC) for states wholly in one time zone.
STATE_UTC_OFFSET <- c(
  CT = 5, DC = 5, DE = 5, GA = 5, MA = 5, MD = 5, ME = 5, NC = 5, NH = 5, NJ = 5,
  NY = 5, OH = 5, PA = 5, RI = 5, SC = 5, VA = 5, VT = 5, WV = 5,
  AL = 6, AR = 6, IA = 6, IL = 6, LA = 6, MN = 6, MO = 6, MS = 6, OK = 6, WI = 6,
  AZ = 7, CO = 7, MT = 7, NM = 7, UT = 7, WY = 7,
  CA = 8, WA = 8)
# AK FL ID IN KS KY MI ND NE NV OR SD TN TX span two zones: 1-minute file or user value.

# Offset read from the station's 1-minute ASOS files (NULL if none is readable).
lst_offset_from_1min <- function(onemin_dir) {
  files <- sort(list.files(onemin_dir, pattern = "\\.dat$", full.names = TRUE))
  for (f in files) {
    ln <- tryCatch(readLines(f, n = 20, warn = FALSE), error = function(e) character(0))
    for (l in ln) {
      m <- regmatches(l, regexec(
        "^\\s*\\d{5}[A-Z0-9]{4} [A-Z0-9]{3}\\d{8}(\\d{2})(\\d{2})(\\d{2})(\\d{2})", l))[[1]]
      if (length(m) != 5 || m[3] != m[5]) next          # LST and UTC minutes must agree
      off <- (as.integer(m[4]) - as.integer(m[2])) %% 24
      if (off >= 4 && off <= 11) return(list(value = as.integer(off), file = basename(f)))
    }
  }
  NULL
}

# Returns list(value, source, note); stops when it cannot be determined.
resolve_tadjust <- function(station_dir, state, override = NULL) {
  if (length(override) && !is.na(override)) {
    v <- suppressWarnings(as.numeric(override))
    if (is.na(v) || v != round(v) || v < 4 || v > 11)
      stop(sprintf(paste0("UTC offset %s is not valid: enter whole hours west of UTC in ",
                          "standard time (5 Eastern, 6 Central, 7 Mountain, 8 Pacific)."), override))
    return(list(value = as.integer(v), source = "the value entered by the user", note = ""))
  }
  st_val <- if (length(state) && !is.na(state)) unname(STATE_UTC_OFFSET[state]) else NA
  m <- if (length(station_dir)) lst_offset_from_1min(file.path(station_dir, "1min")) else NULL
  if (!is.null(m)) {
    note <- if (!is.na(st_val) && st_val != m$value)
      sprintf("differs from the %d h expected for %s -- check the station's time zone", st_val, state)
      else ""
    return(list(value = m$value, note = note,
                source = sprintf("the station's 1-minute ASOS file (%s)", m$file)))
  }
  if (!is.na(st_val))
    return(list(value = as.integer(st_val), note = "",
                source = sprintf("its state (%s is all in one time zone)", state)))
  stop(sprintf(paste0("Cannot tell this station's time zone: %s spans more than one and no ",
                      "1-minute ASOS file was available to read it from. Enter the UTC offset ",
                      "(standard time: 5 Eastern, 6 Central, 7 Mountain, 8 Pacific) and run again."),
               if (length(state) && !is.na(state)) state else "its state"))
}

# Replace the tadjust field of an engine LOCATION string ("<id> <lat>N    <lon>W 6 <elev>").
.set_location_tadjust <- function(loc, tz) {
  out <- sub("^(\\S+ \\S+N +\\S+W) 6 ", sprintf("\\1 %d ", as.integer(tz)), loc)
  if (identical(out, loc) && as.integer(tz) != 6L)
    stop("Could not set the UTC offset on the AERMET LOCATION line: ", loc)
  out
}

.engine_get_station_info <- get_station_info
get_station_info <- function(station_code, station_id, ua_station_id, cache_dir = NULL) {
  info <- .engine_get_station_info(station_code, station_id, ua_station_id, cache_dir)
  if (is.null(pipeline_env$state)) stop("get_station_info: run through run_full_pipeline()")
  tz <- resolve_tadjust(pipeline_env$station_dir, pipeline_env$state,
                        pipeline_env$tadjust_override)
  pipeline_env$tadjust <- tz
  for (k in c("surface", "upper_air"))
    info[[k]]$location_string <- .set_location_tadjust(info[[k]]$location_string, tz$value)
  (pipeline_env$progress %||% function(m, f) {})(
    sprintf("UTC to local standard time offset (AERMET tadjust): %d h, from %s%s",
            tz$value, tz$source, if (nzchar(tz$note)) paste0(" -- NOTE: ", tz$note) else ""), 0.3)
  info
}

# ---- Seam 5: is there 1-minute ASOS data anywhere in the window? -------------
# The engine asks about January of the first year only, with a 30 s GET of the whole
# month; a missing month, a slow download or an NCEI hiccup there switched
# AERMINUTE off for every year.  Probe each month of the window with HEAD (no data
# transferred) and stop at the first hit.  If NCEI could not be reached at all,
# stop rather than silently fall back to hourly winds.
.ASOS_1MIN_URL <- paste0("https://www.ncei.noaa.gov/data/automated-surface-observing-",
                         "system-one-minute-pg1/access/%d/%02d/asos-1min-pg1-%s-%d%02d.dat")
check_aerminute_availability <- function(station_code, year, month) {
  y2 <- pipeline_env$end_year %||% year
  onemin <- file.path(pipeline_env$station_dir %||% "", "1min")
  if (length(list.files(onemin, pattern = "\\.dat$"))) {        # already downloaded
    pipeline_env$has_aerminute <- TRUE
    return(TRUE)
  }
  cy <- as.integer(format(Sys.Date(), "%Y")); cm <- as.integer(format(Sys.Date(), "%m"))
  errs <- 0L
  for (y in seq(year, y2)) for (m in 1:12) {
    if (y > cy || (y == cy && m > cm)) next
    url  <- sprintf(.ASOS_1MIN_URL, y, m, station_code, y, m)
    head <- function() tryCatch(httr::status_code(httr::HEAD(url, httr::timeout(60))),
                                error = function(e) NA_integer_)
    code <- head()
    if (is.na(code)) { Sys.sleep(2); code <- head() }          # one retry per month
    if (isTRUE(code == 200)) { pipeline_env$has_aerminute <- TRUE; return(TRUE) }
    if (is.na(code)) errs <- errs + 1L
  }
  if (errs > 0)
    stop(sprintf(paste0("Could not reach NCEI to check for 1-minute ASOS winds (%d request(s) ",
                        "failed). Not falling back to hourly winds silently -- try again."), errs))
  pipeline_env$has_aerminute <- FALSE
  FALSE
}

# ---- Seam 6: anemometer height ------------------------------------------------
# The engine writes NWS_HGT WIND 10.00 for every station.  ASOS anemometers are
# "typically 10.1 meters or 7.9 meters" and the user "should consult a reference
# ... to obtain the correct height" (AERMET User's Guide 26135, Sec. 3.7.5).
.engine_create_stage2_content <- create_stage2_content
create_stage2_content <- function(...) {
  x <- .engine_create_stage2_content(...)
  h <- pipeline_env$anem_height
  if (length(h) && !is.na(h))
    x <- sub("^(\\s*NWS_HGT\\s+WIND\\s+)[0-9.]+", sprintf("\\1%.2f", h), x)
  x
}

# ---- Seam 7: the verification report describes THIS run ----------------------
.engine_generate_verification_report <- generate_verification_report
generate_verification_report <- function(results, station_code, start_year, end_year) {
  rc <- .engine_generate_verification_report(results, station_code, start_year, end_year)
  rc0 <- rc
  i <- grep("^   Wind reference ht ", rc)[1]
  if (!is.na(i)) {
    rc[i] <- paste0(rc[i], "  -- ", .anem_text())
    tz <- pipeline_env$tadjust
    if (!is.null(tz))
      rc <- append(rc, sprintf("   UTC to LST offset    %d h   -- AERMET tadjust, from %s",
                               tz$value, tz$source), after = i + 1L)
  }
  if (isFALSE(pipeline_env$has_aerminute)) {
    j <- grep("^   1-minute winds ", rc)[1]
    if (!is.na(j))
      rc[j:(j + 1L)] <- c(
        "   1-minute winds       NOT USED -- NCEI has no 1-minute ASOS archive for this",
        "                        station and period; winds are the hourly GHCNh reports")
  }
  if (!identical(rc, rc0))
    writeLines(rc, file.path(results$station_dir,
                             sprintf("%s_verification_report.txt", station_code)))
  rc
}

.anem_text <- function() {
  if (isTRUE(pipeline_env$anem_entered))
    sprintf("NWS_HGT %.2f m entered by the user", pipeline_env$anem_height)
  else "NWS_HGT default 10 m, not verified for this station"
}

# ---- Seam 8: the dataset README names the tool and this run, not MDEQ ---------
create_readme <- function(station_code, start_year, end_year) {
  tz <- pipeline_env$tadjust
  winds <- if (isFALSE(pipeline_env$has_aerminute))
    "hourly GHCNh winds (NCEI has no 1-minute ASOS archive for this station and period)"
  else sprintf("AERMINUTE %s hourly-averaged 1-minute ASOS winds", AERMET_VERSION)
  paste0(
    sprintf("AERMOD-ready meteorological data for %s, %d-%d.\n\n", station_code, start_year, end_year),
    sprintf("Processed with AERMET %s using GHCNh surface data (NCEI), IGRA upper air\n", AERMET_VERSION),
    sprintf("soundings, %s,\nand AERSURFACE 26135 surface characteristics (NLCD %s).\n\n", winds,
            as.character(pipeline_env$aers_opts$nlcd_year %||% 2021)),
    if (!is.null(tz)) sprintf("UTC to local standard time offset (AERMET tadjust): %d h, from %s.\n",
                              tz$value, tz$source) else "",
    sprintf("Anemometer height: %.2f m (%s).\n\n", pipeline_env$anem_height %||% 10, .anem_text()),
    sprintf("Files %s[YYYY].sfc/.pfl were processed without ADJ_U*;\n", station_code),
    sprintf("files %s[YYYY]US.sfc/.pfl were processed with METHOD STABLEBL ADJ_U*.\n\n", station_code),
    "See the included met report PDF for wind roses, climatology, mixing height,\n",
    "stability, and data-completeness graphics, the verification report for\n",
    "quarterly completeness statistics, and the QA summary.\n\n",
    sprintf("Produced with AERMET Runner v%s (https://github.com/Cuevman81/aermet-runner),\n",
            RUNNER_VERSION),
    "which runs the EPA programs named above. Direct questions about this dataset to\n",
    "whoever produced it; report problems with the tool itself on GitHub.")
}

# ---- The engine's report and PDF look stations up in STATION_REGISTRY ---------
# That table holds MDEQ's 18 stations and their production upper-air pairings.
# Record the station and upper-air site THIS run used, so both documents describe
# them (the app pairs some MDEQ stations differently, e.g. KTUP -> Birmingham).
register_run_station <- function(icao, st) {
  env <- environment(process_aermet_complete)
  reg <- get("STATION_REGISTRY", envir = env)
  reg <- reg[reg$code != icao, , drop = FALSE]
  assign("STATION_REGISTRY",
         rbind(reg, data.frame(code = icao, station_id = st$station_id,
                               ua_station_id = st$ua_station_id, stringsAsFactors = FALSE)),
         envir = env)
  invisible(TRUE)
}

# =============================================================================
# Public entry point
# =============================================================================
# icao       : 4-letter ICAO of any active US ASOS station
# y1, y2     : start / end year of the met window
# output_root: parent folder for the run output (a per-run subfolder is created)
# aers_opts  : list(moisture, snow, arid, airport, zoradius, nlcd_year) or NULL
# progress   : function(message, fraction) for a Shiny progress bar
# met_opts   : list(tadjust, anem_height) or NULL
#                tadjust     UTC-to-LST offset in hours (NULL = from the station's
#                            1-minute file or its state; required in split states
#                            when there is no 1-minute file)
#                anem_height anemometer height in m (NULL = 10 m)
#
# Returns a list: station metadata, output_dir, zip_path, sfc_file, completeness.
run_full_pipeline <- function(icao, y1, y2, output_root,
                              aers_opts = NULL,
                              progress = function(m, f) {},
                              met_opts = NULL) {
  icao <- toupper(icao); y1 <- as.integer(y1); y2 <- as.integer(y2)
  stopifnot(y2 >= y1)
  anem <- met_opts$anem_height
  if (length(anem) && !is.na(anem) && (!is.numeric(anem) || anem < 1 || anem > 50))
    stop(sprintf("Anemometer height %s m is not plausible (expected 1-50 m).", anem))
  dir.create(output_root, recursive = TRUE, showWarnings = FALSE)
  cache_dir <- file.path(output_root, "cache")

  progress("Resolving station metadata ...", 0.02)
  surf <- load_surface_stations(cache_dir)
  igra <- load_igra_stations(cache_dir)
  st   <- resolve_station(icao, surf, igra)

  # Merge user options over latitude-based defaults
  opts <- default_aersurface_opts(st$lat)
  if (!is.null(aers_opts)) opts <- modifyList(opts, aers_opts)

  # Auto surface moisture from the site's rainfall record (EPA 30/70 percentile rule)
  moisture_info <- NULL
  if (identical(toupper(opts$moisture %||% ""), "AUTO")) {
    progress("Determining surface moisture from rainfall ...", 0.03)
    mc <- classify_moisture(y1:y2, st$ghcnh_id, cache_dir)
    opts$moisture <- mc$overall
    moisture_info <- mc
    progress(sprintf("Auto moisture -> %s  (%s)", mc$overall, mc$note), 0.04)
    if (isTRUE(mc$ok)) for (i in seq_len(nrow(mc$per_year)))
      progress(sprintf("   %d: %.1f in -> %s", mc$per_year$year[i],
                       mc$per_year$precip_in[i], mc$per_year$class[i]), 0.04)
  }

  # Per-run output folder = <output_root>/<ICAO>_<y1>_<y2>
  run_dir <- file.path(output_root, sprintf("%s_%d_%d", icao, y1, y2))
  dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)

  # Publish context for the overridden seams. The NLCD cache is site-level (keyed
  # by ICAO + NLCD year), so it survives across year windows and moisture re-runs.
  pipeline_env$icao           <- icao
  pipeline_env$name           <- st$name
  pipeline_env$lat            <- st$lat
  pipeline_env$lon            <- st$lon
  pipeline_env$aers_opts      <- opts
  pipeline_env$app_root       <- APP_ROOT
  pipeline_env$progress       <- progress
  pipeline_env$nlcd_cache_dir <- file.path(cache_dir, "nlcd",
                                           sprintf("%s_%s", icao, as.character(opts$nlcd_year %||% 2021)))
  station_dir <- file.path(run_dir, icao)
  pipeline_env$station_dir      <- station_dir
  pipeline_env$state            <- st$state
  pipeline_env$end_year         <- y2
  pipeline_env$tadjust_override <- met_opts$tadjust
  pipeline_env$tadjust          <- NULL
  pipeline_env$has_aerminute    <- NULL
  pipeline_env$anem_entered     <- length(anem) > 0 && !is.na(anem)
  pipeline_env$anem_height      <- if (pipeline_env$anem_entered) as.numeric(anem) else 10
  register_run_station(icao, st)

  # Note whether the met data is already local (the engine skips re-downloading
  # GHCNh / IGRA / 1-min & 5-min ASOS when the files exist), so a re-run that only
  # changes an AERSURFACE option (e.g. moisture) never re-fetches met data.
  met_cached <- length(list.files(station_dir, pattern = "_GHCNh_.*\\.psv$")) > 0 ||
    (dir.exists(file.path(station_dir, "1min")) &&
       length(list.files(file.path(station_dir, "1min"), pattern = "\\.dat$")) > 0)
  progress(if (met_cached) "Reusing cached met data from a previous run (no re-download) ..."
           else "Fetching met data (first run for this station/years) ...", 0.05)

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

  # --- Post-run QA: prove AERSURFACE + AERMET ran correctly and the data is sound
  progress("Running QA checks ...", 0.95)
  aers_dir <- file.path(paths$station_dir, "aersurface")
  qa <- tryCatch(qa_run(paths$station_dir, aers_dir, icao, y1, y2),
                 error = function(e) list(overall = "WARN",
                   checks = list(list(group = "QA", label = "QA checks",
                     status = "warn", detail = conditionMessage(e))),
                   text = c("QA could not complete:", conditionMessage(e))))
  qa_file <- file.path(paths$station_dir, sprintf("%s_QA_SUMMARY.txt", icao))
  writeLines(qa$text, qa_file)
  progress(sprintf("QA overall: %s", qa$overall), 0.96)

  progress("Packaging output ...", 0.97)
  zip_path <- tryCatch(zip_met_files(paths, y1, y2), error = function(e) NA_character_)
  # fold the QA summary into the delivered zip
  if (!is.na(zip_path) && file.exists(qa_file))
    tryCatch(utils::zip(zip_path, qa_file, flags = "-jgq"), error = function(e) NULL)

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

  progress(sprintf("Done. QA: %s", qa$overall), 1.0)
  list(station = st, output_dir = normalizePath(run_dir),
       station_dir = paths$station_dir,
       zip_path = if (is.na(zip_path)) NA else normalizePath(zip_path),
       missing_asos_months = missing,
       moisture = opts$moisture, moisture_info = moisture_info,
       qa = qa,
       icao = icao, years = c(y1, y2))
}
