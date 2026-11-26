- **The quickstart.** The README and the install page show a new first program that needs no file
  beside it: it writes a small Parquet file with pyarrow, runs an aggregate and a GROUP BY, reads the
  answers as rows, as a pyarrow Table, with `to_reader()` and with `pyarrow.table(result)`, and shows
  the message of a missing file and of a syntax error. Both pages show what it prints. The
  `readings.parquet` the earlier program downloaded is no longer needed.
