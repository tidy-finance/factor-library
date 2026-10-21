library(dplyr)
library(purrr)
library(vctrs)
library(nanoparquet)
library(mirai)

config <- config::get(file = "config.yml")
worker_count <- config$worker_count
panel_directory <- config$directories$panels
task_directory <- config$directories$tasks
library_directory <- config$directories$factor_library
rebalancing_month <- config$rebalancing_month
cost_start <- as.Date(config$trading_costs$first_month)
ids_per_file <- config$ids_per_file
# tidyfinance caps the weights of capped value weighting at the 80th
# percentile of the NYSE stocks of a date.
cap_quantile <- 0.8
cap_exchange <- "NYSE"
filter_choices <- c(
  "exclude_financials",
  "exclude_utilities",
  "min_size_quantile",
  "min_listing_age",
  "exclude_negative_earnings"
)

for (kind in c("returns", "costs")) {
  dir.create(
    file.path(task_directory, kind),
    recursive = TRUE,
    showWarnings = FALSE
  )
}
grid <- read_parquet(config$files$sort_grid)
# The panels hold neither prices nor book equity.
stopifnot(
  all(is.na(grid$min_stock_price)),
  !any(grid$exclude_negative_book_equity)
)
stock_costs <- read_parquet(config$files$stock_costs)
# A task is done once its costs are written, so a rerun after an interruption
# sorts only the remaining tasks.
task_paths <- split(
  grid,
  paste0(grid$sorting_variable, "_", grid$sorting_variable_lag)
)
task_paths <- task_paths[
  !file.exists(
    file.path(task_directory, "costs", paste0(names(task_paths), ".parquet"))
  )
]

# Type-7 quantiles of x within each group, as stats::quantile computes them,
# with one row per group and one column per probability.
group_quantiles <- function(x, group, probabilities, group_count) {
  order_in_group <- order(group, x)
  x <- x[order_in_group]
  group_sizes <- tabulate(group[order_in_group], group_count)
  offsets <- cumsum(c(0, group_sizes))[seq_len(group_count)]
  result <- matrix(NA_real_, group_count, length(probabilities))
  filled <- group_sizes > 0
  filled_sizes <- group_sizes[filled]
  offset <- offsets[filled]
  for (column in seq_along(probabilities)) {
    index <- 1 + (filled_sizes - 1) * probabilities[column]
    lower <- floor(index)
    lower_value <- x[offset + lower]
    upper_value <- x[offset + ceiling(index)]
    weight <- index - lower
    interpolate <- index > lower & upper_value != lower_value
    value <- lower_value
    value[interpolate] <- (1 - weight[interpolate]) *
      lower_value[interpolate] +
      weight[interpolate] * upper_value[interpolate]
    result[filled, column] <- value
  }
  result
}

# Portfolios as tidyfinance's assign_portfolio() with compute_breakpoints()
# assigns them, for several portfolio counts from one breakpoint sample. A
# group with a constant sorting variable forms one portfolio, and a group
# without breakpoint stocks none.
assign_portfolios <- function(
  x,
  group,
  group_count,
  breakpoint_stock,
  portfolio_counts
) {
  probabilities <- map(
    portfolio_counts,
    \(count) seq(0, 1, length.out = count + 1)
  )
  breakpoints <- group_quantiles(
    x[breakpoint_stock],
    group[breakpoint_stock],
    unlist(probabilities),
    group_count
  )
  extremes <- group_quantiles(x, group, c(0, 1), group_count)
  constant <- !is.na(extremes[, 1]) & extremes[, 1] == extremes[, 2]
  column_offsets <- cumsum(c(0, head(portfolio_counts + 1, -1)))
  map2(portfolio_counts, column_offsets, function(count, offset) {
    group_breakpoints <- breakpoints[, offset + seq_len(count + 1)]
    group_breakpoints[, -1] <- group_breakpoints[, -1] + 1e-20
    portfolio <- rep(1L, length(x))
    for (edge in 2:count) {
      portfolio <- portfolio + (x >= group_breakpoints[group, edge])
    }
    portfolio[is.na(group_breakpoints[group, 1])] <- NA_integer_
    portfolio[constant[group]] <- 1L
    portfolio
  })
}

