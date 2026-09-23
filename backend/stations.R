# =============================================================================
# stations.R -- resolve any US ASOS station to the metadata the pipeline needs
# and pair it with the nearest active upper-air (IGRA) sounding site.
#
# Sources (cached under cache/):
#   * NCEI ISD-history CSV  -> surface station id (USAF-WBAN), GHCNh id, lat/lon
#   * NCEI IGRA2 station list -> radiosonde sites for the upper-air pairing
# =============================================================================
suppressWarnings(suppressMessages({
  library(httr); library(readr); library(dplyr); library(stringr)
}))

ISD_HISTORY_URL  <- "https://www.ncei.noaa.gov/pub/data/noaa/isd-history.csv"
IGRA_STATION_URL <- "https://www.ncei.noaa.gov/pub/data/igra/igra2-station-list.txt"

# Documented IGRA2 station-list layout (gapped fixed width -- NOT consecutive)
IGRA_FWF <- readr::fwf_positions(
  start = c(1, 13, 22, 32, 39, 42, 73, 78, 83),
  end   = c(11, 20, 30, 37, 40, 71, 76, 81, 88),
  col_names = c("IGRA_ID", "LAT", "LON", "ELEV", "STATE", "STATION_NAME",
                "FIRST_YEAR", "LAST_YEAR", "NUM_RECORDS"))

.download_cached <- function(url, dest, max_age_days = 30, timeout_s = 120) {
  if (file.exists(dest) &&
      difftime(Sys.time(), file.info(dest)$mtime, units = "days") < max_age_days &&
      file.info(dest)$size > 0) return(dest)
  old <- options(timeout = max(timeout_s, getOption("timeout"))); on.exit(options(old))
  err <- character(0)                      # keep the reason, so callers can report it
  ok <- tryCatch(withCallingHandlers(
          { utils::download.file(url, dest, mode = "wb", quiet = TRUE); TRUE },
          warning = function(w) { err <<- c(err, conditionMessage(w)); invokeRestart("muffleWarning") }),
        error = function(e) { err <<- c(err, conditionMessage(e)); FALSE })
  if (!ok || !file.exists(dest) || file.info(dest)$size == 0)
    stop(sprintf("Download failed: %s%s", url,
                 if (length(err)) paste0(" (", paste(unique(err), collapse = "; "), ")") else ""))
  dest
}

# ---- Surface ASOS stations (active US, with a valid WBAN) --------------------
load_surface_stations <- function(cache_dir = "cache") {
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  f <- .download_cached(ISD_HISTORY_URL, file.path(cache_dir, "isd-history.csv"))
  cur <- as.integer(format(Sys.Date(), "%Y"))
  df <- suppressWarnings(readr::read_csv(f, col_types = readr::cols(.default = "c"),
                                         progress = FALSE, show_col_types = FALSE))
  names(df) <- toupper(gsub("[^A-Za-z0-9]", "_", names(df)))
  df %>%
    mutate(ICAO = str_trim(ICAO), WBAN = str_trim(WBAN), USAF = str_trim(USAF),
           STATE = str_trim(STATE), CTRY = str_trim(CTRY),
           STATION_NAME = str_trim(STATION_NAME),
           LAT = suppressWarnings(as.numeric(LAT)),
           LON = suppressWarnings(as.numeric(LON)),
           END_YR = suppressWarnings(as.integer(substr(END, 1, 4)))) %>%
    filter(CTRY == "US", !is.na(ICAO), nchar(ICAO) == 4,
           !is.na(WBAN), WBAN != "", WBAN != "99999",
           !is.na(STATE), STATE != "",
           !is.na(LAT), !is.na(LON), !(LAT == 0 & LON == 0),
           !is.na(END_YR), END_YR >= (cur - 2)) %>%
    arrange(ICAO, desc(END_YR)) %>% distinct(ICAO, .keep_all = TRUE) %>%
    transmute(ICAO,
              WBAN     = str_pad(WBAN, 5, "left", "0"),
              USAF     = str_pad(USAF, 6, "left", "0"),
              STATION_ID = paste0(str_pad(USAF, 6, "left", "0"), "-",
                                  str_pad(WBAN, 5, "left", "0")),
              GHCNH_ID = paste0("USW000", str_pad(WBAN, 5, "left", "0")),
              STATE, STATION_NAME, LAT, LON) %>%
    arrange(STATE, ICAO)
}

# ---- Upper-air IGRA sites (active US) ----------------------------------------
load_igra_stations <- function(cache_dir = "cache") {
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  f <- .download_cached(IGRA_STATION_URL, file.path(cache_dir, "igra2-station-list.txt"))
  cur <- as.integer(format(Sys.Date(), "%Y"))
  suppressWarnings(readr::read_fwf(f, IGRA_FWF, col_types = readr::cols(.default = "c"),
                                   progress = FALSE)) %>%
    mutate(IGRA_ID = str_trim(IGRA_ID), STATE = str_trim(STATE),
           STATION_NAME = str_trim(STATION_NAME),
           LAT = suppressWarnings(as.numeric(LAT)),
           LON = suppressWarnings(as.numeric(LON)),
           LAST_YEAR = suppressWarnings(as.integer(LAST_YEAR))) %>%
    filter(substr(IGRA_ID, 1, 2) == "US", !is.na(LAT), !is.na(LON),
           !is.na(LAST_YEAR), LAST_YEAR >= (cur - 2)) %>%
    transmute(IGRA_ID, STATE, STATION_NAME, LAT, LON) %>%
    distinct(IGRA_ID, .keep_all = TRUE)
}

# Great-circle distance (km)
.haversine_km <- function(lat1, lon1, lat2, lon2) {
  R <- 6371; d2r <- pi / 180
  dlat <- (lat2 - lat1) * d2r; dlon <- (lon2 - lon1) * d2r
  a <- sin(dlat / 2)^2 + cos(lat1 * d2r) * cos(lat2 * d2r) * sin(dlon / 2)^2
  2 * R * asin(pmin(1, sqrt(a)))
}

# Nearest active IGRA sounding site to a point
nearest_igra <- function(lat, lon, igra_df) {
  d <- .haversine_km(lat, lon, igra_df$LAT, igra_df$LON)
  i <- which.min(d)
  list(igra_id = igra_df$IGRA_ID[i], name = igra_df$STATION_NAME[i],
       lat = igra_df$LAT[i], lon = igra_df$LON[i], dist_km = round(d[i], 1))
}

# Resolve everything the pipeline needs for one ICAO
resolve_station <- function(icao, surf_df, igra_df) {
  icao <- toupper(icao)
  s <- surf_df[surf_df$ICAO == icao, ]
  if (nrow(s) == 0) stop(sprintf("ICAO %s not found among active US ASOS stations", icao))
  s <- s[1, ]
  ua <- nearest_igra(s$LAT, s$LON, igra_df)
  list(icao = icao, station_id = s$STATION_ID, wban = s$WBAN, usaf = s$USAF,
       ghcnh_id = s$GHCNH_ID, state = s$STATE, name = s$STATION_NAME,
       lat = s$LAT, lon = s$LON,
       ua_station_id = ua$igra_id, ua_name = ua$name, ua_dist_km = ua$dist_km)
}
