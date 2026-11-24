# Installing komira for Python

komira's Python package is `komira` on PyPI. This page covers installing it, what it needs, the first
program, what it does not do yet, and what to do when something goes wrong. To build komira from a clone
instead, see [getting started](getting-started.md).

> **This is an early release.** It registers Parquet files as tables and runs SQL over them, with each
> answer read as pyarrow. A DataFrame API shaped like pandas and one shaped like polars come in later
> releases of this same package. This page changes when they do.

## Install

In a new virtual environment of CPython 3.11, 3.12, 3.13 or 3.14:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install komira
```

That is the whole install. The wheel is about 2.4 MB, and `pip` installs one other package with it,
pyarrow (`pip show komira` lists `Requires: pyarrow`), which a query's answer is read as.

## What it needs

| | |
|---|---|
| platform | **Linux on x86_64**. Linux on arm64 and macOS on Apple silicon come in later releases. There is no Windows package. |
| C library | **glibc 2.35 or newer**: the wheel is tagged `manylinux_2_35_x86_64`. For example Ubuntu 22.04 or newer, Debian 12 or newer and Fedora 36 or newer have it; RHEL 9 (glibc 2.34) and Debian 11 (glibc 2.31) do not, and neither does Alpine (musl). `ldd --version` prints yours on its first line. |
| CPU | **x86-64-v3**: AVX2, BMI2 and FMA. Intel CPUs from Haswell on and AMD CPUs from Excavator on have it, except some low-end Pentium, Celeron and Atom models. `grep -c avx2 /proc/cpuinfo` prints 0 on a CPU without AVX2. |
| Python | **CPython 3.11, 3.12, 3.13 or 3.14**. The package's tests, and a `pip install` of each release, run on each. One wheel serves all four. A newer CPython installs too, but nothing tests it yet. |
| C++ runtime | the system `libstdc++`. Most systems have it; a minimal container image may need the `libstdc++6` package (Debian, Ubuntu) or `libstdc++` (Fedora, RHEL). |

The wheel carries everything else: `libkomira`, the engine as one shared library, its native libraries,
and the three Mojo runtime libraries `libkomira` loads, which are Modular's and come under Modular's
licence (in the wheel's `.dist-info/licenses/`, beside komira's Apache-2.0 `LICENSE` and `NOTICE`). It
needs no Mojo installation and no package of Modular's.

## The first program

Save this as `quickstart.py`:

```python
import komira

print(komira.__version__)     # the installed version
print(komira.abi_version())   # the engine's C ABI version: 1006 is 1.6

with komira.Session() as s:
    s.register_parquet("readings", "readings.parquet")
    print(s.sql("SELECT 1 AS n").to_arrow().to_pylist())
    result = s.sql("SELECT count(*) AS n, sum(value) AS total FROM readings")
    print(result.to_arrow().to_pylist())   # a pyarrow Table, as Python rows
print(s.closed)               # True: the session is freed
```

and put the five-row Parquet file the release checks use beside it as `readings.parquet` (the query
reads its column `value`):

```sh
curl -LO https://raw.githubusercontent.com/komira-ai/komira/main/python/examples/readings.parquet
```

Then `python quickstart.py` prints:

```text
0.1.1512
1006
[{'n': 1}]
[{'n': 5, 'total': 152.5}]
True
```

The first line is the version you installed, so a newer release prints a larger number there.

This program is
[`python/examples/quickstart.py`](../python/examples/quickstart.py). After the upload to TestPyPI, and
again after the upload to PyPI, the release workflow installs the published wheel with `pip` into an
empty virtual environment on a fresh machine, runs this program there and compares what it prints
with [`quickstart.expected`](../python/examples/quickstart.expected); when the TestPyPI run's output
differs, the release stops and nothing is uploaded to PyPI. The two blocks above are those files (the second with the version of the newest release
in the [changelog](../python/CHANGELOG.md) and the ABI version filled in), and the build test
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
  syntax error, an unknown table or column, or a construct the engine does not run yet raises
  `komira.KomiraError` from `sql`, with the engine's message.
- `to_arrow()` reads the whole answer as a `pyarrow.Table`. A result is read once; `to_reader()` reads
  it batch by batch instead, and `pyarrow.table(result)` takes it through the Arrow PyCapsule
  interface. `to_pylist()` is pyarrow's, turning the table into Python rows.

The package's [README](../python/README.md), which is also its PyPI description, has the rest.

## What does not work yet

- **pandas and polars results.** A result reads as pyarrow only; `pyarrow.Table.to_pandas()` and
  `polars.from_arrow()` convert it.
- **One session from two threads at once.** Use a session per thread.
- **The DataFrame APIs**, pandas-shaped and polars-shaped.
- **Python UDFs.**
- **Other platforms**: Linux on arm64, macOS, Windows, and Linux with musl (Alpine) have no wheel.
- **Older systems**: glibc older than 2.35, CPUs older than x86-64-v3 and Python older than 3.11.
- **Installing from source.** Only wheels are published, so `pip` cannot build komira from source.

## When something goes wrong

- **`ERROR: Could not find a version that satisfies the requirement komira`** and **`ERROR: No
  matching distribution found for komira`**: `pip` found no wheel for this machine. Check the
  [requirements](#what-it-needs): `python --version` (3.11 or newer), `uname -m` (`x86_64`) and
  `ldd --version` (2.35 or newer). An old `pip` may not know the `manylinux_2_35` tag:
  `pip install --upgrade pip` first.
- **`komira.UnsupportedCpuError`**: the CPU lacks a feature of x86-64-v3. The message lists the
  missing flags as `/proc/cpuinfo` spells them. komira raises it before it loads the engine, instead
  of letting the engine stop on an illegal instruction.
- **`komira.LibraryLoadError`**: the engine could not be loaded, and the message names the library
  and the reason. A file of the package that is missing (`pip install --force-reinstall komira` puts it
  back), or a Mojo runtime of another build already loaded in the process (by Mojo code built with
  another Mojo version: one process holds one Mojo runtime), are the usual causes.
- **`komira.KomiraError`** from `register_parquet`, `register_csv` or `register_json`: the file is
  missing, empty, or not a file of that format the engine can read, or (for CSV and JSON) the
  session already has a table of that name. The message is the engine's.

`komira.KomiraError` is the base class of every error komira raises on purpose, so `except
komira.KomiraError` catches all three. Anything else is a bug:
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
[README](../python/README.md), the [quickstart](../python/examples/README.md) and the
[changelog](../python/CHANGELOG.md) with it: the release that adds SQL extends the first program with
a query over `readings.parquet` and its rows, and the releases that add the pandas-shaped and
polars-shaped APIs and other platforms move their lines out of
[what does not work yet](#what-does-not-work-yet).
