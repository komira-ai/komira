# The composite join's NULL keys: a NULL key of every numeric arm (INT64,
# INT32, FLOAT64, numeric dictionary) matches nothing, on the build side and on
# the probe side, whatever value sits under its cleared validity bit; LEFT
# keeps a NULL-keyed probe row unmatched; the widened key slots keep the
# source's validity; and the sentinel's one known collision.

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion

from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key import _NAN_SENTINEL_BITS
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)


comptime I64 = DType.int64
comptime I32 = DType.int32
comptime F64 = DType.float64

comptime _TRAP: Int64 = 42

comptime _K1: Int64 = 7


def _i64_keys(
    var values: List[Int64], var null_at: List[Int]
) raises -> PrimitiveArray[I64]:
    """An INT64 key column holding `values[i]` in the DATA slot REGARDLESS of
    validity, NULL at each index in `null_at`. A column with an empty `null_at`
    still carries an (all-valid) bitmap — see `_i64_keys_no_bitmap` for the
    genuinely non-nullable shape, which takes a different arm.
    """
    var n = len(values)
    var arr = PrimitiveArray[I64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    for k in range(len(null_at)):
        arr._set_null(null_at[k])
    return arr^


def _i64_keys_no_bitmap(var values: List[Int64]) raises -> PrimitiveArray[I64]:
    """An INT64 key column with NO validity bitmap at all — the pass-through
    pass-through arm of the extract.
    """
    var n = len(values)
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    return arr^


def _i32_keys(
    var values: List[Int32], var null_at: List[Int]
) raises -> PrimitiveArray[I32]:
    """The INT32 twin of `_i64_keys` — the arm that used to widen into a
    NON-NULLABLE Int64 array.
    """
    var n = len(values)
    var arr = PrimitiveArray[I32].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    for k in range(len(null_at)):
        arr._set_null(null_at[k])
    return arr^


def _f64_keys(
    var values: List[Float64], var null_at: List[Int]
) raises -> PrimitiveArray[F64]:
    """The FLOAT64 twin. NaN rows are written as values, not as nulls: a NULL
    float matches nothing, a NaN float is a key like any other.
    """
    var n = len(values)
    var arr = PrimitiveArray[F64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, values[i])
    for k in range(len(null_at)):
        arr._set_null(null_at[k])
    return arr^


def _k1_col(n: Int) raises -> Column[HeapRegion]:
    """The constant INT64 second key: `_K1` on every row, never null."""
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, _K1)
    return Column.from_primitive[I64](arr^)


