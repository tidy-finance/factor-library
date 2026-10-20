library(dplyr)
library(tidyr)
library(nanoparquet)

config <- config::get(file = "config.yml")

# Quantile sorts are only meaningful for continuous signals. The documentation
# also lists short-term reversal, price and size, which come from CRSP.
sorting_variables <- read.csv(
  file.path(config$directories$raw, config$raw_files$signal_documentation)
) |>
  filter(Cat.Signal == "Predictor", Cat.Form == "continuous") |>
  transmute(
    sorting_variable = tolower(Acronym),
    full_name = LongDescription,
    direction = "top_minus_bottom"
  ) |>
  arrange(sorting_variable)

grid <- expand_grid(
  sorting_variable = sorting_variables$sorting_variable,
  min_size_quantile = c(NA, 0.2),
  min_stock_price = NA_real_,
  min_listing_age = 24L,
  exclude_financials = c(TRUE, FALSE),
  exclude_utilities = c(TRUE, FALSE),
  exclude_negative_book_equity = FALSE,
  exclude_negative_earnings = c(TRUE, FALSE),
  sorting_variable_lag = c("1m", "3m", "6m", "ff"),
  rebalancing = c("monthly", "annual"),
  n_portfolios_main = c(3, 5, 10),
  sorting_method = c(
    "univariate",
    "bivariate-dependent",
    "bivariate-independent"
  ),
  breakpoints_min_size_threshold = c(NA, 0.2),
  n_portfolios_secondary = c(2, 5),
  breakpoints_exchanges = c("NYSE", "AMEX|NASDAQ|NYSE"),
  weighting_scheme = c("EW", "VW", "capped VW")
) |>
  # A univariate sort has no secondary portfolios.
  filter_out(
    sorting_method == "univariate",
    n_portfolios_secondary > min(n_portfolios_secondary)
  ) |>
  mutate(
    n_portfolios_secondary = if_else(
      sorting_method == "univariate",
      NA_real_,
      n_portfolios_secondary
    )
  ) |>
  # The bivariate sorts also sort on market capitalization, so for size they
  # would sort on the same characteristic twice.
  filter_out(sorting_variable == "size", sorting_method != "univariate") |>
  # The id of a path is its row in this order, so the paths of one sorting
  # variable at one lag have consecutive ids, and the equal-weighted,
  # value-weighted and capped value-weighted returns of one sort have the ids
  # id, id + 1 and id + 2.
  arrange(sorting_variable_lag, sorting_variable) |>
  mutate(id = row_number(), .before = 1)

write_parquet(grid, config$files$sort_grid)
write_parquet(sorting_variables, config$files$sorting_variables)
