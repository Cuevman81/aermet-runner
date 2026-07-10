# AERMET Runner

Build an **AERMOD-ready meteorological data set for any active US ASOS station**
from a single R Shiny app. Pick a station and a 1–5 year window; the app runs
**AERSURFACE** and **AERMET/AERMINUTE** end to end and drops the results into a
clean folder with a completeness report and a zip.

It is designed to be **cloned and run locally** by any state's air-modeling
program — no pre-staged land cover, no manual control files.

---

## What it does

For the station and years you choose, the app automatically:

1. **Resolves the station** — surface id (USAF-WBAN) and GHCNh id from the NCEI
   ISD-history list, and pairs it with the **nearest active IGRA** radiosonde
   site for upper air.
2. **Runs AERSURFACE** — fetches **NLCD** land cover, impervious, and tree-canopy
   for the site *on demand* from the MRLC Web Coverage Service (no bundled land
   cover), derives **airport (AP) vs non-airport (NONAP) sectors** from real
   runway geometry, writes a control file with latitude-based season/climate
   defaults, and runs AERSURFACE 26135.
3. **Gathers the met data** — GHCNh hourly surface (`.psv`), 1-minute & 5-minute
   ASOS winds (for AERMINUTE), and IGRA upper-air soundings.
4. **Runs AERMET** — builds the Stage 1 and Stage 2 control files and runs
   AERMINUTE + AERMET 26135.
5. **Packages the output** — the AERMOD-ready `.sfc`/`.pfl`, a data-completeness
   report, and a zip, in a per-run folder.

The heavy lifting reuses the tested MDEQ AERMET/AERMINUTE engine unchanged; only
the station resolution and the on-demand AERSURFACE step are added on top.

---

## Requirements

- **R** (4.1+). Install packages once:
  ```r
  Rscript install_deps.R      # shiny, leaflet, httr, readr, dplyr, stringr, terra
  ```
- **Internet** — NCEI (GHCNh/ASOS/IGRA/ISD), MRLC (NLCD).
- **The bundled binaries** in `bin/` — EPA **AERMET / AERMINUTE / AERSURFACE
  26135** for Windows and macOS, plus the AERSURFACE datum files. These are
  public-domain EPA releases, shipped so the tool is clone-and-run. *(Linux
  users: drop in Linux builds named `aermet_26135`, `aerminute_26135`,
  `aersurface_26135_mac`→`aersurface` per your build, or compile from EPA source.)*

## Run it

```r
# from the repo folder
shiny::runApp()
```
or open `app.R` in RStudio and click **Run App**. Pick a state → station (map or
dropdown) → year range → options → **Build met data**.

You can also run it headless:
```r
APP_ROOT <- normalizePath(".")
source(file.path(APP_ROOT, "backend", "bootstrap.R"))
res <- run_full_pipeline("KJAN", 2020, 2024, output_root = "runs")
```

---

## Output

```
runs/<ICAO>_<y1>_<y2>/
  <ICAO>/                     # AERMET working + output files (.sfc, .pfl, report, zip)
    aersurface/               # NLCD clips, control file, AERSURFACE outputs
  cache/                      # station lists (reused between runs)
```

## AERSURFACE options

The app exposes the site-dependent AERSURFACE inputs, defaulted sensibly:

- **Surface moisture** — Average / Dry / Wet.
- **Continuous winter snow** — off by default (auto-on above ~45°N).
- **Arid climate** — off by default.
- **Airport site** — on by default (ASOS stations are at airports).

Season month assignments are chosen by latitude. These defaults follow AERSURFACE
guidance but reflect regional judgment — review them for your site if it sits
near a climate boundary.

### Airport (AP) vs non-airport (NONAP) sectors

Rather than treating the whole domain as an airport, the tool derives the
airport designation **per wind direction** from real **runway geometry**
(bundled OurAirports data): it builds the airfield footprint (buffered convex
hull of the runway endpoints) around the ASOS tower and marks each 10° wedge
**AP** if enough of it overlaps the airfield within the 1 km roughness radius,
else **NONAP**. Inland fields come out all-AP (e.g. Jackson `0-360 AP`); coastal
or partial fields split (e.g. Gulfport ≈ `300-150 AP / 150-300 NONAP`, with the
over-water directions NONAP). The **station's coordinate precision matters** here
— the tool uses the NCEI ISD-history location; if it looks off for your site,
use the **Sectors override** box (`start end type; …`, e.g.
`300 150 AP; 150 300 NONAP`) to set them explicitly.

---

## How the NLCD fetch works (and a gotcha)

Land cover is pulled per-site (a 30 km box) from the MRLC WCS as ~1 MB GeoTIFF
clips, then normalized so AERSURFACE can read them. Two things must be corrected
in that normalization (handled automatically): MRLC returns **tiled** GeoTIFFs
(AERSURFACE needs **stripped**), and it flags **NoData=0** on impervious/canopy
(where 0% is a *valid* value, so those zeros are restored). With that, the output
surface characteristics match the regional-tile workflow byte-for-byte.

## Data sources

| Data | Source |
|------|--------|
| Surface station metadata | NCEI `isd-history.csv` |
| Surface obs (hourly) | NCEI **GHCNh** |
| Winds (1-min/5-min) | NCEI **ASOS** → AERMINUTE |
| Upper air | NCEI **IGRA2** |
| Land cover / impervious / canopy | **MRLC** NLCD (WCS) |
| Processing engine | EPA **AERMET / AERMINUTE / AERSURFACE 26135** |

## Notes & limits

- A run downloads a few hundred MB (mostly the IGRA period-of-record) and takes
  several minutes; the app is single-user and processes synchronously.
- Upper-air pairing uses the **nearest active** IGRA site — in radiosonde-sparse
  regions that can be a few hundred km; confirm it suits your application.
- NLCD is the 2021 CONUS release. AK/HI/PR use different NLCD/datum handling and
  are not yet wired in.
