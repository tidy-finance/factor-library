library(dplyr)
library(tidyr)
library(purrr)
library(nanoparquet)
library(mirai)

config <- config::get(file = "config.yml")
# 05_portfolio_sorts.R sorts with its own fast engine. This check sorts a
# sample of specifications again with tidyfinance, the definition of a path,
# each under all three weighting schemes.
specification_count <- 300
# The published returns are single precision, which keeps about seven
# significant digits.
tolerance <- 1e-7
weighting_columns <- c("ret_excess_ew", "ret_excess_vw", "ret_excess_vw_capped")
ids_per_file <- config$ids_per_file

grid <- read_parquet(config$files$sort_grid)
specifications <- filter(grid, weighting_scheme == "EW")
stopifnot(
  grid$weighting_scheme[match(specifications$id + 1L, grid$id)] == "VW",
  grid$weighting_scheme[match(specifications$id + 2L, grid$id)] == "capped VW"
)

# Every sorting variable enters the sample, and the k-th choice of the grid
# changes its value every k specifications, so the sample meets every value of
# every choice in many combinations without random draws.
choices <- setdiff(names(grid), c("id", "sorting_variable", "weighting_scheme"))
sorting_variables <- unique(specifications$sorting_variable)
picked_ids <- map_int(seq_len(specification_count), function(position) {
  candidates <- filter(
    specifications,
    sorting_variable ==
      sorting_variables[(position - 1) %% length(sorting_variables) + 1]
  )
  for (choice_number in seq_along(choices)) {
    choice <- choices[choice_number]
    values <- sort(unique(candidates[[choice]]), na.last = TRUE)
    value <- values[((position - 1) %/% choice_number) %% length(values) + 1]
    candidates <- candidates[candidates[[choice]] %in% value, ]
  }
  candidates$id
})
checked_specifications <- filter(specifications, id %in% picked_ids)
stopifnot(map_lgl(c("sorting_variable", choices), function(choice) {
  setequal(checked_specifications[[choice]], specifications[[choice]])
}))

sort_specification <- function(specification) {
  sorting_column <- paste0("sv_", specification$sorting_variable)
  panel <- read_parquet(
    file.path(
      panel_directory,
      paste0(specification$sorting_variable_lag, ".parquet")
    ),
    col_select = c(
      "permno",
      "date",
      "ret_excess",
      "exchange",
      "siccd",
      "mktcap_lag",
      "listing_age",
      "earnings",
      sorting_column
    )
  )
  bivariate <- specification$sorting_method != "univariate"
  exchanges <- specification$breakpoints_exchanges |>
    strsplit("|", fixed = TRUE) |>
    unlist()
  # The grid stores a disabled option as NA, tidyfinance expects NULL.
  na_to_null <- function(value) if (is.na(value)) NULL else value
  # OSAP sign every characteristic so that high values predict high returns.
  long_short <- tryCatch(
    implement_portfolio_sort(
      panel,
      sorting_variables = c(sorting_column, if (bivariate) "mktcap_lag"),
      sorting_method = specification$sorting_method,
      rebalancing_month = if (specification$rebalancing == "annual") {
        rebalancing_month
      },
      portfolio_sort_options = portfolio_sort_options(
        filter_options = filter_options(
          exclude_financials = specification$exclude_financials,
          exclude_utilities = specification$exclude_utilities,
          exclude_negative_book_equity = specification$exclude_negative_book_equity,
          exclude_negative_earnings = specification$exclude_negative_earnings,
          min_stock_price = na_to_null(specification$min_stock_price),
          min_size_quantile = na_to_null(specification$min_size_quantile),
          min_listing_age = na_to_null(specification$min_listing_age)
        ),
        breakpoint_options_main = breakpoint_options(
          n_portfolios = specification$n_portfolios_main,
          breakpoints_exchanges = exchanges,
          breakpoints_min_size_threshold = na_to_null(
            specification$breakpoints_min_size_threshold
          )
        ),
        breakpoint_options_secondary = if (bivariate) {
          breakpoint_options(
            n_portfolios = specification$n_portfolios_secondary,
            breakpoints_exchanges = exchanges
          )
        }
      ),
      data_options = data_options(earnings = "earnings"),
      quiet = TRUE
    ) |>
      compute_long_short_returns(direction = "top_minus_bottom"),
    error = function(error) NULL
  )
  # A path that tidyfinance cannot sort has no rows in the library, and a month
  # without a long-short return has a return of zero.
  if (is.null(long_short) || nrow(long_short) == 0) {
    return(NULL)
  }
  long_short |>
    pivot_longer(
      all_of(weighting_columns),
      names_to = "weighting",
      values_to = "ret"
    ) |>
    transmute(
      id = specification$id + match(weighting, weighting_columns) - 1L,
      date,
      ret = coalesce(ret, 0)
    )
}

daemons(config$worker_count)
everywhere({
  library(dplyr)
  library(tidyr)
  library(nanoparquet)
  library(tidyfinance)
})
recomputed <- mirai_map(
  split(checked_specifications, checked_specifications$id),
  sort_specification,
  panel_directory = config$directories$panels,
  rebalancing_month = config$rebalancing_month,
  weighting_columns = weighting_columns
)[.stop, .progress] |>
  list_rbind()
daemons(0)

checked_ids <- c(
  checked_specifications$id,
  checked_specifications$id + 1L,
  checked_specifications$id + 2L
)
first_ids <- (checked_ids - 1L) %/% ids_per_file * ids_per_file + 1L
library_files <- file.path(
  config$directories$factor_library,
  sprintf("id_%07d-%07d.parquet", first_ids, first_ids + ids_per_file - 1L)
)
published <- unique(library_files[file.exists(library_files)]) |>
  map(\(file) filter(read_parquet(file), id %in% checked_ids)) |>
  list_rbind()

comparison <- full_join(
  published,
  recomputed,
  by = c("id", "date"),
  suffix = c("_published", "_recomputed")
)
different_months <- comparison |>
  filter(is.na(ret_published) | is.na(ret_recomputed)) |>
  distinct(id) |>
  pull(id)
different_returns <- comparison |>
  filter(
    abs(ret_published - ret_recomputed) >
      tolerance * pmax(1, abs(ret_recomputed))
  ) |>
  distinct(id) |>
  pull(id)
failing_ids <- union(different_months, different_returns)
if (length(failing_ids) > 0) {
  cli::cli_abort(c(
    paste(
      "The published returns of {length(failing_ids)} of",
      "{length(checked_ids)} checked paths differ from",
      "{.fn tidyfinance::implement_portfolio_sort}."
    ),
    "x" = if (length(different_months) > 0) {
      "Months missing or extra: ids {toString(sort(different_months))}."
    },
    "x" = if (length(different_returns) > 0) {
      "Returns differ by more than {tolerance}: ids {toString(sort(different_returns))}."
    }
  ))
}
