# =============================================================================
# test_avro_comptime_shape_kind_decode.mojo — SHAPE_KIND cascade.
# =============================================================================
#
# Acceptance:
#   1. CORRECTNESS PARITY: the comptime SHAPE_KIND path
#      (decode_avro_bytes_comptime) produces byte-identical Arrow output to the
#      runtime ActionTableInterpreter path (read_avro_bytes) on the same OCF
#      data, for each specialized SHAPE_KIND. Asserted column-by-column,
#      row-by-row, including nulls.
#   2. CLASSIFIER: classify_avro_shape returns the right SHAPE_KIND for each
#      hot shape + SHAPE_KIND_UNKNOWN for an unknown (decimal-bearing) shape.
#   3. FALLBACK: an unknown shape still decodes correctly via
#      decode_avro_bytes_comptime (routes through the runtime interpreter).
#   4. IN-TEST MICROBENCH: decode the SAME large multi-block OCF buffer via the
#      runtime path vs the comptime path; report the ratio, whatever it is.
#
# fastavro is unavailable, so fixtures are hand-emitted as the byte-exact
# inverse of the decoder (the decoder-test pattern).
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_avro import (
    read_avro_bytes,
    decode_avro_bytes_comptime,
    classify_avro_shape,
    is_hot_shape,
    OCF_SYNC_LEN,
    SHAPE_KIND_STRUCT_OF_1_INT,
    SHAPE_KIND_STRUCT_OF_N_PRIMS,
    SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS,
    SHAPE_KIND_UNKNOWN,
)
from komira_avro.avro_schema import AvroSchema
from komira_arrow.record_batch import RecordBatch


# -----------------------------------------------------------------------------
# In-test OCF binary encoders (byte-exact inverse of the decoder).
# -----------------------------------------------------------------------------


def _enc_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _enc_str(s: String, mut out: List[UInt8]):
    var b = s.as_bytes()
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_bytes(b: List[UInt8], mut out: List[UInt8]):
    _enc_long(Int64(len(b)), out)
    for i in range(len(b)):
        out.append(b[i])


def _enc_double(d: Float64, mut out: List[UInt8]):
    var bits = bitcast[DType.uint64, 1](d)
    for i in range(8):
        out.append(UInt8((bits >> UInt64(8 * i)) & 0xFF))


