# Tidy Finance Factor Library — Construction Pipeline

This repository builds the **Tidy Finance Factor Library** and publishes it on Hugging Face in two datasets:

- [`tidy-finance/factor-library`](https://huggingface.co/datasets/tidy-finance/factor-library): the monthly long-short return of every construction specification (path), and in `costs/` its turnover, trading cost, and microcap share.
- [`tidy-finance/factor-library-grid`](https://huggingface.co/datasets/tidy-finance/factor-library-grid): the grid of construction choices behind every `id`, one slice of it per sorting variable, the list of sorting variables, and the persistence of every timing choice.

The library covers 179 sorting variables, the continuous predictors of the October 2025 release of [Open Source Asset Pricing](https://www.openassetpricing.com/) (Chen and Zimmermann, 2022), across 4,105,728 specifications. The signed OSAP file omits three of them, short-term reversal, price, and size, which the pipeline computes from CRSP. Most users never run this pipeline. They download the series with the [tidyfinance](https://github.com/tidy-finance/r-tidyfinance) R package, the [py-tidyfinance](https://github.com/tidy-finance/py-tidyfinance) Python package, or directly from Hugging Face. The dataset cards in [`cards/`](cards) describe the published data and how to read it; this README describes how to build it.

## Pipeline

Run the scripts in order from the repository root. Each script reads its settings from [`config.yml`](config.yml) and runs on its own once the outputs of the earlier scripts exist. All data go to `data/`, which git ignores.

| Script | Reads | Writes |
| --- | --- | --- |
| [`01_download_data.R`](01_download_data.R) | WRDS, Google Drive, GitHub | `data/raw/`: CRSP monthly stock data, Compustat annual earnings, CRSP daily bid and ask prices, the OSAP signed predictors, and the OSAP signal documentation |
| [`02_define_portfolio_sorts_grid.R`](02_define_portfolio_sorts_grid.R) | signal documentation | `data/portfolio_sort_grid.parquet`, `data/sorting_variables.parquet` |
| [`03_stock_panels.R`](03_stock_panels.R) | CRSP, Compustat, OSAP, grid | `data/panels/<lag>.parquet` for the lags `1m`, `3m`, `6m`, and `ff`, `data/sorting_variable_persistence.parquet` |
| [`04_stock_costs.R`](04_stock_costs.R) | CRSP monthly data and quotes | `data/stock_costs.parquet`: the half-spread and the microcap flag of every stock and month |
| [`05_portfolio_sorts.R`](05_portfolio_sorts.R) | grid, panels, stock costs | `data/tasks/`: returns and costs of one sorting variable at one lag per file; then `data/factor_library/`, the published layout |
| [`06_check_portfolio_sorts.R`](06_check_portfolio_sorts.R) | grid, panels, `data/factor_library/` | nothing: it stops if the library differs from tidyfinance |
| [`07_upload_to_huggingface.R`](07_upload_to_huggingface.R) | `data/factor_library/`, grid, sorting variables, persistence, `cards/` | `data/factor_library_grid/`, `data/factor_library/README.md`, and the two Hugging Face datasets |

```bash
uvr sync --frozen
uvr run 01_download_data.R
uvr run 02_define_portfolio_sorts_grid.R
uvr run 03_stock_panels.R
uvr run 04_stock_costs.R
uvr run 05_portfolio_sorts.R
uvr run 06_check_portfolio_sorts.R
uvr run 07_upload_to_huggingface.R
```

Reruns pick up where a run stopped. `01_download_data.R` keeps the OSAP file and the years of quotes already on disk and downloads the rest again, and `05_portfolio_sorts.R` skips the tasks whose costs file exists. Delete `data/tasks/` before a fresh build.

`05_portfolio_sorts.R` sorts all paths of one sorting variable and one lag at once, with a fast engine that reproduces `tidyfinance::implement_portfolio_sort()`. `06_check_portfolio_sorts.R` sorts about 300 specifications again with tidyfinance itself. The sample takes every sorting variable, every value of every choice, and all three weightings, without random draws. The check stops and names the failing ids when a published return differs by more than single precision allows. It also stops when the months or the ids differ.

## Published layout

`data/factor_library/` is a mirror of the returns dataset:

- `id_0000001-0001000.parquet`, `id_0001001-0002000.parquet`, ...: the returns, with exactly the columns `id` (int32), `date` (date32), and `ret` (float32). Each file holds 1,000 consecutive ids, sorted by `id` and `date`, compressed with zstd. An id range without rows has no file.
- `costs/`: files with the same names and the columns `id`, `date`, `turnover`, `cost`, and `microcap_share` (float32).
- `README.md`: a copy of [`cards/factor-library.md`](cards/factor-library.md).

`data/factor_library_grid/` is a mirror of the grid dataset: `portfolio_sort_grid.parquet`, `portfolio_sort_grid/<sorting_variable>.parquet`, `sorting_variables.parquet`, `sorting_variable_persistence.parquet`, and `README.md`, a copy of [`cards/factor-library-grid.md`](cards/factor-library-grid.md). `07_upload_to_huggingface.R` rebuilds this folder in every run.

The grid names the sorting variables without a prefix (`bm`, not `sv_bm`). Only the columns of the stock panels carry the prefix `sv_`.

## Conventions

The dataset cards define the data in full. In short:

- **Sample.** The library runs from January 1960 to December 2024. Most characteristics of the October 2025 OSAP release end in December 2024, and those based on option-implied volatility in December 2022. CRSP has later months, but without characteristics most paths would earn zero, so the sample stops there. With a new OSAP release, update its Google Drive file, its commit, and the end date in `config.yml`.
- **Timing.** Open Source Asset Pricing date a value when it becomes public. The lags `1m`, `3m`, and `6m` use the value that has been public for at least one, three, or six months. They do not carry a value forward over months in which it is missing. The lag `ff` follows Fama and French: in July of year t, a path takes the latest value public by June of year t and keeps it until June of year t + 1.
- **Sorts.** The sorts follow the rules of tidyfinance at commit `bf87021`. CRSP keeps the months of delistings. Capped value weights cap at the 80th percentile of NYSE stocks. Annual paths apply their filters in July only. Dependent sorts compute the size cutoff of the main breakpoints once per month.
- **Zeros and missing paths.** A month without a long-short return has a return of exactly 0. A path that cannot be sorted at all has no rows.
- **Costs.** Every trade pays half the quoted spread of its stock. The costs start in January 1994, because CRSP has NYSE quotes from 1993.

## Credentials

- **WRDS** (`01_download_data.R`): tidyfinance reads the credentials from `WRDS_USER` and `WRDS_PASSWORD`. `uvr run` does not read `.Renviron`, so set them in the shell first, for example with `set -a && source .Renviron && set +a` in bash. Git ignores `.Renviron`; never commit credentials.
- **Google Drive** (`01_download_data.R`): the OSAP file downloads without a Google login. Google Drive often answers "Quota exceeded" for this file. The script then fails, and a rerun a day later continues.
- **Hugging Face** (`07_upload_to_huggingface.R`): install the [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli) and run `hf auth login` with a token that has write access to the `tidy-finance` organization.

## Computational requirements

- **Software.** R 4.6.1 and the packages in [`uvr.toml`](uvr.toml), among them tidyfinance 0.9.0.9008 from GitHub at commit `bf87021`, nanoparquet, mirai, and mori. [uvr](https://github.com/nbafrank/uvr) 0.4.7 installs R (`uvr r install 4.6.1`) and the exact package versions of [`uvr.lock`](uvr.lock) (`uvr sync --frozen`) into the project library `.uvr/library`, which `.Rprofile` activates whenever R starts in the repository root. On Linux, `uvr sync --frozen --install-system-deps` also installs the system libraries that some packages need. The upload needs the `hf` command line interface.
- **Hardware.** The full build runs on a UCloud `cpu-amd-zen5` node with 128 virtual CPUs and 384 GB of memory. Select the `cloud` profile of `config.yml` there with `export R_CONFIG_ACTIVE=cloud`. It runs 40 sort workers and 20 panel workers; the default profile runs 7 and 2. The main process of `03_stock_panels.R` holds the panels of all four lags at once, about 40 GB, so the default profile needs a machine with 64 GB of memory. A panel worker needs about 3 GB on Windows and more on Linux, and a sort worker holds more than 6 GB once it has sorted a few tasks. On Linux, glibc keeps the memory that R frees, so the workers of a long run grow until the machine runs out of memory. Fixed thresholds return that memory to the system. Set them before R starts:

  ```bash
  export MALLOC_ARENA_MAX=2 MALLOC_MMAP_THRESHOLD_=131072 MALLOC_TRIM_THRESHOLD_=131072
  ```
- **Storage.** The OSAP file takes 1.6 GB zipped and more than 6 GB unzipped, which `03_stock_panels.R` unzips next to the zip while it runs, the four stock panels tens of GB, and the published library about 12 GB of returns plus the costs.
- **Upload.** The Hub allows 1,000 API requests per five minutes and 128 commits per hour, so `07_upload_to_huggingface.R` uploads with two workers. `hf upload-large-folder` keeps its state in `data/factor_library/.cache/huggingface/`, and a rerun after an interruption continues from there. If it keeps failing because "an LFS pointer pointed to a file that does not exist", delete that folder and rerun. If uploads time out on the Xet storage backend, set `HF_HUB_DISABLE_XET=1`.

## Reproducibility

A release depends on four inputs that change over time:

- the October 2025 release (v2.0.0) of Open Source Asset Pricing, Google Drive file `1avFIMjz_7LoF3p3nO26eqLW5KdRTOdhW`, and its signal documentation at commit `b4e911e69678a7424f318617a61d813f54183123` of [OpenSourceAP/CrossSection](https://github.com/OpenSourceAP/CrossSection) (both set in `config.yml`);
- tidyfinance at commit `bf87021` (set in `uvr.toml`);
- the monthly risk-free rate of the Hugging Face dataset [`tidy-finance/risk-free`](https://huggingface.co/datasets/tidy-finance/risk-free), which tidyfinance reads at `main` when it computes the excess returns of CRSP;
- the CRSP and Compustat data on WRDS, which their vendors revise. Each release records the date of these downloads and the last commit of both datasets here. Current release: `to-be-set-after-the-release`.

The returns of a release go up in many commits, the grid in one. The last commit of each dataset completes the release, and the commit histories keep all earlier releases. Users pin both datasets to the commits of the same release, as the dataset cards explain.

## License

The code is released under the MIT License (see [LICENSE](LICENSE)). The published data are released under CC0 1.0. The waiver covers the authors' contribution only and grants no rights to the CRSP and Compustat data from which the library is computed. Cite the library and Open Source Asset Pricing as the dataset cards ask.
