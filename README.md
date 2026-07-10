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

## Versions

The bundled processing engine is the **current EPA release as of July 9, 2026**:

| Component | Version | Notes |
|-----------|---------|-------|
| AERMET | **26135** | latest EPA build |
| AERMINUTE | **26135** | latest EPA build |
| AERSURFACE | **26135** | latest EPA build |
| NLCD (land cover) | **2021** | CONUS release used by AERSURFACE |
| R | **4.1+** | required |

EPA stamps the AERMOD suite with a Julian build number `YYDDD`, so **26135** is the
2026 build, day 135 (mid-May 2026) — the newest AERMET / AERMINUTE / AERSURFACE on
EPA SCRAM at the time of writing. The app also shows these versions live at the top
of its window and in the run footer, and AERMET's version is re-checked from the
output header during the QA pass.

When EPA posts a newer build, update it in place: replace the executables in `bin/`
(keeping the same file names) and bump `ENGINE_VERSION` in `app.R`. Authoritative
downloads: EPA SCRAM —
<https://www.epa.gov/scram/air-quality-dispersion-modeling-preferred-and-recommended-models>.

---

## Requirements

- **R** (4.1+). Install packages once:
  ```r
  Rscript install_deps.R      # shiny, leaflet, httr, readr, dplyr, stringr, terra
  ```
- **Internet** — NCEI (GHCNh/ASOS/IGRA/ISD), MRLC (NLCD).
- **The bundled binaries** in `bin/` — public-domain EPA **AERMET / AERMINUTE /
  AERSURFACE v26135**, shipped so the tool is clone-and-run (see Platform support).

## Platform support

The R code and all data sources are cross-platform; the only OS-specific piece is
the three EPA executables. The app auto-selects the right build:

| OS | Binaries used | Status |
|----|---------------|--------|
| **Windows** | `bin/<tool>_26135.exe` (official EPA v26135) | ✅ works out of the box |
| **macOS** | `bin/<tool>_26135_mac` | ✅ works out of the box* |
| **Linux** | `bin/<tool>_26135_linux` | ⚠️ add binaries (see below) |

- **Windows / macOS:** everything needed is bundled — clone and run.
- **\*macOS Gatekeeper:** the Mac builds are unsigned, so the first run may be
  blocked. Clear the quarantine flag once: `xattr -dr com.apple.quarantine bin/`
  (or right-click each binary → Open). The Mac builds are Intel; on Apple Silicon
  they run under Rosetta 2.
- **Linux:** EPA does not distribute Linux binaries, so compile AERMET, AERMINUTE
  and AERSURFACE v26135 from EPA source with `gfortran` and place them in `bin/`
  as `aermet_26135_linux`, `aerminute_26135_linux`, `aersurface_26135_linux`. The
  app looks for exactly those names and prints a reminder if they're missing.
  (Linux also needs system GDAL/PROJ for the `terra` package — see `install_deps.R`.)

## Install

You need **git** and **R 4.1+** (RStudio optional but recommended).

**1. Clone the repository** (in a terminal / macOS Terminal / Windows Git Bash or
PowerShell):

```bash
git clone https://github.com/Cuevman81/aermet-runner.git
cd aermet-runner
```

No git? On the GitHub page use **Code ▸ Download ZIP**, unzip it, and open the
folder — everything below is the same.

**2. Install the R packages** (one time). From a terminal in the repo folder:

```bash
Rscript install_deps.R      # shiny, leaflet, httr, readr, dplyr, stringr, terra
```

or from an R / RStudio console with that folder as the working directory:

```r
source("install_deps.R")
```

The bundled EPA binaries in `bin/` are already included by the clone — nothing else
to download (macOS/Windows). See **Platform support** for the one macOS Gatekeeper
step and the Linux note.

## Run it

Open the project in RStudio (open `app.R`, or **File ▸ Open Project** if you make
one) and click **Run App** — or, from an R console with the repo folder as the
working directory:

```r
shiny::runApp()
```

Then pick a state → station (map or dropdown) → year range → options →
**Build met data**.

**Multiple stations:** pick one station, then list additional ICAOs in the
**"Also process"** box (comma-separated, e.g. `KGPT, KMEI, KTUP`). The app runs
each in turn and writes a separate output folder per station.

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
  cache/                      # station lists, precip records, per-site NLCD (reused)
