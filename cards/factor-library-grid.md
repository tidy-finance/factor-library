---
pretty_name: Tidy Finance Factor Library Specification Grid
license: cc0-1.0
language:
- en
tags:
- finance
- asset-pricing
- factor-models
- portfolio-sorts
- empirical-finance
size_categories:
- 1M<n<10M
configs:
- config_name: default
  data_files: portfolio_sort_grid.parquet
- config_name: sorting_variables
  data_files: sorting_variables.parquet
- config_name: persistence
  data_files: sorting_variable_persistence.parquet
---

# Tidy Finance Factor Library: Specification Grid

Lookup table that maps each specification `id` to its portfolio construction choices. Use it together with the [Portfolio Returns](https://huggingface.co/datasets/tidy-finance/factor-library) dataset to select return series and to identify the choices behind each series.

## Dataset Details

### Dataset Description

The grid contains 4,105,728 specifications for 179 sorting variables, the continuous predictors of the October 2025 release (v2.0.0) of Open Source Asset Pricing. Each row defines a complete set of construction choices: sample exclusions, lagging convention, breakpoints, sorting method, weighting scheme, and rebalancing frequency. The `id` column links to the corresponding return series and trading costs in the Portfolio Returns dataset. Another table measures how up to date the characteristic is under each timing choice.

- **Curated by:** Christoph Frey (Lancaster University), Christoph Scheuch (Tidy Intelligence), Stefan Voigt (University of Copenhagen), Patrick Weiss (Reykjavík University)
- **Funded by:** Danish Finance Institute
- **License:** CC0 1.0 (see [License](#license))

### Dataset Sources

- **Construction pipeline:** [github.com/tidy-finance/factor-library](https://github.com/tidy-finance/factor-library)
- **Portfolio returns:** [tidy-finance/factor-library](https://huggingface.co/datasets/tidy-finance/factor-library)
- **R package:** [github.com/tidy-finance/r-tidyfinance](https://github.com/tidy-finance/r-tidyfinance)
- **Python package:** [github.com/tidy-finance/py-tidyfinance](https://github.com/tidy-finance/py-tidyfinance)
- **Demo:** [factors.tidy-finance.org](https://factors.tidy-finance.org/)

## Uses

### Direct Use

- Joining with the Portfolio Returns dataset to filter or group factor returns by specific methodological choices.
- Robustness and sensitivity analysis: selecting subsets of specifications to study how construction decisions affect factor premia.
- Timing choices: relating the effect of a lag or of annual rebalancing to how far the characteristic it sorts on lags behind the up-to-date value.
- Replication: documenting the exact configuration behind a reported result.

### Out-of-Scope Use

- Standalone analysis. The grid contains no return data and must be joined with the Portfolio Returns dataset via the `id` column.

## Dataset Structure

The repository holds four kinds of Parquet files:

- `portfolio_sort_grid.parquet`: the grid, with 17 columns and 4,105,728 rows.
- `portfolio_sort_grid/<sorting_variable>.parquet` (e.g., `portfolio_sort_grid/bm.parquet`): the rows of the grid for one sorting variable, at most 23,040 rows or about 115 KB each. Together these slices hold exactly the rows of the grid. They serve clients that need one sorting variable at a time, such as the [demo](https://factors.tidy-finance.org/), which runs in the browser.
- `sorting_variables.parquet`: one row per sorting variable, with its full name and the direction of its high-minus-low portfolio.
- `sorting_variable_persistence.parquet`: the persistence of every sorting variable under every timing choice, one row per sorting variable, lag, rebalancing frequency, and month.

Read each file by its name. A reader that loads every Parquet file of the repository mixes the grid with the other files.

### Grid columns

| Column | Type | Description |
|--------|------|-------------|
| `id` | int32 | Specification identifier, the key of the Portfolio Returns dataset |
| `sorting_variable` | string | Sorting characteristic, named like the Open Source Asset Pricing signals (e.g., `bm` for book-to-market, `size` for market equity) |
| `min_size_quantile` | double | Size filter: `NA` (none) or `0.2` (stocks below the 20th NYSE size percentile excluded) |
| `min_stock_price` | double | Minimum stock price: always `NA` (not applied) |
| `min_listing_age` | int32 | Minimum listing age in months: always `24` |
| `exclude_financials` | bool | Whether financial firms (SIC 6000-6799) are excluded |
| `exclude_utilities` | bool | Whether utility firms (SIC 4900-4999) are excluded |
| `exclude_negative_book_equity` | bool | Whether firms with negative book equity are excluded: always `false` |
| `exclude_negative_earnings` | bool | Whether firms with zero, negative, or missing earnings are excluded |
| `sorting_variable_lag` | string | Lagging convention: `1m`, `3m`, or `6m` (the value public for at least one, three, or six months) or `ff` (Fama-French timing). The Portfolio Returns card defines them in full |
| `rebalancing` | string | Rebalancing frequency: `monthly` or `annual` (July; the filters apply in July only) |
| `n_portfolios_main` | double | Number of portfolios in the main sort: `3`, `5`, or `10` |
| `sorting_method` | string | `univariate`, `bivariate-dependent`, or `bivariate-independent`, with size as the second variable of bivariate sorts |
| `breakpoints_min_size_threshold` | double | Minimum size of the stocks that set the main breakpoints: `NA` (none) or `0.2` (only stocks above the 20th percentile of market capitalization of the breakpoint exchanges). In dependent bivariate sorts, the cutoff comes from all stocks of the month. It applies to the main breakpoints only; the size breakpoints of bivariate sorts are not screened |
| `n_portfolios_secondary` | double | Number of size portfolios in bivariate sorts: `2` or `5`; `NA` for univariate sorts |
| `breakpoints_exchanges` | string | Exchanges whose stocks set the breakpoints: `NYSE` or `AMEX\|NASDAQ\|NYSE` |
| `weighting_scheme` | string | Portfolio weighting: `EW` (equal-weighted), `VW` (value-weighted), or `capped VW` (value-weighted with market capitalization capped at the 80th percentile of NYSE stocks each month) |

Each set of construction choices appears three times, once per weighting scheme, with consecutive ids in the order `EW`, `VW`, `capped VW`. Ids follow the alphabetical order of the sorting variables within each lag.

Invalid combinations are removed: univariate sorts have no size sort, so `n_portfolios_secondary` is `NA`, and `size` itself is not used in bivariate sorts. Specifications that cannot be sorted have no rows in the Portfolio Returns dataset; see its dataset card, which also describes the timing conventions and the sorting rules in detail.

### Sorting variable columns

| Column | Type | Description |
|--------|------|-------------|
| `sorting_variable` | string | Name of the sorting variable, as in the `sorting_variable` column of the grid |
| `full_name` | string | Description of the signal from the Open Source Asset Pricing documentation |
| `direction` | string | `top_minus_bottom` if the high-minus-low portfolio is long the top portfolio and short the bottom one, `bottom_minus_top` otherwise |

The Open Source Asset Pricing signals are signed so that higher values go with higher expected returns, so every direction is `top_minus_bottom`.

### Persistence columns

A series with a stale timing choice sorts on an older value of the characteristic than the up-to-date series. The persistence measures how similar the two values are. Each month, it is the Spearman rank correlation across all stocks between the value that the series of a timing choice sort on and the up-to-date value. The up-to-date value is the value under the `1m` lag with monthly rebalancing. An annual series sorts on the value of the stock's last July under its lag. A persistence of 1 means that both values rank the stocks the same way.

| Column | Type | Description |
|--------|------|-------------|
| `sorting_variable` | string | Name of the sorting variable, as in the grid |
| `sorting_variable_lag` | string | `1m`, `3m`, `6m`, or `ff`, as in the grid |
| `rebalancing` | string | `monthly` or `annual`, as in the grid |
| `date` | date32 | Month |
| `persistence` | double | Spearman correlation with the up-to-date value; `NA` in months with fewer than 30 stocks that have both values |

## Dataset Creation

### Curation Rationale

Factor construction involves many subjective methodological choices. Rather than committing to a single specification, we enumerate all valid combinations to enable systematic robustness analysis and transparent reporting.

### Source Data

#### Data Collection and Processing

The grid is generated programmatically from the full factorial combination of construction choices, with invalid configurations removed. See `02_define_portfolio_sorts_grid.R` in the [construction pipeline](https://github.com/tidy-finance/factor-library) for the exact generation logic. `03_stock_panels.R` computes the persistence from the stock panels, and `07_upload_to_huggingface.R` writes the published files.

The October 2025 release of Open Source Asset Pricing renamed three signals: `zerotrade`, `zerotradealt1`, and `zerotradealt12` are now `zerotrade6m`, `zerotrade1m`, and `zerotrade12m`. Their ids moved with the alphabetical order of the names, so look up ids in the grid of the same release as the returns.

#### Who are the source data producers?

The grid is a methodological artifact created by the dataset authors. The sorting variables follow the Open Source Asset Pricing release (Chen and Zimmermann, 2022). The persistence is computed from CRSP and Compustat data and the Open Source Asset Pricing signals.

### Personal and Sensitive Information

The dataset contains no personal or sensitive information. The grid describes portfolio sorting configurations, and the persistence aggregates across stocks.

## Bias, Risks, and Limitations

- The grid reflects the authors' choice of specification dimensions and does not cover all possible methodological variations (e.g., alternative industry classifications, different minimum listing requirements, or alternative risk-free rate definitions).
- Some specifications may produce portfolios with very few stocks in certain months, particularly for sorting variables with limited coverage or restrictive exclusion criteria.
- The persistence uses all stocks with both values, before the filters of a specification.

### Recommendations

Always join with the Portfolio Returns dataset via the `id` column. When reporting results, cite the specific `id` or the full set of column values to ensure reproducibility. Every release is a commit of this dataset, and the [commit history](https://huggingface.co/datasets/tidy-finance/factor-library-grid/commits/main) keeps all earlier releases. Pin both datasets to revisions of the same release, for example by reading `https://huggingface.co/datasets/tidy-finance/factor-library-grid/resolve/<revision>/portfolio_sort_grid.parquet` with the commit hash as `<revision>`.

## License

The grid, the list of sorting variables, and the persistence table are released under CC0 1.0. The waiver covers the authors' contribution only and grants no rights to the CRSP and Compustat data from which the persistence is computed. The `full_name` column copies the signal descriptions of the Open Source Asset Pricing documentation, which is under GPL-2.0, and the waiver does not cover them.

## Citation

**BibTeX:**

```bibtex
@unpublished{Frey.2026,
  title={The {Tidy Finance} Factor Library},
  author={Frey, Christoph and Scheuch, Christoph and Voigt, Stefan and Weiss, Patrick},
  type={Working paper},
  year={2026}
}
```

## Dataset Card Authors

Christoph Frey, Christoph Scheuch, Stefan Voigt, Patrick Weiss

## Dataset Card Contact

Stefan Voigt (stefan.voigt@econ.ku.dk), Patrick Weiss (patrickw@ru.is)