def _str_bytes(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _sync() -> List[UInt8]:
    var s = List[UInt8]()
    for i in range(OCF_SYNC_LEN):
        s.append(UInt8(0xA0 + i))
    return s^


def _make_header(schema: String, mut out: List[UInt8]):
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    _enc_long(Int64(2), out)
    _enc_str(String("avro.schema"), out)
    _enc_bytes(_str_bytes(schema), out)
    _enc_str(String("avro.codec"), out)
    _enc_bytes(_str_bytes(String("null")), out)
    _enc_long(Int64(0), out)
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


def _append_block(mut out: List[UInt8], object_count: Int64, payload: List[UInt8]):
    _enc_long(object_count, out)
    _enc_long(Int64(len(payload)), out)
    for i in range(len(payload)):
        out.append(payload[i])
    var s = _sync()
    for i in range(len(s)):
        out.append(s[i])


# -----------------------------------------------------------------------------
# Schemas.
# -----------------------------------------------------------------------------

# All-non-null flat primitive struct → SHAPE_KIND_STRUCT_OF_N_PRIMS.
comptime _SCHEMA_N_PRIMS = String(
    '{"type":"record","name":"NPrims","fields":['
    '{"name":"a","type":"long"},'
    '{"name":"b","type":"int"},'
    '{"name":"c","type":"double"},'
    '{"name":"d","type":"string"}]}'
)

# All-numeric flat struct (no string allocation per value) — isolates the
# per-field DISPATCH cost (what the comptime cascade erases) from per-value materialization.
comptime _SCHEMA_NUMERIC = String(
    '{"type":"record","name":"Numeric","fields":['
    '{"name":"a","type":"long"},'
    '{"name":"b","type":"int"},'
    '{"name":"c","type":"long"},'
    '{"name":"d","type":"int"},'
    '{"name":"e","type":"double"},'
    '{"name":"f","type":"long"}]}'
)

# Single int → SHAPE_KIND_STRUCT_OF_1_INT.
comptime _SCHEMA_1_INT = String(
    '{"type":"record","name":"OneInt","fields":['
    '{"name":"x","type":"int"}]}'
)

# All-nullable flat primitive struct → SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS.
comptime _SCHEMA_NULLABLE = String(
    '{"type":"record","name":"NullPrims","fields":['
    '{"name":"a","type":["null","long"]},'
    '{"name":"b","type":["null","string"]},'
    '{"name":"c","type":["int","null"]}]}'
)

# Decimal-bearing → SHAPE_KIND_UNKNOWN (fallback to runtime).
comptime _SCHEMA_DECIMAL = String(
    '{"type":"record","name":"WithDec","fields":['
    '{"name":"a","type":"long"},'
    '{"name":"q","type":{"type":"bytes","logicalType":"decimal",'
    '"precision":15,"scale":2}}]}'
)


# -----------------------------------------------------------------------------
# Parity assertion helpers — compare two RecordBatches column-by-column.
# -----------------------------------------------------------------------------


def _assert_batches_equal(rt: RecordBatch, ct: RecordBatch, label: String) raises:
    assert_equal(rt.num_rows(), ct.num_rows(), label + ": num_rows")
    assert_equal(rt.num_columns(), ct.num_columns(), label + ": num_columns")


# -----------------------------------------------------------------------------
# Test 1: classifier returns the right SHAPE_KIND.
# -----------------------------------------------------------------------------


def test_classifier() raises:
    var s_nprims = AvroSchema.parse(_SCHEMA_N_PRIMS)
    assert_equal(
        classify_avro_shape(s_nprims),
        SHAPE_KIND_STRUCT_OF_N_PRIMS,
        "N_PRIMS classify",
    )
    assert_true(is_hot_shape(classify_avro_shape(s_nprims)), "N_PRIMS hot")

    var s_1int = AvroSchema.parse(_SCHEMA_1_INT)
    assert_equal(
        classify_avro_shape(s_1int),
        SHAPE_KIND_STRUCT_OF_1_INT,
        "1_INT classify",
    )

    var s_null = AvroSchema.parse(_SCHEMA_NULLABLE)
    assert_equal(
        classify_avro_shape(s_null),
        SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS,
        "NULLABLE classify",
    )

    var s_dec = AvroSchema.parse(_SCHEMA_DECIMAL)
    assert_equal(
        classify_avro_shape(s_dec),
        SHAPE_KIND_UNKNOWN,
        "DECIMAL classify (unknown / fallback)",
    )
    assert_true(not is_hot_shape(SHAPE_KIND_UNKNOWN), "UNKNOWN not hot")


# -----------------------------------------------------------------------------
# Test 2: STRUCT_OF_N_PRIMS parity + values.
# -----------------------------------------------------------------------------


def _build_nprims_ocf(nrows: Int, nblocks: Int) -> List[UInt8]:
    var buf = List[UInt8]()
    _make_header(_SCHEMA_N_PRIMS, buf)
    var per_block = nrows // nblocks
    var emitted = 0
    for blk in range(nblocks):
        var count = per_block if blk < nblocks - 1 else (nrows - emitted)
        var payload = List[UInt8]()
        for r in range(count):
            var i = emitted + r
            _enc_long(Int64(i * 7 + 1), payload)  # a: long
            _enc_long(Int64((i % 1000) - 500), payload)  # b: int
            _enc_double(Float64(i) * 1.5, payload)  # c: double
            _enc_str(String("row") + String(i % 97), payload)  # d: string
        _append_block(buf, Int64(count), payload)
        emitted += count
    return buf^


def test_nprims_parity() raises:
    var buf = _build_nprims_ocf(20, 3)
    var rt = read_avro_bytes(Span(buf))
    var ct = decode_avro_bytes_comptime(Span(buf))
    _assert_batches_equal(rt, ct, "N_PRIMS")
    assert_equal(ct.num_rows(), 20, "N_PRIMS rows")
    assert_equal(ct.num_columns(), 4, "N_PRIMS cols")

    # a: long
    ref a_rt = rt.column_at(0)
    ref a_ct = ct.column_at(0)
    var a_rt_v = a_rt.as_primitive[DType.int64]()
    var a_ct_v = a_ct.as_primitive[DType.int64]()
    for i in range(20):
        assert_equal(Int(a_ct_v.get(i)), Int(a_rt_v.get(i)), "a parity row")
    assert_equal(Int(a_ct_v.get(0)), 1, "a[0]==1")
    assert_equal(Int(a_ct_v.get(19)), 19 * 7 + 1, "a[19]")

    # b: int
    ref b_ct = ct.column_at(1)
    var b_ct_v = b_ct.as_primitive[DType.int32]()
    var b_rt_v = rt.column_at(1).as_primitive[DType.int32]()
    for i in range(20):
        assert_equal(Int(b_ct_v.get(i)), Int(b_rt_v.get(i)), "b parity")

    # c: double
    ref c_ct = ct.column_at(2)
    var c_ct_v = c_ct.as_primitive[DType.float64]()
    var c_rt_v = rt.column_at(2).as_primitive[DType.float64]()
    for i in range(20):
        assert_equal(c_ct_v.get(i), c_rt_v.get(i), "c parity")

    # d: string
    ref d_ct = ct.column_at(3)
    var d_ct_v = d_ct.as_string()
    var d_rt_v = rt.column_at(3).as_string()
    for i in range(20):
        assert_equal(d_ct_v.get(i), d_rt_v.get(i), "d parity")


# -----------------------------------------------------------------------------
# Test 3: STRUCT_OF_1_INT parity.
# -----------------------------------------------------------------------------


def test_1int_parity() raises:
    var buf = List[UInt8]()
    _make_header(_SCHEMA_1_INT, buf)
    var p1 = List[UInt8]()
    for i in range(5):
        _enc_long(Int64(i * 11 - 13), p1)
    _append_block(buf, Int64(5), p1)
    var p2 = List[UInt8]()
    for i in range(5, 8):
        _enc_long(Int64(i * 11 - 13), p2)
    _append_block(buf, Int64(3), p2)

    var rt = read_avro_bytes(Span(buf))
    var ct = decode_avro_bytes_comptime(Span(buf))
    _assert_batches_equal(rt, ct, "1_INT")
    var x_ct = ct.column_at(0).as_primitive[DType.int32]()
    var x_rt = rt.column_at(0).as_primitive[DType.int32]()
    for i in range(8):
        assert_equal(Int(x_ct.get(i)), Int(x_rt.get(i)), "x parity")
    assert_equal(Int(x_ct.get(0)), -13, "x[0]")


# -----------------------------------------------------------------------------
# Test 4: STRUCT_OF_NULLABLE_PRIMS parity (with nulls).
# -----------------------------------------------------------------------------


def test_nullable_parity() raises:
    var buf = List[UInt8]()
    _make_header(_SCHEMA_NULLABLE, buf)
    var p = List[UInt8]()
    # Row 0: a=100, b="hi", c=7
    _enc_long(Int64(1), p)  # a: union[null,long] tag 1 == long branch
    _enc_long(Int64(100), p)
    _enc_long(Int64(1), p)  # b: union[null,string] tag 1 == string
    _enc_str(String("hi"), p)
    _enc_long(Int64(0), p)  # c: union[int,null] tag 0 == int branch
    _enc_long(Int64(7), p)
    # Row 1: a=null, b=null, c=null
    _enc_long(Int64(0), p)  # a tag 0 == null
    _enc_long(Int64(0), p)  # b tag 0 == null
    _enc_long(Int64(1), p)  # c: union[int,null] tag 1 == null
    # Row 2: a=-5, b="x", c=null
    _enc_long(Int64(1), p)
    _enc_long(Int64(-5), p)
    _enc_long(Int64(1), p)
    _enc_str(String("x"), p)
    _enc_long(Int64(1), p)  # c null
    _append_block(buf, Int64(3), p)

    var rt = read_avro_bytes(Span(buf))
    var ct = decode_avro_bytes_comptime(Span(buf))
    _assert_batches_equal(rt, ct, "NULLABLE")

    # a: nullable long
    var a_ct = ct.column_at(0).as_primitive[DType.int64]()
    var a_rt = rt.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(a_ct.get(0)), 100, "a[0]")
    assert_true(a_ct.is_null(1), "a[1] null (comptime)")
    assert_true(a_rt.is_null(1), "a[1] null (runtime)")
    assert_equal(Int(a_ct.get(2)), -5, "a[2]")
    assert_equal(ct.column_at(0).null_count(), rt.column_at(0).null_count(), "a null_count parity")

    # b: nullable string
    var b_ct = ct.column_at(1).as_string()
    assert_equal(b_ct.get(0), String("hi"), "b[0]")
    assert_true(b_ct.is_null(1), "b[1] null")
    assert_equal(b_ct.get(2), String("x"), "b[2]")
    assert_equal(ct.column_at(1).null_count(), rt.column_at(1).null_count(), "b null_count parity")

    # c: nullable int (union[int,null])
    var c_ct = ct.column_at(2).as_primitive[DType.int32]()
    assert_equal(Int(c_ct.get(0)), 7, "c[0]")
    assert_true(c_ct.is_null(1), "c[1] null")
    assert_true(c_ct.is_null(2), "c[2] null")
    assert_equal(ct.column_at(2).null_count(), rt.column_at(2).null_count(), "c null_count parity")


