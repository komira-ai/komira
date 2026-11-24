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

- **SQL.** `Session.sql(query)` runs one SQL statement over the session's registered tables and returns
  a `Result`, read once as a pyarrow `Table` (`to_arrow()`), a `RecordBatchReader` (`to_reader()`) or
  through the Arrow PyCapsule interface (`__arrow_c_stream__`, so `pyarrow.table(result)` reads it). A
  syntax error, an unknown table or a refused construct raises `KomiraError` from `sql` itself, with the
  engine's message. A result still reads after its session is closed. `komira.Result` is a new public name; a requested
  schema on `__arrow_c_stream__` raises a `KomiraError`.
- **Where a syntax error is.** A statement the engine cannot parse raises `KomiraError` from `sql`
  with a message that ends with where it stopped parsing, `at line <L>, column <C>`:
  `parse: SQL syntax error: expected keyword 'by' at line 1, column 42`.
- **The quickstart.** The README and the install page show a new first program that needs no file
  beside it: it writes a small Parquet file with pyarrow, runs an aggregate and a GROUP BY, reads the
  answers as rows, as a pyarrow Table, with `to_reader()` and with `pyarrow.table(result)`, and shows
  the message of a missing file and of a syntax error. Both pages show what it prints. The
  `readings.parquet` the earlier program downloaded is no longer needed.
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
