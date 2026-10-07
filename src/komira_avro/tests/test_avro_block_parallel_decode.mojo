# =============================================================================
# test_avro_block_parallel_decode.mojo — block-parallel decode.
# =============================================================================
#
# Acceptance:
#   1. CROSS-THREAD ORDER PARITY (the correctness gate): a multi-block OCF file
#      decoded in PARALLEL (read_avro_bytes_parallel) produces row-for-row
#      IDENTICAL output (same order, same values, same null bitmap) to the
#      SERIAL decode (read_avro_bytes). Tested with >= 8 blocks so multiple
#      workers actually run. Asserted column-by-column, row-by-row, incl nulls.
#      MUST FAIL if reorder is wrong or a race corrupts data.
#   2. IN-TEST PARALLEL SPEEDUP: decode a many-block OCF buffer serial vs
#      parallel; report the multi-core speedup ratio on linux x86_64.
#   3. SINGLE-THREAD REGRESSION: the 1-block / serial-fallback path must not
#      regress (parallel path on a 1-block file routes to the serial path).
#
# fastavro is unavailable, so fixtures are hand-emitted as the byte-exact
# inverse of the decoder (the decoder-test pattern). The encoders here are
# copied from test_avro_comptime_shape_kind_decode.mojo for self-containment.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true
from std.sys import num_physical_cores
from std.time import perf_counter_ns

from komira_avro import (
    read_avro_bytes,
    read_avro_bytes_parallel,
    OCF_SYNC_LEN,
)
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

# All-non-null flat primitive struct → SHAPE_KIND_STRUCT_OF_N_PRIMS (hot).
comptime _SCHEMA_N_PRIMS = String(
    '{"type":"record","name":"NPrims","fields":['
    '{"name":"a","type":"long"},'
    '{"name":"b","type":"int"},'
    '{"name":"c","type":"double"},'
    '{"name":"d","type":"string"}]}'
)

# All-nullable flat primitive struct → SHAPE_KIND_STRUCT_OF_NULLABLE_PRIMS (hot).
comptime _SCHEMA_NULLABLE = String(
    '{"type":"record","name":"NullPrims","fields":['
    '{"name":"a","type":["null","long"]},'
    '{"name":"b","type":["null","string"]},'
    '{"name":"c","type":["int","null"]}]}'
)

# Decimal-bearing → SHAPE_KIND_UNKNOWN (runtime-fallback path under parallel).
comptime _SCHEMA_DECIMAL = String(
    '{"type":"record","name":"WithDec","fields":['
    '{"name":"a","type":"long"},'
    '{"name":"q","type":{"type":"bytes","logicalType":"decimal",'
    '"precision":15,"scale":2}}]}'
)


# -----------------------------------------------------------------------------
# Fixture builders.
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


def _build_nullable_ocf(nrows: Int, nblocks: Int) -> List[UInt8]:
    var buf = List[UInt8]()
    _make_header(_SCHEMA_NULLABLE, buf)
    var per_block = nrows // nblocks
    var emitted = 0
    for blk in range(nblocks):
        var count = per_block if blk < nblocks - 1 else (nrows - emitted)
        var payload = List[UInt8]()
        for r in range(count):
            var i = emitted + r
            # a: union[null,long] — null on every 3rd row.
            if i % 3 == 0:
                _enc_long(Int64(0), payload)  # null branch
            else:
                _enc_long(Int64(1), payload)  # long branch
                _enc_long(Int64(i * 13 - 7), payload)
            # b: union[null,string] — null on every 5th row.
            if i % 5 == 0:
                _enc_long(Int64(0), payload)
            else:
                _enc_long(Int64(1), payload)
                _enc_str(String("s") + String(i % 41), payload)
            # c: union[int,null] — null on every 7th row (tag 1 == null here).
            if i % 7 == 0:
                _enc_long(Int64(1), payload)  # null branch (second)
            else:
                _enc_long(Int64(0), payload)  # int branch (first)
                _enc_long(Int64((i % 200) - 100), payload)
        _append_block(buf, Int64(count), payload)
        emitted += count
    return buf^


def _build_decimal_ocf(nrows: Int, nblocks: Int) -> List[UInt8]:
    var buf = List[UInt8]()
    _make_header(_SCHEMA_DECIMAL, buf)
    var per_block = nrows // nblocks
    var emitted = 0
    for blk in range(nblocks):
        var count = per_block if blk < nblocks - 1 else (nrows - emitted)
        var payload = List[UInt8]()
        for r in range(count):
            var i = emitted + r
            _enc_long(Int64(i * 3 + 2), payload)  # a: long
            var v = (i * 137 + 11) % 30000
            var be = List[UInt8]()
            be.append(UInt8((v >> 8) & 0xFF))
            be.append(UInt8(v & 0xFF))
            _enc_bytes(be, payload)  # q: decimal over bytes
        _append_block(buf, Int64(count), payload)
        emitted += count
    return buf^


# -----------------------------------------------------------------------------
# Parity assertion helpers.
# -----------------------------------------------------------------------------


