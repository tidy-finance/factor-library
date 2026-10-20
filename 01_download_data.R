library(tidyfinance)
library(nanoparquet)
library(dplyr)
library(lubridate)
library(googledrive)

config <- config::get(file = "config.yml")

raw_directory <- config$directories$raw
raw_files <- config$raw_files
sample_start <- as.Date(config$sample$start_date)
sample_end <- as.Date(config$sample$end_date)
dir.create(raw_directory, recursive = TRUE, showWarnings = FALSE)

# The signal documentation changes between OSAP releases, so it comes from the
# commit of the release that the characteristics come from.
download.file(
  paste0(
    "https://raw.githubusercontent.com/OpenSourceAP/CrossSection/",
    config$osap$release_commit,
    "/SignalDoc.csv"
  ),
  file.path(raw_directory, raw_files$signal_documentation),
  mode = "wb",
  quiet = TRUE
)

# The signed characteristics of Open Source Asset Pricing are public, so the
# download needs no Google account. Google Drive refuses the file for up to a
# day once too many people have downloaded it, so a file already on disk is
# kept. A refused or interrupted download leaves an incomplete file behind, so
# only a complete download gets the final name.
osap_file <- file.path(raw_directory, raw_files$osap_signals)
if (!file.exists(osap_file)) {
  incomplete_osap_file <- paste0(osap_file, ".part")
  drive_deauth()
  with_drive_quiet(
    drive_download(
      as_id(config$osap$signals_file),
      path = incomplete_osap_file,
      overwrite = TRUE
    )
  )
  stopifnot(file.rename(incomplete_osap_file, osap_file))
}

# The WRDS downloads need the credentials that tidyfinance reads from
# WRDS_USER and WRDS_PASSWORD. In version 2 of CRSP, the return of the month
# in which a stock delists includes the delisting return. The return, the price
# and the market capitalization give the signals short-term reversal, price and
# size, which the signed OSAP file omits.
download_data(
  "WRDS",
  "crsp_monthly",
  start_date = sample_start,
  end_date = sample_end,
  version = "v2",
  add_ccm_links = TRUE
) |>
  select(
    gvkey,
    permno,
    date,
    ret,
    ret_excess,
    exchange,
    siccd,
    mktcap,
    mktcap_lag,
    price = prc,
    listing_age
  ) |>
  write_parquet(file.path(raw_directory, raw_files$crsp_monthly))

# Compustat enters only through the filter on negative earnings. The first
# months of the sample use the earnings of the two fiscal years before it.
download_data(
  "WRDS",
  "compustat_annual",
  start_date = sample_start %m-% years(2),
  end_date = sample_end,
  only_usd = TRUE
) |>
  select(gvkey, date, earnings = ib) |>
  write_parquet(file.path(raw_directory, raw_files$compustat_annual))

# A trade pays the spread of the month before, and a stock that leaves a
# portfolio in the first cost month pays the spread of two months before, so
# the quotes start there. A year on disk is skipped, so an interrupted
# download resumes.
quote_directory <- file.path(raw_directory, raw_files$quotes)
dir.create(quote_directory, recursive = TRUE, showWarnings = FALSE)
first_quote_month <- as.Date(config$trading_costs$first_month) %m-% months(2)
for (quote_year in seq(year(first_quote_month), year(sample_end))) {
  quote_file <- file.path(quote_directory, paste0(quote_year, ".parquet"))
  if (file.exists(quote_file)) {
    next
  }
  download_data(
    "WRDS",
    "crsp_daily",
    start_date = make_date(quote_year, 1, 1),
    end_date = make_date(quote_year, 12, 31),
    version = "v2",
    additional_columns = c("dlybid", "dlyask")
  ) |>
    select(permno, date, dlybid, dlyask) |>
    write_parquet(quote_file)
}
