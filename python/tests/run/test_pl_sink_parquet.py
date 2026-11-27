"""`komira.pl`'s `LazyFrame.sink_parquet` on the real libkomira: it runs the
frame's plan through komira_plan_stream with a write target, as
`DataFrame.to_parquet` does, and every file is read back with pyarrow and
compared with the rows worked out by hand and with `collect()`:

- test_a_filtered_plan_writes_exactly_its_rows: the rows of a filter, with the
  source's column names and types;
- test_a_sorted_plan_writes_its_rows_in_its_order: a sort, a filter and a
  projection over it and a head of it write their rows in the frame's order;
- test_the_file_reads_back_equal_to_collect: the file equals `collect()` of the
  same frame, columns, types and rows in order;
- test_a_csv_scan_writes_one_parquet_file: `scan_csv(...).sink_parquet(...)`,
  the call of the common task, writes the CSV's rows to one Parquet file;
- test_the_default_codec_is_zstd_and_each_codec_is_written: the default is
  ZSTD, as polars' is; "snappy", "gzip", "lz4" (LZ4_RAW, pyarrow's "LZ4") and
  "uncompressed" are written with the same rows;
- test_head_zero_writes_the_schema_and_no_rows;
- test_a_relative_path_is_resolved_at_the_call;
- test_an_existing_file_is_replaced_whole_or_not_at_all: a second write
  replaces the first; a frame writes over the very file it reads; a write the
  engine refuses leaves the existing file's bytes as they were and makes no new
  file; no temporary file is left beside the destination;
- test_a_url_and_a_missing_directory_raise_what_to_parquet_raises: the same
  type, code, step and message as `DataFrame.to_parquet` for the same
  destination (`STORAGE_URL_REFUSED` at bind, `STORAGE_NOT_FOUND` at execute),
  no directory made, and the session writing again after each;
- test_argument_refusals_name_what_they_refuse: every keyword of polars'
  sink_parquet komira does not take is refused by its name, an unknown keyword
  is a TypeError naming it, brotli and a non-str compression are refused, a
  None or non-path destination is a TypeError, a file object is refused; each
  by exact type and message, with the directory listing unchanged;
- test_a_closed_session_refuses_the_write: KomiraError "the session is closed"
  and no file;
- test_sink_parquet_returns_none: polars' sink_parquet returns None unless
  `lazy=True`, which komira refuses.

The test is of the `run/` family (python/tests/BUCK): `pl_sink_parquet_test`
runs on the real libkomira on each supported minor, with the generated plan
modules, protobuf 7.36.2 and pyarrow.

    test_pl_sink_parquet.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which
the rule passes, is not read).
"""

import contextlib
import io
import os
import shutil
import sys
import tempfile
import types

import pyarrow as pa
import pyarrow.parquet as pq

import komira
import komira.pl as kpl
from komira import KomiraError, StorageError, UnsupportedOperation
from komira import _native

CLOSED = "the session is closed"

IDS = [1, 2, 3, 4, 5, 6]
N = [10, None, -5, 7, None, 0]
X = [1.5, -2.5, 0.0, None, 4.25, -0.5]
S = ["b", "a", None, "c", "a", ""]
FLAG = [True, False, None, True, False, True]
COLUMNS = ["id", "n", "x", "s", "flag"]
ROWS = [{"id": i, "n": n, "x": x, "s": s, "flag": f} for i, n, x, s, f in zip(IDS, N, X, S, FLAG)]
SCHEMA = pa.schema(
    [
        ("id", pa.int64()),
        ("n", pa.int64()),
        ("x", pa.float64()),
        ("s", pa.string()),
        ("flag", pa.bool_()),
    ]
)
SOURCE_KINDS = {"id": "int64", "n": "int64", "x": "double", "s": "string", "flag": "bool"}