def _assert_shape_equal(s: RecordBatch, p: RecordBatch, label: String) raises:
    assert_equal(s.num_rows(), p.num_rows(), label + ": num_rows")
    assert_equal(s.num_columns(), p.num_columns(), label + ": num_columns")


# -----------------------------------------------------------------------------
# Test 1: N_PRIMS (hot, all-non-null) cross-thread order parity, >= 8 blocks.
# -----------------------------------------------------------------------------


def test_nprims_order_parity() raises:
    # 12 blocks * many rows: exercises multiple workers + the in-order concat.
    var nrows = 4000
    var nblocks = 12
    var buf = _build_nprims_ocf(nrows, nblocks)

    var serial = read_avro_bytes(Span(buf))
    var parallel = read_avro_bytes_parallel(Span(buf))  # default worker count

    _assert_shape_equal(serial, parallel, "N_PRIMS")
    assert_equal(parallel.num_rows(), nrows, "N_PRIMS parallel rows")
    assert_equal(parallel.num_columns(), 4, "N_PRIMS parallel cols")

    # a: long — row-for-row identical AND in the same order.
    var a_s = serial.column_at(0).as_primitive[DType.int64]()
    var a_p = parallel.column_at(0).as_primitive[DType.int64]()
    for i in range(nrows):
        assert_equal(Int(a_p.get(i)), Int(a_s.get(i)), "a parity row " + String(i))
    # Spot-check absolute values (catches a silent reorder that happens to be
    # self-consistent between the two paths).
    assert_equal(Int(a_p.get(0)), 1, "a[0]==1")
    assert_equal(Int(a_p.get(nrows - 1)), (nrows - 1) * 7 + 1, "a[last]")

    # b: int
    var b_s = serial.column_at(1).as_primitive[DType.int32]()
    var b_p = parallel.column_at(1).as_primitive[DType.int32]()
    for i in range(nrows):
        assert_equal(Int(b_p.get(i)), Int(b_s.get(i)), "b parity row " + String(i))

    # c: double
    var c_s = serial.column_at(2).as_primitive[DType.float64]()
    var c_p = parallel.column_at(2).as_primitive[DType.float64]()
    for i in range(nrows):
        assert_equal(c_p.get(i), c_s.get(i), "c parity row " + String(i))

    # d: string
    var d_s = serial.column_at(3).as_string()
    var d_p = parallel.column_at(3).as_string()
    for i in range(nrows):
        assert_equal(d_p.get(i), d_s.get(i), "d parity row " + String(i))


# -----------------------------------------------------------------------------
# Test 2: NULLABLE (hot, with nulls) cross-thread order + null-bitmap parity.
# -----------------------------------------------------------------------------


def test_nullable_order_parity() raises:
    var nrows = 3500
    var nblocks = 10
    var buf = _build_nullable_ocf(nrows, nblocks)

    var serial = read_avro_bytes(Span(buf))
    var parallel = read_avro_bytes_parallel(Span(buf))

    _assert_shape_equal(serial, parallel, "NULLABLE")
    assert_equal(parallel.num_rows(), nrows, "NULLABLE rows")

    # Null bitmap parity per column.
    assert_equal(
        parallel.column_at(0).null_count(),
        serial.column_at(0).null_count(),
        "a null_count parity",
    )
    assert_equal(
        parallel.column_at(1).null_count(),
        serial.column_at(1).null_count(),
        "b null_count parity",
    )
    assert_equal(
        parallel.column_at(2).null_count(),
        serial.column_at(2).null_count(),
        "c null_count parity",
    )

    # a: nullable long — value + null position parity, in order.
    var a_s = serial.column_at(0).as_primitive[DType.int64]()
    var a_p = parallel.column_at(0).as_primitive[DType.int64]()
    for i in range(nrows):
        assert_equal(a_p.is_null(i), a_s.is_null(i), "a null-pos parity row " + String(i))
        if not a_p.is_null(i):
            assert_equal(Int(a_p.get(i)), Int(a_s.get(i)), "a val parity row " + String(i))

    # b: nullable string
    var b_s = serial.column_at(1).as_string()
    var b_p = parallel.column_at(1).as_string()
    for i in range(nrows):
        assert_equal(b_p.is_null(i), b_s.is_null(i), "b null-pos parity row " + String(i))
        if not b_p.is_null(i):
            assert_equal(b_p.get(i), b_s.get(i), "b val parity row " + String(i))

    # c: nullable int
    var c_s = serial.column_at(2).as_primitive[DType.int32]()
    var c_p = parallel.column_at(2).as_primitive[DType.int32]()
    for i in range(nrows):
        assert_equal(c_p.is_null(i), c_s.is_null(i), "c null-pos parity row " + String(i))
        if not c_p.is_null(i):
            assert_equal(Int(c_p.get(i)), Int(c_s.get(i)), "c val parity row " + String(i))


# -----------------------------------------------------------------------------
# Test 3: UNKNOWN shape (decimal) order parity — parallel uses the runtime
# ActionTableInterpreter fallback PER WORKER; output must still match serial.
# -----------------------------------------------------------------------------


