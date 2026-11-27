# Installing komira for Python

komira's Python package is `komira` on PyPI. This page covers installing it, what it needs, the first
program, what it does not do yet, and what to do when something goes wrong. To build komira from a clone
instead, see [getting started](getting-started.md).

> **This is an early release.** It registers Parquet files as tables and runs SQL over them, with each
> answer read as pyarrow, or as a pandas or polars frame. Parts of the pandas-shaped DataFrame and
> of the polars-shaped `komira.pl` run as plans with no SQL; the
> [DataFrame pages](../python/docs/dataframe/overview.md) say which, and the rest comes in later
> releases of this same package.

## Install

In a new virtual environment of CPython 3.11, 3.12, 3.13 or 3.14:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install komira
```

That is the whole install. The wheel is about 11 MB on Linux and 8 MB on macOS, and `pip` installs
two other packages with it (`pip show komira` lists `Requires: protobuf, pyarrow`): pyarrow, which a
query's answer is read as, and protobuf, which a DataFrame's plan is encoded with.

## What it needs

| | |
|---|---|
| platform | **Linux on x86_64**, or **macOS 11 or newer on Apple silicon** (arm64; the wheel is tagged `macosx_11_0_arm64`). Linux on arm64 comes in a later release. There is no Windows package. |
| C library | **On Linux, glibc 2.35 or newer**: the wheel is tagged `manylinux_2_35_x86_64`. For example Ubuntu 22.04 or newer, Debian 12 or newer and Fedora 36 or newer have it; RHEL 9 (glibc 2.34) and Debian 11 (glibc 2.31) do not, and neither does Alpine (musl). `ldd --version` prints yours on its first line. |
| CPU | **On Linux, x86-64-v3**: AVX2, BMI2 and FMA. Intel CPUs from Haswell on and AMD CPUs from Excavator on have it, except some low-end Pentium, Celeron and Atom models. `grep -c avx2 /proc/cpuinfo` prints 0 on a CPU without AVX2. |
| Python | **CPython 3.11, 3.12, 3.13 or 3.14**. The package's tests, and a `pip install` of each release, run on each. One wheel serves all four. A newer CPython installs too, but nothing tests it yet. |
| C++ runtime | on Linux, the system `libstdc++`. Most systems have it; a minimal container image may need the `libstdc++6` package (Debian, Ubuntu) or `libstdc++` (Fedora, RHEL). macOS has its own. |

The wheel carries everything else: `libkomira`, the engine as one shared library, its native libraries,
and the three Mojo runtime libraries `libkomira` loads, which are Modular's and come under Modular's
licence (in the wheel's `.dist-info/licenses/`, beside komira's Apache-2.0 `LICENSE` and `NOTICE`). It
needs no Mojo installation and no package of Modular's.

## The first program

Save this as `quickstart.py` in an empty directory:

```python
import pyarrow as pa
import pyarrow.parquet as pq

import komira

print(komira.__version__)     # the installed version
print(komira.abi_version())   # the engine's C ABI version: 1010 is 1.10

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

It needs no other file: it writes the six-row Parquet file it queries, `weather.parquet`, with
pyarrow, which `pip install komira` installed. Then `python quickstart.py` prints:

```text
0.1.1623
1010
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

The first line is the version you installed, so a newer release prints a larger number there, and
`<cwd>` stands for the directory you ran it in: the relative name `no_such_file.parquet` is resolved
against it, and the error names the file komira looked for. The last two lines before `True` are
the two mistakes the program makes on purpose: the missing file raises `komira.BindError` and the
syntax error `komira.ParseError`, both kinds of `komira.KomiraError`, and the program prints each
message. The syntax error's message ends with ` at line 1, column 42` in releases newer than 0.1.1623;
0.1.1623 and older print it without that part.

This program is
[`python/examples/quickstart.py`](../python/examples/quickstart.py), and what it prints is
[`quickstart.expected`](../python/examples/quickstart.expected). Each pull request runs it on the
wheel installed into an empty environment. Before any upload, the release workflow installs the
wheel file with `pip` into an empty virtual environment on a fresh machine and runs it there; after
the upload to TestPyPI, and again after the upload to PyPI, it does the same with the published
wheel. Each run compares every line it prints with `quickstart.expected`; when one differs before the
upload nothing is uploaded, and when the TestPyPI run's output differs nothing is uploaded to PyPI.
The two blocks above are those files (the second with the version of the newest release
section in the [changelog](../python/CHANGELOG.md) and the ABI version filled in), and the build test
`//python/smoke:install_page_shows_quickstart` fails when they differ.

What each call does:

- `komira.__version__` is the installed version.
- `komira.abi_version()` loads the engine and returns its C ABI version as `major * 1000 + minor`.
  The engine is loaded on this call or the first `Session()`, not on `import komira`.
- `komira.Session()` is one engine context, and a context manager: leaving the `with` block closes
  it. `close()` can be called again; any other call on a closed session raises `komira.KomiraError`.
