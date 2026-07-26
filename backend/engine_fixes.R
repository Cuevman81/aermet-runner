# =============================================================================
# engine_fixes.R -- corrections layered on top of the bundled engine (engine.R).
#
# engine.R is a verbatim copy of the MDEQ AERMET.R production script so it can be
# re-synced wholesale when that script changes.  This file wraps the helpers whose
# defects reached user-facing output, keeping the bundle pristine and the
# corrections reviewable in one spot.
#
# STATUS: both fixes were also applied upstream in the production AERMET.R on
# 2026-07-26, and engine.R has been re-synced from it -- so these wrappers are
# currently redundant.  They are kept deliberately: both are idempotent (re-parsing
# yields the same numbers; de-duplicating an already-unique table is a no-op), so
# they cost nothing, and they stop an older or un-patched AERMET.R from silently
# reintroducing either defect the next time engine.R is re-synced.
#
# Must be sourced AFTER engine.R (see bootstrap.R).
# =============================================================================

if (!exists("parse_rp2_file") || !exists("read_sfc_data"))
  stop("engine_fixes.R must be sourced after engine.R")

# --- 1) RP2 counts the engine's regex misses ----------------------------------
# The engine's num_after() extracts with "\\D*(\\d+)\\s*$", which only matches when
# the line ENDS in the number.  AERMET writes
#
#     ERROR MESSAGES        0 MESSAGES
#
# so the trailing word defeats the anchor and error_count / warning_count come back
# NA -- which printed as "Errors: NA | Warnings: NA" in the verification report
# shipped to end users.  Separately the PBL block is scanned only 12 lines deep,
# one line short of the TEMPERATURE substitution line, so temp_subs was also NA.
# Grab the first integer that follows the label instead, and widen the PBL window.
.rp2_first_int_after <- function(pattern, lines) {
  hit <- grep(pattern, lines, value = TRUE)
  if (!length(hit)) return(NA_real_)
  m <- regmatches(hit[1], regexec(paste0(pattern, "\\D*?(\\d+)"), hit[1]))[[1]]
  if (length(m) >= 2) as.numeric(m[2]) else NA_real_
}

.engine_parse_rp2_file <- parse_rp2_file
parse_rp2_file <- function(rp2_file) {
  stats <- .engine_parse_rp2_file(rp2_file)
  if (is.null(stats)) return(NULL)
  content <- readLines(rp2_file, warn = FALSE)

  msg_start <- grep("MESSAGE SUMMARY", content)
  if (length(msg_start)) {
    msg <- content[(msg_start[1] + 1):length(content)]
    stats$error_count   <- .rp2_first_int_after("ERROR MESSAGES",   msg)
    stats$warning_count <- .rp2_first_int_after("WARNING MESSAGES", msg)
  }
  pbl_start <- grep("PBL PROCESSING SUMMARY", content)
  if (length(pbl_start)) {
    pbl <- content[(pbl_start[1] + 1):min(pbl_start[1] + 25, length(content))]
    stats$cloud_cover_subs <- .rp2_first_int_after("SUBSTITUTIONS.*CLOUD COVER:", pbl)
    stats$temp_subs        <- .rp2_first_int_after("SUBSTITUTIONS.*TEMPERATURE:", pbl)
  }
  stats
}

# --- 2) duplicate hours across adjacent yearly .sfc files ---------------------
# AERMET is driven with XDATES <y>/01/01 TO <y+1>/01/01, so every yearly .sfc ends
# with the 24 hours of 1 January of the FOLLOWING year.  That is deliberate and
# matches MDEQ production output byte for byte -- it is not changed here.
#
# But read_sfc_data() rbinds the yearly files for the met report, so for every year
# after the first, 1 January arrived twice: KBHM 2024 reported 8802 "valid hrs"
# against a 8784-hour year, and that day was double-weighted in the wind rose,
# means and precipitation total.  Keep the first record for each timestamp.
.engine_read_sfc_data <- read_sfc_data
read_sfc_data <- function(...) {
  d <- .engine_read_sfc_data(...)
  if (is.null(d) || !nrow(d)) return(d)
  d[!duplicated(d[, c("year", "month", "day", "hour")]), , drop = FALSE]
}