# The keywords of polars 1.44.2's LazyFrame.sink_parquet other than `path` and
# `compression` (python/tests/pl_oracle/test_pl_oracle_sink.py holds this list
# equal to polars' own signature), each with a value a caller might pass.
POLARS_OPTIONS = {
    "compression_level": 3,
    "statistics": False,
    "row_group_size": 2,
    "data_page_size": 1024,
    "maintain_order": False,
    "storage_options": {"region": "x"},
    "credential_provider": None,
    "retries": 1,
    "sync_on_close": "data",
    "metadata": {"k": "v"},
    "arrow_schema": None,
    "mkdir": True,
    "lazy": True,
    "engine": "streaming",
    "optimizations": None,
    "sinked_paths_callback": None,
}
TAKES = "komira.pl's sink_parquet takes a path and compression= only"


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    """`call` raises exactly `cls` with exactly `message`; the error."""
    e = raised(call)
    assert type(e) is cls and str(e) == message, repr(e)
    return e


def rows_for(wanted):
    return [ROWS[i - 1] for i in wanted]


def by_id(rows):
    return sorted(rows, key=lambda r: r["id"])


def kinds(table):
    """The column types of `table` by name, a text type as "string"."""
    out = {}
    for f in table.schema:
        text = pa.types.is_string(f.type) or pa.types.is_large_string(f.type) or pa.types.is_string_view(f.type)
        out[f.name] = "string" if text else str(f.type)
    return out


def codec_of(path):
    return pq.ParquetFile(path).metadata.row_group(0).column(0).compression


def all_bytes(path):
    with open(path, "rb") as f:
        return f.read()


@contextlib.contextmanager
def workspace():
    """A session, the source Parquet file and an empty `out` directory, in a
    directory removed afterwards."""
    with tempfile.TemporaryDirectory() as work:
        table = pa.Table.from_pydict({"id": IDS, "n": N, "x": X, "s": S, "flag": FLAG}, schema=SCHEMA)
        parquet = os.path.join(work, "rows.parquet")
        pq.write_table(table, parquet, row_group_size=2)
        out = os.path.join(work, "out")
        os.mkdir(out)
        with komira.Session() as s:
            yield s, types.SimpleNamespace(work=work, parquet=parquet, out=out, join=lambda n: os.path.join(out, n))


def frame(s, p):
    return kpl.scan_parquet(p.parquet, session=s)


def good_write(s, p, name="good.parquet"):
    """The session still writes: the whole source frame, read back."""
    path = p.join(name)
    assert frame(s, p).sink_parquet(path) is None
    assert by_id(pq.read_table(path).to_pylist()) == ROWS


# ---- the tests -----------------------------------------------------------------


def test_a_filtered_plan_writes_exactly_its_rows(lib_dir):
    with workspace() as (s, p):
        path = p.join("f.parquet")
        frame(s, p).filter(kpl.col("id") > 2).sink_parquet(path)
        t = pq.read_table(path)
        assert t.schema.names == COLUMNS and kinds(t) == SOURCE_KINDS, (t.schema.names, kinds(t))
        assert by_id(t.to_pylist()) == rows_for([3, 4, 5, 6]), t.to_pylist()
        # A filter no row passes writes the schema and no rows.
        none = p.join("none.parquet")
        frame(s, p).filter(kpl.col("id") > 100).sink_parquet(none)
        t = pq.read_table(none)
        assert t.num_rows == 0 and t.schema.names == COLUMNS, t


def test_a_sorted_plan_writes_its_rows_in_its_order(lib_dir):
    with workspace() as (s, p):
        lf = frame(s, p).sort("id", descending=True)
        path = p.join("sorted.parquet")
        lf.sink_parquet(path)
        assert pq.read_table(path).to_pylist() == list(reversed(ROWS))
        # A filter and a projection after the sort keep its order.
        kept = lf.filter(kpl.col("id") != 4).select("id", (kpl.col("id") * 10).alias("ten"))
        kept.sink_parquet(p.join("kept.parquet"))
        want = [{"id": i, "ten": i * 10} for i in (6, 5, 3, 2, 1)]
        assert pq.read_table(p.join("kept.parquet")).to_pylist() == want
        # A head of the sort is exactly its first rows, in order.
        lf.head(2).sink_parquet(p.join("head.parquet"))
        assert pq.read_table(p.join("head.parquet")).to_pylist() == list(reversed(rows_for([5, 6])))
        # A sort by a string key with its null last.
        frame(s, p).sort("s", nulls_last=True).select("id", "s").sink_parquet(p.join("s.parquet"))
        got = pq.read_table(p.join("s.parquet")).to_pylist()
        assert [r["s"] for r in got] == ["", "a", "a", "b", "c", None], got


