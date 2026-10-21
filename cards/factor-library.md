---
pretty_name: Tidy Finance Factor Library Portfolio Returns
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
- 1B<n<10B
task_categories:
- tabular-regression
- time-series-forecasting
configs:
- config_name: default
  data_files: "id_*.parquet"
- config_name: costs
  data_files: "costs/id_*.parquet"
---

# Tidy Finance Factor Library: Portfolio Returns

Monthly long-short portfolio returns for 179 firm characteristics across 4,105,728 portfolio construction specifications, together with the turnover, trading cost, and microcap share of every series. The returns cover US common stocks from January 1960 to December 2024, the costs from January 1994. The sample ends in December 2024 because most characteristics of the October 2025 release of Open Source Asset Pricing end there; those based on option-implied volatility end in December 2022.

## Dataset Details

### Dataset Description

The dataset contains monthly long-short portfolio returns for 179 sorting variables, the continuous predictors of the October 2025 release (v2.0.0) of [Open Source Asset Pricing](https://www.openassetpricing.com/) (Chen and Zimmermann, 2022). Three of them, short-term reversal, price, and size, are computed from CRSP. Each sorting variable is evaluated across all valid combinations of construction choices: sample exclusions, lagging conventions, breakpoints, sorting methods, weighting schemes, and rebalancing frequencies. Every return series is identified by an `id` that links to the [specification grid](https://huggingface.co/datasets/tidy-finance/factor-library-grid), which records all choices behind the series.

- **Curated by:** Christoph Frey (Lancaster University), Christoph Scheuch (Tidy Intelligence), Stefan Voigt (University of Copenhagen), Patrick Weiss (Reykjavík University)
- **License:** CC0 1.0 (see [License](#license))

### Dataset Sources

- **Construction pipeline:** [github.com/tidy-finance/factor-library](https://github.com/tidy-finance/factor-library)
- **Specification grid:** [tidy-finance/factor-library-grid](https://huggingface.co/datasets/tidy-finance/factor-library-grid)
- **R package:** [github.com/tidy-finance/r-tidyfinance](https://github.com/tidy-finance/r-tidyfinance)
- **Python package:** [github.com/tidy-finance/py-tidyfinance](https://github.com/tidy-finance/py-tidyfinance)
- **Demo:** [factors.tidy-finance.org](https://factors.tidy-finance.org/)

## Uses

### Direct Use

- Empirical asset pricing research: evaluating factor models, testing anomalies, and benchmarking portfolio strategies.
- Robustness analysis: comparing factor returns across methodological specifications.
- Trading costs: comparing returns before and after the cost of the trades a series needs.
- Teaching and replication: reproducing canonical results from the asset pricing literature.
- Sensitivity analysis: studying how construction choices (breakpoints, weighting, rebalancing, lags) affect factor premia.

### Out-of-Scope Use

- Live trading signals. The returns are historical. The costs cover the quoted half-spread only, not market impact, commissions, or short-selling fees.
- Causal inference about individual firm outcomes.

## Dataset Structure

### Returns

The returns are stored in Parquet files with three columns:

| Column | Type | Description |
| --- | --- | --- |
| `id` | int32 | Specification identifier, the key of the specification grid |
| `date` | date32 | Month of the return |
| `ret` | float32 | Monthly long-short excess return |

Everything else about a series, such as its sorting variable, lag, sorting method, or weighting scheme, is a property of its `id` and is recorded in the specification grid, so it is not repeated in the returns.

The files are cut by contiguous ranges of 1,000 ids and named after the range they cover, so the file that holds a series follows from its `id` alone:

```
id_0000001-0001000.parquet
id_0001001-0002000.parquet
...
id_4105001-4106000.parquet
```

Within a file, rows are sorted by `id` and `date`. The last file is named after its nominal range although it only holds ids up to the last id of the grid.

### Costs

The folder `costs/` holds the trading costs of every series, in files with the same names as the return files (`costs/id_0000001-0001000.parquet`, ...). The returns and the costs of a release come from the same build.

| Column | Type | Description |
| --- | --- | --- |
| `id` | int32 | Specification identifier, as in the returns |
| `date` | date32 | Month of the trades |
| `turnover` | float32 | Half the sum of the absolute trades of both legs, from 0 to 2 |
| `cost` | float32 | Sum of the absolute trades times the half-spread of each stock, in units of `ret` |
| `microcap_share` | float32 | Share of the weight in microcaps, averaged over the legs with positive weight |

- Every trade pays half the quoted spread of its stock. The quoted spread of a stock is the mean of its daily closing spreads relative to the midquote in the month before the trade, from the bid and ask prices in the CRSP daily stock file. Spreads above 50% of the midquote are dropped, and spreads above the 99th percentile of the month are set to it. A stock without quotes keeps its last spread. A stock that never had quotes gets the median spread of its size group (microcaps or other stocks) in the month.
- Between two months, the weights drift with the returns of the stocks. A trade is the difference between the new weight and the drifted weight. A stock that leaves a leg is sold at its last spread. Annual series keep their portfolio assignments for twelve months but, like the returns, use the weights of each month, so they also trade a little in the months between two formations.
- `ret - cost` is the return after costs.
- Microcaps are the stocks below the 20th percentile of NYSE market capitalization in the month.
- The costs start in January 1994, because CRSP has NYSE quotes from 1993. There is one row per `id` and month from January 1994 on, for every month in which the series has a return. `turnover` and `cost` are `0` in months without trades. `microcap_share` is missing (`NA`) in months without holdings. The trades that close the positions of the last holding month count in the month after it.

### Months without a return, and missing series

- A month without a valid long-short return is stored as exactly `0`. This happens before a signal starts, after it ends, and when a sort collapses to a single portfolio. Series of signals that end before December 2024 therefore end in a run of zeros. Genuine returns are never exactly zero, so filter `ret != 0` to restrict a series to the months in which the factor exists.
- Specifications that cannot be sorted at all have no rows, neither returns nor costs. This applies to `rdcap` and `probinformedtrading` when small firms are excluded, because Open Source Asset Pricing provides these signals only for small firms.
- All values are stored in single precision. Compare a downloaded series with a locally rebuilt one using a tolerance of about `1e-6`.

## Loading the Data

With the [tidyfinance](https://github.com/tidy-finance/r-tidyfinance) R package, version 0.8.0.9007 or later, which selects series by their construction choices or by `id` and joins the specification grid:

```r
library(tidyfinance)

download_data("Tidy Finance", "factor_library", sorting_variable = "bm")
download_factor_library_ids(c(1L, 2L, 3L))
```

With the Python `datasets` package, the default configuration reads the returns and the `costs` configuration the costs:

```python
from datasets import load_dataset

costs = load_dataset("tidy-finance/factor-library", "costs")
```

Both read every file. To read a few series, compute the file that holds an `id` and read only that file, for example with DuckDB:

```sql
SELECT *
FROM 'hf://datasets/tidy-finance/factor-library/id_0000001-0001000.parquet'
WHERE id IN (1, 2, 3);
```

A glob over all files also works, but it reads the metadata of every file first, so reading the files computed from the ids is faster.

### Pinning a release

A release goes up in many commits, and only its last commit holds all of its files. The [commit history](https://huggingface.co/datasets/tidy-finance/factor-library/commits/main) keeps all earlier releases. To make results reproducible, read the files at the last commit of a release, by its hash, instead of `main`:

```
https://huggingface.co/datasets/tidy-finance/factor-library/resolve/<revision>/id_0000001-0001000.parquet
```

In Python, `load_dataset()` and `huggingface_hub.hf_hub_download()` take the same hash as `revision`. Pin the [specification grid](https://huggingface.co/datasets/tidy-finance/factor-library-grid) to a revision of the same release, because ids can change between releases. For example, the October 2025 release of Open Source Asset Pricing renamed `zerotrade`, `zerotradealt1`, and `zerotradealt12` to `zerotrade6m`, `zerotrade1m`, and `zerotrade12m`. The ids of these signals moved with the alphabetical order of their names.

### Specification grid

Each sorting variable is evaluated across the combinations of:

| Choice | Options |
| --- | --- |
| Size filter | None; exclude stocks below the 20th NYSE size percentile |
| Exclusion of financials | No; Yes |
| Exclusion of utilities | No; Yes |
| Exclusion of negative earnings | No; Yes (also zero or missing earnings) |
| Minimum listing age | 24 months |
| Sorting variable lag | 1 month; 3 months; 6 months; Fama-French |
| Rebalancing | Monthly; Annual (July) |
| Portfolios in the main sort | 3; 5; 10 |
| Sorting method | Univariate; Bivariate dependent; Bivariate independent (size as the second variable) |
| Portfolios in the size sort | 2; 5 |
| Minimum size for the main breakpoints | None; 20th percentile |
| Breakpoint exchanges | NYSE; NYSE, AMEX, and NASDAQ |
| Weighting | Equal-weighted; Value-weighted; Capped value-weighted (market capitalization capped at the 80th percentile of NYSE stocks each month) |

Invalid combinations are removed: univariate sorts have no size sort, and `size` itself is not used in bivariate sorts. See the [specification grid](https://huggingface.co/datasets/tidy-finance/factor-library-grid) for the exact values.

## Dataset Creation

### Curation Rationale

Existing factor libraries (e.g., the French Data Library) provide canonical factor series but without code or detailed workflows, limiting reproducibility and methodological comparison. We constructed this dataset to offer a transparent, fully replicable factor library that covers a comprehensive grid of specification choices.

### Source Data

#### Data Collection and Processing

Stock returns, market capitalization, exchange, industry, and listing age come from the CRSP monthly stock file, earnings from Compustat, and bid and ask prices from the CRSP daily stock file, all via WRDS. Compustat is used only for the negative earnings filter. The sorting variables are the signed firm-level predictors of the October 2025 release of Open Source Asset Pricing. The portfolio sorts follow `implement_portfolio_sort()` of the [`tidyfinance`](https://github.com/tidy-finance/r-tidyfinance) R package. The pipeline sorts with a faster engine that reproduces it and checks a sample of about 300 specifications against tidyfinance itself. The full pipeline is in [github.com/tidy-finance/factor-library](https://github.com/tidy-finance/factor-library).

Open Source Asset Pricing date the value of a signal in the month in which it becomes public. For example, annual accounting data count as public six months after the fiscal year end. The lags build on these dates:

- **1, 3, and 6 months:** each month, a series uses the value that has been public for at least one, three, or six months. A missing value stays missing: the library does not carry an older value forward. The earnings filter uses the latest annual earnings that have been public for at least as long, where earnings count as public six months after the fiscal year end.
- **Fama-French:** in July of year t, a series takes the latest value that was public by June of year t and keeps it until June of year t + 1. The earnings filter follows Fama and French (1993): the earnings of a fiscal year that ends in calendar year t - 1 count from July of year t to June of year t + 1.

The sorts follow the rules of the development version of tidyfinance, commit [`bf87021`](https://github.com/tidy-finance/r-tidyfinance/commit/bf87021):

- The CRSP data keep the month in which a stock delists, so its delisting return enters the portfolios.
- Annual series sort in July and keep the portfolio assignments until the next June. Their filters apply in July only: a stock that passes them in July is not filtered again until the next July. Monthly series apply the filters every month.
- The size filter drops the stocks below the 20th percentile of NYSE market capitalization of the month, computed from the stocks left after the exclusion of financials and utilities.
- With a minimum size for the main breakpoints, only stocks above the 20th percentile of market capitalization of the breakpoint exchanges set the main breakpoints. In dependent bivariate sorts, this cutoff comes from all stocks of the month, not from each size portfolio.
- Capped value weights cap market capitalization at the 80th percentile of NYSE stocks of the month, as in Jensen, Kelly, and Pedersen (2023).

#### Who are the source data producers?

- CRSP (Center for Research in Security Prices) at the University of Chicago
- Compustat (S&P Global Market Intelligence)
- Open Source Asset Pricing (Andrew Y. Chen and Tom Zimmermann)

### Personal and Sensitive Information

The dataset contains aggregated portfolio-level returns and costs only. No individual-level, personal, or sensitive information is included.

## Bias, Risks, and Limitations

- **Look-ahead and survivorship bias:** The lagging conventions are designed to avoid look-ahead bias, but the dataset reflects the CRSP and Compustat universe with its known survivorship characteristics.
- **Signal coverage:** Signals start and end at different dates, which shows up as leading and trailing zero months. Some signals cover only small firms, so their series have long runs of zero months.
- **Trading costs:** The quoted half-spread understates the cost of large trades and of trades in illiquid stocks.
- **US equities only:** International markets are not included.
- **Historical data:** Returns reflect past market conditions and do not predict future performance.
- **Data vendor dependence:** Reproducing the dataset from scratch requires WRDS access (CRSP and Compustat subscriptions).
- **Data revisions:** CRSP, Compustat, and Open Source Asset Pricing revise their data between releases, so a rebuild can differ slightly from a published release. Earlier releases stay available through the commit history of this dataset.

### Recommendations

Consult the specification grid and the companion paper before using the data. When reporting results, state the `id` of every series used and the revision of the dataset.

## License

The returns and costs are released under CC0 1.0. The waiver covers the authors' contribution only and grants no rights to the CRSP and Compustat data from which the series are computed.

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

Please also cite Open Source Asset Pricing:

```bibtex
@article{ChenZimmermann.2022,
  title={Open Source Cross-Sectional Asset Pricing},
  author={Chen, Andrew Y. and Zimmermann, Tom},
  journal={Critical Finance Review},
  volume={11},
  number={2},
  pages={207--264},
  year={2022}
}
```
