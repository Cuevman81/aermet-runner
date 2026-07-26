# =============================================================================
# qa.R -- post-run quality assurance for a completed AERMOD met build.
#
# After the pipeline finishes, this inspects the on-disk artifacts and produces a
# structured pass / warn / fail checklist so the end user can SEE that AERSURFACE
# and AERMET ran correctly and the processed data is sound. It reuses the engine's
# own verification helpers (verify_data_completeness, verify_software_versions,
# verify_file_dates, parse_rp2_file, aermet_run_succeeded) and adds AERSURFACE and
# provenance checks on top.
#
# qa_run(...) returns list(overall, checks, text):
#   overall : "PASS" | "WARN" | "FAIL"
#   checks  : list of list(group, label, status, detail)   status in pass/warn/fail/info
#   text    : character vector -> written as QA_SUMMARY.txt (and added to the zip)
# =============================================================================

`%||%` <- if (exists("%||%")) `%||%` else function(a, b) if (is.null(a)) b else a

.qa_status_rank <- c(pass = 0, info = 0, warn = 1, fail = 2)

# One checklist row.
.qa_chk <- function(group, label, status, detail = "")
  list(group = group, label = label, status = status, detail = detail)

# Read the AERMET .RP2 MESSAGE SUMMARY error/warning counts directly. The engine's
# own parse_rp2_file used to return NA for the "<n> MESSAGES" layout (corrected in
# engine_fixes.R); QA keeps its own reader so the error pass/fail check stays
# independent of that wrapper and cannot silently regress to a false PASS.
.qa_rp2_counts <- function(rp2) {
  if (!file.exists(rp2)) return(c(error = NA_real_, warning = NA_real_))
  ln <- readLines(rp2, warn = FALSE)
  grab <- function(pat) {
    h <- grep(pat, ln, value = TRUE)
    if (!length(h)) return(NA_real_)
    m <- regmatches(h[1], regexec(paste0(pat, "\\s+(\\d+)"), h[1]))[[1]]
    if (length(m) >= 2) as.numeric(m[2]) else NA_real_
  }
  c(error = grab("ERROR MESSAGES"), warning = grab("WARNING MESSAGES"))
}

# --- AERSURFACE ---------------------------------------------------------------
# Reads the aers_sfc.txt table + stdout to confirm a clean, complete, physically
# plausible surface-characteristics file.
qa_aersurface <- function(aers_dir, icao) {
  chk <- list(); grp <- "AERSURFACE (land cover)"
  sfc  <- file.path(aers_dir, sprintf("%s_aers_sfc.txt", tolower(icao)))
  sout <- file.path(aers_dir, "aersurface_stdout.txt")

  if (!file.exists(sfc) || file.info(sfc)$size == 0)
    return(list(.qa_chk(grp, "Surface-characteristics file produced", "fail",
                        "aers_sfc.txt missing or empty")))

  ln <- readLines(sfc, warn = FALSE)
  out <- if (file.exists(sout)) readLines(sout, warn = FALSE) else character(0)

  # 1) clean completion
  ok_done <- any(grepl("Finished Successfully", out, ignore.case = TRUE))
  hung    <- any(grepl("Standard Parallel|Enter the", out, ignore.case = TRUE))
  chk <- c(chk, list(.qa_chk(grp, "AERSURFACE finished successfully",
    if (ok_done && !hung) "pass" else "fail",
    if (hung) "interactive-prompt hang detected"
    else if (ok_done) "clean exit" else "no success banner in stdout")))

  # 2) version
  ver <- sub(".*Version\\s+([0-9]+).*", "\\1", grep("Version", ln, value = TRUE)[1])
  chk <- c(chk, list(.qa_chk(grp, "AERSURFACE version 26135",
    if (identical(ver, "26135")) "pass" else "warn",
    sprintf("reported %s", ver %||% "unknown"))))

  # 3) surface-characteristics table complete & physically plausible
  # AERSURFACE row layout is:  SITE_CHAR <month> <sector> <albedo> <Bowen> <z0>
  # so dropping the keyword leaves f = [month, sector, albedo, Bowen, z0] and the
  # three values of interest are f[3:5] in THAT order (albedo first, z0 last).
  sc <- grep("^\\s*SITE_CHAR", ln, value = TRUE)
  nsect <- length(grep("^\\s*SECTOR\\s", ln))
  vals <- do.call(rbind, lapply(sc, function(l) {
    f <- suppressWarnings(as.numeric(strsplit(trimws(l), "\\s+")[[1]][-1]))
    if (length(f) >= 5) f[3:5] else rep(NA_real_, 3)
  }))
  exp_rows <- 12 * max(nsect, 1)
  plausible <- !is.null(vals) && all(is.finite(vals)) && all(vals >= 0) && all(vals <= 10)
  complete  <- length(sc) == exp_rows
  chk <- c(chk, list(.qa_chk(grp, "Surface characteristics complete & in range",
    if (complete && plausible) "pass" else if (length(sc) > 0 && plausible) "warn" else "fail",
    sprintf("%d/%d monthly rows across %d sector(s); %s", length(sc), exp_rows,
            max(nsect, 1),
            if (!is.null(vals) && all(is.finite(vals)))
              sprintf("albedo %.3f-%.3f, Bowen %.2f-%.2f, z0 %.3f-%.3f m",
                      min(vals[,1]), max(vals[,1]), min(vals[,2]), max(vals[,2]),
                      min(vals[,3]), max(vals[,3]))
            else "non-finite values present"))))

  # 4) sectors used (informational) -- prefer AP/NONAP from the control file
  inp <- file.path(aers_dir, sprintf("%s_aersurface.inp", tolower(icao)))
  sect_txt <- if (file.exists(inp)) {
    s <- grep("^\\s*SECTOR\\s", readLines(inp, warn = FALSE), value = TRUE)
    paste(sub(".*SECTOR\\s+\\d+\\s+([0-9.]+)\\s+([0-9.]+)\\s+(\\S+).*", "\\1-\\2 \\3", s), collapse = ", ")
  } else sprintf("%d sector(s)", max(nsect, 1))
  chk <- c(chk, list(.qa_chk(grp, "Airport (AP) / non-airport (NONAP) sectors", "info", sect_txt)))
  chk
}

