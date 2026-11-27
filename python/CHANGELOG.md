# Changelog

What each release of the Python package `komira` added or changed, newest first. Installing it is
on [the install page](https://github.com/komira-ai/komira/blob/main/docs/install.md).

A change to the package never adds a line to this file. It adds one file, `python/changelog.d/<slug>.md`
(the slug is lower-case letters, digits and hyphens), holding one or more bullets: `- **Title.** text`,
a continuation line indented two spaces, no heading
([how to write one](https://github.com/komira-ai/komira/blob/main/python/README.md#changelog-entries)).
A release's version is `0.1.<n>`, given by the release workflow, so a pull request cannot know it: the
release assembles the entries, and the section `## 0.1.<n>` it ships, before the sections kept below,
lists the bullets of every file of `python/changelog.d/` in file-name order. So it lists every change
merged since the newest section kept in this file. Every version on PyPI has its section here: once a version
is on PyPI, one change moves the bullets of the files `python/changelog.d/` held at the commit it was built
from under a `## <version>` heading above the sections kept, and deletes those files.

## 0.1.1623

Two wheels: `komira-0.1.1623-py3-none-manylinux_2_35_x86_64.whl` and, the first for macOS,
`komira-0.1.1623-py3-none-macosx_11_0_arm64.whl`. `komira.abi_version()` is 1009 (ABI 1.9).

- **macOS on Apple silicon.** A second wheel, `komira-0.1.1623-py3-none-macosx_11_0_arm64.whl`, for
  macOS 11 or newer on arm64, with the same Python API as the Linux one: `pip install komira` on such a
  Mac installs it. It carries `libkomira.dylib` and the three Mojo runtime libraries it loads.
- **protobuf.** The wheel requires `protobuf>=5.29.1,<8`, so `pip install komira` installs it, and
  ships the generated plan modules a DataFrame encodes its plan with. `import komira` imports neither.
- **The pandas-shaped DataFrame, first part.** `komira.read_parquet(path)`, `komira.read_csv(path, *,
  sep=",", header="infer")` and `komira.read_json(path, lines=True)` make a lazy `komira.DataFrame` of
  a file, its schema read now, on the session given as `session=` or the process's default session.
  `df["x"]` (a `komira.Series`, whose `dtype` is the name of its Arrow type as the engine derives it,
  and whose `isin(values)` takes a list or tuple of at most 64 literals: a `Series` argument raises
  `UnsupportedOperation`, being a semi join), `df[["a", "b"]]`, `df[cond]`, `assign`, `df["x"] = ...`,
  `sort_values`, `head` and `copy` build a plan and run nothing; `materialize()` runs it through the
  engine's plan entry, with no SQL, and returns a `Result`; `explain()` returns the engine's text of
  the plan. `columns`, `dtypes` and `repr` run nothing. A pandas name komira does not have raises
  `AttributeError` saying what to write instead, and `len(df)` and the other conversions raise
  `UnsupportedOperation` naming `materialize()`. They need libkomira ABI 1.8.
- **Group-by and aggregates in the pandas-shaped DataFrame.** `df.groupby(by, *, sort=True,
  dropna=True)` gives a `komira.GroupBy` whose `agg(...)`, `sum`, `mean`, `median`, `std`, `var`,
  `min`, `max`, `count`, `size` and `nunique` return a frame of the keys and one column per output,
  sorted by the keys unless `sort=False`, with the rows of a missing key left out unless
  `dropna=False`. `df.agg(...)` and the frame's `sum`, `mean`, `median`, `std`, `var`, `min`, `max`,
  `count` and `nunique` give a one-row frame. `aggregate` is another name for `agg`, on the frame and on the `GroupBy`. A
  sum of nothing is 0, as in pandas.
  `df.drop_duplicates()` keeps one of each set of equal rows, or with `keep=False` only the rows no
  other row equals. Each builds an aggregate or distinct node of the plan, run with no SQL. The engine
  refuses at `materialize()` what it does not compute yet: `median`, `std` and `var`, a grouped sum
  or mean of a float column, the mean of a boolean column, and `min`, `max` or `nunique` of a column type it does not fold.
- **komira.pl, the polars-shaped frames (core).** `import komira.pl as kpl`: `kpl.scan_parquet`,
  `scan_ndjson` and `scan_csv` make a lazy `LazyFrame` (reading the file's schema, nothing else), and
  `select`, `with_columns`, `filter`, `sort`, `head`, `limit`, `slice`, `tail`, `top_k`, `bottom_k`,
  `drop`, `rename`, `drop_nulls` and `kpl.concat` build its plan, with `kpl.col`, `kpl.lit`,
  `kpl.when`, `kpl.len` and the expression operators (`~expr` and `expr.not_()` negate a boolean),
  `abs()`, `alias(name)` (the output name, a non-empty `str`), the null tests `is_null()` and
  `is_not_null()`, `fill_null(value)` (`strategy=` and `limit=` raise `UnsupportedOperation`), `cast`,
  `is_in`, `is_between`, aggregates (`n_unique()` counts a null as one value, as polars does, and is an
  Int64) and the `.str` functions of `kpl.ExprStringNameSpace`: `to_lowercase()`, `to_uppercase()`,
  `len_chars()`, `starts_with(prefix)`, `ends_with(suffix)` and `contains(pattern, literal=True)`, which
  refuses a regular expression. `kpl.Expr` is the class of an expression and `kpl.LazyFrame` of a
  frame, whose `width` is its number of columns and whose `collect_schema()` is `schema`. `collect()` runs the plan through the engine's plan entry, not
  through SQL, and returns a `Result`; `schema` and `explain()` run nothing. Output names and types
  follow polars 1.44.2, except that a count, `len()`, `str.len_chars()` and the sum of a boolean or a UInt32
  column are Int64 where polars gives UInt32; what the engine cannot run is refused by name (today `median()`, `std()`, `var()` and `min()` or `max()` of a string column build their
  plans and the engine refuses them when the frame is collected).
- **Notebook display.** In Jupyter and IPython a `komira.DataFrame` shows as a table of its column
  names over their types, and runs nothing; a `Result` shows its first ten rows at most, with a line
  giving the row and column counts or saying there are more. The result is still unread after it is
  shown: `to_arrow()`, `to_pandas()` and the other terminals read every row, once.
- **Memory limit.** `Session(*, threads=None, memory_limit=None)` sets the engine's worker count and
  the bytes the operators of one query may hold in total, each a positive `int` or `None` for the
  engine's own value (`ValueError` for a value below 1 or above 2**63 - 1, `TypeError` for a
  non-`int`, before the library is called; they need libkomira ABI 1.4). A query that needs more
  memory than `memory_limit` raises the new `komira.MemoryLimitError` from `Session.sql`, with
  `status` -3, `code` `"MEMORY_BUDGET_EXCEEDED"` and `step` `"execute"`; the session answers the
  next query. The engine's message names the operator that was denied memory and the budget. Code
  that catches `KomiraError` still catches it.
- **Error classes.** A refusal of `Session.sql` raises the most specific subclass of `KomiraError` its
  refusal names (they need libkomira ABI 1.7): `ParseError` for a syntax error (and any refusal of the
  parse step with no other code), `BindError` for a name that does not resolve (and any refusal of the
  bind step with no other code), `UnsupportedOperation` for a construct refused by name, `StorageError`
  for a failed storage read or write (the codes `STORAGE_NOT_FOUND`, `STORAGE_ACCESS_DENIED`,
  `STORAGE_THROTTLED`, `STORAGE_TRANSPORT`, `STORAGE_MALFORMED`, `STORAGE_OBJECT_CHANGED`, `STORAGE_IO`
  and `STORAGE_REGION_UNKNOWN`) and `CredentialsError` for a credential the engine refuses
  (`CREDENTIAL_UNBOUND`, `CREDENTIAL_NAME_CONFLICT`, `CREDENTIAL_KIND_MISMATCH`, `CREDENTIALS_NOT_FOUND`
  and `CREDENTIALS_INVALID`; no public call takes a credential yet). Code that catches `KomiraError`
  still catches each.
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
- **Threads.** A call made from a `progress` callback inside a running call of the same thread raises
  `KomiraError`, as one from a signal handler or a finalizer does.
- **Logging.** komira logs to the `logging` logger `"komira"`, which has a `NullHandler`: at `DEBUG`
  the library it loaded and each answered query's plan segments, at `INFO` a query stopped by an
  exception. It logs no query text.

## 0.1.1600

One wheel, `komira-0.1.1600-py3-none-manylinux_2_35_x86_64.whl`. `komira.abi_version()` is 1006 (ABI 1.6).

- **pyarrow.** The wheel requires `pyarrow>=25.0.1`, so `pip install komira` installs it; it had no
  requirement.
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
  once. A call from a signal handler or a finalizer made inside a running call of the same thread raises
  `KomiraError`. Of two threads reading one `Result`, one reads it and the other gets `KomiraError`. Using
  one session from two threads at once was not supported.
- **Ctrl-C.** A query cannot be interrupted while it runs: Ctrl-C during `Session.sql` raises
  `KeyboardInterrupt` once the engine has finished the query, and the session runs the next query. The
  answer that query computed is freed; before, it was never freed when the interrupt was raised before
  pyarrow took it.

## 0.1.1564

One wheel, `komira-0.1.1564-py3-none-manylinux_2_35_x86_64.whl`. `komira.abi_version()` is 1002 (ABI 1.2).

- **UDF types.** A function captured for `komira/python` takes and returns `bool`, `int8` to `int64`, `float32`,
  `float64`, `string`, `binary`, `date32`, `timestamp` (with or without a time zone), `decimal128`, `list` and
  `struct`, with any number of arguments (it carried only `int32`, `int64` and `float64`). `decimal.Decimal` takes
  `return_dtype=`; a list item or struct field is not a list, struct, decimal or zoned timestamp; a `timestamp[ns]`
  argument is refused for a `VALUES` function. A dtype is the `str()` of the pyarrow type, except that the
  floats are `float32` and `float64` (pyarrow's `float` and `double` are accepted and kept as those). A
  `TypedDict` return hint with an optional key is refused: a struct's fields are all required.

## 0.1.1545

One wheel, `komira-0.1.1545-py3-none-manylinux_2_35_x86_64.whl`. `komira.abi_version()` is 1001 (ABI 1.1).

No change to what the package does or needs is listed since the release below.

## 0.1.1525

One wheel, `komira-0.1.1525-py3-none-manylinux_2_35_x86_64.whl`. `komira.abi_version()` is 1001 (ABI 1.1).

- **Python 3.11 and 3.12.** The wheel installs on CPython 3.11, 3.12, 3.13 and 3.14: its
  `Requires-Python` is `>=3.11` (it was `>=3.13`), and its classifiers name the four. The package's
  tests and the install of each release run on all four.

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
