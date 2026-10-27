# =============================================================================
# ORDER BY on a NEGATIVE DT_I16 / DT_I8 sort key (SortBuffer_Untyped)
# =============================================================================
#
# The buffer stores narrow signed keys in an UNSIGNED cell (`write_slot_u16`)
# and sign-extends them back with integer arithmetic (`_sext_cell_u16`). The
# comparison must run on the sign-extended value: read as the unsigned word,
# -1001 would compare as 64535, ordering would stay monotone within each sign
# class and only the classes would swap, putting every negative key after every
# non-negative one. A test that sorts only negatives, or only non-negatives,
# cannot tell the two apart.
#
# The fixtures therefore MIX signs, and the assertions are on VALUES (the
# exact emitted key sequence), not on a row count or an "is_sorted" check that
# reuses the comparator under test.
#
# The read-back oracle is `read_sorted_i16()` / `read_sorted_i8()`, which
# return a `List[Int16]` / `List[Int8]` directly, so the narrow value is read
# back without any widening conversion.
#
# Single-sign-class fixtures (`test_sort_i16_all_non_negative_unaffected` and
# `test_sort_i16_all_negative_unaffected`) check the harness and the monotone case.
#
# Encapsulation: public surface only — no UnsafePointer, no wildcard origin.
# =============================================================================

from komira_column_format.column_format_storage import (
    ColDescriptor,
    COL_FIXED,
    DT_I16,
    DT_I8,
    ROLE_SORT_KEY,
)
from komira_op_sort.sort_buffer_untyped import (
    SortBuffer_Untyped,
    SORT_ASC,
    SORT_DESC,
)
from komira_arrow.batch_view import BatchView
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.record_batch import RecordBatchBuilder

from std.testing import TestSuite, assert_equal, assert_true


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _i16_key_desc() -> List[ColDescriptor]:
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=DT_I16,
            role=ROLE_SORT_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _i8_key_desc() -> List[ColDescriptor]:
    var l = List[ColDescriptor]()
    l.append(
        ColDescriptor(
            name_id=0,
            kind=COL_FIXED,
            dtype_tag=DT_I8,
            role=ROLE_SORT_KEY,
            col_idx_in_batch=0,
            col_idx_in_storage=0,
            validity_tracked=False,
        )
    )
    return l^


def _batch_i16(imm vals: List[Int16]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT16, False))
    var schema = sb.build()
    var l: List[Scalar[DType.int16]] = []
    for i in range(len(vals)):
        l.append(vals[i])
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int16](
            PrimitiveArray[DType.int16].from_list(l)
        )
    )
    return rbb.build(schema^)


def _batch_i8(imm vals: List[Int8]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT8, False))
    var schema = sb.build()
    var l: List[Scalar[DType.int8]] = []
    for i in range(len(vals)):
        l.append(vals[i])
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int8](
            PrimitiveArray[DType.int8].from_list(l)
        )
    )
    return rbb.build(schema^)


def _sorted_i16(imm vals: List[Int16], dir: UInt8) raises -> List[Int16]:
    var descs = _i16_key_desc()
    var dirs = List[UInt8]()
    dirs.append(dir)
    var sbuf = SortBuffer_Untyped(descs^, dirs^, List[ColDescriptor](), 16)
    var batch = _batch_i16(vals)
    var view = BatchView(batch)
    sbuf.feed_batch(view)
    sbuf.finalize_sort()
    return sbuf.read_sorted_i16(0)


def _sorted_i8(imm vals: List[Int8], dir: UInt8) raises -> List[Int8]:
    var descs = _i8_key_desc()
    var dirs = List[UInt8]()
    dirs.append(dir)
    var sbuf = SortBuffer_Untyped(descs^, dirs^, List[ColDescriptor](), 16)
    var batch = _batch_i8(vals)
    var view = BatchView(batch)
    sbuf.feed_batch(view)
    sbuf.finalize_sort()
    return sbuf.read_sorted_i8(0)


def _fmt_i16(imm v: List[Int16]) -> String:
    var s = String("[")
    for i in range(len(v)):
        if i > 0:
            s += ", "
        s += String(Int(v[i]))
    return s + "]"


def _fmt_i8(imm v: List[Int8]) -> String:
    var s = String("[")
    for i in range(len(v)):
        if i > 0:
            s += ", "
        s += String(Int(v[i]))
    return s + "]"


# -----------------------------------------------------------------------------
# Mixed-sign keys
# -----------------------------------------------------------------------------


def test_sort_i16_mixed_sign_ascending() raises:
    """ASC over MIXED-SIGN Int16 keys: every negative key sorts before
    every non-negative one."""
    var vals = List[Int16]()
    vals.append(Int16(-1001))
    vals.append(Int16(5))
    vals.append(Int16(-32768))
    vals.append(Int16(32767))
    vals.append(Int16(-7))
    vals.append(Int16(12))

    var got = _sorted_i16(vals, SORT_ASC)

    var want = List[Int16]()
    want.append(Int16(-32768))
    want.append(Int16(-1001))
    want.append(Int16(-7))
    want.append(Int16(5))
    want.append(Int16(12))
    want.append(Int16(32767))

    assert_equal(len(got), len(want), "row count changed")
    for i in range(len(want)):
        assert_equal(
            Int(got[i]),
            Int(want[i]),
            "ASC Int16 order wrong at index "
            + String(i)
            + ": got "
            + _fmt_i16(got)
            + " want "
            + _fmt_i16(want),
        )


