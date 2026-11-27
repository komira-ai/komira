"""komira.pl's sinks on the real libkomira: `sink_csv`, `sink_parquet` and
`sink_ndjson` run a frame's plan through komira_plan_stream with a write
target, and every file is read back and compared with the rows worked out by
hand, or with the bytes another writer of komira writes for the same rows:

- test_sink_parquet_round_trips_through_the_readers: the default codec is
  zstd, and `scan_parquet`, `read_parquet` and pyarrow read back the source's
  rows, column names and types;
- test_sink_parquet_codecs: snappy, gzip, lz4 and uncompressed write SNAPPY,
  GZIP, LZ4 (pyarrow's name for LZ4_RAW) and UNCOMPRESSED files of the same
  rows;
- test_an_ordered_frame_writes_its_rows_in_order: a filtered, computed frame
  sorted downwards writes exactly its rows in its order to each format, and a
  head of a sort its first rows;
- test_a_frame_of_no_rows_writes_its_columns_only: Parquet with the schema
  and no rows, CSV with only the header line, NDJSON with no bytes;
- test_sink_csv_and_ndjson_rows_and_compression: the header line, NULL kept
  apart from the empty string, gzip and zstd files of the same rows, and a
  `.csv.gz` name written as plain text unless compression says otherwise;
- test_every_writer_of_komira_writes_the_same_csv_bytes: an ordered frame's
  `sink_csv` equals the pandas-shaped frame's `to_csv` of the same rows, with
  and without `sep=","`, `header=True` and `index=False`, and the file
  `COPY (<the same query>) TO` writes through `Session.sql`; `sink_ndjson`
  equals `to_json(orient="records", lines=True)`;
- test_an_existing_file_is_replaced_whole_or_not_at_all: a second write
  replaces the file; a frame writes over the very file it reads; a write the
  engine refuses (a binary column, a missing directory) leaves an existing
  file byte for byte and creates nothing; no temporary file is left;
- test_engine_refusals_name_their_code_and_step: a URL at bind, a missing
  directory at execute, and the session writing again after each;
- test_a_closed_session_refuses_a_write: KomiraError "the session is closed"
  and no file.

The test is of the `run/` family (python/tests/BUCK): `pl_sink_run_test` runs
on the real libkomira on each supported minor (`pl_sink_run_test_py311`, ...),
with the generated plan modules, protobuf 7.36.2 and pyarrow.

    test_pl_sink_run.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which
the rule passes, is not read).
"""

import contextlib
import os
import shutil
import sys
import tempfile
import types

import pyarrow as pa
import pyarrow.csv as pacsv
import pyarrow.json as pajson
import pyarrow.parquet as pq

import komira
import komira.pl as kpl
from komira import KomiraError, StorageError, UnsupportedOperation
from komira import _native

GZIP_MAGIC = b"\x1f\x8b"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
HEADER = b"id,n,x,s,flag\n"

IDS = [1, 2, 3, 4, 5, 6]
N = [10, None, -5, 7, None, 0]
X = [1.5, -2.5, 0.0, None, 4.25, -0.5]
S = ["b", "a", None, "c, d", "say \"hi\"", ""]
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


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


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


def lazy(s, p):
    return kpl.scan_parquet(p.parquet, session=s)


def read_csv_file(path, source=None, schema=SCHEMA):
    options = pacsv.ConvertOptions(
        column_types={f.name: f.type for f in schema}, strings_can_be_null=True, quoted_strings_can_be_null=False
    )
    return pacsv.read_csv(source if source is not None else path, convert_options=options)


def read_json_file(path, source=None, schema=SCHEMA):
    return pajson.read_json(
        source if source is not None else path, parse_options=pajson.ParseOptions(explicit_schema=schema)
    )


def all_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def good_write(s, p, name):
    """The session still writes: the whole source frame, read back."""
    path = p.join(name)
    assert lazy(s, p).sink_parquet(path) is None
    assert by_id(pq.read_table(path).to_pylist()) == ROWS


# ---- the tests -----------------------------------------------------------------


def test_sink_parquet_round_trips_through_the_readers(lib_dir):
    with workspace() as (s, p):
        path = p.join("o.parquet")
        assert lazy(s, p).sink_parquet(path) is None
        assert pq.ParquetFile(path).metadata.row_group(0).column(0).compression == "ZSTD"
        back = kpl.scan_parquet(path, session=s).collect().to_arrow()
        assert back.schema.names == COLUMNS and kinds(back) == SOURCE_KINDS, (back.schema.names, kinds(back))
        assert by_id(back.to_pylist()) == ROWS
        pandas_back = komira.read_parquet(path, session=s).materialize().to_arrow()
        assert by_id(pandas_back.to_pylist()) == ROWS
        assert by_id(pq.read_table(path).to_pylist()) == ROWS


