#!/usr/bin/env python3
"""
gen_pyarrow_interop_fixtures.py: pyarrow-written Arrow IPC File-format fixtures.

Each fixture is an Arrow IPC *File-format* file (ARROW1 magic + Schema +
optional DictionaryBatch + RecordBatch(es) + Footer + ARROW1), written by
pyarrow so that a reader can be checked against a third-party producer:
exact row count, exact null POSITIONS and exact non-null values.

The high-value check: nullable STRING / INT64 / FLOAT64 / BOOL columns that
CONTAIN nulls must come back with all N rows and the nulls at their exact
positions, not N-K rows and not packed to the front.

USAGE (from this directory, with pyarrow installed):
    python3 gen_pyarrow_interop_fixtures.py

Reproducibility: deterministic, no random seeds. The committed files were
written by pyarrow 24.0.0.

Conventions:
  * nulls are placed by a fixed modulus so a test can recompute the exact
    null mask without reading the file twice.
  * an INT64 "id" anchor column == row index in every multi-column fixture
    (guards sibling-column misalignment).
"""
import os
import pyarrow as pa

FIXTURE_DIR = os.path.dirname(os.path.abspath(__file__))


def _write_file(name: str, rb_or_table, *, compression=None) -> None:
    """Write an Arrow IPC *File-format* file (magic + Footer)."""
    path = os.path.join(FIXTURE_DIR, name)
    if isinstance(rb_or_table, pa.Table):
        schema = rb_or_table.schema
        batches = rb_or_table.to_batches()
    elif isinstance(rb_or_table, list):
        schema = rb_or_table[0].schema
        batches = rb_or_table
    else:
        schema = rb_or_table.schema
        batches = [rb_or_table]

    opts = None
    if compression is not None:
        opts = pa.ipc.IpcWriteOptions(compression=compression)

    sink = pa.OSFile(path, "wb")
    writer = pa.ipc.new_file(sink, schema, options=opts)
    for b in batches:
        writer.write_batch(b)
    writer.close()
    sink.close()
    sz = os.path.getsize(path)
    print(f"wrote {name}: {sz:,} bytes ({len(batches)} batch(es))")


# =============================================================================
# 1. NULLABLE columns containing nulls — THE high-value check
# =============================================================================

N = 300  # rows


def _nullable_string():
    """STRING column NULL every 3rd row, else cat[row % 4]."""
    ids = list(range(N))
    cat = ["alpha", "beta", "gamma", "delta"]
    labels = [None if (i % 3 == 0) else cat[i % 4] for i in range(N)]
    rb = pa.RecordBatch.from_arrays(
        [pa.array(ids, type=pa.int64()),
         pa.array(labels, type=pa.utf8())],
        names=["id", "label"],
    )
    _write_file("interop_nullable_string.arrow", rb)


def _nullable_int64():
    """INT64 column NULL every 5th row, else value == row * 10."""
    ids = list(range(N))
    vals = [None if (i % 5 == 0) else (i * 10) for i in range(N)]
    rb = pa.RecordBatch.from_arrays(
        [pa.array(ids, type=pa.int64()),
         pa.array(vals, type=pa.int64())],
        names=["id", "v"],
    )
    _write_file("interop_nullable_int64.arrow", rb)


def _nullable_float64():
    """FLOAT64 column NULL every 4th row, else value == row + 0.5."""
    ids = list(range(N))
    vals = [None if (i % 4 == 0) else (i + 0.5) for i in range(N)]
    rb = pa.RecordBatch.from_arrays(
        [pa.array(ids, type=pa.int64()),
         pa.array(vals, type=pa.float64())],
        names=["id", "v"],
    )
    _write_file("interop_nullable_float64.arrow", rb)


def _nullable_bool():
    """BOOL column NULL every 7th row, else (row % 2 == 0)."""
    ids = list(range(N))
    vals = [None if (i % 7 == 0) else (i % 2 == 0) for i in range(N)]
    rb = pa.RecordBatch.from_arrays(
        [pa.array(ids, type=pa.int64()),
         pa.array(vals, type=pa.bool_())],
        names=["id", "v"],
    )
    _write_file("interop_nullable_bool.arrow", rb)


# =============================================================================
# 2. Dictionary-encoded STRING column with nulls
# =============================================================================

def _dict_string_nulls():
    """Dictionary-encoded STRING, NULL every 3rd row, else cat[row % 5]."""
    cat = ["red", "green", "blue", "yellow", "purple"]
    labels = [None if (i % 3 == 0) else cat[i % 5] for i in range(N)]
    arr = pa.array(labels, type=pa.utf8()).dictionary_encode()
    ids = pa.array(list(range(N)), type=pa.int64())
    rb = pa.RecordBatch.from_arrays([ids, arr], names=["id", "color"])
    _write_file("interop_dict_string_nulls.arrow", rb)


# =============================================================================
# 3. Multiple record batches + codec matrix
# =============================================================================

