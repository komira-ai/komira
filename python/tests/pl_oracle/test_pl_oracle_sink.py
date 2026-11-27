"""komira.pl's `LazyFrame.sink_parquet` against polars' own, on the real
libkomira and the pinned polars:

- test_the_keywords_are_polars_own: every keyword of polars'
  `LazyFrame.sink_parquet` is either one komira takes (`path`, `compression`)
  or one it refuses by name (`komira.pl._frame.SINK_PARQUET_REFUSED`), and
  komira refuses no name polars lacks;
- test_the_codecs_and_the_default_are_polars_own: polars' default compression
  is komira's, and each codec polars names is one komira writes or one it
  refuses by name (brotli);
- test_each_program_writes_the_file_polars_writes: for each program, run
  through komira.pl and through polars, the file `sink_parquet` writes reads
  back with the same columns, the same types and the same rows (in order when
  the frame is sorted, as a multiset when it is not), and both calls return
  None.

    test_pl_oracle_sink.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import argparse
import inspect
import os
import sys
import tempfile
import typing

import polars as pl
import pyarrow as pa
import pyarrow.parquet as pq

import komira.pl as kpl
from komira import Session, UnsupportedOperation
from komira import _native
from komira.pl._frame import SINK_PARQUET_REFUSED

assert pl.__version__ == "1.44.2", pl.__version__


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def kinds(table):
    """The column types of `table` by name, every text type as "string"."""
    out = {}
    for f in table.schema:
        text = pa.types.is_string(f.type) or pa.types.is_large_string(f.type) or pa.types.is_string_view(f.type)
        out[f.name] = "string" if text else str(f.type)
    return out


def test_the_keywords_are_polars_own():
    theirs = inspect.signature(pl.LazyFrame.sink_parquet).parameters
    named = [n for n in theirs if n != "self"]
    assert named[:2] == ["path", "compression"], named
    assert set(named[2:]) == set(SINK_PARQUET_REFUSED), (
        sorted(set(named[2:]) - set(SINK_PARQUET_REFUSED)),
        sorted(set(SINK_PARQUET_REFUSED) - set(named[2:])),
    )
    assert len(SINK_PARQUET_REFUSED) == len(set(SINK_PARQUET_REFUSED)), SINK_PARQUET_REFUSED
    mine = inspect.signature(kpl.LazyFrame.sink_parquet).parameters
    assert list(mine)[:3] == ["self", "path", "compression"], list(mine)
    assert mine["compression"].kind is inspect.Parameter.KEYWORD_ONLY
    assert theirs["compression"].kind is inspect.Parameter.KEYWORD_ONLY


def test_the_codecs_and_the_default_are_polars_own(session, work):
    theirs = inspect.signature(pl.LazyFrame.sink_parquet).parameters["compression"]
    mine = inspect.signature(kpl.LazyFrame.sink_parquet).parameters["compression"]
    assert mine.default == theirs.default == "zstd", (mine.default, theirs.default)
    from polars._typing import ParquetCompression

    codecs = typing.get_args(ParquetCompression)
    assert sorted(codecs) == ["brotli", "gzip", "lz4", "snappy", "uncompressed", "zstd"], codecs
    path = os.path.join(work, "t.parquet")
    lf = kpl.scan_parquet(path, session=session)
    for codec in codecs:
        dest = os.path.join(work, f"codec_{codec}.parquet")
        if codec == "brotli":
            e = raised(lambda: lf.sink_parquet(dest, compression=codec))
            assert type(e) is UnsupportedOperation, repr(e)
            assert not os.path.exists(dest)
            continue
        assert lf.sink_parquet(dest, compression=codec) is None
        assert pl.scan_parquet(path).sink_parquet(dest + ".polars", compression=codec) is None
        a = pq.ParquetFile(dest).metadata.row_group(0).column(0).compression
        b = pq.ParquetFile(dest + ".polars").metadata.row_group(0).column(0).compression
        assert a == b, (codec, a, b)


def programs(P, lf):
    """Each case: a name, the frame, and whether it is ordered."""
    return [
        ("all", lf, False),
        ("filter", lf.filter(P.col("x") > 0), False),
        ("filter_sort", lf.filter(P.col("y").is_not_null()).sort("id", descending=True), True),
        (
            "with_columns_sort",
            lf.with_columns((P.col("id") * 2).alias("twice")).sort("twice").select("id", "twice", "s"),
            True,
        ),
        ("sort_head", lf.sort("id").head(3), True),
        ("empty", lf.filter(P.col("id") > 100), False),
    ]


def test_each_program_writes_the_file_polars_writes(session, work):
    path = os.path.join(work, "t.parquet")
    mine = programs(kpl, kpl.scan_parquet(path, session=session))
    theirs = programs(pl, pl.scan_parquet(path))
    for (name, k, ordered), (_, p, _) in zip(mine, theirs):
        a_path = os.path.join(work, f"{name}.komira.parquet")
        b_path = os.path.join(work, f"{name}.polars.parquet")
        assert k.sink_parquet(a_path) is None, name
        assert p.sink_parquet(b_path) is None, name
        a, b = pq.read_table(a_path), pq.read_table(b_path)
        assert a.schema.names == b.schema.names, (name, a.schema, b.schema)
        assert kinds(a) == kinds(b), (name, kinds(a), kinds(b))
        rows_a, rows_b = a.to_pylist(), b.to_pylist()
        if not ordered:
            rows_a, rows_b = sorted(rows_a, key=lambda r: r["id"]), sorted(rows_b, key=lambda r: r["id"])
        assert rows_a == rows_b, (name, rows_a, rows_b)
    # A CSV scan, the common task's call.
    csv = os.path.join(work, "orders.csv")
    with open(csv, "w", encoding="utf-8") as f:
        f.write("order_id,customer,amount\n1,Ana,120\n2,Bo,40\n3,Ana,75\n")
    kpl.scan_csv(csv, session=session).sink_parquet(os.path.join(work, "orders.komira.parquet"))
    pl.scan_csv(csv).sink_parquet(os.path.join(work, "orders.polars.parquet"))
    a = pq.read_table(os.path.join(work, "orders.komira.parquet"))
    b = pq.read_table(os.path.join(work, "orders.polars.parquet"))
    assert kinds(a) == kinds(b), (kinds(a), kinds(b))
    key = lambda r: r["order_id"]  # noqa: E731
    assert sorted(a.to_pylist(), key=key) == sorted(b.to_pylist(), key=key)


def table():
    return pa.table(
        {
            "id": pa.array([1, 2, 3, 4, 5, 6], pa.int64()),
            "x": pa.array([5, -3, None, 7, 0, 2], pa.int64()),
            "y": pa.array([1.5, None, -2.25, 4.0, 0.5, None], pa.float64()),
            "s": pa.array(["a", None, "b", "", "c", "a"], pa.string()),
            "flag": pa.array([True, False, None, True, True, False], pa.bool_()),
        }
    )


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args(argv)
    _native.load(os.path.join(os.path.abspath(args.lib_dir), "libkomira"))
    test_the_keywords_are_polars_own()
    print("ok test_the_keywords_are_polars_own")
    with tempfile.TemporaryDirectory() as work:
        pq.write_table(table(), os.path.join(work, "t.parquet"))
        with Session() as session:
            test_the_codecs_and_the_default_are_polars_own(session, work)
            print("ok test_the_codecs_and_the_default_are_polars_own")
            test_each_program_writes_the_file_polars_writes(session, work)
            print("ok test_each_program_writes_the_file_polars_writes")
    print("pl_oracle sink_parquet: the cases passed")


if __name__ == "__main__":
    main(sys.argv[1:])
