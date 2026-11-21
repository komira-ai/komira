# The quickstart

`quickstart.py` is the smallest program that uses the published `komira`
package: it prints the installed version and the engine's C ABI version,
opens a session, registers `readings.parquet` as the table `readings`, and
closes the session. It runs from this directory.

- The release smoke runs it. The jobs `testpypi-smoke` and `pypi-smoke` of
  `.github/workflows/pypi.yml` `pip install` the published wheel into an empty
  virtual environment, run `quickstart.py` there with `readings.parquet` beside
  it, and compare what it prints with `quickstart.expected` exactly, after
  replacing `<version>` with the installed version and `<abi_version>` with the
  ABI version of `src/so/abi/komira.tsv` (`1.1` is `1001`).
- The "What works" block of [the package README](../README.md) is the same
  text as `quickstart.py`, byte for byte. The test
  `//python/smoke:readme_shows_quickstart` fails when the two differ.
- `readings.parquet` is a byte copy of
  [`pyarrow_gzip_plain.parquet`](../../src/parquet_codec/tests/fixtures/parquet/pyarrow_gzip_plain.parquet),
  written by
  [`gen_pyarrow_fixtures.py`](../../src/parquet_codec/tests/fixtures/parquet/gen_pyarrow_fixtures.py).
  It holds five rows of two columns: `id` (INT64, 1 to 5) and `value`
  (DOUBLE, 10.5 to 50.5).

A change that lands a capability, for example the call that runs a query,
extends `quickstart.py`, the README block and `quickstart.expected` in the same
pull request. The next step is a query over `readings.parquet` with its five
rows asserted.
