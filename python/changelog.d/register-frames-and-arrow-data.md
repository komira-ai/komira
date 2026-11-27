- **SQL on a DataFrame or Arrow data in memory.** `Session.register(name, obj)` registers rows in
  memory as the table `name`, as DuckDB's `register` does: a komira `DataFrame` or
  `komira.pl.LazyFrame`, whose plan runs then, or any object with the Arrow C stream interface
  (`__arrow_c_stream__`), such as a `pyarrow.Table`, `RecordBatch` or `RecordBatchReader`, a
  `Result`, or a pandas or polars DataFrame. The rows are copied when the call is made; a reader is
  read once, and giving it to `register` again raises `KomiraError`. Registering a name again
  replaces its table. A column of a nested type is refused as `UnsupportedOperation` with the code
  `TABLE_TYPE_UNSUPPORTED`, naming the column. Needs the library of ABI 1.9.
