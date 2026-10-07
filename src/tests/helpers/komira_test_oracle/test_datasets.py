"""The oracle's datasets are what they claim to be, in every format.

    test_datasets.py <the :datasets output directory>

What it checks, and the defect each check catches (README.md has the table):

1. The tree holds exactly `index.tsv`, one `.schema` per dataset and one
   file per dataset and format, and the index lists each data file with the
   right dataset, format, row count and columns. Catches a format or dataset
   that is not written, or a file nobody declared.
2. Each sidecar is the schema line written out by hand below (SIDECARS),
   and the writer escapes and refuses as the harness's spelling says.
   Catches a sidecar that drifts from komira_plan_harness's schema line (a
   lost `?`, an unescaped `:` in a time zone, a unit spelt the legacy way).
3. Each format leaves out exactly the columns written out by hand below
   (LEFT_OUT), and nothing for `nulls` and the join pair. Catches a column
   silently dropped from a format, or a reason that no longer holds.
4. Each file, decoded by pyarrow, is the dataset's table: the same column
   names in order, the same types (decimal precision and scale, timestamp
   unit and zone), the same nullability where the format keeps it, the same
   row count, and the same values, NULLs in the same rows and floats compared
   by their bits (so NaN, -0.0 and 0.0 are told apart). The table is rebuilt
   here from datasets.py's fixed seeds, in a process of its own, so a seed
   that changed between the generator's run and this one also fails.
   Catches a writer that loses a NULL, a value, a type parameter or a
   column, and a format that disagrees with the others.
5. Anchors on the tables themselves, written out by hand (ROWS and
   `check_anchors`): the special values each column must hold, the nine
   {true, false, NULL} pairs, the keys of the join pair. Catches a generator
   change that drops the cases a shard relies on; the checks above cannot,
   because they compare the generator with itself.
6. Structure the readers rely on: an LZ4 or ZSTD IPC file holds compressed
   frames of that codec, and datasets larger than formats.CHUNK_ROWS cross
   Parquet row groups and IPC record batches. Catches a codec option that is
   silently ignored.

Every mismatch is collected and reported, not only the first.
"""

import decimal
import os
import sys

import pyarrow as pa
import pyarrow.ipc as ipc
import pyarrow.parquet as pq

import datasets
import formats
import schema_text

ROWS = {"join_left": 40, "join_right": 30, "nulls": 1000, "types": 256}

SIDECARS = {
    "types": "\t".join([
        "i8:int8?", "i16:int16?", "i32:int32?", "i64:int64?",
        "u8:uint8?", "u16:uint16?", "u32:uint32?", "u64:uint64?",
        "f32:float32?", "f64:float64?", "f32_special:float32?", "f64_special:float64?",
        "dec_9_2:decimal128(9,2)?", "dec_38_10:decimal128(38,10)?",
        "str:string?", "bin:binary?", "bin_raw:binary?", "date32:date32?",
        "ts_s:timestamp_s?", "ts_s_tz:timestamp_s(UTC)?",
        "ts_ms:timestamp_ms?", "ts_ms_tz:timestamp_ms(UTC)?",
        "ts_us:timestamp_us?", "ts_us_tz:timestamp_us(+05\\:30)?",
        "ts_ns:timestamp_ns?", "ts_ns_tz:timestamp_ns(+05\\:30)?",
        "bool:bool?",
    ]) + "\n",
    "nulls": "id:int64\tk:int64?\tb1:bool?\tb2:bool?\ti32:int32?\tv:float64?\ts:string?\tall_null:int64?\n",
    "join_left": "id:int64\tk:int64?\tk2:string?\tlv:int32?\n",
    "join_right": "id:int64\tk:int64?\tk2:string?\trv:string?\n",
}

_TS = ["ts_s", "ts_s_tz", "ts_ms", "ts_ms_tz", "ts_us", "ts_us_tz", "ts_ns", "ts_ns_tz"]
LEFT_OUT = {
    "types": {
        "orc": ["u8", "u16", "u32", "u64"] + _TS,
        "parquet": ["ts_s", "ts_s_tz"],
        "jsonl": ["f32_special", "f64_special", "bin_raw"],
    },
}

failures = []


def fail(msg):
    failures.append(msg)


def keys(column):
    """Comparable Python values of a column: NULL is None, a float is its
    bit pattern, a date or timestamp its integer."""
    arr = column.combine_chunks() if isinstance(column, pa.ChunkedArray) else column
    t = arr.type
    if pa.types.is_float32(t):
        return arr.view(pa.uint32()).to_pylist()
    if pa.types.is_float64(t):
        return arr.view(pa.uint64()).to_pylist()
    if pa.types.is_timestamp(t):
        return arr.cast(pa.int64()).to_pylist()
    if pa.types.is_date32(t):
        return arr.cast(pa.int32()).to_pylist()
    return arr.to_pylist()


