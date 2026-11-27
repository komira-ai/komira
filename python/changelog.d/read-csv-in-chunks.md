- **Reading a CSV file in chunks.** `komira.read_csv(path, chunksize=n)` is pandas' loop: `for
  chunk in komira.read_csv(path, chunksize=n)` yields `pyarrow.Table`s of `n` rows, the last one the
  rest, each read from the file when the loop asks for it. `iterator=True` gives the same reader, with
  `get_chunk(size)`; `close()` and a `with` block release the file early. The columns are the names
  and types `read_csv` infers from the start of the file, and a later cell that does not fit its
  type is NULL, as the engine reads it. A `chunksize` that is not an integer of at least 1 raises
  pandas' `ValueError`.
