library("dplyr")
library("lubridate")
library("arrow")
library("tidyfinance")

sorting_variables_osap <- read_parquet("data/sorting_variables_osap.parquet")

compustat_filters <- read_parquet("data/compustat_annual.parquet")

crsp_monthly <- read_parquet("data/crsp_monthly.parquet")

# OSAP signals are already release-lagged, so "1m" uses them at their native
# timing; 3m/6m/ff stack additional lag on top for robustness. Allow "old"
# values up to twelve months after the minimum lag (ff: as before).
lag_conventions <- list(
  "1m" = list(min_lag = months(1), max_lag = months(13), ff_adjustment = FALSE),
  "3m" = list(min_lag = months(3), max_lag = months(15), ff_adjustment = FALSE),
  "6m" = list(min_lag = months(6), max_lag = months(18), ff_adjustment = FALSE),
  "ff" = list(min_lag = months(7), max_lag = months(18), ff_adjustment = TRUE)
)

for (lag_label in names(lag_conventions)) {
  convention <- lag_conventions[[lag_label]]

  sv_lag <- crsp_monthly |>
    join_lagged_values(
      sorting_variables_osap,
      "permno",
      min_lag = convention$min_lag,
      max_lag = convention$max_lag,
      ff_adjustment = convention$ff_adjustment
    ) |>
    join_lagged_values(
      compustat_filters,
      "gvkey",
      min_lag = convention$min_lag,
      max_lag = convention$max_lag,
      ff_adjustment = convention$ff_adjustment
    ) |>
    select(
      gvkey,
      permno,
      date,
      ret_excess,
      exchange,
      siccd,
      mktcap_lag,
      price,
      size,
      listing_age,
      be,
      earnings,
      everything()
    )

  write_parquet(
    sv_lag,
    file.path("data", paste0("sorting_variables_lag_", lag_label, ".parquet"))
  )

  # Each panel holds ~180 signal columns; free it before the next convention
  rm(sv_lag)
  gc(verbose = FALSE)
}
