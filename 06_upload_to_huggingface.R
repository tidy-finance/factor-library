library("arrow")
library("dplyr")
library("fs")

# This script publishes the factor library to Hugging Face. It does two things:
#
#   1. Builds the Hugging-Face-ready grid from the construction grid by stripping
#      the "sv_" prefix from `sorting_variable`. The prefix is an internal
#      construction convention (the sorting-variable columns in the panel are
#      named sv_<name>, see 05_portfolio_sorts.R), but it must not leak into the
#      published data: the factor-library return partitions and the
#      `download_data(..., sorting_variable = "bm")` argument both use the bare
#      name (e.g. "bm", not "sv_bm"). Keeping the grid prefixed forced consumers
#      (the tidyfinance package and the Shiny app) to strip it themselves. See
#      https://github.com/tidy-finance/r-tidyfinance/issues/284.
#
#      The construction grid (data/portfolio_sort_grid.parquet) keeps the prefix
#      because scripts 01-05 rely on it; only the published copy is stripped.
#
#   2. Uploads the partitioned returns and the stripped grid to Hugging Face via
#      the `hf` CLI. Authenticate first with `hf auth login` (a token with write
#      access to the tidy-finance organization is required).

returns_repo <- "tidy-finance/factor-library"
grid_repo <- "tidy-finance/factor-library-grid"

returns_dir <- "data/portfolio_returns"
construction_grid <- "data/portfolio_sort_grid.parquet"

# The published grid keeps the same file name it currently has on the Hub
# (portfolio_sort_grid.parquet) so existing consumers keep resolving it.
publish_dir <- "data/publish"
published_grid <- file.path(publish_dir, "portfolio_sort_grid.parquet")

# 1. Build the stripped, Hugging-Face-ready grid -----------------------------

dir_create(publish_dir)

read_parquet(construction_grid) |>
  mutate(sorting_variable = sub("^sv_", "", sorting_variable)) |>
  write_parquet(published_grid)

message("Wrote stripped grid to ", published_grid)

# 2. Upload to Hugging Face --------------------------------------------------

if (unname(Sys.which("hf")) == "") {
  cli::cli_abort(c(
    "The {.code hf} CLI was not found on the PATH.",
    "i" = "Install the Hugging Face CLI and run {.code hf auth login} first."
  ))
}

hf_upload <- function(repo_id, local_path, path_in_repo) {
  status <- system2(
    "hf",
    c(
      "upload",
      repo_id,
      shQuote(local_path),
      shQuote(path_in_repo),
      "--repo-type", "dataset"
    )
  )
  if (status != 0) {
    cli::cli_abort("Upload to {.val {repo_id}} failed (exit status {status}).")
  }
}

# Returns: upload the partitioned dataset to the repo root.
hf_upload(returns_repo, returns_dir, ".")

# Grid: upload the stripped grid under its existing file name.
hf_upload(grid_repo, published_grid, "portfolio_sort_grid.parquet")

message("Upload complete.")
