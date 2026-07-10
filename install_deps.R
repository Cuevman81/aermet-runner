# Install the R packages AERMET Runner needs. Run once after cloning:
#   Rscript install_deps.R
pkgs <- c("shiny", "leaflet", "httr", "readr", "dplyr", "stringr", "terra")
new  <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(new)) {
  cat("Installing:", paste(new, collapse = ", "), "\n")
  install.packages(new, repos = "https://cloud.r-project.org")
} else {
  cat("All required packages are already installed.\n")
}
# terra pulls in GDAL/PROJ system libraries; on Linux you may first need
# system packages (e.g. libgdal-dev libproj-dev). On Windows/macOS the CRAN
# binary of 'terra' is self-contained.
