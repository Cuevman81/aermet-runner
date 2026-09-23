# =============================================================================
# AERMET Runner  (R Shiny)
# -----------------------------------------------------------------------------
# Pick any active US ASOS station and a year window; the app runs AERSURFACE
# (fetching NLCD on demand) and AERMET/AERMINUTE (fetching GHCNh surface,
# 1-minute ASOS winds, and IGRA upper air) and drops an AERMOD-ready met data
# set into a clean folder, with a completeness report and a zip.
#
# Run locally:  shiny::runApp()   (from this folder) — needs the bundled
# binaries in bin/ and an internet connection.
# =============================================================================
library(shiny)
library(leaflet)

# Shiny evaluates app.R in its own environment, but source(local=FALSE) and the
# bundled engine run in globalenv(); put APP_ROOT and the backend there so they
# resolve consistently. (getwd() is the app directory under runApp()/Run App.)
APP_ROOT <- normalizePath(getwd())
assign("APP_ROOT", APP_ROOT, envir = globalenv())
source(file.path(APP_ROOT, "backend", "bootstrap.R"))

DEFAULT_OUTPUT <- file.path(APP_ROOT, "runs")
CUR_YEAR <- as.integer(format(Sys.Date(), "%Y"))

# --- App / engine metadata (update these when the bundled EPA binaries change) --
APP_VERSION    <- "1.3"
ENGINE_VERSION <- "26135"          # EPA AERMET / AERMINUTE / AERSURFACE (posted 07-09-2026)
ENGINE_ASOF    <- "July 26, 2026"  # date the bundled EPA versions were last verified current on SCRAM
NLCD_YEAR      <- 2021             # NLCD product used by AERSURFACE
CONTACT_NAME   <- "Rodney Cuevas"
CONTACT_TITLE  <- "Branch Manager, Air Quality Management Branch"
CONTACT_ORG    <- "Mississippi Department of Environmental Quality — Air Division"
CONTACT_EMAIL  <- "RCuevas@mdeq.ms.gov"
PLATFORM_LABEL <- switch(os_tag(), windows = "Windows (EPA .exe)",
                         macos = "macOS build", linux = "Linux build")

