library("dplyr")
library("tidyr")
library("tibble")
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
# filters; all sorting variables come from OSAP
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

id_wide_zip <- as_id("1ETUr7dwJvF8TCiS3hBDEqlrG36pvhKME")
id_release <- as_id("1EP6oEabyZRamveGNyzYU0u6qJ-N43Qfq")
temp_path <- "temp"
dir.create(temp_path, showWarnings = FALSE)
csv_path <- file.path(temp_path, "signed_predictors_dl_wide.csv")
signal_doc_path <- file.path(temp_path, "SignalDoc.csv")

drive_auth()

if (!file.exists(csv_path)) {
  zip_path <- file.path(temp_path, "signed_predictors_dl_wide.zip")

  if (!file.exists(zip_path) || file.size(zip_path) < 1e6) {
    drive_download(id_wide_zip, path = zip_path, overwrite = TRUE)
  }

  csv_path <- unzip(zip_path, exdir = temp_path)
}

if (!file.exists(signal_doc_path)) {
  drive_ls(id_release) |>
    filter(name == "SignalDoc.csv") |>
    drive_download(path = signal_doc_path, overwrite = TRUE)
}

signal_doc <- read_csv(signal_doc_path, show_col_types = FALSE)

# Quantile sorts are only meaningful for continuous signals
continuous_acronyms <- signal_doc |>
  filter(Cat.Signal == "Predictor", Cat.Form == "continuous") |>
  pull(Acronym)

# Declare the schema: inference types early-empty columns (e.g. Activism1) as
# null and permno as int64, both of which break the join with crsp_monthly.
# Column names come from the header because they differ across OSAP releases.
header <- strsplit(readLines(csv_path, n = 1L), ",")[[1]]
osap_schema <- do.call(
  schema,
  setNames(
    lapply(header, \(x) if (x == "yyyymm") int32() else float64()),
    header
  )
)

signal_cols <- intersect(
  setdiff(header, c("permno", "yyyymm")),
  continuous_acronyms
)
stopifnot(anyDuplicated(tolower(signal_cols)) == 0)

# Values older than the largest max_lag in 03 are never joined to the panel
osap_date_start <- date_start - months(18)

osap_raw <- open_csv_dataset(csv_path, schema = osap_schema, skip = 1) |>
  mutate(date = make_date(yyyymm %/% 100L, yyyymm %% 100L, 1L)) |>
  filter(date >= osap_date_start) |>
  select(
    permno,
    date,
    all_of(setNames(signal_cols, paste0("sv_", tolower(signal_cols))))
  )

# OSAP adds these three CRSP-based signals on top of the wide file; sign them
# like the signed predictors
crsp_signals <- crsp_monthly |>
  transmute(
    permno,
    date,
    sv_streversal = -replace_na(ret, 0),
    sv_price = -log(if_else(abs(prc) > 0, abs(prc), NA_real_)),
    sv_size = -log(if_else(mktcap > 0, mktcap, NA_real_))
  )

osap_raw |>
  full_join(crsp_signals, by = c("permno", "date")) |>
  write_parquet("data/sorting_variables_osap.parquet")

unlink(temp_path, recursive = TRUE)

# The wide file is signed (higher value = higher expected return), so every
# signal sorts top minus bottom
sorting_variable_information <- tibble(
  acronym = c(signal_cols, "STreversal", "Price", "Size")
) |>
  left_join(
    signal_doc |> select(Acronym, LongDescription),
    join_by(acronym == Acronym)
  ) |>
  transmute(
    sorting_variable = tolower(acronym),
    full_name = coalesce(LongDescription, acronym),
    direction = "top_minus_bottom"
  ) |>
  arrange(sorting_variable)

write_parquet(
  sorting_variable_information,
  "data/sorting_variable_information.parquet"
)