```

### Reusing previous work (caching)

Re-running a station is cheap — the app only redoes what actually changed:

- **Met data** (GHCNh hourly, 1-min/5-min ASOS, IGRA upper air) is written to the
  run folder and **reused as-is** on any later run of the same station/years — it
  is never re-downloaded.
- **NLCD land cover** is cached per site, so it is fetched from MRLC **once** and
  reused for other year windows and for every AERSURFACE re-run.
- **AERSURFACE** records the settings it ran with. If you re-run with the **same**
  options it is **skipped entirely** (the `.sfc` is reused); if you change an
  option that affects it — e.g. flip **Surface moisture** from Auto/Wet to **Dry** —
  it re-runs using the cached NLCD (no re-download) and AERMET rebuilds from the
  new surface characteristics.

So a typical "same site, try Dry instead" re-run does no network downloads at
all: it just re-runs AERSURFACE on the cached land cover and rebuilds AERMET.

### Quality assurance (QA)

Every run ends with an automatic QA pass so you can see the processed data is
sound before you use it. The app shows a **PASS / WARN / FAIL** badge per station
and an expandable checklist (auto-expanded when it isn't a clean PASS):

- **AERSURFACE** — finished cleanly (no interactive-prompt hang), version 26135,
  and a complete, physically plausible surface-characteristics table (12 monthly
  rows per sector; roughness / Bowen / albedo in range), plus the AP/NONAP sectors.
- **AERMET** — engine version 26135, every Stage-2 run finished successfully
  (regular + ADJ_U*), **zero error messages** in the `.RP2` summaries, all
  `.sfc`/`.pfl` output files present, non-empty and stamped with the right year,
  and confirmation that upper-air and surface observations were actually ingested.
- **Data completeness** — each year's annual and per-quarter percentages against
  the EPA 90%-per-quarter target (a quarter below 90% is a **WARN**, i.e. a data-
  availability note, not a processing error).

The same checklist is written to `<ICAO>_QA_SUMMARY.txt` and folded into the
delivered zip. Meaning of the states: **PASS** = check met; **WARN** = review
(usually data availability); **FAIL** = do not use until resolved.

## AERSURFACE options

The app exposes the site-dependent AERSURFACE inputs, defaulted sensibly:

- **Surface moisture** — **Auto (from rainfall)** by default, or Average / Dry / Wet.
  Auto follows EPA guidance: it pulls the site's own GHCN-Daily annual precipitation,
  builds a 30-year climatology, and classifies the modeled period — wettest 30% →
  **wet**, driest 30% → **dry**, middle 40% → **average**. The per-year totals and
  thresholds are printed to the run log so the basis is transparent.
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

## License & attribution

The code in this repository is released under the **MIT License** (see `LICENSE`).

It redistributes, for convenience, third-party components that keep their own terms:

- **EPA AERMET, AERMINUTE and AERSURFACE (v26135)** in `bin/` — U.S. EPA regulatory
  models in the **public domain**, bundled unmodified (the Windows builds are the
  official EPA executables; the macOS builds are compiled from EPA source). EPA does
  not endorse or support this tool. Authoritative versions come from EPA SCRAM:
  <https://www.epa.gov/scram/air-quality-dispersion-modeling-preferred-and-recommended-models>
- **OurAirports runway data** (`data/ourairports_runways.csv`) — released into the
  **public domain** by OurAirports (<https://ourairports.com/data/>).

Input data is fetched at run time from public U.S. Government sources (public-domain
works): **NOAA / NCEI** — ISD-history, GHCNh hourly, 1-/5-minute ASOS, IGRA2 upper
air, and GHCN-Daily precipitation; **MRLC** — NLCD land cover, impervious and
tree-canopy. Please credit NOAA/NCEI and the MRLC (USGS/USFS) NLCD program in any
analyses that use the output.

Processed output is only as good as its inputs and the automated defaults — review
the QA summary and the **Notes & limits** above before regulatory use.

---

## Contact

Questions, comments, or bug reports are welcome:

**Rodney Cuevas**<br>
Branch Manager, Air Quality Management Branch<br>
Mississippi Department of Environmental Quality — Air Division<br>
📧 [RCuevas@mdeq.ms.gov](mailto:RCuevas@mdeq.ms.gov?subject=AERMET%20Runner)
