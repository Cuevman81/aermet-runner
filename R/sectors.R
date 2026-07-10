# =============================================================================
# sectors.R -- derive AERSURFACE airport (AP) vs non-airport (NONAP) sectors
# from real runway geometry, so the surface roughness is computed with the
# correct airport designation per wind direction.
#
# Method (ported from the MDEQ AERSURFACE_DeriveSectors workflow):
#   * airfield footprint = buffered convex hull of the airport's runway endpoints
#     (from the bundled OurAirports runways table), centred on the ASOS tower;
#   * for each 10-degree wedge out to the 1 km roughness radius, mark AP if
#     >= AP_FRAC of the wedge area lies inside the airfield, else NONAP;
#   * merge adjacent like sectors, wrap 0/360, enforce a 30-degree minimum width.
# Falls back to a single 0-360 sector when no runway geometry is available.
# =============================================================================
suppressWarnings(suppressMessages(library(terra)))

SECTOR_RADIUS_M <- 1000
SECTOR_STEP     <- 10
HULL_BUFFER_M   <- 300
AP_FRAC         <- 0.25
MIN_WIDTH_DEG   <- 30

.norm360 <- function(a) a %% 360

# Read runway endpoints for an ICAO from the bundled OurAirports table.
.runway_points <- function(icao, runways_csv) {
  if (!file.exists(runways_csv)) return(NULL)
  rw <- utils::read.csv(runways_csv, stringsAsFactors = FALSE)
  rw <- rw[toupper(trimws(rw$airport_ident)) == toupper(icao), ]
  rw <- rw[!is.na(rw$le_latitude_deg) & !is.na(rw$he_latitude_deg) &
           !is.na(rw$le_longitude_deg) & !is.na(rw$he_longitude_deg), ]
  if (nrow(rw) == 0) return(NULL)
  rbind(data.frame(lon = rw$le_longitude_deg, lat = rw$le_latitude_deg),
        data.frame(lon = rw$he_longitude_deg, lat = rw$he_latitude_deg))
}

# Derive AP/NONAP sectors. Returns data.frame(start, end, type) or a single
# 0-360 sector (type = default_type) when runway geometry is unavailable.
derive_sectors <- function(icao, tower_lat, tower_lon, runways_csv,
                           default_type = "AP") {
  pts <- tryCatch(.runway_points(icao, runways_csv), error = function(e) NULL)
  if (is.null(pts) || nrow(pts) < 2)
    return(data.frame(start = 0, end = 360, type = default_type, stringsAsFactors = FALSE))

  aeqd <- sprintf("+proj=aeqd +lat_0=%f +lon_0=%f +x_0=0 +y_0=0 +datum=WGS84 +units=m",
                  tower_lat, tower_lon)
  sp <- terra::project(terra::vect(as.matrix(pts[, c("lon", "lat")]),
                                   type = "points", crs = "EPSG:4326"), aeqd)
  foot <- tryCatch(terra::buffer(terra::convHull(sp), HULL_BUFFER_M),
                   error = function(e) terra::buffer(sp, HULL_BUFFER_M))
  foot <- terra::aggregate(foot)

  ang <- seq(0, 360 - SECTOR_STEP, by = SECTOR_STEP)
  fr <- vapply(ang, function(a) {
    th <- seq(a, a + SECTOR_STEP, length.out = 8) * pi / 180
    poly <- rbind(c(0, 0),
                  cbind(SECTOR_RADIUS_M * sin(th), SECTOR_RADIUS_M * cos(th)),
                  c(0, 0))                                 # compass: x=E=sin, y=N=cos
    wedge <- terra::vect(list(poly), type = "polygons", crs = aeqd)
    inter <- tryCatch(terra::intersect(wedge, foot), error = function(e) NULL)
    if (is.null(inter) || nrow(inter) == 0) return(0)
    as.numeric(terra::expanse(inter)) / as.numeric(terra::expanse(wedge))
  }, numeric(1))

  types <- ifelse(fr >= AP_FRAC, "AP", "NONAP")
  n <- length(types)
  if (length(unique(types)) == 1)
    return(data.frame(start = 0, end = 360, type = types[1], stringsAsFactors = FALSE))

  # merge consecutive like wedges
  bounds <- NULL; cur <- types[1]; s0 <- 0
  for (k in 2:n) if (types[k] != cur) {
    bounds <- rbind(bounds, data.frame(start = s0, end = (k - 1) * SECTOR_STEP, type = cur))
    s0 <- (k - 1) * SECTOR_STEP; cur <- types[k]
  }
  bounds <- rbind(bounds, data.frame(start = s0, end = 360, type = cur))
  # wrap-merge first/last if same type
  if (nrow(bounds) > 1 && bounds$type[1] == bounds$type[nrow(bounds)]) {
    bounds$start[1] <- bounds$start[nrow(bounds)]
    bounds <- bounds[-nrow(bounds), , drop = FALSE]
  }
  # enforce minimum width: absorb a too-narrow sector into the previous one
  changed <- TRUE
  while (changed && nrow(bounds) > 1) {
    changed <- FALSE
    w <- .norm360(bounds$end - bounds$start); w[w == 0] <- 360
    j <- which(w < MIN_WIDTH_DEG)[1]
    if (!is.na(j)) {
      prev <- if (j == 1) nrow(bounds) else j - 1
      bounds$end[prev] <- bounds$end[j]
      bounds <- bounds[-j, , drop = FALSE]; changed <- TRUE
    }
  }
  rownames(bounds) <- NULL
  bounds$type <- toupper(bounds$type)
  bounds
}
