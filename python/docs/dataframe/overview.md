# The pandas-shaped DataFrame

This directory has one page for each thing the DataFrame can do. This page is
the first program and what a frame is.

```python
import komira

df = komira.read_parquet("readings.parquet")
top = (
    df[df["value"] > 20.0][["id", "value"]]
    .assign(twice=lambda d: d["value"] * 2)
    .sort_values("value", ascending=False)
    .head(2)
)
print(top.columns, top.dtypes)            # known now: nothing has run
print(top.materialize().to_arrow().to_pylist())
# [{'id': 5, 'value': 50.5, 'twice': 101.0}, {'id': 4, 'value': 40.5, 'twice': 81.0}]
```

A frame is a plan. No verb runs a query: `materialize()` encodes the plan and
runs it through the engine's plan entry (`komira_plan_stream`, which takes no
SQL), and returns a `Result`, read once as above. Every call runs the plan
again. The install test runs this program on the installed wheel.

- [Readers](readers.md): `read_parquet`, `read_csv`, `read_json`.
- [Verbs](verbs.md): subscripts, `assign`, `sort_values`, `head`, `copy`.
- [Missing values](missing_values.md): `fillna`, `dropna`, `replace` (newer than 0.1.1623).
- [Names and types](names_and_types.md): `rename`, `add_prefix`, `add_suffix`, `astype` (newer than 0.1.1623).
- [tail and concat](tail_and_concat.md) (newer than 0.1.1623).
- [Series](series.md): the operators of a column, with the
  [`.str`](str_accessor.md) and [`.dt`](dt_accessor.md) accessors
  (newer than 0.1.1623).
- [Schema without a query](schema.md): `columns`, `dtypes`, `repr`.
- [Row order](row_order.md): which verbs keep an order.
- [No index, and nothing runs by accident](no_index.md): what is refused.
- [Explain](explain.md): the engine's text of a plan.
- [Writing files](writing_files.md): `to_parquet`, `to_csv`, `to_json`.
- [Group-by and aggregates](groupby.md), with
  [what the engine runs today](aggregates_engine.md) and
  [drop_duplicates](drop_duplicates.md).
- [merge, and isin with another frame](merge.md) (newer than 0.1.1623): joins.
- [Windows](windows.md): `transform`, `cumsum`, `cummin`, `cummax`, `rolling`, `rank` (newer than 0.1.1623).
- [In a notebook](display.md).

The polars-shaped surface, `komira.pl`, is in [../pl/](../pl/frames.md).
What is not built, one capability at a time, is recorded in
[the verbs document](../../../docs/design/dataframe_surface_verbs.md).
