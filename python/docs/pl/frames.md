# komira.pl: lazy frames and readers

`komira.pl` is the polars-shaped DataFrame surface
([design](../../../docs/design/dataframe_surface.md)).

```python
import komira.pl as kpl

lf = kpl.scan_parquet("trips.parquet")
out = (
    lf.filter(kpl.col("fare") > 10)
    .with_columns((kpl.col("fare") / kpl.col("miles")).alias("per_mile"))
    .sort("per_mile", descending=True)
    .head(5)
    .collect()
)
out.to_polars()
```

A frame is a plan: no verb runs a query, and `collect()` encodes the plan and
runs it through `komira_plan_stream`. Nothing writes SQL text and nothing
imports polars.

- **Readers.** `scan_parquet`, `scan_ndjson` and `scan_csv`.
- **`LazyFrame`.** `select`, `with_columns`, `filter`, `sort`, `head`,
  `limit`, `slice`, `tail`, `top_k`, `bottom_k`, `drop`, `rename`,
  `drop_nulls`, `columns`, `schema`, `explain` and `collect`;
  [`group_by`, `join` and `unique`](group_by_join_unique.md) (newer than
  0.1.1623).
- **Writing.** [`sink_csv`, `sink_parquet` and `sink_ndjson`](writing_files.md)
  (newer than 0.1.1623).
- **Module functions.** `col`, `lit`, `when`, `len`, `concat`.
- **Names it does not define** raise `AttributeError`, with the refusal
  tables' message for the names they hold.

The expressions are on [their own page](expressions.md). Not built yet:
`from_arrow`, `join_asof`, regular expressions and `.dt`.
