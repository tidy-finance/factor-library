library(dplyr)
library(tidyr)
library(purrr)
library(nanoparquet)
library(lubridate)

config <- config::get(file = "config.yml")
costs <- config$trading_costs
cost_start <- as.Date(costs$first_month)
raw_directory <- config$directories$raw

# A trade pays half the quoted spread of the month before, so a stock that
# leaves a portfolio in the first cost month pays the spread of two months
# before, and the spreads start there.
first_quote_month <- cost_start %m-% months(2)

# The quoted spread of a month is the mean of the daily closing spreads
# relative to the midquote, and it is stored under the following month, in
# which a trade pays it.
quoted_spreads <- list.files(
  file.path(raw_directory, config$raw_files$quotes),
  full.names = TRUE
) |>
  map(function(quote_file) {
    read_parquet(quote_file) |>
      mutate(
        relative_spread = (dlyask - dlybid) / ((dlyask + dlybid) / 2),
        quote_month = floor_date(date, "month")
      ) |>
      filter(
        dlybid > 0,
        dlyask > dlybid,
        relative_spread < costs$maximum_relative_spread
      ) |>
      summarise(
        quoted_spread = mean(relative_spread),
        .by = c(permno, quote_month)
      ) |>
      transmute(permno, date = quote_month %m+% months(1), quoted_spread)
  }) |>
  list_rbind() |>
  filter(date > first_quote_month)

# Microcaps are the stocks below the 20th percentile of NYSE market
# capitalization. Extreme spreads are capped within each month. A stock
# without quotes keeps its last spread; a stock that never had one gets the
# median of its size group in the month.
stock_costs <- read_parquet(
  file.path(raw_directory, config$raw_files$crsp_monthly),
  col_select = c("permno", "date", "exchange", "mktcap_lag")
) |>
  filter(date >= first_quote_month) |>
  left_join(quoted_spreads, by = c("permno", "date")) |>
  mutate(
    microcap_cutoff = quantile(
      mktcap_lag[exchange == "NYSE"],
      costs$microcap_quantile,
      na.rm = TRUE
    ),
    microcap = !is.na(mktcap_lag) & mktcap_lag < microcap_cutoff,
    spread = pmin(
      quoted_spread,
      quantile(quoted_spread, costs$spread_winsor_quantile, na.rm = TRUE)
    ),
    .by = date
  ) |>
  arrange(permno, date) |>
  fill(spread, .direction = "down", .by = permno) |>
  mutate(
    group_spread = median(spread, na.rm = TRUE),
    .by = c(date, microcap)
  ) |>
  transmute(
    permno,
    date,
    half_spread = coalesce(spread, group_spread) / 2,
    microcap
  )
stopifnot(!anyNA(stock_costs$half_spread[stock_costs$date >= cost_start]))
write_parquet(stock_costs, config$files$stock_costs)