def check_tree(out):
    want = {"index.tsv"}
    for name in datasets.NAMES:
        want.add(name + ".schema")
        for fmt in datasets.FORMATS:
            want.add(name + "." + formats.SUFFIX[fmt])
    got = set()
    for parent, dirs, files in os.walk(out):
        for f in files:
            got.add(os.path.relpath(os.path.join(parent, f), out))
        for d in dirs:
            fail("tree: unexpected directory %s" % os.path.relpath(os.path.join(parent, d), out))
    for f in sorted(want - got):
        fail("tree: %s is missing" % f)
    for f in sorted(got - want):
        fail("tree: %s is not a file of the oracle" % f)


def check_index(out, built):
    with open(os.path.join(out, "index.tsv"), encoding="utf-8") as f:
        lines = f.read().split("\n")
    if lines[0] != "file\tdataset\tformat\trows\tcolumns" or lines[-1] != "":
        fail("index.tsv: header %r or missing final newline" % lines[0])
        return
    rows = [line.split("\t") for line in lines[1:-1]]
    want = []
    for name in datasets.NAMES:
        for fmt in datasets.FORMATS:
            want.append([name + "." + formats.SUFFIX[fmt], name, fmt, str(ROWS[name]), ",".join(built[name].carried(fmt))])
    if rows != sorted(want):
        fail("index.tsv: rows differ from the datasets: %r" % [r for r in rows if r not in want][:3])


def check_sidecars(out):
    for name in datasets.NAMES:
        with open(os.path.join(out, name + ".schema"), encoding="utf-8", newline="") as f:
            got = f.read()
        if got != SIDECARS[name]:
            fail("%s.schema: %r, want %r" % (name, got, SIDECARS[name]))
    # The writer's escapes and refusals, on names and types no dataset holds.
    named = pa.schema([pa.field("a:b,c<d>e[f]g\\h\ti\x01", pa.int8(), nullable=False)])
    want = "a\\:b\\,c\\<d\\>e\\[f\\]g\\\\h\\ti\\x01:int8\n"
    if schema_text.schema_line(named) != want:
        fail("schema_text: %r, want %r" % (schema_text.schema_line(named), want))
    for t in (pa.list_(pa.int8()), pa.large_string(), pa.float16(), pa.time32("s")):
        try:
            schema_text.schema_line(pa.schema([pa.field("x", t)]))
            fail("schema_text: %s was spelt, but O1 spells flat types only" % t)
        except ValueError:
            pass


def check_left_out(built):
    for name in datasets.NAMES:
        ds = built[name]
        everything = [f.name for f in ds.schema]
        for fmt in datasets.FORMATS:
            want = [c for c in everything if c not in LEFT_OUT.get(name, {}).get(fmt, [])]
            if ds.carried(fmt) != want:
                fail("%s.%s: carries %s, want %s" % (name, fmt, ds.carried(fmt), want))


def check_decoded(out, built):
    for name in datasets.NAMES:
        ds = built[name]
        for fmt in datasets.FORMATS:
            file = name + "." + formats.SUFFIX[fmt]
            expected = ds.table.select(ds.carried(fmt))
            try:
                got = formats.read(fmt, os.path.join(out, file), expected.schema)
            except Exception as e:
                fail("%s: pyarrow cannot decode it: %s: %s" % (file, type(e).__name__, e))
                continue
            if got.column_names != expected.column_names:
                fail("%s: columns %s, want %s" % (file, got.column_names, expected.column_names))
                continue
            if got.num_rows != ROWS[name]:
                fail("%s: %d rows, want %d" % (file, got.num_rows, ROWS[name]))
                continue
            for want_field in expected.schema:
                got_field = got.schema.field(want_field.name)
                if got_field.type != want_field.type:
                    fail("%s: column %s is %s, want %s" % (file, want_field.name, got_field.type, want_field.type))
                    continue
                if fmt in formats.KEEPS_NULLABILITY and got_field.nullable != want_field.nullable:
                    fail("%s: column %s nullable=%s, want %s" % (file, want_field.name, got_field.nullable, want_field.nullable))
                a, b = keys(expected.column(want_field.name)), keys(got.column(want_field.name))
                bad = [i for i in range(len(a)) if a[i] != b[i]]
                if bad:
                    i = bad[0]
                    fail("%s: column %s differs in %d rows, first row %d: decoded %r, want %r" % (
                        file, want_field.name, len(bad), i, b[i], a[i]))


