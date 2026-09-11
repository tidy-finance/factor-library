library("dplyr")
library("arrow")
library("mirai")
library("mori")

# Input data is shared via mori, so transfer to workers is free; per-worker
# memory is bounded by private copies of the columns a task actually touches
# (~9 of the ~190 shared columns) plus transient sort allocations.
n_workers <- 30L

message(sprintf("Using %d worker daemon(s).", n_workers))

# filter_options() and breakpoint_options() expect NULL to disable an option;
# the grid stores disabled options as NA, so translate on the way in.
na_to_null <- function(x) {
  if (length(x) == 1L && is.na(x)) NULL else x
}

# Output layout ---------------------------------------------------------------
#
# Every task computes a chunk of specifications of the grid under all three
# weighting schemes and writes the long-short returns to a scratch file below
# `task_dir`. Once all tasks are done, the scratch files are consolidated into
# `output_dir`, which is the layout that 05_upload_to_huggingface.R publishes:
#
#   * The files hold nothing but `id`, `date`, and `ret`. Everything else about
#     a return series (sorting variable, lag, weighting scheme, ...) is a
#     property of its `id` and lives in the grid, so it is not repeated here.
#   * The files are cut by contiguous ranges of `ids_per_file` ids and named
#     after the range they cover, e.g. `id_0000001-0001000.parquet`, so the
#     file holding an id follows from the id alone:
#       id_first <- (id - 1) %/% ids_per_file * ids_per_file + 1
#       id_last <- id_first + ids_per_file - 1
#   * Within a file, rows are sorted by `id` and `date`.

task_dir <- "data/portfolio_returns_tasks"
task_index <- file.path(task_dir, "index.parquet")
output_dir <- "data/portfolio_returns"
ids_per_file <- 1000L
id_width <- 7L # Zero-padding of the ids in the file names (~4.1M ids)

# CONSOLIDATE_ONLY=true skips the sorts and rebuilds output_dir from the scratch
# files and index the last run left behind, so a failed consolidation does not
# cost the days of sorting before it.
consolidate_only <- identical(Sys.getenv("CONSOLIDATE_ONLY"), "true")

