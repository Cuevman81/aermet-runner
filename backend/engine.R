# =====================================================================================
# AERMET.R  --  MDEQ AERMET/AERMINUTE processing pipeline, v26135 / GHCNh edition
#
# Updated July 2026 for the EPA AERMOD Modeling System 26135 release:
#   * Surface data source: GHCNh (pipe-delimited .psv from NCEI) replaces ISHD,
#     which NOAA stopped updating after 2025-08-29.  Stage 1 keyword: DATA <file> GHCN
#   * Cross-platform: runs on macOS (native gfortran builds in bin/) and Windows
#     (EPA .exe in bin/).  No hardcoded C:\ paths.
#   * AERMET Stage 2 (26135) writes 4-digit years in .sfc/.pfl; verification parsers
#     accept both 2- and 4-digit years.
#   * AERMINUTE 26135: same INP syntax; SURFDATA now lists the GHCNh file.
#   * AERSURFACE file auto-copied from ../AERSURFACE/stations/<id>/met_<window>/.
#
# Usage (from the AERMINUTE folder):
#   Rscript AERMET.R                      # processes all stations in STATIONS
#   or in R:  AERMET_SOURCE_ONLY <- TRUE; source("AERMET.R"); then
#             process_aermet_complete("KGLH", start_year=2021, end_year=2025)
#
# Previous ISHD-based version preserved as AERMET_24142_backup.R
# =====================================================================================

library(httr)

# ------------------------------- configuration --------------------------------------

MET_START_YEAR <- 2021
MET_END_YEAR   <- 2025
AERMET_VERSION <- "26135"

STATIONS <- c("KCBM","KGLH","KGPT","KGTR","KGWO","KHBG","KHEZ","KHKS","KJAN",
              "KMCB","KMEI","KMEM","KMOB","KPIB","KPQL","KTUP","KTVR","KUTA")

# Station registry: ISHD-era USAF-WBAN id (used for isd-history metadata lookup),
# WBAN (drives the GHCNh station id = USW000 + WBAN), and IGRA upper-air station.
STATION_REGISTRY <- data.frame(
  code = c("KCBM","KGLH","KGPT","KGTR","KGWO","KHBG","KHEZ","KHKS","KJAN",
           "KMCB","KMEI","KMEM","KMOB","KPIB","KPQL","KTUP","KTVR","KUTA"),
  station_id = c("723306-13825","747680-13939","747570-93874","723307-53893",
                 "747580-13978","747590-13833","722357-03961","722354-13927",
                 "722350-03940","722358-93919","722340-13865","723340-13893",
                 "722230-13894","722348-53808","747688-53858","723320-93862",
                 "722488-03996","722364-23903"),
  ua_station_id = c("USM00072235","USM00072235","USM00072233","USM00072235",
                    "USM00072235","USM00072235","USM00072235","USM00072235",
                    "USM00072235","USM00072235","USM00072235","USM00072340",
                    "USM00072233","USM00072235","USM00072233","USM00072235",
                    "USM00072235","USM00072235"),
  stringsAsFactors = FALSE
)

# ----------------------------- platform helpers -------------------------------------

is_windows <- function() .Platform$OS.type == "windows"

# Native path separators for text written into AERMET/AERMINUTE control files.
np <- function(p) if (is_windows()) gsub("/", "\\\\", p) else p

# Filenames in control files are written RELATIVE to the station folder and the
# programs are executed with the station folder as the working directory:
#   * AERMET 26135's filename parser leaves residue from quoted names, so DATA
#     filenames must be UNQUOTED (E02 INVALID DATA FILENAME otherwise).
#   * AERMINUTE reads its file lists with Fortran list-directed reads, where an
#     unquoted '/' terminates input -- so paths there must be QUOTED.
# Relative names keep both happy on macOS and Windows alike.

# Locate a program: prefer the 26135 build in <root>/bin, then the station folder.
find_exe <- function(tool, station_dir, root_directory) {
  cands <- if (is_windows()) {
    c(file.path(root_directory, "bin", sprintf("%s_26135.exe", tool)),
      file.path(station_dir, sprintf("%s.exe", tool)),
      file.path(station_dir, sprintf("%s_26135.exe", tool)))
  } else {
    c(file.path(root_directory, "bin", sprintf("%s_26135_mac", tool)),
      file.path(root_directory, "bin", tool),
      file.path(station_dir, tool))
  }
  for (p in cands) if (file.exists(p)) return(normalizePath(p))
  stop(sprintf("%s executable not found. Looked in:\n  %s", tool,
               paste(cands, collapse = "\n  ")))
}

# Run a program in a working directory, optionally feeding stdin lines.
run_program <- function(exe, workdir, stdin_lines = NULL) {
  old <- getwd(); on.exit(setwd(old))
  setwd(workdir)
  status <- if (is.null(stdin_lines)) system2(exe, stdout = "", stderr = "")
            else system2(exe, input = stdin_lines, stdout = "", stderr = "")
  invisible(status)
}

# sprintf("%d", NA) errors; report-friendly integer formatting
fmt_int <- function(x) if (length(x) == 0 || is.na(x)) "NA" else sprintf("%d", as.integer(x))

# Accept 2- or 4-digit years when checking values parsed from .sfc/.pfl files
# (AERMET 26135 writes 4-digit years; earlier versions wrote 2-digit).
year_matches <- function(parsed, expected) {
  !is.na(parsed) & (parsed == expected | parsed == expected %% 100)
}

# --------------------------- station metadata (NCEI) --------------------------------

get_isd_history <- function(cache_dir = NULL) {
  if (is.null(cache_dir)) cache_dir <- file.path(getwd(), "cache")
  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)
  isd_file <- file.path(cache_dir, "isd-history.txt")

  needs_dl <- !file.exists(isd_file) ||
    difftime(Sys.time(), file.info(isd_file)$mtime, units = "days") > 30
  if (needs_dl) {
    cat("Downloading ISD history file...\n")
    ok <- tryCatch({
      download.file("https://www.ncei.noaa.gov/pub/data/noaa/isd-history.txt",
                    isd_file, mode = "wb", quiet = TRUE); TRUE
    }, error = function(e) FALSE)
    if (!ok && !file.exists(isd_file))
      stop("Failed to download isd-history.txt and no cached copy exists")
  }

  lines <- readLines(isd_file, warn = FALSE)
  start_line <- which(grepl("^USAF   WBAN  STATION NAME", lines))[1] + 2
  if (is.na(start_line)) stop("Could not find data section in ISD history file")
  data_lines <- lines[start_line:length(lines)]
  data_lines <- data_lines[nchar(trimws(data_lines)) > 0]

  parse_line <- function(line) {
    if (nchar(line) < 84) line <- sprintf("%-84s", line)
    list(usaf = trimws(substr(line, 1, 6)),
         wban = trimws(substr(line, 8, 12)),
         station_name = trimws(substr(line, 14, 42)),
         state = trimws(substr(line, 49, 50)),
         icao = trimws(substr(line, 52, 55)),
         lat = as.numeric(trimws(substr(line, 57, 64))),
         lon = as.numeric(trimws(substr(line, 66, 73))),
         elev_m = as.numeric(gsub("\\+", "", substr(line, 75, 81))),
         begin_date = trimws(substr(line, 83, 90)),
         end_date = if (nchar(line) >= 99) trimws(substr(line, 92, 99)) else NA)
  }
  isd <- do.call(rbind, lapply(lapply(data_lines, parse_line),
                               as.data.frame, stringsAsFactors = FALSE))
  isd$station_id <- paste(isd$usaf, isd$wban, sep = "-")
  isd[!is.na(isd$lat) & !is.na(isd$lon) & !is.na(isd$elev_m), ]
}

get_igra_info <- function(cache_dir = NULL) {
  if (is.null(cache_dir)) cache_dir <- file.path(getwd(), "cache")
  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)
  igra_file <- file.path(cache_dir, "igra2-station-list.txt")
  if (!file.exists(igra_file) ||
      difftime(Sys.time(), file.info(igra_file)$mtime, units = "days") > 30) {
    download.file("https://www.ncei.noaa.gov/pub/data/igra/igra2-station-list.txt",
                  igra_file, quiet = TRUE)
  }
  igra <- read.fwf(igra_file,
                   widths = c(11, 9, 10, 7, 3, 30, 4, 4, 6),
                   col.names = c("igra_id","lat","lon","elev_m","state",
                                 "station_name","first_year","last_year","num_records"),
                   strip.white = TRUE, stringsAsFactors = FALSE)
  igra$lat <- as.numeric(igra$lat); igra$lon <- as.numeric(igra$lon)
  igra$elev_m <- as.numeric(igra$elev_m)
  igra
}

get_icao_from_igra <- function(ua_station_id, cache_dir = NULL) {
  direct <- list("USM00072235" = "KJAN",   # Jackson, MS
                 "USM00072233" = "KLIX",   # Slidell, LA
                 "USM00072340" = "KLZK",   # Little Rock, AR
                 "USM00072248" = "KSHV",   # Shreveport, LA
                 "USM00072327" = "KSGF",   # Springfield, MO
                 "USM00072318" = "KBNA")   # Nashville, TN
  if (!is.null(direct[[ua_station_id]])) return(direct[[ua_station_id]])
  igra <- get_igra_info(cache_dir)
  isd  <- get_isd_history(cache_dir)
  ua <- igra[igra$igra_id == ua_station_id, ]
  if (nrow(ua) == 0) stop(sprintf("Unknown IGRA station: %s", ua_station_id))
  hit <- isd[abs(isd$lat - ua$lat[1]) < 0.02 & abs(isd$lon - ua$lon[1]) < 0.02 &
             !is.na(isd$icao) & isd$icao != "", ][1, ]
  if (is.na(hit$icao)) stop(sprintf("No ICAO found for IGRA station %s", ua_station_id))
  hit$icao
}

format_coord <- function(coord) {
  a <- abs(coord)
  sprintf("%d.%03d", floor(a), round((a - floor(a)) * 1000))
}

get_station_info <- function(station_code, station_id, ua_station_id, cache_dir = NULL) {
  isd  <- get_isd_history(cache_dir)
  igra <- get_igra_info(cache_dir)

  surface <- isd[isd$station_id == station_id, ][1, ]
  if (is.na(surface$usaf))
    surface <- isd[!is.na(isd$icao) & isd$icao == station_code, ][1, ]
  if (is.na(surface$usaf))
    stop(sprintf("No ISD metadata for %s (%s)", station_code, station_id))

  ua <- igra[igra$igra_id == ua_station_id, ][1, ]
  if (is.na(ua$igra_id)) stop(sprintf("No IGRA metadata for %s", ua_station_id))
  ua_wban <- substr(ua_station_id, 6, 10)

  list(
    surface = list(
      station_code = station_code, station_id = station_id,
      station_name = surface$station_name, wban = surface$wban,
      location_string = sprintf("%s %sN    %sW 6 %.2f",
                                surface$wban, format_coord(surface$lat),
                                format_coord(surface$lon), surface$elev_m)),
    upper_air = list(
      igra_id = ua_station_id, wban = ua_wban, ua_name = trimws(ua$station_name),
      location_string = sprintf("%s %sN    %sW 6 %.2f",
                                ua_wban, format_coord(ua$lat),
                                format_coord(abs(ua$lon)), ua$elev_m))
  )
}

# ------------------------------ data acquisition -------------------------------------

# GHCNh: pipe-delimited by-year station files from NCEI.  Downloads each year,
# concatenates into one .psv (header kept once) for AERMET Stage 1 / AERMINUTE.
download_ghcnh <- function(station_code, wban, start_year, end_year, station_dir) {
  ghcn_id <- paste0("USW000", wban)
  out_file <- file.path(station_dir,
                        sprintf("%s_GHCNh_%d_%d.psv", station_code, start_year, end_year))
  if (file.exists(out_file) && file.size(out_file) > 0) {
    cat(sprintf("GHCNh file already present: %s\n", basename(out_file)))
    return(out_file)
  }
  base <- "https://www.ncei.noaa.gov/oa/global-historical-climatology-network/hourly/access/by-year"
  old_to <- getOption("timeout"); options(timeout = 900); on.exit(options(timeout = old_to))

  all_lines <- character(0); header <- NULL
  for (year in start_year:end_year) {
    url <- sprintf("%s/%d/psv/GHCNh_%s_%d.psv", base, year, ghcn_id, year)
    tmp <- file.path(station_dir, sprintf("ghcnh_%s_%d.psv.tmp", ghcn_id, year))
    cat(sprintf("Downloading GHCNh %s %d ... ", ghcn_id, year))
    ok <- tryCatch({
      download.file(url, tmp, mode = "wb", quiet = TRUE)
      file.exists(tmp) && file.size(tmp) > 1000
    }, error = function(e) FALSE)
    if (!ok) { unlink(tmp); stop(sprintf("GHCNh download failed for %s %d (%s)", ghcn_id, year, url)) }
    ln <- readLines(tmp, warn = FALSE)
    unlink(tmp)
    if (is.null(header)) { header <- ln[1]; all_lines <- c(all_lines, ln) }
    else all_lines <- c(all_lines, ln[-1])
    cat(sprintf("%d records\n", length(ln) - 1))
  }
  writeLines(all_lines, out_file)
  cat(sprintf("GHCNh combined file: %s (%d data records)\n",
              basename(out_file), length(all_lines) - 1))
  out_file
}

# ------------------------------ GHCNh quality control --------------------------------
#
# AERMET reads the GHCNh .psv as delivered and does not honour NCEI's per-element
# quality flags, so observations NCEI itself marked "suspect" or "erroneous" reach the
# .sfc verbatim.  At KMEI that put 50 hours of 30.16 m/s into April-May 2025 (every one
# of them qc=2 on a 3-hourly FM12 SYNOP report); KTUP 2025 carried 25 more.
#
# Two independent screens are applied.  Both only ever blank a value -- the element
# becomes missing for that observation and AERMET falls back to AERMINUTE or to its own
# substitution logic.  No record is dropped and no value is altered or invented, so the
# edit stays defensible and is fully auditable from the log written beside the file.
#
#   1. Quality codes.  ISD/GHCNh codes 2 and 6 mean "suspect", 3 and 7 "erroneous";
#      0/1/4/5/9 and blank pass.  Applied to every element carrying a *_Quality_Code.
#
#   2. Wind-speed cross-check.  NCEI carries the verbatim METAR/SPECI text in REM, so
#      the decoded wind_speed can be checked against the report it came from.  KMEI
#      2025-05-01 19:55Z and 19:58Z both decode to 54.1 m/s from a METAR that plainly
#      reads 25010KT (5.1 m/s), and NCEI flags one of them qc=5 "passed all checks" --
#      a decoding error the quality flags miss entirely.  Wind direction was checked
#      the same way across 821,424 METAR groups with zero disagreement, so only speed
#      is screened.
#
# The function is idempotent: a blanked value cannot be blanked twice, so re-running
# the pipeline over an already-filtered .psv is a no-op.

