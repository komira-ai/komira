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

`open_pinned(path, version, max_silence_ms)` is the one call that checks and then starts: it reads the file, refuses with the check's message unless the file is the pinned binary, and returns a session on a process started from that path. It starts nothing for a file that is not pinned. The file is read once and then started by its path, so a file replaced between those two steps is not detected.

## Drive a session

```text
from komira_bench_duckdb import open_pinned

def main() raises:
    # the path is an argument of your program; 600000 ms of silence is the
    # longest wait for output before a query raises
    var s = open_pinned("/path/to/duckdb", "1.5.6", 600000)
    # the same two numbers configure the other engine's arm
    var settings = s.start(threads=20, memory_limit_bytes=16 * 1024 * 1024 * 1024)
    print(settings.version, settings.threads_readback, settings.memory_limit_readback)

    var view = s.fetch("CREATE VIEW t AS SELECT * FROM read_parquet('path/to/t.parquet')")
    var timed = s.run_timed("SELECT count(*) FROM t")   # nothing is rendered
    if timed.resolved:
        print(timed.elapsed_ns, timed.error)
    var answer = s.fetch("SELECT count(*) AS n, sum(x) AS s FROM t")
    _ = s.close()       # on a raised query, call s.kill() instead
```

A session sends `.print @@S <n>` before a query and `.print @@E <n>` after it. The host takes the time of each marker line when the line is read from the pipe, and a timed query's duration is the end marker minus the start marker, in nanoseconds on `BenchClock`. A timed query runs under `.mode trash`; a fetched query runs under `.mode json` and comes back as a `ResultSet`. DuckDB's JSON quotes DECIMAL, HUGEINT, UHUGEINT and UBIGINT values (as it quotes every type but BIGINT and DOUBLE), so a quoted `123.4567` is a DECIMAL or a VARCHAR only by the column's type. Every fetched query is therefore followed by `DESCRIBE <the same query>` in the same session (the query is never rewritten, a timed query never gets one, and the settings read-back of `start` sends none). The types it answers with do two things: a DECIMAL is read as an exact decimal cell, a HUGEINT, UHUGEINT or UBIGINT is an integer cell when it fits 64 bits and an exact decimal cell beyond, a VARCHAR or DATE stays a text, and once the types are read a value in such a column that is not an exact number of its type is an error; and each type is recorded on the result as the column's declared type (`ResultSet.types`, see Declared column types below), for an answer with no rows too. DuckDB's own error text for a query comes back in `error` of that query's result. A query whose two markers arrive in one read has the same stamp on both: its `elapsed_ns` is 0 and `resolved` is False, which means "shorter than the clock could tell apart", not a measurement of zero. Do not record such a time as a result. A query is cheap to time only if it is long next to one pipe read.

A session raises when the process stops writing (its output ends, or a write to it fails) and, with `max_silence_ms` above zero, when that many milliseconds pass without any output while a query waits for its end marker. After a raise the session is unusable: stop the process with `kill()`. `ProcessTransport` drains the process's error output whenever it waits on or reads the output, so an error text of any length cannot block the process before it prints its end marker. A write to a process that has exited raises; it never ends this process with SIGPIPE.

A query's last line may end with a semicolon or not; a last line that holds `--` is followed by a line holding only `;` so that a semicolon inside a comment does not leave the statement open. An unterminated quote or block comment still swallows the end marker: that is what `max_silence_ms` is for.

`start` turns off extension auto-install and auto-load (so a run never fetches or loads code on its own), sets `threads` and `memory_limit` (a whole number of KiB, sent as `KiB`) and applies the extra `(name, value)` settings you pass, each as its own statement with nothing rendered (each sent as `SET name='value'`). It then reads everything back with `current_setting` and raises when the thread count, the memory limit or an extra setting did not take, or the process is not the pinned release and build. The memory limit comes back in DuckDB's own rounded text (`memory_limit_readback`, for example `953.7 MiB`) and is compared with the request within the rounding of the printed digits; a read-back that is not a size raises. The thread count is compared exactly, and an extra setting is compared as text ignoring case, or as a size when both are sizes. The settings the DuckDB arm should record are the two above plus whatever caches the comparison needs; name them in `extra_settings`, and they appear in `FairnessSettings`. The process also reads the startup file of the user it runs as, if there is one; that file can change settings the run does not set, so run the benchmark as a user without one.

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