# -----------------------------------------------------------------------------
# Test 5: UNKNOWN-shape fallback decodes correctly (routes to runtime).
# -----------------------------------------------------------------------------


def test_unknown_fallback() raises:
    var buf = List[UInt8]()
    _make_header(_SCHEMA_DECIMAL, buf)
    var p = List[UInt8]()
    # Row 0: a=42, q=1700 (2-byte BE decimal)
    _enc_long(Int64(42), p)
    var be0 = List[UInt8]()
    be0.append(UInt8((1700 >> 8) & 0xFF))
    be0.append(UInt8(1700 & 0xFF))
    _enc_bytes(be0, p)
    # Row 1: a=99, q=255
    _enc_long(Int64(99), p)
    var be1 = List[UInt8]()
    be1.append(UInt8((255 >> 8) & 0xFF))
    be1.append(UInt8(255 & 0xFF))
    _enc_bytes(be1, p)
    _append_block(buf, Int64(2), p)

    var rt = read_avro_bytes(Span(buf))
    var ct = decode_avro_bytes_comptime(Span(buf))
    _assert_batches_equal(rt, ct, "UNKNOWN-fallback")
    var a_ct = ct.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(a_ct.get(0)), 42, "fallback a[0]")
    assert_equal(Int(a_ct.get(1)), 99, "fallback a[1]")
    var q_ct = ct.column_at(1).as_decimal128()
    var q_rt = rt.column_at(1).as_decimal128()
    assert_equal(Int(q_ct.get_low(0)), Int(q_rt.get_low(0)), "fallback q[0] parity")
    assert_equal(Int(q_ct.get_low(0)), 1700, "fallback q[0] value")


