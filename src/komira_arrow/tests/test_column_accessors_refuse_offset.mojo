# =============================================================================
# Column.as_string / as_binary / as_large_string / as_large_binary / as_boolean
# and utf8_value_at refuse a column whose `_offset` is not 0
# =============================================================================
#
# These accessors copy offsets[0 .. _length], data from byte 0 and validity
# from bit 0: they read a column as if `_offset` were 0. On a column whose
# `_offset` is 1 they return the row BEFORE each requested one, a wrong answer
# under a correct row count. `Column.slice` refuses these layouts, but
# `_offset` is a constructor argument every producer can set, so the
# accessors refuse it themselves (as `widened_to_int64_offsets` already does).
#
# Each test builds the column with `_offset == 1` and asserts the refusal; a
# control builds the same rows at `_offset == 0` and asserts the values, so a
# refusal of every column would not pass. `utf8_is_null_at` answers row `r`
# from validity bit `_offset + r`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


comptime REFUSAL = "refusing a sliced column"


def _var_col(at: ArrowType, off: Int) raises -> Column[HeapRegion]:
    """Rows "a", "bb", "ccc" (row 1 NULL), viewing [off, 3)."""
    var wide = at == ArrowType.LARGE_STRING or at == ArrowType.LARGE_BINARY
    var ow = 8 if wide else 4
    var offs: List[Int] = [0, 1, 3, 6]
    var obuf = OwnedAlignedBuffer(4 * ow)
    obuf.set_length(Int64(4 * ow))
    for i in range(4):
        if wide:
            obuf.set_typed[Int64](i, Int64(offs[i]))
        else:
            obuf.set_typed[Int32](i, Int32(offs[i]))
    var bytes = String("abbccc").as_bytes()
    var dbuf = OwnedAlignedBuffer(6)
    dbuf.set_length(6)
    for i in range(6):
        dbuf.write_u8_at(i, bytes[i])
    var bm = Bitmap.create_all_valid(3)
    bm.clear(1)
    return Column[HeapRegion](
        arrow_type=at,
        data=dbuf^,
        offsets=Optional(obuf^),
        validity=Optional(bm^),
        length=3 - off,
        null_count=1,
        offset=off,
    )


def _bool_col(off: Int) raises -> Column[HeapRegion]:
    """Rows true, false, true, viewing [off, 3)."""
    var buf = OwnedAlignedBuffer(1)
    buf.set_length(1)
    buf.write_u8_at(0, UInt8(0b101))
    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=buf^,
        offsets=None,
        validity=None,
        length=3 - off,
        null_count=0,
        offset=off,
    )


def _assert_refusal(msg: String, label: String) raises:
    assert_true(
        REFUSAL in msg, label + ": want '" + REFUSAL + "', got '" + msg + "'"
    )


def test_as_string_refuses_offset() raises:
    var ok = _var_col(ArrowType.STRING, 0).as_string()
    assert_equal(ok.get(2), String("ccc"), "control")
    var msg = String()
    try:
        _ = _var_col(ArrowType.STRING, 1).as_string()
    except e:
        msg = String(e)
    _assert_refusal(msg, "as_string")


def test_as_binary_refuses_offset() raises:
    var ok = _var_col(ArrowType.BINARY, 0).as_binary()
    assert_equal(ok.length, 3, "control")
    var msg = String()
    try:
        _ = _var_col(ArrowType.BINARY, 1).as_binary()
    except e:
        msg = String(e)
    _assert_refusal(msg, "as_binary")


def test_as_large_string_refuses_offset() raises:
    var ok = _var_col(ArrowType.LARGE_STRING, 0).as_large_string()
    assert_equal(ok.get(2), String("ccc"), "control")
    var msg = String()
    try:
        _ = _var_col(ArrowType.LARGE_STRING, 1).as_large_string()
    except e:
        msg = String(e)
    _assert_refusal(msg, "as_large_string")


def test_as_large_binary_refuses_offset() raises:
    var ok = _var_col(ArrowType.LARGE_BINARY, 0).as_large_binary()
    assert_equal(ok.length, 3, "control")
    var msg = String()
    try:
        _ = _var_col(ArrowType.LARGE_BINARY, 1).as_large_binary()
    except e:
        msg = String(e)
    _assert_refusal(msg, "as_large_binary")


def test_as_boolean_refuses_offset() raises:
    var ok = _bool_col(0).as_boolean()
    assert_equal(ok.length, 3, "control")
    var msg = String()
    try:
        _ = _bool_col(1).as_boolean()
    except e:
        msg = String(e)
    _assert_refusal(msg, "as_boolean")


def test_utf8_value_at_refuses_offset() raises:
    assert_equal(
        _var_col(ArrowType.STRING, 0).utf8_value_at(2), String("ccc"), "control"
    )
    for wide in range(2):
        var at = ArrowType.LARGE_STRING if wide == 1 else ArrowType.STRING
        var msg = String()
        try:
            _ = _var_col(at, 1).utf8_value_at(1)
        except e:
            msg = String(e)
        _assert_refusal(msg, "utf8_value_at wide=" + String(wide))


def test_utf8_is_null_at_honours_offset() raises:
    # Rows "a", NULL, "ccc"; window [1, 3) is NULL, "ccc".
    var col = _var_col(ArrowType.STRING, 1)
    assert_true(col.utf8_is_null_at(0), "window row 0 is the NULL")
    assert_false(col.utf8_is_null_at(1), "window row 1 is 'ccc'")


def main() raises:
    var t = TestSuite()
    t.test[test_as_string_refuses_offset]()
    t.test[test_as_binary_refuses_offset]()
    t.test[test_as_large_string_refuses_offset]()
    t.test[test_as_large_binary_refuses_offset]()
    t.test[test_as_boolean_refuses_offset]()
    t.test[test_utf8_value_at_refuses_offset]()
    t.test[test_utf8_is_null_at_honours_offset]()
    t^.run()