def test_unknown_fallback_order_parity() raises:
    var nrows = 2000
    var nblocks = 8
    var buf = _build_decimal_ocf(nrows, nblocks)

    var serial = read_avro_bytes(Span(buf))
    var parallel = read_avro_bytes_parallel(Span(buf))

    _assert_shape_equal(serial, parallel, "DECIMAL-fallback")
    assert_equal(parallel.num_rows(), nrows, "DECIMAL rows")

    var a_s = serial.column_at(0).as_primitive[DType.int64]()
    var a_p = parallel.column_at(0).as_primitive[DType.int64]()
    for i in range(nrows):
        assert_equal(Int(a_p.get(i)), Int(a_s.get(i)), "a parity row " + String(i))

    var q_s = serial.column_at(1).as_decimal128()
    var q_p = parallel.column_at(1).as_decimal128()
    for i in range(nrows):
        assert_equal(Int(q_p.get_low(i)), Int(q_s.get_low(i)), "q low parity row " + String(i))


# -----------------------------------------------------------------------------
# Test 4: single-block / forced-serial regression — parallel must equal serial.
# -----------------------------------------------------------------------------


def test_single_block_fallback() raises:
    # 1-block file: the parallel driver's threshold gate routes to the serial
    # path. Output must be byte-identical to read_avro_bytes.
    var buf = _build_nprims_ocf(50, 1)
    var serial = read_avro_bytes(Span(buf))
    var parallel = read_avro_bytes_parallel(Span(buf))
    _assert_shape_equal(serial, parallel, "1-block")
    var a_s = serial.column_at(0).as_primitive[DType.int64]()
    var a_p = parallel.column_at(0).as_primitive[DType.int64]()
    for i in range(50):
        assert_equal(Int(a_p.get(i)), Int(a_s.get(i)), "1-block a parity")

    # n_workers=1 forced serial on a multi-block file: also must equal serial.
    var buf2 = _build_nprims_ocf(500, 8)
    var serial2 = read_avro_bytes(Span(buf2))
    var forced = read_avro_bytes_parallel(Span(buf2), 1)
    _assert_shape_equal(serial2, forced, "forced-serial")
    var b_s = serial2.column_at(1).as_primitive[DType.int32]()
    var b_p = forced.column_at(1).as_primitive[DType.int32]()
    for i in range(500):
        assert_equal(Int(b_p.get(i)), Int(b_s.get(i)), "forced-serial b parity")


# -----------------------------------------------------------------------------
# Test 5: IN-TEST SPEEDUP signal — serial vs parallel on a many-block buffer.
# -----------------------------------------------------------------------------


def test_parallel_speedup_signal() raises:
    # Many blocks so the work distributes across the available cores. NUMERIC-
    # heavy + string mix is CPU-bound on decode (the per-thread decode cost is
    # what the parallel driver multiplies across cores).
    var nrows = 400000
    var nblocks = 64
    var buf = _build_nprims_ocf(nrows, nblocks)
    var ncores = num_physical_cores()

    # Correctness sanity before timing.
    var s0 = read_avro_bytes(Span(buf))
    var p0 = read_avro_bytes_parallel(Span(buf))
    assert_equal(s0.num_rows(), nrows, "speedup serial rows")
    assert_equal(p0.num_rows(), nrows, "speedup parallel rows")

    var trials = 3
    var best_serial: Int = -1
    var best_parallel: Int = -1
    for _t in range(trials):
        var t0 = perf_counter_ns()
        var rb_s = read_avro_bytes(Span(buf))
        var t1 = perf_counter_ns()
        var dt_s = Int(t1 - t0)
        if best_serial < 0 or dt_s < best_serial:
            best_serial = dt_s
        assert_equal(rb_s.num_rows(), nrows, "serial trial rows")

        var t2 = perf_counter_ns()
        var rb_p = read_avro_bytes_parallel(Span(buf))
        var t3 = perf_counter_ns()
        var dt_p = Int(t3 - t2)
        if best_parallel < 0 or dt_p < best_parallel:
            best_parallel = dt_p
        assert_equal(rb_p.num_rows(), nrows, "parallel trial rows")

    var ratio = Float64(best_serial) / Float64(best_parallel)
    print("")
    print("=== block-parallel speedup (", nrows, "rows /", nblocks, "blocks, best-of-3) ===")
    print("  physical cores:        ", ncores)
    print("  serial   read_avro_bytes:          ", Float64(best_serial) / Float64(nrows), "ns/row")
    print("  parallel read_avro_bytes_parallel: ", Float64(best_parallel) / Float64(nrows), "ns/row")
    print("  speedup (serial / parallel):       ", ratio, "x")
    if ratio >= 1.5:
        print("  >>> >= 1.5x — meaningful multi-core speedup")
    else:
        print("  >>> < 1.5x — marginal speedup")
    print("")
    # The parallel path must never be CORRECTNESS-worse; speedup is a signal,
    # not a hard gate (CPU contention on a shared CI box can suppress it).
    assert_true(ratio > 0.0, "ratio computed")


def main() raises:
    test_nprims_order_parity()
    test_nullable_order_parity()
    test_unknown_fallback_order_parity()
    test_single_block_fallback()
    test_parallel_speedup_signal()
    print("test_avro_block_parallel_decode: ALL PASS")
