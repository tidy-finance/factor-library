library("arrow")
library("dplyr")
library("fs")

# This script publishes the factor library to Hugging Face. It does three
# things:
#
#   1. Checks that data/portfolio_returns/ has the layout 04_portfolio_sorts.R
#      produces: Parquet files that hold nothing but `id`, `date`, and `ret`,
#      cut by id range and named after it (id_0000001-0001000.parquet, ...).
#      Everything else about a return series is a property of its `id` and
#      lives in the grid, which is why only the grid needs to be joined to
#      the returns and nothing from it is repeated in the returns.
#
#   2. Builds the Hugging-Face-ready grid from the construction grid by
#      stripping the "sv_" prefix from `sorting_variable`. The prefix is an
#      internal construction convention (the sorting-variable columns in the
#      panel are named sv_<name>, see 04_portfolio_sorts.R), but it must not
#      leak into the published data: the `download_data(..., sorting_variable
#      = "bm")` argument uses the bare name (e.g. "bm", not "sv_bm"). Keeping
#      the grid prefixed forced consumers (the tidyfinance package and the
#      Shiny app) to strip it themselves. See
#      https://github.com/tidy-finance/r-tidyfinance/issues/284.
#
#      The construction grid (data/portfolio_sort_grid.parquet) keeps the
#      prefix because scripts 01-04 rely on it; only the published copy is
#      stripped.
#
#      Two smaller files go next to the grid for clients that cannot load all
#      of it, such as the Shiny app at factors.tidy-finance.org, which runs R
#      in the browser: one slice of the grid per sorting variable, and the
#      list of sorting variables with their full names and high-minus-low
#      directions.
#
#   3. Uploads the returns and the grid files to Hugging Face via the `hf`
#      CLI. The returns go up with `hf upload-large-folder`, which commits in
#      batches and picks up where it stopped when rerun: a single commit of
#      the ~12 GB folder is slow, and a failure near its end loses all of it.
#      A second pass over the same folder then deletes every Parquet file the
#      repo holds that is no longer local, so the repo mirrors
#      data/portfolio_returns/ exactly and no file of an earlier layout
#      survives a release. Earlier releases remain available through the
#      repo's commit history. Authenticate first with `hf auth login` (a token
#      with write access to the tidy-finance organization is required).

returns_repo <- "tidy-finance/factor-library"
grid_repo <- "tidy-finance/factor-library-grid"

returns_dir <- "data/portfolio_returns"
construction_grid <- "data/portfolio_sort_grid.parquet"
sorting_variable_information <- "data/sorting_variable_information.parquet"

# The published grid keeps the same file name it currently has on the Hub
# (portfolio_sort_grid.parquet) so existing consumers keep resolving it.
publish_dir <- "data/publish"
published_grid <- file.path(publish_dir, "portfolio_sort_grid.parquet")

# The slices sit in a folder named after the grid file. The Hub lists files in
# path order, so the grid stays the first Parquet file of the repo, which is
# the file py-tidyfinance 0.5.1 reads as the grid.
published_slices <- file.path(publish_dir, "portfolio_sort_grid")
published_sorting_variables <- file.path(
  publish_dir,
  "sorting_variables.parquet"
)

# 1. Check the returns -------------------------------------------------------

returns_files <- dir_ls(returns_dir, recurse = TRUE)

if (!all(grepl("^id_[0-9]+-[0-9]+\\.parquet$", path_file(returns_files)))) {
  cli::cli_abort(c(
    "{.path {returns_dir}} must contain only id-range Parquet files.",
    "i" = "Rerun {.file 04_portfolio_sorts.R} to rebuild the returns."
  ))
}

# Unifying reads every file's schema rather than only the first file's
returns_columns <- names(open_dataset(returns_dir, unify_schemas = TRUE)$schema)

if (!identical(returns_columns, c("id", "date", "ret"))) {
  cli::cli_abort(c(
    "The returns must hold only the columns {.val {c('id', 'date', 'ret')}}.",
    "x" = "Found: {.val {returns_columns}}"
  ))
}

