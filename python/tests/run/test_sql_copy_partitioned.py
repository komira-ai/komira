"""`Session.sql("COPY (...) TO '<dir>' (FORMAT parquet, PARTITION_BY (...))")` on
the real libkomira: the statement writes a Hive-partitioned directory tree, and
pyarrow and komira read it back:

- test_partition_by_writes_one_directory_per_value_pair: PARTITION_BY (year,
  month) answers the rows written and makes `year=<y>/month=<m>/data_0.parquet`
  for each pair; each file holds the other columns only; pyarrow's dataset
  reader with Hive partitioning and komira's `register_parquet` over a glob
  both read back the rows of the query;
- test_escaped_and_null_values_read_back_with_pyarrow: a value with `/`, one
  with a space and a NULL name the directories `k=a%2Fb`, `k=sp%20ace` and
  `k=__HIVE_DEFAULT_PARTITION__`, and pyarrow reads each back as its value and
  NULL;
- test_refusals_name_their_code_and_step: a target directory holding a file
  is UnsupportedOperation COPY_TARGET_EXISTS at bind, and leaves the file
  alone; a PARTITION_BY column the query does not have is BindError
  SQL_BIND_ERROR at bind; an option DuckDB has and komira does not
  (OVERWRITE_OR_IGNORE) is UnsupportedOperation SQL_NOT_SUPPORTED at parse.

    test_sql_copy_partitioned.py --lib-dir <dir holding libkomira>
"""

import os
import sys
import tempfile

import pyarrow as pa
import pyarrow.dataset as ds
import pyarrow.parquet as pq

import komira
from komira import BindError, UnsupportedOperation
from komira import _native

ROWS = [
    {"id": 1, "amount": 120, "year": 2027, "month": 1},
    {"id": 2, "amount": 40, "year": 2027, "month": 2},
    {"id": 3, "amount": 75, "year": 2028, "month": 1},
    {"id": 4, "amount": 200, "year": 2027, "month": 1},
    {"id": 5, "amount": 10, "year": 2028, "month": 1},
]


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def tree(root):
    """Every file under `root`, relative to it, sorted."""
    out = []
    for here, _, files in os.walk(root):
        for f in files:
            out.append(os.path.relpath(os.path.join(here, f), root))
    return sorted(out)


def session_with_sales(work):
    path = os.path.join(work, "sales.parquet")
    pq.write_table(pa.Table.from_pylist(ROWS), path)
    s = komira.Session()
    s.register_parquet("sales", path)
    return s


def test_partition_by_writes_one_directory_per_value_pair(lib_dir):
    with tempfile.TemporaryDirectory() as work:
        out = os.path.join(work, "out")
        with session_with_sales(work) as s:
            written = s.sql(
                f"COPY (SELECT id, amount, year, month FROM sales) TO '{out}'"
                " (FORMAT parquet, PARTITION_BY (year, month))"
            ).to_arrow()
            assert written.column(0).to_pylist() == [5], written
            assert tree(out) == [
                "year=2027/month=1/data_0.parquet",
                "year=2027/month=2/data_0.parquet",
                "year=2028/month=1/data_0.parquet",
            ], tree(out)
            one = pq.read_table(os.path.join(out, "year=2027", "month=1", "data_0.parquet"), partitioning=None)
            assert one.schema.names == ["id", "amount"], one.schema
            assert one.to_pylist() == [{"id": 1, "amount": 120}, {"id": 4, "amount": 200}], one

            back = ds.dataset(out, format="parquet", partitioning="hive").to_table()
            got = sorted(back.to_pylist(), key=lambda r: r["id"])
            assert got == ROWS, got

            s.register_parquet("back", os.path.join(out, "**", "*.parquet"))
            mine = s.sql("SELECT id, amount, year, month FROM back ORDER BY id").to_arrow().to_pylist()
            assert mine == ROWS, mine


def test_escaped_and_null_values_read_back_with_pyarrow(lib_dir):
    with tempfile.TemporaryDirectory() as work:
        out = os.path.join(work, "out")
        keys = os.path.join(work, "keys.parquet")
        pq.write_table(
            pa.table({"id": [1, 2, 3, 4, 5], "k": pa.array(["a/b", "sp ace", None, "a/b", "a/b"], pa.string())}), keys
        )
        with session_with_sales(work) as s:
            s.register_parquet("keys", keys)
            s.sql(f"COPY (SELECT id, k FROM keys) TO '{out}' (FORMAT parquet, PARTITION_BY (k))").to_arrow()
        assert tree(out) == [
            "k=__HIVE_DEFAULT_PARTITION__/data_0.parquet",
            "k=a%2Fb/data_0.parquet",
            "k=sp%20ace/data_0.parquet",
        ], tree(out)
        part = ds.partitioning(pa.schema([("k", pa.string())]), flavor="hive", segment_encoding="uri")
        back = ds.dataset(out, format="parquet", partitioning=part).to_table()
        got = sorted(back.to_pylist(), key=lambda r: r["id"])
        assert got == [
            {"id": 1, "k": "a/b"},
            {"id": 2, "k": "sp ace"},
            {"id": 3, "k": None},
            {"id": 4, "k": "a/b"},
            {"id": 5, "k": "a/b"},
        ], got


def test_refusals_name_their_code_and_step(lib_dir):
    with tempfile.TemporaryDirectory() as work:
        full = os.path.join(work, "full")
        os.mkdir(full)
        with open(os.path.join(full, "old.txt"), "w") as f:
            f.write("old")
        with session_with_sales(work) as s:
            e = raised(
                lambda: s.sql(
                    f"COPY (SELECT id, year FROM sales) TO '{full}' (FORMAT parquet, PARTITION_BY (year))"
                ).to_arrow()
            )
            assert type(e) is UnsupportedOperation, repr(e)
            assert (e.code, e.step) == ("COPY_TARGET_EXISTS", "bind"), (e.code, e.step)
            assert os.listdir(full) == ["old.txt"], os.listdir(full)

            out = os.path.join(work, "out")
            e = raised(
                lambda: s.sql(
                    f"COPY (SELECT id, year FROM sales) TO '{out}' (FORMAT parquet, PARTITION_BY (day))"
                ).to_arrow()
            )
            assert type(e) is BindError, repr(e)
            assert (e.code, e.step) == ("SQL_BIND_ERROR", "bind"), (e.code, e.step)

            e = raised(
                lambda: s.sql(
                    f"COPY (SELECT id, year FROM sales) TO '{out}'"
                    " (FORMAT parquet, PARTITION_BY (year), OVERWRITE_OR_IGNORE)"
                ).to_arrow()
            )
            assert type(e) is UnsupportedOperation, repr(e)
            assert (e.code, e.step) == ("SQL_NOT_SUPPORTED", "parse"), (e.code, e.step)
            assert not os.path.exists(out)


TESTS = [
    test_partition_by_writes_one_directory_per_value_pair,
    test_escaped_and_null_values_read_back_with_pyarrow,
    test_refusals_name_their_code_and_step,
]


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    for test in TESTS:
        test(lib_dir)
        print("ok", test.__name__)
    print("sql copy partitioned: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
