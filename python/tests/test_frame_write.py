"""The DataFrame's write terminals on the real libkomira: `to_parquet`, `to_csv`
and `to_json(orient="records", lines=True)` run a frame's plan through
komira_plan_stream with a write target, and every file is read back with pyarrow
and compared with the rows worked out by hand:

- test_to_parquet_default_is_snappy_and_equals_the_source: the default codec is
  Snappy, and the rows, column names and types are the source's;
- test_to_parquet_codecs: gzip, zstd, lz4 and None write GZIP, ZSTD, LZ4 (pyarrow's name for LZ4_RAW) and
  UNCOMPRESSED files with the same rows;
- test_a_composed_frame_writes_its_rows_in_order: a filtered, assigned, sorted
  frame writes exactly its rows in its order;
- test_head_zero_writes_the_schema_and_no_rows: Parquet with the schema and no
  rows, CSV with only the header line, JSON with no bytes;
- test_to_csv_rows_header_and_null_versus_empty: the header line, the rows with
  their types, and NULL kept apart from the empty string;
- test_to_csv_infers_its_compression_from_the_extension: `.csv.gz` is gzip,
  `.csv.zst` is zstd, anything else plain text;
- test_to_csv_compression_argument_overrides_the_extension: None writes plain
  text to `.csv.gz`, "gzip" writes gzip to `.csv`, "zstd" writes zstd;
- test_to_json_lines_rows_and_compression: one object per line, equal to the
  source rows, plain and gzip;
- test_to_csv_index_changes_nothing: index=True and index=False write the same
  bytes;
- test_the_verb_chooses_the_format_not_the_extension: `to_csv("x.parquet")`
  writes CSV and `to_json("x.csv")` writes JSON lines;
- test_a_relative_path_is_resolved_at_the_call: the file lands in the working
  directory of the call;
- test_an_existing_destination_is_replaced: the old file is gone, the new one
  is whole; so is the Parquet file the frame itself reads;
- test_argument_refusals_leave_no_file: each refusal made before the library is
  called, by exact type and message, with the directory listing unchanged;
- test_engine_refusals_name_their_code_and_step: a URL at bind, a missing
  directory at execute, a binary column and its untouched destination, and
  the session writing again after each;
- test_a_closed_session_refuses_a_write: KomiraError "the session is closed";
- test_each_terminal_returns_none.

    test_frame_write.py --lib-dir <dir> --runtime-dir <dir>

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
from komira import KomiraError, StorageError, UnsupportedOperation
from komira import _native

CLOSED = "the session is closed"
GZIP_MAGIC = b"\x1f\x8b"
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
HEADER = b"id,n,x,s,flag\n"

IDS = [1, 2, 3, 4, 5, 6]
N = [10, None, -5, 7, None, 0]
X = [1.5, -2.5, 0.0, None, 4.25, -0.5]
S = ["b", "a", None, "c", "a", ""]
FLAG = [True, False, None, True, False, True]
COLUMNS = ["id", "n", "x", "s", "flag"]
ROWS = [
    {"id": i, "n": n, "x": x, "s": s, "flag": f} for i, n, x, s, f in zip(IDS, N, X, S, FLAG)
]
SCHEMA = pa.schema(
    [
        ("id", pa.int64()),
        ("n", pa.int64()),
        ("x", pa.float64()),
        ("s", pa.string()),
        ("flag", pa.bool_()),
    ]
)
URL_MESSAGE_PART = "s3://bucket/o.parquet"


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


def names(table):
    return table.schema.names


def kinds(table):
    """The column types of `table` by name, a text type as "string"."""
    out = {}
    for f in table.schema:
        text = pa.types.is_string(f.type) or pa.types.is_large_string(f.type) or pa.types.is_string_view(f.type)
        out[f.name] = "string" if text else str(f.type)
    return out


SOURCE_KINDS = {"id": "int64", "n": "int64", "x": "double", "s": "string", "flag": "bool"}


@contextlib.contextmanager
def workspace():
    """A session, the source Parquet file and an empty `out` directory, in a
    directory removed afterwards."""
    with tempfile.TemporaryDirectory() as work:
        table = pa.Table.from_pydict(
            {
                "id": IDS,
                "n": N,
                "x": X,
                "s": S,
                "flag": FLAG,
            },
            schema=SCHEMA,
        )
        parquet = os.path.join(work, "rows.parquet")
        pq.write_table(table, parquet, row_group_size=2)
        out = os.path.join(work, "out")
        os.mkdir(out)
        with komira.Session() as s:
            yield s, types.SimpleNamespace(work=work, parquet=parquet, out=out, join=lambda n: os.path.join(out, n))


def frame(s, p):
    return komira.read_parquet(p.parquet, session=s)


def read_parquet_file(path):
    return pq.read_table(path)


def read_csv_file(path, source=None):
    options = pacsv.ConvertOptions(
        column_types={f.name: f.type for f in SCHEMA}, strings_can_be_null=True, quoted_strings_can_be_null=False
    )
    return pacsv.read_csv(source if source is not None else path, convert_options=options)


def read_json_file(path, source=None, schema=SCHEMA):
    return pajson.read_json(
        source if source is not None else path, parse_options=pajson.ParseOptions(explicit_schema=schema)
    )


def head_bytes(path, n):
    with open(path, "rb") as f:
        return f.read(n)


def all_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def good_write(s, p, name="good.parquet"):
    """The session still writes: the whole source frame, read back."""
    path = p.join(name)
    assert frame(s, p).to_parquet(path) is None
    assert by_id(read_parquet_file(path).to_pylist()) == ROWS


# ---- the tests -----------------------------------------------------------------


def test_to_parquet_default_is_snappy_and_equals_the_source(lib_dir):
    with workspace() as (s, p):
        path = p.join("o.parquet")
        frame(s, p).to_parquet(path)
        meta = pq.ParquetFile(path).metadata
        assert meta.num_rows == 6, meta.num_rows
        assert meta.row_group(0).column(0).compression == "SNAPPY"
        t = read_parquet_file(path)
        assert names(t) == COLUMNS and kinds(t) == SOURCE_KINDS, (names(t), kinds(t))
        assert by_id(t.to_pylist()) == ROWS
        # An explicit "snappy" is the default.
        explicit = p.join("e.parquet")
        frame(s, p).to_parquet(explicit, compression="snappy")
        assert pq.ParquetFile(explicit).metadata.row_group(0).column(0).compression == "SNAPPY"


def test_to_parquet_codecs(lib_dir):
    with workspace() as (s, p):
        for compression, want in (("gzip", "GZIP"), ("zstd", "ZSTD"), ("lz4", "LZ4"), (None, "UNCOMPRESSED")):
            path = p.join(f"{want}.parquet")
            frame(s, p).to_parquet(path, compression=compression)
            got = pq.ParquetFile(path).metadata.row_group(0).column(0).compression
            assert got == want, (compression, got)
            assert by_id(read_parquet_file(path).to_pylist()) == ROWS, compression


def test_a_composed_frame_writes_its_rows_in_order(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        composed = df[df["id"] > 1].assign(y=lambda d: d["id"] * 2).sort_values("id", ascending=False)
        want = [dict(r, y=r["id"] * 2) for r in reversed(rows_for([2, 3, 4, 5, 6]))]
        parquet, csv, jsonl = p.join("c.parquet"), p.join("c.csv"), p.join("c.jsonl")
        composed.to_parquet(parquet)
        composed.to_csv(csv)
        composed.to_json(jsonl, orient="records", lines=True)
        t = read_parquet_file(parquet)
        assert names(t) == COLUMNS + ["y"] and t.to_pylist() == want, t.to_pylist()
        schema = SCHEMA.append(pa.field("y", pa.int64()))
        c = pacsv.read_csv(
            csv,
            convert_options=pacsv.ConvertOptions(
                column_types={f.name: f.type for f in schema}, strings_can_be_null=True, quoted_strings_can_be_null=False
            ),
        )
        assert c.to_pylist() == want, c.to_pylist()
        assert read_json_file(jsonl, schema=schema).to_pylist() == want
        # A head over a sort is exactly the first rows, in order.
        df.sort_values("id", ascending=False).head(2).to_parquet(p.join("h.parquet"))
        assert read_parquet_file(p.join("h.parquet")).to_pylist() == list(reversed(rows_for([5, 6])))


def test_head_zero_writes_the_schema_and_no_rows(lib_dir):
    with workspace() as (s, p):
        empty = frame(s, p).head(0)
        empty.to_parquet(p.join("z.parquet"))
        t = read_parquet_file(p.join("z.parquet"))
        assert t.num_rows == 0 and names(t) == COLUMNS and kinds(t) == SOURCE_KINDS, (names(t), kinds(t))
        empty.to_csv(p.join("z.csv"))
        assert all_bytes(p.join("z.csv")) == HEADER
        empty.to_json(p.join("z.jsonl"), orient="records", lines=True)
        assert all_bytes(p.join("z.jsonl")) == b""


def test_to_csv_rows_header_and_null_versus_empty(lib_dir):
    with workspace() as (s, p):
        path = p.join("o.csv")
        frame(s, p).to_csv(path)
        assert all_bytes(path).split(b"\n")[0] + b"\n" == HEADER
        t = read_csv_file(path)
        assert names(t) == COLUMNS and kinds(t) == SOURCE_KINDS, (names(t), kinds(t))
        got = by_id(t.to_pylist())
        assert got == ROWS, got
        # NULL (row 3) and "" (row 6) are two different cells.
        assert got[2]["s"] is None and got[5]["s"] == ""


def test_to_csv_infers_its_compression_from_the_extension(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        gz, zst, plain = p.join("o.csv.gz"), p.join("o.csv.zst"), p.join("o.txt")
        df.to_csv(gz)
        df.to_csv(zst)
        df.to_csv(plain)
        df.to_csv(p.join("UPPER.CSV.GZ"))
        assert head_bytes(gz, 2) == GZIP_MAGIC
        assert head_bytes(zst, 4) == ZSTD_MAGIC
        assert head_bytes(plain, 6) == b"id,n,x"
        assert head_bytes(p.join("UPPER.CSV.GZ"), 2) == GZIP_MAGIC
        for path, codec in ((gz, "gzip"), (zst, "zstd")):
            with pa.input_stream(path, compression=codec) as stream:
                assert by_id(read_csv_file(path, stream).to_pylist()) == ROWS, codec
        assert by_id(read_csv_file(plain).to_pylist()) == ROWS


def test_to_csv_compression_argument_overrides_the_extension(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        none_gz, gzip_csv, zstd_csv = p.join("n.csv.gz"), p.join("g.csv"), p.join("z.csv")
        df.to_csv(none_gz, compression=None)
        df.to_csv(gzip_csv, compression="gzip")
        df.to_csv(zstd_csv, compression="zstd")
        assert all_bytes(none_gz).startswith(b"id,n,x")
        assert head_bytes(gzip_csv, 2) == GZIP_MAGIC
        assert head_bytes(zstd_csv, 4) == ZSTD_MAGIC
        # pyarrow takes gzip from a `.gz` path; this file is plain text.
        with pa.input_stream(none_gz, compression=None) as stream:
            assert by_id(read_csv_file(none_gz, stream).to_pylist()) == ROWS
        with pa.CompressedInputStream(pa.OSFile(gzip_csv), "gzip") as stream:
            assert by_id(read_csv_file(gzip_csv, stream).to_pylist()) == ROWS


def test_to_json_lines_rows_and_compression(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        plain, gz = p.join("o.jsonl"), p.join("o.jsonl.gz")
        df.to_json(plain, orient="records", lines=True)
        df.to_json(gz, orient="records", lines=True)
        text = all_bytes(plain)
        assert text.endswith(b"\n") and len(text.splitlines()) == 6, text
        assert by_id(read_json_file(plain).to_pylist()) == ROWS
        assert head_bytes(gz, 2) == GZIP_MAGIC
        with pa.input_stream(gz, compression="gzip") as stream:
            assert by_id(read_json_file(gz, stream).to_pylist()) == ROWS
        none_gz = p.join("n.jsonl.gz")
        df.to_json(none_gz, orient="records", lines=True, compression=None)
        assert sorted(all_bytes(none_gz).splitlines()) == sorted(text.splitlines())


def test_to_csv_index_changes_nothing(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p).sort_values("id")
        df.to_csv(p.join("a.csv"), index=True)
        df.to_csv(p.join("b.csv"), index=False)
        assert all_bytes(p.join("a.csv")) == all_bytes(p.join("b.csv"))


def test_the_verb_chooses_the_format_not_the_extension(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p).sort_values("id")
        df.to_csv(p.join("x.parquet"))
        assert all_bytes(p.join("x.parquet")).startswith(HEADER)
        df.to_json(p.join("y.csv"), orient="records", lines=True)
        assert all_bytes(p.join("y.csv")).startswith(b"{")
        df.to_parquet(p.join("z.csv"))
        assert head_bytes(p.join("z.csv"), 4) == b"PAR1"


def test_a_relative_path_is_resolved_at_the_call(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        cwd = os.getcwd()
        try:
            os.chdir(p.out)
            df.to_csv("rel.csv")
            df.to_parquet("rel.parquet")
        finally:
            os.chdir(cwd)
        assert sorted(os.listdir(p.out)) == ["rel.csv", "rel.parquet"], os.listdir(p.out)
        assert by_id(read_parquet_file(p.join("rel.parquet")).to_pylist()) == ROWS


def test_an_existing_destination_is_replaced(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        path = p.join("o.parquet")
        df.to_parquet(path)
        df[df["id"] > 4].to_parquet(path)
        assert by_id(read_parquet_file(path).to_pylist()) == rows_for([5, 6])
        csv = p.join("o.csv")
        df.to_csv(csv)
        df.head(0).to_csv(csv)
        assert all_bytes(csv) == HEADER
        # The frame reads the very file it writes over.
        mine = p.join("mine.parquet")
        shutil.copyfile(p.parquet, mine)
        own = komira.read_parquet(mine, session=s)
        own[own["id"] > 3].to_parquet(mine)
        assert by_id(read_parquet_file(mine).to_pylist()) == rows_for([4, 5, 6])
        # Each replacement left no temporary file beside its destination.
        assert sorted(os.listdir(p.out)) == ["mine.parquet", "o.csv", "o.parquet"], os.listdir(p.out)


def test_argument_refusals_leave_no_file(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        path = p.join("o.csv")
        pq_path = p.join("o.parquet")
        before = sorted(os.listdir(p.out))
        none_message = (
            "{}(None) returns the file's contents instead of writing it, which komira does not: pass a file path"
        )
        records = dict(orient="records", lines=True)
        gzip_zstd = "use compression='gzip', 'zstd' or None"

        def explicit(name):
            return f"to_csv(compression={name!r}) writes a {name} file, which komira does not write: {gzip_zstd}"

        def inferred(name, dest):
            return (
                f"to_csv(compression='infer') reads {name!r} from the extension of {dest!r}, "
                f"and komira does not write a {name} file: pass compression='gzip', 'zstd' or None"
            )

        cases = [
            (lambda: df.to_json(), UnsupportedOperation, none_message.format("to_json")),
            (lambda: df.to_csv(None), UnsupportedOperation, none_message.format("to_csv")),
            (
                lambda: df.to_json(p.join("o.json"), orient="columns", lines=True),
                UnsupportedOperation,
                "to_json(orient='columns', lines=True) writes one JSON document, which komira does not write: "
                'pass orient="records", lines=True for one object per line',
            ),
            (
                lambda: df.to_json(p.join("o.json"), orient="records", lines=False),
                UnsupportedOperation,
                "to_json(orient='records', lines=False) writes one JSON document, which komira does not write: "
                'pass orient="records", lines=True for one object per line',
            ),
            (
                lambda: df.to_json(p.join("o.json")),
                UnsupportedOperation,
                "to_json(orient=None, lines=False) writes one JSON document, which komira does not write: "
                'pass orient="records", lines=True for one object per line',
            ),
            (
                lambda: df.to_json(p.join("o.json"), compression="xz", **records),
                UnsupportedOperation,
                "to_json(compression='xz') writes a xz file, which komira does not write: " + gzip_zstd,
            ),
            (lambda: df.to_csv(path, compression="bz2"), UnsupportedOperation, explicit("bz2")),
            (lambda: df.to_csv(path, compression="zip"), UnsupportedOperation, explicit("zip")),
            (lambda: df.to_csv(path, compression="xz"), UnsupportedOperation, explicit("xz")),
            (lambda: df.to_csv(path, compression="tar"), UnsupportedOperation, explicit("tar")),
            (
                lambda: df.to_csv(p.join("o.csv.bz2")),
                UnsupportedOperation,
                inferred("bz2", p.join("o.csv.bz2")),
            ),
            (lambda: df.to_csv(p.join("o.csv.xz")), UnsupportedOperation, inferred("xz", p.join("o.csv.xz"))),
            (lambda: df.to_csv(p.join("o.csv.zip")), UnsupportedOperation, inferred("zip", p.join("o.csv.zip"))),
            (lambda: df.to_csv(p.join("o.tar.gz")), UnsupportedOperation, inferred("tar", p.join("o.tar.gz"))),
            (
                lambda: df.to_csv(path, compression="lz4"),
                UnsupportedOperation,
                "to_csv(compression='lz4') is not a compression komira writes: use 'infer', 'gzip', 'zstd' or None",
            ),
            (
                lambda: df.to_parquet(pq_path, compression="brotli"),
                UnsupportedOperation,
                "to_parquet(compression='brotli') is not a codec komira writes: "
                "use 'snappy', 'gzip', 'zstd', 'lz4' or None",
            ),
            (lambda: df.to_csv(path, compression=1), TypeError, "to_csv compression must be a str or None, not int"),
            (
                lambda: df.to_parquet(pq_path, compression=1),
                TypeError,
                "to_parquet compression must be a str or None, not int",
            ),
            (
                lambda: df.to_csv(path, compression={"method": "gzip", "compresslevel": 1}),
                UnsupportedOperation,
                "to_csv(compression={...}) takes the compression's options, and komira takes only its name: "
                "pass compression='gzip', 'zstd' or None",
            ),
            (lambda: df.to_csv(path, index="no"), TypeError, "to_csv index must be a bool, not str"),
            (lambda: df.to_parquet(3), TypeError, "path must be a str or os.PathLike[str], not int"),
        ]
        for call, cls, message in cases:
            refused(call, cls, message)
            assert sorted(os.listdir(p.out)) == before, message
        e = raised(lambda: df.to_csv(path, sep=";"))
        assert type(e) is TypeError and "sep" in str(e), repr(e)
        assert sorted(os.listdir(p.out)) == before
        good_write(s, p)


def test_engine_refusals_name_their_code_and_step(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        before = sorted(os.listdir(p.out))

        e = raised(lambda: df.to_parquet(URL_MESSAGE_PART))
        assert type(e) is UnsupportedOperation, repr(e)
        assert (e.code, e.step) == ("STORAGE_URL_REFUSED", "bind"), (e.code, e.step)
        good_write(s, p, "after_url.parquet")

        missing = os.path.join(p.work, "no_such_directory", "o.parquet")
        e = raised(lambda: df.to_parquet(missing))
        assert type(e) is StorageError, repr(e)
        assert (e.code, e.step) == ("STORAGE_NOT_FOUND", "execute"), (e.code, e.step)
        assert not os.path.exists(os.path.dirname(missing))
        good_write(s, p, "after_missing.parquet")

        e = raised(lambda: df.to_csv("s3://bucket/o.csv"))
        assert type(e) is UnsupportedOperation and e.code == "STORAGE_URL_REFUSED", repr(e)

        # A column type the writer does not write: nothing is written, and an
        # existing destination is left as it was.
        raw = os.path.join(p.work, "raw.parquet")
        pq.write_table(pa.table({"t": pa.array([b"\xff", b"ok"], pa.binary())}), raw)
        blobs = komira.read_parquet(raw, session=s)
        dest = p.join("keep.parquet")
        df.to_parquet(dest)
        kept = all_bytes(dest)
        e = raised(lambda: blobs.to_parquet(dest))
        assert type(e) is UnsupportedOperation and e.code == "COPY_TYPE_UNSUPPORTED", repr(e)
        assert all_bytes(dest) == kept
        e = raised(lambda: blobs.to_parquet(p.join("new.parquet")))
        assert type(e) is UnsupportedOperation and e.code == "COPY_TYPE_UNSUPPORTED", repr(e)
        assert not os.path.exists(p.join("new.parquet"))
        good_write(s, p, "after_type.parquet")
        assert sorted(os.listdir(p.out)) == sorted(
            before + ["after_url.parquet", "after_missing.parquet", "keep.parquet", "after_type.parquet"]
        ), os.listdir(p.out)


def test_a_closed_session_refuses_a_write(lib_dir):
    with tempfile.TemporaryDirectory() as work:
        table = pa.Table.from_pydict({"id": IDS}, schema=pa.schema([("id", pa.int64())]))
        src = os.path.join(work, "ids.parquet")
        pq.write_table(table, src)
        s = komira.Session()
        df = komira.read_parquet(src, session=s)
        s.close()
        out = os.path.join(work, "o.parquet")
        e = refused(lambda: df.to_parquet(out), KomiraError, CLOSED)
        assert e.status is None, repr(e)
        assert not os.path.exists(out)


def test_each_terminal_returns_none(lib_dir):
    with workspace() as (s, p):
        df = frame(s, p)
        assert df.to_parquet(p.join("a.parquet")) is None
        assert df.to_csv(p.join("a.csv")) is None
        assert df.to_json(p.join("a.jsonl"), orient="records", lines=True) is None


TESTS = [
    test_to_parquet_default_is_snappy_and_equals_the_source,
    test_to_parquet_codecs,
    test_a_composed_frame_writes_its_rows_in_order,
    test_head_zero_writes_the_schema_and_no_rows,
    test_to_csv_rows_header_and_null_versus_empty,
    test_to_csv_infers_its_compression_from_the_extension,
    test_to_csv_compression_argument_overrides_the_extension,
    test_to_json_lines_rows_and_compression,
    test_to_csv_index_changes_nothing,
    test_the_verb_chooses_the_format_not_the_extension,
    test_a_relative_path_is_resolved_at_the_call,
    test_an_existing_destination_is_replaced,
    test_argument_refusals_leave_no_file,
    test_engine_refusals_name_their_code_and_step,
    test_a_closed_session_refuses_a_write,
    test_each_terminal_returns_none,
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
    print("frame writes: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
