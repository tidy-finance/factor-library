library(dplyr)
library(tidyr)
library(nanoparquet)

config <- config::get(file = "config.yml")

# Quantile sorts are only meaningful for continuous signals. The documentation
# also lists short-term reversal, price and size, which come from CRSP.
signal_documentation <- read.csv(
  file.path(config$directories$raw, config$raw_files$signal_documentation)
) |>
  filter(Cat.Signal == "Predictor", Cat.Form == "continuous") |>
  mutate(sorting_variable = tolower(Acronym))

sorting_variables <- signal_documentation |>
  transmute(
    sorting_variable,
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

# Three rules pick one path per sorting variable. The OSAP path maps the
# implementation of the original study, as OSAP document it, onto the nearest
# path of the grid: the long-short quantile and the holding period map to the
# nearest option on a log scale, and a signal without a quantile to deciles.
# Like OSAP, the path sorts on the value public for at least one month. Of the
# further filters of OSAP, only the NYSE size filter is on the grid. Choices
# that OSAP leave open take the option that drops no stocks.
nearest_option <- function(values, options) {
  vapply(
    values,
    \(value) options[which.min(abs(log(options) - log(value)))],
    numeric(1)
  )
}
osap_paths <- signal_documentation |>
  transmute(
    sorting_variable,
    min_size_quantile = if_else(
      grepl("me_nyse20", Filter, fixed = TRUE),
      0.2,
      NA_real_
    ),
    exclude_financials = FALSE,
    exclude_utilities = FALSE,
    exclude_negative_earnings = FALSE,
    sorting_variable_lag = "1m",
    rebalancing = if_else(
      nearest_option(Portfolio.Period, c(1, 12)) == 1,
      "monthly",
      "annual"
    ),
    n_portfolios_main = nearest_option(
      1 / coalesce(LS.Quantile, 0.1),
      c(3, 5, 10)
    ),
    sorting_method = "univariate",
    breakpoints_min_size_threshold = NA_real_,
    breakpoints_exchanges = if_else(
      Quantile.Filter == "NYSE",
      "NYSE",
      "AMEX|NASDAQ|NYSE"
    ),
    weighting_scheme = Stock.Weight
  )
osap_ids <- semi_join(grid, osap_paths, by = names(osap_paths))$id

# JKP sort into terciles with the breakpoints of the stocks above the NYSE
# 20th percentile of all exchanges, weight by market capitalization capped at
# the NYSE 80th percentile, and rebalance every month. They lag all data four
# months; the nearest lag of the grid is one month after OSAP treat a value as
# public.
jkp_ids <- grid |>
  filter(
    is.na(min_size_quantile),
    !exclude_financials,
    !exclude_utilities,
    !exclude_negative_earnings,
    sorting_variable_lag == "1m",
    rebalancing == "monthly",
    n_portfolios_main == 3,
    sorting_method == "univariate",
    breakpoints_min_size_threshold %in% 0.2,
    breakpoints_exchanges == "AMEX|NASDAQ|NYSE",
    weighting_scheme == "capped VW"
  ) |>
  pull(id)

# HXZ sort into deciles with NYSE breakpoints, weight by market
# capitalization, and exclude financial firms. They sort annual accounting
# signals at the end of June on the fiscal year that ended in the year before,
# which the Fama-French lag with annual rebalancing reproduces, and all other
# signals every month on the latest value. Their exclusion of negative book
# equity is not on the grid.
hxz_timing <- signal_documentation |>
  mutate(
    annual = Cat.Data == "Accounting" &
      !sorting_variable %in% config$hxz_monthly_accounting
  ) |>
  transmute(
    sorting_variable,
    sorting_variable_lag = if_else(annual, "ff", "1m"),
    rebalancing = if_else(annual, "annual", "monthly")
  )
hxz_ids <- grid |>
  semi_join(hxz_timing, by = names(hxz_timing)) |>
  filter(
    is.na(min_size_quantile),
    exclude_financials,
    !exclude_utilities,
    !exclude_negative_earnings,
    n_portfolios_main == 10,
    sorting_method == "univariate",
    is.na(breakpoints_min_size_threshold),
    breakpoints_exchanges == "NYSE",
    weighting_scheme == "VW"
  ) |>
  pull(id)

grid <- grid |>
  mutate(
    is_osap_path = id %in% osap_ids,
    is_jkp_path = id %in% jkp_ids,
    is_hxz_path = id %in% hxz_ids
  )
# Every rule picks exactly one path per sorting variable.
path_counts <- grid |>
  summarize(across(starts_with("is_"), sum), .by = sorting_variable)
stopifnot(all(select(path_counts, -sorting_variable) == 1))

write_parquet(grid, config$files$sort_grid)
write_parquet(sorting_variables, config$files$sorting_variables)