def test_the_file_reads_back_equal_to_collect(lib_dir):
    with workspace() as (s, p):
        lf = (
            frame(s, p)
            .filter(kpl.col("n").is_not_null())
            .with_columns((kpl.col("n") - kpl.col("id")).alias("d"))
            .sort("d")
        )
        path = p.join("c.parquet")
        lf.sink_parquet(path)
        written = pq.read_table(path)
        collected = lf.collect().to_arrow()
        assert written.schema.names == collected.schema.names, (written.schema, collected.schema)
        assert kinds(written) == kinds(collected), (kinds(written), kinds(collected))
        assert written.to_pylist() == collected.to_pylist(), (written.to_pylist(), collected.to_pylist())
        # n - id is -8, -6, 3 and 9 for the ids 3, 6, 4 and 1: no ties.
        assert [(r["id"], r["d"]) for r in written.to_pylist()] == [(3, -8), (6, -6), (4, 3), (1, 9)], written


def test_a_csv_scan_writes_one_parquet_file(lib_dir):
    with workspace() as (s, p):
        csv = os.path.join(p.work, "orders.csv")
        with open(csv, "w", encoding="utf-8") as f:
            f.write("order_id,customer,amount\n1,Ana,120\n2,Bo,40\n3,Ana,75\n")
        dest = p.join("orders.parquet")
        assert kpl.scan_csv(csv, session=s).sink_parquet(dest) is None
        assert os.listdir(p.out) == ["orders.parquet"]
        got = sorted(pq.read_table(dest).to_pylist(), key=lambda r: r["order_id"])
        assert got == [
            {"order_id": 1, "customer": "Ana", "amount": 120},
            {"order_id": 2, "customer": "Bo", "amount": 40},
            {"order_id": 3, "customer": "Ana", "amount": 75},
        ], got


def test_the_default_codec_is_zstd_and_each_codec_is_written(lib_dir):
    with workspace() as (s, p):
        default = p.join("default.parquet")
        frame(s, p).sink_parquet(default)
        assert codec_of(default) == "ZSTD", codec_of(default)
        assert by_id(pq.read_table(default).to_pylist()) == ROWS
        for compression, want in (
            ("zstd", "ZSTD"),
            ("snappy", "SNAPPY"),
            ("gzip", "GZIP"),
            ("lz4", "LZ4"),
            ("uncompressed", "UNCOMPRESSED"),
        ):
            path = p.join(f"{compression}.parquet")
            frame(s, p).sink_parquet(path, compression=compression)
            assert codec_of(path) == want, (compression, codec_of(path))
            assert by_id(pq.read_table(path).to_pylist()) == ROWS, compression


def test_head_zero_writes_the_schema_and_no_rows(lib_dir):
    with workspace() as (s, p):
        frame(s, p).head(0).sink_parquet(p.join("z.parquet"))
        t = pq.read_table(p.join("z.parquet"))
        assert t.num_rows == 0 and t.schema.names == COLUMNS and kinds(t) == SOURCE_KINDS, t


def test_a_relative_path_is_resolved_at_the_call(lib_dir):
    with workspace() as (s, p):
        lf = frame(s, p)
        cwd = os.getcwd()
        try:
            os.chdir(p.out)
            lf.sink_parquet("rel.parquet")
        finally:
            os.chdir(cwd)
        assert os.listdir(p.out) == ["rel.parquet"], os.listdir(p.out)
        assert by_id(pq.read_table(p.join("rel.parquet")).to_pylist()) == ROWS