GHCNH_BAD_QC <- c("2", "3", "6", "7")   # suspect (2,6) and erroneous (3,7)
GHCNH_WS_TOL <- 5                       # m/s; decoded-vs-METAR tolerance
GHCNH_KT     <- 0.514444

ghcnh_isopen <- function(cc) tryCatch(isOpen(cc), error = function(e) FALSE)

# knots from the wind group of a METAR/SPECI report ("25010KT", "VRB03G15KT", ...)
metar_wind_kt <- function(rem) {
  m <- regmatches(rem, regexpr("\\b(\\d{3}|VRB)\\d{2,3}(G\\d{2,3})?KT\\b", rem))
  if (!length(m)) return(NA_real_)
  suppressWarnings(as.numeric(sub("^(\\d{3}|VRB)(\\d{2,3}).*$", "\\2", m)))
}

filter_ghcnh_quality <- function(psv_file, log_file = NULL, chunk = 20000L,
                                 verbose = TRUE) {
  if (!file.exists(psv_file) || file.size(psv_file) == 0)
    stop("GHCNh file not found: ", psv_file)
  if (is.null(log_file))
    log_file <- sub("\\.psv$", "_qc_log.txt", psv_file)

  con <- file(psv_file, "r"); out <- NULL
  on.exit({
    for (cc in list(con, out))
      if (!is.null(cc) && inherits(cc, "connection") && ghcnh_isopen(cc))
        try(close(cc), silent = TRUE)
  }, add = TRUE)

  header <- readLines(con, n = 1L, warn = FALSE)
  cols   <- strsplit(header, "|", fixed = TRUE)[[1]]
  ncol   <- length(cols)

  qc_idx  <- grep("_Quality_Code$", cols); qc_idx <- qc_idx[qc_idx > 2L]
  val_idx <- qc_idx - 2L            # layout: value, Measurement_Code, Quality_Code, ...
  elem    <- sub("_Quality_Code$", "", cols[qc_idx])
  keep    <- cols[val_idx] == elem  # only trust the pairing where it really lines up
  qc_idx  <- qc_idx[keep]; val_idx <- val_idx[keep]; elem <- elem[keep]

  i_ws  <- match("wind_speed", cols)
  i_rem <- match("REM", cols)
  i_t   <- match("DATE", cols); if (is.na(i_t)) i_t <- 3L

  tmp <- paste0(psv_file, ".qctmp")
  out <- file(tmp, "w")
  writeLines(header, out)

  counts <- setNames(integer(length(elem)), elem)
  n_ws_x <- 0L
  audit  <- list(); xaudit <- list()
  nrec   <- 0L

  repeat {
    lines <- readLines(con, n = chunk, warn = FALSE)
    if (!length(lines)) break
    nrec <- nrec + length(lines)

    f   <- strsplit(lines, "|", fixed = TRUE)
    len <- lengths(f)
    if (any(len < ncol))
      f[len < ncol] <- lapply(f[len < ncol], function(v) c(v, rep("", ncol - length(v))))
    m <- matrix(unlist(f, use.names = FALSE), nrow = length(f), byrow = TRUE)

    # --- screen 1: NCEI quality codes ---
    for (j in seq_along(qc_idx)) {
      bad <- m[, qc_idx[j]] %in% GHCNH_BAD_QC & nzchar(m[, val_idx[j]])
      if (!any(bad)) next
      counts[j] <- counts[j] + sum(bad)
      audit[[length(audit) + 1L]] <- data.frame(
        timestamp = m[bad, i_t], element = elem[j],
        value = m[bad, val_idx[j]], qc = m[bad, qc_idx[j]], stringsAsFactors = FALSE)
      m[bad, val_idx[j]] <- ""
    }

    # --- screen 2: decoded wind speed vs the METAR it came from ---
    if (!is.na(i_ws) && !is.na(i_rem)) {
      w <- suppressWarnings(as.numeric(m[, i_ws]))
      cand <- which(!is.na(w) & nzchar(m[, i_rem]))
      if (length(cand)) {
        kt <- vapply(m[cand, i_rem], metar_wind_kt, numeric(1), USE.NAMES = FALSE)
        mw <- kt * GHCNH_KT
        off <- which(!is.na(mw) & abs(mw - w[cand]) > GHCNH_WS_TOL)
        if (length(off)) {
          r <- cand[off]
          n_ws_x <- n_ws_x + length(r)
          xaudit[[length(xaudit) + 1L]] <- data.frame(
            timestamp = m[r, i_t], decoded = m[r, i_ws],
            metar = sprintf("%.1f", mw[off]), rem_kt = sprintf("%g", kt[off]),
            stringsAsFactors = FALSE)
          m[r, i_ws] <- ""
        }
      }
    }

    writeLines(apply(m, 1L, paste, collapse = "|"), out)
  }

  close(out); out <- NULL
  close(con); con <- NULL
  if (!file.rename(tmp, psv_file)) { unlink(tmp); stop("could not replace ", psv_file) }

  hit <- counts[counts > 0]
  lg <- c(sprintf("GHCNh quality-control filter log -- %s", basename(psv_file)),
          sprintf("Applied: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), "",
          "Rejected values are blanked so AERMET treats the element as missing for that",
          "observation.  No record is dropped and no value is altered or substituted.",
          "",
          sprintf("Records scanned        : %d", nrec),
          sprintf("Screen 1 (NCEI flags)  : %d values rejected", sum(counts)),
          sprintf("Screen 2 (METAR check) : %d wind speeds rejected", n_ws_x), "",
          "SCREEN 1 -- NCEI quality codes 2/6 (suspect) and 3/7 (erroneous)")
  if (length(hit)) {
    aud <- do.call(rbind, audit)
    lg <- c(lg, sprintf("   %-30s %6d", names(hit), hit), "",
            "   Detail (timestamp | element | rejected value | quality code):",
            sprintf("   %s | %s | %s | %s", aud$timestamp, aud$element, aud$value, aud$qc))
  } else lg <- c(lg, "   none")
  lg <- c(lg, "",
          sprintf("SCREEN 2 -- decoded wind_speed vs METAR text (tolerance %g m/s)",
                  GHCNH_WS_TOL))
  if (n_ws_x) {
    xa <- do.call(rbind, xaudit)
    lg <- c(lg, "   Detail (timestamp | decoded m/s | METAR m/s | METAR kt):",
            sprintf("   %s | %s | %s | %s", xa$timestamp, xa$decoded, xa$metar, xa$rem_kt))
  } else lg <- c(lg, "   none")

  # The log is the audit trail for values that are no longer present in the .psv, so
  # it has to survive a re-run.  Re-processing an already-screened file rejects
  # nothing; leave the existing log as it stands rather than overwriting it with
  # zeroes and destroying the record of the first pass.
  if (sum(counts) == 0 && n_ws_x == 0 && file.exists(log_file)) {
    if (verbose)
      cat(sprintf("QC filter: %s already screened; existing log left intact\n",
                  basename(psv_file)))
    return(invisible(list(records = nrec, rejected = 0L, ws_crosscheck = 0L,
                          by_element = integer(0), log_file = log_file)))
  }
  writeLines(lg, log_file)

  if (verbose)
    cat(sprintf("QC filter: %s -- %d records, %d flagged + %d METAR-mismatch rejected\n",
                basename(psv_file), nrec, sum(counts), n_ws_x))
  invisible(list(records = nrec, rejected = sum(counts), ws_crosscheck = n_ws_x,
                 by_element = hit, log_file = log_file))
}

download_igra_data <- function(ua_station_id, start_year, end_year,
                               root_directory, station_code, timeout = 600) {
  icao_code <- get_icao_from_igra(ua_station_id)
  output_dir <- file.path(root_directory, station_code)
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  output_file <- file.path(output_dir, sprintf("%s%02d-%02dUA.txt", icao_code,
                                               start_year %% 100, end_year %% 100))
  if (file.exists(output_file) && file.size(output_file) > 0) {
    ln <- readLines(output_file, warn = FALSE)
    hdr <- grep("^#", ln, value = TRUE)
    yrs <- suppressWarnings(as.numeric(substr(hdr, 14, 17)))
    if (length(yrs) && min(yrs, na.rm = TRUE) <= start_year &&
        max(yrs, na.rm = TRUE) >= end_year) {
      cat(sprintf("IGRA data already present: %s\n", basename(output_file)))
      return(output_file)
    }
  }
  url <- sprintf("https://www.ncei.noaa.gov/pub/data/igra/data/data-por/%s-data.txt.zip",
                 ua_station_id)
  old_to <- getOption("timeout"); options(timeout = timeout); on.exit(options(timeout = old_to))
  temp_zip <- tempfile(fileext = ".zip")
  cat(sprintf("Downloading IGRA data for %s ...\n", ua_station_id))
  download.file(url, temp_zip, mode = "wb", quiet = TRUE)
  temp_dir <- tempfile(); dir.create(temp_dir)
  unzip(temp_zip, exdir = temp_dir); unlink(temp_zip)
  data_file <- file.path(temp_dir, paste0(ua_station_id, "-data.txt"))
  if (!file.exists(data_file)) stop("IGRA zip did not contain expected data file")

  con_in <- file(data_file, "r"); con_out <- file(output_file, "w")
  cur_hdr <- NULL; cur_dat <- character(0)
  flush_snd <- function() {
    if (!is.null(cur_hdr)) {
      yr <- suppressWarnings(as.numeric(substr(cur_hdr, 14, 17)))
      if (!is.na(yr) && yr >= start_year && yr <= end_year)
        writeLines(c(cur_hdr, cur_dat), con_out)
    }
  }
  while (TRUE) {
    line <- readLines(con_in, n = 1)
    if (length(line) == 0) break
    if (substr(line, 1, 1) == "#") { flush_snd(); cur_hdr <- line; cur_dat <- character(0) }
    else cur_dat <- c(cur_dat, line)
  }
  flush_snd()
  close(con_in); close(con_out); unlink(temp_dir, recursive = TRUE)
  if (!file.exists(output_file) || file.size(output_file) == 0)
    stop("IGRA extraction produced an empty file")
  cat(sprintf("IGRA soundings written: %s\n", basename(output_file)))
  output_file
}

check_aerminute_availability <- function(station_code, year, month) {
  url <- sprintf(paste0("https://www.ncei.noaa.gov/data/automated-surface-observing-",
                        "system-one-minute-pg1/access/%d/%02d/asos-1min-pg1-%s-%d%02d.dat"),
                 year, month, station_code, year, month)
  tryCatch(status_code(GET(url, timeout(30))) == 200, error = function(e) FALSE)
}

download_asos <- function(station_code, year, month, data_type, output_dir) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
  base_url <- if (data_type == "1min")
    "https://www.ncei.noaa.gov/data/automated-surface-observing-system-one-minute-pg1/access/"
  else
    "https://www.ncei.noaa.gov/data/automated-surface-observing-system-five-minute/access/"
  prefix <- if (data_type == "1min") "64050" else "64010"
  url_suffix <- if (data_type == "1min")
    sprintf("/asos-1min-pg1-%s-%d%02d.dat", station_code, year, month)
  else
    sprintf("/asos-5min-%s-%d%02d.dat", station_code, year, month)
  url <- paste0(base_url, year, "/", sprintf("%02d", month), url_suffix)
  file_path <- file.path(output_dir, paste0(prefix, station_code, year,
                                            sprintf("%02d", month), ".dat"))
  now <- Sys.Date()
  if (year > as.numeric(format(now, "%Y")) ||
      (year == as.numeric(format(now, "%Y")) && month > as.numeric(format(now, "%m"))))
    return(FALSE)
  if (file.exists(file_path) && file.size(file_path) > 0) return(TRUE)

  tryCatch({
    resp <- GET(url, timeout(120))
    if (status_code(resp) == 200) {
      writeBin(content(resp, "raw"), file_path)
      cat(sprintf("%s %s %d-%02d downloaded\n", station_code, data_type, year, month))
      TRUE
    } else {
      cat(sprintf("%s %s %d-%02d not available (HTTP %d)\n",
                  station_code, data_type, year, month, status_code(resp)))
      FALSE
    }
  }, error = function(e) {
    cat(sprintf("%s %s %d-%02d download error: %s\n",
                station_code, data_type, year, month, e$message))
    FALSE
  })
}

# ----------------------------- AERSURFACE handoff ------------------------------------

# Copy the current AERSURFACE surface-characteristics file from the AERSURFACE
# pipeline output tree into the station folder; returns the filename for AERSURF.
fetch_aersurface_file <- function(station_code, root_directory, start_year, end_year) {
  id <- tolower(station_code)
  src <- file.path(dirname(root_directory), "AERSURFACE", "stations", id,
                   sprintf("met_%d-%d", start_year, end_year),
                   sprintf("%s_2021_aers_sfc.txt", id))
  dest_name <- basename(src)
  dest <- file.path(root_directory, station_code, dest_name)
  if (file.exists(src)) {
    file.copy(src, dest, overwrite = TRUE)
    cat(sprintf("AERSURFACE file copied from pipeline: %s\n", dest_name))
  } else if (!file.exists(dest)) {
    stop(sprintf("AERSURFACE file not found:\n  %s\nRun the AERSURFACE pipeline first.", src))
  }
  dest_name
}

# ------------------------------ AERMINUTE (1-min winds) ------------------------------

