# Readers

`komira.read_parquet(path)`, `komira.read_csv(path, *, sep=",",
header="infer")` (`header=None` for a file with no header line) and
`komira.read_json(path, lines=True)` (one object per line; `lines=False` is
refused). Each reads the file's schema now, so a missing file raises at the
reader; paths are taken as `register_parquet` takes them. `read_parquet`
also takes a glob (`"sales/*.parquet"`, `"ds/**/*.parquet"`), whose matching
files read as one frame in sorted order of their paths, or a folder, whose
`.parquet` files below it do; the `key=value` folders of their paths are
columns after the files' own when every file has the same keys. A glob that
matches nothing raises `BindError` naming it (`PARQUET_GLOB_NO_MATCH`). Each takes
`session=`, the session the frame runs on; without it, the process's
default session, made by the first reader called without one. No table name
is registered.

Back to [the DataFrame overview](overview.md).