# Sums of values within the integer groups 1 to group_count.
group_sums <- function(values, group, group_count) {
  sums <- rowsum(values, group)
  result <- numeric(group_count)
  result[as.integer(rownames(sums))] <- sums[, 1]
  result
}

# The top and the bottom portfolio of a path with the weight of every stock
# within its leg under each weighting scheme. A bivariate portfolio averages
# its size groups with positive weight. Rows are the held stock-months. A
# stock lacks a size group only in a month whose breakpoint exchanges hold no
# stock; it then holds no position, as in tidyfinance.
leg_weights <- function(stocks, held, portfolio, secondary, secondary_count) {
  top <- max(portfolio)
  bottom <- min(portfolio)
  in_leg <- (portfolio == top | portfolio == bottom) & !is.na(secondary)
  rows <- held[in_leg]
  leg <- (portfolio[in_leg] == top) + 1L
  leg_month <- (stocks$month[rows] - 1L) * 2L + leg
  leg_count <- max(stocks$month) * 2L
  cell <- (leg_month - 1L) * secondary_count + secondary[in_leg]
  weights <- map(
    set_names(c("EW", "VW", "capped VW")),
    function(scheme) {
      weight <- stocks[[scheme]][rows]
      cell_total <- group_sums(weight, cell, leg_count * secondary_count)[cell]
      valid <- cell_total > 0
      valid_cells <- unique(cell[valid])
      groups_in_leg <- tabulate(
        (valid_cells - 1L) %/% secondary_count + 1L,
        leg_count
      )
      if_else(valid, weight / cell_total / groups_in_leg[leg_month], 0)
    }
  )
  list(rows = rows, leg_month = leg_month, weights = weights)
}

# Turnover, cost, and microcap share of a path in the cost months, the months
# of the path from the first cost month on. A position drifts with its return
# until the next month of the path, against which the new weight is traded; a
# stock that enters a leg is bought in full, and a stock that leaves a leg is
# sold in the next month at the spread of its last month. Annual paths keep
# their stocks for twelve months but, like tidyfinance, reset the weights
# every month.
path_costs <- function(stocks, legs, weight, cost_months, month_count) {
  in_window <- stocks$month[legs$rows] >= cost_months[1] - 1L
  rows <- legs$rows[in_window]
  leg_month <- legs$leg_month[in_window]
  weight <- weight[in_window]
  # One month more than the path has, for the exits of its last month.
  trade_month_count <- month_count + 1L
  leg_count <- trade_month_count * 2L
  month <- stocks$month[rows]
  stock_return <- stocks$ret_excess[rows]
  leg_return <- group_sums(weight * stock_return, leg_month, leg_count)
  drifted <- weight * (1 + stock_return) / (1 + leg_return[leg_month])
  # match() on one number per stock, leg, and month finds the same position a
  # month earlier or later; month counts stay far below 1e5.
  key <- (stocks$permno[rows] * 2 + (leg_month - 1L) %% 2L) * 1e5 + month
  previous <- match(key - 1, key)
  trade <- abs(weight - if_else(is.na(previous), 0, drifted[previous]))
  leaving <- is.na(match(key + 1, key))
  trades <- c(trade, abs(drifted[leaving]))
  trade_month <- c(month, month[leaving] + 1L)
  spreads <- stocks$half_spread[rows]
  spread_costs <- trades * c(spreads, spreads[leaving])
  # The microcap share averages the legs with positive weight.
  month_of_leg <- (seq_len(leg_count) - 1L) %/% 2L + 1L
  leg_microcap <- group_sums(
    weight * stocks$microcap[rows],
    leg_month,
    leg_count
  )
  weighted_legs <- group_sums(weight, leg_month, leg_count) > 0
  weighted_leg_count <- group_sums(
    as.numeric(weighted_legs),
    month_of_leg,
    trade_month_count
  )
  microcap_share <- group_sums(leg_microcap, month_of_leg, trade_month_count) /
    weighted_leg_count
  microcap_share[weighted_leg_count == 0] <- NA_real_
  tibble(
    month = cost_months,
    turnover = 0.5 *
      group_sums(trades, trade_month, trade_month_count)[cost_months],
    cost = group_sums(spread_costs, trade_month, trade_month_count)[
      cost_months
    ],
    microcap_share = microcap_share[cost_months]
  )
}