create_aerminute_input <- function(station_code, start_year, end_year,
                                   base_directory, ghcnh_file) {
  station_prefix <- sub("^K", "", station_code)
  output_inp <- file.path(base_directory, sprintf("%s_AERMINUTE.INP", station_prefix))

  valid <- list(onemin = character(0), fivemin = character(0))
  now <- Sys.Date()
  cur_y <- as.numeric(format(now, "%Y")); cur_m <- as.numeric(format(now, "%m"))

  for (year in start_year:end_year) {
    for (month in 1:12) {
      if (year > cur_y || (year == cur_y && month > cur_m)) next
      ok1 <- download_asos(station_code, year, month, "1min", file.path(base_directory, "1min"))
      ok5 <- download_asos(station_code, year, month, "5min", file.path(base_directory, "5min"))
      if (ok1 && ok5) {
        p1 <- file.path(base_directory, "1min",
                        sprintf("64050%s%d%02d.dat", station_code, year, month))
        p5 <- file.path(base_directory, "5min",
                        sprintf("64010%s%d%02d.dat", station_code, year, month))
        if (file.size(p1) > 0 && file.size(p5) > 0) {
          # quoted relative paths: list-directed Fortran reads stop at unquoted '/'
          valid$onemin  <- c(valid$onemin,
                             sprintf('"%s"', np(file.path("1min", basename(p1)))))
          valid$fivemin <- c(valid$fivemin,
                             sprintf('"%s"', np(file.path("5min", basename(p5)))))
        }
      }
    }
  }
  if (length(valid$onemin) == 0) stop("No valid AERMINUTE data files found")

  last <- basename(valid$onemin[length(valid$onemin)])
  dt <- regmatches(last, regexpr("\\d{6}", last))
  last_y <- as.numeric(substr(dt, 1, 4)); last_m <- as.numeric(substr(dt, 5, 6))

  inp <- c(
    sprintf("startend 01 %d %02d %d", start_year, last_m, last_y),
    "ifwgroup y 03 26 2007",
    "",
    "DATAFILE STARTING", valid$onemin, "DATAFILE FINISHED",
    "",
    "DAT5FILE STARTING", valid$fivemin, "DAT5FILE FINISHED",
    "",
    "SURFDATA STARTING", sprintf('"%s"', basename(ghcnh_file)), "SURFDATA FINISHED",
    "",
    "OUTFILES STARTING",
    'HOURFILE "AERMINUTE_hour.dat"',
    'SUMMFILE "AERMINUTE_sum.dat"',
    'COMPFILE "AERMINUTE_comp.dat"',
    '1_5_FILE "AERMINUTE_1_5.dat"',
    'SUB5FILE "AERMINUTE_sub5.dat"',
    "OUTFILES FINISHED")
  writeLines(inp, output_inp)
  cat(sprintf("AERMINUTE input: %s (%d months, %d-01 to %d-%02d)\n",
              basename(output_inp), length(valid$onemin), start_year, last_y, last_m))
  output_inp
}

run_aerminute <- function(station_paths, root_directory) {
  if (!station_paths$has_aerminute) {
    cat("Skipping AERMINUTE (no 1-minute data for this station)\n")
    return(invisible(NULL))
  }
  exe <- find_exe("aerminute", station_paths$station_dir, root_directory)
  inp <- basename(station_paths$aerminute_input)
  hour_file <- file.path(station_paths$station_dir, "AERMINUTE_hour.dat")
  run_started <- Sys.time()
  cat(sprintf("Running AERMINUTE (%s)\n", basename(exe)))
  run_program(exe, station_paths$station_dir, stdin_lines = inp)
  # a pre-existing hour file from an old run must NOT satisfy this check
  if (!file.exists(hour_file) || file.size(hour_file) == 0 ||
      file.info(hour_file)$mtime < run_started)
    stop("AERMINUTE did not produce a fresh AERMINUTE_hour.dat (stale or missing)")
  pad_aerminute_wban(hour_file)
  cat("AERMINUTE processing complete\n")
}

# AERMINUTE writes the WBAN space-padded in the hour-file header ("WBAN:  3940"),
# but AERMET's LOCATION keyword carries it zero-padded ("03940"). AERMET compares
# the two as strings, so for any station whose WBAN has a leading zero it emits
#
#   W40  READ_1MIN  AERMINUTE WBAN 3940 DOES NOT MATCH SURFACE WBAN 03940
#   W56  READ_1MIN  DO NOT PROCESS 1-MINUTE DATA
#
# and silently discards the ENTIRE 1-minute wind record -- a warning, not an error,
# so the run still "succeeds". The effect is large: KJAN 2021 went from 0 to 8784
# 1-minute hours and from 1888 to 106 calm hours once the header was padded.
# Zero-pad it to 5 digits, preserving the column width AERMET expects.
pad_aerminute_wban <- function(hour_file) {
  ln <- readLines(hour_file, warn = FALSE)
  if (!length(ln)) return(invisible(FALSE))
  m <- regmatches(ln[1], regexec("WBAN:( *)([0-9]+)", ln[1]))[[1]]
  if (length(m) < 3) return(invisible(FALSE))
  if (nchar(m[3]) >= 5) return(invisible(FALSE))          # already 5 digits
  ln[1] <- sub("WBAN:( *)([0-9]+)", sprintf("WBAN: %05d", as.integer(m[3])), ln[1])
  writeLines(ln, hour_file)
  cat(sprintf("  padded AERMINUTE WBAN %s -> %05d so AERMET accepts the 1-minute data\n",
              m[3], as.integer(m[3])))
  invisible(TRUE)
}

# ------------------------------- AERMET Stage 1 --------------------------------------

create_aermet_input <- function(station_code, start_year, end_year, root_directory,
                                ua_file_path, station_id, ua_station_id, ghcnh_file,
                                cache_dir = NULL) {
  info <- get_station_info(station_code, station_id, ua_station_id, cache_dir)
  ua_icao <- get_icao_from_igra(ua_station_id, cache_dir)
  output_inp <- file.path(root_directory, station_code, sprintf("%s.IN1", station_code))
  start_date <- sprintf("%d/01/01", start_year)
  end_date   <- sprintf("%d/01/01", end_year + 1)

  content <- c(
    "********************************************************",
    "** AERMET - STAGE 1 Input",
    sprintf("** AERMET VERSION: %s (GHCNh surface data)", AERMET_VERSION),
    "** Mississippi DEQ Air Quality Modeling",
    sprintf("** Date: %s", format(Sys.Date(), "%Y/%m/%d")),
    "********************************************************",
    "JOB",
    sprintf("   REPORT      %s.RP1", station_code),
    sprintf("   MESSAGES    %s.MG1", station_code),
    "UPPERAIR",
    sprintf("   DATA        %s IGRA", basename(ua_file_path)),
    sprintf("   EXTRACT     %s.UAX", ua_icao),
    "   AUDIT       ALL",
    "   MODIFY      ALL",
    sprintf("   QAOUT       %s.UQA", ua_icao),
    sprintf("   XDATES      %s TO %s", start_date, end_date),
    sprintf("** Station: %s", info$upper_air$ua_name),
    sprintf("   LOCATION    %s", info$upper_air$location_string),
    "SURFACE",
    "** Surface data: GHCNh (NCEI), replaces discontinued ISHD",
    sprintf("   DATA        %s GHCN", basename(ghcnh_file)),
    sprintf("   EXTRACT     %s.SAX", station_code),
    "   AUDIT       ALL",
    sprintf("   QAOUT       %s.SQA", station_code),
    sprintf("   XDATES      %s TO %s", start_date, end_date),
    sprintf("** Station: %s", info$surface$station_name),
    sprintf("   LOCATION    %s", info$surface$location_string))
  writeLines(content, output_inp)
  cat(sprintf("AERMET Stage 1 input: %s\n", basename(output_inp)))
  output_inp
}

aermet_run_succeeded <- function(report_file) {
  file.exists(report_file) &&
    any(grepl("AERMET FINISHED SUCCESSFULLY",
              readLines(report_file, warn = FALSE), fixed = TRUE))
}

run_aermet_stage1 <- function(station_paths, root_directory) {
  station_dir <- station_paths$station_dir
  station_code <- basename(station_dir)
  exe <- find_exe("aermet", station_dir, root_directory)
  file.copy(station_paths$aermet_input,
            file.path(station_dir, "AERMET.INP"), overwrite = TRUE)
  run_started <- Sys.time()
  cat(sprintf("Running AERMET Stage 1 (%s)\n", basename(exe)))
  run_program(exe, station_dir)
  rp1 <- file.path(station_dir, sprintf("%s.RP1", station_code))
  sqa <- file.path(station_dir, sprintf("%s.SQA", station_code))
  # stale QAOUT from an earlier run must NOT satisfy this check
  if (!aermet_run_succeeded(rp1))
    stop(sprintf("AERMET Stage 1 FINISHED UN-SUCCESSFULLY -- see %s.MG1", station_code))
  if (!file.exists(sqa) || file.size(sqa) == 0 || file.info(sqa)$mtime < run_started)
    stop("AERMET Stage 1 did not produce a fresh surface QAOUT (.SQA) file")
  cat("AERMET Stage 1 complete\n")
}

# ------------------------------- AERMET Stage 2 --------------------------------------

create_stage2_content <- function(year, use_ustar, aersurf_file, station_code,
                                  ua_station, has_aerminute, root_directory) {
  suffix <- if (use_ustar) "US" else ""
  content <- c(
    "JOB",
    sprintf("   REPORT      %s%d%s.RP2", station_code, year, suffix),
    sprintf("   MESSAGES    %s%d%s.MG2", station_code, year, suffix),
    "UPPERAIR",
    sprintf("   QAOUT       %s.UQA", ua_station),
    "SURFACE",
    sprintf("   QAOUT       %s.SQA", station_code))
  if (has_aerminute) {
    content <- c(content,
                 "** Hourly averaged 1-minute ASOS winds (AERMINUTE)",
                 "   ASOS1MIN    AERMINUTE_hour.dat")
  }
  content <- c(content,
    "METPREP",
    "   MODEL       AERMOD",
    sprintf("   OUTPUT      %s%d%s.sfc", station_code, year, suffix),
    sprintf("   PROFILE     %s%d%s.pfl", station_code, year, suffix),
    sprintf("   XDATES      %d/01/01 TO %d/01/01", year, year + 1),
    "   METHOD      REFLEVEL  SUBNWS",
    "   METHOD      WIND_DIR  RANDOM")
  if (use_ustar) content <- c(content, "   METHOD      STABLEBL  ADJ_U*")
  c(content,
    "   METHOD      CCVR SUB_CC",
    "   METHOD      TEMP SUB_TT",
    "   THRESH_1MIN 0.50",
    "   NWS_HGT     WIND 10.00",
    "** Primary Surface Characteristics (AERSURFACE 26135)",
    sprintf("   AERSURF   %s", aersurf_file))
}

create_and_run_aermet_stage2 <- function(station_paths, start_year, end_year,
                                         aersurf_file, ua_station, root_directory) {
  station_dir <- station_paths$station_dir
  station_code <- basename(station_dir)
  exe <- find_exe("aermet", station_dir, root_directory)

  for (year in start_year:end_year) {
    for (use_ustar in c(FALSE, TRUE)) {
      lbl <- if (use_ustar) "ADJ_U*" else "regular"
      cat(sprintf("AERMET Stage 2: %s %d (%s)\n", station_code, year, lbl))
      content <- create_stage2_content(year, use_ustar, aersurf_file, station_code,
                                       ua_station, station_paths$has_aerminute,
                                       root_directory)
      in2 <- file.path(station_dir, sprintf("%s%d%s.IN2", station_code, year,
                                            if (use_ustar) "US" else ""))
      writeLines(content, in2)
      file.copy(in2, file.path(station_dir, "AERMET.INP"), overwrite = TRUE)
      run_program(exe, station_dir)
      rp2 <- file.path(station_dir, sprintf("%s%d%s.RP2", station_code, year,
                                            if (use_ustar) "US" else ""))
      if (!aermet_run_succeeded(rp2))
        stop(sprintf("AERMET Stage 2 FINISHED UN-SUCCESSFULLY for %s %d (%s) -- see %s",
                     station_code, year, lbl, basename(rp2)))
    }
    for (f in c(sprintf("%s%d.sfc", station_code, year),
                sprintf("%s%d.pfl", station_code, year),
                sprintf("%s%dUS.sfc", station_code, year),
                sprintf("%s%dUS.pfl", station_code, year))) {
      fp <- file.path(station_dir, f)
      if (!file.exists(fp) || file.size(fp) == 0)
        stop(sprintf("Stage 2 output missing or empty: %s", f))
      cat(sprintf("  created: %s\n", f))
    }
  }
  cat("AERMET Stage 2 complete for all years\n")
}

# -------------------------------- verification ---------------------------------------

verify_software_versions <- function(station_dir, start_year, end_year) {
  versions <- list()
  sfc_pattern <- paste0(basename(station_dir),
                        sprintf("%d\\.sfc$", start_year:end_year), collapse = "|")
  sfc_files <- list.files(station_dir, pattern = sfc_pattern, full.names = TRUE)
  if (length(sfc_files) > 0) {
    content <- readLines(sfc_files[1], n = 1)
    m <- regexec("VERSION:\\s*(\\d+)", content)
    if (m[[1]][1] > 0) versions$aermet <- regmatches(content, m)[[1]][2]
  }
  versions
}

verify_file_dates <- function(file_path, expected_year) {
  if (!file.exists(file_path)) return(list(exists = FALSE, message = "File not found"))
  content <- readLines(file_path, n = 10)
  data_lines <- grep("^\\s*\\d{2,4}\\s+\\d{1,2}\\s+\\d{1,2}", content, value = TRUE)
  if (length(data_lines) == 0)
    return(list(exists = TRUE, valid_dates = FALSE, message = "No data lines found"))
  first_year <- suppressWarnings(as.numeric(strsplit(trimws(data_lines[1]), "\\s+")[[1]][1]))
  ok <- year_matches(first_year, expected_year)
  list(exists = TRUE, valid_dates = ok, found_year = first_year,
       message = if (ok) "Valid"
                 else sprintf("Year mismatch: expected %d, found %s",
                              expected_year, fmt_int(first_year)))
}