# --- AERMET -------------------------------------------------------------------
qa_aermet <- function(station_dir, icao, y1, y2) {
  chk <- list(); grp <- "AERMET (processing)"
  years <- y1:y2

  # 1) engine version from the .sfc header
  ver <- verify_software_versions(station_dir, y1, y2)$aermet
  chk <- c(chk, list(.qa_chk(grp, "AERMET version 26135",
    if (identical(ver, "26135")) "pass" else "warn", sprintf("reported %s", ver %||% "unknown"))))

  # 2) every Stage-2 report finished successfully (regular + ADJ_U*)
  rp2 <- unlist(lapply(years, function(y)
    file.path(station_dir, sprintf("%s%d%s.RP2", icao, y, c("", "US")))))
  okv <- vapply(rp2, aermet_run_succeeded, logical(1))
  chk <- c(chk, list(.qa_chk(grp, "AERMET Stage 2 finished successfully",
    if (all(okv)) "pass" else "fail",
    sprintf("%d/%d runs OK%s", sum(okv), length(okv),
            if (all(okv)) "" else paste0(" — failed: ",
              paste(basename(rp2[!okv]), collapse = ", "))))))

  # 3) no AERMET error messages; surface warning totals as info
  cnts   <- vapply(rp2, .qa_rp2_counts, numeric(2))     # 2 x n: rows "error","warning"
  errs   <- sum(cnts["error", ],   na.rm = TRUE)
  warns  <- sum(cnts["warning", ], na.rm = TRUE)
  parsed <- any(!is.na(cnts["error", ]))
  chk <- c(chk, list(.qa_chk(grp, "No AERMET error messages",
    if (!parsed) "warn" else if (errs == 0) "pass" else "fail",
    if (!parsed) "could not read RP2 message summary"
    else sprintf("%g error(s) across all runs", errs))))
  chk <- c(chk, list(.qa_chk(grp, "AERMET warnings (informational)", "info",
    sprintf("%g warning(s) — routine (e.g. calm/variable winds, substitutions)", warns))))

  # 4) output files exist, non-empty, correct start year
  bad <- character(0); nfiles <- 0
  for (y in years) for (sfx in c("", "US")) for (ext in c("sfc", "pfl")) {
    fp <- file.path(station_dir, sprintf("%s%d%s.%s", icao, y, sfx, ext))
    nfiles <- nfiles + 1
    v <- verify_file_dates(fp, y)
    if (!isTRUE(v$exists) || !isTRUE(v$valid_dates) || !file.exists(fp) || file.size(fp) == 0)
      bad <- c(bad, basename(fp))
  }
  chk <- c(chk, list(.qa_chk(grp, "AERMOD .sfc/.pfl files valid (year-checked)",
    if (length(bad) == 0) "pass" else "fail",
    if (length(bad) == 0) sprintf("all %d files present, non-empty, correct year", nfiles)
    else paste("problem files:", paste(bad, collapse = ", ")))))

  # 5) data actually flowed through (obs counts, informational)
  obs <- lapply(years, function(y)
    parse_rp2_file(file.path(station_dir, sprintf("%s%d.RP2", icao, y))))
  obs_txt <- paste(mapply(function(y, s) sprintf("%d: UA %s / sfc %s", y,
    fmt_int(s$ua_obs %||% NA), fmt_int(s$surface_obs %||% NA)), years, obs), collapse = " | ")
  any_zero <- any(vapply(obs, function(s) isTRUE((s$surface_obs %||% 0) == 0) ||
                                          isTRUE((s$ua_obs %||% 0) == 0), logical(1)))
  chk <- c(chk, list(.qa_chk(grp, "Upper-air & surface observations ingested",
    if (any_zero) "warn" else "info", obs_txt)))

  # 6) the 1-minute ASOS winds were actually USED.
  # AERMET rejects the whole AERMINUTE record if the WBAN in the hour-file header
  # does not string-match the surface WBAN (a leading-zero WBAN like 03940 arrives
  # from AERMINUTE as "3940"). It reports that as a WARNING, so the run still
  # "succeeds" while quietly falling back to standard hourly winds -- which inflates
  # calms dramatically. Only meaningful when AERMINUTE actually ran for this site.
  hour_file <- file.path(station_dir, "AERMINUTE_hour.dat")
  if (file.exists(hour_file) && file.size(hour_file) > 0) {
    a1 <- vapply(obs, function(s) as.numeric(s$asos_obs %||% NA), numeric(1))
    got <- sum(a1 > 0, na.rm = TRUE)
    mism <- unlist(lapply(years, function(y) {
      mg <- file.path(station_dir, sprintf("%s%d.MG2", icao, y))
      if (file.exists(mg)) grep("DOES NOT MATCH SURFACE WBAN", readLines(mg, warn = FALSE),
                                value = TRUE) else character(0)
    }))
    chk <- c(chk, list(.qa_chk(grp, "1-minute ASOS winds (AERMINUTE) ingested",
      if (got == length(years)) "pass" else "fail",
      if (length(mism))
        sprintf("%d/%d years used them — AERMET rejected the AERMINUTE file: %s",
                got, length(years), trimws(sub(".*(AERMINUTE WBAN.*)", "\\1", mism[1])))
      else sprintf("%d/%d years used them (%s hourly obs)", got, length(years),
                   paste(vapply(a1, fmt_int, character(1)), collapse = "/")))))
  }

  # 7) the GHCNh quality screen ran.
  # AERMET does not act on NCEI's per-element quality flags, so suspect and erroneous
  # observations otherwise reach the .sfc verbatim. Confirm the screen was applied and
  # report what it removed.
  qcl <- list.files(station_dir, pattern = "_qc_log\\.txt$", full.names = TRUE)
  if (length(qcl)) {
    lg  <- readLines(qcl[1], warn = FALSE)
    num <- function(p) {
      h <- grep(p, lg, value = TRUE)
      if (!length(h)) return(NA_integer_)
      suppressWarnings(as.integer(sub("^\\D*?(\\d+).*$", "\\1", sub(p, "", h[1]))))
    }
    chk <- c(chk, list(.qa_chk(grp, "GHCNh quality screening applied", "pass",
      sprintf("%s obs screened; %s suspect/erroneous and %s METAR-mismatch rejected",
              fmt_int(num("Records scanned\\s*:")),
              fmt_int(num("Screen 1 \\(NCEI flags\\)\\s*:")),
              fmt_int(num("Screen 2 \\(METAR check\\)\\s*:"))))))
  } else {
    chk <- c(chk, list(.qa_chk(grp, "GHCNh quality screening applied", "warn",
      "no quality-control log found -- suspect NCEI observations may have been used")))
  }

  # 8) nothing physically implausible survived into the delivered files.
  ext <- tryCatch(screen_sfc_extremes(station_dir, icao, years), error = function(e) NULL)
  if (!is.null(ext) && length(ext)) {
    nbad <- sum(vapply(ext, function(e) as.integer(e$n_ws_hi + e$n_t_out), integer(1)))
    wmax <- suppressWarnings(max(vapply(ext, function(e) e$ws_max, numeric(1)), na.rm = TRUE))
    chk <- c(chk, list(.qa_chk(grp, "Delivered .sfc physically plausible",
      if (nbad == 0) "pass" else "warn",
      sprintf("max wind %.1f m/s; %d hour(s) outside plausible bounds (ws>25 m/s, T outside -25..45 C)",
              wmax, nbad))))
  }
  chk
}

