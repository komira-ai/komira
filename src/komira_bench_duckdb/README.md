# komira_bench_duckdb

The DuckDB side of a komira benchmark, and the checks that decide whether an answer is the right one. It holds:

- **a pin table and a verifier** for a DuckDB binary you supply: the file is accepted only when its SHA-256 and size are those of the pinned release (today 1.5.6, the version `third_party/duckdb` pins);
- **one persistent DuckDB session** driven over stdin and stdout, every query bracketed by marker lines the host stamps with its own clock as they arrive, with the thread count and the memory limit set and read back;
- **the value checks**: a per-column signature that does not depend on row order, compared with a relative tolerance, a separate row-order check for `ORDER BY` queries, and recorded reference answers a package can compile in, so values are checked without running DuckDB at all.

DuckDB is not shipped, linked or downloaded by this package. A package on the registry is a `.mojoc` and cannot carry an executable, and the code writes no download address: you get the DuckDB CLI yourself and pass its path.

## Check a binary

```text
from komira_bench_duckdb import check_duckdb_file, DEFAULT_DUCKDB_VERSION

def main() raises:
    var got = check_duckdb_file("/path/to/duckdb", DEFAULT_DUCKDB_VERSION)
    print(got.describe())          # PINNED duckdb 1.5.6 sha256 ...
    if not got.is_pinned():
        raise Error("refusing to benchmark against " + got.describe())
```

`check_duckdb_file` returns `PIN_PINNED` only when digest and size both match the table. A file that is the release archive (the `.zip` the project publishes) says so and asks you to unpack it. Any other file reports the digest and size it has. A version with no row in `duckdb_pins()` is refused: there is no switch that runs an unpinned binary.

## Drive a session

```text
from komira_bench_duckdb import BenchClock, DuckDbSession, ProcessTransport

def main() raises:
    var args = List[String]()                      # arguments of the duckdb binary
    var s = DuckDbSession[ProcessTransport](
        ProcessTransport("/path/to/duckdb", args), BenchClock.system()
    )
    # the same two numbers configure the other engine's arm
    var settings = s.start(threads=20, memory_limit_bytes=16 * 1024 * 1024 * 1024)
    print(settings.version, settings.threads_readback, settings.memory_limit_readback)

    s.fetch("CREATE VIEW t AS SELECT * FROM read_parquet('/data/t.parquet')")
    var timed = s.run_timed("SELECT count(*) FROM t")   # nothing is rendered
    print(timed.elapsed_ns, timed.error)
    var answer = s.fetch("SELECT count(*) AS n, sum(x) AS s FROM t")
    _ = s.close()
```

A session sends `.print @@S <n>` before a query and `.print @@E <n>` after it. The host takes the time of each marker line when the line is read from the pipe, and a timed query's duration is the end marker minus the start marker, in nanoseconds on `BenchClock`. A timed query runs under `.mode trash`; a fetched query runs under `.mode json` and comes back as a `ResultSet`. DuckDB's own error text for a query comes back in `error` of that query's result. A query whose two markers arrive in one read has the same stamp on both. A query is cheap to time only if it is long next to one pipe read.

`start` sets `threads` and `memory_limit` (a whole number of KiB, sent as `KiB`), applies the extra `(name, value)` settings you pass (each sent as `SET name='value'` and read back with `current_setting`), reads everything back, and raises when the thread count did not take or the process is not the pinned release and build. The memory limit comes back in DuckDB's own rounded text (`memory_limit_readback`); the thread count is compared exactly. The settings a board should record on the DuckDB arm are the two above plus whatever caches the comparison needs; name them in `extra_settings`, and they appear in `FairnessSettings`.

`ProcessTransport` uses `komira_supervisor`: the binary is started without a shell, with stdin, stdout and stderr on pipes. Any other conformer of `DuckDbTransport` can stand in for the process; the tests use one that lives in the test file and a shell loop for the real pipes.

The same session over a shell loop that stands in for DuckDB (this is a program the README gate runs; no DuckDB is needed):