def test_an_existing_file_is_replaced_whole_or_not_at_all(lib_dir):
    with workspace() as (s, p):
        lf = frame(s, p)
        path = p.join("o.parquet")
        lf.sink_parquet(path)
        lf.filter(kpl.col("id") > 4).sink_parquet(path)
        assert by_id(pq.read_table(path).to_pylist()) == rows_for([5, 6])
        # The frame reads the very file it writes over.
        mine = p.join("mine.parquet")
        shutil.copyfile(p.parquet, mine)
        kpl.scan_parquet(mine, session=s).filter(kpl.col("id") > 3).sink_parquet(mine)
        assert by_id(pq.read_table(mine).to_pylist()) == rows_for([4, 5, 6])
        # A write the engine refuses (a binary column) leaves an existing file
        # as it was and makes no new one.
        raw = os.path.join(p.work, "raw.parquet")
        pq.write_table(pa.table({"t": pa.array([b"\xff", b"ok"], pa.binary())}), raw)
        blobs = kpl.scan_parquet(raw, session=s)
        kept = all_bytes(path)
        e = raised(lambda: blobs.sink_parquet(path))
        assert type(e) is UnsupportedOperation and e.code == "COPY_TYPE_UNSUPPORTED", repr(e)
        assert all_bytes(path) == kept
        e = raised(lambda: blobs.sink_parquet(p.join("new.parquet")))
        assert type(e) is UnsupportedOperation and e.code == "COPY_TYPE_UNSUPPORTED", repr(e)
        # No temporary file is left beside a destination.
        assert sorted(os.listdir(p.out)) == ["mine.parquet", "o.parquet"], os.listdir(p.out)
        good_write(s, p)


def test_a_url_and_a_missing_directory_raise_what_to_parquet_raises(lib_dir):
    with workspace() as (s, p):
        lf = frame(s, p)
        df = komira.read_parquet(p.parquet, session=s)
        missing = os.path.join(p.work, "no_such_directory", "o.parquet")
        for dest, cls, code, step in (
            ("s3://bucket/o.parquet", UnsupportedOperation, "STORAGE_URL_REFUSED", "bind"),
            (missing, StorageError, "STORAGE_NOT_FOUND", "execute"),
        ):
            mine = raised(lambda: lf.sink_parquet(dest))
            theirs = raised(lambda: df.to_parquet(dest))
            assert type(mine) is cls and (mine.code, mine.step) == (code, step), repr(mine)
            assert (type(mine), mine.code, mine.step, str(mine)) == (type(theirs), theirs.code, theirs.step, str(theirs)), (
                repr(mine),
                repr(theirs),
            )
            good_write(s, p, f"after_{code.lower()}.parquet")
        assert not os.path.exists(os.path.dirname(missing))
        # Another scheme is refused alike.
        e = raised(lambda: lf.sink_parquet("gs://bucket/o.parquet"))
        assert type(e) is UnsupportedOperation and e.code == "STORAGE_URL_REFUSED", repr(e)


