# =============================================================================
# moisture.R -- auto-determine the AERSURFACE surface-moisture condition
# (DRY / AVERAGE / WET) from the site's precipitation record.
#
# Follows EPA AERSURFACE guidance: compare the modeled period's precipitation to
# the climatological record; precipitation in the wettest 30% -> WET, driest
# 30% -> DRY, middle 40% -> AVERAGE. Uses the ASOS site's own GHCN-Daily record.
# =============================================================================
suppressWarnings(suppressMessages({ library(dplyr) }))

GHCND_ACCESS <- "https://www.ncei.noaa.gov/data/global-historical-climatology-network-daily/access"

# Site annual precipitation (inches) from GHCN-Daily. Returns data.frame(year,
# precip_in, ndays); years with < 350 reporting days are flagged via ndays.
annual_precip <- function(ghcn_id, cache_dir) {
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  dest <- file.path(cache_dir, sprintf("ghcnd_%s.csv", ghcn_id))
  # ~11 MB for a long-record site: R's default 60 s download limit is not enough
  .download_cached(sprintf("%s/%s.csv", GHCND_ACCESS, ghcn_id), dest, max_age_days = 90,
                   timeout_s = 300)
  raw <- utils::read.csv(dest, colClasses = "character")
  if (!all(c("DATE", "PRCP") %in% names(raw))) return(NULL)
  d <- data.frame(
    year = suppressWarnings(as.integer(substr(raw$DATE, 1, 4))),
    prcp = suppressWarnings(as.numeric(raw$PRCP)),          # tenths of mm
    stringsAsFactors = FALSE)
  d <- d[!is.na(d$year), ]
  d %>%
    group_by(year) %>%
    summarise(precip_in = sum(prcp[!is.na(prcp)]) / 10 / 25.4,   # tenths mm -> mm -> in
              ndays = sum(!is.na(prcp)), .groups = "drop") %>%
    as.data.frame()
}

# Classify AERSURFACE surface moisture for the processing years.
# Returns list(overall, per_year(df), q30, q70, climo_years, n_climo, short_record,
# ok, note).  EPA's test is the 30th/70th percentile of the 30-year record
# (AERSURFACE User's Guide 26135, Sec. 3.2.8); a shorter record is used when that is
# all there is, but it is flagged.  When the record cannot be used at all the result
# is AVERAGE with ok = FALSE and a note saying so -- never a quiet default.
classify_moisture <- function(years, ghcn_id, cache_dir, climo_n = 30) {
  defaulted <- function(why)
    list(overall = "AVERAGE", ok = FALSE,
         note = sprintf("could not classify (%s); DEFAULTED to AVERAGE -- set surface moisture by hand", why))
  ap <- tryCatch(annual_precip(ghcn_id, cache_dir), error = function(e) e)
  if (inherits(ap, "error")) return(defaulted(conditionMessage(ap)))
  if (is.null(ap) || nrow(ap) == 0)
    return(defaulted(sprintf("GHCN-Daily file for %s has no precipitation (PRCP) data", ghcn_id)))

  complete <- ap[ap$ndays >= 350, ]
  cur_year <- as.integer(format(Sys.Date(), "%Y"))
  complete <- complete[complete$year < cur_year, ]          # drop partial current year
  if (nrow(complete) < 10)
    return(defaulted(sprintf("only %d complete precipitation year(s) at %s; at least 10 needed",
                             nrow(complete), ghcn_id)))

  climo <- tail(complete[order(complete$year), ], climo_n)   # most recent N complete years
  short <- nrow(climo) < climo_n
  q30 <- as.numeric(quantile(climo$precip_in, 0.30))
  q70 <- as.numeric(quantile(climo$precip_in, 0.70))
  cls <- function(p) if (is.na(p)) NA_character_ else if (p <= q30) "DRY" else if (p >= q70) "WET" else "AVERAGE"

  per_year <- do.call(rbind, lapply(years, function(y) {
    p <- ap$precip_in[ap$year == y]
    p <- if (length(p) == 0) NA_real_ else p[1]
    nd <- ap$ndays[ap$year == y]; nd <- if (length(nd) == 0) 0L else nd[1]
    data.frame(year = y, precip_in = round(p, 1), ndays = nd, class = cls(p),
               stringsAsFactors = FALSE)
  }))

  # single representative value for the (single) AERSURFACE run: classify the
  # period-mean annual precip against the climatological 30/70 thresholds.
  #
  # Only years with an essentially complete daily record may enter that mean: a
  # year missing months totals low for a reporting reason, not a climatic one, and
  # would drag the period toward DRY. Fall back to whatever exists if none qualify.
  have    <- per_year[!is.na(per_year$precip_in), ]
  usable  <- have[have$ndays >= 350, ]
  partial <- have$year[have$ndays < 350]
  if (nrow(usable) == 0) usable <- have
  mean_p  <- if (nrow(usable)) mean(usable$precip_in, na.rm = TRUE) else NA_real_
  overall <- cls(mean_p); if (is.na(overall)) overall <- "AVERAGE"

  note <- sprintf("%d-yr climatology %d-%d: dry<=%.1f in, wet>=%.1f in",
                  nrow(climo), min(climo$year), max(climo$year), q30, q70)
  if (short)
    note <- sprintf("%s; SHORT RECORD -- only %d complete years (EPA compares against 30)",
                    note, nrow(climo))
  if (length(partial))
    note <- sprintf("%s; incomplete precip record excluded for %s", note,
                    paste(partial, collapse = ", "))

  list(overall = overall, per_year = per_year, q30 = round(q30, 1), q70 = round(q70, 1),
       climo_years = range(climo$year), n_climo = nrow(climo), short_record = short,
       mean_p = round(mean_p, 1), ok = TRUE, partial_years = partial, note = note)
}
