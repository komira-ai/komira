"""`iceberg_scan` through Session.sql on the real libkomira, against the
answers of the pinned DuckDB's Iceberg extension over the same table.

The table is `orders` of src/tests/conformance/komira_iceberg_scan_conformance
(six snapshots: two appends, a position delete, an equality delete, an append
that reinserts a deleted key, an overwrite; partitioned by `region`; its
manifests record file:///warehouse/db/orders, which is not where it is staged,
hence `allow_moved_paths = true`). That package's `:answers` ran each line of
its oracle/cases.sql in DuckDB and wrote `<case>.tsv`.

- every case of cases.sql, run through Session.sql with 'orders' replaced by
  the staged table's path, gives DuckDB's column names and rows, in DuckDB's
  order, each value compared by value as komira's Arrow type reads the TSV
  text (an empty field is NULL: no case's answer holds an empty string);
- the current metadata file names the table as its directory does, and an
  older snapshot through it reads that snapshot's rows;
- each refusal is the class, code, step and message below, and the session
  answers the next query after it: an unknown snapshot, a directory with no
  metadata/version-hint.text, a path that does not exist, a location with a
  scheme other than file:, a file: URI with a host, the moved table read
  without allow_moved_paths, and a snapshot id that is not an integer.

    test_iceberg_scan.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`, `<dir>/orders/` the
table, `<dir>/cases.sql` the cases and `<dir>/<case>.tsv` DuckDB's answers.
"""

import csv
import datetime
import decimal
import io
import math
import os
import sys

import pyarrow as pa

import komira
from komira import _native

# The number of COPY lines of cases.sql; BUCK stages one answer for each.
CASES = 19


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def cases(lib_dir):
    """(name, query) of every `COPY (<query>) TO '<name>.tsv' ...;` line."""
    out = []
    with open(os.path.join(lib_dir, "cases.sql"), encoding="utf-8") as f:
        for line in f:
            if not line.startswith("COPY ("):
                continue
            to = line.rindex(") TO '")
            out.append((line[to + len(") TO '") : line.rindex(".tsv'")], line[len("COPY (") : to]))
    return out


def typed(text, kind):
    """The value DuckDB's CSV text `text` spells, read as Arrow type `kind`."""
    if text == "":
        return None
    if pa.types.is_boolean(kind):
        assert text in ("true", "false"), text
        return text == "true"
    if pa.types.is_integer(kind):
        return int(text)
    if pa.types.is_floating(kind):
        return float(text)
    if pa.types.is_decimal(kind):
        return decimal.Decimal(text)
    if pa.types.is_date(kind):
        return datetime.date.fromisoformat(text)
    assert pa.types.is_string(kind) or pa.types.is_large_string(kind), kind
    return text


def same(a, b):
    """Equal values, a NaN equal to a NaN."""
    if isinstance(a, float) and isinstance(b, float) and math.isnan(a) and math.isnan(b):
        return True
    return type(a) is type(b) and a == b


def duckdb_rows(path, schema):
    with open(path, encoding="utf-8", newline="") as f:
        rows = list(csv.reader(io.StringIO(f.read()), delimiter="\t"))
    header, body = rows[0], rows[1:]
    return header, [tuple(typed(v, schema.field(i).type) for i, v in enumerate(row)) for row in body]


def check_case(s, lib_dir, name, query):
    table = s.sql(query.replace("iceberg_scan('orders'", "iceberg_scan('{}'".format(os.path.join(lib_dir, "orders"))))
    got = table.to_arrow()
    header, want = duckdb_rows(os.path.join(lib_dir, name + ".tsv"), got.schema)
    assert got.column_names == header, (name, got.column_names, header)
    rows = [tuple(r[c] for c in header) for r in got.to_pylist()]
    assert len(rows) == len(want), (name, rows, want)
    for g, w in zip(rows, want):
        assert all(same(a, b) for a, b in zip(g, w)), (name, g, w)


