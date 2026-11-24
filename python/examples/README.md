# The quickstart

`quickstart.py` is the smallest program that uses the published `komira`
package: it prints the installed version and the engine's C ABI version,
opens a session, registers `readings.parquet` as the table `readings`, runs
`SELECT 1 AS n` and an aggregate over the table (its row count and the sum of
`value`, 5 and 152.5) and prints each answer's rows through pyarrow, and
closes the session. It runs from this directory.

- The user test of the wheel runs it on every push to main that changes code.
  The job `wheel-user-test` of `.github/workflows/pypi.yml` (before any
  upload) `pip install`s the wheel file the build made into an
  empty virtual environment on a fresh runner, once per supported Python
  (`python/pythons.bzl`), and runs `quickstart.py` there as below.
- The index smoke runs it. The jobs `testpypi-smoke` (every push to main
  that changes code) and `pypi-smoke` (the daily promotion) of
  `.github/workflows/pypi.yml` `pip install` the published wheel into an empty
  virtual environment, run `quickstart.py` there with `readings.parquet` beside
  it, and compare what it prints with `quickstart.expected` exactly, after
  replacing `<version>` with the installed version and `<abi_version>` with the
  ABI version of `src/so/abi/komira.tsv` (`1.4` is `1004`).
- The "What works" block of [the package README](../README.md) is the same
  text as `quickstart.py`, byte for byte. The test
  `//python/smoke:readme_shows_quickstart` fails when the two differ.
- The install page, [docs/install.md](../../docs/install.md), shows the same
  program and what it prints: `quickstart.expected` with the version of the
  newest release in [the changelog](../CHANGELOG.md) and the ABI version
  filled in. The test `//python/smoke:install_page_shows_quickstart` fails
  when either block differs.
- `readings.parquet` is a byte copy of
  [`pyarrow_gzip_plain.parquet`](../../src/parquet_codec/tests/fixtures/parquet/pyarrow_gzip_plain.parquet),
  written by
  [`gen_pyarrow_fixtures.py`](../../src/parquet_codec/tests/fixtures/parquet/gen_pyarrow_fixtures.py).
  It holds five rows of two columns: `id` (INT64, 1 to 5) and `value`
  (DOUBLE, 10.5 to 50.5).

A change that lands a capability, for example the pandas terminal of a
result, extends `quickstart.py`, the README block, the install page's two
blocks and `quickstart.expected` in the same pull request.

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
