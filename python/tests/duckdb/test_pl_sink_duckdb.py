"""komira.pl's `sink_csv` held to DuckDB: each frame program writes its CSV
file through komira's plan door (`komira_plan_stream` with a write target, no
SQL), DuckDB runs `COPY (<the SQL that means the program>) TO ... (FORMAT csv,
HEADER true)` over the same Parquet file, and the two files must be equal byte
for byte (`pl_sink_duckdb_test`, CPython 3.13, the real libkomira).

- the file: 7 rows built in code, row groups of 3. `id` int64, unique; `n`
  int64 with NULLs and a negative; `i` int32; `x` float64 with NULLs, a
  negative, zero, a fraction with no short binary form and a six-digit one;
  `s` string with NULLs, an empty string, a comma, a double quote, a line
  break, leading and trailing spaces and non-ASCII text; `flag` bool with
  NULLs; `d` date32 with NULLs and a leap day;
- test_sink_csv_equals_duckdbs_copy: the whole frame sorted by `id`, sorted
  downwards, a filtered and computed frame sorted by `id`, a head of a sort,
  and a frame of no rows (the header line alone);
- test_a_compressed_sink_csv_holds_duckdbs_bytes: gzip and zstd files whose
  decompressed bytes equal DuckDB's uncompressed COPY of the same query;
- test_to_csv_equals_duckdbs_copy: the pandas-shaped frame's `to_csv`, with
  `sep=","` and `header=True`, writes the same bytes as DuckDB.

Every case runs even when an earlier one fails, and the test then fails naming
each failing case with the two files' first differing line.

    test_pl_sink_duckdb.py --lib-dir <dir> --runtime-dir <dir>
"""

import datetime
import os
import sys
import tempfile

import komira
from komira import _native

IDS = [1, 2, 3, 4, 5, 6, 7]
N = [10, None, -5, 7, None, 0, 3]
I32 = [1, 2, 3, 4, 5, 6, 7]
X = [1.5, -2.5, 0.0, None, 0.1, 123456.789, None]
S = ["plain", "a, b", 'say "hi"', None, "two\nlines", "", "  é ü 漢  "]
FLAG = [True, False, None, True, False, True, None]
D = [
    datetime.date(2028, 2, 29),
    None,
    datetime.date(2030, 12, 31),
    datetime.date(2027, 1, 1),
    None,
    datetime.date(2029, 6, 15),
    datetime.date(2027, 9, 9),
]


def write_data(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pa.table(
        {
            "id": pa.array(IDS, pa.int64()),
            "n": pa.array(N, pa.int64()),
            "i": pa.array(I32, pa.int32()),
            "x": pa.array(X, pa.float64()),
            "s": pa.array(S, pa.string()),
            "flag": pa.array(FLAG, pa.bool_()),
            "d": pa.array(D, pa.date32()),
        }
    )
    pq.write_table(table, path, row_group_size=3)
    return path


def first_difference(got, want):
    g, w = got.split(b"\n"), want.split(b"\n")
    for k, (a, b) in enumerate(zip(g, w)):
        if a != b:
            return f"line {k + 1}: komira {a!r}, DuckDB {b!r}"
    return f"komira has {len(g)} lines, DuckDB {len(w)}"


class Cases:
    def __init__(self):
        self.failures = []
        self.count = 0

    def equal(self, name, got, want):
        self.count += 1
        if got != want:
            self.failures.append(f"{name}: {first_difference(got, want)}")


def read(path):
    with open(path, "rb") as f:
        return f.read()


def duckdb_copy(con, work, name, sql):
    out = os.path.join(work, f"duckdb_{name}.csv")
    con.execute(f"COPY ({sql}) TO '{out}' (FORMAT csv, HEADER true)")
    return read(out)


def programs(kpl, lf):
    """Each case: a name, the komira.pl frame, and the SQL over `t` that means it."""
    col = kpl.col
    return [
        ("sorted", lf.sort("id"), "SELECT * FROM t ORDER BY id"),
        ("sorted_down", lf.sort("id", descending=True), "SELECT * FROM t ORDER BY id DESC"),
        (
            "filtered_computed",
            lf.filter(col("id") > 2).with_columns((col("n") * 2).alias("m")).sort("id"),
            "SELECT *, n * 2 AS m FROM t WHERE id > 2 ORDER BY id",
        ),
        ("head_of_sort", lf.sort("id", descending=True).head(3), "SELECT * FROM t ORDER BY id DESC LIMIT 3"),
        ("no_rows", lf.head(0), "SELECT * FROM t LIMIT 0"),
    ]


def test_sink_csv_equals_duckdbs_copy(cases, kpl, s, con, path, work):
    lf = kpl.scan_parquet(path, session=s)
    for name, frame, sql in programs(kpl, lf):
        out = os.path.join(work, f"komira_{name}.csv")
        frame.sink_csv(out)
        cases.equal(f"sink_csv {name}", read(out), duckdb_copy(con, work, name, sql))


def test_a_compressed_sink_csv_holds_duckdbs_bytes(cases, kpl, s, con, path, work):
    import pyarrow as pa

    want = duckdb_copy(con, work, "compressed", "SELECT * FROM t ORDER BY id")
    for codec in ("gzip", "zstd"):
        out = os.path.join(work, f"komira.{codec}.csv")
        kpl.scan_parquet(path, session=s).sort("id").sink_csv(out, compression=codec)
        with pa.input_stream(out, compression=codec) as stream:
            cases.equal(f"sink_csv compression={codec}", stream.read(), want)


def test_to_csv_equals_duckdbs_copy(cases, kpl, s, con, path, work):
    want = duckdb_copy(con, work, "pandas", "SELECT * FROM t ORDER BY id")
    out = os.path.join(work, "komira_pandas.csv")
    komira.read_parquet(path, session=s).sort_values("id").to_csv(out, sep=",", header=True, index=False)
    cases.equal("to_csv", read(out), want)


TESTS = [
    test_sink_csv_equals_duckdbs_copy,
    test_a_compressed_sink_csv_holds_duckdbs_bytes,
    test_to_csv_equals_duckdbs_copy,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    import duckdb

    import komira.pl as kpl

    cases = Cases()
    with tempfile.TemporaryDirectory() as work:
        path = write_data(os.path.join(work, "t.parquet"))
        con = duckdb.connect()
        con.execute(f"CREATE VIEW t AS SELECT * FROM read_parquet('{path}')")
        with komira.Session() as s:
            for test in TESTS:
                test(cases, kpl, s, con, path, work)
        con.close()
    if cases.failures:
        raise AssertionError("{} of {} files differ from DuckDB's:\n{}".format(
            len(cases.failures), cases.count, "\n".join(cases.failures)))
    print("pl sink duckdb: {} files equal DuckDB's COPY over libkomira {}".format(cases.count, komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