The signature of a result is, per column, the count of non-null cells, the sum, the sum of squares, the minimum and the maximum. An integer column also keeps its sum and sum of squares modulo 2^64, which are exact however large the numbers are. A DECIMAL column (and an integer past 64 bits) keeps the count of its decimals, their exact sum (no rounding, no width limit), their smallest and largest value and the sum of a 64-bit hash of every value's canonical text; a decimal is never turned into a double, and `123.40` and `123.4` are one value. A text column keeps the count, the total byte length, the smallest and the largest cell, and the sum of a 64-bit hash of every cell, so a changed cell shows even when the length and the extremes are the same. Two results with the same rows in any order have the same signature. `compare_signatures` compares two of them:

- the row count, the column count, each column's kind and its counts of non-null, null and NaN cells are equal;
- each column's declared type is equal (see Declared column types below), and a difference is a failure of its own, listed in `type_reasons` as well as in `reasons`, even when every value agrees;
- numbers are equal when they are the same value (two infinities of one sign included) or differ by at most the larger of `ABS_FLOOR` (1e-6) and `REL_TOL` (1e-9) times the larger magnitude;
- an integer column's minimum, maximum, sum and sum of squares are compared exactly (the sums modulo 2^64, so there is no size at which they fall back to a tolerance);
- an exact decimal column compares its count of decimals, sum, minimum, maximum and hash sum exactly, with no tolerance; a decimal column against a column of any other kind (a double column included) is a difference of kinds;
- a numeric column that holds only integers on one side and doubles on the other (engines return `SUM`, `COUNT` and `AVG` as different types, and a double with no fraction may print without a point) is compared as numbers with the tolerance;
- the verdict's `modes` list says which mode each column used (`column 0.sum=exact`, `column 1.sum=tolerance`);
- column names are not compared, and two results with no rows are identical whatever their columns (a result with no rows carries no column names, so a reference recorded with columns would otherwise never match), unless both carry declared types, which are then compared;
- the comparison does not stop at the first difference.

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
    # a session's fetch records the declared types; rows parsed by hand name them
    got.types.append("BIGINT")
    got.types.append("DOUBLE")

    # a recorded answer is text; a package keeps it as a constant
    var recorded = ReferenceAnswer("q1")
    var expected = ResultSet()
    expected.names.append("k")
    expected.names.append("v")
    expected.types.append("BIGINT")
    expected.types.append("DOUBLE")
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

