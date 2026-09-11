library("dplyr")
library("arrow")
library("tidyr")
library("stringr")
library("tidyfinance")
library("future.apply")

n_workers <- max(1L, availableCores() - 1L)
options(future.globals.maxSize = Inf)
options(parallelly.fork.enable = TRUE)
plan(multicore, workers = n_workers)

# Output layout ---------------------------------------------------------------
#
# Every task computes one specification of the grid under all three weighting
# schemes and writes the long-short returns to a scratch file below `task_dir`.
# Once all tasks are done, the scratch files are consolidated into
# `output_dir`, which is the layout that 06_upload_to_huggingface.R publishes:
#
#   * The files hold nothing but `id`, `date`, and `ret`. Everything else about
#     a return series (sorting variable, lag, weighting scheme, ...) is a
#     property of its `id` and lives in the grid, so it is not repeated here.
#   * The files are cut by contiguous ranges of `ids_per_file` ids and named
#     after the range they cover, e.g. `id_000001-001000.parquet`, so the file
#     holding an id follows from the id alone:
#       id_first <- (id - 1) %/% ids_per_file * ids_per_file + 1
#       id_last <- id_first + ids_per_file - 1
#   * Within a file, rows are sorted by `id` and `date`.

task_dir <- "data/portfolio_returns_tasks"
output_dir <- "data/portfolio_returns"
ids_per_file <- 1000L
id_width <- 6L # Zero-padding of the ids in the file names

# Scratch file of a task, named after the id of the grid row it computes
task_file <- function(sorting_variable, sorting_variable_lag, id) {
  file.path(
    task_dir,
    paste0("sorting_variable=", sorting_variable),
    paste0("sorting_variable_lag=", sorting_variable_lag),
    paste0("task_", id, ".parquet")
  )
}

sv_directions <- read_parquet("data/sorting_variable_information.parquet") |>
  transmute(sorting_variable = str_c("sv_", sorting_variable), direction)

grid <- read_parquet("data/portfolio_sort_grid.parquet") |>
  inner_join(sv_directions, join_by(sorting_variable)) |>
  mutate(
    parquet_path = file.path(
      "data",
      paste0("sorting_variables_lag_", sorting_variable_lag, ".parquet")
    )
  )

process_task <- function(row, sorting_data, path) {
  warnings_collected <- character(0)

  result <- tryCatch(
    withCallingHandlers(
      {
        sorting_variables <- grep("sv_", names(sorting_data), value = TRUE)

        rebalancing_month <- if (row$rebalancing == "monthly") NULL else 7
        bp_exchanges <- strsplit(row$breakpoints_exchanges, split = "\\|")[[1]]
        breakpoints_min_size_threshold = if (
          !is.na(row$breakpoints_min_size_threshold)
        ) {
          row$breakpoints_min_size_threshold
        } else {
          NULL
        }

        options_main <- breakpoint_options(
          n_portfolios = row$n_portfolios_main,
          breakpoints_exchanges = bp_exchanges,
          breakpoints_min_size_threshold = breakpoints_min_size_threshold
        )

        options_secondary <- NULL

        if (row$sorting_method != "univariate") {
          sorting_variables <- c(sorting_variables, "mktcap_lag")
          options_secondary <- breakpoint_options(
            n_portfolios = row$n_portfolios_secondary,
            breakpoints_exchanges = bp_exchanges
          )
        }

        min_portfolio_size <- 1L

        portfolio_returns <- implement_portfolio_sort(
          sorting_data,
          sorting_variables = sorting_variables,
          sorting_method = row$sorting_method,
          rebalancing_month = rebalancing_month,
          portfolio_sort_options = portfolio_sort_options(
            filter_options = filter_options(
              exclude_financials = row$exclude_financials,
              exclude_utilities = row$exclude_utilities,
              exclude_negative_earnings = row$exclude_negative_earnings,
              min_size_quantile = if (!is.na(row$min_size_quantile)) {
                row$min_size_quantile
              } else {
                NULL
              },
              min_listing_age = 24
            ),
            breakpoint_options_main = options_main,
            breakpoint_options_secondary = options_secondary
          ),
          min_portfolio_size = min_portfolio_size,
          data_options = data_options(
            earnings = "filter_earnings"
          ),
          quiet = TRUE
        )

        # `row` is the EW row of the specification. Its VW and capped VW rows
        # carry the next two ids because `weighting_scheme` is the innermost
        # dimension of the grid (see 01_define_portfolio_sorts_grid.R).
        long_short_return <- portfolio_returns |>
          compute_long_short_returns(direction = row$direction) |>
          pivot_longer(-date, names_to = "ret_type", values_to = "ret") |>
          mutate(
            ret_type = str_remove(ret_type, "ret_excess_"),
            id = row$id + match(ret_type, c("ew", "vw", "vw_capped")) - 1L,
            ret = replace_na(ret, 0)
          ) |>
          select(id, date, ret)

        dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
        write_parquet(long_short_return, path)

        "success"
      },
      warning = function(w) {
        warnings_collected <<- c(warnings_collected, conditionMessage(w))
        invokeRestart("muffleWarning")
      }
    ),
    error = function(e) e
  )

  if (is.character(result)) {
    tibble(
      id = row$id,
      status = result,
      n_warnings = length(warnings_collected),
      warnings = paste(warnings_collected, collapse = " | ")
    )
  } else {
    tibble(
      id = row$id,
      status = paste("error:", as.character(result)),
      n_warnings = length(warnings_collected),
      warnings = paste(warnings_collected, collapse = " | ")
    )
  }
}