def test_sink_parquet_codecs(lib_dir):
    with workspace() as (s, p):
        for compression, want in (
            ("snappy", "SNAPPY"),
            ("gzip", "GZIP"),
            ("lz4", "LZ4"),
            ("uncompressed", "UNCOMPRESSED"),
            ("zstd", "ZSTD"),
        ):
            path = p.join(f"{compression}.parquet")
            lazy(s, p).sink_parquet(path, compression=compression)
            got = pq.ParquetFile(path).metadata.row_group(0).column(0).compression
            assert got == want, (compression, got)
            assert by_id(pq.read_table(path).to_pylist()) == ROWS, compression


def test_an_ordered_frame_writes_its_rows_in_order(lib_dir):
    with workspace() as (s, p):
        lf = lazy(s, p)
        composed = (
            lf.filter(kpl.col("id") > 1).with_columns((kpl.col("id") * 2).alias("y")).sort("id", descending=True)
        )
        want = [dict(r, y=r["id"] * 2) for r in reversed(rows_for([2, 3, 4, 5, 6]))]
        schema = SCHEMA.append(pa.field("y", pa.int64()))
        composed.sink_parquet(p.join("c.parquet"))
        composed.sink_csv(p.join("c.csv"))
        composed.sink_ndjson(p.join("c.jsonl"))
        t = pq.read_table(p.join("c.parquet"))
        assert t.schema.names == COLUMNS + ["y"] and t.to_pylist() == want, t.to_pylist()
        assert read_csv_file(p.join("c.csv"), schema=schema).to_pylist() == want
        assert read_json_file(p.join("c.jsonl"), schema=schema).to_pylist() == want
        # A head of a sort is exactly its first rows, in order.
        lf.sort("id", descending=True).head(2).sink_csv(p.join("h.csv"))
        assert read_csv_file(p.join("h.csv")).to_pylist() == list(reversed(rows_for([5, 6])))


def test_a_frame_of_no_rows_writes_its_columns_only(lib_dir):
    with workspace() as (s, p):
        empty = lazy(s, p).head(0)
        empty.sink_parquet(p.join("z.parquet"))
        t = pq.read_table(p.join("z.parquet"))
        assert t.num_rows == 0 and t.schema.names == COLUMNS and kinds(t) == SOURCE_KINDS, kinds(t)
        empty.sink_csv(p.join("z.csv"))
        assert all_bytes(p.join("z.csv")) == HEADER
        empty.sink_ndjson(p.join("z.jsonl"))
        assert all_bytes(p.join("z.jsonl")) == b""


def test_sink_csv_and_ndjson_rows_and_compression(lib_dir):
    with workspace() as (s, p):
        lf = lazy(s, p)
        plain = p.join("o.csv")
        lf.sink_csv(plain)
        assert all_bytes(plain).startswith(HEADER)
        got = by_id(read_csv_file(plain).to_pylist())
        assert got == ROWS, got
        # NULL (row 3) and "" (row 6) are two different cells.
        assert got[2]["s"] is None and got[5]["s"] == ""
        for codec, magic in (("gzip", GZIP_MAGIC), ("zstd", ZSTD_MAGIC)):
            path = p.join(f"o.{codec}.csv")
            lf.sink_csv(path, compression=codec)
            assert all_bytes(path)[: len(magic)] == magic, codec
            with pa.input_stream(path, compression=codec) as stream:
                assert by_id(read_csv_file(path, stream).to_pylist()) == ROWS, codec
            jpath = p.join(f"o.{codec}.jsonl")
            lf.sink_ndjson(jpath, compression=codec)
            assert all_bytes(jpath)[: len(magic)] == magic, codec
            with pa.input_stream(jpath, compression=codec) as stream:
                assert by_id(read_json_file(jpath, stream).to_pylist()) == ROWS, codec
        # The name does not choose the codec: a `.csv.gz` is plain text by default.
        named = p.join("n.csv.gz")
        lf.sink_csv(named)
        assert all_bytes(named).startswith(HEADER)
        jplain = p.join("o.jsonl")
        lf.sink_ndjson(jplain)
        text = all_bytes(jplain)
        assert text.endswith(b"\n") and len(text.splitlines()) == 6, text
        assert by_id(read_json_file(jplain).to_pylist()) == ROWS