def check_anchors(built):
    for name in datasets.NAMES:
        if built[name].rows != ROWS[name]:
            fail("%s: %d rows, want %d" % (name, built[name].rows, ROWS[name]))
    t = built["types"].table
    for field in t.schema:
        col = t.column(field.name)
        if not field.nullable or col.null_count == 0 or col.null_count == len(col):
            fail("types.%s: nullable=%s with %d NULLs of %d; every column must be nullable and hold both" % (
                field.name, field.nullable, col.null_count, len(col)))
    must = {
        "i8": [-128, 127], "i64": [-(2**63), 2**63 - 1], "u8": [255], "u64": [2**64 - 1],
        # -0.0, the least subnormal; then NaN, +inf, -inf.
        "f32": [0x80000000, 0x00000001], "f64": [0x8000000000000000, 0x0000000000000001],
        "f32_special": [0x7FC00000, 0x7F800000, 0xFF800000],
        "f64_special": [0x7FF8000000000000, 0x7FF0000000000000, 0xFFF0000000000000],
        "dec_38_10": [decimal.Decimal("9999999999999999999999999999.9999999999")],
        "dec_9_2": [decimal.Decimal("-9999999.99")],
        "str": ["", "\\N", "NaN", "\U0001F600", "line\nbreak", 'say "hi"', "a\x00b"],
        "bin": [b"", b"\x00"], "bin_raw": [b"\xff"],
        # 0001-01-01 and 9999-12-31, in days since the epoch.
        "date32": [-719162, 2932896],
        "ts_ns": [-9223372036000000000, 2**63 - 1, -1], "ts_s": [-62135596800, 253402300799],
        "bool": [True, False],
    }
    for col, values in must.items():
        have = set(keys(t.column(col)))
        for v in values:
            if v not in have:
                fail("types.%s lacks %r" % (col, v))
    zones = {f.name: f.type.tz for f in t.schema if pa.types.is_timestamp(f.type)}
    if zones != {"ts_s": None, "ts_s_tz": "UTC", "ts_ms": None, "ts_ms_tz": "UTC",
                 "ts_us": None, "ts_us_tz": "+05:30", "ts_ns": None, "ts_ns_tz": "+05:30"}:
        fail("types: timestamp zones %r" % zones)

    n = built["nulls"].table
    tvn = [True, False, None]
    pairs = list(zip(n.column("b1").to_pylist()[:9], n.column("b2").to_pylist()[:9]))
    if pairs != [(a, b) for a in tvn for b in tvn]:
        fail("nulls: the first nine (b1, b2) pairs are %r" % pairs)
    if n.column("all_null").null_count != ROWS["nulls"]:
        fail("nulls.all_null: %d NULLs" % n.column("all_null").null_count)
    if n.column("id").to_pylist() != list(range(ROWS["nulls"])):
        fail("nulls.id is not 0..%d" % (ROWS["nulls"] - 1))
    for col, values in {"s": ["", None], "k": [None, 1, 2, 3], "i32": [None, 0], "v": [None]}.items():
        have = set(n.column(col).to_pylist())
        for v in values:
            if v not in have:
                fail("nulls.%s lacks %r" % (col, v))
    for col in ("k", "s", "v", "i32"):
        if n.column(col).null_count < ROWS["nulls"] // 5:
            fail("nulls.%s: only %d NULLs" % (col, n.column(col).null_count))

    left = built["join_left"].table.column("k").to_pylist()
    right = built["join_right"].table.column("k").to_pylist()
    for side, ks, own, other in (("join_left", left, 9, right), ("join_right", right, 10, left)):
        if None not in ks or ks.count(1) < 2 or own not in ks or own in other:
            fail("%s.k: needs NULL, a duplicated 1 and %d, which the other side lacks: %r" % (side, own, ks))
    for side in ("join_left", "join_right"):
        k2 = built[side].table.column("k2").to_pylist()
        if "" not in k2 or None not in k2:
            fail("%s.k2 lacks the empty string or NULL" % side)


_MAGIC = {"lz4": b"\x04\x22\x4d\x18", "zstd": b"\x28\xb5\x2f\xfd"}


def check_structure(out, built):
    for name in datasets.NAMES:
        chunks = -(-ROWS[name] // formats.CHUNK_ROWS)
        groups = pq.ParquetFile(os.path.join(out, name + ".parquet")).metadata.num_row_groups
        if groups != chunks:
            fail("%s.parquet: %d row groups, want %d" % (name, groups, chunks))
        for fmt in datasets.FORMATS:
            if not fmt.startswith("arrow_"):
                continue
            path = os.path.join(out, name + "." + formats.SUFFIX[fmt])
            if fmt.startswith("arrow_file"):
                batches = ipc.open_file(path).num_record_batches
            else:
                batches = sum(1 for _ in ipc.open_stream(path))
            if batches != chunks:
                fail("%s: %d record batches, want %d" % (path, batches, chunks))
            with open(path, "rb") as f:
                body = f.read()
            codec = formats.ipc_codec(fmt)
            for c, magic in _MAGIC.items():
                if (c == codec) != (magic in body):
                    fail("%s: written with %s, %s frames %s" % (
                        os.path.basename(path), codec, c, "found" if magic in body else "not found"))


def main(out):
    built = {name: datasets.build(name) for name in datasets.NAMES}
    check_tree(out)
    check_index(out, built)
    check_sidecars(out)
    check_left_out(built)
    check_anchors(built)
    check_decoded(out, built)
    check_structure(out, built)
    if failures:
        raise AssertionError("%d failures:\n  %s" % (len(failures), "\n  ".join(failures)))
    print("datasets: %d files checked" % (len(datasets.NAMES) * len(datasets.FORMATS)))


main(sys.argv[1])