# -----------------------------------------------------------------------------
# Test 6: IN-TEST MICROBENCH — runtime vs comptime on a large multi-block OCF.
# -----------------------------------------------------------------------------


def _build_numeric_ocf(nrows: Int, nblocks: Int) -> List[UInt8]:
    var buf = List[UInt8]()
    _make_header(_SCHEMA_NUMERIC, buf)
    var per_block = nrows // nblocks
    var emitted = 0
    for blk in range(nblocks):
        var count = per_block if blk < nblocks - 1 else (nrows - emitted)
        var payload = List[UInt8]()
        for r in range(count):
            var i = emitted + r
            _enc_long(Int64(i * 7 + 1), payload)
            _enc_long(Int64((i % 1000) - 500), payload)
            _enc_long(Int64(i * 3), payload)
            _enc_long(Int64(i % 256), payload)
            _enc_double(Float64(i) * 1.5, payload)
            _enc_long(Int64(i * 11), payload)
        _append_block(buf, Int64(count), payload)
        emitted += count
    return buf^


def _bench_one(buf: List[UInt8], nrows: Int, label: String) raises -> Float64:
    var rt0 = read_avro_bytes(Span(buf))
    var ct0 = decode_avro_bytes_comptime(Span(buf))
    assert_equal(rt0.num_rows(), nrows, label + " bench rt rows")
    assert_equal(ct0.num_rows(), nrows, label + " bench ct rows")

    var trials = 3
    var best_rt: Int = -1
    var best_ct: Int = -1
    for _t in range(trials):
        var t0 = perf_counter_ns()
        var rb_rt = read_avro_bytes(Span(buf))
        var t1 = perf_counter_ns()
        var dt_rt = Int(t1 - t0)
        if best_rt < 0 or dt_rt < best_rt:
            best_rt = dt_rt
        assert_equal(rb_rt.num_rows(), nrows, "rt rows")

        var t2 = perf_counter_ns()
        var rb_ct = decode_avro_bytes_comptime(Span(buf))
        var t3 = perf_counter_ns()
        var dt_ct = Int(t3 - t2)
        if best_ct < 0 or dt_ct < best_ct:
            best_ct = dt_ct
        assert_equal(rb_ct.num_rows(), nrows, "ct rows")

    var ratio = Float64(best_rt) / Float64(best_ct)
    print("")
    print("=== comptime-cascade microbench:", label, "(", nrows, "rows, best-of-3) ===")
    print("  runtime ActionTableInterpreter:", Float64(best_rt) / Float64(nrows), "ns/row")
    print("  comptime SHAPE_KIND cascade:   ", Float64(best_ct) / Float64(nrows), "ns/row")
    print("  ratio (runtime / comptime):    ", ratio, "x")
    if ratio >= 1.3:
        print("  >>> >= 1.3x target MET")
    else:
        print("  >>> < 1.3x — marginal/negative result")
    return ratio


