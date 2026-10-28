# FLOAT64 keys of the composite join follow the float model of
# `docs/design/query_semantics.md` 3.9, as DuckDB does: every NaN equals every
# NaN (whatever its sign and payload) and `-0.0` equals `+0.0`; a NULL key is
# not a NaN and still matches nothing. Every join kind is checked: INNER, LEFT,
# SEMI, ANTI, RIGHT and FULL, each over a two-key (FLOAT64, INT64) join so the
# composite hash and the per-key equality both see the float slot.

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion

from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key import (
    _NAN_SENTINEL_BITS,
    _canonicalize_float64_for_hash,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_filter import (
    multi_key_probe_anti,
    multi_key_probe_semi,
)
from komira_op_join_probe.join_multi_key_outer import (
    multi_key_probe_full_into,
    multi_key_probe_right_into,
)


def _f64(bits: UInt64) -> Float64:
    return bitcast[DType.float64](bits)


def _qnan() -> Float64:
    """The quiet NaN arithmetic produces."""
    return _f64(UInt64(0x7FF8000000000000))


def _neg_nan() -> Float64:
    """A NaN with the sign bit set."""
    return _f64(UInt64(0xFFF8000000000000))


def _payload_nan() -> Float64:
    """A signalling NaN with a payload."""
    return _f64(UInt64(0x7FF0000000000001))


def _neg_zero() -> Float64:
    return _f64(UInt64(0x8000000000000000))


def _sentinel_nan() -> Float64:
    """The NaN whose bits are the NULL sentinel's."""
    return _f64(UInt64(_NAN_SENTINEL_BITS))


def _batch(values: List[Float64], nulls: List[Bool]) raises -> RecordBatch:
    """A (k0 FLOAT64, k1 INT64 = 7) batch; `nulls[i]` makes k0 NULL."""
    var n = len(values)
    var a = PrimitiveArray[DType.float64].allocate_nullable(n)
    var c = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set(i, values[i])
        if nulls[i]:
            a._set_null(i)
        c.set(i, Int64(7))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.FLOAT64, True))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.float64](a^))
    b.add_column(Column.from_primitive[DType.int64](c^))
    return b.build(sb.build())


def _names() -> List[String]:
    var l = List[String]()
    l.append(String("k0"))
    l.append(String("k1"))
    return l^


def _builder(imm build: RecordBatch) raises -> MultiKeyHashJoinBuilder:
    return MultiKeyHashJoinBuilder.build(
        extract_join_key_columns_serial(build, _names())
    )


