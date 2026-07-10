# =============================================================================
# aersurface_runner.R -- run AERSURFACE for ANY US site with no pre-staged data.
#
# Fetches NLCD land cover / impervious / tree-canopy for the site's area on
# demand from the MRLC Web Coverage Service, normalizes the rasters into the
# exact form AERSURFACE's reader needs, writes a control file with sensible
# latitude-based season/climate defaults, and runs the bundled AERSURFACE 26135.
#
# The NLCD retrieval + normalization recipe was validated to reproduce byte-for-
# byte identical surface characteristics vs. the regional-tile workflow.  Two
# gotchas handled here:
#   1) MRLC returns TILED GeoTIFFs; AERSURFACE needs STRIPPED -> rewrite w/ terra.
#   2) MRLC flags NoData=0 on impervious & canopy, nulling valid 0% cells ->
#      restore NA to 0 for those two products (land cover keeps its values).
# =============================================================================
suppressWarnings(suppressMessages({ library(httr); library(terra) }))

if (!exists("%||%")) `%||%` <- function(a, b) if (is.null(a)) b else a

MRLC_WCS <- "https://www.mrlc.gov/geoserver/mrlc_download/wcs"

# NLCD coverage ids by product (2021 release -- the current CONUS NLCD)
.nlcd_coverage <- function(product) {
  switch(product,
    landcover  = "mrlc_download__NLCD_2021_Land_Cover_L48",
    impervious = "mrlc_download__NLCD_2021_Impervious_L48",
    canopy     = "mrlc_download__nlcd_tcc_conus_2021_v2021-4",
    stop("unknown product"))
}

# site lon/lat (NAD83) -> NLCD Albers (EPSG:5070) x/y metres
.to_albers <- function(lat, lon) {
  p <- terra::project(terra::vect(cbind(lon, lat), crs = "EPSG:4269"), "EPSG:5070")
  as.numeric(terra::crds(p))
}

# One WCS GetCoverage clip -> GeoTIFF on disk
.wcs_clip <- function(product, xmin, xmax, ymin, ymax, dest, timeout_s = 300) {
  url <- sprintf(paste0("%s?service=WCS&version=2.0.1&request=GetCoverage",
                        "&coverageId=%s&format=image/geotiff",
                        "&subset=X(%d,%d)&subset=Y(%d,%d)"),
                 MRLC_WCS, .nlcd_coverage(product),
                 as.integer(xmin), as.integer(xmax),
                 as.integer(ymin), as.integer(ymax))
  r <- httr::GET(url, httr::timeout(timeout_s), httr::write_disk(dest, overwrite = TRUE))
  if (httr::status_code(r) != 200 || !file.exists(dest) || file.info(dest)$size < 1000)
    stop(sprintf("NLCD %s fetch failed (HTTP %s)", product, httr::status_code(r)))
  dest
}

# Normalize a fetched clip to what AERSURFACE expects: stripped, uncompressed,
# Byte; restore 0s (fill_zero) for impervious/canopy.
# CRITICAL: assign the Albers projection as an EXPLICIT-parameter WKT (crs_wkt),
# NOT "EPSG:5070".  AERSURFACE's minimal GeoTIFF reader cannot resolve an EPSG
# code -- given one it falls into an interactive prompt for the standard
# parallels and hangs.  The explicit WKT writes user-defined projection geokeys
# (gdal reports code = NA) which AERSURFACE reads directly.
.normalize <- function(src, dst, fill_zero, crs_wkt) {
  r <- terra::rast(src)
  terra::crs(r) <- crs_wkt
  if (fill_zero) r[is.na(r)] <- 0
  terra::writeRaster(r, dst, datatype = "INT1U", NAflag = 255,
                     gdal = c("COMPRESS=NONE", "TILED=NO"), overwrite = TRUE)
  dst
}

# Latitude-based season month assignments (each 1-12 used exactly once).
season_defaults <- function(lat) {
  lat <- abs(lat)
  if (lat < 34)       list(winter = c(12,1),       spring = c(2,3,4),  summer = 5:9,   autumn = c(10,11))
  else if (lat < 40)  list(winter = c(12,1,2),     spring = c(3,4),    summer = 5:9,   autumn = c(10,11))
  else if (lat < 45)  list(winter = c(12,1,2,3),   spring = c(4,5),    summer = 6:8,   autumn = c(9,10,11))
  else                list(winter = c(11,12,1,2,3),spring = c(4,5),    summer = 6:8,   autumn = c(9,10))
}

