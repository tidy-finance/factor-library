library(dplyr)
library(purrr)
library(nanoparquet)

config <- config::get(file = "config.yml")
returns_repository <- "tidy-finance/factor-library"
grid_repository <- "tidy-finance/factor-library-grid"
library_directory <- config$directories$factor_library
grid_directory <- config$directories$factor_library_grid
id_range_file <- "id_[0-9]{7}-[0-9]{7}[.]parquet"
returns_layout <- c("id INT32", "date DATE", "ret FLOAT")
costs_layout <- c(
  "id INT32",
  "date DATE",
  "turnover FLOAT",
  "cost FLOAT",
  "microcap_share FLOAT"
)

# Everything in the folder gets published.
library_files <- list.files(library_directory, recursive = TRUE)
returns_files <- grep(
  paste0("^", id_range_file, "$"),
  library_files,
  value = TRUE
)
costs_files <- grep(
  paste0("^costs/", id_range_file, "$"),
  library_files,
  value = TRUE
)
other_files <- setdiff(
  library_files,
  c(returns_files, costs_files, "README.md")
)
if (length(other_files) > 0) {
  cli::cli_abort(c(
    "{.path {library_directory}} must hold only id-range Parquet files.",
    "x" = "Other files: {.file {other_files}}",
    "i" = "Rerun {.file 05_portfolio_sorts.R} to rebuild the library."
  ))
}
only_returns <- setdiff(returns_files, basename(costs_files))
only_costs <- setdiff(basename(costs_files), returns_files)
if (length(only_returns) > 0 || length(only_costs) > 0) {
  cli::cli_abort(c(
    "The returns and the costs cover different id ranges.",
    "x" = if (length(only_returns) > 0) "Only returns: {.file {only_returns}}",
    "x" = if (length(only_costs) > 0) "Only costs: {.file {only_costs}}",
    "i" = "Rerun {.file 05_portfolio_sorts.R} to rebuild the library."
  ))
}
layout_of <- function(file) {
  schema <- read_parquet_schema(file.path(library_directory, file))[-1, ]
  paste(schema$name, coalesce(schema$converted_type, schema$type))
}
wrong_layout <- c(
  keep(returns_files, \(file) !identical(layout_of(file), returns_layout)),
  keep(costs_files, \(file) !identical(layout_of(file), costs_layout))
)
if (length(wrong_layout) > 0) {
  cli::cli_abort(c(
    paste(
      "The returns must hold exactly {.val {returns_layout}} and the costs",
      "{.val {costs_layout}}."
    ),
    "x" = "Files with other columns or types: {.file {wrong_layout}}",
    "i" = "Rerun {.file 05_portfolio_sorts.R} to rebuild the library."
  ))
}

grid <- read_parquet(config$files$sort_grid)
sorting_variables <- read_parquet(config$files$sorting_variables)
persistence <- read_parquet(config$files$persistence)
persistence_keys <- c("sorting_variable", "sorting_variable_lag", "rebalancing")
if (
  !setequal(sorting_variables$sorting_variable, grid$sorting_variable) ||
    !setequal(
      distinct(persistence, across(all_of(persistence_keys))),
      distinct(grid, across(all_of(persistence_keys)))
    )
) {
  cli::cli_abort(c(
    paste(
      "The grid, the list of sorting variables, and the persistence table",
      "disagree on the sorting variables or their timing choices."
    ),
    "i" = "Rerun scripts 02 and 03, which build them from the same inputs."
  ))
}

# The slices sit in a folder named after the grid file, so the grid stays the
# first Parquet file of the dataset, which py-tidyfinance 0.5.1 reads.
unlink(grid_directory, recursive = TRUE)
dir.create(file.path(grid_directory, "portfolio_sort_grid"), recursive = TRUE)
stopifnot(
  file.copy(
    config$files$sort_grid,
    file.path(grid_directory, "portfolio_sort_grid.parquet")
  ),
  file.copy(
    config$files$sorting_variables,
    file.path(grid_directory, "sorting_variables.parquet")
  ),
  file.copy(
    config$files$persistence,
    file.path(grid_directory, "sorting_variable_persistence.parquet")
  ),
  file.copy(
    config$cards$factor_library_grid,
    file.path(grid_directory, "README.md")
  ),
  file.copy(
    config$cards$factor_library,
    file.path(library_directory, "README.md"),
    overwrite = TRUE
  )
)
for (grid_slice in split(grid, grid$sorting_variable)) {
  write_parquet(
    grid_slice,
    file.path(
      grid_directory,
      "portfolio_sort_grid",
      paste0(grid_slice$sorting_variable[1], ".parquet")
    ),
    compression = "zstd"
  )
}

if (Sys.which("hf") == "") {
  cli::cli_abort(c(
    "The {.code hf} command line interface was not found on the PATH.",
    "i" = "Install the Hugging Face CLI and run {.code hf auth login} first."
  ))
}
hf_upload <- function(repository, directory, delete) {
  status <- system2(
    "hf",
    c(
      "upload",
      repository,
      shQuote(directory),
      ".",
      "--repo-type",
      "dataset",
      "--delete",
      shQuote(delete)
    )
  )
  if (status != 0) {
    cli::cli_abort(
      "The upload to {.val {repository}} failed (exit status {status})."
    )
  }
}

# upload-large-folder resumes after an interruption. Two workers stay below
# the Hub's limit of 1,000 requests per five minutes.
status <- system2(
  "hf",
  c(
    "upload-large-folder",
    returns_repository,
    shQuote(library_directory),
    "--repo-type",
    "dataset",
    "--num-workers",
    "2"
  )
)
if (status != 0) {
  cli::cli_abort(
    "The upload to {.val {returns_repository}} failed (exit status {status})."
  )
}
# upload-large-folder cannot delete, so a second pass removes the Parquet
# files of earlier releases, in costs/ as well.
hf_upload(returns_repository, library_directory, delete = "*.parquet")
# One commit, so the grid files of different releases never mix.
hf_upload(
  grid_repository,
  grid_directory,
  delete = "portfolio_sort_grid/*.parquet"
)