message("Checked ", length(returns_files), " return files in ", returns_dir)

# 2. Build the stripped, Hugging-Face-ready grid -----------------------------

# The folder goes up as a whole, so it is rebuilt from scratch: a slice left
# over from a sorting variable that has since been dropped would otherwise be
# uploaded again and survive on the Hub.
if (dir_exists(publish_dir)) {
  dir_delete(publish_dir)
}
dir_create(published_slices)

grid <- read_parquet(construction_grid) |>
  mutate(sorting_variable = sub("^sv_", "", sorting_variable))

write_parquet(grid, published_grid)

message("Wrote stripped grid to ", published_grid)

# A slice holds at most 23,040 rows, about 115 KB with zstd, against 19 MB for
# the full grid. Together the slices hold exactly the rows of the grid.
for (grid_slice in split(grid, grid$sorting_variable)) {
  write_parquet(
    grid_slice,
    path(published_slices, grid_slice$sorting_variable[1], ext = "parquet"),
    compression = "zstd"
  )
}

message(
  "Wrote ", n_distinct(grid$sorting_variable), " grid slices to ",
  published_slices
)

# 01_download_raw_data.R names the sorting variables without the "sv_" prefix
# (02_define_portfolio_sorts_grid.R adds it for the construction grid), so the
# names match the stripped grid as they are. A mismatch means that one of the
# two files was rebuilt without the other, and a client would offer sorting
# variables without a slice or miss some that have one.
sorting_variables <- read_parquet(sorting_variable_information) |>
  select(sorting_variable, full_name, direction) |>
  arrange(sorting_variable)

grid_variables <- unique(grid$sorting_variable)
only_in_grid <- setdiff(grid_variables, sorting_variables$sorting_variable)
only_in_information <- setdiff(
  sorting_variables$sorting_variable,
  grid_variables
)

if (length(only_in_grid) > 0 || length(only_in_information) > 0) {
  cli::cli_abort(c(
    paste(
      "The grid and {.path {sorting_variable_information}} disagree on the",
      "sorting variables."
    ),
    "x" = "Only in the grid: {.val {only_in_grid}}",
    "x" = "Only in the information: {.val {only_in_information}}",
    "i" = "Rerun scripts 02 to 04, which build the grid from the information."
  ))
}

write_parquet(sorting_variables, published_sorting_variables)

message("Wrote the list of sorting variables to ", published_sorting_variables)

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

hf_upload_large_folder <- function(repo_id, local_path) {
  args <- c(
    "upload-large-folder",
    repo_id,
    shQuote(local_path),
    "--repo-type", "dataset",
    # The Hub allows 1,000 API requests per 5 minutes. On a fast connection
    # more workers exceed that, and files caught by the rate limit can end up
    # marked as sent although the Hub never registered them.
    "--num-workers", "2"
  )
  status <- system2("hf", args)
  if (status != 0) {
    cli::cli_abort("Upload to {.val {repo_id}} failed (exit status {status}).")
  }
}

# Returns: upload-large-folder cannot delete remote files, so a second pass
# over the same folder deletes the Parquet files of earlier releases that the
# new files do not overwrite. It checks each file against the Hub and uploads
# only what the Hub lacks, which is nothing after a clean first pass.
hf_upload_large_folder(returns_repo, returns_dir)
hf_upload(returns_repo, returns_dir, ".", delete = "*.parquet")

# Grid: the grid, its slices, and the list of sorting variables go up in one
# commit, so the Hub never serves slices or a list from another release than
# the grid. The pattern deletes the slices of sorting variables no longer in
# the grid; it only matches files inside portfolio_sort_grid/, so the grid
# file and the dataset card stay.
hf_upload(
  grid_repo, publish_dir, ".",
  delete = "portfolio_sort_grid/*.parquet"
)

message("Upload complete.")