- `register_parquet(name, path)` reads the Parquet file's footer and registers the file as the table
  `name`. `path` is a `str` or a `pathlib.Path`; a relative path is resolved against the working
  directory and `~` is expanded. `register_csv(name, path)` and `register_json(name, path)` register
  a CSV file and a newline-delimited JSON file the same way, with the column names and types the
  engine infers from the file.
- `s.sql(query)` runs one SQL statement over the session's tables and returns a `komira.Result`. A
  syntax error (`komira.ParseError`), an unknown table or column (`komira.BindError`), or a construct
  the engine does not run yet (`komira.UnsupportedOperation`) raises from `sql`, with the engine's
  `<step>: <reason>` message; a syntax error's message ends with the line and column where the
  statement stopped parsing (newer than 0.1.1623).
- `to_arrow()` reads the whole answer as a `pyarrow.Table`, with its schema. A result is read once;
  `to_reader()` reads it batch by batch instead, and `pyarrow.table(result)` takes it through the
  Arrow PyCapsule interface. `to_pylist()` is pyarrow's, turning the table into Python rows.

The package's [README](../python/README.md), which is also its PyPI description, has the rest.

## What does not work yet

- **The DataFrame verbs not built yet**, of the pandas-shaped and the polars-shaped frames: the
  [capability table](design/dataframe_surface_verbs.md) marks each one "not built", and gives what the
  engine does with each capability's plan. Among them: the ORC, Avro and Arrow IPC readers, the
  readers on an object-store URL (`s3://`, `gs://`, `az://`; SQL reads `s3://` and `az://` Parquet
  through `Session.add_sql_binding`), frames made from Arrow data, and the polars-shaped frame's
  writers (`sink_parquet`, `sink_csv`, `sink_ndjson`); the pandas-shaped frame writes a local file
  with `to_parquet`, `to_csv` and `to_json`.
- **Python UDFs**: no verb takes a Python function yet, and `sql` runs none.
- **Other platforms**: Linux on arm64, macOS on Intel, Windows, and Linux with musl (Alpine) have no
  wheel.
- **Older systems**: on Linux, glibc older than 2.35 and CPUs older than x86-64-v3; macOS older than 11;
  Python older than 3.11.
- **Installing from source.** Only wheels are published, so `pip` cannot build komira from source.

## When something goes wrong

- **`ERROR: Could not find a version that satisfies the requirement komira`** and **`ERROR: No
  matching distribution found for komira`**: `pip` found no wheel for this machine. Check the
  [requirements](#what-it-needs): `python --version` (3.11 or newer), `uname -m` (`x86_64` on Linux,
  `arm64` on macOS) and, on Linux, `ldd --version` (2.35 or newer). An old `pip` may not know the `manylinux_2_35` tag:
  `pip install --upgrade pip` first.
- **`komira.UnsupportedCpuError`** (Linux): the CPU lacks a feature of x86-64-v3. The message lists the
  missing flags as `/proc/cpuinfo` spells them. komira raises it before it loads the engine, instead
  of letting the engine stop on an illegal instruction.
- **`komira.LibraryLoadError`**: the engine could not be loaded, and the message names the library
  and the reason. A file of the package that is missing (`pip install --force-reinstall komira` puts it
  back), or a Mojo runtime of another build already loaded in the process (by Mojo code built with
  another Mojo version: one process holds one Mojo runtime), are the usual causes.
- **`komira.BindError`** from `register_parquet`, `register_csv` or `register_json`: the file is
  missing, empty, or not a file of that format the engine can read, a glob pattern matches no file,
  the files of a pattern have different columns, or (for CSV and JSON) the session already has a
  table of that name. The message is the engine's; for `register_parquet` it
  names the file by its absolute path, a relative path resolved against the working directory.
- **`komira.ParseError`** from `sql`: a syntax error. The message starts with `parse: ` and ends with
  `at line <L>, column <C>`, where the statement stopped parsing (newer than 0.1.1623). Other
  refusals of `sql` start with the step that refused the statement: `bind: ...`
  (`komira.BindError`) names a table or column the session does not have (register it first).

`komira.KomiraError` is the base class of every error komira raises on purpose, so `except
komira.KomiraError` catches all of these. Anything else is a bug:
[open an issue](https://github.com/komira-ai/komira/issues) with the version, `python --version`,
`uname -m`, the first line of `ldd --version` and the full message.

## Upgrading and removing

```sh
pip install --upgrade komira
pip uninstall komira
```

Versions are `0.1.<n>`, and a larger `<n>` is a newer release. The package is pre-alpha
(`Development Status :: 2 - Pre-Alpha`): its names can still change from one release to the next. The
[changelog](../python/CHANGELOG.md) lists what each release added or changed.

## Keeping this page true

A pull request that changes what the package does, or what it needs, changes this page, the
[README](../python/README.md) and the [quickstart](../python/examples/README.md) with it, and adds
an entry, a file of [python/changelog.d/](../python/changelog.d/) that the release lists in
its [changelog](../python/CHANGELOG.md) section ([how](../python/README.md#changelog-entries)): the
releases that add more of the pandas-shaped and polars-shaped verbs, Python UDFs or Linux on arm64
extend the first program and its output where they change it, and move their lines out of
[what does not work yet](#what-does-not-work-yet).