# Calendar hours in a year (AERMET writes one .sfc record per hour).
.qa_expected_hours <- function(year) {
  leap <- (year %% 4 == 0 && year %% 100 != 0) || year %% 400 == 0
  24L * (365L + as.integer(leap))
}

# Hourly records the .sfc actually carries FOR that year. (Each yearly file also
# ends with 1 January of the next year -- deliberate; those are not counted here.)
.qa_sfc_year_records <- function(sfc, year) {
  if (!file.exists(sfc)) return(NA_integer_)
  ln <- readLines(sfc, warn = FALSE)
  ln <- ln[grep("^\\s*\\d{2,4}\\s+\\d{1,2}\\s+\\d{1,2}", ln)]
  if (!length(ln)) return(NA_integer_)
  yy <- suppressWarnings(as.numeric(sub("^\\s*(\\d+).*", "\\1", ln)))
  sum(vapply(yy, function(v) isTRUE(year_matches(v, year)), logical(1)))
}

# --- Completeness (EPA 90% per quarter) ---------------------------------------
qa_completeness <- function(station_dir, icao, y1, y2) {
  grp <- "Data completeness (EPA target 90%/quarter)"
  dc <- verify_data_completeness(station_dir, icao, y1, y2)
  chk <- list(); low <- character(0)
  for (y in as.character(y1:y2)) {
    yd <- dc[[y]]
    if (is.null(yd) || !is.null(yd$error)) {
      chk <- c(chk, list(.qa_chk(grp, sprintf("%s completeness", y), "fail",
                                 yd$error %||% "no data")))
      next
    }

    # The percentages below are computed over records PRESENT in the .sfc, so a
    # block of hours AERMET never wrote would not lower them. Check the record
    # count against the calendar year so a wholesale gap cannot read as 100%.
    yi    <- as.integer(y)
    nrec  <- .qa_sfc_year_records(file.path(station_dir, sprintf("%s%d.sfc", icao, yi)), yi)
    exp_h <- .qa_expected_hours(yi)
    chk <- c(chk, list(.qa_chk(grp, sprintf("%s — every calendar hour written", y),
      if (is.na(nrec)) "warn" else if (nrec == exp_h) "pass" else "fail",
      if (is.na(nrec)) "could not read .sfc"
      else sprintf("%d of %d hourly records%s", nrec, exp_h,
                   if (nrec == exp_h) "" else sprintf(" — %d hour(s) absent from the file",
                                                      exp_h - nrec)))))
    ann <- yd$annual$completeness_pct %||% NA
    qtxt <- paste(vapply(names(yd$quarters), function(q) {
      qd <- yd$quarters[[q]]
      if (isFALSE(qd$meets_epa)) low <<- c(low, sprintf("%s %s", y, q))
      sprintf("%s %.0f%%", q, qd$completeness_pct %||% 0)
    }, character(1)), collapse = "  ")
    allq <- all(vapply(yd$quarters, function(qd) isTRUE(qd$meets_epa), logical(1)))
    chk <- c(chk, list(.qa_chk(grp, sprintf("%s — %.1f%% annual", y, ann),
      if (allq) "pass" else "warn", qtxt)))
  }
  attr(chk, "low") <- low
  chk
}

