#!/usr/bin/env python3
"""
gen_fixtures.py: pyarrow-written Arrow IPC fixtures (stream format, File
format and a Tensor message) for byte-level parity tests of the
komira_arrow_ipc FlatBuffer reader and record-batch decoders.

USAGE (from this directory, with pyarrow installed):
    python3 gen_fixtures.py                    # every fixture
    python3 gen_fixtures.py schema_only        # one fixture

OUTPUTS:
    schema_only.arrow             Schema-only IPC stream, one field per primitive Type arm
    schema_record_batch.arrow     Schema + 1 RecordBatch (Int64 + Float64 + Utf8, 100 rows)
    arrow_file.arrow              Full Arrow File (magic + IPC + Footer + magic trailer)
    tensor_1d_int64.tensor        Tensor 1D Int64, 1000 elements (needs numpy)
    view_types_inline.arrow       Utf8View + BinaryView, every value <= 12 bytes
    view_types_indirect.arrow     Utf8View with values > 12 bytes (variadic buffer)
    primitives_int_float.arrow    Int32/Int64/UInt32/UInt64/Float32/Float64 stream
    temporal_batch.arrow          date32 / time32[ms] / timestamp[us, UTC] / duration[us] stream
    decimal128_batch.arrow        decimal128(18, 4) stream
    dict_delta_stream.arrow       dictionary<int32, utf8> stream with isDelta DictionaryBatches
    dict_replacement_stream.arrow dictionary<int32, utf8> stream, two batches sharing one dictionary

Reproducibility: deterministic, no random seeds. The committed files were
written by pyarrow 24.0.0.
"""
import os
import sys
import pyarrow as pa


FIXTURE_DIR = os.path.dirname(os.path.abspath(__file__))


def _write_bytes(name: str, payload: bytes) -> None:
    path = os.path.join(FIXTURE_DIR, name)
    with open(path, "wb") as f:
        f.write(payload)
    print(f"wrote {name}: {len(payload):,} bytes")


def gen_schema_only() -> None:
    """IPC stream holding only a Schema message (plus EOS), one field per
    primitive Type arm."""
    fields = [
        pa.field("f_null", pa.null()),
        pa.field("f_bool", pa.bool_()),
        pa.field("f_int8", pa.int8()),
        pa.field("f_int16", pa.int16()),
        pa.field("f_int32", pa.int32()),
        pa.field("f_int64", pa.int64()),
        pa.field("f_uint8", pa.uint8()),
        pa.field("f_uint16", pa.uint16()),
        pa.field("f_uint32", pa.uint32()),
        pa.field("f_uint64", pa.uint64()),
        pa.field("f_float16", pa.float16()),
        pa.field("f_float32", pa.float32()),
        pa.field("f_float64", pa.float64()),
        pa.field("f_decimal128", pa.decimal128(precision=18, scale=4)),
        pa.field("f_date32", pa.date32()),
        pa.field("f_date64", pa.date64()),
        pa.field("f_time32_ms", pa.time32("ms")),
        pa.field("f_time64_us", pa.time64("us")),
        pa.field("f_timestamp_ns", pa.timestamp("ns", tz="UTC")),
        pa.field("f_duration_s", pa.duration("s")),
        pa.field("f_utf8", pa.string()),
        pa.field("f_binary", pa.binary()),
        pa.field("f_fixed_size_binary", pa.binary(16)),
    ]
    schema = pa.schema(fields)
    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, schema)
    writer.close()
    payload = sink.getvalue().to_pybytes()
    _write_bytes("schema_only.arrow", payload)


def gen_schema_record_batch() -> None:
    """Schema + 1 RecordBatch with 100 rows x 3 columns (Int64, Float64, Utf8)."""
    n = 100
    arr_i = pa.array(list(range(n)), type=pa.int64())
    arr_f = pa.array([x * 1.5 for x in range(n)], type=pa.float64())
    arr_s = pa.array([f"row_{i}" for i in range(n)], type=pa.string())
    rb = pa.RecordBatch.from_arrays([arr_i, arr_f, arr_s], names=["i", "f", "s"])

    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, rb.schema)
    writer.write_batch(rb)
    writer.close()
    payload = sink.getvalue().to_pybytes()
    _write_bytes("schema_record_batch.arrow", payload)


def gen_arrow_file() -> None:
    """Full Arrow File: magic header + Schema + RecordBatch + Footer +
    magic trailer."""
    n = 50
    arr_i = pa.array(list(range(n)), type=pa.int64())
    arr_f = pa.array([x * 0.25 for x in range(n)], type=pa.float64())
    rb = pa.RecordBatch.from_arrays([arr_i, arr_f], names=["i", "f"])

    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_file(sink, rb.schema)
    writer.write_batch(rb)
    writer.close()
    payload = sink.getvalue().to_pybytes()
    _write_bytes("arrow_file.arrow", payload)


