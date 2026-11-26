# Readers

`komira.read_parquet(path)`, `komira.read_csv(path, *, sep=",",
header="infer")` (`header=None` for a file with no header line) and
`komira.read_json(path, lines=True)` (one object per line; `lines=False` is
refused). Each reads the file's schema now, so a missing file raises at the
reader; paths are taken as `register_parquet` takes them. Each takes
`session=`, the session the frame runs on; without it, the process's
default session, made by the first reader called without one. No table name
is registered.

Back to [the DataFrame overview](overview.md).
