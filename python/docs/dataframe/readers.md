# Readers

`komira.read_parquet(path)`, `komira.read_csv(path, *, sep=",",
header="infer", chunksize=None, iterator=False)` (`header=None` for a file
with no header line; `chunksize` and `iterator` give a reader of chunks,
below) and
`komira.read_json(path, lines=True)` (one object per line; `lines=False` is
refused). Each reads the file's schema now, so a missing file raises at the
reader; paths are taken as `register_parquet` takes them. Each takes
`session=`, the session the frame runs on; without it, the process's
default session, made by the first reader called without one. No table name
is registered.

## A CSV file in chunks

`komira.read_csv(path, chunksize=n)` is pandas' loop over a file too large to
hold (pandas documentation, "Iterating through files chunk by chunk"):

```python
for chunk in komira.read_csv("sales.csv", chunksize=10_000):
    ...  # chunk is a pyarrow.Table of at most 10 000 rows
```

It returns a reader, not a frame. Iterating it yields `pyarrow.Table`s of `n`
rows each, the last one the rest of the file, each read from the file when the
loop asks for it; a file of a header alone yields none. `iterator=True` gives
the same reader, whose `get_chunk(size)` returns the next `size` rows (`size`
None: `chunksize`, or the rest of the file without one). Both raise
`StopIteration` at the end. Reaching the end, `close()` and leaving a `with`
block release the file; a closed reader raises `ValueError`. A `chunksize`
that is not an integer of at least 1 raises pandas' `ValueError: 'chunksize'
must be an integer >=1`.

A chunk is a `pyarrow.Table` because a komira `DataFrame` is a plan over a
file and holds no rows, and the engine answers a plan whole, so it would read
the file to the end before the first chunk. The reader reads the file itself,
in blocks of one MiB, with pyarrow's CSV reader in the engine's dialect.
The column names and types are the ones `read_csv` infers through the engine
from the start of the file; a later cell that does not fit its column's type
is NULL, as the engine reads it (also an integer outside int64, which the
engine wraps, and a date of the year 0000). A row with another number of
fields than the header raises `KomiraError` from the call that reads its
block, and closes the reader; the chunks whose rows all lie in earlier blocks
have arrived. The reader is in `komira/_chunks.py`.

Back to [the DataFrame overview](overview.md).