# All paths of one sorting variable at one lag, as tidyfinance's
# implement_portfolio_sort() and compute_long_short_returns() sort them: the
# screens, then the sort, then the long-short return of the top minus the
# bottom portfolio, zero where it is missing. A path that tidyfinance cannot
# sort, because no stock is left or none is assigned a portfolio, has no rows.
sort_paths <- function(paths) {
  variable <- paths$sorting_variable[1]
  lag <- paths$sorting_variable_lag[1]
  sorting_column <- paste0("sv_", variable)
  panel <- read_parquet(
    file.path(panel_directory, paste0(lag, ".parquet")),
    col_select = c(
      "permno",
      "date",
      "ret_excess",
      "exchange",
      "siccd",
      "listing_age",
      "earnings",
      "mktcap_lag",
      sorting_column
    )
  )
  names(panel)[names(panel) == sorting_column] <- "characteristic"
  calendar_month <- as.integer(format(panel$date, "%m"))
  panel$in_formation_month <- calendar_month == rebalancing_month
  # Annual portfolios formed in a July are held until the next June, so a
  # stock-month belongs to the holding period of the stock and its last July.
  formation_year <- as.integer(format(panel$date, "%Y")) -
    (calendar_month < rebalancing_month)
  panel$holding_period <- panel$permno * 1e4 + formation_year
  paths$bivariate <- paths$sorting_method != "univariate"
  returns <- list()
  costs <- list()
  for (filter_paths in vec_split(paths, paths[filter_choices])$val) {
    choice <- filter_paths[1, ]
    # The screens of tidyfinance's filter_sorting_data() in its order: the
    # NYSE size cutoff comes from the stocks left after the industry screens.
    screened <- panel
    if (choice$exclude_financials) {
      screened <- filter(screened, is.na(siccd) | !between(siccd, 6000, 6799))
    }
    if (choice$exclude_utilities) {
      screened <- filter(screened, is.na(siccd) | !between(siccd, 4900, 4999))
    }
    if (!is.na(choice$min_size_quantile)) {
      screened <- screened |>
        mutate(
          size_cutoff = quantile(
            mktcap_lag[exchange == "NYSE"],
            choice$min_size_quantile,
            na.rm = TRUE,
            names = FALSE
          ),
          .by = date
        ) |>
        filter(!is.na(mktcap_lag), mktcap_lag >= size_cutoff) |>
        select(-size_cutoff)
    }
    if (!is.na(choice$min_listing_age)) {
      screened <- filter(screened, listing_age >= choice$min_listing_age)
    }
    if (choice$exclude_negative_earnings) {
      screened <- filter(screened, earnings > 0)
    }
    any_screen <- choice$exclude_financials ||
      choice$exclude_utilities ||
      !is.na(choice$min_size_quantile) ||
      !is.na(choice$min_listing_age) ||
      choice$exclude_negative_earnings
    for (timing_paths in vec_split(
      filter_paths,
      filter_paths["rebalancing"]
    )$val) {
      annual <- timing_paths$rebalancing[1] == "annual"
      stocks <- screened
      # With annual rebalancing, tidyfinance screens in the formation month
      # only: a stock that passes keeps all its rows until the next June.
      if (annual && any_screen) {
        passed <- screened$holding_period[screened$in_formation_month]
        stocks <- panel[panel$holding_period %in% passed, ]
      }
      dates <- sort(unique(stocks$date))
      if (annual) {
        if (!any(stocks$in_formation_month)) {
          next
        }
        dates <- dates[dates >= min(stocks$date[stocks$in_formation_month])]
      }
      month_count <- length(dates)
      cost_months <- which(dates >= cost_start)
      for (sample_paths in vec_split(
        timing_paths,
        timing_paths["bivariate"]
      )$val) {
        bivariate <- sample_paths$bivariate[1]
        sample <- stocks |>
          filter(
            date >= dates[1],
            !is.na(characteristic),
            !bivariate | !is.na(mktcap_lag)
          ) |>
          arrange(date, permno) |>
          mutate(
            cap_reference = exchange %in% cap_exchange & !is.na(mktcap_lag),
            capped = pmin(
              mktcap_lag,
              quantile(
                mktcap_lag[if (any(cap_reference)) cap_reference else TRUE],
                cap_quantile,
                na.rm = TRUE,
                names = FALSE
              )
            ),
            .by = date
          ) |>
          mutate(
            EW = 1,
            VW = coalesce(mktcap_lag, 0),
            `capped VW` = coalesce(capped, 0),
            month = match(date, dates)
          ) |>
          left_join(stock_costs, by = c("permno", "date")) |>
          mutate(microcap = coalesce(microcap, FALSE))
        if (nrow(sample) == 0) {
          next
        }
        # An annual path holds in every month the assignment of the stock's
        # last formation month.
        if (annual) {
          sort_rows <- which(sample$in_formation_month)
          held_from <- match(
            sample$holding_period,
            sample$holding_period[sort_rows]
          )
        } else {
          sort_rows <- seq_len(nrow(sample))
          held_from <- sort_rows
        }
        sort_month <- sample$month[sort_rows]
        size <- sample$VW[sort_rows]
        for (exchange_paths in vec_split(
          sample_paths,
          sample_paths["breakpoints_exchanges"]
        )$val) {
          exchanges <- strsplit(
            exchange_paths$breakpoints_exchanges[1],
            "|",
            fixed = TRUE
          )[[1]]
          on_exchanges <- sample$exchange[sort_rows] %in% exchanges
          for (secondary_paths in vec_split(
            exchange_paths,
            exchange_paths["n_portfolios_secondary"]
          )$val) {
            if (bivariate) {
              secondary_count <- as.integer(
                secondary_paths$n_portfolios_secondary[1]
              )
              secondary <- assign_portfolios(
                size,
                sort_month,
                month_count,
                on_exchanges,
                secondary_count
              )[[1]]
            } else {
              secondary_count <- 1L
              secondary <- rep(1L, length(sort_rows))
            }
            for (method_paths in vec_split(
              secondary_paths,
              secondary_paths[c(
                "sorting_method",
                "breakpoints_min_size_threshold"
              )]
            )$val) {
              threshold <- method_paths$breakpoints_min_size_threshold[1]
              # Dependent sorts form the main portfolios within the size
              # groups of a month, and the stocks of a month without size
              # groups as one more group.
              dependent <- method_paths$sorting_method[1] ==
                "bivariate-dependent"
              if (dependent) {
                group <- (sort_month - 1L) *
                  (secondary_count + 1L) +
                  coalesce(secondary, secondary_count + 1L)
                group_count <- month_count * (secondary_count + 1L)
              } else {
                group <- sort_month
                group_count <- month_count
              }
              # The minimum size of breakpoint stocks comes from the
              # breakpoint exchanges of the whole month, also in dependent
              # sorts.
              breakpoint_stock <- on_exchanges
              if (!is.na(threshold)) {
                minimum_size <- group_quantiles(
                  size[on_exchanges],
                  sort_month[on_exchanges],
                  threshold,
                  month_count
                )[, 1]
                breakpoint_stock <- on_exchanges &
                  size > minimum_size[sort_month]
                breakpoint_stock[is.na(breakpoint_stock)] <- FALSE
              }
              count_groups <- vec_split(
                method_paths,
                method_paths["n_portfolios_main"]
              )
              portfolios <- assign_portfolios(
                sample$characteristic[sort_rows],
                group,
                group_count,
                breakpoint_stock,
                count_groups$key$n_portfolios_main
              )
              for (index in seq_along(portfolios)) {
                portfolio <- portfolios[[index]][held_from]
                held <- which(!is.na(portfolio))
                if (length(held) == 0) {
                  next
                }
                legs <- leg_weights(
                  sample,
                  held,
                  portfolio[held],
                  secondary[held_from[held]],
                  secondary_count
                )
                count_paths <- count_groups$val[[index]]
                for (path in seq_len(nrow(count_paths))) {
                  id <- count_paths$id[path]
                  weight <- legs$weights[[count_paths$weighting_scheme[path]]]
                  # A leg without positive weight has no return that month.
                  # Rows are months, columns the bottom and top leg.
                  leg_return <- group_sums(
                    weight * sample$ret_excess[legs$rows],
                    legs$leg_month,
                    month_count * 2L
                  )
                  leg_weight <- group_sums(
                    weight,
                    legs$leg_month,
                    month_count * 2L
                  )
                  leg_return[leg_weight <= 0] <- NA_real_
                  long_short <- matrix(leg_return, ncol = 2, byrow = TRUE)
                  returns[[length(returns) + 1]] <- tibble(
                    id = id,
                    date = dates,
                    ret = coalesce(long_short[, 2] - long_short[, 1], 0)
                  )
                  if (length(cost_months) > 0) {
                    costs[[length(costs) + 1]] <- path_costs(
                      sample,
                      legs,
                      weight,
                      cost_months,
                      month_count
                    ) |>
                      transmute(
                        id = id,
                        date = dates[month],
                        turnover,
                        cost,
                        microcap_share
                      )
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  task <- paste0(variable, "_", lag, ".parquet")
  write_parquet(
    list_rbind(
      returns,
      ptype = tibble(
        id = integer(),
        date = as.Date(character()),
        ret = numeric()
      )
    ),
    file.path(task_directory, "returns", task)
  )
  write_parquet(
    list_rbind(
      costs,
      ptype = tibble(
        id = integer(),
        date = as.Date(character()),
        turnover = numeric(),
        cost = numeric(),
        microcap_share = numeric()
      )
    ),
    file.path(task_directory, "costs", task)
  )
}
daemons(worker_count)
everywhere(
  {
    library(dplyr)
    library(purrr)
    library(vctrs)
    library(nanoparquet)
  },
  stock_costs = stock_costs,
  panel_directory = panel_directory,
  task_directory = task_directory,
  rebalancing_month = rebalancing_month,
  cost_start = cost_start,
  cap_quantile = cap_quantile,
  cap_exchange = cap_exchange,
  filter_choices = filter_choices,
  group_quantiles = group_quantiles,
  group_sums = group_sums,
  assign_portfolios = assign_portfolios,
  leg_weights = leg_weights,
  path_costs = path_costs
)
invisible(mirai_map(task_paths, sort_paths)[.stop, .progress])
daemons(0)

# The published files hold the paths of ids_per_file consecutive ids each,
# named after their id range, so the file of an id follows from the id alone.
# Values are single precision; months without a return are zero.
task_files <- paste0(
  grid$sorting_variable,
  "_",
  grid$sorting_variable_lag,
  ".parquet"
)
schemas <- list(
  returns = parquet_schema(id = "INT32", date = "DATE", ret = "FLOAT"),
  costs = parquet_schema(
    id = "INT32",
    date = "DATE",
    turnover = "FLOAT",
    cost = "FLOAT",
    microcap_share = "FLOAT"
  )
)
output_directories <- list(
  returns = library_directory,
  costs = file.path(library_directory, "costs")
)
for (kind in names(schemas)) {
  dir.create(output_directories[[kind]], recursive = TRUE, showWarnings = FALSE)
  # Files of an earlier build would otherwise survive for id ranges that are
  # empty now.
  file.remove(
    list.files(
      output_directories[[kind]],
      "^id_.*\\.parquet$",
      full.names = TRUE
    )
  )
  # Consecutive id ranges share their task files, so a task file is read
  # once while the ranges pass through it.
  loaded <- list()
  for (first_id in unique(
    (grid$id - 1L) %/% ids_per_file * ids_per_file + 1L
  )) {
    last_id <- first_id + ids_per_file - 1L
    in_range <- grid$id >= first_id & grid$id <= last_id
    needed <- unique(task_files[in_range])
    loaded <- loaded[intersect(names(loaded), needed)]
    for (task in setdiff(needed, names(loaded))) {
      loaded[[task]] <- read_parquet(file.path(task_directory, kind, task))
    }
    rows <- list_rbind(unname(loaded)) |>
      filter(id >= first_id, id <= last_id) |>
      arrange(id, date)
    if (nrow(rows) > 0) {
      write_parquet(
        rows,
        file.path(
          output_directories[[kind]],
          sprintf("id_%07d-%07d.parquet", first_id, last_id)
        ),
        schema = schemas[[kind]],
        compression = "zstd",
        # R has no single-precision type, so the Arrow schema that nanoparquet
        # embeds would declare the float columns as double, and polars refuses
        # to read such files.
        options = parquet_options(write_arrow_metadata = FALSE)
      )
    }
  }
}
