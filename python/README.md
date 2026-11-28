# komira

komira is a SQL query engine that runs in your process. This package is its
Python binding: it carries `libkomira`, the engine as one shared library, and
calls it with `ctypes`.

**This is an early release.** It registers Parquet files as tables and runs
SQL over them, and it hands each answer to pyarrow. Two DataFrames, a pandas-shaped one
and a polars-shaped one (`komira.pl`), read files and build plans the engine
runs with no SQL; The DataFrames, below, says where each is described. More
DataFrame APIs come later.

This README, and the pages it links to, describe the package at one commit.
On PyPI that is the commit the release was built from, and every link of a
release's page opens the files of that commit. On GitHub's `main` it can be
newer than the newest release: what `main` has and 0.1.1623 does not says
"newer than 0.1.1623", and the
[changelog](https://github.com/komira-ai/komira/blob/main/python/CHANGELOG.md)
lists what each release added (on PyPI it follows this README, with the
release's own section first).

## Install

```sh
pip install komira
```

What it needs:

- **Linux on x86_64**, with glibc 2.35 or newer and an x86-64-v3 CPU (AVX2,
  BMI2, FMA: Intel Haswell, AMD Excavator or newer), or **macOS 11 or newer
  on Apple silicon** (arm64). A wheel for Linux on arm64 comes in a later
  release.
- **CPython 3.11, 3.12, 3.13 or 3.14.** One wheel serves all four, and each
  is tested (Supported Pythons, below).
- **On Linux, the system C++ runtime, `libstdc++`.** Most systems have it. A
  minimal container image may need the `libstdc++6` package (Debian, Ubuntu)
  or `libstdc++` (Fedora, RHEL). macOS has its own C++ runtime.

### What is in the wheel

libkomira needs three Mojo runtime libraries, which are Modular's and come
under Modular's licence. The wheel carries libkomira in `komira/_lib/` and, in `komira/_lib/lib/`,
its native owner libraries (Linux only: on macOS they are linked into the
dylib) and those three Mojo runtime libraries, with Modular's licence and
third-party notices beside komira's own. The Linux wheel also carries, beside
libkomira, `libkomira_udf_python.so`, the runtime that runs Python UDFs in
worker processes; the engine opens it the first time a plan with UDFs runs on a
session, and no public verb builds such a plan yet. It requires two other
distributions, which `pip install komira` installs: `pyarrow>=25.0.1`, which a
result is read as, and `protobuf>=5.29.1,<8`, which a DataFrame's plan is
encoded with (the generated plan modules are in the wheel, at
`komira/plan/v1/`).
The runtime libraries add about 2 MB uncompressed.

The Linux wheel and the macOS wheel (macOS 11 or later, Apple silicon) are one
distribution, `komira`, with one version and the same Python API.

The install page,
[docs/install.md](https://github.com/komira-ai/komira/blob/main/docs/install.md),
says what each requirement means and what to do when the install or the first
load fails. What each release changed is in the
[changelog](https://github.com/komira-ai/komira/blob/main/python/CHANGELOG.md).

## What works

```python
import pyarrow as pa
import pyarrow.parquet as pq

import komira

print(komira.__version__)     # the installed version
print(komira.abi_version())   # the engine's C ABI version: 1011 is 1.11

# A small Parquet file to query: six days of weather in three cities.
weather = pa.table({
    "city": ["Oslo", "Lima", "Oslo", "Pune", "Lima", "Oslo"],
    "temp": [3, 18, 1, 31, 20, 5],
    "rain": [1.5, 0.0, 2.5, 4.0, 0.5, 1.0],
})
pq.write_table(weather, "weather.parquet")

with komira.Session() as s:
    s.register_parquet("weather", "weather.parquet")

    # An answer is a pyarrow Table; to_pylist() gives its rows.
    total = s.sql("SELECT count(*) AS days, sum(rain) AS rain FROM weather")
    print(total.to_arrow().to_pylist())

    # A group-by with an aggregate and an order.
    table = s.sql(
        "SELECT city, count(*) AS days, avg(temp) AS mean, max(temp) AS hottest"
        " FROM weather GROUP BY city ORDER BY city"
    ).to_arrow()
    print(table.schema)
    for row in table.to_pylist():
        print(row)

    # Batch by batch with to_reader(), or by any Arrow library.
    hot = "SELECT city, temp FROM weather WHERE temp > 10 ORDER BY temp DESC"
    print(s.sql(hot).to_reader().read_all().to_pylist())
    print(pa.table(s.sql(hot)).column("city").to_pylist())

    # A mistake raises komira.KomiraError, naming the file or the place.
    try:
        s.register_parquet("missing", "no_such_file.parquet")
    except komira.KomiraError as e:
        print(e)
    try:
        s.sql("SELECT city, count(*) FROM weather GROUP city")
    except komira.KomiraError as e:
        print(e)
print(s.closed)               # True: the session is freed
```

It prints:

```text
0.1.1623
1011
[{'days': 6, 'rain': 9.5}]
city: string
days: int64 not null
mean: double
hottest: int64
{'city': 'Lima', 'days': 2, 'mean': 19.0, 'hottest': 20}
{'city': 'Oslo', 'days': 3, 'mean': 3.0, 'hottest': 5}
{'city': 'Pune', 'days': 1, 'mean': 31.0, 'hottest': 31}
[{'city': 'Pune', 'temp': 31}, {'city': 'Lima', 'temp': 20}, {'city': 'Lima', 'temp': 18}]
['Pune', 'Lima', 'Lima']
parquet footer '<cwd>/no_such_file.parquet': no such file, or it cannot be read
parse: SQL syntax error: expected keyword 'by' at line 1, column 42
True
```

The first line is the installed version, and `<cwd>` stands for the
directory the program ran in: a relative path is resolved against it, and
the error names the file it looked for. The syntax error's message ends with
` at line 1, column 42` in releases newer than 0.1.1623; 0.1.1623 and older
print it without that part.

The program is the file `python/examples/quickstart.py` of the source tree,
and the text it prints is `python/examples/quickstart.expected` (shown here
with the version of the newest release in the changelog). The pull request
check runs it on the wheel installed into an empty environment, the release
checks run it after `pip install` of the wheel file and of the published
package, and each compares what it prints with that file, every line.

- `komira.__version__` is the installed distribution's version.
- `komira.abi_version()` loads the engine and returns its C ABI version as
  `major * 1000 + minor`.
- `komira.Session(*, threads=None, memory_limit=None)` is one engine context.
  `threads` is the engine's worker count and `memory_limit` the bytes the
  operators of one query may hold in total, each a positive `int`; `None`
  takes the engine's own value. A query that needs more memory than
  `memory_limit` raises `komira.MemoryLimitError` from `sql` (code
  `MEMORY_BUDGET_EXCEEDED`, step `"execute"`); the session answers the next
  query. `register_parquet(name, path)`
  reads the Parquet file's footer and registers the file as the table `name`.
  - `path` may be a `str` or a `pathlib.Path`.
  - A relative path is resolved against the working directory, and `~` is
    expanded.
  - A missing or unreadable file raises `komira.BindError` with the engine's
    message (a plain `KomiraError` from a library older than ABI 1.7), which
    names the file by its absolute path:
    `parquet footer '<path>': no such file, or it cannot be read`.
  - Registering a name again replaces the table.
- `register_csv(name, path, *, delimiter=",", header=True, all_varchar=False)`
  registers a CSV file as the table `name`, the table SQL's `read_csv` makes
  of the same file, and `register_json(name, path)` a newline-delimited JSON
  file (one object per line), the table `read_json` makes.
  - The engine infers the column names and types when the call is made, and
    every later query reads the file with them. An empty CSV field and a JSON
    `null` or missing key read as NULL.
  - `delimiter` is the one ASCII character between fields, and
    `all_varchar=True` makes every column a string. A table registered with
    `header=False` raises `KomiraError` when a query reads it: the engine
    does not name the columns of a file with no header yet.
  - Paths are taken as `register_parquet` takes them.
  - A missing, empty or unreadable file raises `komira.KomiraError` with the
    engine's message, which names the file. So does a name the session
    already has a table under, in any case, and nothing is registered.
- `register(name, obj)` registers rows in memory as the table `name`, as
  DuckDB's `register(name, obj)` does (newer than 0.1.1623; needs libkomira
  ABI 1.9). `obj` is a komira `DataFrame` or `komira.pl.LazyFrame`, whose plan
  runs now, or any object with the Arrow C stream interface
  (`__arrow_c_stream__`): a `pyarrow.Table`, `RecordBatch` or
  `RecordBatchReader`, a `komira.Result`, or a pandas or polars DataFrame.

  ```python
  import pyarrow as pa

  with komira.Session() as s:
      s.register("goals", pa.table({"region": ["east", "north"], "target": [100, 150]}))
      s.sql("SELECT region FROM goals WHERE target > 100").to_arrow()
  ```

  - The rows are copied now, and every query reads the copy: a change to
    `obj` afterwards is not seen until it is registered again. A
    `RecordBatchReader` is read now, once; giving it to `register` again,
    whether or not the first registration succeeded, raises `KomiraError`.
  - Registering a name again replaces its table, of any kind and in any case.
  - A column of a nested type (list, struct, map) or a union raises
    `komira.UnsupportedOperation` (code `TABLE_TYPE_UNSUPPORTED`) naming the
    column, and a type the engine does not import (the null type, a large
    list, run-end encoding) a `komira.BindError` naming its Arrow format;
    nothing is registered then, and the name keeps the table it had. Large
    and view strings (pandas' and polars' strings) register as `string`,
    and large and view binaries as `binary`, with the same values.
  - DuckDB also finds a frame by its Python variable name, with no
    `register`; komira does not yet.
- `Session.add_sql_binding(name, source)` binds the SQL name `name` to a
  source, which `sql` then reads as a table (newer than 0.1.1623). A source
  is `komira.files(location, *, credential=komira.AMBIENT, endpoint=None,
  region=None, url_style=None)`: Parquet files at a local path or glob, or
  Parquet objects of an object store, one key or a glob of keys.
  - `s3://bucket/key` (`s3a://` too) is read with
    `komira.AwsKeys(name, *, key_id, secret, session_token=None)` and a
    `region`; `az://container/blob` (`abfs://`, `abfss://`) with
    `komira.AzureKey(name, *, account, key)` or
    `komira.AzureSas(name, *, account, sas)`. `endpoint` reaches a store
    that is not the provider's (`http://` for an emulator, in plaintext), and
    `url_style` is `"vhost"` or `"path"`, as DuckDB's S3 settings are named.
  - A credential has a name of your choice. Binding seals the credential's
    value on the session under that name, then binds the source, which the
    library is given with the name only; every table bound under that name
    reads with the value sealed last. The footers are read, and a glob
    listed, when the source is bound.
  - A secret never reaches a log record or an error message, `repr` shows
    it as `<set>`, and a credential or a source refuses `pickle` and `copy`.
  - Binding a name again replaces its table, of any kind. A refused binding
    binds nothing and leaves the name's table as it was, with the engine's
    named refusal: `CredentialsError` for `AMBIENT` on an object store
    (`CREDENTIALS_NOT_FOUND`: the engine does not read the process's own
    identity yet) or a credential the engine refuses, `UnsupportedOperation`
    for a location no store reads (`STORAGE_URL_REFUSED`: `gs://` among
    them), `StorageError` for an S3 source with no region, `BindError` for
    the rest (`ANONYMOUS` or `AwsProfile` on `s3://`, a location ending in
    `/`, a bucket another table reads with other settings).
  - A credential of another store than the location's, and a setting or a
    credential other than `AMBIENT` on a local path, raise `ValueError` when
    the source is built.
  - The page [How do I read Parquet or CSV files from S3?](https://github.com/komira-ai/komira/blob/main/python/docs/tasks/31-read-parquet-csv-files-s3/page.md)
    shows a complete program, which the pull request check runs.
- `Session.sql(query)` runs one SQL statement over the session's tables and
  returns a `komira.Result`. The engine turns the text into a plan before
  `sql` returns, so a syntax error, an unknown table or column, or a construct
  the engine does not run yet raises a `KomiraError` from `sql`, with the
  engine's `<step>: <reason>` message: `ParseError` for a syntax error,
  `BindError` for an unknown name, `UnsupportedOperation` for a construct the
  engine refuses by name. A refusal of the `parse` step ends with where the
  statement stopped parsing, `at line <L>, column <C>` (both from 1, the
  column counted in characters; the end of the text when the statement ends
  early; newer than 0.1.1623).
- Ctrl-C while `Session.sql` runs cancels the query: the engine stops at its
  next check, `sql` raises `KeyboardInterrupt`, nothing the query computed is
  kept, and the session runs the next query. A second Ctrl-C while the query
  stops is not raised again. The query runs on a helper thread while the
  thread that called `sql` waits for it, which is what lets Python run the
  Ctrl-C handler during the query.
- `Session.sql(query, progress=callback)` calls `callback(done, total)` on the
  calling thread with the plan segments the query has finished and the
  segments its plan has, each time that changes, and once more with `done`
  equal to `total` when the query has answered. The readings only grow. A
  query refused before its plan is checked never calls it. An exception the
  callback raises cancels the query and is raised from `sql`, and calling the
  session from the callback raises `KomiraError`. For example, a line that
  rewrites itself:

  ```python
  def show(done, total):
      print("\r{}/{} segments".format(done, total), end="", flush=True)

  table = s.sql("SELECT count(*) AS n FROM readings", progress=show).to_arrow()
  ```
- komira logs to the standard `logging` logger `"komira"`: at `DEBUG` the
  library it loaded and the plan segments of each query that answered, at
  `INFO` a query stopped by an exception, such as the `KeyboardInterrupt` of a
  Ctrl-C. It never logs query text. Nothing is printed unless the application
  configures logging, for example with `logging.basicConfig(level=logging.DEBUG)`.
- A `Result` is read once, by one of:
  - `to_arrow()`, the whole answer as a `pyarrow.Table`;
  - `to_reader()`, a `pyarrow.RecordBatchReader` that reads batches as they
    are asked for;
  - `to_pandas()`, the whole answer as a `pandas.DataFrame`, converted by
    pyarrow's `Table.to_pandas()` with its default dtypes (an integer column
    with nulls becomes `float64`, a decimal holds `decimal.Decimal`, a
    timestamp keeps its unit);
  - `to_polars()`, the whole answer as a `polars.DataFrame`, converted by
    `polars.from_arrow`;
  - `__arrow_c_stream__()`, the Arrow PyCapsule interface, so
    `pyarrow.table(result)` and other Arrow libraries read it with no copy. A
    requested schema raises `KomiraError`.

  pandas and polars are not installed with komira. When one is missing,
  `to_pandas()` or `to_polars()` raises `ImportError` saying what to install
  (`pip install pandas`, `pip install polars`), and the result stays unread.

  Reading it a second time raises `KomiraError`: run the query again. A
  result still reads after its session is closed, and one never read frees
  its answer when it is garbage collected.
- A session is a context manager. `close()` frees it and can be called again,
  and `closed` says whether it was. Any other call on a closed session raises
  `KomiraError`.
- A session may be used from several threads. Its calls run one at a time: a
  call made while another thread's call runs on the same session waits for it
  to return. `close()` waits too, so a session is never freed under a running
  call. Two sessions run their calls at once, so a session per thread is how
  to run queries in parallel. A call made from a signal handler, a finalizer
  or a `progress` callback
  while a call of the same thread is running on that session raises
  `KomiraError` instead of waiting for itself. A `Result` reads without the
  session, so reading one never waits for a call on its session; of two
  threads that read one `Result`, one reads it and the other gets the
  already-read `KomiraError`.
- `komira.KomiraError` is the base class of every error komira raises on
  purpose. Its `status` attribute is the engine's status code, or `None`; its
  `code` is the refusal's named code (`SQL_SYNTAX_ERROR`,
  `LOWERING_WINDOW_UNSERVED`, ...) and its `step` the step that refused
  (`"parse"`, `"bind"`, `"optimize"`, `"lower"` or `"execute"`), each `None`
  when the library gave none (an empty code is `None`, never `""`).
- Its subclasses, chosen from the code and then the step of an engine refusal
  (status -3; any other status is a plain `KomiraError`): `ParseError`
  (`SQL_SYNTAX_ERROR`, or any refusal of the parse step), `BindError`
  (`SQL_BIND_ERROR` and the `BIND_*` codes, or any refusal of the bind step),
  `MemoryLimitError` (`MEMORY_BUDGET_EXCEEDED`: the query needed more memory
  than the session's `memory_limit`), `UnsupportedOperation` (`SQL_NOT_SUPPORTED`, `STATEMENT_NOT_A_QUERY`,
  `LOWERING_*_UNSERVED`, `LOWERING_UNCUTTABLE_NODE`, `STORAGE_URL_REFUSED`, `TABLE_TYPE_UNSUPPORTED`, ...), `CredentialsError`
  (`CREDENTIAL_*` and `CREDENTIALS_*`) and `StorageError` (the other
  `STORAGE_*` codes). The table is `_errors._CODE_CLASSES`; the package never
  parses a message to choose a class.
- `komira.LibraryLoadError` is raised when the engine cannot be loaded. Its
  message names the library and the reason. For example, a library built for
  a different ABI major version is refused.
  A Mojo runtime library missing from the package's `lib/` is reported as an
  incomplete package: the message names each missing file, says to reinstall
  komira, and ends with the loader's own text. Another file that is missing is
  reported with the loader's message naming the file.
- A process holds one Mojo runtime. `komira.LibraryLoadError` is also raised
  when a Mojo runtime library of another build is already loaded in the
  process, for example by Mojo code built with another Mojo version. Its
  message names the library and the directory it was loaded from.
- `komira.UnsupportedCpuError`, a `LibraryLoadError`, is raised on Linux
  x86_64 only (the CPU guard does nothing on macOS) when the CPU lacks a flag of x86-64-v3, before the engine is loaded.
  Its message lists the missing flags as `/proc/cpuinfo` spells them.

The engine is loaded on the first `Session()` or `abi_version()` call, and
pyarrow during the first `Session.sql` call the engine accepts, when the
answer's schema is read; neither on `import komira`.

### The DataFrames

A DataFrame is a lazy plan: no verb runs a query, `materialize()` (pandas-shaped,
`komira.read_parquet`) and `collect()` (polars-shaped, `komira.pl`) encode the
plan and run it through the engine's plan entry, which takes no SQL, and the
answer is a `Result`. Each thing a DataFrame can do has a page, with its
examples, in
[python/docs](https://github.com/komira-ai/komira/tree/main/python/docs/): start
with the overview in `dataframe/` for the pandas-shaped one and with `pl/` for
`komira.pl`. The install test runs the overview's first program on the
installed wheel.

protobuf and the generated plan modules are imported by the first reader, not
by `import komira`.

## What does not work yet

- The module-level `komira.sql` and `komira.register_parquet` on a default
  session.
- Surviving a crash inside the engine. An error the engine reports raises
  `KomiraError`, but an abort, a fault, running out of stack, or running out
  of memory that the session's `memory_limit` does not catch (a query over it
  raises `MemoryLimitError`) ends the Python process. Inputs known to cause
  one are refused with `KomiraError` first (newer than 0.1.1623), for example
  a statement nested more than 100 levels deep.
- The DataFrame verbs not built yet, for both skins: what each capability
  has and lacks is recorded in
  [docs/design/dataframe_surface_verbs.md](https://github.com/komira-ai/komira/blob/main/docs/design/dataframe_surface_verbs.md).
- Iceberg tables: reading one, and writing to one by its name in a catalog.
- Of object stores: `gs://` and `https://` locations, CSV or JSON objects,
  a URL written in the SQL text (`FROM 's3://...'`), the DataFrame readers
  on a URL, `COPY ... TO` a URL, the process's own identity (`AMBIENT`), and
  `ANONYMOUS` or `AwsProfile` on `s3://` (komira-ai/komira#2337).
- Python user functions: no verb takes one. The engine runs a plan that carries one (private `komira/_capture/` and `komira/_udf_runtime.py`), but no public call builds it.

The DataFrame verbs not built yet come in later releases of this same package.

## Working on the package

Most readers can skip this section. It describes the source tree of the
commit it is read at, files and tests a release does not ship among them.

The package's layout and API are designed in
[docs/design/python_package.md](https://github.com/komira-ai/komira/blob/main/docs/design/python_package.md).

| path | what it is |
|---|---|
| `komira/__init__.py` | the public names, exactly `__all__`, and the module's `__getattr__`, which refuses the pandas names of `_refusals.MODULE` with their message |
| `komira/_frame.py` | the pandas-shaped `DataFrame` and its readers: a plan of `komira/_ops` nodes, the sources its scans read and the session it runs on; the verbs build nodes with `_ops`'s builder, derive the output schema with the encoder, and `materialize()` sends the encoded plan to the session's plan door, and `to_parquet`, `to_csv` and `to_json` send a plan with a write target there. It writes no SQL text, and imports `_plan`, so protobuf, only when the first frame is made. The verbs are described, one page each, in `python/docs/dataframe/` |
| `komira/_display.py` | the HTML of the notebook display (`_repr_html_`): a frame's column names over their types, and the first ten rows a result read (`python/docs/dataframe/display.md`). It reads no stream and calls no library |
| `komira/_series.py` | `Series`: an expression node over its frame's columns and the field the engine derives for it, bound to the frame and its generation |
| `komira/_groupby.py` | `GroupBy` and the frame's reductions: each builds one `Aggregate` node, and `drop_duplicates` a `Distinct` or an `Aggregate` (over a `subset` of fewer columns, the window of `komira/_windows.py`); it writes no SQL text |
| `komira/_verbs.py` | the bodies of `fillna`'s fill literals, the label-axis check of `rename`, `add_prefix` and `add_suffix`, and `concat` (the session, column-set, type and nullability checks, the projection that reorders a later frame's columns, and the `Union` node) |
| `komira/_missing.py` | pandas' "missing" as plan nodes: `IS NOT NULL`, and for a float column also not NaN, built from comparisons with infinity since the plan has no NaN test |
| `komira/_cast.py` | the dtype names `astype` takes (the design's table, pandas' spellings, Python's types and pyarrow types) and the `Cast` node of each |
| `komira/_accessors.py` | `s.str` and `s.dt`: each method one expression node (`StringFn`, `StringOp`, `StringFnN`, `Substring`, `Regexp`, `Extract`) over the Series' node |
| `komira/_write.py` | the write terminals' shared path: the destination (`None` refused, a URL passed on for the engine to refuse by name, any other path made absolute at the call with `~` expanded), each verb's `compression` to the engine's codec (`'infer'` from the extension), `unsupported`, the refusal of an argument at a value komira does not write, and `write`, which encodes the frame's plan under a `WriteTarget` and runs it through the session's `_plan_write` |
| `komira/_refusals.py` | the refusal tables of the frame, the GroupBy, the Series, the `.str` and `.dt` accessors and the module ([docs/design/dataframe_surface_verbs.md](https://github.com/komira-ai/komira/blob/main/docs/design/dataframe_surface_verbs.md)) |
| `komira/_capture/` | the capture of Python user functions (private; no public verb takes one, though the engine runs a plan that carries one): `udf`, the decorator that records a function's call shape (`scalar`, `map_batches_column`, `row`, `map_batches_frame`), its return type (`return_dtype=`, `schema=` or the type hints) and, for `row` and `map_batches_frame`, its read set (`columns=`, a `TypedDict` or dataclass annotation, or for `row` a scan of the function's bytecode, refused with `UDF_READ_SET_REQUIRED` when the reads are not bounded); `Udf.spec()`, the `UdfSpec` the plan encodes, with the function's code as a bundle named by its sha256 or as a reference into an installed distribution; and `write_code`, which writes each code object under its digest. Calling a decorated function calls the function, which is how the komira/python worker runs it. It imports no `ctypes` |
| `komira/_credentials.py` | the credential objects, which `komira.files` takes (public: those a file source takes; `BearerToken` and `OAuth2ClientCredentials`, for a catalog, stay private): `AwsKeys`, `AwsProfile`, `GcpServiceAccount`, `GcpToken`, `AzureKey`, `AzureSas`, `BearerToken` and `OAuth2ClientCredentials`, each a name and its fields, checked when built (the name's grammar and reserved names; each value a non-empty `str` of at most 4096 bytes of UTF-8), with every secret shown as `<set>` by `repr` and no pickle or copy; and the built-in `AMBIENT` and `ANONYMOUS` ([docs/design/credentials_and_writes.md](https://github.com/komira-ai/komira/blob/main/docs/design/credentials_and_writes.md), decision 1) |
| `komira/_iceberg.py` | the Iceberg sources (private; nothing public takes one yet): `iceberg(uri, *, warehouse=None, credential=AMBIENT, signing=None, access_delegation="vended-credentials")`, an `IcebergCatalog`; `catalog.table(name)`, an `IcebergTable`, with `name` as `"namespace.table"` or a tuple of namespace levels and the table; and `SigV4(region, service)`. Each is checked when built (an http or https URI with a host and no user, password, query or fragment; a credential that fits the catalog: `AMBIENT` or `AwsKeys` with SigV4, and `AMBIENT`, `ANONYMOUS`, `BearerToken` or `OAuth2ClientCredentials` without; `access_delegation` `vended-credentials` or `none`), does no I/O and loads no library; a catalog or a table shows its credential's secrets as `<set>` and refuses pickle and copy ([docs/design/iceberg_tables.md](https://github.com/komira-ai/komira/blob/main/docs/design/iceberg_tables.md), "What the user sees") |
| `komira/_arrow.py` | the Arrow C stream of a query: `ArrowArrayStream`, the C struct for `ctypes`, and `import_stream`, which hands a filled stream to pyarrow's public `RecordBatchReader.from_stream` through a PyCapsule with no destructor, and releases it itself if pyarrow did not take it |
| `komira/_errors.py` | `KomiraError`, its subclasses, and `error_class`, which picks one from an engine refusal's code and step |
| `komira/_native.py` | the `ctypes` loader: `load(lib_dir=None)` and the `Native` it returns, with the calls up to ABI 1.11 (`sql_stream`, `register_csv`, `register_json`, `register_arrow_stream` of 1.9, the run handle calls `run_new`, `run_cancel`, `run_progress` and `sql_stream_run` of 1.6, the last error's code and step, `plan_stream`, the plan door of 1.8, `add_sql_binding` of 1.10 and `udf_runtime_set` of 1.11 among them) |
| `komira/_run.py` | `run_sql`, which `Session.sql` runs a query with on ABI 1.6: the call `komira_sql_stream_run` on a helper thread under a run handle of its own, while the calling thread waits, reads the handle's progress for the `progress` callback, and cancels the handle when anything is raised on it (a Ctrl-C's `KeyboardInterrupt`, the callback's exception) |
| `komira/_plan/` | the plan encoder: `encode_plan`, a plan of `komira/_ops` as the `komira.plan.v1` `WirePlanEnvelope` the plan door takes, every node with the output schema the engine derives for it and every scan reading a source libkomira described (`parquet_source`, `binding_source`); calls of user functions (`UdfCall`, `MapBatches`) as `WireUdfApply` and `WireMapBatchesNode` over the envelope's `UdfRef` list, one per distinct function, each with the komira/python descriptor; `encode_expr`, an expression node as a `WireExpr`; and `expr_field`, the output field the engine derives for it. It writes no SQL text. It imports the generated plan modules, which the wheel ships at `komira/plan/v1/`; `import komira` does not import it |
| `komira/pl/` | `komira.pl`, the polars-shaped DataFrame surface ([docs/design/dataframe_surface.md](https://github.com/komira-ai/komira/blob/main/docs/design/dataframe_surface.md)): lazy frames and expressions over a plan of `komira/_ops`; `collect()` encodes it with `komira/_plan` and runs it through `komira_plan_stream`, and `sink_csv`, `sink_parquet` and `sink_ndjson` run it there with a write target through `komira/_write.py`, their polars arguments checked in `komira/pl/_sink.py`. It writes no SQL text and imports no polars. A name it does not define raises `AttributeError`, with the refusal tables' message for theirs. Its verbs are described, one page each, in `python/docs/pl/` |
| `komira/_runtime.py` | `check_loaded_runtime`, called before libkomira is opened: it compares the Mojo runtime libraries already loaded in the process with komira's copies by build id, and the GNU build id reader it uses |
| `komira/_sources.py` | `files(location, *, credential=AMBIENT, endpoint=None, region=None, url_style=None)`, a file source: checked when built (types; a credential that fits the location's store; no setting on a local path, which is made absolute), its credential's secrets shown as `<set>`, no pickle or copy, and `_wire()`, its `WireBoundSource` bytes (src/plan_proto/bound_source.proto), which carry the credential's name and never a value |
| `komira/_session.py` | `Session` with `register_parquet`, `register_csv`, `register_json`, `register` (a frame's rows, or an object's Arrow C stream, drained by `komira_register_arrow_stream`), `add_sql_binding` (which seals the source's credential, then calls `komira_add_sql_binding`, under one hold of the lock) and `sql`, `Result` (whose notebook display reads its stream at most one batch past the tenth row and puts back a reader that replays those batches before the rest, so the result stays unread), and the session's private `_seal_credential`, which defines a credential on the session through `komira_credential_add`, `_set` and `_seal`; the private calls a frame makes (`_parquet_schema`, `_csv_binding`, `_json_binding`, `_plan_stream`, `_plan_write`, `_plan_render`), each under the session's lock; and `default_session()`, the process's default session |
| `komira/py.typed` | the PEP 561 marker |
| `BUCK` | `:komira`, the package's files as the directory its tests import from; `:komira_with_plan_modules`, the same with the generated plan modules at `komira/plan/v1/`, for the tests that encode or run a plan; `:komira_wheel`, the wheel; `:komira_wheel_macos_arm64`, the macOS wheel; `:wheel_install_test` and `:wheel_install_test_macos_arm64`, each installed into an empty environment; and the `refuses_*` and `beside_*` targets |
| `install_test.bzl` | the rules of the wheel's files and of the install test, and `python_versions`, the supported Pythons as JSON for the workflows |
| `task_examples.bzl` | `task_pages_check`, the check of the common-task pages against the catalogue (`docs/tasks/catalogue.json`) |
| `docs/tasks/` | the Python examples of the common data-analysis tasks, one directory `<rank>-<slug>/` per task with `example.py`, `expected_output.txt` and `page.md`, and `BUCK`, which runs each example against the installed wheel ([docs/tasks/README.md](https://github.com/komira-ai/komira/blob/main/docs/tasks/README.md)) |
| `pythons.bzl` | the supported Pythons, the one list of them (Supported Pythons, below) |
| `CHANGELOG.md` | what the releases it keeps added or changed, newest first, and how a change gets an entry (Changelog entries, below) |
| `changelog.d/` | the entries no kept release holds yet, one file `<slug>.md` for each change |
| `changelog/` | the Zig tool that assembles the changelog and the wheel's description from them, its cases, and the rule that runs it (`changelog_file`, `defs.bzl`) |
| `tests/` | the tests (`python_binding_test` for those that load a library, `py_test` for those that do not), each file's docstring saying what it covers, `BUCK`, which declares them, and `families.bzl`, which holds the checks of the suite (below); `plan/`, `run/`, `duckdb/`, `pl/` and `pl_oracle/`, the family directories, each holding the tests of one shape as files; `fake_libkomira.c`, `fake_threads.c` and `fake_runtime_lib.c`, the stand-in libraries they load; `test_installed.py` and `wheel_install_run.py`, the install test and its driver; `test_tpch_installed.py` and `tpch_compare.py`, TPC-H q1 to q22 at scale factor 1 through the installed wheel against DuckDB's recorded answers (`:tpch_via_wheel_test`; its answer check is held by `test_tpch_compare.py`); `test_analysis_job.py`, which runs `examples/analysis_job.py` from the installed wheel and compares its answers with DuckDB's (`:analysis_job_test`); `test_objectstore_installed.py`, which binds Parquet objects on the loopback stand-ins of S3 and Azure Blob (`objectstore_fakes.py`) from the installed wheel and compares each answer with the same files read locally (`:objectstore_installed_test`); and `test_beside_modular.py`, the tests of komira loaded beside Modular's runtime |

### Changelog entries

A change that alters what the package does or what it needs adds one file,
`changelog.d/<slug>.md`, and no line of `CHANGELOG.md`: two changes then never
edit the same line, whatever else is queued. The slug is lower-case letters,
digits and hyphens (`memory-limit`). The file holds one or more Markdown
bullets and nothing else: `- **Title.** text`, a continuation line indented two
spaces, no heading. Write the text as the changelog's other entries are
written, from what the code does: the names it adds (each in a code span), the
errors it raises, the ABI version it needs. Name the file after its bold title.

The release assembles the entries (`//python:changelog`, the tool of
`changelog/`): the stamped build, `-c komira.package_stamp=<N>`, gives the
section `## 0.1.<N>` listing the bullets of every file of `changelog.d/` in
file-name order, placed above the newest section `CHANGELOG.md` keeps; an
unstamped build calls it `## Unreleased`. The section a release ships therefore
lists every change merged since the newest section kept in `CHANGELOG.md`. The
wheel's description is this README followed by that changelog with its headings
one level down (`//python:changelog[description]`), so the page of version
0.1.`<N>` on PyPI shows its own section. A stamped build also gives the
description its commit, `-c komira.package_commit=<sha>`, and every link of it
to the repository's `main` (`.../blob/main/...`, `.../tree/main/...`) opens
that commit instead, so the pages a release's PyPI page links to describe that
release; the wheel's `Documentation` URL is the install page of that commit.
The tool refuses a stamp with no commit, a commit with no stamp, and a commit
that is not 40 lower-case hexadecimal digits.

`CHANGELOG.md` keeps a section for each version on PyPI. Once a version
0.1.`<N>` is on PyPI, one change keeps its section: it moves the entries
that `changelog.d/` held at the commit that version was built from (the
`<N>`th commit of `main`'s first-parent history, `git rev-list --first-parent
--reverse main | sed -n <N>p`) under a heading `## 0.1.<N>`, above the
sections already kept, and deletes their files. A version that added nothing
gets the line the tool writes for no entry. A page or a sentence of the docs
that describes a change no kept section holds says so: "newer than
0.1.`<K>`", `K` the newest section kept, and the change that keeps the
section holding it drops those words.

Building the changelog is the check of the entries: it refuses, naming the
file and the line, a file whose name is not a slug and `.md`, an empty file, a
line that is neither a bullet nor an indented continuation, a heading, a
`## Unreleased` heading in `CHANGELOG.md` and a `CHANGELOG.md` with no
release heading; it is a dependency of the wheel, so a pull request that
builds the wheel builds it. `//python/tests:changelog_names_test` holds every
public name of `komira` and `komira.pl` (each module's `__all__`, and each
public class's own public attributes) to an entry: the name is an identifier
inside a code span of `CHANGELOG.md` or of a file of `changelog.d/`, and the
failure lists the names without one. It holds the names, not the change: a
name whose last part is a common word already in a span passes, and a change
of behaviour that adds no name needs a fragment by review.

### Supported Pythons

`pythons.bzl` lists the CPython minors the package supports, oldest first:
3.11, 3.12, 3.13 and 3.14. Each entry names the interpreter pinned for the
farm's tests (`third_party/python`) and the exact version a GitHub-hosted
runner installs with `actions/setup-python` on Linux x86_64 (the pinned
version) and on macOS arm64. Everything else is read from it:

- the wheel's `Requires-Python` (`>=` the oldest minor) and its
  `Programming Language :: Python` classifiers;
- the package's tests (`tests/BUCK`) and the wheel's install and upgrade tests
  (`BUCK`), one target per minor: `<name>` on CPython 3.13, `<name>_py311`,
  `<name>_py312` and `<name>_py314` on the others;
- `//python:supported_pythons[linux-x86_64]` and `[macos-arm64]`, the exact
  versions as JSON lists, from which `pypi_smoke matrix` writes the job matrix
  of the wheel's user test and of the index smoke (in pypi.yml, and in
  the macOS jobs of the same file for the macOS wheel): one job per version. `//python/smoke:supported_pythons_lists` holds both
  lists to the versions it writes out.

Adding a minor is a line in `pythons.bzl` and its interpreter's pin in
`third_party/python/pins.bzl`. The one wheel, tagged `py3-none`, serves every
minor. On macOS, `actions/setup-python` has no build of the newer patch
releases of 3.11 and 3.12 (they are released as source alone), so the macOS
jobs install 3.11.9 and 3.12.10. The farm's macOS tests run CPython 3.13
alone: the interpreters of the other minors are linux x86_64 builds, so the
tests and wheels that name one (`_py311`, `_py312`, `_py314`) are configured for
linux x86_64 only (limit `python-linux-interpreters`, set by the macros of
`tools/build/python`) and a macOS build skips them.

How the loader behaves:

- **Where it looks.** `_native.load` opens `<lib_dir>/libkomira.so`
  (`libkomira.dylib` on macOS), or, when the directory holds a `VARIANTS`
  manifest, the CPU-level variant `_native._select_variant` picks (below).
  With no directory, it opens the package's own `_lib/` copy. No environment
  variable and no search of the working directory picks the library. It opens
  the file with `RTLD_LOCAL`. libkomira's run path (`$ORIGIN/lib:$ORIGIN` on Linux,
  `@loader_path/lib` on macOS) finds the native owner libraries (Linux only:
  on macOS they are linked into the dylib) in `_lib/lib/`, and the three Mojo
  runtime libraries there too. A file of the package that
  is missing is a `LibraryLoadError` with the loader's message, which names
  the file; when a Mojo runtime library is missing from `_lib/lib/`, the
  message first says the package is incomplete and names each missing one.
- **What runs before the library opens.** `load` first checks the CPU, with
  `_native._select_variant(<lib_dir>)` when the directory holds a `VARIANTS`
  manifest and `_native._check_cpu()` when it does not, then calls
  `_runtime.check_loaded_runtime(<lib_dir>/lib)`. An error raised by either
  stops the load.
  - From a directory with a manifest (docs/design/isa_variants.md, decision
    5), the loader opens the last line, the highest level, whose features the
    `flags` (x86_64) or `Features` (aarch64) lines of `/proc/cpuinfo` list on
    every processor. A CPU without the features of the first line, the floor,
    raises `UnsupportedCpuError` naming them. A manifest it cannot read or
    parse, an unreadable cpuinfo, or a missing chosen file raises
    `LibraryLoadError`; a lower level is never loaded in place of a missing
    one. The wheel carries no manifest yet.
  - On Linux x86_64, `_check_cpu` reads the `flags` lines of `/proc/cpuinfo`
    and requires every flag of x86-64-v3, the level the library is compiled
    for there, on every processor: `pni` (SSE3), `ssse3`, `cx16`, `sse4_1`,
    `sse4_2`, `popcnt`, `lahf_lm`, `avx`, `avx2`, `bmi1`, `bmi2`, `f16c`,
    `fma`, `abm` (LZCNT) and `movbe`. A missing one raises
    `UnsupportedCpuError` naming it, instead of an illegal instruction inside
    the library; a file it cannot read raises `LibraryLoadError`. On other
    platforms, macOS among them, it reads nothing.
- **The runtime check.** libkomira's NEEDED names for the Mojo runtime
  (`libMSupportGlobals`, `libAsyncRTRuntimeGlobals`, `libKGENCompilerRTShared`;
  `.so` on Linux) resolve to a library already loaded under the same name
  before any path is searched. So when other Mojo code is in the process,
  libkomira would bind to that code's runtime without a message. The check
  looks at each of the three names with `dlopen(name, RTLD_NOLOAD)` and reads
  the directory it came from with `dlinfo`.
  - Not loaded, or loaded from komira's own file: nothing to do.
  - Loaded from another file with the same GNU build id as komira's copy (the
    same Mojo build, such as the `mojo-compiler` wheel of the toolchain's
    version): accepted, and
    libkomira uses that copy.
  - Another build id, or none: `LibraryLoadError` naming the library, the
    directory it was loaded from and komira's copy.
  - Komira's copy cannot be read while another is loaded: `LibraryLoadError`.
  - On other platforms, macOS among them, it does nothing.
  - The runtime libraries are not opened with `RTLD_GLOBAL`: that would put
    komira's copy in the global scope, ahead of the definitions of other Mojo
    libraries. A process holds one Mojo runtime version, so Mojo code built
    with another version (for example `max` with `mojo-compiler` 1.2.0) does
    not work beside komira: loaded first, komira refuses it; loaded after, a
    newer runtime fails to load, and an older one (not yet run: inferred from
    its symbols) loads on komira's libraries.
- **The version check.** `komira_abi_version()` is read before any other
  symbol is looked up.
  - A major version other than 1 is refused with `LibraryLoadError`.
  - Any minor version is accepted.
  - A call added in a minor up to the library's own is required, and its
    absence is refused by name.
  - A call added in a later minor may be missing. It raises `KomiraError` only
    when it is used.
- **Call errors.** A failed call raises `KomiraError` with its status. The
  message is the context's last error, read with the two-call protocol: the
  first call learns the length, and the second passes a buffer of exactly that
  length. From ABI 1.7 the error also carries `komira_last_error_code` and
  `komira_last_error_step`, and `_errors.error_class` picks the class of an
  engine refusal (-3) from them: by code first, then by step, then the call's
  own default (`CredentialsError` for the credential calls, which a library
  older than 1.7 answers only with `CREDENTIALS_INVALID`). The package never
  parses the message to choose the class.
- **Private calls.** `parquet_schema`, `csv_binding`, `json_binding`,
  `plan_render`, `plan_stream`, `credential_add`, `credential_set` and
  `credential_seal` exist only on `_native.Native`, and so does
  `Native.add_sql_binding`, which the public `Session.add_sql_binding` makes. They have no public API and no stability
  promise.

The tests run on Linux x86_64 as build actions, so building a test's target
runs it. `./buck2 build //python/tests:all` builds and runs every test of the
package, and each test is `//python/tests:<name>` (`load_test`, `sql_test`,
`frame_test`, ...) with `<name>_py311`, `<name>_py312` and `<name>_py314` for
the other Pythons (Supported Pythons, below). The farm's macOS workers run
them too, on CPython 3.13 only (the other pinned interpreters are Linux
builds), with Mach-O stand-in libraries (`libkomira.dylib`); `runtime_test`
and the tests of the Linux wheel are Linux only. What a test covers is in its
file's docstring, which also says what the test is given.

A test is declared in one of two ways (`tests/BUCK`):

- **A file of a family.** The tests of a common shape are files
  `test_<name>.py` in the directory of their family, with no entry in `BUCK`:
  the family's stanza declares `<name>_test`, one per Python where the family
  says so. The directory is part of the package `python/tests`, so a test
  there is found by a glob and adding one is adding the file.
  - `plan/`: the plan side with no library, under the generated plan
    modules and protobuf 7.36.2 on each Python, and 5.29.1 too on CPython 3.13
    (`<name>_test_protobuf_lower_edge`).
  - `run/`: on the real `libkomira` (and the ABI 1.7 stand-in), on each
    Python, with the plan modules, protobuf 7.36.2 and pyarrow.
  - `duckdb/`: on the real `libkomira` against DuckDB, CPython 3.13 only.
  - `pl/`: `komira.pl` with no library, on each Python, with the plan
    modules, protobuf 7.36.2 and pyarrow.
  - `pl_oracle/`: `komira.pl` against polars on the real `libkomira`,
    CPython 3.13 only.
- **A stanza.** A test whose inputs no family has (its own stand-in library,
  fixtures, arguments or protobuf runtime) is a stanza of `BUCK` with its file as
  `src`.

The target name is the file's name without `test_`, then `_test`: two files
that give one name fail the load of `BUCK`, naming both, and so does a
`test_*.py` that no stanza names, no family directory holds and no install test
uses, which names the file and says where to put it. `:all` depends on every
test `BUCK` declares, so the check set lists the package as that one
target and a new test changes no generated list.

The Linux wheel is `./buck2 build //python:komira_wheel`: the package and, in
`komira/_lib/`, `libkomira[dist]` whole: `libkomira.so`, and in `lib/` its
native owner libraries and the three Mojo runtime libraries, taken from the
toolchain's Mojo package so that runtime and compiler are one build; beside
`libkomira.so`, the komira/python UDF runtime `libkomira_udf_python.so`
(`//src/udf_python:komira_udf_python`), which the engine opens when a plan with UDFs
runs (`//python:udf_installed_test` runs a UDF through it from the installed wheel and
checks the engine's answer against a Python loop). It is
tagged `py3-none-manylinux_2_35_x86_64`, declares the `Requires-Dist` lines
`pyarrow>=25.0.1` and `protobuf>=5.29.1,<8` (`PYARROW_REQUIREMENT` and
`PROTOBUF_REQUIREMENT`, `dependencies.bzl`), carries the generated plan
modules at `komira/plan/v1/`, and
carries Modular's licence and third-party notices beside komira's own
(`Apache-2.0 AND LicenseRef-Modular-Proprietary`).

The macOS wheel is `//python:komira_wheel_macos_arm64`, built with
`--target-platforms komira//tools/build/platforms:darwin-arm64`. It has
the same package and metadata as `:komira_wheel` (including the licence
expression and the licence files, which are those of the pinned Linux package, the runtime libraries
being under the same Modular licence), and `libkomira[dist]` for macOS arm64,
which is `libkomira.dylib` and, in `lib/`, the three Mojo runtime libraries
(`libAsyncRTRuntimeGlobals.dylib`, `libKGENCompilerRTShared.dylib`,
`libMSupportGlobals.dylib`) and no native owner libraries. It is tagged
`py3-none-macosx_11_0_arm64`. It is
built and tested only in the macOS jobs of `.github/workflows/pypi.yml`,
never in a pull request, and a run publishes it only from main. After the upload, a GitHub-hosted macOS runner installs it from the
index and runs the smoke test.

`./buck2 build //python:wheel_install_test` (CPython 3.13; `:wheel_install_test_py311`,
`_py312` and `_py314` on the other supported Pythons) installs the wheel, the pinned pyarrow
25.0.1 wheel of that Python and the pinned protobuf 7.36.2 wheel into an empty virtual environment, the
way a wheel is installed for the other tests (no pip, no network), and runs
`tests/test_installed.py` there in isolated mode, from an empty directory, with
no library path set. `//python:wheel_install_test_macos_arm64` runs the test on
the macOS wheel on the farm's macOS workers (CPython 3.13, the one macOS
interpreter pinned), from the release workflow only. That test holds:

| what | how |
|---|---|
| the installed package | `komira` imports from the environment, at the wheel's version |
| its metadata | the `Requires-Dist` lines `pyarrow>=25.0.1` and `protobuf>=5.29.1,<8`, in that order, and no other; `Requires-Python` `>=3.11` and exactly the classifiers `python/BUCK` writes out (`_PYTHON_METADATA`: the four supported minors); the `License-Expression` given; `.dist-info/licenses/` holding `LICENSE`, `NOTICE`, `AWS_LC_LICENSE`, `S2N_TLS_LICENSE`, `MODULAR_LICENSE` and `MODULAR_THIRD_PARTY_NOTICES`, each byte-equal to its source, and no other; the description equal to `//python:changelog[description]` (this README followed by the assembled changelog) byte for byte, so PyPI shows the same quickstart |
| nothing else | no `modular/` directory and no distribution in the environment but komira, pyarrow and protobuf; `import komira` imports neither protobuf nor the plan modules |
| the library | `abi_version()` is the version of `src/so/abi/komira.tsv`; a Parquet file registers, a missing one raises `KomiraError`; `SELECT 1 AS n` and an aggregate over `tests/fixtures/readings.parquet` answer their rows through pyarrow; a DataFrame of `tests/fixtures/readings.parquet`, filtered, projected, given a computed column, sorted and cut with `head`, answers its two rows through the plan door; a serialized plan renders |
| the quickstart | `examples/quickstart.py`, run in an empty directory, prints exactly `examples/quickstart.expected` (its version, ABI version and directory filled in) and leaves only the `weather.parquet` it wrote |
| where it loaded from | `/proc/self/maps` (on macOS, the images dyld has loaded) lists libkomira and its owners (none on macOS, where `lib/` holds exactly the three runtime `.dylib` files) from `komira/_lib`, and the three Mojo runtime libraries from `komira/_lib/lib` |

Each `//python:refuses_*` target runs the same install and test on one broken
case and passes only if it fails with the line it names: no `libkomira.so` in
the wheel (`refuses_missing_libkomira`), owner libraries off libkomira's run
path (`refuses_owners_off_run_path`), a Mojo runtime library missing from the
wheel (`refuses_missing_runtime_library`), a wheel tagged for another platform
(`refuses_wheel_of_another_platform`), another distribution installed with the
wheel (`refuses_other_distribution`), an unmet requirement
(`refuses_unmet_requirement`), the wheel without pyarrow
(`refuses_missing_requirement`), the wheel beside pyarrow without protobuf
(`refuses_missing_protobuf`), a pyarrow wheel of another CPython minor
(`refuses_requirement_of_another_minor`), a wheel whose `Requires-Dist` is
another range (`refuses_requires_dist_not_the_declared_range`), a wheel whose classifiers leave out 3.11
(`refuses_classifiers_not_the_supported_pythons`) or whose `Requires-Python`
starts at 3.12 (`refuses_requires_python_not_the_oldest_supported`), and
CPython 3.10, which the wheel's
`Requires-Python` (`>=3.11`) leaves out
(`refuses_python_outside_requires_python`).

`//python:upgrade_test` (and `_py311`, `_py312` and `_py314`) installs two releases of
the wheel one after the other into one environment, the way pip does, and
holds the result to what the install test holds of a fresh install, plus that
every file only the older release had is gone. Its refusals are a downgrade
(`refuses_downgrade`), an upgrade from nothing (`refuses_upgrade_from_nothing`)
and a second release installed without the upgrade
(`refuses_second_release_without_uninstall`). `//python:wheel_libs` reads the
finished wheel and walks its libraries as the loader would.

The `//python:beside_*` targets load komira in a process that also holds
Modular's runtime from the `mojo-compiler` wheel, run by
`tests/test_beside_modular.py`:

| target | what it holds |
|---|---|
| `beside_modular_loaded_first` | the same Mojo version loaded first: libkomira binds to Modular's copy and works |
| `beside_modular_loaded_after` | komira loaded first, then Modular's `libKGENCompilerRTShared` of the same version: both work |
| `beside_other_mojo_loaded_first` | another Mojo version loaded first: the load is refused, naming the library |
| `beside_other_mojo_loaded_after` | komira loaded first, then another Mojo version: a newer one fails to load with the loader's `undefined symbol`, an older one loads as a second `libKGENCompilerRTShared` on komira's two other libraries (first run at a 1.1.0 or 1.2.0 toolchain; inferred from symbols until then), and komira keeps working |
| `refuses_modular_unlike_toolchain` | the `mojo-compiler` wheel handed to a same-version case is not the toolchain's version, and the test refuses it |
| `refuses_other_mojo_at_toolchain` | the `mojo-compiler` wheel handed to an other-version case is the toolchain's version, and the test refuses it |

The toolchain's Mojo picks the versions: the pair at its version and the
compiler wheel of the newest other version in
`third_party/modular/pins.bzl`.

`//tools/build/package/libkomira:libkomira_dist_load` loads a copy of the
`[dist]` directory from C, with no Python, no library path and nothing of
Modular's.