# Default AERSURFACE options for a site (user may override the moisture/snow/arid).
default_aersurface_opts <- function(lat) {
  list(moisture = "AVERAGE",           # DRY | AVERAGE | WET
       snow     = (abs(lat) >= 45),    # continuous winter snow?
       arid     = FALSE,               # arid climate?
       airport  = TRUE,                # treat the site sector as an airport
       zoradius = 1.0,                 # roughness radius (km)
       nlcd_year = 2021)
}

# Build the AERSURFACE control file text.
.build_control <- function(icao, name, lat, lon, opts, sfc_name, sectors) {
  s <- season_defaults(lat)
  mon <- function(v) paste(v, collapse = " ")
  clim <- sprintf("CLIMATE %s %s %s", toupper(opts$moisture),
                  if (isTRUE(opts$snow)) "SNOW" else "NOSNOW",
                  if (isTRUE(opts$arid)) "ARID" else "NONARID")
  winter_kw <- if (isTRUE(opts$snow)) "WINTERSN" else "WINTERNS"
  freq <- sprintf("FREQ_SECT MONTHLY %d VARYAP", nrow(sectors))
  sect_lines <- sprintf("   SECTOR %d %.1f %.1f %s", seq_len(nrow(sectors)),
                        sectors$start, sectors$end, sectors$type)
  yr <- opts$nlcd_year
  c("CO STARTING",
    sprintf("   TITLEONE AERSURFACE (on-demand NLCD) for %s", icao),
    sprintf("   TITLETWO NLCD%d, %s", yr, name),
    "   OPTIONS PRIMARY ZORAD",
    "   DEBUGOPT GRID",
    sprintf("   CENTERLL %.6f %.6f NAD83", lat, lon),
    sprintf('   DATAFILE NLCD%d "input/landcover.tif"',  yr),
    sprintf('   DATAFILE CNPY%d "input/canopy.tif"',     yr),
    sprintf('   DATAFILE MPRV%d "input/impervious.tif"', yr),
    sprintf("   ZORADIUS %.1f", opts$zoradius),
    sprintf("   %s", clim),
    sprintf("   %s", freq),
    sect_lines,
    sprintf("   SEASON %s %s", winter_kw, mon(s$winter)),
    sprintf("   SEASON SPRING %s", mon(s$spring)),
    sprintf("   SEASON SUMMER %s", mon(s$summer)),
    sprintf("   SEASON AUTUMN %s", mon(s$autumn)),
    "   RUNORNOT RUN",
    "CO FINISHED",
    "OU STARTING",
    sprintf('   SFCCHAR "%s"', sfc_name),
    '   NLCDGRID "aers_lc_grid.txt"',
    "OU FINISHED")
}

# OS tag used to pick the right bundled binary: "windows" | "macos" | "linux"
os_tag <- function() {
  s <- Sys.info()[["sysname"]]
  if (identical(s, "Windows")) "windows" else if (identical(s, "Darwin")) "macos" else "linux"
}

# Candidate binary paths for a tool on the current OS (first existing wins).
# Windows -> <tool>_26135.exe ; macOS -> <tool>_26135_mac ; Linux -> <tool>_26135_linux
bin_candidates <- function(app_root, tool) {
  b <- file.path(app_root, "bin")
  switch(os_tag(),
    windows = file.path(b, sprintf("%s_26135.exe", tool)),
    macos   = c(file.path(b, sprintf("%s_26135_mac", tool)),   file.path(b, tool)),
    linux   = c(file.path(b, sprintf("%s_26135_linux", tool)), file.path(b, tool)))
}

# Locate the AERSURFACE binary bundled in bin/ (Linux users must supply theirs).
.aersurface_exe <- function(app_root) {
  for (p in bin_candidates(app_root, "aersurface")) if (file.exists(p)) return(normalizePath(p))
  stop(sprintf(paste0("AERSURFACE binary not found in %s/bin for %s.\n",
       "Linux users: compile AERSURFACE 26135 from EPA source and place it as ",
       "bin/aersurface_26135_linux."), app_root, os_tag()))
}