# Scratch files of an earlier run must not end up in the published data
if (fs::dir_exists(task_dir)) {
  fs::dir_delete(task_dir)
}

unique_paths <- unique(grid$parquet_path)
all_diagnostics <- vector("list", length(unique_paths))

for (p in seq_along(unique_paths)) {
  path <- unique_paths[p]
  group_grid <- grid[grid$parquet_path == path, ]
  group_grid <- group_grid |> filter(weighting_scheme == "EW") # Avoid redundant computations for VW and VW_CAPPED since they use the same breakpoints

  sv_cols_needed <- unique(group_grid$sorting_variable)

  message(
    sprintf(
      "[%s] Loading %s (%d tasks, %d sorting variables)...",
      Sys.time(),
      basename(path),
      nrow(group_grid),
      length(sv_cols_needed)
    )
  )

  sv_lag_data <- open_dataset(path) |>
    select(
      permno,
      date,
      ret_excess,
      exchange,
      siccd,
      filter_earnings,
      listing_age,
      mktcap_lag,
      all_of(sv_cols_needed)
    ) |>
    collect()

  task_files <- task_file(
    group_grid$sorting_variable,
    group_grid$sorting_variable_lag,
    group_grid$id
  )

  results <- future_lapply(
    seq_len(nrow(group_grid)),
    function(i) {
      row <- group_grid[i, ]

      task_data <- sv_lag_data[,
        c(
          "permno",
          "date",
          "ret_excess",
          "exchange",
          "siccd",
          "filter_earnings",
          "listing_age",
          "mktcap_lag",
          row$sorting_variable
        ),
        drop = FALSE
      ]

      process_task(row, task_data, task_files[i])
    },
    future.seed = TRUE,
    future.chunk.size = max(1L, nrow(group_grid) %/% (n_workers * 4L))
  )

  all_diagnostics[[p]] <- bind_rows(results)

  message(
    sprintf(
      "[%s] Finished %s — %d tasks",
      Sys.time(),
      basename(path),
      nrow(group_grid)
    )
  )
}

plan(sequential)
diagnostics <- bind_rows(all_diagnostics)
write_parquet(diagnostics, "data/task_diagnostics.parquet")
message("All done! ", nrow(diagnostics), " tasks processed.")

# Consolidate the task files into the published layout -----------------------

message(
  sprintf("[%s] Consolidating task files into %s...", Sys.time(), output_dir)
)

# A task writes one specification under all weighting schemes to the file named
# after its EW row, so the ids in a task file are those of the grid rows that
# agree on every construction choice except `weighting_scheme`.
id_files <- grid |>
  group_by(across(-c(id, weighting_scheme))) |>
  mutate(task_id = id[weighting_scheme == "EW"]) |>
  ungroup() |>
  transmute(
    id,
    task = task_file(sorting_variable, sorting_variable_lag, task_id),
    id_first = (id - 1L) %/% ids_per_file * ids_per_file + 1L,
    id_last = id_first + ids_per_file - 1L
  )

# Tasks that failed (see task_diagnostics.parquet) have no scratch file, so
# their ids are left out of the published data.
tasks <- id_files |>
  distinct(task) |>
  mutate(found = unname(fs::file_exists(task)))

if (any(!tasks$found)) {
  message(
    sprintf(
      "%d of %d task files are missing; see data/task_diagnostics.parquet.",
      sum(!tasks$found),
      nrow(tasks)
    )
  )
}

id_files <- id_files |>
  semi_join(tasks |> filter(found), join_by(task))

files <- id_files |>
  group_by(id_first, id_last) |>
  summarise(ids = list(id), tasks = list(unique(task)), .groups = "drop") |>
  mutate(
    file = str_c(
      "id_",
      formatC(id_first, width = id_width, format = "d", flag = "0"),
      "-",
      formatC(id_last, width = id_width, format = "d", flag = "0"),
      ".parquet"
    )
  ) |>
  arrange(id_first)

if (fs::dir_exists(output_dir)) {
  fs::dir_delete(output_dir)
}
fs::dir_create(output_dir)

n_rows <- 0
for (i in seq_len(nrow(files))) {
  id_first <- files$id_first[i]
  id_last <- files$id_last[i]

  returns <- open_dataset(files$tasks[[i]], partitioning = NULL) |>
    filter(id >= id_first, id <= id_last) |>
    select(id, date, ret) |>
    collect() |>
    arrange(id, date)

  if (!setequal(returns$id, files$ids[[i]])) {
    stop(
      sprintf("The ids read for %s do not match the grid.", files$file[i])
    )
  }

  write_parquet(returns, file.path(output_dir, files$file[i]))
  n_rows <- n_rows + nrow(returns)

  if (i %% 100 == 0 || i == nrow(files)) {
    message(
      sprintf("[%s] Wrote %d of %d files", Sys.time(), i, nrow(files))
    )
  }
}

fs::dir_delete(task_dir)

message(
  sprintf(
    "Wrote %d ids (%d rows) to %d files in %s.",
    nrow(id_files),
    n_rows,
    nrow(files),
    output_dir
  )
)