def test_argument_refusals_name_what_they_refuse(lib_dir):
    with workspace() as (s, p):
        lf = frame(s, p)
        dest = p.join("o.parquet")
        before = sorted(os.listdir(p.out))
        cases = [
            (
                lambda name=name, value=value: lf.sink_parquet(dest, **{name: value}),
                UnsupportedOperation,
                f"sink_parquet: {name}= is not supported; {TAKES}",
            )
            for name, value in POLARS_OPTIONS.items()
        ]
        cases += [
            (
                lambda: lf.sink_parquet(dest, row_group_size=2, statistics=False),
                UnsupportedOperation,
                f"sink_parquet: row_group_size= and statistics= are not supported; {TAKES}",
            ),
            (
                lambda: lf.sink_parquet(dest, mkdir=True, lazy=True, engine="streaming"),
                UnsupportedOperation,
                f"sink_parquet: mkdir=, lazy= and engine= are not supported; {TAKES}",
            ),
            # A polars default is refused too: komira takes no value of the option.
            (
                lambda: lf.sink_parquet(dest, maintain_order=True),
                UnsupportedOperation,
                f"sink_parquet: maintain_order= is not supported; {TAKES}",
            ),
            (
                lambda: lf.sink_parquet(dest, sep=";"),
                TypeError,
                "sink_parquet() got an unexpected keyword argument 'sep'",
            ),
            # A name polars does not have is a TypeError before any refusal.
            (
                lambda: lf.sink_parquet(dest, statistics=False, index=False),
                TypeError,
                "sink_parquet() got an unexpected keyword argument 'index'",
            ),
            (
                lambda: lf.sink_parquet(dest, compression="brotli"),
                UnsupportedOperation,
                "sink_parquet(compression='brotli') is not a codec komira writes: "
                "use 'snappy', 'gzip', 'zstd', 'lz4' or 'uncompressed'",
            ),
            (
                lambda: lf.sink_parquet(dest, compression="lzo"),
                UnsupportedOperation,
                "sink_parquet(compression='lzo') is not a codec komira writes: "
                "use 'snappy', 'gzip', 'zstd', 'lz4' or 'uncompressed'",
            ),
            (
                lambda: lf.sink_parquet(dest, compression=None),
                TypeError,
                "sink_parquet compression must be a str, not NoneType",
            ),
            (
                lambda: lf.sink_parquet(dest, compression=1),
                TypeError,
                "sink_parquet compression must be a str, not int",
            ),
            (lambda: lf.sink_parquet(None), TypeError, "path must be a str or os.PathLike[str], not NoneType"),
            (lambda: lf.sink_parquet(3), TypeError, "path must be a str or os.PathLike[str], not int"),
            (
                lambda: lf.sink_parquet(io.BytesIO()),
                UnsupportedOperation,
                "sink_parquet: writing to a file object is not supported; pass a file path",
            ),
        ]
        for call, cls, message in cases:
            refused(call, cls, message)
            assert sorted(os.listdir(p.out)) == before, message
        good_write(s, p)


def test_a_closed_session_refuses_the_write(lib_dir):
    with tempfile.TemporaryDirectory() as work:
        src = os.path.join(work, "ids.parquet")
        pq.write_table(pa.Table.from_pydict({"id": IDS}, schema=pa.schema([("id", pa.int64())])), src)
        s = komira.Session()
        lf = kpl.scan_parquet(src, session=s)
        s.close()
        out = os.path.join(work, "o.parquet")
        e = refused(lambda: lf.sink_parquet(out), KomiraError, CLOSED)
        assert e.status is None, repr(e)
        assert not os.path.exists(out)


def test_sink_parquet_returns_none(lib_dir):
    with workspace() as (s, p):
        assert frame(s, p).sink_parquet(p.join("a.parquet")) is None
        assert frame(s, p).sink_parquet(p.join("b.parquet"), compression="gzip") is None


TESTS = [
    test_a_filtered_plan_writes_exactly_its_rows,
    test_a_sorted_plan_writes_its_rows_in_its_order,
    test_the_file_reads_back_equal_to_collect,
    test_a_csv_scan_writes_one_parquet_file,
    test_the_default_codec_is_zstd_and_each_codec_is_written,
    test_head_zero_writes_the_schema_and_no_rows,
    test_a_relative_path_is_resolved_at_the_call,
    test_an_existing_file_is_replaced_whole_or_not_at_all,
    test_a_url_and_a_missing_directory_raise_what_to_parquet_raises,
    test_argument_refusals_name_what_they_refuse,
    test_a_closed_session_refuses_the_write,
    test_sink_parquet_returns_none,
]


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1008, komira.abi_version()
    for test in TESTS:
        test(lib_dir)
        print("ok", test.__name__)
    print("pl sink_parquet: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
