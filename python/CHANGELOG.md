# Changelog

What each release of the Python package `komira` added or changed, newest first. Installing it is
on [the install page](../docs/install.md).

A release's version is `0.1.<n>`, given by the release workflow, so a pull request cannot know the
version it will ship in. A pull request that changes what the package does, or what it needs, adds
a line under `## Unreleased` (adding that heading above the newest release if it is not there), and
the release that ships it moves those lines under its own `## <version>` heading.
`//python/smoke:install_page_shows_quickstart` reads the newest version heading here: the output the
install page shows names it.

## Unreleased

- **Memory limit.** `Session(*, threads=None, memory_limit=None)` sets the engine's worker count and
  the bytes the operators of one query may hold in total, each a positive `int` or `None` for the
  engine's own value (`ValueError` for a value below 1 or above 2**63 - 1, `TypeError` for a
  non-`int`, before the library is called; they need libkomira ABI 1.4). A query that needs more
  memory than `memory_limit` raises the new `komira.MemoryLimitError` from `Session.sql`, with
  `status` -3, `code` `"MEMORY_BUDGET_EXCEEDED"` and `step` `"execute"`; the session answers the
  next query. The engine's message names the operator that was denied memory and the budget. Code
  that catches `KomiraError` still catches it.
- **CSV and JSON files.** `Session.register_csv(name, path, *, delimiter=",", header=True,
  all_varchar=False)` and `Session.register_json(name, path)` register a CSV file and a
  newline-delimited JSON file as a table for `Session.sql`, with the column names and types the
  engine infers when the call is made: the table `read_csv` or `read_json` makes of the same file.
  A relative path is resolved against the working directory and `~` is expanded. A missing, empty or
  unreadable file, or a name the session already has, raises `KomiraError` with the engine's message.
  They need libkomira ABI 1.5.
- **SQL.** `Session.sql(query)` runs one SQL statement over the session's registered tables and returns
  a `Result`, read once as a pyarrow `Table` (`to_arrow()`), a `RecordBatchReader` (`to_reader()`) or
  through the Arrow PyCapsule interface (`__arrow_c_stream__`, so `pyarrow.table(result)` reads it). A
  syntax error, an unknown table or a refused construct raises `KomiraError` from `sql` itself, with the
  engine's message. A result still reads after its session is closed. `komira.Result` is a new public name; a requested
  schema on `__arrow_c_stream__` raises a `KomiraError`.
- **pandas and polars.** `Result.to_pandas()` and `Result.to_polars()` read the answer as a pandas or
  polars `DataFrame`, converted through Arrow by pyarrow's `Table.to_pandas()` and `polars.from_arrow`.
  Neither library is a requirement of the wheel: when one is missing the call raises `ImportError`
  naming it, and the result stays unread.
- **Threads.** A `Session` may be used from several threads: its calls run one at a time, a call waiting
  for the one running on the same session, and `close()` waits for a running call. Two sessions run at
  once. A call from a signal handler, a finalizer or a `progress` callback made inside a running call of the same thread raises
  `KomiraError`. Of two threads reading one `Result`, one reads it and the other gets `KomiraError`. Using
  one session from two threads at once was not supported.
- **Ctrl-C.** Ctrl-C during `Session.sql` cancels the query: the engine stops at its next check,
  `sql` raises `KeyboardInterrupt`, and the session runs the next query. Before, a query could not be
  interrupted: the `KeyboardInterrupt` came only once the engine had finished it. The query now runs on
  a helper thread while the calling thread waits for it. Nothing a cancelled query computed is kept.
  Cancel and progress need libkomira ABI 1.6, which the wheel carries; with an older library a query
  still cannot be interrupted, and `progress` raises `KomiraError`.
- **Progress.** `Session.sql(query, progress=callback)` calls `callback(done, total)` on the calling
  thread with the plan segments the query has finished and the segments its plan has, each time that
  changes and once more when the query has answered. An exception the callback raises cancels the
  query and is raised from `sql`.
- **Logging.** komira logs to the `logging` logger `"komira"`, which has a `NullHandler`: at `DEBUG`
  the library it loaded and each answered query's plan segments, at `INFO` a query stopped by an
  exception. It logs no query text.
- **pyarrow.** The wheel requires `pyarrow>=25.0.1`, so `pip install komira` installs it; it had no
  requirement.
- **Python 3.11 and 3.12.** The wheel installs on CPython 3.11, 3.12, 3.13 and 3.14: its
  `Requires-Python` is `>=3.11` (it was `>=3.13`), and its classifiers name the four. The package's
  tests and the install of each release run on all four.
- **UDF types.** A function captured for `komira/python` takes and returns `bool`, `int8` to `int64`, `float32`,
  `float64`, `string`, `binary`, `date32`, `timestamp` (with or without a time zone), `decimal128`, `list` and
  `struct`, with any number of arguments (it carried only `int32`, `int64` and `float64`). `decimal.Decimal` takes
  `return_dtype=`; a list item or struct field is not a list, struct, decimal or zoned timestamp; a `timestamp[ns]`
  argument is refused for a `VALUES` function. A dtype is the `str()` of the pyarrow type, except that the
  floats are `float32` and `float64` (pyarrow's `float` and `double` are accepted and kept as those). A
  `TypedDict` return hint with an optional key is refused: a struct's fields are all required.

## 0.1.1512

The first release, on PyPI and TestPyPI: one wheel, `komira-0.1.1512-py3-none-manylinux_2_35_x86_64.whl`.

- **Platforms.** Linux on x86_64 only, with glibc 2.35 or newer, an x86-64-v3 CPU (AVX2, BMI2,
  FMA) and the system `libstdc++`. Python 3.13 or newer.
- **Self-contained.** The wheel carries `libkomira` and the three Mojo runtime libraries it loads, and
  requires no other package.
- **What works.** `import komira`, `komira.__version__`, `komira.abi_version()` (1001: ABI 1.1), and
  `komira.Session()` with `register_parquet(name, path)`, `close()` and `closed`. The errors
  `KomiraError`, `LibraryLoadError` and `UnsupportedCpuError`.
- **What does not.** No query runs: no SQL, no results, no DataFrame API. Only Parquet files
  register.
