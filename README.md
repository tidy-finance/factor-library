# Tidy Finance Factor Library — Construction Pipeline

This repository contains the construction pipeline behind the **Tidy Finance Factor
Library**: the precomputed set of long-short factor return series that is published
on Hugging Face at
[`tidy-finance/factor-library`](https://huggingface.co/datasets/tidy-finance/factor-library)
and consumed through the [tidyfinance](https://github.com/tidy-finance/r-tidyfinance)
R package via `download_data("tidyfinance", "factor_library")`.

The pipeline runs [tidyfinance](https://github.com/tidy-finance/r-tidyfinance) across
many defensible construction choices and writes the resulting factor returns as a
partitioned Parquet dataset, which is then uploaded to Hugging Face. The current
release covers **50 sorting variables** across **841,536 construction
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
| [`01_define_portfolio_sorts_grid.R`](01_define_portfolio_sorts_grid.R) | `sorting_variable_information.parquet`, `portfolio_sort_grid.parquet` | Defines the 50 sorting variables and expands the full grid of construction specifications (size filters, industry exclusions, lags, rebalancing, breakpoints, weighting schemes, …). |
| [`02_download_raw_data.R`](02_download_raw_data.R) | `crsp_monthly`, `crsp_daily`, `compustat_annual`, `compustat_quarterly`, `factors_ff_5_*` | Downloads raw CRSP, Compustat, and Fama-French data from WRDS / Ken French's Data Library via `tidyfinance::download_data()`. |
| [`03_sorting_variables_monthly.R`](03_sorting_variables_monthly.R)<br>[`03_sorting_variables_quarterly.R`](03_sorting_variables_quarterly.R)<br>[`03_sorting_variables_yearly.R`](03_sorting_variables_yearly.R) | `sorting_variables_{monthly,quarterly,yearly}.parquet` | Construct each sorting variable at its native frequency from the raw data. |
| [`04_sorting_variables_combination_lag.R`](04_sorting_variables_combination_lag.R) | `sorting_variables_lag_{3m,6m,ff}.parquet` | Join the frequency-specific sorting variables onto the CRSP monthly panel under each lag convention (3-month, 6-month, Fama-French July). |
| [`05_portfolio_sorts.R`](05_portfolio_sorts.R) | `data/portfolio_returns/` (partitioned), `task_diagnostics.parquet` | Runs `implement_portfolio_sort()` across every specification in the grid (in parallel), computes long-short returns, and writes a Hive-partitioned Parquet dataset. |

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
Rscript 01_define_portfolio_sorts_grid.R
Rscript 02_download_raw_data.R            # requires WRDS credentials
Rscript 03_sorting_variables_monthly.R
Rscript 03_sorting_variables_quarterly.R
Rscript 03_sorting_variables_yearly.R
Rscript 04_sorting_variables_combination_lag.R
Rscript 05_portfolio_sorts.R
```

Then upload the resulting `data/portfolio_returns/` dataset to Hugging Face with the
`hf` CLI (see [Publishing to Hugging Face](#publishing-to-hugging-face)).

## Publishing to Hugging Face

The partitioned `data/portfolio_returns/` dataset (together with
`portfolio_sort_grid.parquet`, which becomes `factor_library_grid` on the Hub) is
uploaded to [`tidy-finance/factor-library`](https://huggingface.co/datasets/tidy-finance/factor-library)
using the [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli)
(`hf upload`).

<!-- TODO: this upload is currently a manual `hf` CLI step that is not scripted or
documented here. Add the exact command(s) and, ideally, a small
`06_upload_to_huggingface.{R,sh}` so the publish step is reproducible. -->

## Data

No data are committed to this repository. The `data/` directory is gitignored.

- **Raw inputs (CRSP, Compustat)** are proprietary and require an institutional
  [WRDS](https://wrds-www.wharton.upenn.edu/) subscription. They are downloaded at run
  time in `02_download_raw_data.R` and are not redistributed.
- **Public inputs** (Fama-French factors) come from Ken French's Data Library, also
  downloaded at run time.
- **Output** is the factor library itself, released under **CC-BY-4.0** on Hugging
  Face. It is the authors' own artefact.

Running the full pipeline requires on the order of **several GB of intermediate
storage** (the `crsp_daily` extract alone is ~1.5 GB) and produces large intermediate
files.

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

WRDS credentials are required for `02_download_raw_data.R`. Configure them once with
`tidyfinance::set_wrds_credentials()` (preferred), or supply `WRDS_USER` /
`WRDS_PASSWORD` via a local `.Renviron`.

> **Do not commit credentials.** `.Renviron` is gitignored. Never store your WRDS
> password in plaintext in a tracked file; if you have, rotate it.

### Parallelism and platform

`05_portfolio_sorts.R` parallelizes across specifications with the
[future](https://future.futureverse.org/) framework. It currently uses
`plan(multicore)`, which is **fork-based and does not work on Windows** (it silently
falls back to sequential). On Windows, switch to `plan(multisession)`.

## Reproducibility

CRSP and Compustat periodically revise historical data, and the library is rebuilt
against the data vintage current at run time. Exact numerical reproduction therefore
depends on the access date. Each Hugging Face release is versioned (the Hub retains
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