```mojo
from komira_bench_duckdb import BenchClock, DuckDbSession, ProcessTransport


def main() raises:
    var args = List[String]()
    args.append("-c")
    args.append(
        'while IFS= read -r l; do case "$l" in'
        ' ".print "*) echo "${l#.print }";;'
        ' "SELECT 1"*) echo \'[{"one":1}]\';;'
        " esac; done"
    )
    var s = DuckDbSession[ProcessTransport](
        ProcessTransport("/bin/sh", args), BenchClock.system()
    )
    var answer = s.fetch("SELECT 1 AS one")
    if not answer.ok() or answer.rows.rows[0][0].i != 1:
        raise Error("the stand-in answered wrongly")
    var timed = s.run_timed("SELECT 1")
    if not timed.ok():
        raise Error(timed.error)
    if s.close() != 0:
        raise Error("the stand-in exited with an error")
```

## Check values

The signature of a result is, per column, the count of non-null cells, the sum, the sum of squares, the minimum and the maximum (for text: the count, the total byte length, the smallest and the largest cell). Two results with the same rows in any order have the same signature. `compare_signatures` compares two of them:

- the row count, the column count, each column's kind and its counts of non-null, null and NaN cells are equal;
- numbers are equal when they differ by at most the larger of `ABS_FLOOR` (1e-6) and `REL_TOL` (1e-9) times the larger magnitude;
- an integer column's minimum and maximum are compared exactly, and so are its sum and sum of squares while both stay below 2^53; past that the field falls back to the tolerance, and the verdict's `modes` list says which mode each field used (`column 0.sum=exact`, `column 0.sumsq=tolerance`);
- column names are not compared.

`check_order` is separate because the signature ignores order: it checks that the rows of an `ORDER BY` query are monotone in the keys (`OrderKey(column, descending, nulls_first)`; NULLs last by default, as in DuckDB).

```mojo
from komira_bench_duckdb import (
    Cell,
    OrderKey,
    ReferenceAnswer,
    ResultSet,
    check_order,
    compare_signatures,
    format_reference,
    parse_json_rows,
    parse_references,
    signature_of,
)


def main() raises:
    # rows as DuckDB prints them with `.mode json`
    var got = parse_json_rows('[{"k":2,"v":0.5},\n{"k":1,"v":1.5}]')

    # a recorded answer is text; a package keeps it as a constant
    var recorded = ReferenceAnswer("q1")
    var expected = ResultSet()
    expected.names.append("k")
    expected.names.append("v")
    var first = List[Cell]()
    first.append(Cell.integer(Int64(1)))
    first.append(Cell.real(1.5))
    expected.add_row(first^)
    var second = List[Cell]()
    second.append(Cell.integer(Int64(2)))
    second.append(Cell.real(0.5))
    expected.add_row(second^)
    recorded.signature = signature_of(expected)
    var text = format_reference(recorded)

    var set = parse_references(text)
    var reference = set.answers[set.find("q1")].copy()
    var verdict = compare_signatures(signature_of(got), reference.signature)
    if not verdict.identical:
        raise Error(verdict.label())

    # the rows came back in descending key order: an ORDER BY k would fail
    var keys = List[OrderKey]()
    keys.append(OrderKey(0))
    if check_order(got, keys).ok:
        raise Error("expected the order check to fail")
```

A recorded answer is one record per query (`format_reference`, `parse_references`; the layout is at the top of `reference.mojo`): its row count, its signature and its `ORDER BY` keys. It is how a run without DuckDB is value-checked. Recording answers is done once against the pinned DuckDB, and a run with DuckDB then also cross-checks its live answer against the recorded one, which catches a DuckDB of another version.

## What it does not do

- No download of DuckDB and no data. The files a benchmark reads are the user's, passed as paths in the queries.
- No unpinned run, and no ratio or report: this package returns timings and verdicts, and another package turns them into a board.
- No nested values (lists, structs) in a result, no `HUGEINT` beyond 64 bits (an integer past 64 bits is read as a double), and no NaN or infinity in a recorded sum.
- No timeout: a DuckDB query that never ends blocks the session. Stop the process from outside.
- The wire to DuckDB (`.mode`, `.print`, JSON output, `pragma_version`, `current_setting`) is DuckDB's documented CLI; this package's tests use stand-ins, so a real run is the check that the exact settings you name are accepted.

## Tests

`tests/test_values.mojo` (signature, tolerance and order on fixed inputs), `tests/test_reference_rows.mojo` (recorded answers and the JSON output), `tests/test_pins.mojo` (the pin table and the digest check on made-up bytes), `tests/test_session.mojo` (the session over an in-test stand-in and a manual clock: timing from markers, errors, fetch, settings) and `tests/test_process.mojo` (the same session over real pipes to a shell loop). No test reads the time or waits.
