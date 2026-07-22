library("dplyr")
library("tidyr")
library("tibble")
library("arrow")

sorting_variable_information <- read_parquet(
  "data/sorting_variable_information.parquet"
)

full_grid <- expand_grid(
  sorting_variable = paste0(
    "sv_",
    sorting_variable_information$sorting_variable
  ),
  min_size_quantile = c(NA, 0.2),
  min_stock_price = NA_real_,
  min_listing_age = 24L,
  exclude_financials = c(TRUE, FALSE),
  exclude_utilities = c(TRUE, FALSE),
  exclude_negative_book_equity = c(FALSE),
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
)

grid <- full_grid |>
  # For univariate sorting, secondary breakpoints do not apply
  filter_out(when_all(
    sorting_method == "univariate",
    n_portfolios_secondary > min(full_grid$n_portfolios_secondary)
  )) |>
  mutate(
    n_portfolios_secondary = if_else(
      sorting_method == "univariate",
      NA_real_,
      n_portfolios_secondary
    )
  ) |>
  # sv_size is excluded from bivariate sorts (size already in first sort)
  filter_out(when_all(
    sorting_variable == "sv_size",
    sorting_method %in% c("bivariate-dependent", "bivariate-independent")
  )) |>
  # id is used for parallelization later
  arrange(sorting_variable_lag, sorting_variable) |>
  rowid_to_column(var = "id")

write_parquet(
  grid,
  "data/portfolio_sort_grid.parquet"
)