ui <- fluidPage(
  tags$head(tags$style(HTML("
    .btn-run { background:#005ea2; border-color:#005ea2; color:#fff; font-weight:600; }
    #log { white-space:pre-wrap; font-family:monospace; font-size:12px;
           background:#0b1f33; color:#d6e6f5; padding:10px; border-radius:6px;
           height:360px; overflow-y:auto; }
    .muted { color:#666; font-size:12px; }
    .verbadge { display:inline-block; background:#eef4fa; border:1px solid #cfe0f0;
                color:#134a76; font-size:12px; font-weight:600; padding:4px 10px;
                border-radius:4px; margin:4px 0 8px; }
    .verbadge-asof { display:block; font-weight:400; font-size:11px;
                     color:#2e6b3e; margin-top:2px; }
    .footer { border-top:1px solid #ddd; margin-top:14px; padding-top:10px;
              font-size:12px; color:#555; }
    .footer a { color:#005ea2; }
    .qa-station { border:1px solid #e6ebf0; border-radius:8px; padding:8px 12px; margin:8px 0; }
    .qa-badge { display:inline-block; font-weight:700; font-size:11px; padding:2px 9px;
                border-radius:10px; color:#fff; margin-left:8px; vertical-align:middle; }
    .qa-PASS { background:#2e8540; } .qa-WARN { background:#c98a00; } .qa-FAIL { background:#c22e2e; }
    .qa-panel { margin-top:6px; }
    .qa-panel > summary { cursor:pointer; font-size:13px; color:#134a76; outline:none; }
    .qa-group { font-weight:600; margin:8px 0 2px; font-size:12.5px; color:#134a76; }
    .qa-list { list-style:none; padding-left:2px; margin:0 0 4px; }
    .qa-list li { font-size:12.5px; padding:1px 0; }
    .qa-ico { font-weight:700; margin-right:6px; }
    .qa-pass .qa-ico { color:#2e8540; } .qa-warn .qa-ico { color:#c98a00; }
    .qa-fail .qa-ico { color:#c22e2e; } .qa-info .qa-ico { color:#5a80a0; }
    .qa-detail { color:#777; }
  "))),
  titlePanel("AERMET Runner — AERMOD-ready met data for any US station"),
  p(class = "muted", "Runs AERSURFACE (on-demand NLCD) + AERMET/AERMINUTE ",
    "(GHCNh surface, 1-min ASOS winds, IGRA upper air) for a 1-5 year window."),
  div(class = "verbadge",
      sprintf("Processing with EPA AERMET %s · AERMINUTE %s · AERSURFACE %s",
              ENGINE_VERSION, ENGINE_VERSION, ENGINE_VERSION),
      sprintf("  |  NLCD %d  |  running: %s  |  app v%s", NLCD_YEAR, PLATFORM_LABEL, APP_VERSION),
      tags$span(class = "verbadge-asof",
                sprintf("latest EPA versions · current as of %s", ENGINE_ASOF))),
  sidebarLayout(
    sidebarPanel(
      width = 4,
      selectInput("state", "State", choices = NULL, selectize = FALSE),
      leafletOutput("map", height = "260px"),
      selectizeInput("station", "ASOS Station (ICAO)", choices = NULL),
      textInput("stations_extra", "Also process (optional)",
                placeholder = "more ICAOs, comma-separated: KGPT, KMEI, KTUP"),
      fluidRow(
        column(6, numericInput("y1", "Start year", value = CUR_YEAR - 5,
                               min = 2000, max = CUR_YEAR, step = 1)),
        column(6, numericInput("y2", "End year", value = CUR_YEAR - 1,
                               min = 2000, max = CUR_YEAR, step = 1))),
      tags$b("AERMET options"),
      fluidRow(
        column(6, numericInput("tadjust", "UTC offset (h)", value = NA,
                               min = 4, max = 11, step = 1))),
      tags$span(class = "muted", paste(
        "Blank UTC offset = read from the station's 1-minute ASOS file or its state",
        "(standard time: 5 Eastern, 6 Central, 7 Mountain, 8 Pacific).")),
      tags$b("AERSURFACE options"),
      fluidRow(
        column(6, selectInput("moisture", "Surface moisture",
                              c("Auto (from rainfall)" = "AUTO", "Average" = "AVERAGE",
                                "Dry" = "DRY", "Wet" = "WET"))),
        column(6, div(style = "margin-top:26px;",
               checkboxInput("snow", "Continuous winter snow", FALSE),
               checkboxInput("arid", "Arid climate", FALSE),
               checkboxInput("airport", "Airport site", TRUE)))),
      textInput("sectors", "Sectors override (optional)",
                placeholder = "e.g. 300 150 AP; 150 300 NONAP"),
      tags$span(class = "muted", "Blank = auto-derive AP/NONAP from runway geometry."),
      textInput("outdir", "Output folder", value = DEFAULT_OUTPUT),
      actionButton("run", "Build met data", class = "btn-run", width = "100%"),
      tags$hr(),
      uiOutput("station_info")
    ),
    mainPanel(
      width = 8,
      div(id = "log", textOutput("log_text")),
      br(),
      uiOutput("result_ui")
    )
  ),
  div(class = "footer",
    fluidRow(
      column(8,
        tags$p(tags$b("Processing engine: "),
          sprintf("EPA AERMET %s · AERMINUTE %s · AERSURFACE %s (bundled; latest EPA builds as of %s). ",
                  ENGINE_VERSION, ENGINE_VERSION, ENGINE_VERSION, ENGINE_ASOF),
          sprintf("NLCD %d land cover via MRLC. ", NLCD_YEAR),
          "Surface: GHCNh (NCEI) · Winds: 1-minute ASOS · Upper air: IGRA2."),
        tags$p(tags$em("Automated defaults (AERSURFACE seasons/moisture, AP/NONAP ",
          "sectors, nearest upper-air site, data completeness) should be reviewed ",
          "for suitability before regulatory use."))),
      column(4,
        tags$p(tags$b("Questions, comments or bugs?")),
        tags$p(tags$b(CONTACT_NAME), tags$br(),
          CONTACT_TITLE, tags$br(),
          CONTACT_ORG, tags$br(),
          tags$a(href = paste0("mailto:", CONTACT_EMAIL,
                 "?subject=AERMET%20Runner%20app"), CONTACT_EMAIL)))
    )
  )
)

server <- function(input, output, session) {
  surf <- reactiveVal(NULL); igra <- reactiveVal(NULL)
  logbuf <- reactiveVal(character(0))
  results <- reactiveVal(NULL)   # named list of per-station result objects
  addlog <- function(...) {
    logbuf(c(logbuf(), sprintf("[%s] %s", format(Sys.time(), "%H:%M:%S"), paste0(...))))
  }

  # ---- load station lists ONCE at startup (fixed cache; no reactive deps) --
  observeEvent(TRUE, once = TRUE, {
    cache <- file.path(APP_ROOT, "cache")
    withProgress(message = "Loading NCEI station lists ...", value = 0.5, {
      s <- tryCatch(load_surface_stations(cache), error = function(e) conditionMessage(e))
      g <- tryCatch(load_igra_stations(cache),    error = function(e) NULL)
    })
    if (is.data.frame(s)) {
      surf(s); igra(g)
      states <- sort(unique(s$STATE))
      updateSelectInput(session, "state", choices = states,
                        selected = if ("MS" %in% states) "MS" else states[1])
      addlog("Loaded ", nrow(s), " US ASOS stations and ",
             if (is.data.frame(g)) nrow(g) else 0, " IGRA upper-air sites.")
    } else {
      addlog("ERROR loading station list: ", if (is.character(s)) s else "check network")
    }
  })

  in_state <- reactive({
    req(surf(), input$state); surf()[surf()$STATE == input$state, ]
  })
  observe({
    df <- in_state()
    ch <- if (nrow(df)) setNames(df$ICAO, paste0(df$ICAO, " - ", df$STATION_NAME)) else character(0)
    updateSelectizeInput(session, "station", choices = ch,
                         selected = if (length(ch)) ch[[1]] else NULL, server = TRUE)
  })
  output$map <- renderLeaflet({
    df <- in_state()
    if (!nrow(df)) return(leaflet() %>% addTiles() %>% setView(-98.6, 39.8, 3))
    leaflet(df) %>% addTiles() %>%
      addCircleMarkers(~LON, ~LAT, label = ~paste0(ICAO, " - ", STATION_NAME),
                       layerId = ~ICAO, radius = 5, color = "#c0392b", fillOpacity = 0.8) %>%
      setView(mean(df$LON), mean(df$LAT), 6)
  })
  observeEvent(input$map_marker_click, {
    req(input$map_marker_click$id)
    updateSelectizeInput(session, "station", selected = input$map_marker_click$id)
  })

  output$station_info <- renderUI({
    req(input$station, surf(), igra())
    st <- tryCatch(resolve_station(input$station, surf(), igra()), error = function(e) NULL)
    if (is.null(st)) return(NULL)
    rw <- file.path(APP_ROOT, "data", "ourairports_runways.csv")
    sec <- tryCatch(derive_sectors(st$icao, st$lat, st$lon, rw), error = function(e) NULL)
    sec_txt <- if (is.null(sec)) "n/a" else
      paste(sprintf("%.0f-%.0f %s", sec$start, sec$end, sec$type), collapse = ";  ")
    tags$div(class = "muted",
      tags$b(sprintf("%s — %s", st$icao, st$name)), tags$br(),
      sprintf("Surface id %s | GHCNh %s", st$station_id, st$ghcnh_id), tags$br(),
      sprintf("Nearest upper air: %s (%s, %.0f km)", st$ua_station_id, st$ua_name, st$ua_dist_km),
      tags$br(), tags$b("Auto sectors: "), sec_txt)
  })

  parse_sectors <- function(txt) {
    txt <- trimws(txt %||% ""); if (!nzchar(txt)) return(NULL)
    parts <- strsplit(txt, "[;\n]+")[[1]]
    rows <- lapply(parts, function(p) {
      t <- strsplit(trimws(p), "[ ,\t]+")[[1]]
      if (length(t) < 3 || is.na(suppressWarnings(as.numeric(t[1])))) return(NULL)
      data.frame(start = as.numeric(t[1]), end = as.numeric(t[2]),
                 type = toupper(t[3]), stringsAsFactors = FALSE)
    })
    rows <- do.call(rbind, rows[!vapply(rows, is.null, logical(1))])
    if (is.null(rows) || nrow(rows) == 0) NULL else rows
  }

  output$log_text <- renderText(paste(logbuf(), collapse = "\n"))

  parse_icaos <- function(txt) {
    txt <- trimws(txt %||% ""); if (!nzchar(txt)) return(character(0))
    toupper(unique(trimws(strsplit(txt, "[ ,;\n\t]+")[[1]])))
  }

  # ---- run (single station or batch) --------------------------------------
  observeEvent(input$run, {
    req(input$station, input$station != "")
    y1 <- as.integer(input$y1); y2 <- as.integer(input$y2)
    if (is.na(y1) || is.na(y2) || y2 < y1 || y2 > CUR_YEAR) {
      addlog("Invalid year range."); return()
    }
    primary <- toupper(input$station)
    icaos <- unique(c(primary, parse_icaos(input$stations_extra)))
    icaos <- icaos[nzchar(icaos)]
    results(NULL)
    base_opts <- list(moisture = input$moisture, snow = isTRUE(input$snow),
                      arid = isTRUE(input$arid), airport = isTRUE(input$airport))
    # A sectors override describes ONE airport's geometry, so it applies only to the
    # station it was entered for; the rest of a batch auto-derive from their own runways.
    sec_override <- parse_sectors(input$sectors)
    # Likewise the UTC offset describes one station.
    num_or_null <- function(v) if (length(v) && !is.na(v)) as.numeric(v) else NULL
    met_override <- list(tadjust = num_or_null(input$tadjust))
    addlog(sprintf("=== Building %d station(s): %s  |  %d-%d ===",
                   length(icaos), paste(icaos, collapse = ", "), y1, y2))
    if (y2 - y1 + 1 > 5)
      addlog(sprintf("NOTE: %d-year window requested; EPA guidance is 5 years of NWS data.",
                     y2 - y1 + 1))
    if (!is.null(sec_override) && length(icaos) > 1)
      addlog(sprintf("NOTE: sectors override applies to %s only; %s auto-derive from runway geometry.",
                     primary, paste(setdiff(icaos, primary), collapse = ", ")))
    if (length(Filter(Negate(is.null), met_override)) && length(icaos) > 1)
      addlog(sprintf("NOTE: UTC offset applies to %s only, not to %s.",
                     primary, paste(setdiff(icaos, primary), collapse = ", ")))

    collected <- list(); n <- length(icaos)
    withProgress(message = "Building met data", value = 0, {
      for (k in seq_len(n)) {
        ic <- icaos[k]
        opts <- base_opts; mopts <- NULL
        if (identical(ic, primary)) { opts$sectors <- sec_override; mopts <- met_override }
        addlog(sprintf("--- [%d/%d] %s ---", k, n, ic))
        cb <- function(msg, frac) {
          setProgress(value = max(0, min(1, (k - 1 + frac) / n)),
                      detail = sprintf("%s: %s", ic, msg))
          addlog(msg)
        }
        res <- tryCatch(
          run_full_pipeline(ic, y1, y2, output_root = input$outdir, aers_opts = opts, progress = cb,
                            met_opts = mopts),
          error = function(e) { addlog(sprintf("%s FAILED: %s", ic, conditionMessage(e))); NULL })
        if (!is.null(res)) {
          addlog(sprintf("%s done (moisture %s). Output: %s", ic, res$moisture, res$output_dir))
          collected[[ic]] <- res
        }
      }
    })
    results(collected)
    addlog(sprintf("=== Batch complete: %d/%d succeeded ===", length(collected), n))
  })

  output$result_ui <- renderUI({
    rs <- results(); if (is.null(rs) || length(rs) == 0) return(NULL)
    single <- length(rs) == 1
    rows <- lapply(rs, function(res) {
      miss <- res$missing_asos_months; qa <- res$qa
      div(class = "qa-station",
        tags$p(
          tags$b(sprintf("%s %d-%d", res$icao, res$years[1], res$years[2])),
          sprintf(" — moisture %s", res$moisture %||% "?"),
          if (!is.null(qa)) tags$span(class = paste0("qa-badge qa-", qa$overall), qa$overall) else NULL,
          if (length(miss)) tags$span(class = "muted",
            sprintf("  (1-min ASOS gap: %s)", paste(miss, collapse = ", "))) else NULL),
        tags$code(res$output_dir),
        qa_panel(qa))
    })
    tagList(
      tags$h4(sprintf("Build complete — %d station(s)", length(rs))),
      tags$p(class = "muted", sprintf("EPA AERMET/AERMINUTE/AERSURFACE %s · NLCD %d · ",
                                      ENGINE_VERSION, NLCD_YEAR),
             "QA summary is saved as <ICAO>_QA_SUMMARY.txt and included in the zip."),
      rows,
      if (single && !is.na(rs[[1]]$zip_path)) downloadButton("dl", "Download zip")
      else tags$p(class = "muted",
        "Each station folder above holds its AERMOD-ready met files, QA summary and a zip.")
    )
  })
  output$dl <- downloadHandler(
    filename = function() basename(results()[[1]]$zip_path),
    content = function(file) file.copy(results()[[1]]$zip_path, file, overwrite = TRUE)
  )
}

`%||%` <- function(a, b) if (is.null(a) || !nzchar(a)) b else a

# --- QA panel rendering -------------------------------------------------------
qa_icon <- function(s) switch(s, pass = "✓", warn = "▲",
                              fail = "✗", info = "•", "•")

# Collapsible per-station QA checklist; auto-expanded when not a clean PASS.
qa_panel <- function(qa) {
  if (is.null(qa)) return(NULL)
  groups <- unique(vapply(qa$checks, function(c) c$group, ""))
  body <- lapply(groups, function(g) {
    items <- Filter(function(c) identical(c$group, g), qa$checks)
    tagList(div(class = "qa-group", g),
      tags$ul(class = "qa-list", lapply(items, function(c)
        tags$li(class = paste0("qa-", c$status),
          tags$span(class = "qa-ico", qa_icon(c$status)),
          tags$span(c$label),
          if (nzchar(c$detail)) tags$span(class = "qa-detail",
                                          paste0(" — ", c$detail)) else NULL))))
  })
  det <- tags$details(class = "qa-panel",
    tags$summary(sprintf("Quality assurance — overall %s (click to %s)",
                         qa$overall, if (qa$overall == "PASS") "expand" else "review")),
    body)
  if (qa$overall != "PASS") det <- tagAppendAttributes(det, open = NA)
  det
}

shinyApp(ui, server)