# Scratch file of a task, named after the chunk of the grid it computes
task_file <- function(sorting_variable, sorting_variable_lag, chunk_index) {
  file.path(
    task_dir,
    paste0("sorting_variable=", sorting_variable),
    paste0("sorting_variable_lag=", sorting_variable_lag),
    paste0("chunk_", chunk_index, ".parquet")
  )
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

process_task <- function(row, sorting_data) {
  warnings_collected <- character(0)

  result <- tryCatch(
    withCallingHandlers(
      {
        sorting_variables <- row$sorting_variable

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
          # breakpoints_min_size_threshold screens only the main breakpoints;
          # the secondary sort is on size itself, so its breakpoints are not
          # size-screened.
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

        # `row` is the EW row of the specification. Its VW and capped VW rows
        # carry the next two ids because `weighting_scheme` is the innermost
        # dimension of the grid (see 02_define_portfolio_sorts_grid.R).
        portfolio_returns |>
          compute_long_short_returns(direction = row$direction) |>
          pivot_longer(-date, names_to = "ret_type", values_to = "ret") |>
          mutate(
            ret_type = sub("ret_excess_", "", ret_type),
            id = row$id + match(ret_type, c("ew", "vw", "vw_capped")) - 1L,
            ret = replace_na(ret, 0)
          ) |>
          select(id, date, ret)
      },
      warning = function(w) {
        warnings_collected <<- c(warnings_collected, conditionMessage(w))
        invokeRestart("muffleWarning")
      }
    ),
    error = function(e) e
  )

  failed <- inherits(result, "error")

  list(
    diagnostics = tibble(
      id = row$id,
      status = if (failed) paste("error:", as.character(result)) else "success",
      n_warnings = length(warnings_collected),
      warnings = paste(warnings_collected, collapse = " | ")
    ),
    returns = if (failed) NULL else result
  )
}

# Only the columns that filters enabled in the grid read. Add price or be here
# before enabling min_stock_price or exclude_negative_book_equity in 02.
fixed_cols <- c(
  "permno",
  "date",
  "ret_excess",
  "exchange",
  "siccd",
  "listing_age",
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

# Scratch files of an earlier run must not end up in the published data
if (!consolidate_only && fs::dir_exists(task_dir)) {
  fs::dir_delete(task_dir)
}

task_files <- list()

for (path in if (consolidate_only) character() else unique_paths) {
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

  # One task per sorting variable is far too coarse: 179 tasks of 1920 sorts
  # each means the map ends on a few multi-hour stragglers while the rest of the
  # pool idles, and daemons beyond 179 never get work. Sub-divide so tasks
  # outnumber daemons ~20:1, capped at 500 sorts so that fewer daemons do not
  # mean coarser tasks; each chunk still holds exactly one sorting variable, so
  # the materialized column set per task is unchanged. The chunk is also the
  # scratch file, so the cap bounds the returns each worker buffers before
  # writing (~23 MB).
  rows_per_task <- min(
    500L,
    max(1L, ceiling(nrow(grid_file) / (n_workers * 20L)))
  )

  grid_file <- grid_file |>
    mutate(
      chunk_index = (row_number() - 1L) %/% rows_per_task,
      task = task_file(sorting_variable, sorting_variable_lag, chunk_index),
      .by = sorting_variable
    )

  task_files[[path]] <- select(grid_file, task_id = id, task)

  group_chunks <- group_split(grid_file, sorting_variable, chunk_index)

  message(sprintf(
    "[%s] Processing %d tasks (%d sorts) from %s with %d daemon(s)...",
    Sys.time(),
    length(group_chunks),
    nrow(grid_file),
    basename(path),
    n_workers
  ))

  map <- mirai_map(
    group_chunks,
    function(chunk, shared_data, fixed_cols) {
      task_data <- shared_data[,
        c(fixed_cols, chunk$sorting_variable[1]),
        drop = FALSE
      ]

      tasks <- lapply(
        seq_len(nrow(chunk)),
        function(i) process_task(chunk[i, ], task_data)
      )

      # One scratch file per chunk rather than per sort: per sort would make
      # ~1.4M files of ~2,300 rows and force the consolidation below to read a
      # footer per file.
      chunk_returns <- bind_rows(lapply(tasks, `[[`, "returns"))

      if (nrow(chunk_returns) > 0) {
        dir.create(
          dirname(chunk$task[1]),
          recursive = TRUE,
          showWarnings = FALSE
        )
        write_parquet(chunk_returns, chunk$task[1])
      }

      out <- bind_rows(lapply(tasks, `[[`, "diagnostics"))

      # shared_data holds the private materialization caches of the touched
      # columns; drop its binding too so this gc frees them before the task
      # returns instead of at some later gc during the next task.
      rm(task_data, shared_data, tasks, chunk_returns)
      gc(verbose = FALSE)
      out
    },
    .args = list(
      shared_data = shared_data,
      fixed_cols = fixed_cols
    )
  )

  # [.progress] collects strictly in order, so it reports the length of the
  # finished prefix rather than the number of finished tasks: one slow task
  # early in the order pins it near 0% while everything behind it has already
  # completed. Count resolved tasks directly, and log how many daemons are still
  # executing so a thinning tail shows up in the log while it happens.
  n_tasks <- length(map)
  repeat {
    n_done <- sum(vapply(map, function(x) !unresolved(x), logical(1)))
    daemon_status <- status()
    message(sprintf(
      "[%s] %d/%d tasks done (%.1f%%), %d daemon(s) executing.",
      Sys.time(),
      n_done,
      n_tasks,
      100 * n_done / n_tasks,
      daemon_status$mirai[["executing"]]
    ))
    if (n_done == n_tasks) break
    # mirai does not relaunch local daemons, so once all have exited the
    # remaining tasks would stay unresolved forever.
    if (daemon_status$connections == 0L) {
      stop(sprintf(
        "All daemons exited with %d of %d tasks unfinished.",
        n_tasks - n_done,
        n_tasks
      ))
    }
    Sys.sleep(60)
  }

  results <- map[]

  # A chunk that fails outside process_task resolves to an error value instead
  # of its diagnostics, e.g. error value 19 when its daemon was killed for
  # memory. Record its sorts as failed so the remaining lags still run and the
  # consolidation leaves them out.
  for (i in which(vapply(results, is_error_value, logical(1)))) {
    results[[i]] <- tibble(
      id = group_chunks[[i]]$id,
      status = paste(
        "error: chunk failed:",
        paste(as.character(results[[i]]), collapse = " ")
      ),
      n_warnings = 0L,
      warnings = ""
    )
  }

  diagnostics_file <- bind_rows(results)
  write_parquet(diagnostics_file, diagnostics_path)

  daemons(0L)

  rm(map, results, diagnostics_file, group_chunks, grid_file, shared_data)
  gc(verbose = FALSE)

  message(sprintf(
    "[%s] Finished %s; diagnostics written to %s.",
    Sys.time(),
    basename(path),
    diagnostics_path
  ))
}

if (consolidate_only) {
  task_files <- list(read_parquet(task_index))
} else {
  write_parquet(bind_rows(task_files), task_index)
}

diagnostics <- open_dataset(diagnostics_dir) |>
  collect()

write_parquet(diagnostics, "data/task_diagnostics.parquet")
message("All done! ", nrow(diagnostics), " tasks processed.")

# Consolidate the task files into the published layout -----------------------

message(
  sprintf("[%s] Consolidating task files into %s...", Sys.time(), output_dir)
)

# A task writes each of its EW rows under all weighting schemes, so the returns
# of a grid row sit in the task file of the EW row that agrees with it on every
# construction choice except `weighting_scheme`. Failed sorts (see
# task_diagnostics.parquet) wrote nothing, so their ids are left out of the
# published data.
succeeded <- diagnostics |>
  filter(status == "success") |>
  select(task_id = id)

if (nrow(succeeded) < nrow(diagnostics)) {
  message(
    sprintf(
      "%d of %d sorts failed; see data/task_diagnostics.parquet.",
      nrow(diagnostics) - nrow(succeeded),
      nrow(diagnostics)
    )
  )
}

id_files <- grid |>
  group_by(across(-c(id, weighting_scheme))) |>
  mutate(task_id = id[weighting_scheme == "EW"]) |>
  ungroup() |>
  select(id, task_id) |>
  semi_join(succeeded, join_by(task_id)) |>
  inner_join(bind_rows(task_files), join_by(task_id)) |>
  transmute(
    id,
    task,
    id_first = (id - 1L) %/% ids_per_file * ids_per_file + 1L,
    id_last = id_first + ids_per_file - 1L
  )

files <- id_files |>
  group_by(id_first, id_last) |>
  summarise(ids = list(id), tasks = list(unique(task)), .groups = "drop") |>
  mutate(
    file = paste0(
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

# ret holds ~95% of the bytes, so it is the only column whose encoding matters.
# float32 keeps ~7.2 significant digits against the ~5-6 carried by the CRSP
# returns it averages: worst-case error on this panel is 0.0003 basis points,
# which moves a t-statistic by <1e-7 and a 65-year compounded return by <1e-7
# relative. It does put values outside all.equal()'s default tolerance
# (1.5e-8 < float32 eps of 1.19e-7), so consumers comparing a downloaded series
# against a locally rebuilt one need tolerance = 1e-6. zstd adds ~6% over snappy
# at the same read speed and is read natively by pyarrow, polars and duckdb.
returns_schema <- schema(id = int32(), date = date32(), ret = float32())

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

  write_parquet(
    arrow_table(returns, schema = returns_schema),
    file.path(output_dir, files$file[i]),
    compression = "zstd",
    compression_level = 3
  )
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
    "Wrote %s ids (%s rows) to %d files in %s.",
    format(nrow(id_files), big.mark = ","),
    format(n_rows, big.mark = ",", scientific = FALSE),
    nrow(files),
    output_dir
  )
)