def test_sort_i16_mixed_sign_descending() raises:
    """DESC over MIXED-SIGN Int16 keys — the mirror of the ASC case, so a
    comparator that merely INVERTED the sign classes cannot pass both."""
    var vals = List[Int16]()
    vals.append(Int16(-1001))
    vals.append(Int16(5))
    vals.append(Int16(-32768))
    vals.append(Int16(32767))

    var got = _sorted_i16(vals, SORT_DESC)

    var want = List[Int16]()
    want.append(Int16(32767))
    want.append(Int16(5))
    want.append(Int16(-1001))
    want.append(Int16(-32768))

    for i in range(len(want)):
        assert_equal(
            Int(got[i]),
            Int(want[i]),
            "DESC Int16 order wrong at index "
            + String(i)
            + ": got "
            + _fmt_i16(got)
            + " want "
            + _fmt_i16(want),
        )


def test_sort_i16_negative_sorts_before_zero() raises:
    """The smallest case: -1 sorts before 0."""
    var vals = List[Int16]()
    vals.append(Int16(0))
    vals.append(Int16(-1))

    var got = _sorted_i16(vals, SORT_ASC)
    assert_equal(Int(got[0]), -1, "-1 must sort before 0, got " + _fmt_i16(got))
    assert_equal(Int(got[1]), 0, "0 must sort after -1, got " + _fmt_i16(got))


def test_sort_i8_mixed_sign_ascending() raises:
    """ASC over MIXED-SIGN Int8 keys, the DT_I8 twin of the DT_I16 arm."""
    var vals = List[Int8]()
    vals.append(Int8(-25))
    vals.append(Int8(3))
    vals.append(Int8(-128))
    vals.append(Int8(127))
    vals.append(Int8(-1))

    var got = _sorted_i8(vals, SORT_ASC)

    var want = List[Int8]()
    want.append(Int8(-128))
    want.append(Int8(-25))
    want.append(Int8(-1))
    want.append(Int8(3))
    want.append(Int8(127))

    assert_equal(len(got), len(want), "row count changed")
    for i in range(len(want)):
        assert_equal(
            Int(got[i]),
            Int(want[i]),
            "ASC Int8 order wrong at index "
            + String(i)
            + ": got "
            + _fmt_i8(got)
            + " want "
            + _fmt_i8(want),
        )


def test_sort_i8_negative_sorts_before_zero() raises:
    """The DT_I8 twin of the -1 < 0 pin."""
    var vals = List[Int8]()
    vals.append(Int8(0))
    vals.append(Int8(-1))

    var got = _sorted_i8(vals, SORT_ASC)
    assert_equal(Int(got[0]), -1, "-1 must sort before 0, got " + _fmt_i8(got))


# -----------------------------------------------------------------------------
# Single-sign-class controls
# -----------------------------------------------------------------------------


def test_sort_i16_all_non_negative_unaffected() raises:
    """All keys >= 0: the u16 word equals the signed value, so the order is
    the same under either reading."""
    var vals = List[Int16]()
    vals.append(Int16(300))
    vals.append(Int16(1))
    vals.append(Int16(32767))
    vals.append(Int16(0))

    var got = _sorted_i16(vals, SORT_ASC)
    assert_equal(Int(got[0]), 0)
    assert_equal(Int(got[1]), 1)
    assert_equal(Int(got[2]), 300)
    assert_equal(Int(got[3]), 32767)


def test_sort_i16_all_negative_unaffected() raises:
    """All keys < 0: the u16 words are order-isomorphic to the signed values
    within this class, so a single-sign-class test cannot tell the readings
    apart."""
    var vals = List[Int16]()
    vals.append(Int16(-7))
    vals.append(Int16(-32768))
    vals.append(Int16(-1001))

    var got = _sorted_i16(vals, SORT_ASC)
    assert_equal(Int(got[0]), -32768)
    assert_equal(Int(got[1]), -1001)
    assert_equal(Int(got[2]), -7)


def test_sort_i16_readback_reconstructs_sign() raises:
    """`read_sorted_i16` is the oracle for the tests above, so pin that IT is
    correct independently: it spells `Int16(Int(u))` with a `List[Int16]`
    consumer and no widening, which is the SAFE side of the same trap."""
    var vals = List[Int16]()
    vals.append(Int16(-1001))

    var got = _sorted_i16(vals, SORT_ASC)
    assert_equal(len(got), 1)
    assert_true(
        Int(got[0]) < 0,
        "read_sorted_i16 lost the sign — the oracle itself is compromised",
    )
    assert_equal(Int(got[0]), -1001)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