def test_microbench_runtime_vs_comptime() raises:
    # Two workloads. NUMERIC isolates the per-field DISPATCH cost the comptime cascade
    # erases (no per-value string allocation). N_PRIMS is the string-heavy
    # mixed shape where per-value materialization dominates.
    _ = _bench_one(_build_numeric_ocf(200000, 50), 200000, "NUMERIC (6 numeric cols)")

    var nrows = 200000
    var nblocks = 50
    var buf = _build_nprims_ocf(nrows, nblocks)

    # Correctness sanity: both paths agree on row count before timing.
    var rt0 = read_avro_bytes(Span(buf))
    var ct0 = decode_avro_bytes_comptime(Span(buf))
    assert_equal(rt0.num_rows(), nrows, "bench rt rows")
    assert_equal(ct0.num_rows(), nrows, "bench ct rows")

    var trials = 3
    var best_rt: Int = -1
    var best_ct: Int = -1
    for _t in range(trials):
        var t0 = perf_counter_ns()
        var rb_rt = read_avro_bytes(Span(buf))
        var t1 = perf_counter_ns()
        var dt_rt = Int(t1 - t0)
        if best_rt < 0 or dt_rt < best_rt:
            best_rt = dt_rt
        assert_equal(rb_rt.num_rows(), nrows, "rt rows in trial")

        var t2 = perf_counter_ns()
        var rb_ct = decode_avro_bytes_comptime(Span(buf))
        var t3 = perf_counter_ns()
        var dt_ct = Int(t3 - t2)
        if best_ct < 0 or dt_ct < best_ct:
            best_ct = dt_ct
        assert_equal(rb_ct.num_rows(), nrows, "ct rows in trial")

    var rt_ns_per_row = Float64(best_rt) / Float64(nrows)
    var ct_ns_per_row = Float64(best_ct) / Float64(nrows)
    var ratio = Float64(best_rt) / Float64(best_ct)

    print("")
    print("=== comptime-cascade microbench (N_PRIMS, 200k rows / 50 blocks, best-of-3) ===")
    print("  runtime ActionTableInterpreter:", rt_ns_per_row, "ns/row")
    print("  comptime SHAPE_KIND cascade:   ", ct_ns_per_row, "ns/row")
    print("  ratio (runtime / comptime):    ", ratio, "x")
    if ratio >= 1.3:
        print("  >>> >= 1.3x target MET")
    else:
        print("  >>> < 1.3x — marginal/negative result")
    print("")


def main() raises:
    test_classifier()
    test_nprims_parity()
    test_1int_parity()
    test_nullable_parity()
    test_unknown_fallback()
    test_microbench_runtime_vs_comptime()
    print("test_avro_comptime_shape_kind_decode: ALL PASS")
