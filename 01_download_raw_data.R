library("dplyr")
library("tidyr")
library("readr")
library("lubridate")
library("arrow")
library("googledrive")
library("tidyfinance")

if (!dir.exists("data")) {
  dir.create("data")
}

date_start <- as.Date("1960-01-01")
date_end <- as.Date("2024-12-31")

# WRDS raw data ------------------------------------------------------------

crsp_monthly <- download_data(
  domain = "WRDS",
  dataset = "crsp_monthly",
  version = "v2",
  start_date = date_start,
  end_date = date_end,
  add_ccm_links = TRUE
)

crsp_monthly |>
  select(
    gvkey,
    permno,
    date,
    ret_excess,
    exchange,
    siccd,
    mktcap_lag,
    size = mktcap,
    price = prc,
    listing_age
  ) |>
  write_parquet("data/crsp_monthly.parquet")

# Compustat is only needed for the negative-book-equity and negative-earnings
# filters
download_data(
  domain = "WRDS",
  dataset = "compustat_annual",
  start_date = date_start,
  end_date = date_end,
  additional_columns = "ib",
  only_usd = TRUE
) |>
  semi_join(crsp_monthly, join_by(gvkey)) |>
  select(gvkey, date, be, earnings = ib) |>
  write_parquet("data/compustat_annual.parquet")

# OSAP characteristics -----------------------------------------------------

temp_path <- "temp"
dir.create(temp_path, showWarnings = FALSE)
zip_path <- file.path(temp_path, "signed_predictors_dl_wide.zip")
signal_doc_path <- file.path(temp_path, "SignalDoc.csv")

drive_auth()
drive_download(
  as_id("1ETUr7dwJvF8TCiS3hBDEqlrG36pvhKME"),
  path = zip_path,
  overwrite = TRUE
)
csv_path <- unzip(zip_path, exdir = temp_path)

drive_download(
  as_id("1EReSLb0gwUNv_7m82hoPk6AUlHnud4-s"),
  path = signal_doc_path,
  overwrite = TRUE
)

# Quantile sorts are only meaningful for continuous signals
sorting_variable_information <- read_csv(
  signal_doc_path,
  show_col_types = FALSE
) |>
  filter(Cat.Signal == "Predictor", Cat.Form == "continuous")

signal_cols <- setdiff(
  sorting_variable_information$Acronym,
  c("STreversal", "Price", "Size")
)

sorting_variable_information <- sorting_variable_information |>
  transmute(
    sorting_variable = tolower(Acronym),
    full_name = LongDescription,
    direction = "top_minus_bottom"
  ) |>
  arrange(sorting_variable)

write_parquet(
  sorting_variable_information,
  "data/sorting_variable_information.parquet"
)

osap_raw <- open_csv_dataset(
  csv_path,
  col_types = schema(sapply(c("permno", "yyyymm", signal_cols), \(x) float64()))
) |>
  mutate(date = make_date(yyyymm %/% 100L, yyyymm %% 100L, 1L)) |>
  filter(date >= date_start) |>
  select(
    permno,
    date,
    all_of(setNames(signal_cols, paste0("sv_", tolower(signal_cols))))
  )

# Sign the CRSP-based signals like the signed predictors (higher value =
# higher expected return)
crsp_signals <- crsp_monthly |>
  transmute(
    permno,
    date,
    sv_streversal = -replace_na(ret, 0),
    sv_price = -prc,
    sv_size = -mktcap
  )

osap_raw |>
  full_join(crsp_signals, by = c("permno", "date")) |>
  write_parquet("data/sorting_variables_osap.parquet")

unlink(temp_path, recursive = TRUE)
