library("arrow")
library("dplyr")
library("stringr")
library("fs")

# This script publishes the factor library to Hugging Face. It does three
# things:
#
#   1. Checks that data/portfolio_returns/ has the layout 05_portfolio_sorts.R
#      produces: Parquet files that hold nothing but `id`, `date`, and `ret`,
#      cut by id range and named after it (id_000001-001000.parquet, ...).
#      Everything else about a return series is a property of its `id` and
#      lives in the grid, which is why only the grid needs to be joined to
#      the returns and nothing from it is repeated in the returns.
#
#   2. Builds the Hugging-Face-ready grid from the construction grid by
#      stripping the "sv_" prefix from `sorting_variable`. The prefix is an
#      internal construction convention (the sorting-variable columns in the
#      panel are named sv_<name>, see 05_portfolio_sorts.R), but it must not
#      leak into the published data: the `download_data(..., sorting_variable
#      = "bm")` argument uses the bare name (e.g. "bm", not "sv_bm"). Keeping
#      the grid prefixed forced consumers (the tidyfinance package and the
#      Shiny app) to strip it themselves. See
#      https://github.com/tidy-finance/r-tidyfinance/issues/284.
#
#      The construction grid (data/portfolio_sort_grid.parquet) keeps the
#      prefix because scripts 01-05 rely on it; only the published copy is
#      stripped.
#
#   3. Uploads the returns and the stripped grid to Hugging Face via the `hf`
#      CLI. The returns upload deletes every Parquet file the repo already
#      holds in the same commit, so the repo mirrors data/portfolio_returns/
#      exactly and no file of an earlier layout survives a release. Earlier
#      releases remain available through the repo's commit history.
#      Authenticate first with `hf auth login` (a token with write access to
#      the tidy-finance organization is required).

returns_repo <- "tidy-finance/factor-library"
grid_repo <- "tidy-finance/factor-library-grid"

returns_dir <- "data/portfolio_returns"
construction_grid <- "data/portfolio_sort_grid.parquet"

# The published grid keeps the same file name it currently has on the Hub
# (portfolio_sort_grid.parquet) so existing consumers keep resolving it.
publish_dir <- "data/publish"
published_grid <- file.path(publish_dir, "portfolio_sort_grid.parquet")

# 1. Check the returns -------------------------------------------------------

returns_files <- dir_ls(returns_dir, recurse = TRUE)

if (!all(str_detect(path_file(returns_files), "^id_[0-9]+-[0-9]+\\.parquet$"))) {
  cli::cli_abort(c(
    "{.path {returns_dir}} must contain only id-range Parquet files.",
    "i" = "Rerun {.file 05_portfolio_sorts.R} to rebuild the returns."
  ))
}

returns_columns <- names(open_dataset(returns_dir)$schema)

if (!identical(returns_columns, c("id", "date", "ret"))) {
  cli::cli_abort(c(
    "The returns must hold only the columns {.val {c('id', 'date', 'ret')}}.",
    "x" = "Found: {.val {returns_columns}}"
  ))
}

message("Checked ", length(returns_files), " return files in ", returns_dir)

# 2. Build the stripped, Hugging-Face-ready grid -----------------------------

dir_create(publish_dir)

read_parquet(construction_grid) |>
  mutate(sorting_variable = str_remove(sorting_variable, "^sv_")) |>
  write_parquet(published_grid)

message("Wrote stripped grid to ", published_grid)

# 3. Upload to Hugging Face --------------------------------------------------

if (unname(Sys.which("hf")) == "") {
  cli::cli_abort(c(
    "The {.code hf} CLI was not found on the PATH.",
    "i" = "Install the Hugging Face CLI and run {.code hf auth login} first."
  ))
}

hf_upload <- function(repo_id, local_path, path_in_repo, delete = NULL) {
  args <- c(
    "upload",
    repo_id,
    shQuote(local_path),
    shQuote(path_in_repo),
    "--repo-type", "dataset"
  )
  if (!is.null(delete)) {
    args <- c(args, "--delete", shQuote(delete))
  }
  status <- system2("hf", args)
  if (status != 0) {
    cli::cli_abort("Upload to {.val {repo_id}} failed (exit status {status}).")
  }
}

# Returns: mirror the local layout at the repo root. Deleting every Parquet
# file the repo already holds in the same commit removes the files of earlier
# releases that the new files do not overwrite.
hf_upload(returns_repo, returns_dir, ".", delete = "*.parquet")

# Grid: upload the stripped grid under its existing file name.
hf_upload(grid_repo, published_grid, "portfolio_sort_grid.parquet")

message("Upload complete.")