def test_every_writer_of_komira_writes_the_same_csv_bytes(lib_dir):
    with workspace() as (s, p):
        lazy(s, p).sort("id").sink_csv(p.join("sink.csv"))
        sunk = all_bytes(p.join("sink.csv"))
        df = komira.read_parquet(p.parquet, session=s).sort_values("id")
        df.to_csv(p.join("to.csv"))
        df.to_csv(p.join("to_args.csv"), sep=",", header=True, index=False)
        s.register_parquet("rows", p.parquet)
        copied = p.join("copy.csv")
        count = s.sql(f"COPY (SELECT * FROM rows ORDER BY id) TO '{copied}' (FORMAT csv, HEADER true)").to_arrow()
        assert count.column("Count").to_pylist() == [6], count
        for other in ("to.csv", "to_args.csv", "copy.csv"):
            assert all_bytes(p.join(other)) == sunk, (other, all_bytes(p.join(other)), sunk)
        assert by_id(read_csv_file(p.join("sink.csv")).to_pylist()) == ROWS
        lazy(s, p).sort("id").sink_ndjson(p.join("sink.jsonl"))
        df.to_json(p.join("to.jsonl"), orient="records", lines=True)
        assert all_bytes(p.join("sink.jsonl")) == all_bytes(p.join("to.jsonl"))


def test_an_existing_file_is_replaced_whole_or_not_at_all(lib_dir):
    with workspace() as (s, p):
        lf = lazy(s, p)
        path = p.join("o.parquet")
        lf.sink_parquet(path)
        lf.filter(kpl.col("id") > 4).sink_parquet(path)
        assert by_id(pq.read_table(path).to_pylist()) == rows_for([5, 6])
        csv = p.join("o.csv")
        lf.sink_csv(csv)
        lf.head(0).sink_csv(csv)
        assert all_bytes(csv) == HEADER
        # The frame reads the very file it writes over.
        mine = p.join("mine.parquet")
        shutil.copyfile(p.parquet, mine)
        own = kpl.scan_parquet(mine, session=s)
        own.filter(kpl.col("id") > 3).sink_parquet(mine)
        assert by_id(pq.read_table(mine).to_pylist()) == rows_for([4, 5, 6])
        # A write the engine refuses leaves the existing file as it was.
        raw = os.path.join(p.work, "raw.parquet")
        pq.write_table(pa.table({"t": pa.array([b"\xff", b"ok"], pa.binary())}), raw)
        blobs = kpl.scan_parquet(raw, session=s)
        kept = all_bytes(csv)
        e = raised(lambda: blobs.sink_csv(csv))
        assert type(e) is UnsupportedOperation and e.code == "COPY_TYPE_UNSUPPORTED", repr(e)
        assert all_bytes(csv) == kept
        e = raised(lambda: blobs.sink_parquet(p.join("new.parquet")))
        assert type(e) is UnsupportedOperation and e.code == "COPY_TYPE_UNSUPPORTED", repr(e)
        assert not os.path.exists(p.join("new.parquet"))
        # Each replacement left no temporary file beside its destination.
        assert sorted(os.listdir(p.out)) == ["mine.parquet", "o.csv", "o.parquet"], os.listdir(p.out)


def test_engine_refusals_name_their_code_and_step(lib_dir):
    with workspace() as (s, p):
        lf = lazy(s, p)
        e = raised(lambda: lf.sink_parquet("s3://bucket/o.parquet"))
        assert type(e) is UnsupportedOperation, repr(e)
        assert (e.code, e.step) == ("STORAGE_URL_REFUSED", "bind"), (e.code, e.step)
        good_write(s, p, "after_url.parquet")
        missing = os.path.join(p.work, "no_such_directory", "o.csv")
        e = raised(lambda: lf.sink_csv(missing))
        assert type(e) is StorageError, repr(e)
        assert (e.code, e.step) == ("STORAGE_NOT_FOUND", "execute"), (e.code, e.step)
        assert not os.path.exists(os.path.dirname(missing))
        good_write(s, p, "after_missing.parquet")
        assert sorted(os.listdir(p.out)) == ["after_missing.parquet", "after_url.parquet"], os.listdir(p.out)


def test_a_closed_session_refuses_a_write(lib_dir):
    with tempfile.TemporaryDirectory() as work:
        src = os.path.join(work, "ids.parquet")
        pq.write_table(pa.Table.from_pydict({"id": IDS}, schema=pa.schema([("id", pa.int64())])), src)
        s = komira.Session()
        lf = kpl.scan_parquet(src, session=s)
        s.close()
        out = os.path.join(work, "o.csv")
        e = raised(lambda: lf.sink_csv(out))
        assert type(e) is KomiraError and str(e) == "the session is closed", repr(e)
        assert not os.path.exists(out)


TESTS = [
    test_sink_parquet_round_trips_through_the_readers,
    test_sink_parquet_codecs,
    test_an_ordered_frame_writes_its_rows_in_order,
    test_a_frame_of_no_rows_writes_its_columns_only,
    test_sink_csv_and_ndjson_rows_and_compression,
    test_every_writer_of_komira_writes_the_same_csv_bytes,
    test_an_existing_file_is_replaced_whole_or_not_at_all,
    test_engine_refusals_name_their_code_and_step,
    test_a_closed_session_refuses_a_write,
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
    print("pl sinks: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