def _sorted(imm bm: List[Int], imm pm: List[Int]) -> List[Int]:
    """The pairs as `[b0, p0, b1, p1, ...]`, ordered by (build, probe)."""
    var order = List[Int]()
    for i in range(len(bm)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0:
            var a = order[j - 1]
            var b = order[j]
            if not (bm[a] > bm[b] or (bm[a] == bm[b] and pm[a] > pm[b])):
                break
            order[j - 1] = b
            order[j] = a
            j -= 1
    var out = List[Int]()
    for i in range(len(order)):
        out.append(bm[order[i]])
        out.append(pm[order[i]])
    return out^


def _assert_flat(imm got: List[Int], imm want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": pair count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": element " + String(i))


def test_key_slot_is_canonical() raises:
    """Every NaN renders to one slot, which is not the NULL sentinel; both
    zeros render to `+0.0`'s slot; any other value to its own bits."""
    var q = _canonicalize_float64_for_hash(_qnan())
    assert_equal(_canonicalize_float64_for_hash(_neg_nan()), q)
    assert_equal(_canonicalize_float64_for_hash(_payload_nan()), q)
    assert_equal(_canonicalize_float64_for_hash(_sentinel_nan()), q)
    assert_true(q != _NAN_SENTINEL_BITS, "a NaN key must not read as NULL")
    assert_equal(_canonicalize_float64_for_hash(_neg_zero()), Int64(0))
    assert_equal(_canonicalize_float64_for_hash(Float64(0.0)), Int64(0))
    assert_equal(
        _canonicalize_float64_for_hash(Float64(1.5)),
        Int64(bitcast[DType.int64](Float64(1.5))),
    )


def test_inner_nan_matches_every_nan() raises:
    """Build [NaN, -NaN, payload NaN, 1.0]; probe [qNaN, 1.0, 2.0]: the probe
    NaN matches all three build NaNs."""
    var build = _batch(
        [_qnan(), _neg_nan(), _payload_nan(), Float64(1.0)],
        [False, False, False, False],
    )
    var probe = _batch([_qnan(), Float64(1.0), Float64(2.0)], [False, False, False])
    var b = _builder(build)
    var bm = List[Int]()
    var pm = List[Int]()
    b.probe_inner_into(extract_join_key_columns_serial(probe, _names()), bm, pm)
    _assert_flat(_sorted(bm, pm), [0, 0, 1, 0, 2, 0, 3, 1], "INNER NaN")


def test_inner_signed_zeros_match() raises:
    """Build [-0.0, 3.0]; probe [+0.0, -0.0, -3.0]: both probe zeros match the
    build zero; -3.0 matches nothing."""
    var build = _batch([_neg_zero(), Float64(3.0)], [False, False])
    var probe = _batch(
        [Float64(0.0), _neg_zero(), Float64(-3.0)], [False, False, False]
    )
    var b = _builder(build)
    var bm = List[Int]()
    var pm = List[Int]()
    b.probe_inner_into(extract_join_key_columns_serial(probe, _names()), bm, pm)
    _assert_flat(_sorted(bm, pm), [0, 0, 0, 1], "INNER signed zero")


def test_nan_is_not_null_left_semi_anti() raises:
    """Build [NaN, NULL]; probe [NaN, NULL, sentinel-bits NaN]. Both probe NaNs
    match build row 0 (the sentinel-bits NaN is a NaN, not a NULL); the NULL
    probe row matches nothing, not even the NULL build row."""
    var build = _batch([_qnan(), Float64(0.0)], [False, True])
    var probe = _batch(
        [_neg_nan(), Float64(0.0), _sentinel_nan()], [False, True, False]
    )
    var b = _builder(build)
    var bm = List[Int]()
    var pm = List[Int]()
    b.probe_left_into(extract_join_key_columns_serial(probe, _names()), bm, pm)
    _assert_flat(_sorted(bm, pm), [-1, 1, 0, 0, 0, 2], "LEFT")
    var semi = multi_key_probe_semi(
        b, extract_join_key_columns_serial(probe, _names())
    )
    assert_equal(len(semi), 2, "SEMI keeps both NaN probe rows")
    assert_equal(semi[0], 0)
    assert_equal(semi[1], 2)
    var anti = multi_key_probe_anti(
        b, extract_join_key_columns_serial(probe, _names())
    )
    assert_equal(len(anti), 1, "ANTI keeps only the NULL probe row")
    assert_equal(anti[0], 1)


def test_right_and_full_nan_build_row_is_matched() raises:
    """Build [NaN, 5.0]; probe [-NaN, 6.0]. RIGHT: the NaN build row is
    matched, 5.0 unmatched. FULL adds the unmatched probe row 6.0."""
    var build = _batch([_payload_nan(), Float64(5.0)], [False, False])
    var probe = _batch([_neg_nan(), Float64(6.0)], [False, False])
    var b = _builder(build)
    var bm = List[Int]()
    var pm = List[Int]()
    multi_key_probe_right_into(
        b, extract_join_key_columns_serial(probe, _names()), bm, pm
    )
    _assert_flat(_sorted(bm, pm), [0, 0, 1, -1], "RIGHT")
    var fb = List[Int]()
    var fp = List[Int]()
    multi_key_probe_full_into(
        b, extract_join_key_columns_serial(probe, _names()), fb, fp
    )
    _assert_flat(_sorted(fb, fp), [-1, 1, 0, 0, 1, -1], "FULL")


def main() raises:
    var suite = TestSuite()
    suite.test[test_key_slot_is_canonical]()
    suite.test[test_inner_nan_matches_every_nan]()
    suite.test[test_inner_signed_zeros_match]()
    suite.test[test_nan_is_not_null_left_semi_anti]()
    suite.test[test_right_and_full_nan_build_row_is_matched]()
    suite^.run()