def _batch2(
    var k0: Column[HeapRegion], k0_type: ArrowType, n: Int
) raises -> RecordBatch:
    """A two-key composite batch: `k0` (under test) + the constant `k1`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", k0_type, True))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(k0^)
    b.add_column(_k1_col(n))
    return b.build(sb.build())


def _key_names() raises -> List[String]:
    var l = List[String]()
    l.append(String("k0"))
    l.append(String("k1"))
    return l^


def _inner_pairs(
    imm build: RecordBatch, imm probe: RecordBatch
) raises -> List[Int]:
    """Run the composite INNER probe and return the matches flattened as
    `[build_idx, probe_idx, ...]` so a test can assert an exact pair multiset
    without inventing an emit ORDER the kernel never promised.
    """
    var names = _key_names()
    var bkeys = extract_join_key_columns_serial(build, names)
    var builder = MultiKeyHashJoinBuilder.build(bkeys^)
    var pkeys = extract_join_key_columns_serial(probe, names)
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_inner_into(pkeys, bm, pm)
    return _sorted_pairs(bm, pm)


def _sorted_pairs(imm bm: List[Int], imm pm: List[Int]) raises -> List[Int]:
    var order = List[Int]()
    for i in range(len(bm)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0:
            var a = order[j - 1]
            var b = order[j]
            var swap = (bm[a] > bm[b]) or (bm[a] == bm[b] and pm[a] > pm[b])
            if not swap:
                break
            order[j - 1] = b
            order[j] = a
            j -= 1
    var out = List[Int]()
    for i in range(len(order)):
        out.append(bm[order[i]])
        out.append(pm[order[i]])
    return out^


def _assert_pairs(
    imm got: List[Int], imm want: List[Int], imm what: String
) raises:
    assert_equal(
        len(got) // 2,
        len(want) // 2,
        what
        + ": wrong MATCH COUNT (extra rows joined: a NULL key must match"
        " nothing)",
    )
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": pair element " + String(i))


def _pairs(var flat: List[Int]) -> List[Int]:
    return flat^


def test_int64_null_build_key_is_not_a_match_target() raises:
    """BUILD row 1 is NULL and its data slot holds `_TRAP` (42); probe row 0 is
    a REAL 42. Build row 2 (55) matches probe row 1 legitimately.
    """
    var bvals = List[Int64]()
    bvals.append(Int64(10))
    bvals.append(_TRAP)
    bvals.append(Int64(55))
    var bnull = List[Int]()
    bnull.append(1)
    var build = _batch2(
        Column.from_primitive[I64](_i64_keys(bvals^, bnull^)),
        ArrowType.INT64,
        3,
    )

    var pvals = List[Int64]()
    pvals.append(_TRAP)
    pvals.append(Int64(55))
    var probe = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(pvals^)),
        ArrowType.INT64,
        2,
    )

    var want = List[Int]()
    want.append(2)
    want.append(1)
    _assert_pairs(
        _inner_pairs(build, probe), want, String("int64 null BUILD key")
    )


def test_int64_null_probe_key_matches_nothing() raises:
    """PROBE row 0 is NULL with `_TRAP` under the cleared bit; build row 0 is a
    REAL 42.
    """
    var bvals = List[Int64]()
    bvals.append(_TRAP)
    bvals.append(Int64(55))
    var build = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(bvals^)),
        ArrowType.INT64,
        2,
    )

    var pvals = List[Int64]()
    pvals.append(_TRAP)
    pvals.append(Int64(55))
    var pnull = List[Int]()
    pnull.append(0)
    var probe = _batch2(
        Column.from_primitive[I64](_i64_keys(pvals^, pnull^)),
        ArrowType.INT64,
        2,
    )

    var want = List[Int]()
    want.append(1)
    want.append(1)
    _assert_pairs(
        _inner_pairs(build, probe), want, String("int64 null PROBE key")
    )


def test_int32_null_build_key_is_not_a_match_target() raises:
    """The INT32 twin of the INT64 NULL build key: the INT32 arm widens into a
    fresh array, which must still read the source's validity.
    """
    var bvals = List[Int32]()
    bvals.append(Int32(10))
    bvals.append(Int32(42))
    bvals.append(Int32(55))
    var bnull = List[Int]()
    bnull.append(1)
    var build = _batch2(
        Column.from_primitive[I32](_i32_keys(bvals^, bnull^)),
        ArrowType.INT32,
        3,
    )

    var pvals = List[Int32]()
    pvals.append(Int32(42))
    pvals.append(Int32(55))
    var pnull = List[Int]()
    var probe = _batch2(
        Column.from_primitive[I32](_i32_keys(pvals^, pnull^)),
        ArrowType.INT32,
        2,
    )

    var want = List[Int]()
    want.append(2)
    want.append(1)
    _assert_pairs(
        _inner_pairs(build, probe), want, String("int32 null BUILD key")
    )


def test_int32_null_probe_key_matches_nothing() raises:
    """The INT32 twin of the INT64 NULL probe key."""
    var bvals = List[Int32]()
    bvals.append(Int32(42))
    bvals.append(Int32(55))
    var bnull = List[Int]()
    var build = _batch2(
        Column.from_primitive[I32](_i32_keys(bvals^, bnull^)),
        ArrowType.INT32,
        2,
    )

    var pvals = List[Int32]()
    pvals.append(Int32(42))
    pvals.append(Int32(55))
    var pnull = List[Int]()
    pnull.append(0)
    var probe = _batch2(
        Column.from_primitive[I32](_i32_keys(pvals^, pnull^)),
        ArrowType.INT32,
        2,
    )

    var want = List[Int]()
    want.append(1)
    want.append(1)
    _assert_pairs(
        _inner_pairs(build, probe), want, String("int32 null PROBE key")
    )


def test_float64_null_key_matches_nothing_and_nan_matches_nan() raises:
    """Build: [42.0 NULL, 55.0, NaN]. Probe: [42.0 NULL, 55.0, NaN]. The NULL
    rows match nothing; 55.0 matches 55.0 and, under the float model, NaN
    matches NaN."""
    var bvals = List[Float64]()
    bvals.append(Float64(42.0))
    bvals.append(Float64(55.0))
    bvals.append(Float64(0.0) / Float64(0.0))
    var bnull = List[Int]()
    bnull.append(0)
    var build = _batch2(
        Column.from_primitive[F64](_f64_keys(bvals^, bnull^)),
        ArrowType.FLOAT64,
        3,
    )

    var pvals = List[Float64]()
    pvals.append(Float64(42.0))
    pvals.append(Float64(55.0))
    pvals.append(Float64(0.0) / Float64(0.0))
    var pnull = List[Int]()
    pnull.append(0)
    var probe = _batch2(
        Column.from_primitive[F64](_f64_keys(pvals^, pnull^)),
        ArrowType.FLOAT64,
        3,
    )

    var want = List[Int]()
    want.append(1)
    want.append(1)
    want.append(2)
    want.append(2)
    _assert_pairs(
        _inner_pairs(build, probe), want, String("float64 null key, NaN key")
    )


def _numeric_dict_col(
    var codes: List[Int32], var null_at: List[Int], var values: List[Int64]
) raises -> Column[HeapRegion]:
    """A numeric dict-VECTOR column: per-row codes (nullable) into `values`.
    `resolve_numeric_dict_to_flat` preserves the CODES' validity bitmap, which
    is what the extract arm used to ignore.
    """
    var n = len(codes)
    var arr = PrimitiveArray[I32].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, codes[i])
    for k in range(len(null_at)):
        arr._set_null(null_at[k])
    return Column.from_numeric_dict[I32, I64](arr^, values^)


def test_numeric_dict_null_key_matches_nothing() raises:
    """Build codes resolve to [10, 42(NULL), 55]; probe to [42, 55]."""
    var dvals = List[Int64]()
    dvals.append(Int64(10))
    dvals.append(_TRAP)
    dvals.append(Int64(55))

    var bcodes = List[Int32]()
    bcodes.append(Int32(0))
    bcodes.append(Int32(1))
    bcodes.append(Int32(2))
    var bnull = List[Int]()
    bnull.append(1)
    var build = _batch2(
        _numeric_dict_col(bcodes^, bnull^, dvals.copy()),
        ArrowType.DICTIONARY,
        3,
    )

    var pcodes = List[Int32]()
    pcodes.append(Int32(1))
    pcodes.append(Int32(2))
    var pnull = List[Int]()
    var probe = _batch2(
        _numeric_dict_col(pcodes^, pnull^, dvals.copy()),
        ArrowType.DICTIONARY,
        2,
    )

    var want = List[Int]()
    want.append(2)
    want.append(1)
    _assert_pairs(
        _inner_pairs(build, probe), want, String("numeric-dict null key")
    )


def test_int32_widened_key_slots_preserve_validity() raises:
    """The widened INT32 key slots carry the source's validity bitmap, so the
    produced Int64 column is truthful about its nulls (a value assertion
    cannot see this).
    """
    var vals = List[Int32]()
    vals.append(Int32(10))
    vals.append(Int32(42))
    vals.append(Int32(55))
    vals.append(Int32(60))
    var nulls = List[Int]()
    nulls.append(1)
    nulls.append(3)
    var batch = _batch2(
        Column.from_primitive[I32](_i32_keys(vals^, nulls^)),
        ArrowType.INT32,
        4,
    )
    var keys = extract_join_key_columns_serial(batch, _key_names())
    ref k0 = keys.int_keys.value()[0]
    assert_true(
        k0.validity.__bool__(),
        "widened int32 key slots dropped the source validity bitmap",
    )
    assert_equal(k0.null_count, 2, "widened key slots: wrong null_count")
    assert_false(k0.is_null(0), "row 0 was not null")
    assert_true(k0.is_null(1), "row 1 was null in the source")
    assert_false(k0.is_null(2), "row 2 was not null")
    assert_true(k0.is_null(3), "row 3 was null in the source")
    ref k1 = keys.int_keys.value()[1]
    assert_false(
        k1.validity.__bool__(),
        "a non-nullable key column must stay non-nullable",
    )


def test_null_probe_key_left_disposition() raises:
    """`no match` is not `dropped`. A NULL probe key (row 0, with a real
    build 42 under its cleared bit) must make LEFT emit BOTH probe rows, row 0
    with build index -1.
    """
    var bvals = List[Int64]()
    bvals.append(_TRAP)
    bvals.append(Int64(55))
    var build = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(bvals^)),
        ArrowType.INT64,
        2,
    )
    var pvals = List[Int64]()
    pvals.append(_TRAP)
    pvals.append(Int64(55))
    var pnull = List[Int]()
    pnull.append(0)
    var probe = _batch2(
        Column.from_primitive[I64](_i64_keys(pvals^, pnull^)),
        ArrowType.INT64,
        2,
    )

    var names = _key_names()
    var bkeys = extract_join_key_columns_serial(build, names)
    var builder = MultiKeyHashJoinBuilder.build(bkeys^)

    var pkeys = extract_join_key_columns_serial(probe, names)
    var bm = List[Int]()
    var pm = List[Int]()
    builder.probe_left_into(pkeys, bm, pm)
    var left = _sorted_pairs(bm, pm)
    var want_left = List[Int]()
    want_left.append(-1)
    want_left.append(0)
    want_left.append(1)
    want_left.append(1)
    _assert_pairs(left, want_left, String("LEFT with a null probe key"))


def test_non_nullable_int64_join_is_unchanged() raises:
    """The control for the fast-path claim. Neither side carries a bitmap, so
    the INT64 arm appends the column with no walk and no allocation, and every
    legitimate match must still be emitted — including one against key 0, which
    is the value a broken null encoding would have collided with.
    """
    var bvals = List[Int64]()
    bvals.append(Int64(0))
    bvals.append(_TRAP)
    bvals.append(Int64(55))
    var build = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(bvals^)),
        ArrowType.INT64,
        3,
    )
    var pvals = List[Int64]()
    pvals.append(Int64(55))
    pvals.append(Int64(0))
    pvals.append(_TRAP)
    pvals.append(Int64(999))
    var probe = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(pvals^)),
        ArrowType.INT64,
        4,
    )
    var want = List[Int]()
    want.append(0)
    want.append(1)
    want.append(1)
    want.append(2)
    want.append(2)
    want.append(0)
    _assert_pairs(
        _inner_pairs(build, probe), want, String("non-nullable control")
    )


def test_int64_key_equal_to_the_sentinel_is_skipped_today() raises:
    """THIS TEST ASSERTS A KNOWN WRONG ANSWER, as a tripwire: a non-NULL
    INT64 key equal to the NULL sentinel's bits is skipped like a NULL (the
    cost of encoding NULL as a key-slot value). A change that fixes it makes
    this test fail on purpose; update it then."""
    assert_equal(
        _NAN_SENTINEL_BITS,
        Int64(0x7FF8000000000001),
        (
            "the skip-row sentinel moved -- re-derive this test and decide"
            " whether the collision is still accepted"
        ),
    )

    var bvals = List[Int64]()
    bvals.append(Int64(1))
    bvals.append(_NAN_SENTINEL_BITS)
    bvals.append(Int64(3))
    var build = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(bvals^)),
        ArrowType.INT64,
        3,
    )

    var pvals = List[Int64]()
    pvals.append(Int64(1))
    pvals.append(_NAN_SENTINEL_BITS)
    pvals.append(Int64(3))
    var probe = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(pvals^)),
        ArrowType.INT64,
        3,
    )

    var want = List[Int]()
    want.append(0)
    want.append(0)
    want.append(2)
    want.append(2)
    _assert_pairs(
        _inner_pairs(build, probe),
        want,
        String(
            "sentinel-valued INT64 key is skipped today -- see the"
            " docstring before changing this test"
        ),
    )

    var bv2 = List[Int64]()
    bv2.append(Int64(1))
    bv2.append(Int64(2))
    bv2.append(Int64(3))
    var build2 = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(bv2^)),
        ArrowType.INT64,
        3,
    )
    var pv2 = List[Int64]()
    pv2.append(Int64(1))
    pv2.append(Int64(2))
    pv2.append(Int64(3))
    var probe2 = _batch2(
        Column.from_primitive[I64](_i64_keys_no_bitmap(pv2^)),
        ArrowType.INT64,
        3,
    )
    var want2 = List[Int]()
    want2.append(0)
    want2.append(0)
    want2.append(1)
    want2.append(1)
    want2.append(2)
    want2.append(2)
    _assert_pairs(
        _inner_pairs(build2, probe2),
        want2,
        String(
            "control: an ORDINARY value in row 1 matches, so the missing pair"
            " above is the sentinel collision and not the fixture"
        ),
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_int64_null_build_key_is_not_a_match_target]()
    suite.test[test_int64_null_probe_key_matches_nothing]()
    suite.test[test_int32_null_build_key_is_not_a_match_target]()
    suite.test[test_int32_null_probe_key_matches_nothing]()
    suite.test[test_float64_null_key_matches_nothing_and_nan_matches_nan]()
    suite.test[test_numeric_dict_null_key_matches_nothing]()
    suite.test[test_int32_widened_key_slots_preserve_validity]()
    suite.test[test_null_probe_key_left_disposition]()
    suite.test[test_non_nullable_int64_join_is_unchanged]()
    suite.test[test_int64_key_equal_to_the_sentinel_is_skipped_today]()
    suite^.run()