def _multi_batch():
    """3 record batches, nullable INT64 + STRING; nulls span batches."""
    cat = ["a", "bb", "ccc", "dddd"]
    batches = []
    base = 0
    for sz in (40, 55, 30):
        ids = [base + i for i in range(sz)]
        ints = [None if ((base + i) % 5 == 0) else (base + i) for i in range(sz)]
        strs = [None if ((base + i) % 3 == 0) else cat[(base + i) % 4]
                for i in range(sz)]
        batches.append(pa.RecordBatch.from_arrays(
            [pa.array(ids, type=pa.int64()),
             pa.array(ints, type=pa.int64()),
             pa.array(strs, type=pa.utf8())],
            names=["id", "n", "s"],
        ))
        base += sz
    _write_file("interop_multi_batch.arrow", batches)


def _codec_lz4():
    """Single batch, nullable INT64 + STRING, LZ4_FRAME body compression."""
    ids = list(range(N))
    ints = [None if (i % 5 == 0) else (i * 2) for i in range(N)]
    cat = ["lz", "frame", "compressed", "values"]
    strs = [None if (i % 3 == 0) else cat[i % 4] for i in range(N)]
    rb = pa.RecordBatch.from_arrays(
        [pa.array(ids, type=pa.int64()),
         pa.array(ints, type=pa.int64()),
         pa.array(strs, type=pa.utf8())],
        names=["id", "n", "s"],
    )
    _write_file("interop_codec_lz4.arrow", rb, compression="lz4")


def _codec_zstd():
    """Single batch, nullable INT64 + STRING, ZSTD body compression."""
    ids = list(range(N))
    ints = [None if (i % 5 == 0) else (i * 3) for i in range(N)]
    cat = ["zstd", "block", "deflate", "stream"]
    strs = [None if (i % 3 == 0) else cat[i % 4] for i in range(N)]
    rb = pa.RecordBatch.from_arrays(
        [pa.array(ids, type=pa.int64()),
         pa.array(ints, type=pa.int64()),
         pa.array(strs, type=pa.utf8())],
        names=["id", "n", "s"],
    )
    _write_file("interop_codec_zstd.arrow", rb, compression="zstd")


# =============================================================================
# 4. Edge cases + large strings + mixed-type schema
# =============================================================================

def _large_strings():
    """Multi-KB strings, nullable, NULL every 4th row.

    value length grows with row so offsets cover a wide range; tests the
    var-len data/offsets copy path with large bodies.
    """
    rows = 60
    ids = list(range(rows))
    strs = []
    for i in range(rows):
        if i % 4 == 0:
            strs.append(None)
        else:
            # ~ (i+1)*64 bytes, distinct per row, content == "row{i}:" + filler
            strs.append("row%d:" % i + ("x" * ((i + 1) * 64)))
    rb = pa.RecordBatch.from_arrays(
        [pa.array(ids, type=pa.int64()),
         pa.array(strs, type=pa.utf8())],
        names=["id", "big"],
    )
    _write_file("interop_large_strings.arrow", rb)


def _empty():
    """Zero-row batch, nullable STRING + INT64 — schema present, no rows."""
    rb = pa.RecordBatch.from_arrays(
        [pa.array([], type=pa.int64()),
         pa.array([], type=pa.utf8())],
        names=["id", "label"],
    )
    _write_file("interop_empty.arrow", rb)


def _single_row():
    """Single-row batch; STRING value present, INT64 value NULL."""
    rb = pa.RecordBatch.from_arrays(
        [pa.array([None], type=pa.int64()),
         pa.array(["only"], type=pa.utf8())],
        names=["n", "s"],
    )
    _write_file("interop_single_row.arrow", rb)


def _mixed_schema():
    """One batch, 5 columns of different types, all nullable with nulls.

    id    INT64  non-null (anchor, == row idx)
    i32   INT32  NULL every 2nd
    f64   FLOAT64 NULL every 3rd
    b     BOOL   NULL every 4th
    s     STRING NULL every 5th
    """
    rows = 120
    cat = ["q", "ww", "eee", "rrrr", "ttttt"]
    ids = list(range(rows))
    i32 = [None if (i % 2 == 0) else (i + 1) for i in range(rows)]
    f64 = [None if (i % 3 == 0) else (i * 1.25) for i in range(rows)]
    bo = [None if (i % 4 == 0) else (i % 3 == 0) for i in range(rows)]
    ss = [None if (i % 5 == 0) else cat[i % 5] for i in range(rows)]
    rb = pa.RecordBatch.from_arrays(
        [pa.array(ids, type=pa.int64()),
         pa.array(i32, type=pa.int32()),
         pa.array(f64, type=pa.float64()),
         pa.array(bo, type=pa.bool_()),
         pa.array(ss, type=pa.utf8())],
        names=["id", "i32", "f64", "b", "s"],
    )
    _write_file("interop_mixed_schema.arrow", rb)


def main():
    _nullable_string()
    _nullable_int64()
    _nullable_float64()
    _nullable_bool()
    _dict_string_nulls()
    _multi_batch()
    _codec_lz4()
    _codec_zstd()
    _large_strings()
    _empty()
    _single_row()
    _mixed_schema()
    print("done.")


if __name__ == "__main__":
    main()
