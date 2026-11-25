# The quickstart

`quickstart.py` is the smallest program that uses the published `komira`
package the way a new user does, and `quickstart.expected` is what it prints.
It needs no file beside it and runs in an empty directory:

- it prints the installed version and the engine's C ABI version;
- it writes `weather.parquet` with pyarrow (six rows: `city`, `temp` as
  INT64 and `rain` as DOUBLE), opens a session and registers the file as the
  table `weather`;
- it runs an aggregate (6 days, 9.5 of rain) and reads it as rows;
- it runs a GROUP BY with an aggregate and an ORDER BY (per city: the number
  of days, the mean and the highest temperature), reads it as a pyarrow
  Table and prints its schema and each row;
- it reads a filtered, ordered query with `to_reader()` and through the
  Arrow PyCapsule interface (`pyarrow.table(result)`);
- it makes two mistakes and prints each `komira.KomiraError`: a missing file
  (`komira.BindError`), whose message names the file by its absolute path,
  and a SQL syntax error (`komira.ParseError`), whose message names the line
  and column;
- it closes the session.

Every value it prints can be checked by eye against the six rows it wrote.
In `quickstart.expected`, `<version>` stands for the installed version,
`<abi_version>` for the ABI version of `src/so/abi/komira.tsv` (`1.9` is
`1009`) and `<cwd>` for the real path of the directory the program ran in.

Where it runs, each time compared with `quickstart.expected` exactly, every
line, with those three filled in:

- In the pull request check. `//python:wheel_install_test` (and its
  `_py311`, `_py312` and `_py314` siblings) installs the wheel into an empty
  environment and `python/tests/test_installed.py` runs the program there,
  from an empty directory.
- In the user test of the wheel, on every push to main that changes code. The
  job `wheel-user-test` of `.github/workflows/pypi.yml` (before any upload)
  `pip install`s the wheel file the build made into an empty virtual
  environment on a fresh runner, once per supported Python
  (`python/pythons.bzl`), and runs the program with `python -I` in a
  directory that holds only it.
- In the index smoke. The jobs `testpypi-smoke` (every push to main that
  changes code) and `pypi-smoke` (the daily promotion) of
  `.github/workflows/pypi.yml` do the same with the wheel `pip` installs from
  the index; `pypi-macos-arm64.yml` does it for the macOS wheel.

The docs show the same text:

- The "What works" section of [the package README](../README.md), which is
  also the package's description on PyPI, shows `quickstart.py` byte for
  byte and what it prints: `quickstart.expected` with the version of the
  newest release in [the changelog](../CHANGELOG.md) and the ABI version
  filled in, and `<cwd>` as written. The test
  `//python/smoke:readme_shows_quickstart` fails when either block differs,
  and the install test holds the wheel's description to the README byte for
  byte.
- The install page, [docs/install.md](../../docs/install.md), shows the same
  two blocks. The test `//python/smoke:install_page_shows_quickstart` fails
  when either differs.

A change that lands a capability, for example the pandas terminal of a
result, extends `quickstart.py`, `quickstart.expected`, the README's two
blocks and the install page's two blocks in the same pull request.

# The analysis job

`analysis_job.py` is a realistic job over two files it writes itself: orders
as Parquet and customers as CSV. It registers the Parquet file as a table,
reads the CSV with `read_csv`, joins them, sums per customer, ranks the
customers of each region with `row_number()` and a running `sum()` window,
keeps the top two of each region and the top three overall, and writes the
per-region result to `top_customers.parquet` with `COPY ... TO`. The amounts
are whole cents in a BIGINT column, so every sum is exact and the answer is
the same in any engine that follows DuckDB.

- `analysis_job_test` of `python/BUCK` runs it from the installed wheel on
  CPython 3.13, installed beside pyarrow and the pinned DuckDB wheel, and holds
  the per-region answer, the overall answer and the Parquet file it wrote to
  DuckDB's answer for the same SQL over the same files. The same query with
  the join on the wrong key must differ from DuckDB's answer. It also starts
  the command below as a child process and holds its exit code, printed rows,
  written Parquet file and usage error to the same account.
- Run it yourself with `python analysis_job.py <empty directory>`.
