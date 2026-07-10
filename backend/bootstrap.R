# =============================================================================
# bootstrap.R -- load the whole backend in the correct order.
# Requires APP_ROOT (repo root, absolute path) to be defined first.
#
#   APP_ROOT <- "/path/to/AERMET_Runner_RShiny"
#   source(file.path(APP_ROOT, "backend", "bootstrap.R"))
#   res <- run_full_pipeline("KJAN", 2024, 2024, output_root = "runs")
# =============================================================================
if (!exists("APP_ROOT")) stop("Define APP_ROOT (repo root) before sourcing bootstrap.R")
APP_ROOT <- normalizePath(APP_ROOT)

source(file.path(APP_ROOT, "backend", "stations.R"))
source(file.path(APP_ROOT, "backend", "sectors.R"))
source(file.path(APP_ROOT, "backend", "moisture.R"))
source(file.path(APP_ROOT, "backend", "aersurface_runner.R"))

# Bundled AERMET/AERMINUTE engine (AERMET.R) -- source without auto-running.
AERMET_SOURCE_ONLY <- TRUE
source(file.path(APP_ROOT, "backend", "engine.R"))

# Overrides + run_full_pipeline() -- must come AFTER engine.R.
source(file.path(APP_ROOT, "backend", "pipeline.R"))
