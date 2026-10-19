library(dplyr)
library(purrr)
library(lubridate)
library(nanoparquet)
library(tidyfinance)
library(mirai)
library(mori)

config <- config::get(file = "config.yml")

raw_directory <- config$directories$raw
raw_files <- config$raw_files
panel_directory <- config$directories$panels
dir.create(panel_directory, recursive = TRUE, showWarnings = FALSE)
release_lag <- months(config$osap$release_lag_months)
rebalancing_month <- config$rebalancing_month
up_to_date_lag <- config$persistence$up_to_date_lag
minimum_stocks <- config$persistence$minimum_stocks
# Every join at the 1-, 3- and 6-month lags first dates all rows of the
# characteristics, so each task joins several of them at once.
characteristics_per_task <- 8

timings <- read_parquet(config$files$sort_grid) |>
  distinct(sorting_variable, sorting_variable_lag, rebalancing)
sorting_variables <- unique(timings$sorting_variable)

crsp_monthly <- read_parquet(file.path(raw_directory, raw_files$crsp_monthly))

# OSAP sign every characteristic so that high values predict high returns. The
# three characteristics that OSAP compute from CRSP alone come from our CRSP
# data, signed the same way. OSAP date a characteristic when it is public,
# which for annual accounts is six months after the fiscal year end. The CSV
# unzips next to the zip, because at more than 6 GB it does not fit into the
# temporary folder of a cloud job.
osap_file <- unzip(
  file.path(raw_directory, raw_files$osap_signals),
  exdir = raw_directory
)
osap_columns <- strsplit(readLines(osap_file, n = 1), ",")[[1]]
signal_columns <- osap_columns[tolower(osap_columns) %in% sorting_variables]
crsp_signals <- crsp_monthly |>
  transmute(
    permno,
    public_date = date,
    sv_streversal = -coalesce(ret, 0),
    sv_price = -price,
    sv_size = -mktcap
  ) |>
  select(permno, public_date, any_of(paste0("sv_", sorting_variables)))
# The full join gives every stock a row in every month of CRSP. The latest row
# wins even when its value is missing, so no characteristic carries over a
# missing value.
characteristics <- data.table::fread(
  osap_file,
  select = c("permno", "yyyymm", signal_columns),
  colClasses = list(numeric = c("permno", "yyyymm", signal_columns))
) |>
  as_tibble() |>
  mutate(public_date = make_date(yyyymm %/% 100L, yyyymm %% 100L, 1L)) |>
  select(
    permno,
    public_date,
    all_of(setNames(signal_columns, paste0("sv_", tolower(signal_columns))))
  ) |>
  full_join(crsp_signals, by = c("permno", "public_date")) |>
  mutate(fiscal_year_end = public_date %m-% release_lag, .after = public_date)
unlink(osap_file)

# Compustat date earnings at the fiscal year end, and OSAP would treat them as
# public six months later.
earnings <- read_parquet(
  file.path(raw_directory, raw_files$compustat_annual)
) |>
  transmute(
    gvkey,
    public_date = date %m+% release_lag,
    fiscal_year_end = date,
    earnings
  )

# The 1-, 3- and 6-month lags count from the public date. The Fama-French lag
# counts from the fiscal year end, as tidyfinance expects, which dates every
# characteristic six months before it is public. So from July of year t to
# June of t + 1, it uses the latest value public by June of t.
lags <- c(
  map(config$lags, \(lag) {
    list(
      date = "public_date",
      minimum = months(lag$minimum_months),
      maximum = months(lag$maximum_months),
      fama_french = FALSE
    )
  }),
  list(ff = list(date = "fiscal_year_end", fama_french = TRUE))
)
stopifnot(setequal(names(lags), timings$sorting_variable_lag))

# The persistence of a timing choice is the Spearman correlation across stocks
# between the value that its paths sort on and the up-to-date value, every
# month. An annual path sorts on the value of the stock's last formation month.
stocks <- crsp_monthly |>
  select(permno, gvkey, date) |>
  mutate(
    formation_date = make_date(
      year(date) - (month(date) < rebalancing_month),
      rebalancing_month
    ),
    formation_row = match(paste(permno, formation_date), paste(permno, date))
  )
month_rows <- split(seq_along(stocks$date), stocks$date)

# The lags of every characteristic are independent, so each task joins a few
# columns at every lag and measures their persistence while it holds them, and
# the panel of a lag binds the columns of all tasks to the CRSP columns.
join_columns <- function(task, stocks, values) {
  columns <- map(lags, \(lag) {
    stocks |>
      select(all_of(c(task$id, "date"))) |>
      join_lagged_values(
        select(
          values[[task$id]],
          all_of(c(task$id, date = lag$date, task$columns))
        ),
        task$id,
        min_lag = lag$minimum,
        max_lag = lag$maximum,
        ff_adjustment = lag$fama_french
      ) |>
      select(all_of(task$columns))
  })
  persistence <- timings |>
    filter(paste0("sv_", sorting_variable) %in% task$columns) |>
    pmap(\(sorting_variable, sorting_variable_lag, rebalancing) {
      column <- paste0("sv_", sorting_variable)
      up_to_date <- columns[[up_to_date_lag]][[column]]
      sorted_on <- columns[[sorting_variable_lag]][[column]]
      if (rebalancing == "annual") {
        sorted_on <- sorted_on[stocks$formation_row]
      }
      tibble(
        sorting_variable,
        sorting_variable_lag,
        rebalancing,
        date = as.Date(names(month_rows)),
        persistence = unname(map_dbl(month_rows, \(rows) {
          rows <- rows[!is.na(up_to_date[rows]) & !is.na(sorted_on[rows])]
          if (length(rows) < minimum_stocks) {
            return(NA_real_)
          }
          cor(up_to_date[rows], sorted_on[rows], method = "spearman")
        }))
      )
    }) |>
    list_rbind()
  list(columns = columns, persistence = persistence)
}
characteristic_columns <- setdiff(
  names(characteristics),
  c("permno", "public_date", "fiscal_year_end")
)
stopifnot(setequal(characteristic_columns, paste0("sv_", sorting_variables)))
column_groups <- split(
  characteristic_columns,
  ceiling(seq_along(characteristic_columns) / characteristics_per_task)
)
tasks <- c(
  list(list(id = "gvkey", columns = "earnings")),
  map(unname(column_groups), \(columns) list(id = "permno", columns = columns))
)
values <- share(list(permno = characteristics, gvkey = earnings))
stocks <- share(stocks)
daemons(config$panel_worker_count)
everywhere(
  {
    library(dplyr)
    library(purrr)
    library(lubridate)
    library(tidyfinance)
  },
  lags = lags,
  timings = timings,
  up_to_date_lag = up_to_date_lag,
  minimum_stocks = minimum_stocks,
  month_rows = month_rows
)
outputs <- mirai_map(
  tasks,
  join_columns,
  .args = list(stocks = stocks, values = values)
)[.stop, .progress]
daemons(0)

for (lag in names(lags)) {
  crsp_monthly |>
    select(
      permno,
      date,
      ret_excess,
      exchange,
      siccd,
      mktcap_lag,
      listing_age
    ) |>
    bind_cols(!!!map(outputs, \(output) output$columns[[lag]])) |>
    write_parquet(file.path(panel_directory, paste0(lag, ".parquet")))
}

map(outputs, "persistence") |>
  list_rbind() |>
  arrange(sorting_variable, sorting_variable_lag, rebalancing, date) |>
  write_parquet(config$files$persistence)
