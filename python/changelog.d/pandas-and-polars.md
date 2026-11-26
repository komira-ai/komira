- **pandas and polars.** `Result.to_pandas()` and `Result.to_polars()` read the answer as a pandas or
  polars `DataFrame`, converted through Arrow by pyarrow's `Table.to_pandas()` and `polars.from_arrow`.
  Neither library is a requirement of the wheel: when one is missing the call raises `ImportError`
  naming it, and the result stays unread.