verify_data_completeness <- function(station_dir, station_code, start_year, end_year) {
  results <- list()
  quarters <- list(Q1 = 1:3, Q2 = 4:6, Q3 = 7:9, Q4 = 10:12)

  for (year in start_year:end_year) {
    sfc_file <- file.path(station_dir, sprintf("%s%d.sfc", station_code, year))
    if (!file.exists(sfc_file)) {
      results[[as.character(year)]] <- list(error = "SFC file not found"); next
    }
    lines <- readLines(sfc_file, warn = FALSE)
    data_lines <- lines[grep("^\\s*\\d{2,4}\\s+\\d{1,2}\\s+\\d{1,2}", lines)]
    if (length(data_lines) == 0) {
      results[[as.character(year)]] <- list(error = "No valid data lines"); next
    }
    yr_res <- list(quarters = list())
    parsed <- lapply(data_lines, function(l) {
      f <- strsplit(trimws(l), "\\s+")[[1]]
      if (length(f) < 19) return(NULL)
      list(yr = suppressWarnings(as.numeric(f[1])),
           month = suppressWarnings(as.numeric(f[2])),
           wspd = suppressWarnings(as.numeric(f[16])),
           wdir = suppressWarnings(as.numeric(f[17])),
           temp = suppressWarnings(as.numeric(f[19])))
    })
    parsed <- parsed[!sapply(parsed, is.null)]
    for (q in names(quarters)) {
      qm <- quarters[[q]]
      tot <- 0; miss <- 0; calm <- 0
      for (p in parsed) {
        if (!year_matches(p$yr, year) || is.na(p$month) || !(p$month %in% qm)) next
        tot <- tot + 1
        if (!is.na(p$wspd) && p$wspd <= 0.5) calm <- calm + 1
        if (is.na(p$wspd) || is.na(p$wdir) || is.na(p$temp) ||
            p$wspd %in% c(999, 9999) || p$wdir %in% c(999, 9999) ||
            p$temp %in% c(999, 9999) || p$wspd < 0 || p$wdir < 0 || p$wdir > 360)
          miss <- miss + 1
      }
      if (tot > 0) {
        pct <- (tot - miss) / tot * 100
        yr_res$quarters[[q]] <- list(expected_hours = tot, missing_hours = miss,
                                     calm_hours = calm,
                                     completeness_pct = round(pct, 1),
                                     meets_epa = pct >= 90)
      } else {
        yr_res$quarters[[q]] <- list(error = "No hours found",
                                     completeness_pct = 0, meets_epa = FALSE)
      }
    }
    qs <- yr_res$quarters
    tot_a  <- sum(sapply(qs, function(x) if (!is.null(x$expected_hours)) x$expected_hours else 0))
    miss_a <- sum(sapply(qs, function(x) if (!is.null(x$missing_hours)) x$missing_hours else 0))
    calm_a <- sum(sapply(qs, function(x) if (!is.null(x$calm_hours)) x$calm_hours else 0))
    if (tot_a > 0) {
      pct_a <- (tot_a - miss_a) / tot_a * 100
      yr_res$annual <- list(total_hours = tot_a, missing_hours = miss_a,
                            calm_hours = calm_a, completeness_pct = round(pct_a, 1),
                            meets_epa = pct_a >= 90)
    }
    results[[as.character(year)]] <- yr_res
  }
  results
}

parse_rp2_file <- function(rp2_file) {
  if (!file.exists(rp2_file)) return(NULL)
  content <- readLines(rp2_file, warn = FALSE)
  stats <- list()
  # First integer that FOLLOWS the label. This used to anchor on the end of the
  # line ("\\D*(\\d+)\\s*$"), which silently returned NA whenever AERMET puts a
  # word after the number -- e.g. "ERROR MESSAGES        0 MESSAGES" -- so the
  # verification report printed "Errors: NA | Warnings: NA".
  num_after <- function(pattern, lines) {
    hit <- grep(pattern, lines, value = TRUE)
    if (length(hit) == 0) return(NA)
    m <- regmatches(hit[1], regexec(paste0(pattern, "\\D*?(\\d+)"), hit[1]))[[1]]
    if (length(m) >= 2) suppressWarnings(as.numeric(m[2])) else NA
  }
  obs_start <- grep("TOTAL OBSERVATION COUNTS", content)
  if (length(obs_start) > 0) {
    obs <- content[(obs_start + 1):min(obs_start + 6, length(content))]
    stats$ua_obs      <- num_after("NWS UPPER AIR\\s+OBS", obs)
    stats$surface_obs <- num_after("NWS SURFACE\\s+OBS", obs)
    stats$asos_obs    <- num_after("1-MIN ASOS HR\\s+OBS", obs)
  }
  pbl_start <- grep("PBL PROCESSING SUMMARY", content)
  if (length(pbl_start) > 0) {
    # 25 lines, not 12: the TEMPERATURE substitution count sits on line 13 of this
    # block, so a 12-line window always returned NA for temp_subs.
    pbl <- content[(pbl_start + 1):min(pbl_start + 25, length(content))]
    stats$no_convective_days <- num_after("NO CONVECTIVE CONDITIONS:", pbl)
    stats$total_calms        <- num_after("NUMBER OF TOTAL CALMS:", pbl)
    stats$variable_winds     <- num_after("NUMBER OF VARIABLE WINDS:", pbl)
    stats$cloud_cover_subs   <- num_after("SUBSTITUTIONS.*CLOUD COVER:", pbl)
    stats$temp_subs          <- num_after("SUBSTITUTIONS.*TEMPERATURE:", pbl)
  }
  msg_start <- grep("MESSAGE SUMMARY", content)
  if (length(msg_start) > 0) {
    msg <- content[(msg_start + 1):length(content)]
    stats$error_count   <- num_after("ERROR MESSAGES", msg)
    stats$warning_count <- num_after("WARNING MESSAGES", msg)
  }
  stats
}

# ------------------------- verification report helpers --------------------------------

# Parse an AERSURFACE .txt: the commented header carries every run setting a reviewer
# asks about, and the SITE_CHAR rows are the monthly x sector surface characteristics
# that AERMET actually applied.
parse_aersurface_file <- function(path) {
  if (!file.exists(path)) return(NULL)
  ln <- readLines(path, warn = FALSE)
  # Header keys contain regex metacharacters ("Zo Radius (m)"), so match them
  # literally and take what follows, then strip the trailing ** that closes each
  # AERSURFACE header comment.
  hv <- function(key, default = NA_character_) {
    h <- grep(key, ln, fixed = TRUE, value = TRUE)
    if (!length(h)) return(default)
    p <- regexpr(key, h[1], fixed = TRUE)
    v <- substring(h[1], p + attr(p, "match.length"))
    trimws(sub("\\*+\\s*$", "", sub("^\\s*:?\\s*", "", v)))
  }
  sec <- grep("^\\s*SECTOR\\s", ln, value = TRUE)
  sectors <- if (length(sec)) {
    p <- do.call(rbind, lapply(strsplit(trimws(sec), "\\s+"), function(v)
      data.frame(id = as.integer(v[2]), start = as.numeric(v[3]),
                 end = as.numeric(v[4]), stringsAsFactors = FALSE)))
    p
  } else NULL
  sc <- grep("^\\s*SITE_CHAR\\s", ln, value = TRUE)
  tab <- if (length(sc)) {
    do.call(rbind, lapply(strsplit(trimws(sc), "\\s+"), function(v)
      data.frame(month = as.integer(v[2]), sector = as.integer(v[3]),
                 albedo = as.numeric(v[4]), bowen = as.numeric(v[5]),
                 z0 = as.numeric(v[6]), stringsAsFactors = FALSE)))
  } else NULL
  list(
    version   = sub("\\s.*$", "", hv("Generated by AERSURFACE, Version", "")),
    lat       = suppressWarnings(as.numeric(hv("Center Latitude  (decimal degrees)"))),
    lon       = suppressWarnings(as.numeric(hv("Center Longitude (decimal degrees)"))),
    datum     = hv("Datum"),
    nlcd      = hv("NLCD Version"),
    zo_method = hv("Zo Method"),
    zo_radius = hv("Zo Radius (m)"),
    snow      = hv("Continuous snow cover"),
    moisture  = hv("Surface moisture"),
    highz0    = hv("High Z0 (Non-Airport) Sector IDs"),
    sectors   = sectors, table = tab)
}

# great-circle distance and compass bearing, for the surface-to-upper-air separation
# that representativeness reviews always ask for
gc_km <- function(lat1, lon1, lat2, lon2) {
  r <- pi / 180
  6371 * acos(pmin(1, sin(lat1*r)*sin(lat2*r) +
                      cos(lat1*r)*cos(lat2*r)*cos((lon2-lon1)*r)))
}
gc_dir <- function(lat1, lon1, lat2, lon2) {
  r <- pi / 180
  y <- sin((lon2-lon1)*r) * cos(lat2*r)
  x <- cos(lat1*r)*sin(lat2*r) - sin(lat1*r)*cos(lat2*r)*cos((lon2-lon1)*r)
  b <- (atan2(y, x) / r + 360) %% 360
  c("N","NNE","NE","ENE","E","ESE","SE","SSE","S","SSW","SW","WSW",
    "W","WNW","NW","NNW")[floor(((b + 11.25) %% 360) / 22.5) + 1]
}

# AERMOD reference heights are written into every .sfc row (cols 18 and 20) but have
# never been stated anywhere in the deliverable
sfc_ref_heights <- function(sfc_file) {
  if (!file.exists(sfc_file)) return(list(wind = NA_real_, temp = NA_real_))
  ln <- readLines(sfc_file, n = 3, warn = FALSE)
  if (length(ln) < 2) return(list(wind = NA_real_, temp = NA_real_))
  f <- strsplit(trimws(ln[2]), "\\s+")[[1]]
  list(wind = suppressWarnings(as.numeric(f[18])),
       temp = suppressWarnings(as.numeric(f[20])))
}

# Physical-plausibility screen of the DELIVERED files.  This is the check that would
# have caught the suspect GHCNh winds on its own, so it is reported per year whether
# or not anything is found.
screen_sfc_extremes <- function(station_dir, station_code, years) {
  out <- list()
  for (y in years) {
    d <- read_sfc_data(station_dir, station_code, y)
    if (is.null(d) || !nrow(d)) next
    d <- d[!is.na(d$year) & year_matches(d$year, y), , drop = FALSE]
    ws <- d$ws[!is.na(d$ws)]; tc <- d$temp[!is.na(d$temp)] - 273.15
    out[[as.character(y)]] <- list(
      ws_max = if (length(ws)) max(ws) else NA_real_,
      t_min  = if (length(tc)) min(tc) else NA_real_,
      t_max  = if (length(tc)) max(tc) else NA_real_,
      n_ws_hi = sum(ws > 25), n_t_out = sum(tc > 45 | tc < -25))
  }
  out
}

# Condense the GHCNh QC filter log for the reader
qc_log_summary <- function(station_dir, station_code) {
  f <- file.path(station_dir, sprintf("%s_GHCNh_2021_2025_qc_log.txt", station_code))
  if (!file.exists(f)) {
    g <- list.files(station_dir, pattern = "_qc_log\\.txt$", full.names = TRUE)
    if (!length(g)) return(NULL)
    f <- g[1]
  }
  ln <- readLines(f, warn = FALSE)
  gi <- function(p) {
    h <- grep(p, ln, value = TRUE)
    if (!length(h)) return(NA_integer_)
    suppressWarnings(as.integer(sub("^\\D*?(\\d+).*$", "\\1", sub(p, "", h[1]))))
  }
  list(records = gi("Records scanned\\s*:"),
       flagged = gi("Screen 1 \\(NCEI flags\\)\\s*:"),
       metar   = gi("Screen 2 \\(METAR check\\)\\s*:"),
       file    = basename(f))
}