# Compact signature of every input that changes the surface characteristics.
# If it matches a previous run's, AERSURFACE can be skipped entirely (the .sfc is
# reused as-is). Note: moisture must already be resolved to DRY/AVERAGE/WET here
# (the pipeline resolves AUTO before this), so an AUTO->WET run and an explicit
# WET run share a signature and reuse, while WET->DRY differs and re-runs.
.aers_signature <- function(lat, lon, opts, sectors) {
  sec <- paste(sprintf("%.1f-%.1f:%s", sectors$start, sectors$end, sectors$type), collapse = ",")
  sprintf("v1|ll=%.5f,%.5f|moist=%s|snow=%s|arid=%s|zorad=%.2f|nlcd=%s|sect=%s",
          lat, lon, toupper(opts$moisture %||% "AVERAGE"),
          isTRUE(opts$snow), isTRUE(opts$arid), as.numeric(opts$zoradius %||% 1.0),
          as.character(opts$nlcd_year %||% 2021), sec)
}

# True when all given rasters exist and look non-empty.
.have_tifs <- function(paths) all(file.exists(paths)) && all(file.info(paths)$size > 1000)

# Main entry: run AERSURFACE for a site, return the full path to the .sfc file.
# Reuses work across runs so a re-run with a different moisture (or an identical
# re-run) never re-fetches NLCD:
#   * settings unchanged  -> skip AERSURFACE entirely, reuse the existing .sfc
#   * settings changed     -> re-run, but reuse the NLCD clips (run folder, then
#                             a site-level cache) rather than re-downloading them
# progress(msg, frac) is an optional callback for the Shiny progress bar.
run_aersurface <- function(icao, name, lat, lon, aers_dir, app_root,
                           opts = NULL, nlcd_cache_dir = NULL,
                           progress = function(m, f) {}) {
  if (is.null(opts)) opts <- default_aersurface_opts(lat)
  input_dir <- file.path(aers_dir, "input")
  dir.create(input_dir, recursive = TRUE, showWarnings = FALSE)

  sfc_name <- sprintf("%s_aers_sfc.txt", tolower(icao))
  sfc      <- file.path(aers_dir, sfc_name)
  sig_file <- file.path(aers_dir, ".aers_signature")

  # Sectors first -- cheap and needed for the signature (no network).
  # User override wins; else derive AP/NONAP from runway geometry
  # (single 0-360 NONAP if the site is marked non-airport).
  progress("Deriving airport sectors ...", 0.30)
  runways_csv <- file.path(app_root, "data", "ourairports_runways.csv")
  sectors <- if (!is.null(opts$sectors) && nrow(opts$sectors) > 0) opts$sectors
    else if (isTRUE(opts$airport)) derive_sectors(icao, lat, lon, runways_csv, default_type = "AP")
    else data.frame(start = 0, end = 360, type = "NONAP", stringsAsFactors = FALSE)

  # Reuse #1: a previous run produced this .sfc with identical settings -> skip
  # the NLCD fetch and the AERSURFACE run altogether.
  sig <- .aers_signature(lat, lon, opts, sectors)
  if (file.exists(sfc) && file.info(sfc)$size > 0 && file.exists(sig_file) &&
      identical(readLines(sig_file, warn = FALSE)[1], sig)) {
    progress("Reusing existing AERSURFACE output (settings unchanged) ...", 0.34)
    cat(sprintf("AERSURFACE reuse for %s: settings unchanged, skipping NLCD + run\n", icao))
    return(normalizePath(sfc))
  }

  cat(sprintf("AERSURFACE sectors for %s: %s\n", icao,
              paste(sprintf("%.0f-%.0f:%s", sectors$start, sectors$end, sectors$type),
                    collapse = "  ")))

  # NLCD clips: reuse if already normalized in the run folder, else pull from the
  # site-level cache, else fetch from MRLC + normalize (and populate the cache).
  dst_lc  <- file.path(input_dir, "landcover.tif")
  dst_imp <- file.path(input_dir, "impervious.tif")
  dst_can <- file.path(input_dir, "canopy.tif")
  input_tifs <- c(dst_lc, dst_imp, dst_can)
  cache_tifs <- if (!is.null(nlcd_cache_dir))
    file.path(nlcd_cache_dir, c("landcover.tif", "impervious.tif", "canopy.tif")) else NULL

  if (.have_tifs(input_tifs)) {
    progress("Reusing NLCD clips already in the run folder ...", 0.26)
  } else if (!is.null(cache_tifs) && .have_tifs(cache_tifs)) {
    progress("Reusing cached NLCD for this site ...", 0.26)
    file.copy(cache_tifs, input_tifs, overwrite = TRUE)
  } else {
    # 30 km AOI (site +/- 15 km), snapped to the 30 m NLCD grid
    xy <- .to_albers(lat, lon); half <- 15000
    snap <- function(v) round(v / 30) * 30
    xmin <- snap(xy[1] - half); xmax <- snap(xy[1] + half)
    ymin <- snap(xy[2] - half); ymax <- snap(xy[2] + half)

    progress("Fetching NLCD land cover ...", 0.10)
    lc  <- .wcs_clip("landcover",  xmin, xmax, ymin, ymax, file.path(aers_dir, "_lc.tif"))
    progress("Fetching NLCD impervious ...", 0.16)
    imp <- .wcs_clip("impervious", xmin, xmax, ymin, ymax, file.path(aers_dir, "_imp.tif"))
    progress("Fetching NLCD tree canopy ...", 0.22)
    can <- .wcs_clip("canopy",     xmin, xmax, ymin, ymax, file.path(aers_dir, "_can.tif"))

    progress("Normalizing NLCD rasters ...", 0.26)
    wkt_file <- file.path(app_root, "backend", "nlcd_albers.wkt")
    if (!file.exists(wkt_file)) stop("Missing projection file backend/nlcd_albers.wkt")
    crs_wkt <- paste(readLines(wkt_file, warn = FALSE), collapse = "\n")
    .normalize(lc,  dst_lc,  fill_zero = FALSE, crs_wkt)
    .normalize(imp, dst_imp, fill_zero = TRUE,  crs_wkt)
    .normalize(can, dst_can, fill_zero = TRUE,  crs_wkt)
    unlink(c(lc, imp, can))

    # Populate the site-level NLCD cache so other windows / moisture re-runs reuse it.
    if (!is.null(cache_tifs)) {
      dir.create(nlcd_cache_dir, recursive = TRUE, showWarnings = FALSE)
      file.copy(input_tifs, cache_tifs, overwrite = TRUE)
    }
  }

  # binary + datum files into the run dir
  exe_src <- .aersurface_exe(app_root)
  exe_local <- file.path(aers_dir, basename(exe_src))
  file.copy(exe_src, exe_local, overwrite = TRUE)
  if (.Platform$OS.type != "windows") Sys.chmod(exe_local, "0755")
  exe_abs <- normalizePath(exe_local)          # absolute: system2 needs a path, not a bare name
  for (d in list.files(file.path(app_root, "bin"), pattern = "\\.(las|los)$", full.names = TRUE))
    file.copy(d, file.path(aers_dir, basename(d)), overwrite = TRUE)

  inp <- file.path(aers_dir, sprintf("%s_aersurface.inp", tolower(icao)))
  writeLines(.build_control(icao, name, lat, lon, opts, sfc_name, sectors), inp)

  progress("Running AERSURFACE ...", 0.32)
  old <- getwd(); on.exit(setwd(old))
  setwd(aers_dir)
  # timeout guards against a hang if the projection is ever unreadable
  system2(exe_abs, args = basename(inp), stdout = "aersurface_stdout.txt",
          stderr = "aersurface_stderr.txt", timeout = 600)
  setwd(old)

  if (!file.exists(sfc) || file.info(sfc)$size == 0)
    stop("AERSURFACE did not produce a surface-characteristics file (check aers_dir logs).")
  writeLines(sig, sig_file)      # record settings so an identical re-run can skip
  normalizePath(sfc)
}