def gen_tensor_1d_int64() -> None:
    """Tensor 1D Int64, 1000 elements; Tensor.data is an inline 16-byte
    Buffer struct. Requires numpy."""
    import numpy as np
    arr = np.arange(1000, dtype=np.int64)
    tensor = pa.Tensor.from_numpy(arr)

    sink = pa.BufferOutputStream()
    pa.ipc.write_tensor(tensor, sink)
    payload = sink.getvalue().to_pybytes()
    _write_bytes("tensor_1d_int64.tensor", payload)


def gen_view_types_record_batch() -> None:
    """Schema + 1 RecordBatch with BinaryView + Utf8View columns, once with
    inline-only values (<= 12 bytes) and once with indirect values."""
    short_strs = pa.array(["hi", "world", "foo", "", "abc"], type=pa.string_view())
    short_bins = pa.array([b"\x01\x02", b"", b"abcdefg", b"x", b"\xff"], type=pa.binary_view())

    rb = pa.RecordBatch.from_arrays(
        [short_strs, short_bins],
        names=["s_view", "b_view"],
    )
    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, rb.schema)
    writer.write_batch(rb)
    writer.close()
    payload = sink.getvalue().to_pybytes()
    _write_bytes("view_types_inline.arrow", payload)

    long_strs = pa.array(
        [
            "short",
            "this is a long string > 12 bytes",
            "another moderately long string",
            "short2",
        ],
        type=pa.string_view(),
    )
    rb2 = pa.RecordBatch.from_arrays([long_strs], names=["s_view"])
    sink2 = pa.BufferOutputStream()
    writer2 = pa.ipc.new_stream(sink2, rb2.schema)
    writer2.write_batch(rb2)
    writer2.close()
    payload2 = sink2.getvalue().to_pybytes()
    _write_bytes("view_types_indirect.arrow", payload2)


def gen_primitives_int_float() -> None:
    """RecordBatch with Int32 + Int64 + UInt32 + UInt64 + Float32 + Float64
    columns, 8 rows each; values span the signed/unsigned boundaries."""
    n = 8
    i32 = pa.array([-2147483648, -1, 0, 1, 2147483647, 42, -42, 100], type=pa.int32())
    i64 = pa.array([-9223372036854775807, -1, 0, 1, 9223372036854775807, 42, -42, 100], type=pa.int64())
    u32 = pa.array([0, 1, 2, 4294967295, 100, 42, 7, 99], type=pa.uint32())
    u64 = pa.array([0, 1, 2, 18446744073709551615, 100, 42, 7, 99], type=pa.uint64())
    f32 = pa.array([0.0, 1.5, -1.5, 3.14, -3.14, 1e10, -1e10, 0.0], type=pa.float32())
    f64 = pa.array([0.0, 1.5, -1.5, 3.141592653589793, -3.141592653589793, 1e100, -1e100, 0.0], type=pa.float64())
    rb = pa.RecordBatch.from_arrays(
        [i32, i64, u32, u64, f32, f64],
        names=["i32", "i64", "u32", "u64", "f32", "f64"],
    )
    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, rb.schema)
    writer.write_batch(rb)
    writer.close()
    _write_bytes("primitives_int_float.arrow", sink.getvalue().to_pybytes())


def gen_temporal_batch() -> None:
    """date32, time32[ms], timestamp[us, tz=UTC], duration[us]; 4 rows each."""
    d32 = pa.array([0, 1, 18250, 19000], type=pa.date32())                    # days since epoch
    t32 = pa.array([0, 1000, 86399000, 43200000], type=pa.time32("ms"))
    ts_us = pa.array([0, 1000000, 1577836800000000, 1640995200000000], type=pa.timestamp("us", tz="UTC"))
    dur_us = pa.array([0, 1000000, 3600000000, 86400000000], type=pa.duration("us"))
    rb = pa.RecordBatch.from_arrays(
        [d32, t32, ts_us, dur_us],
        names=["d32", "t32_ms", "ts_us_utc", "dur_us"],
    )
    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, rb.schema)
    writer.write_batch(rb)
    writer.close()
    _write_bytes("temporal_batch.arrow", sink.getvalue().to_pybytes())


def gen_decimal128_batch() -> None:
    """decimal128(precision=18, scale=4), 4 rows (16 bytes per cell)."""
    from decimal import Decimal
    decimal_type = pa.decimal128(precision=18, scale=4)
    vals = pa.array(
        [Decimal("0.0000"), Decimal("1.5000"), Decimal("-1.5000"), Decimal("12345.6789")],
        type=decimal_type,
    )
    rb = pa.RecordBatch.from_arrays([vals], names=["amount"])
    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, rb.schema)
    writer.write_batch(rb)
    writer.close()
    _write_bytes("decimal128_batch.arrow", sink.getvalue().to_pybytes())