generate_verification_report <- function(results, station_code, start_year, end_year) {
  station_dir <- results$station_dir
  report_file <- file.path(station_dir, sprintf("%s_verification_report.txt", station_code))
  years <- start_year:end_year
  W <- 78
  rule <- function(ch = "=") paste(rep(ch, W), collapse = "")

  # ---- gather ----
  reg <- STATION_REGISTRY[STATION_REGISTRY$code == station_code, ]
  sid <- if (nrow(reg)) reg$station_id[1] else NA_character_
  uid <- if (nrow(reg)) reg$ua_station_id[1] else NA_character_
  cache_dir <- file.path(dirname(station_dir), "cache")
  meta <- tryCatch({
    isd <- get_isd_history(cache_dir); igr <- get_igra_info(cache_dir)
    s <- isd[isd$station_id == sid, ][1, ]
    if (is.na(s$usaf)) s <- isd[!is.na(isd$icao) & isd$icao == station_code, ][1, ]
    u <- igr[igr$igra_id == uid, ][1, ]
    list(s = s, u = u)
  }, error = function(e) NULL)

  aers <- parse_aersurface_file(file.path(station_dir,
            sprintf("%s_2021_aers_sfc.txt", tolower(station_code))))
  refh <- sfc_ref_heights(file.path(station_dir, sprintf("%s%d.sfc", station_code, start_year)))
  ext  <- screen_sfc_extremes(station_dir, station_code, years)
  qcs  <- qc_log_summary(station_dir, station_code)
  rp   <- lapply(setNames(years, years), function(y)
            parse_rp2_file(file.path(station_dir, sprintf("%s%d.RP2", station_code, y))))

  # ---- overall verdict ----
  q_fail <- 0L; q_tot <- 0L
  for (y in names(results$data_completeness)) {
    yd <- results$data_completeness[[y]]
    if (!is.null(yd$error)) next
    for (q in names(yd$quarters)) {
      qd <- yd$quarters[[q]]
      if (is.null(qd$completeness_pct)) next
      q_tot <- q_tot + 1L
      if (!isTRUE(qd$meets_epa)) q_fail <- q_fail + 1L
    }
  }
  n_err <- sum(vapply(rp, function(s)
    if (is.null(s) || is.null(s$error_count) || is.na(s$error_count)) 0L
    else as.integer(s$error_count), integer(1)))
  n_phys <- sum(vapply(ext, function(e) as.integer(e$n_ws_hi + e$n_t_out), integer(1)))
  verdict <- if (q_fail == 0 && n_err == 0 && n_phys == 0) "PASS" else
             if (q_fail > 0 || n_err > 0) "FAIL" else "PASS WITH NOTES"

  nm <- if (!is.null(meta) && !is.na(meta$s$station_name)) meta$s$station_name else station_code
  rc <- c(rule(), sprintf("AERMET PROCESSING VERIFICATION REPORT -- %s (%s)", station_code, nm),
          sprintf("Period %d-%d   |   Generated %s", start_year, end_year,
                  format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
          rule(), "",
          sprintf("OVERALL RESULT: %s", verdict),
          sprintf("   Quarters meeting the EPA 90%% criterion : %d of %d", q_tot - q_fail, q_tot),
          sprintf("   AERMET processing errors               : %d", n_err),
          sprintf("   Non-physical values in delivered .sfc   : %d", n_phys), "")

  # ---- 1. station ----
  rc <- c(rc, rule("-"), "1. STATION", rule("-"))
  if (!is.null(meta) && !is.na(meta$s$usaf)) {
    s <- meta$s
    rc <- c(rc,
      sprintf("   Surface station      %s  %s%s", station_code, s$station_name,
              if (!is.na(s$state) && nzchar(s$state)) paste0(", ", s$state) else ""),
      sprintf("   ICAO / WBAN / USAF   %s / %s / %s", station_code, s$wban, s$usaf),
      sprintf("   GHCNh station ID     USW000%s", s$wban),
      sprintf("   Latitude, longitude  %.4f N, %.4f W", s$lat, abs(s$lon)),
      sprintf("   Elevation            %.1f m MSL", s$elev_m))
  }
  rc <- c(rc,
    sprintf("   Wind reference ht    %.1f m   (AERMOD .sfc column 18)",  refh$wind),
    sprintf("   Temp reference ht    %.1f m   (AERMOD .sfc column 20)",  refh$temp))
  if (!is.null(meta) && !is.na(meta$u$igra_id)) {
    u <- meta$u
    rc <- c(rc, "",
      sprintf("   Upper air station    %s  %s", u$igra_id, trimws(u$station_name)),
      sprintf("   Latitude, longitude  %.4f N, %.4f W", u$lat, abs(u$lon)),
      sprintf("   Elevation            %.1f m MSL", u$elev_m))
    if (!is.null(meta$s) && !is.na(meta$s$lat))
      rc <- c(rc, sprintf("   Separation           %.0f km %s of %s",
              gc_km(meta$s$lat, meta$s$lon, u$lat, u$lon),
              gc_dir(meta$s$lat, meta$s$lon, u$lat, u$lon), station_code))
  }
  rc <- c(rc, "")

  # ---- 2. software and inputs ----
  rc <- c(rc, rule("-"), "2. SOFTWARE AND INPUT DATA", rule("-"),
    sprintf("   AERMET               %s", if (!is.null(results$versions$aermet))
              results$versions$aermet else AERMET_VERSION),
    sprintf("   AERMINUTE            %s", AERMET_VERSION),
    sprintf("   AERSURFACE           %s", if (!is.null(aers) && !is.na(aers$version))
              aers$version else "26135"),
    "   Surface data         NCEI GHCNh hourly (replaces the discontinued ISHD)",
    "   1-minute winds       NCEI ASOS 1-minute and 5-minute, hourly-averaged by",
    "                        AERMINUTE and merged by AERMET",
    "   Upper air            NCEI IGRA v2 radiosonde soundings", "")

  # ---- 3. surface characteristics ----
  rc <- c(rc, rule("-"), "3. SURFACE CHARACTERISTICS (AERSURFACE)", rule("-"))
  if (!is.null(aers)) {
    ns <- if (!is.null(aers$sectors)) nrow(aers$sectors) else NA
    rc <- c(rc,
      sprintf("   Land cover           NLCD %s (with impervious and canopy)", aers$nlcd),
      sprintf("   Roughness method     %s, %s m radius, monthly resolution",
              aers$zo_method, trimws(aers$zo_radius)),
      sprintf("   Site coordinates     %.6f, %.6f  (%s)", aers$lat, aers$lon, aers$datum),
      sprintf("   Surface moisture     %s", aers$moisture),
      sprintf("   Continuous snow      %s", aers$snow),
      sprintf("   Non-airport sectors  %s", aers$highz0),
      sprintf("   Sectors              %s", if (is.na(ns)) "n/a" else ns))
    if (!is.null(aers$sectors))
      for (i in seq_len(nrow(aers$sectors)))
        rc <- c(rc, sprintf("      sector %d: %5.1f to %6.1f degrees",
                aers$sectors$id[i], aers$sectors$start[i], aers$sectors$end[i]))
    if (!is.null(aers$table)) {
      rc <- c(rc, "", "   Monthly surface characteristics applied by AERMET:", "",
              "      Month  Sector   Albedo   Bowen ratio   Roughness z0 (m)",
              "      -----  ------   ------   -----------   ----------------")
      t <- aers$table[order(aers$table$sector, aers$table$month), ]
      rc <- c(rc, sprintf("      %5d  %6d   %6.2f   %11.2f   %16.3f",
                          t$month, t$sector, t$albedo, t$bowen, t$z0))
    }
  } else rc <- c(rc, "   AERSURFACE file not found in the station folder.")
  rc <- c(rc, "")

  # ---- 4. GHCNh quality control ----
  rc <- c(rc, rule("-"), "4. SURFACE DATA QUALITY CONTROL", rule("-"))
  if (!is.null(qcs)) {
    rc <- c(rc,
      "   NCEI flags each observation with a quality code that AERMET does not act",
      "   on, so the GHCNh file is screened before processing.  Rejected values are",
      "   blanked (treated as missing); no record is dropped and no value is altered.",
      "",
      sprintf("   Observations screened            %s", fmt_int(qcs$records)),
      sprintf("   Rejected, NCEI suspect/erroneous %s", fmt_int(qcs$flagged)),
      sprintf("   Rejected, METAR cross-check      %s", fmt_int(qcs$metar)),
      sprintf("   Full detail                      %s", qcs$file))
  } else {
    rc <- c(rc, "   No quality-control log found for this station.")
  }
  rc <- c(rc, "")

  # ---- 5. annual processing statistics ----
  rc <- c(rc, rule("-"), "5. ANNUAL PROCESSING STATISTICS (from AERMET .RP2)", rule("-"))
  for (y in years) {
    st <- rp[[as.character(y)]]
    if (is.null(st)) { rc <- c(rc, sprintf("   %d: RP2 not found", y)); next }
    rc <- c(rc, sprintf("   Year %d", y),
      sprintf("      Upper air soundings %s | Surface obs %s | 1-min ASOS hrs %s",
              fmt_int(st$ua_obs), fmt_int(st$surface_obs), fmt_int(st$asos_obs)),
      sprintf("      Calms %s | Variable winds %s | Cloud subs %s | Temp subs %s",
              fmt_int(st$total_calms), fmt_int(st$variable_winds),
              fmt_int(st$cloud_cover_subs), fmt_int(st$temp_subs)),
      sprintf("      Errors %s | Warnings %s",
              fmt_int(st$error_count), fmt_int(st$warning_count)))
  }
  rc <- c(rc, "")

  # ---- 6. completeness ----
  rc <- c(rc, rule("-"), "6. DATA COMPLETENESS", rule("-"),
    "   EPA requires at least 90% valid data per calendar quarter.  The quarterly",
    "   columns are the compliance test; the annual column is informational.", "",
    "      Year       Q1       Q2       Q3       Q4     Annual   Result",
    "      ----   ------   ------   ------   ------   --------   ------")
  for (y in names(results$data_completeness)) {
    yd <- results$data_completeness[[y]]
    if (!is.null(yd$error)) { rc <- c(rc, sprintf("      %s   %s", y, yd$error)); next }
    qv <- vapply(c("Q1","Q2","Q3","Q4"), function(q) {
      qd <- yd$quarters[[q]]
      if (is.null(qd) || is.null(qd$completeness_pct)) NA_real_ else qd$completeness_pct
    }, numeric(1))
    ok <- all(!is.na(qv) & qv >= 90)
    rc <- c(rc, sprintf("      %s   %5.1f%%   %5.1f%%   %5.1f%%   %5.1f%%   %7.1f%%   %s",
      y, qv[1], qv[2], qv[3], qv[4],
      if (!is.null(yd$annual)) yd$annual$completeness_pct else NA_real_,
      if (ok) "PASS" else "FAIL"))
  }
  rc <- c(rc, "")

  # ---- 7. physical screening ----
  rc <- c(rc, rule("-"), "7. PHYSICAL PLAUSIBILITY OF THE DELIVERED FILES", rule("-"),
    "   Screening of the .sfc files as delivered.  Wind speeds above 25 m/s and",
    "   temperatures outside -25 to +45 C are reported for review; a non-zero count",
    "   does not by itself mean the data are wrong, but each should be explainable.", "",
    "      Year   Max wind   Min temp   Max temp   ws>25 m/s   T out of range",
    "      ----   --------   --------   --------   ---------   --------------")
  for (y in years) {
    e <- ext[[as.character(y)]]
    if (is.null(e)) next
    rc <- c(rc, sprintf("      %d   %6.1f m/s   %5.1f C   %5.1f C   %9d   %14d",
                        y, e$ws_max, e$t_min, e$t_max, e$n_ws_hi, e$n_t_out))
  }
  rc <- c(rc, "")

  # ---- 8. calms and missing data ----
  rc <- c(rc, rule("-"), "8. CALMS AND MISSING DATA", rule("-"),
    "   AERMOD excludes calm hours (wind speed below the 0.5 m/s threshold) and",
    "   missing hours from the averaging period, and reports both in its own output.",
    "   They are counted here so the modeller can anticipate them.", "",
    "      Year   Calm hrs   Missing hrs   Valid hrs",
    "      ----   --------   -----------   ---------")
  for (y in names(results$data_completeness)) {
    yd <- results$data_completeness[[y]]
    if (!is.null(yd$error) || is.null(yd$annual)) next
    a <- yd$annual
    rc <- c(rc, sprintf("      %s   %8d   %11d   %9d",
                        y, a$calm_hours, a$missing_hours, a$total_hours - a$missing_hours))
  }
  rc <- c(rc, "")

  # ---- 9. output files ----
  rc <- c(rc, rule("-"), "9. OUTPUT FILES", rule("-"),
    "   Files without the US suffix were processed WITHOUT the ADJ_U* option; files",
    "   with the US suffix were processed with METHOD STABLEBL ADJ_U*.  Use one set",
    "   or the other consistently -- do not mix them within a single AERMOD run.", "",
    "      File                    Size (MB)   Hours   MD5",
    "      --------------------   ---------   -----   --------------------------------")
  for (y in years) for (sx in c("", "US")) for (ex in c("sfc", "pfl")) {
    fn <- sprintf("%s%d%s.%s", station_code, y, sx, ex)
    f  <- file.path(station_dir, fn)
    if (!file.exists(f)) { rc <- c(rc, sprintf("      %-20s   MISSING", fn)); next }
    nh <- if (ex == "sfc") length(readLines(f, warn = FALSE)) - 1L else NA_integer_
    rc <- c(rc, sprintf("      %-20s   %9.2f   %5s   %s", fn, file.size(f)/1024^2,
                        if (is.na(nh)) "-" else nh,
                        unname(tools::md5sum(f))))
  }
  rc <- c(rc, "", rule(),
    sprintf("End of report -- %s %d-%d", station_code, start_year, end_year), rule())

  writeLines(rc, report_file)
  cat(sprintf("Verification report: %s\n", basename(report_file)))
  rc
}

verify_aermet_processing <- function(station_paths, start_year, end_year) {
  station_dir <- station_paths$station_dir
  station_code <- basename(station_dir)
  res <- list(station_dir = station_dir)
  res$versions <- verify_software_versions(station_dir, start_year, end_year)
  res$output_files <- lapply(setNames(start_year:end_year, start_year:end_year),
    function(y) list(
      sfc = verify_file_dates(file.path(station_dir, sprintf("%s%d.sfc", station_code, y)), y),
      pfl = verify_file_dates(file.path(station_dir, sprintf("%s%d.pfl", station_code, y)), y)))
  res$data_completeness <- verify_data_completeness(station_dir, station_code,
                                                    start_year, end_year)
  generate_verification_report(res, station_code, start_year, end_year)
  res
}

# ------------------------------ graphical met report ---------------------------------
# Comprehensive per-station PDF of the processed AERMET data for PSD modeling review:
# wind roses, wind/temperature climatology, mixing heights, stability, u* (incl.
# regular vs ADJ_U*), moisture, and data completeness.  Base R graphics only so the
# report generates identically on macOS and Windows.

# Read one or more years of .sfc output into a data.frame (AERMOD surface file
# layout: yr mo dy jdy hr H u* w* VPTG Zic Zim L z0 Bowen albedo ws wd zref T ...)
read_sfc_data <- function(station_dir, station_code, years, suffix = "") {
  out <- list()
  for (y in years) {
    f <- file.path(station_dir, sprintf("%s%d%s.sfc", station_code, y, suffix))
    if (!file.exists(f) || file.size(f) == 0) next
    d <- tryCatch(read.table(f, skip = 1, header = FALSE, fill = TRUE,
                             stringsAsFactors = FALSE),
                  error = function(e) NULL)
    if (is.null(d) || ncol(d) < 25) next
    num <- function(v) suppressWarnings(as.numeric(v))
    out[[as.character(y)]] <- data.frame(
      year = num(d$V1), month = num(d$V2), day = num(d$V3), hour = num(d$V5),
      H = num(d$V6), ustar = num(d$V7), wstar = num(d$V8),
      zic = num(d$V10), zim = num(d$V11), L = num(d$V12),
      z0 = num(d$V13), bowen = num(d$V14), albedo = num(d$V15),
      ws = num(d$V16), wd = num(d$V17), temp = num(d$V19),
      ipcode = num(d$V21), pamt = num(d$V22), rh = num(d$V23),
      pres = num(d$V24), ccvr = num(d$V25))
  }
  if (length(out) == 0) return(NULL)
  d <- do.call(rbind, out)
  # normalize 2-digit years from older AERMET versions
  d$year <- ifelse(!is.na(d$year) & d$year < 100, d$year + 2000, d$year)
  # AERMET is driven with XDATES <y>/01/01 TO <y+1>/01/01, so every yearly .sfc
  # ends with the 24 hours of 1 January of the FOLLOWING year (deliberate -- the
  # .sfc files themselves are left exactly as AERMET wrote them). Stacking the
  # yearly files therefore delivered 1 January twice for every year after the
  # first, which double-weighted that day in the report and pushed the reported
  # "valid hrs" above the number of hours in the year. Keep one row per hour.
  d <- d[!duplicated(d[, c("year", "month", "day", "hour")]), , drop = FALSE]
  # missing-value masks (AERMET indicators / physical bounds)
  d$ws  [is.na(d$ws)  | d$ws < 0 | d$ws >= 90]              <- NA
  d$wd  [is.na(d$wd)  | d$wd < 0 | d$wd > 360]              <- NA
  d$temp[is.na(d$temp) | d$temp < 200 | d$temp > 340]       <- NA
  d$ustar[is.na(d$ustar) | d$ustar <= 0 | d$ustar > 5]      <- NA
  d$H   [is.na(d$H)   | d$H < -500 | d$H > 900]             <- NA
  d$zic [is.na(d$zic) | d$zic <= 0 | d$zic > 8000]          <- NA
  d$zim [is.na(d$zim) | d$zim <= 0 | d$zim > 8000]          <- NA
  d$L   [is.na(d$L)   | abs(d$L) >= 8888]                   <- NA
  d$pamt[is.na(d$pamt) | d$pamt < 0 | d$pamt > 400]         <- NA
  d$rh  [is.na(d$rh)  | d$rh < 0 | d$rh > 100]              <- NA
  d$ccvr[is.na(d$ccvr) | d$ccvr < 0 | d$ccvr > 10]          <- NA
  d$z0  [is.na(d$z0)  | d$z0 <= 0 | d$z0 > 5]               <- NA
  d$bowen[is.na(d$bowen) | d$bowen < -10 | d$bowen > 10]    <- NA
  d$albedo[is.na(d$albedo) | d$albedo <= 0 | d$albedo > 1]  <- NA
  d$season <- c("Winter","Winter","Spring","Spring","Spring","Summer",
                "Summer","Summer","Fall","Fall","Fall","Winter")[d$month]
  d$calm <- !is.na(d$ws) & d$ws < 0.5
  d
}

# Stacked wind rose (16 sectors, wind blowing FROM), base graphics.
plot_wind_rose <- function(ws, wd, main = "", calm_pct = NA, show_legend = TRUE) {
  ok <- !is.na(ws) & !is.na(wd) & ws >= 0.5
  breaks <- c(0.5, 2, 4, 6, 8, Inf)
  labs <- c("0.5-2", "2-4", "4-6", "6-8", ">8")
  cols <- c("#4575b4", "#91bfdb", "#fee090", "#fc8d59", "#d73027")
  sec <- floor(((wd[ok] + 11.25) %% 360) / 22.5) + 1          # 1..16, N first
  spd <- cut(ws[ok], breaks, labels = FALSE, right = FALSE)
  tab <- matrix(0, 16, 5)
  for (i in seq_along(sec)) tab[sec[i], spd[i]] <- tab[sec[i], spd[i]] + 1
  tab <- 100 * tab / max(1, length(ws[!is.na(ws)]))            # % of all valid hours
  rmax <- max(rowSums(tab)) * 1.08
  plot(NA, xlim = c(-rmax, rmax), ylim = c(-rmax, rmax), asp = 1,
       axes = FALSE, xlab = "", ylab = "", main = main)
  for (rr in pretty(c(0, rmax), 4)[-1]) {
    th <- seq(0, 2 * pi, length.out = 121)
    lines(rr * sin(th), rr * cos(th), col = "grey85")
    text(rr * sin(3 * pi/4), rr * cos(3 * pi/4), sprintf("%.0f%%", rr),
         cex = 0.62, col = "grey45")
  }
  for (a in seq(0, 315, 45)) lines(c(0, rmax * sin(a * pi/180)),
                                   c(0, rmax * cos(a * pi/180)), col = "grey90")
  dirlab <- c("N","NE","E","SE","S","SW","W","NW")
  for (i in seq_along(dirlab)) {
    a <- (i - 1) * 45 * pi/180
    text(1.06 * rmax * sin(a), 1.06 * rmax * cos(a), dirlab[i], cex = 0.85, font = 2)
  }
  for (s in 1:16) {
    a0 <- ((s - 1) * 22.5 - 11.25 + 2) * pi/180
    a1 <- ((s - 1) * 22.5 + 11.25 - 2) * pi/180
    r0 <- 0
    for (k in 1:5) {
      r1 <- r0 + tab[s, k]
      if (tab[s, k] > 0) {
        th <- seq(a0, a1, length.out = 12)
        polygon(c(r0 * sin(th), rev(r1 * sin(th))),
                c(r0 * cos(th), rev(r1 * cos(th))), col = cols[k], border = "white",
                lwd = 0.4)
      }
      r0 <- r1
    }
  }
  if (show_legend)
    legend(0, -1.12 * rmax, xjust = 0.5, horiz = TRUE, title = "Wind speed (m/s)",
           legend = labs, fill = cols, bty = "n", cex = 0.68, xpd = NA,
           x.intersp = 0.6)
  if (!is.na(calm_pct))
    text(rmax * 1.05, -1.3 * rmax, sprintf("Calm (<0.5 m/s): %.1f%%", calm_pct),
         adj = 1, cex = 0.7, xpd = NA)
}

# 16-sector prevailing direction label
prevailing_dir <- function(wd) {
  if (all(is.na(wd))) return("--")
  labs <- c("N","NNE","NE","ENE","E","ESE","SE","SSE","S",
            "SSW","SW","WSW","W","WNW","NW","NNW")
  labs[which.max(tabulate(floor(((wd[!is.na(wd)] + 11.25) %% 360) / 22.5) + 1, 16))]
}

generate_met_report_pdf <- function(station_dir, station_code, start_year, end_year,
                                    completeness = NULL) {
  years <- start_year:end_year
  d  <- read_sfc_data(station_dir, station_code, years)
  du <- read_sfc_data(station_dir, station_code, years, suffix = "US")
  if (is.null(d)) { cat("No sfc data found; PDF report skipped\n"); return(NULL) }
  if (is.null(completeness))
    completeness <- verify_data_completeness(station_dir, station_code,
                                             start_year, end_year)
  pdf_path <- file.path(station_dir, sprintf("%s_%d_%d_met_report.pdf",
                                             station_code, start_year, end_year))
  seasons <- c("Winter", "Spring", "Summer", "Fall")
  scols <- c(Winter = "#4575b4", Spring = "#33a02c", Summer = "#d73027", Fall = "#ff7f00")
  tC <- d$temp - 273.15
  hdr <- function(txt) mtext(sprintf("%s  |  %d-%d  |  AERMET %s (GHCNh)  |  %s",
                                     station_code, start_year, end_year,
                                     AERMET_VERSION, txt),
                             side = 3, line = 3.1, cex = 0.72, col = "grey30", adj = 0)

  # metadata a reviewer needs in order to reproduce or challenge the run
  reg  <- STATION_REGISTRY[STATION_REGISTRY$code == station_code, ]
  sid  <- if (nrow(reg)) reg$station_id[1]    else NA_character_
  uid  <- if (nrow(reg)) reg$ua_station_id[1] else NA_character_
  meta <- tryCatch({
    cd <- file.path(dirname(station_dir), "cache")
    isd <- get_isd_history(cd); igr <- get_igra_info(cd)
    s <- isd[isd$station_id == sid, ][1, ]
    if (is.na(s$usaf)) s <- isd[!is.na(isd$icao) & isd$icao == station_code, ][1, ]
    list(s = s, u = igr[igr$igra_id == uid, ][1, ])
  }, error = function(e) NULL)
  aers <- parse_aersurface_file(file.path(station_dir,
            sprintf("%s_2021_aers_sfc.txt", tolower(station_code))))
  refh <- sfc_ref_heights(file.path(station_dir,
            sprintf("%s%d.sfc", station_code, start_year)))
  qcs  <- qc_log_summary(station_dir, station_code)

  pdf(pdf_path, width = 10.5, height = 8, title = sprintf("%s met report", station_code))
  on.exit(dev.off(), add = TRUE)

  # shared text-page helper
  new_text_page <- function(main) {
    par(mfrow = c(1, 1), mar = c(1, 1, 2, 1))
    plot.new(); title(main = main)
    yy <<- 0.94
  }
  yy <- 0.94; lh <- 0.031
  put <- function(txt, x = 0.02, bold = FALSE, col = "black", cex = 0.8) {
    text(x, yy, txt, adj = 0, cex = cex, font = if (bold) 2 else 1, col = col)
    yy <<- yy - lh
  }
  gap <- function(f = 0.6) yy <<- yy - lh * f

  ## ---- Page 1: station and data provenance ----
  new_text_page(sprintf("Station and Data Provenance -- %s (%d-%d)",
                        station_code, start_year, end_year))
  put("Surface station", bold = TRUE)
  if (!is.null(meta) && !is.na(meta$s$usaf)) {
    s <- meta$s
    put(sprintf("%-24s %s  %s%s", "Station", station_code, s$station_name,
                if (!is.na(s$state) && nzchar(s$state)) paste0(", ", s$state) else ""), x = 0.04)
    put(sprintf("%-24s %s / %s / %s", "ICAO / WBAN / USAF", station_code, s$wban, s$usaf), x = 0.04)
    put(sprintf("%-24s USW000%s", "GHCNh station ID", s$wban), x = 0.04)
    put(sprintf("%-24s %.4f N, %.4f W", "Latitude, longitude", s$lat, abs(s$lon)), x = 0.04)
    put(sprintf("%-24s %.1f m MSL", "Elevation", s$elev_m), x = 0.04)
  }
  put(sprintf("%-24s %.1f m        Temperature reference height: %.1f m",
              "Wind reference height", refh$wind, refh$temp), x = 0.04)
  gap()
  put("Upper air station", bold = TRUE)
  if (!is.null(meta) && !is.na(meta$u$igra_id)) {
    u <- meta$u
    put(sprintf("%-24s %s  %s", "Station", u$igra_id, trimws(u$station_name)), x = 0.04)
    put(sprintf("%-24s %.4f N, %.4f W        Elevation: %.1f m MSL",
                "Latitude, longitude", u$lat, abs(u$lon), u$elev_m), x = 0.04)
    if (!is.na(meta$s$lat))
      put(sprintf("%-24s %.0f km %s of %s", "Separation",
                  gc_km(meta$s$lat, meta$s$lon, u$lat, u$lon),
                  gc_dir(meta$s$lat, meta$s$lon, u$lat, u$lon), station_code), x = 0.04)
  }
  gap()
  put("Processing", bold = TRUE)
  put(sprintf("%-24s AERMET %s  |  AERMINUTE %s  |  AERSURFACE %s (NLCD %s)",
              "Software", AERMET_VERSION, AERMET_VERSION,
              if (!is.null(aers)) aers$version else "26135",
              if (!is.null(aers)) aers$nlcd else "2021"), x = 0.04)
  put(sprintf("%-24s NCEI GHCNh hourly (replaces the discontinued ISHD)",
              "Surface observations"), x = 0.04)
  put(sprintf("%-24s NCEI ASOS 1-minute and 5-minute, hourly-averaged by AERMINUTE",
              "Winds"), x = 0.04)
  put(sprintf("%-24s NCEI IGRA v2 radiosonde soundings", "Upper air"), x = 0.04)
  if (!is.null(qcs))
    put(sprintf("%-24s %s observations screened; %s suspect/erroneous and %s METAR-mismatch rejected",
                "GHCNh quality control", fmt_int(qcs$records), fmt_int(qcs$flagged),
                fmt_int(qcs$metar)), x = 0.04)
  put(sprintf("%-24s %s", "Report generated", format(Sys.Date())), x = 0.04)
  gap()
  put("Files in this dataset", bold = TRUE)
  put(sprintf("%-24s AERMOD surface and profile files, processed WITHOUT ADJ_U*",
              sprintf("%s<yyyy>.sfc / .pfl", station_code)), x = 0.04)
  put(sprintf("%-24s the same period processed with METHOD STABLEBL ADJ_U*",
              sprintf("%s<yyyy>US.sfc / .pfl", station_code)), x = 0.04)
  gap(0.3)
  put("The .sfc file carries the hourly boundary-layer parameters and the .pfl carries the wind and", x = 0.04, cex = 0.75)
  put("temperature profile at the measurement heights; AERMOD requires both.  Use the regular set or", x = 0.04, cex = 0.75)
  put("the ADJ_U* set consistently -- do not mix them within a single AERMOD run.  ADJ_U* is the", x = 0.04, cex = 0.75)
  put("EPA-approved treatment for low-wind stable hours and generally lowers modelled concentrations;", x = 0.04, cex = 0.75)
  put("its use should be stated and justified in the modelling protocol.", x = 0.04, cex = 0.75)
  gap(0.3)
  put("Each yearly .sfc ends with the 24 hours of 1 January of the FOLLOWING year.  That is how AERMET", x = 0.04, cex = 0.75)
  put("writes the file for XDATES y/01/01 TO y+1/01/01 and is expected by AERMOD -- it is not duplicated", x = 0.04, cex = 0.75)
  put("data within the year.", x = 0.04, cex = 0.75)

  ## ---- Page 2: summary ----
  par(mar = c(1, 1, 2, 1))
  plot.new(); title(main = sprintf("AERMET Meteorological Data Report -- %s (%d-%d)",
                                   station_code, start_year, end_year))
  yy <- 0.94
  put(sprintf("Generated %s  |  AERMET %s + AERMINUTE 26135 + AERSURFACE 26135 (NLCD 2021)",
              format(Sys.Date()), AERMET_VERSION), col = "grey25")
  put("Surface data: NCEI GHCNh (replaces discontinued ISHD)  |  Upper air: IGRA soundings  |  Winds: 1-min ASOS (AERMINUTE)",
      col = "grey25")
  yy <- yy - lh * 0.6
  put("Annual summary (regular, non-ADJ_U* files):", bold = TRUE)
  put(sprintf("%-6s %10s %10s %9s %11s %11s %11s %12s", "Year", "Valid hrs",
              "Calm %", "Mean WS", "Max WS", "Prevail dir", "Mean T", "Precip (in)"),
      x = 0.04, bold = TRUE)
  for (y in years) {
    dy <- d[d$year == y, ]
    if (nrow(dy) == 0) { put(sprintf("%-6d %10s", y, "no data"), x = 0.04); next }
    valid <- sum(!is.na(dy$ws))
    put(sprintf("%-6d %10d %9.1f%% %7.1f m/s %9.1f m/s %11s %8.1f degF %11.1f",
                y, valid, 100 * sum(dy$calm) / max(1, valid),
                mean(dy$ws, na.rm = TRUE), max(dy$ws, na.rm = TRUE),
                prevailing_dir(dy$wd),
                mean(dy$temp - 273.15, na.rm = TRUE) * 9/5 + 32,
                sum(dy$pamt, na.rm = TRUE) / 25.4), x = 0.04)
  }
  yy <- yy - lh * 0.6
  put("Quarterly data completeness vs EPA 90% criterion:", bold = TRUE)
  put(sprintf("%-6s %9s %9s %9s %9s %10s", "Year", "Q1", "Q2", "Q3", "Q4", "Annual"),
      x = 0.04, bold = TRUE)
  n_fail <- 0
  for (y in as.character(years)) {
    yd <- completeness[[y]]
    if (is.null(yd) || !is.null(yd$error)) { put(sprintf("%-6s  n/a", y), x = 0.04); next }
    cells <- sapply(c("Q1","Q2","Q3","Q4"), function(q) {
      qd <- yd$quarters[[q]]
      if (is.null(qd$completeness_pct)) return("n/a")
      n_fail <<- n_fail + !isTRUE(qd$meets_epa)
      sprintf("%.1f%%%s", qd$completeness_pct, if (isTRUE(qd$meets_epa)) "" else "*")
    })
    put(sprintf("%-6s %9s %9s %9s %9s %9.1f%%", y, cells[1], cells[2], cells[3],
                cells[4], yd$annual$completeness_pct), x = 0.04)
  }
  if (n_fail > 0)
    put("* below the 90% quarterly completeness target -- review per App. W / regional guidance (consider substitute years).",
        col = "#b2182b")
  yy <- yy - lh * 0.6
  put("Notes for PSD applications:", bold = TRUE)
  valid_all <- sum(!is.na(d$ws))
  put(sprintf("- Prevailing wind %s; network-wide calms %.1f%% of valid hours; ADJ_U* companion files (US) included in this dataset.",
              prevailing_dir(d$wd), 100 * sum(d$calm) / max(1, valid_all)), x = 0.04)
  if (!is.null(du)) {
    m <- merge(d[!is.na(d$L) & d$L > 0, c("year","month","day","hour","ustar")],
               du[, c("year","month","day","hour","ustar")],
               by = c("year","month","day","hour"), suffixes = c("_reg", "_adj"))
    m <- m[!is.na(m$ustar_reg) & !is.na(m$ustar_adj), ]
    if (nrow(m) > 0)
      put(sprintf("- ADJ_U* raises stable-hour friction velocity by %.0f%% on average (median regular %.3f -> ADJ_U* %.3f m/s).",
                  100 * (mean(m$ustar_adj / m$ustar_reg) - 1),
                  median(m$ustar_reg), median(m$ustar_adj)), x = 0.04)
  }
  put(sprintf("- Surface characteristics: AERSURFACE %s, NLCD %s, %s m radius, %s sector(s); z0 %.3f-%.3f m. Full table follows.",
              if (!is.null(aers)) aers$version else "26135",
              if (!is.null(aers)) aers$nlcd else "2021",
              if (!is.null(aers)) trimws(aers$zo_radius) else "1000",
              if (!is.null(aers) && !is.null(aers$sectors)) nrow(aers$sectors) else "?",
              min(d$z0, na.rm = TRUE), max(d$z0, na.rm = TRUE)), x = 0.04)
  put("- Wind roses use direction FROM which the wind blows; petals are % of all valid hours.", x = 0.04)
  cm <- sum(d$calm, na.rm = TRUE); ms <- sum(is.na(d$ws))
  put(sprintf("- AERMOD excludes calm and missing hours from the averaging period: %s calm and %s missing hours over %d-%d",
              fmt_int(cm), fmt_int(ms), start_year, end_year), x = 0.04)
  put(sprintf("  (%.1f%% of the record). AERMOD reports both counts in its own output; no substitution is made here.",
              100 * (cm + ms) / max(1, nrow(d))), x = 0.04)

  ## ---- Page 2: 5-year wind rose ----
  par(mar = c(4, 2, 5, 2))
  plot_wind_rose(d$ws, d$wd,
                 main = sprintf("Wind Rose -- %s, %d-%d (all hours)",
                                station_code, start_year, end_year),
                 calm_pct = 100 * sum(d$calm) / max(1, sum(!is.na(d$ws))))
  hdr("5-year wind climate")

  ## ---- Page 3: seasonal wind roses ----
  par(mfrow = c(2, 2), mar = c(2.5, 1.5, 3, 1.5), oma = c(3, 0, 2.2, 0))
  for (s in seasons) {
    ds <- d[d$season == s, ]
    plot_wind_rose(ds$ws, ds$wd, main = s,
                   calm_pct = 100 * sum(ds$calm) / max(1, sum(!is.na(ds$ws))),
                   show_legend = FALSE)
  }
  mtext(sprintf("Seasonal Wind Roses -- %s, %d-%d", station_code, start_year, end_year),
        outer = TRUE, cex = 1.1, font = 2)
  par(fig = c(0, 1, 0, 1), oma = c(0, 0, 0, 0), mar = c(0, 0, 0, 0), new = TRUE)
  plot.new()
  legend("bottom", horiz = TRUE, title = "Wind speed (m/s)",
         legend = c("0.5-2", "2-4", "4-6", "6-8", ">8"),
         fill = c("#4575b4", "#91bfdb", "#fee090", "#fc8d59", "#d73027"),
         bty = "n", cex = 0.8, xpd = NA)
  par(mfrow = c(1, 1))

  ## ---- Page 4: wind speed climatology ----
  par(mfrow = c(2, 1), mar = c(4, 4, 3, 1), oma = c(0, 0, 2, 0))
  boxplot(ws ~ month, data = d, outline = FALSE, col = "#91bfdb",
          names = month.abb, xlab = "", ylab = "Wind speed (m/s)",
          main = "Monthly wind speed distribution")
  plot(NA, xlim = c(0, 23), ylim = c(0, max(3, 1.25 * max(
       tapply(d$ws, list(d$hour - 1, d$season), mean, na.rm = TRUE), na.rm = TRUE))),
       xlab = "Hour (LST)", ylab = "Mean wind speed (m/s)",
       main = "Diurnal wind speed by season")
  for (s in seasons) {
    m <- tapply(d$ws[d$season == s], d$hour[d$season == s] - 1, mean, na.rm = TRUE)
    lines(as.numeric(names(m)), m, col = scols[s], lwd = 2)
  }
  legend("topleft", seasons, col = scols[seasons], lwd = 2, bty = "n", cex = 0.8)
  mtext(sprintf("Wind Speed -- %s, %d-%d", station_code, start_year, end_year),
        outer = TRUE, cex = 1.1, font = 2)

  ## ---- Page 5: temperature ----
  par(mfrow = c(2, 1), mar = c(4, 4, 3, 1), oma = c(0, 0, 2, 0))
  mmean <- tapply(tC, d$month, mean, na.rm = TRUE)
  mp05  <- tapply(tC, d$month, quantile, 0.05, na.rm = TRUE)
  mp95  <- tapply(tC, d$month, quantile, 0.95, na.rm = TRUE)
  plot(1:12, mmean, type = "n", ylim = range(c(mp05, mp95), na.rm = TRUE),
       xaxt = "n", xlab = "", ylab = "Temperature (degC)",
       main = "Monthly temperature: mean and 5th-95th percentile")
  axis(1, 1:12, month.abb, cex.axis = 0.85)
  polygon(c(1:12, 12:1), c(mp05, rev(mp95)), col = "#fee0b6", border = NA)
  lines(1:12, mmean, col = "#d73027", lwd = 2); points(1:12, mmean, pch = 16, col = "#d73027")
  plot(NA, xlim = c(0, 23), ylim = range(tapply(tC, list(d$hour - 1, d$season),
       mean, na.rm = TRUE), na.rm = TRUE),
       xlab = "Hour (LST)", ylab = "Mean temperature (degC)",
       main = "Diurnal temperature by season")
  for (s in seasons) {
    m <- tapply(tC[d$season == s], d$hour[d$season == s] - 1, mean, na.rm = TRUE)
    lines(as.numeric(names(m)), m, col = scols[s], lwd = 2)
  }
  legend("topleft", seasons, col = scols[seasons], lwd = 2, bty = "n", cex = 0.8)
  mtext(sprintf("Temperature -- %s, %d-%d", station_code, start_year, end_year),
        outer = TRUE, cex = 1.1, font = 2)

  ## ---- Page 6: mixing heights & stability ----
  par(mfrow = c(2, 1), mar = c(4, 4, 3, 1), oma = c(0, 0, 2, 0))
  plot(NA, xlim = c(0, 23), ylim = c(0, max(500, 1.15 * max(
       tapply(d$zic, d$hour - 1, median, na.rm = TRUE),
       tapply(d$zim, d$hour - 1, median, na.rm = TRUE), na.rm = TRUE))),
       xlab = "Hour (LST)", ylab = "Mixing height (m)",
       main = "Diurnal median mixing heights (AERMOD dispersion drivers)")
  mzic <- tapply(d$zic, d$hour - 1, median, na.rm = TRUE)
  mzim <- tapply(d$zim, d$hour - 1, median, na.rm = TRUE)
  lines(as.numeric(names(mzic)), mzic, col = "#d73027", lwd = 2)
  lines(as.numeric(names(mzim)), mzim, col = "#4575b4", lwd = 2)
  legend("topleft", c("Convective (Zic)", "Mechanical (Zim)"),
         col = c("#d73027", "#4575b4"), lwd = 2, bty = "n", cex = 0.8)
  stab <- ifelse(is.na(d$L), NA, ifelse(d$L > 0, "Stable", "Convective"))
  frac <- sapply(0:23, function(h) {
    v <- stab[d$hour - 1 == h]
    c(mean(v == "Convective", na.rm = TRUE), mean(v == "Stable", na.rm = TRUE))
  })
  barplot(frac * 100, names.arg = 0:23, col = c("#fc8d59", "#4575b4"), border = NA,
          xlab = "Hour (LST)", ylab = "% of hours",
          main = "Boundary-layer state by hour (from Monin-Obukhov L)")
  legend("topright", c("Convective (L<0)", "Stable (L>0)"),
         fill = c("#fc8d59", "#4575b4"), bty = "n", cex = 0.8, bg = "white")
  mtext(sprintf("Mixing Heights & Stability -- %s, %d-%d",
                station_code, start_year, end_year), outer = TRUE, cex = 1.1, font = 2)

  ## ---- Page 7: surface energetics + ADJ_U* ----
  par(mfrow = c(2, 2), mar = c(4, 4, 3, 1), oma = c(0, 0, 2, 0))
  plot(NA, xlim = c(0, 23), ylim = range(tapply(d$H, list(d$hour - 1, d$season),
       mean, na.rm = TRUE), na.rm = TRUE),
       xlab = "Hour (LST)", ylab = "H (W/m2)", main = "Sensible heat flux by season")
  abline(h = 0, col = "grey70")
  for (s in seasons) {
    m <- tapply(d$H[d$season == s], d$hour[d$season == s] - 1, mean, na.rm = TRUE)
    lines(as.numeric(names(m)), m, col = scols[s], lwd = 2)
  }
  legend("topleft", seasons, col = scols[seasons], lwd = 2, bty = "n", cex = 0.7)
  hist(d$ustar, breaks = 40, col = "#91bfdb", border = "white",
       xlab = "u* (m/s)", main = "Friction velocity distribution")
  if (!is.null(du)) {
    m <- merge(d[!is.na(d$L) & d$L > 0, c("year","month","day","hour","ustar")],
               du[, c("year","month","day","hour","ustar")],
               by = c("year","month","day","hour"), suffixes = c("_reg", "_adj"))
    m <- m[!is.na(m$ustar_reg) & !is.na(m$ustar_adj), ]
    if (nrow(m) > 2000) m <- m[sample(nrow(m), 2000), ]
    lim <- c(0, max(m$ustar_reg, m$ustar_adj, 0.3))
    plot(m$ustar_reg, m$ustar_adj, pch = 16, cex = 0.35, col = "#4575b466",
         xlim = lim, ylim = lim, xlab = "u* regular (m/s)", ylab = "u* ADJ_U* (m/s)",
         main = "Stable-hour u*: regular vs ADJ_U*")
    abline(0, 1, col = "grey40", lty = 2)
    qs <- seq(0.05, 0.95, 0.05)
    lines(quantile(m$ustar_reg, qs), quantile(m$ustar_adj, qs), col = "#d73027", lwd = 2)
    legend("topleft", c("1:1", "Q-Q"), col = c("grey40", "#d73027"),
           lty = c(2, 1), lwd = c(1, 2), bty = "n", cex = 0.7)
  } else { plot.new(); title("ADJ_U* files not found") }
  boxplot(ustar ~ season, data = transform(d, season = factor(season, seasons)),
          outline = FALSE, col = scols[seasons], xlab = "", ylab = "u* (m/s)",
          main = "u* by season")
  mtext(sprintf("Surface Energetics & ADJ_U* -- %s, %d-%d",
                station_code, start_year, end_year), outer = TRUE, cex = 1.1, font = 2)

  ## ---- Page 8: moisture ----
  par(mfrow = c(2, 2), mar = c(4, 4, 3, 1), oma = c(0, 0, 2, 0))
  ptot <- sapply(years, function(y) sum(d$pamt[d$year == y], na.rm = TRUE) / 25.4)
  barplot(ptot, names.arg = years, col = "#4575b4", border = NA,
          ylab = "Precipitation (in)", main = "Annual precipitation")
  pm <- sapply(1:12, function(m)
    mean(sapply(years, function(y)
      sum(d$pamt[d$year == y & d$month == m], na.rm = TRUE))) / 25.4)
  barplot(pm, names.arg = month.abb, col = "#91bfdb", border = NA, las = 2,
          ylab = "Precipitation (in)", main = "Mean monthly precipitation")
  m <- tapply(d$rh, d$hour - 1, mean, na.rm = TRUE)
  plot(as.numeric(names(m)), m, type = "l", lwd = 2, col = "#33a02c",
       xlab = "Hour (LST)", ylab = "RH (%)", main = "Diurnal relative humidity")
  mcc <- tapply(d$ccvr, d$month, mean, na.rm = TRUE)
  plot(1:12, mcc, type = "b", pch = 16, lwd = 2, col = "#ff7f00", xaxt = "n",
       xlab = "", ylab = "Cloud cover (tenths)", main = "Monthly mean cloud cover")
  axis(1, 1:12, month.abb, cex.axis = 0.8)
  mtext(sprintf("Moisture & Cloud Cover -- %s, %d-%d",
                station_code, start_year, end_year), outer = TRUE, cex = 1.1, font = 2)

  ## ---- Page 9: AERSURFACE surface characteristics ----
  new_text_page(sprintf("Surface Characteristics -- %s (AERSURFACE %s)", station_code,
                        if (!is.null(aers)) aers$version else "26135"))
  if (!is.null(aers)) {
    put("Run settings", bold = TRUE)
    put(sprintf("%-26s NLCD %s land cover, with impervious and canopy",
                "Land cover", aers$nlcd), x = 0.04)
    put(sprintf("%-26s %s, %s m radius, monthly resolution",
                "Roughness method", aers$zo_method, trimws(aers$zo_radius)), x = 0.04)
    put(sprintf("%-26s %.6f, %.6f  (%s)", "Site centre", aers$lat, aers$lon, aers$datum), x = 0.04)
    put(sprintf("%-26s %s", "Surface moisture", aers$moisture), x = 0.04)
    put(sprintf("%-26s %s", "Continuous snow cover", aers$snow), x = 0.04)
    put(sprintf("%-26s %s", "Non-airport sectors", aers$highz0), x = 0.04)
    if (!is.null(aers$sectors)) {
      put(sprintf("%-26s %d", "Sectors", nrow(aers$sectors)), x = 0.04)
      for (i in seq_len(nrow(aers$sectors)))
        put(sprintf("%-26s sector %d: %5.1f to %6.1f degrees", "",
                    aers$sectors$id[i], aers$sectors$start[i], aers$sectors$end[i]), x = 0.04)
    }
    gap()
    put("Monthly values applied by AERMET", bold = TRUE)
    if (!is.null(aers$table)) {
      t <- aers$table
      nsec <- length(unique(t$sector))
      # months down the page, one block of three columns per sector
      hdrline <- paste0(sprintf("%-6s", "Month"),
        paste(sapply(sort(unique(t$sector)), function(k)
          sprintf("  %8s %8s %8s", sprintf("S%d alb", k), sprintf("S%d Bo", k),
                  sprintf("S%d z0", k))), collapse = ""))
      put(hdrline, x = 0.04, bold = TRUE, cex = 0.72)
      for (m in 1:12) {
        row <- sprintf("%-6s", month.abb[m])
        for (k in sort(unique(t$sector))) {
          r <- t[t$month == m & t$sector == k, ]
          row <- paste0(row, if (nrow(r))
            sprintf("  %8.2f %8.2f %8.3f", r$albedo[1], r$bowen[1], r$z0[1])
            else sprintf("  %8s %8s %8s", "-", "-", "-"))
        }
        put(row, x = 0.04, cex = 0.72)
      }
      gap(0.4)
      put("alb = albedo, Bo = Bowen ratio, z0 = surface roughness length (m). These are the values", x = 0.04, cex = 0.72)
      put("AERMET applied; they are reproduced from the AERSURFACE output supplied with this dataset.", x = 0.04, cex = 0.72)
    }
  } else put("AERSURFACE output file not found in the station folder.", x = 0.04)

  ## ---- Page 10: data quality screening ----
  new_text_page(sprintf("Data Quality Screening -- %s (%d-%d)",
                        station_code, start_year, end_year))
  put("Surface data quality control applied before processing", bold = TRUE)
  put("NCEI flags every observation with a quality code that AERMET does not act on, so the GHCNh", x = 0.04, cex = 0.78)
  put("file is screened first. Rejected values are blanked and treated as missing; no record is dropped", x = 0.04, cex = 0.78)
  put("and no value is altered or substituted. A second screen compares the decoded wind speed against", x = 0.04, cex = 0.78)
  put("the verbatim METAR text NCEI carries alongside it, which catches decoding errors the quality", x = 0.04, cex = 0.78)
  put("flags miss.", x = 0.04, cex = 0.78)
  gap(0.4)
  if (!is.null(qcs)) {
    put(sprintf("%-40s %s", "Observations screened", fmt_int(qcs$records)), x = 0.04)
    put(sprintf("%-40s %s", "Rejected: NCEI suspect or erroneous", fmt_int(qcs$flagged)), x = 0.04)
    put(sprintf("%-40s %s", "Rejected: decoded wind vs METAR text", fmt_int(qcs$metar)), x = 0.04)
    put(sprintf("%-40s %s", "Itemised log", qcs$file), x = 0.04)
  } else put("No quality-control log found for this station.", x = 0.04)
  gap()
  put("Physical plausibility of the delivered files", bold = TRUE)
  put("Screening of the .sfc files as delivered. A non-zero count is not by itself an error, but each", x = 0.04, cex = 0.78)
  put("occurrence should be explainable before the data are used.", x = 0.04, cex = 0.78)
  gap(0.4)
  put(sprintf("%-6s %11s %10s %10s %14s %18s", "Year", "Max wind", "Min temp",
              "Max temp", "Hrs ws>25 m/s", "Hrs T out of range"),
      x = 0.04, bold = TRUE, cex = 0.78)
  ext <- screen_sfc_extremes(station_dir, station_code, years)
  for (y in years) {
    e <- ext[[as.character(y)]]
    if (is.null(e)) next
    put(sprintf("%-6d %7.1f m/s %8.1f C %8.1f C %14d %18d",
                y, e$ws_max, e$t_min, e$t_max, e$n_ws_hi, e$n_t_out),
        x = 0.04, cex = 0.78,
        col = if (e$n_ws_hi + e$n_t_out > 0) "#b2182b" else "black")
  }
  gap(0.4)
  put("Bounds used: wind speed above 25 m/s, temperature outside -25 to +45 C.", x = 0.04, cex = 0.72)

  ## ---- Page 11: completeness heatmap (monthly diagnostic) ----
  par(mfrow = c(1, 1), mar = c(4, 5, 4, 8))
  compmat <- matrix(NA, length(years), 12,
                    dimnames = list(years, month.abb))
  for (yi in seq_along(years)) for (m in 1:12) {
    sel <- d$year == years[yi] & d$month == m
    nhr <- sum(sel)
    if (nhr > 0) compmat[yi, m] <- 100 * sum(!is.na(d$ws[sel]) & !is.na(d$temp[sel])) /
                                   (24 * c(31,28,31,30,31,30,31,31,30,31,30,31)[m])
  }
  compmat[compmat > 100] <- 100
  cols <- colorRampPalette(c("#b2182b", "#fddbc7", "#d1e5f0", "#2166ac"))(50)
  image(1:12, seq_along(years), t(compmat[rev(seq_along(years)), , drop = FALSE]),
        col = cols, zlim = c(50, 100), axes = FALSE, xlab = "", ylab = "",
        main = "Monthly data completeness (% of hours with valid wind and temperature)")
  axis(1, 1:12, month.abb, cex.axis = 0.85)
  axis(2, seq_along(years), rev(years), las = 1)
  for (yi in seq_along(years)) for (m in 1:12)
    if (!is.na(compmat[yi, m]))
      text(m, length(years) - yi + 1, sprintf("%.0f", compmat[yi, m]), cex = 0.7,
           col = if (compmat[yi, m] < 90) "#67001f" else "grey25")
  # quarter boundaries and the quarterly figures that are the actual EPA test
  abline(v = c(3.5, 6.5, 9.5), col = "grey35", lwd = 1.6)
  for (qi in seq_along(qn <- c("Q1","Q2","Q3","Q4")))
    mtext(qn[qi], side = 3, line = 0.2, at = qi * 3 - 1, cex = 0.75, col = "grey30")
  for (yi in seq_along(years)) {
    yd <- completeness[[as.character(years[yi])]]
    if (is.null(yd) || !is.null(yd$error)) next
    lab <- paste(sapply(qn, function(q) {
      qd <- yd$quarters[[q]]
      if (is.null(qd$completeness_pct)) "n/a" else sprintf("%.1f", qd$completeness_pct)
    }), collapse = " / ")
    ok <- all(sapply(qn, function(q) isTRUE(yd$quarters[[q]]$meets_epa)))
    mtext(lab, side = 4, line = 0.4, at = length(years) - yi + 1, las = 1,
          cex = 0.62, col = if (ok) "grey25" else "#b2182b")
  }
  mtext("Quarterly (EPA test)", side = 4, line = 0.4, at = length(years) + 0.75,
        las = 1, cex = 0.62, font = 2, col = "grey20")
  box()
  hdr("monthly detail is diagnostic -- the EPA 90% criterion is applied by QUARTER (values at right)")

  cat(sprintf("Met report PDF: %s\n", basename(pdf_path)))
  pdf_path
}

# ----------------------------------- packaging ---------------------------------------

create_readme <- function(station_code, start_year, end_year) {
  sprintf(paste0(
    "AERMOD-ready meteorological data for %s, %d-%d.\n\n",
    "Processed with AERMET %s using GHCNh surface data (NCEI), IGRA upper air\n",
    "soundings, AERMINUTE %s hourly-averaged 1-minute ASOS winds, and AERSURFACE\n",
    "26135 surface characteristics (NLCD 2021).\n\n",
    "Files %s[YYYY].sfc/.pfl were processed without ADJ_U*;\n",
    "files %s[YYYY]US.sfc/.pfl were processed with METHOD STABLEBL ADJ_U*.\n\n",
    "See the included met report PDF for wind roses, climatology, mixing height,\n",
    "stability, and data-completeness graphics, and the verification report for\n",
    "quarterly completeness statistics.\n\n",
    "Contact: Rodney Cuevas, MDEQ, RCuevas@mdeq.ms.gov"),
    station_code, start_year, end_year, AERMET_VERSION, AERMET_VERSION,
    station_code, station_code)
}

zip_met_files <- function(station_paths, start_year, end_year) {
  station_dir <- station_paths$station_dir
  station_code <- basename(station_dir)
  zip_path <- file.path(station_dir, sprintf("%s%02d_%02d.zip", station_code,
                                             start_year %% 100, end_year %% 100))
  files <- c()
  for (year in start_year:end_year)
    for (suffix in c("", "US"))
      for (ext in c("sfc", "pfl")) {
        f <- file.path(station_dir, sprintf("%s%d%s.%s", station_code, year, suffix, ext))
        if (file.exists(f)) files <- c(files, f)
        else cat(sprintf("Warning: not zipped (missing): %s\n", basename(f)))
      }
  if (length(files) == 0) stop("No met files found to zip")

  readme <- file.path(station_dir, "README.txt")
  writeLines(create_readme(station_code, start_year, end_year), readme)
  files <- c(files, readme)
  vr <- file.path(station_dir, sprintf("%s_verification_report.txt", station_code))
  if (file.exists(vr)) files <- c(files, vr)
  pr <- file.path(station_dir, sprintf("%s_%d_%d_met_report.pdf",
                                       station_code, start_year, end_year))
  if (file.exists(pr)) files <- c(files, pr)

  if (file.exists(zip_path)) unlink(zip_path)
  zip(zip_path, files, flags = "-j9")
  unlink(readme)
  cat(sprintf("Zip created: %s (%d files)\n", basename(zip_path), length(files)))
  zip_path
}

# --------------------------------- orchestration -------------------------------------

process_weather_station <- function(station_code, station_id, start_year, end_year,
                                    root_directory, ua_file_path, ua_station_id,
                                    cache_dir = NULL) {
  base_directory <- file.path(root_directory, station_code)
  if (!dir.exists(base_directory)) dir.create(base_directory, recursive = TRUE)

  wban <- sub(".*-", "", station_id)
  ghcnh_file <- download_ghcnh(station_code, wban, start_year, end_year, base_directory)
  # AERMET does not honour NCEI's quality flags; screen the .psv before it is read.
  filter_ghcnh_quality(ghcnh_file)

  has_aerminute <- check_aerminute_availability(station_code, start_year, 1)
  cat(sprintf("%s %s AERMINUTE data\n", station_code,
              if (has_aerminute) "has" else "does not have"))

  aerminute_input <- NULL
  if (has_aerminute)
    aerminute_input <- create_aerminute_input(station_code, start_year, end_year,
                                              base_directory, ghcnh_file)

  aermet_input <- create_aermet_input(station_code, start_year, end_year,
                                      root_directory, ua_file_path, station_id,
                                      ua_station_id, ghcnh_file, cache_dir)

  station_paths <- list(station_dir = base_directory,
                        has_aerminute = has_aerminute,
                        aerminute_input = aerminute_input,
                        aermet_input = aermet_input,
                        ghcnh_file = ghcnh_file)
  if (has_aerminute) run_aerminute(station_paths, root_directory)
  station_paths
}

process_aermet_complete <- function(station_code,
                                    station_id = NULL,
                                    start_year = MET_START_YEAR,
                                    end_year = MET_END_YEAR,
                                    root_directory = getwd(),
                                    ua_station_id = NULL) {
  station_code <- toupper(station_code)
  reg <- STATION_REGISTRY[STATION_REGISTRY$code == station_code, ]
  if (is.null(station_id))    station_id    <- reg$station_id[1]
  if (is.null(ua_station_id)) ua_station_id <- reg$ua_station_id[1]
  if (is.na(station_id) || is.na(ua_station_id))
    stop(sprintf("%s is not in STATION_REGISTRY; pass station_id and ua_station_id", station_code))

  cache_dir <- file.path(root_directory, "cache")
  if (!dir.exists(cache_dir)) dir.create(cache_dir, recursive = TRUE)

  cat(sprintf("\n=================== %s  %d-%d ===================\n",
              station_code, start_year, end_year))
  ua_icao <- get_icao_from_igra(ua_station_id, cache_dir)
  cat(sprintf("Upper air station: %s (%s)\n", ua_station_id, ua_icao))

  ua_file_path <- download_igra_data(ua_station_id, start_year, end_year,
                                     root_directory, station_code)
  aersurf_file <- fetch_aersurface_file(station_code, root_directory,
                                        start_year, end_year)

  station_paths <- process_weather_station(station_code, station_id, start_year,
                                           end_year, root_directory, ua_file_path,
                                           ua_station_id, cache_dir)
  run_aermet_stage1(station_paths, root_directory)
  create_and_run_aermet_stage2(station_paths, start_year, end_year,
                               aersurf_file, ua_icao, root_directory)
  ver <- verify_aermet_processing(station_paths, start_year, end_year)
  generate_met_report_pdf(station_paths$station_dir, station_code,
                          start_year, end_year,
                          completeness = ver$data_completeness)
  zip_path <- zip_met_files(station_paths, start_year, end_year)

  cat(sprintf("\n%s complete. Output zip: %s\n", station_code, basename(zip_path)))
  station_paths
}

# ------------------------------------ batch ------------------------------------------

process_all_stations <- function(stations = STATIONS,
                                 start_year = MET_START_YEAR,
                                 end_year = MET_END_YEAR,
                                 root_directory = getwd()) {
  results <- list()
  for (st in stations) {
    results[[st]] <- tryCatch(
      process_aermet_complete(st, start_year = start_year, end_year = end_year,
                              root_directory = root_directory),
      error = function(e) {
        cat(sprintf("\n*** %s FAILED: %s ***\n", st, e$message))
        list(error = e$message)
      })
  }
  cat("\n==================== BATCH SUMMARY ====================\n")
  for (st in names(results))
    cat(sprintf("%-6s %s\n", st,
                if (!is.null(results[[st]]$error)) paste("FAILED:", results[[st]]$error)
                else "OK"))
  invisible(results)
}

if (!exists("AERMET_SOURCE_ONLY") || !isTRUE(AERMET_SOURCE_ONLY)) {
  if (!dir.exists(file.path(getwd(), "KJAN")))
    stop("Run this script from the AERMINUTE folder (station folders not found in getwd())")
  process_all_stations()
}