def count(s, sql):
    return s.sql(sql).to_arrow().to_pylist()[0]["n"]


def refused(s, sql, kind, code, step, message):
    e = raised(lambda: s.sql(sql))
    assert type(e) is kind, repr(e)
    assert (e.status, e.code, e.step) == (-3, code, step), (e.status, e.code, e.step)
    assert str(e) == message, str(e)
    assert s.sql("SELECT 1 AS n").to_arrow().to_pylist() == [{"n": 1}]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    orders = os.path.join(lib_dir, "orders")
    metadata = os.path.join(orders, "metadata", "v6.metadata.json")

    with komira.Session() as s:
        every = cases(lib_dir)
        assert len(every) == CASES, [n for n, _ in every]
        for name, query in every:
            assert "iceberg_scan('orders'" in query, name
            check_case(s, lib_dir, name, query)

        # The current metadata file is the table its directory names; through
        # it an older snapshot reads that snapshot's rows.
        scan = "SELECT count(*) AS n FROM iceberg_scan('{}', allow_moved_paths = true{})"
        assert count(s, scan.format(orders, "")) == 10
        assert count(s, scan.format(metadata, "")) == 10
        assert count(s, scan.format(metadata, ", snapshot_from_id = 6000000002")) == 13

        # Each refusal names its code; the session answers after each.
        refused(s, scan.format(orders, ", snapshot_from_id = 42"), komira.BindError,
                "ICEBERG_SNAPSHOT_NOT_FOUND", "bind",
                "bind: ICEBERG_SNAPSHOT_NOT_FOUND: the table has no snapshot 42")
        refused(s, scan.format(lib_dir, ""), komira.BindError, "ICEBERG_TABLE_VERSION_UNKNOWN", "bind",
                "bind: ICEBERG_TABLE_VERSION_UNKNOWN: {} has no metadata/version-hint.text;"
                " name the .metadata.json file".format(lib_dir))
        missing = os.path.join(lib_dir, "no_such_table")
        refused(s, scan.format(missing, ""), komira.BindError, "ICEBERG_METADATA_INVALID", "bind",
                "bind: ICEBERG_METADATA_INVALID: no table at '{}'".format(missing))
        refused(s, scan.format("s3://bucket/orders", ""), komira.BindError, "ICEBERG_PATH_UNSUPPORTED", "bind",
                "bind: ICEBERG_PATH_UNSUPPORTED: 's3://bucket/orders' has the scheme 's3';"
                " only local files (a bare path or a file: URI) are read")
        refused(s, scan.format("file://host/orders", ""), komira.BindError, "ICEBERG_PATH_UNSUPPORTED", "bind",
                "bind: ICEBERG_PATH_UNSUPPORTED: 'file://host/orders' names a host; only local files are read")
        # The manifests record file:///warehouse/db/orders: without
        # allow_moved_paths the manifest list is looked for there.
        refused(s, "SELECT count(*) AS n FROM iceberg_scan('{}')".format(orders), komira.KomiraError,
                "ICEBERG_MANIFEST_INVALID", "lower",
                "lower: ICEBERG_MANIFEST_INVALID: cannot read the manifest list 'file:///warehouse/db/orders/"
                "metadata/snap-6000000006-1-a1b2c3d4-0000-4000-8000-000000000106.avro'")
        bad_id = scan.format(orders, ", snapshot_from_id = 'six'")
        refused(s, bad_id, komira.ParseError, "SQL_SYNTAX_ERROR", "parse",
                "parse: SQL syntax error: iceberg_scan option 'snapshot_from_id' expects an integer snapshot id"
                " at line 1, column {}".format(bad_id.index("'six'") + 1))
    assert s.closed
    print("iceberg_scan: libkomira {} answers DuckDB's rows for {} cases".format(komira.abi_version(), CASES))


if __name__ == "__main__":
    main(sys.argv[1:])