def gen_dict_delta_stream() -> None:
    """Dictionary-encoded column with emit_dictionary_deltas=True. Three
    RecordBatches whose dictionaries extend monotonically, so pyarrow emits:

      Schema
      DictionaryBatch(id=0, isDelta=false) {"a","b","c"}
      RecordBatch indices [0,1,2]
      DictionaryBatch(id=0, isDelta=true)  {"d","e"}
      RecordBatch indices [0,3,4]
      DictionaryBatch(id=0, isDelta=true)  {"f"}
      RecordBatch indices [2,4,5]
      EOS
    """
    schema = pa.schema([pa.field("k", pa.dictionary(pa.int32(), pa.string()))])
    arr1 = pa.DictionaryArray.from_arrays(
        pa.array([0, 1, 2], type=pa.int32()),
        pa.array(["a", "b", "c"], type=pa.string()),
    )
    arr2 = pa.DictionaryArray.from_arrays(
        pa.array([0, 3, 4], type=pa.int32()),
        pa.array(["a", "b", "c", "d", "e"], type=pa.string()),
    )
    arr3 = pa.DictionaryArray.from_arrays(
        pa.array([2, 4, 5], type=pa.int32()),
        pa.array(["a", "b", "c", "d", "e", "f"], type=pa.string()),
    )
    rb1 = pa.RecordBatch.from_arrays([arr1], names=["k"])
    rb2 = pa.RecordBatch.from_arrays([arr2], names=["k"])
    rb3 = pa.RecordBatch.from_arrays([arr3], names=["k"])

    options = pa.ipc.IpcWriteOptions(emit_dictionary_deltas=True)
    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, schema, options=options)
    writer.write_batch(rb1)
    writer.write_batch(rb2)
    writer.write_batch(rb3)
    writer.close()
    _write_bytes("dict_delta_stream.arrow", sink.getvalue().to_pybytes())


def gen_dict_replacement_stream() -> None:
    """Dictionary-encoded column WITHOUT emit_dictionary_deltas: two
    RecordBatches whose dictionaries are equal. pyarrow emits the
    DictionaryBatch (isDelta=false) once and does not re-emit an equal
    dictionary, so the stream is Schema, DictionaryBatch, RecordBatch,
    RecordBatch, EOS. The stream therefore contains no replacement: despite
    its name, this fixture pins a dictionary shared by two batches. (pyarrow's
    stream writer does emit an isDelta=false replacement when a later batch
    carries a different dictionary; only the File format refuses one. A
    pyarrow replacement fixture would pass a different dictionary for arr2.)
    """
    schema = pa.schema([pa.field("k", pa.dictionary(pa.int32(), pa.string()))])
    arr1 = pa.DictionaryArray.from_arrays(
        pa.array([0, 1, 2], type=pa.int32()),
        pa.array(["x", "y", "z"], type=pa.string()),
    )
    arr2 = pa.DictionaryArray.from_arrays(
        pa.array([0, 1, 2], type=pa.int32()),
        pa.array(["x", "y", "z"], type=pa.string()),
    )
    rb1 = pa.RecordBatch.from_arrays([arr1], names=["k"])
    rb2 = pa.RecordBatch.from_arrays([arr2], names=["k"])

    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, schema)
    writer.write_batch(rb1)
    writer.write_batch(rb2)
    writer.close()
    _write_bytes("dict_replacement_stream.arrow", sink.getvalue().to_pybytes())


ALL_FIXTURES = {
    "schema_only": gen_schema_only,
    "schema_record_batch": gen_schema_record_batch,
    "arrow_file": gen_arrow_file,
    "tensor_1d_int64": gen_tensor_1d_int64,
    "view_types_record_batch": gen_view_types_record_batch,
    "primitives_int_float": gen_primitives_int_float,
    "temporal_batch": gen_temporal_batch,
    "decimal128_batch": gen_decimal128_batch,
    "dict_delta_stream": gen_dict_delta_stream,
    "dict_replacement_stream": gen_dict_replacement_stream,
}


def main() -> int:
    print(f"pyarrow version: {pa.__version__}")
    targets = sys.argv[1:] if len(sys.argv) > 1 else list(ALL_FIXTURES.keys())
    failed = []
    for name in targets:
        if name not in ALL_FIXTURES:
            print(f"ERROR: unknown fixture '{name}'", file=sys.stderr)
            print(f"Available: {', '.join(ALL_FIXTURES.keys())}", file=sys.stderr)
            return 1
        try:
            ALL_FIXTURES[name]()
        except Exception as e:  # e.g. numpy missing for tensor_1d_int64
            print(f"FAILED {name}: {e}", file=sys.stderr)
            failed.append(name)
    if failed:
        print(f"PARTIAL: {len(failed)} fixture(s) not written: {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
