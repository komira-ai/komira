# The composite join over integer keys: every key of an N-key INT join takes
# part in the match (rows equal on the first keys and different on a later one
# do not join), and an INT32 key joins by its sign-extended value (a negative
# INT32 key equals the same negative INT64 key).

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion

from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)


def _i64_col(imm values: List[Int64]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    return Column.from_primitive[DType.int64](arr^)


def _i32_col(imm values: List[Int32]) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    return Column.from_primitive[DType.int32](arr^)


def _names(n: Int) raises -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(String("k") + String(i))
    return out^


def _batch(
    var cols: List[Column[HeapRegion]], imm types: List[ArrowType]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    for i in range(len(cols)):
        sb.add_field(Field(String("k") + String(i), types[i], False))
    cols.reverse()
    while len(cols) > 0:
        b.add_column(cols.pop())
    return b.build(sb.build())


def _pairs(
    imm build: RecordBatch,
    imm probe: RecordBatch,
    num_keys: Int,
    left: Bool,
) raises -> List[Int]:
    """The matches flattened as `[build_idx, probe_idx, ...]`, ordered by
    probe index then build index so the expected pairs need no emit order.
    """
    var names = _names(num_keys)
    var bkeys = extract_join_key_columns_serial(build, names)
    var builder = MultiKeyHashJoinBuilder.build(bkeys^)
    var pkeys = extract_join_key_columns_serial(probe, names)
    var bm = List[Int]()
    var pm = List[Int]()
    if left:
        builder.probe_left_into(pkeys, bm, pm)
    else:
        builder.probe_inner_into(pkeys, bm, pm)
    var out = List[Int]()
    var n = len(bm)
    var used = List[Bool]()
    for _ in range(n):
        used.append(False)
    for _ in range(n):
        var best = -1
        for i in range(n):
            if used[i]:
                continue
            if best < 0 or pm[i] < pm[best] or (
                pm[i] == pm[best] and bm[i] < bm[best]
            ):
                best = i
        used[best] = True
        out.append(bm[best])
        out.append(pm[best])
    return out^


def _assert_pairs(imm got: List[Int], imm want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": wrong match count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": element " + String(i))


def _int64_triple(
    k0: List[Int64], k1: List[Int64], k2: List[Int64]
) raises -> RecordBatch:
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64_col(k0))
    cols.append(_i64_col(k1))
    cols.append(_i64_col(k2))
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    return _batch(cols^, types)


def _l(a: Int64, b: Int64, c: Int64, d: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    l.append(b)
    l.append(c)
    l.append(d)
    return l^


def test_three_int64_keys_inner_every_key_must_match() raises:
    """Every row agrees on the first key. Probe row 0 differs from build row 0
    only on the third key and from build row 2 only on the third key too; probe
    row 2 differs from build row 2 only on the second key. Only (build 2,
    probe 1) agrees on all three keys.
    """
    var build = _int64_triple(
        _l(1, 1, 1, 1), _l(1, 1, 2, 3), _l(1, 2, 2, 3)
    )
    var probe = _int64_triple(
        _l(1, 1, 1, 1), _l(2, 2, 4, 3), _l(1, 2, 2, 9)
    )
    var want = List[Int]()
    want.append(2)
    want.append(1)
    _assert_pairs(
        _pairs(build, probe, 3, False), want, String("3-key INT64 INNER")
    )


def test_three_int64_keys_inner_slot_mates_differing_on_later_keys() raises:
    """All rows share the first key, and far more probe rows than build rows
    are looked up, so many probe rows hash into a slot already holding a build
    row. Only the 64 probe rows equal to a build row on all three keys join;
    probe rows that share the first key (and a slot) but differ later do not.
    """
    var bk1 = List[Int64]()
    var bk2 = List[Int64]()
    var bk0 = List[Int64]()
    for i in range(64):
        bk0.append(1)
        bk1.append(Int64(i))
        bk2.append(Int64(i))
    var pk0 = List[Int64]()
    var pk1 = List[Int64]()
    var pk2 = List[Int64]()
    for j in range(20000):
        pk0.append(1)
        if j < 64:
            pk1.append(Int64(j))
            pk2.append(Int64(j))
        else:
            pk1.append(Int64(j))
            pk2.append(Int64(j + 1))
    var build = _int64_triple(bk0, bk1, bk2)
    var probe = _int64_triple(pk0, pk1, pk2)
    var got = _pairs(build, probe, 3, False)
    assert_equal(len(got), 128, String("3-key INT64 INNER, colliding slots"))
    for i in range(64):
        assert_equal(got[2 * i], i, String("build index ") + String(i))
        assert_equal(got[2 * i + 1], i, String("probe index ") + String(i))


def test_three_int64_keys_left_keeps_rows_differing_on_later_key() raises:
    """The same inputs under LEFT: probe rows whose first key matches but whose
    later keys do not stay unmatched (build index -1); the full match joins.
    """
    var build = _int64_triple(
        _l(1, 1, 1, 1), _l(1, 1, 2, 3), _l(1, 2, 2, 3)
    )
    var probe = _int64_triple(
        _l(1, 1, 1, 1), _l(2, 2, 4, 3), _l(1, 2, 2, 9)
    )
    var want = List[Int]()
    want.append(-1)
    want.append(0)
    want.append(2)
    want.append(1)
    want.append(-1)
    want.append(2)
    want.append(-1)
    want.append(3)
    _assert_pairs(
        _pairs(build, probe, 3, True), want, String("3-key INT64 LEFT")
    )


def test_two_int64_keys_swapped_columns_do_not_match() raises:
    """(1, 2) and (2, 1) hold the same values in different key positions."""
    var bk0 = List[Int64]()
    bk0.append(1)
    bk0.append(2)
    var bk1 = List[Int64]()
    bk1.append(2)
    bk1.append(1)
    var pk0 = List[Int64]()
    pk0.append(1)
    var pk1 = List[Int64]()
    pk1.append(1)
    var bcols = List[Column[HeapRegion]]()
    bcols.append(_i64_col(bk0))
    bcols.append(_i64_col(bk1))
    var pcols = List[Column[HeapRegion]]()
    pcols.append(_i64_col(pk0))
    pcols.append(_i64_col(pk1))
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT64)
    var got = _pairs(_batch(bcols^, types), _batch(pcols^, types), 2, False)
    assert_equal(
        len(got), 0, String("(1, 1) matches neither (1, 2) nor (2, 1)")
    )


def _i32s(a: Int32, b: Int32, c: Int32) -> List[Int32]:
    var l = List[Int32]()
    l.append(a)
    l.append(b)
    l.append(c)
    return l^


def _i64s3(a: Int64, b: Int64, c: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    l.append(b)
    l.append(c)
    return l^


def test_negative_int32_keys_join_by_sign_extended_value() raises:
    """INT32 build [-1, -5, 7] against INT32 probe [-5, -1, 3] joins -5 to -5
    and -1 to -1.
    """
    var types = List[ArrowType]()
    types.append(ArrowType.INT32)
    var bcols = List[Column[HeapRegion]]()
    bcols.append(_i32_col(_i32s(-1, -5, 7)))
    var pcols = List[Column[HeapRegion]]()
    pcols.append(_i32_col(_i32s(-5, -1, 3)))
    var want = List[Int]()
    want.append(1)
    want.append(0)
    want.append(0)
    want.append(1)
    _assert_pairs(
        _pairs(_batch(bcols^, types), _batch(pcols^, types), 1, False),
        want,
        String("negative INT32"),
    )


def test_negative_int32_build_joins_negative_int64_probe() raises:
    """A build-side INT32 key -1 equals a probe-side INT64 key -1, and -5 does
    not equal 4294967291 (the zero-extended image of INT32 -5).
    """
    var btypes = List[ArrowType]()
    btypes.append(ArrowType.INT32)
    var ptypes = List[ArrowType]()
    ptypes.append(ArrowType.INT64)
    var bcols = List[Column[HeapRegion]]()
    bcols.append(_i32_col(_i32s(-1, -5, 7)))
    var pcols = List[Column[HeapRegion]]()
    pcols.append(_i64_col(_i64s3(-1, 4294967291, -5)))
    var want = List[Int]()
    want.append(0)
    want.append(0)
    want.append(1)
    want.append(2)
    _assert_pairs(
        _pairs(_batch(bcols^, btypes), _batch(pcols^, ptypes), 1, False),
        want,
        String("INT32 build, INT64 probe"),
    )


def test_negative_int64_build_joins_negative_int32_probe() raises:
    """The mirror: a build-side INT64 key -1 equals a probe-side INT32 -1."""
    var btypes = List[ArrowType]()
    btypes.append(ArrowType.INT64)
    var ptypes = List[ArrowType]()
    ptypes.append(ArrowType.INT32)
    var bcols = List[Column[HeapRegion]]()
    bcols.append(_i64_col(_i64s3(-1, 4294967295, 7)))
    var pcols = List[Column[HeapRegion]]()
    pcols.append(_i32_col(_i32s(-1, 7, 3)))
    var want = List[Int]()
    want.append(0)
    want.append(0)
    want.append(2)
    want.append(1)
    _assert_pairs(
        _pairs(_batch(bcols^, btypes), _batch(pcols^, ptypes), 1, False),
        want,
        String("INT64 build, INT32 probe"),
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_three_int64_keys_inner_every_key_must_match]()
    suite.test[test_three_int64_keys_inner_slot_mates_differing_on_later_keys]()
    suite.test[test_three_int64_keys_left_keeps_rows_differing_on_later_key]()
    suite.test[test_two_int64_keys_swapped_columns_do_not_match]()
    suite.test[test_negative_int32_keys_join_by_sign_extended_value]()
    suite.test[test_negative_int32_build_joins_negative_int64_probe]()
    suite.test[test_negative_int64_build_joins_negative_int32_probe]()
    suite^.run()
