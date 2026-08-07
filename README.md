# Tidy Finance Factor Library — Construction Pipeline

This repository contains the construction pipeline behind the **Tidy Finance Factor
Library**: the precomputed set of long-short factor return series that is published
on Hugging Face at
[`tidy-finance/factor-library`](https://huggingface.co/datasets/tidy-finance/factor-library)
and consumed through the [tidyfinance](https://github.com/tidy-finance/r-tidyfinance)
R package via `download_data("tidyfinance", "factor_library")`.

The pipeline runs [tidyfinance](https://github.com/tidy-finance/r-tidyfinance) across
many defensible construction choices and writes the resulting factor returns as a
partitioned Parquet dataset, which is then uploaded to Hugging Face. Sorting variables
are the firm-level characteristics published by [Open Source Asset
Pricing](https://www.openassetpricing.com/) (Chen and Zimmermann, 2022): the current
release covers **179 sorting variables** (the continuous OSAP predictors plus the
three CRSP-based signals OSAP adds) across **4,105,728 construction
specifications**.

## How this repository fits in

This is the **upstream** repository in a three-part system. It produces the data; the
paper and the package consume it.

| Repository / artefact | Role |
| --- | --- |
| **`factor-library`** (this repo) | Builds the factor library from raw CRSP/Compustat data and uploads it to Hugging Face. |
| [`tidy-finance/r-tidyfinance`](https://github.com/tidy-finance/r-tidyfinance) | The R package whose functions this pipeline calls and through which users retrieve the library. |
| [`tidy-finance/paper-factor-construction`](https://github.com/tidy-finance/paper-factor-construction) | The JSS manuscript and replication package, which downloads the library from Hugging Face rather than rebuilding it. |
| [`tidy-finance/factor-library`](https://huggingface.co/datasets/tidy-finance/factor-library) (Hugging Face) | The published artefact this pipeline produces. |

Most users never run this pipeline: they download precomputed series with a single
`download_data()` call. This repository exists so that the construction of the library
is **transparent, inspectable, and reproducible** — the central claim of the paper.

## Pipeline overview

The numbered scripts run in order. Each reads from and writes to `data/` (gitignored;
see [Data](#data)). Run them from the project root.

| Script | Produces | Description |
| --- | --- | --- |
| [`01_download_raw_data.R`](01_download_raw_data.R) | `crsp_monthly.parquet`, `compustat_annual.parquet`, `sorting_variables_osap.parquet`, `sorting_variable_information.parquet` | Downloads the CRSP monthly panel and a slim Compustat extract (book equity and earnings, needed only for the negative-BE/earnings filters) from WRDS, plus the Open Source Asset Pricing signed wide file and SignalDoc from Google Drive. Keeps the continuous OSAP predictors, adds the three CRSP-based signals (short-term reversal, price, size), and converts everything into monthly `sv_*` sorting variables. |
| [`02_define_portfolio_sorts_grid.R`](02_define_portfolio_sorts_grid.R) | `portfolio_sort_grid.parquet` | Expands the full grid of construction specifications (size filters, industry exclusions, lags, rebalancing, breakpoints, weighting schemes, …) over the OSAP sorting variables. |
| [`03_sorting_variables_combination_lag.R`](03_sorting_variables_combination_lag.R) | `sorting_variables_lag_{1m,3m,6m,ff}.parquet` | Join the OSAP sorting variables onto the CRSP monthly panel under each lag convention (1-month = OSAP-native timing, 3-month, 6-month, Fama-French July). |
| [`04_portfolio_sorts.R`](04_portfolio_sorts.R) | `data/portfolio_returns/` (partitioned), `task_diagnostics.parquet` | Runs `implement_portfolio_sort()` across every specification in the grid (in parallel), computes long-short returns, and writes a Hive-partitioned Parquet dataset. |
| [`05_upload_to_huggingface.R`](05_upload_to_huggingface.R) | `data/publish/portfolio_sort_grid.parquet` | Builds the Hugging-Face-ready grid (strips the `sv_` prefix from `sorting_variable`) and uploads the returns and the grid to Hugging Face via the `hf` CLI. |

The final `data/portfolio_returns/` dataset is partitioned by `sorting_variable`,
`sorting_variable_lag`, `sorting_method`, and `n_portfolios_main`, which is the layout
served from Hugging Face.

To replicate the entire library, restore the locked R environment and run the scripts
in order from the project root (WRDS credentials must be configured first — see
[Credentials](#credentials)):

```bash
# Restore the exact package versions pinned in renv.lock
Rscript -e 'renv::restore(prompt = FALSE)'

# Run the pipeline end to end
Rscript 01_download_raw_data.R            # requires WRDS credentials and Google Drive auth
Rscript 02_define_portfolio_sorts_grid.R
Rscript 03_sorting_variables_combination_lag.R
Rscript 04_portfolio_sorts.R
```

Then publish the results to Hugging Face by running the publish step (see
[Publishing to Hugging Face](#publishing-to-hugging-face)):

```bash
Rscript 05_upload_to_huggingface.R       # requires `hf auth login` first
```

## Publishing to Hugging Face

[`05_upload_to_huggingface.R`](05_upload_to_huggingface.R) publishes two datasets:

- the partitioned `data/portfolio_returns/` dataset to
  [`tidy-finance/factor-library`](https://huggingface.co/datasets/tidy-finance/factor-library), and
- the construction grid to
  [`tidy-finance/factor-library-grid`](https://huggingface.co/datasets/tidy-finance/factor-library-grid)
  (read back through the package as `factor_library_grid`).

Both uploads use the [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli)
(`hf upload`), so authenticate first with `hf auth login` using a token that has
write access to the `tidy-finance` organization.

### The `sv_` prefix

Inside the pipeline the sorting-variable columns of the panel are named `sv_<name>`
(e.g. `sv_bm`), and `portfolio_sort_grid.parquet` carries that prefix in its
`sorting_variable` values so scripts 01–05 can address those columns. The prefix is
an internal construction detail and must not leak into the published data: the
factor-library return partitions and the `download_data(..., sorting_variable = "bm")`
argument both use the bare name. `04_portfolio_sorts.R` already strips the prefix from
the returns; `05_upload_to_huggingface.R` strips it from the grid before upload so the
two published datasets agree (see
[tidy-finance/r-tidyfinance#284](https://github.com/tidy-finance/r-tidyfinance/issues/284)).

## Data

No data are committed to this repository. The `data/` directory is gitignored.

- **Raw inputs (CRSP, Compustat)** are proprietary and require an institutional
  [WRDS](https://wrds-www.wharton.upenn.edu/) subscription. They are downloaded at run
  time in `01_download_raw_data.R` and are not redistributed.
- **Firm-level characteristics** come from [Open Source Asset
  Pricing](https://www.openassetpricing.com/) (Chen and Zimmermann, 2022,
  *Critical Finance Review*) and are downloaded at run time from the OSAP Google
  Drive release in `01_download_raw_data.R`. Cite Chen and Zimmermann
  when using the library. Note that Google Drive intermittently refuses the ~1.7 GB
  download with a quota error; the script reuses a local copy under `temp/` when one
  exists, so a failed attempt can simply be retried later.
- **Output** is the factor library itself, released under **CC-BY-4.0** on Hugging
  Face. It is the authors' own artefact.

Running the full pipeline requires on the order of **tens of GB of intermediate
storage** (the extracted OSAP wide file alone is ~6 GB, and each of the four lagged
sorting-variable panels holds ~180 signal columns).

## Computational requirements

### Software

- **R** (version pinned in [`renv.lock`](renv.lock); developed under R 4.5.2).
- **[renv](https://rstudio.github.io/renv/)** to restore the locked package
  environment.
- **[tidyfinance](https://github.com/tidy-finance/r-tidyfinance)** 0.6.0 (CRAN), as
  recorded in `renv.lock`.
- **[Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli)**
  (`hf`) for the publish step.

Every package version is pinned in `renv.lock`; the `renv::restore()` call at the top
of the replication script in [Pipeline overview](#pipeline-overview) installs the exact
set. Install `renv` itself first if needed (`install.packages("renv")`).

### Credentials

WRDS credentials are required for `01_download_raw_data.R`. Configure them once with
`tidyfinance::set_wrds_credentials()` (preferred), or supply `WRDS_USER` /
`WRDS_PASSWORD` via a local `.Renviron`.

The OSAP download in the same script authenticates against Google Drive through the
[googledrive](https://googledrive.tidyverse.org/) package; the first run opens a
browser window for OAuth consent. With multiple cached Google accounts, pin the right
one via `options(gargle_oauth_email = "you@example.com")` in `.Rprofile`.

> **Do not commit credentials.** `.Renviron` is gitignored. Never store your WRDS
> password in plaintext in a tracked file; if you have, rotate it.

### Parallelism and platform

`04_portfolio_sorts.R` parallelizes across specifications with
[mirai](https://mirai.r-lib.org/) daemons and shares the input panel across workers
via [mori](https://github.com/r-lib/mori). The worker count (`n_workers`) is a
memory/throughput trade-off — see the comment at the top of the script and reduce it
on machines with less RAM.

## Reproducibility

CRSP and Compustat periodically revise historical data, OSAP publishes annual data
releases, and the library is rebuilt against the vintages current at run time. Exact
numerical reproduction therefore depends on the access date and the OSAP release. Each Hugging Face release is versioned (the Hub retains
full commit history), so results computed against an earlier release remain
reproducible by referencing the corresponding snapshot revision. The release backing
the paper was built from data accessed on **June 1, 2026**. 

## License

Code in this repository is released under the MIT License (see [LICENSE](LICENSE)). The
published factor library is released separately under CC-BY-4.0 on Hugging Face.

## Related resources

- R package: [tidyfinance on CRAN](https://CRAN.R-project.org/package=tidyfinance)
- Python package: [tidy-finance/py-tidyfinance](https://github.com/tidy-finance/py-tidyfinance)
- Factor library dataset: [tidy-finance/factor-library on Hugging Face](https://huggingface.co/datasets/tidy-finance/factor-library)
- Interactive dashboard: [factors.tidy-finance.org](https://factors.tidy-finance.org)
- Tidy Finance textbooks: [tidy-finance.org](https://tidy-finance.org)