A recorded answer is one record per query (`format_reference`, `parse_references`; the layout is at the top of `reference.mojo`, today `format 3`): its row count, its signature (with each column's declared type) and its `ORDER BY` keys. A record in another format, `format 2` included, is refused with a message that says to record the answers again; a column with no declared type, or one outside the vocabulary, is not written. It is how a run without DuckDB is value-checked. Recording answers is done once against the pinned DuckDB, and a run with DuckDB then also cross-checks its live answer against the recorded one, which catches a DuckDB of another version.

## Declared column types

Both engines state a declared type for every result column, in one vocabulary, and the comparison fails by name when they differ. A DECIMAL(38,2) against a DECIMAL(38,4), or a BIGINT against a DECIMAL(18,0), is a different result even when every value is equal, because the rule is the same result as DuckDB for the same SQL. DuckDB's side is the `column_type` of `DESCRIBE <query>`; komira's side is the Arrow type of the result batches (`komira_bench_runner`, `convert.mojo`). Equal means the same vocabulary entry:

| vocabulary entry | DuckDB `DESCRIBE` name | Arrow type that equals it |
|---|---|---|
| `BOOLEAN` | `BOOLEAN` | `BOOL` |
| `TINYINT` | `TINYINT` | `INT8` |
| `SMALLINT` | `SMALLINT` | `INT16` |
| `INTEGER` | `INTEGER` | `INT32` |
| `BIGINT` | `BIGINT` | `INT64` |
| `HUGEINT` | `HUGEINT` | none (Arrow has no 128-bit integer) |
| `UTINYINT` | `UTINYINT` | `UINT8` |
| `USMALLINT` | `USMALLINT` | `UINT16` |
| `UINTEGER` | `UINTEGER` | `UINT32` |
| `UBIGINT` | `UBIGINT` | `UINT64` |
| `UHUGEINT` | `UHUGEINT` | none (Arrow has no unsigned 128-bit integer) |
| `FLOAT` | `FLOAT` | `FLOAT32` |
| `DOUBLE` | `DOUBLE` | `FLOAT64` |
| `VARCHAR` | `VARCHAR` | `STRING`, `LARGE_STRING` |
| `DATE` | `DATE` | `DATE32` |
| `DECIMAL(p,s)`, 1 <= p <= 38, 0 <= s <= p | `DECIMAL(p,s)` (no space) | `DECIMAL128` with precision p and scale s |

Rows of the table with Arrow `none` are the departures Arrow forces: a komira column holding values that need 128 bits can only be a `DECIMAL128(38,0)`, which is the entry `DECIMAL(38,0)` and differs from `HUGEINT`; the comparison reports that difference, it does not hide it.

Everything else has no entry: TIMESTAMP and its variants, TIME, INTERVAL, BLOB, UUID, ENUM, nested types, a DuckDB name in any other spelling, and on the Arrow side `DECIMAL256`, dictionary and binary columns, timestamps and nested types. Such a type is kept as `UNMAPPED(<the name it came with>)`, and a comparison that meets one fails with a message that says the type is not in the mapping, on either side and even when both sides have the same one. An unmapped type is a reported failure, never a pass. Types recorded on one side only also fail; a result built by hand with no types on either side is compared by value alone. The mapping functions are `duckdb_declared_type`, `is_declared_type`, `is_unmapped` and `decimal_type`.

## What it does not do

- No download of DuckDB and no data. The files a benchmark reads are the user's, passed as paths in the queries.
- No unpinned run, and no ratio or report: this package returns timings and verdicts, and another package turns them into a report.
- No nested values (lists, structs) in a result, and no `HUGEINT` beyond 64 bits (an integer past 64 bits is read as a double). NaN and infinity are read when DuckDB writes them as the bare words `NaN`, `Infinity`, `-Infinity` (or `nan`, `inf`, `-inf`); written as quoted texts they are texts.
- The wire to DuckDB (`.mode`, `.print`, JSON output, `pragma_version`, `current_setting`) is DuckDB's documented CLI; this package's tests use stand-ins, so a real run is the check that the exact settings you name are accepted.

## Tests

`tests/test_values.mojo` (signature, tolerance and order on fixed inputs), `tests/test_declared_types.mojo` (the type mapping and the comparison of declared types), `tests/test_exact_decimal.mojo` (exact decimal text, sums past 128 bits, the decimal signature, its comparison and its recorded form), `tests/test_reference_rows.mojo` (recorded answers and the JSON output), `tests/test_memory.mojo` (printed sizes and the memory-limit read-back), `tests/test_pins.mojo` (the pin table and the digest check on made-up bytes), `tests/test_session.mojo` (the session over an in-test stand-in and a manual clock: timing from markers, errors, fetch, settings, silence, a failed write) and `tests/test_process.mojo` (the same session over real pipes to a shell loop, a long error text, a silent process and a write to a process that has gone). No test asserts a duration. `test_process` starts real processes: its checks are on what comes back and on the errors raised, never on how long anything took.