# --- Top level ----------------------------------------------------------------
qa_run <- function(station_dir, aers_dir, icao, y1, y2) {
  icao <- toupper(icao)
  checks <- c(qa_aersurface(aers_dir, icao),
              qa_aermet(station_dir, icao, y1, y2),
              qa_completeness(station_dir, icao, y1, y2))
  worst <- max(vapply(checks, function(c) .qa_status_rank[[c$status]], numeric(1)))
  overall <- c("PASS", "WARN", "FAIL")[worst + 1]

  # Human-readable summary (also written to QA_SUMMARY.txt / added to the zip)
  sym <- c(pass = "[PASS]", warn = "[WARN]", fail = "[FAIL]", info = "[info]")
  txt <- c(sprintf("QA SUMMARY -- %s  %d-%d", icao, y1, y2),
           sprintf("Overall: %s", overall),
           sprintf("Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
           strrep("-", 66))
  grp <- ""
  for (c in checks) {
    if (!identical(c$group, grp)) { grp <- c$group; txt <- c(txt, "", grp) }
    txt <- c(txt, sprintf("  %s %s%s", sym[[c$status]], c$label,
                          if (nzchar(c$detail)) sprintf("  --  %s", c$detail) else ""))
  }
  txt <- c(txt, "", strrep("-", 66),
           "PASS = check met.  WARN = review (usually data availability, not a",
           "processing error).  FAIL = do not use until resolved.",
           "EPA completeness target is 90% of hours per calendar quarter.")
  list(overall = overall, checks = checks, text = txt)
}
