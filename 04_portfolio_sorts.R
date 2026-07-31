library("dplyr")
library("arrow")
library("mirai")
library("mori")

# Input data is shared via mori, so transfer to workers is free; per-worker
# memory is bounded by private copies of the columns a task actually touches
# (~12 of the ~190 shared columns) plus transient sort allocations.
# Also note that the number of sorting variables caps how many actually run
# concurrently because workers are reset after each sorting variable lag file.
n_workers <- 30L

message(sprintf("Using %d worker daemon(s).", n_workers))

# filter_options() and breakpoint_options() expect NULL to disable an option;
# the grid stores disabled options as NA, so translate on the way in.
na_to_null <- function(x) {
  if (length(x) == 1L && is.na(x)) NULL else x
}

sv_directions <- read_parquet("data/sorting_variable_information.parquet") |>
  transmute(sorting_variable = paste0("sv_", sorting_variable), direction)

grid <- read_parquet("data/portfolio_sort_grid.parquet") |>
  inner_join(sv_directions, join_by(sorting_variable)) |>
  mutate(
    parquet_path = file.path(
      "data",
      paste0("sorting_variables_lag_", sorting_variable_lag, ".parquet")
    )
  )

process_task <- function(row, sorting_data, output_dir) {
  warnings_collected <- character(0)

  result <- tryCatch(
    withCallingHandlers(
      {
        sorting_variables <- grep("sv_", names(sorting_data), value = TRUE)

        rebalancing_month <- if (row$rebalancing == "monthly") NULL else 7L
        bp_exchanges <- strsplit(row$breakpoints_exchanges, split = "\\|")[[1]]

        options_main <- breakpoint_options(
          n_portfolios = row$n_portfolios_main,
          breakpoints_exchanges = bp_exchanges,
          breakpoints_min_size_threshold = na_to_null(
            row$breakpoints_min_size_threshold
          )
        )

        options_secondary <- NULL

        if (row$sorting_method != "univariate") {
          sorting_variables <- c(sorting_variables, "mktcap_lag")
          options_secondary <- breakpoint_options(
            n_portfolios = row$n_portfolios_secondary,
            breakpoints_exchanges = bp_exchanges
          )
        }

        portfolio_returns <- implement_portfolio_sort(
          sorting_data,
          sorting_variables = sorting_variables,
          sorting_method = row$sorting_method,
          rebalancing_month = rebalancing_month,
          portfolio_sort_options = portfolio_sort_options(
            filter_options = filter_options(
              exclude_financials = row$exclude_financials,
              exclude_utilities = row$exclude_utilities,
              exclude_negative_book_equity = row$exclude_negative_book_equity,
              exclude_negative_earnings = row$exclude_negative_earnings,
              min_stock_price = na_to_null(row$min_stock_price),
              min_size_quantile = na_to_null(row$min_size_quantile),
              min_listing_age = na_to_null(row$min_listing_age)
            ),
            breakpoint_options_main = options_main,
            breakpoint_options_secondary = options_secondary
          ),
          data_options = data_options(price = "price", earnings = "earnings"),
          quiet = TRUE
        )

        long_short_return <- portfolio_returns |>
          compute_long_short_returns(direction = row$direction) |>
          pivot_longer(-date, names_to = "ret_type", values_to = "ret") |>
          mutate(
            ret_type = sub("ret_excess_", "", ret_type),
            id = row$id + match(ret_type, c("ew", "vw", "vw_capped")) - 1L,
            sorting_variable = row$sorting_variable,
            ret = replace_na(ret, 0)
          ) |>
          select(id, sorting_variable, date, ret_type, ret)

        dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
        write_parquet(
          long_short_return,
          file.path(output_dir, paste0("id_", row$id, ".parquet"))
        )

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

fixed_cols <- c(
  "permno",
  "date",
  "ret_excess",
  "exchange",
  "siccd",
  "price",
  "listing_age",
  "be",
  "earnings",
  "mktcap_lag"
)

unique_paths <- unique(grid$parquet_path)

# Avoid redundant computations for VW and VW_CAPPED since they use the same
# breakpoints as EW and are implemented by implement_portfolio_sorts() anyway.
# We can save 2/3 of all calculations by just computing the results once and
# expanding the ouputs to all three relevant rows.
grid_ew <- grid |>
  filter(weighting_scheme == "EW")

diagnostics_dir <- "data/task_diagnostics"
dir.create(diagnostics_dir, recursive = TRUE, showWarnings = FALSE)

for (path in unique_paths) {
  lag_label <- tools::file_path_sans_ext(basename(path))
  diagnostics_path <- file.path(
    diagnostics_dir,
    paste0(lag_label, ".parquet")
  )

  grid_file <- grid_ew |>
    filter(parquet_path == path)

  sv_cols_needed <- unique(grid_file$sorting_variable)

  message(sprintf(
    "[%s] Loading %s (%d sorting variables)...",
    Sys.time(),
    basename(path),
    length(sv_cols_needed)
  ))

  sv_lag_data <- open_dataset(path) |>
    select(all_of(c(fixed_cols, sv_cols_needed))) |>
    collect()

  shared_data <- share(sv_lag_data)
  rm(sv_lag_data)
  gc(verbose = FALSE)

  daemons(n_workers)

  everywhere(
    {
      library("dplyr")
      library("arrow")
      library("tidyr")
      library("tidyfinance")
      library("mori")
    },
    na_to_null = na_to_null,
    process_task = process_task
  )

  group_chunks <- split(grid_file, grid_file$sorting_variable, drop = TRUE)

  message(sprintf(
    "[%s] Processing %d tasks (%d sorts) from %s with %d daemon(s)...",
    Sys.time(),
    length(group_chunks),
    nrow(grid_file),
    basename(path),
    n_workers
  ))

  results <- mirai_map(
    group_chunks,
    function(chunk, shared_data, fixed_cols) {
      task_data <- shared_data[,
        c(fixed_cols, chunk$sorting_variable[1]),
        drop = FALSE
      ]

      output_dirs <- file.path(
        "data",
        "portfolio_returns",
        paste0("sorting_variable=", chunk$sorting_variable),
        paste0("sorting_variable_lag=", chunk$sorting_variable_lag)
      )

      out <- bind_rows(lapply(
        seq_len(nrow(chunk)),
        function(i) process_task(chunk[i, ], task_data, output_dirs[i])
      ))

      # shared_data holds the private materialization caches of the touched
      # columns; drop its binding too so this gc frees them before the task
      # returns instead of at some later gc during the next task.
      rm(task_data, shared_data)
      gc(verbose = FALSE)
      out
    },
    .args = list(
      shared_data = shared_data,
      fixed_cols = fixed_cols
    )
  )[.progress]

  diagnostics_file <- bind_rows(results)
  write_parquet(diagnostics_file, diagnostics_path)

  daemons(0L)

  rm(results, diagnostics_file, group_chunks, grid_file, shared_data)
  gc(verbose = FALSE)

  message(sprintf(
    "[%s] Finished %s; diagnostics written to %s.",
    Sys.time(),
    basename(path),
    diagnostics_path
  ))
}

diagnostics <- open_dataset(diagnostics_dir) |>
  collect()

write_parquet(diagnostics, "data/task_diagnostics.parquet")
message("All done! ", nrow(diagnostics), " tasks processed.")

# Clean up and finalize partition

temporary_folder <- "data/portfolio_returns_new"
open_dataset("data/portfolio_returns/") |>
  mutate(sorting_variable = sub("^sv_", "", sorting_variable)) |>
  left_join(
    grid |> select(id, sorting_method, n_portfolios_main),
    join_by(id)
  ) |>
  write_dataset(
    path = temporary_folder,
    partitioning = c(
      "sorting_variable",
      "sorting_variable_lag",
      "sorting_method",
      "n_portfolios_main"
    )
  )


fs::dir_delete("data/portfolio_returns/")
fs::file_move(temporary_folder, "data/portfolio_returns/")
