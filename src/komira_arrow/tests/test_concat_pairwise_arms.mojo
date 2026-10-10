# =============================================================================
# concat.mojo, pair-wise `_concat_columns`: every type arm and every validity
# shape, checked against the Arrow columnar format by hand.
# =============================================================================
#
# Oracles. Each input is written buffer by buffer from the Arrow columnar
# format ("Physical Memory Layout"):
#   * validity: one bit per slot, LSB first within each byte, 1 = valid;
#   * Int32 / Int64 offsets: `length + 1` entries, value j is
#     `data[offsets[j] : offsets[j + 1]]`;
#   * dictionary: Int32 codes per row, the dictionary a VarBinary array.
# The two worked examples are the format's own: Int32 `[1, null, 2, 4, 8]`
# (validity byte 0b00011101) and VarBinary `["joe", null, null, "mark"]`
# (offsets 0, 3, 3, 3, 7, data "joemark", validity byte 0b00001001).
# Expected outputs are worked out from those rules: the concatenation of two
# arrays is the array whose slots are a's slots followed by b's.
#
# Rows of at least 19 make the Int32 and Int64 offset rebase run both its
# SIMD loop and its scalar tail at any lane width up to 16.
#
# Not here, on purpose: inputs with a slice offset (`_offset > 0`) and inputs
# whose first offset is not 0. This kernel reads every input from position 0
# of its buffers, so a test of those would have to pin a wrong answer.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.concat import _concat_columns
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


# =============================================================================
# Builders: Arrow buffers written by hand
# =============================================================================


def _validity(
    n: Int, nulls: List[Int], present: Bool
) -> Optional[Bitmap[HeapRegion]]:
    """A validity bitmap of `n` slots with `nulls` cleared, or none."""
    if not present:
        return Optional[Bitmap[HeapRegion]](None)
    var bm = Bitmap.create_all_valid(n)
    for j in range(len(nulls)):
        bm.clear(nulls[j])
    return Optional[Bitmap[HeapRegion]](bm^)


def _i32_col(
    vals: List[Int], nulls: List[Int], bitmap: Bool, null_count: Int
) -> Column[HeapRegion]:
    var n = len(vals)
    var d = OwnedAlignedBuffer(n * 4)
    for i in range(n):
        d.set_typed[Int32](i, Int32(vals[i]))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT32,
        data=d^,
        offsets=None,
        validity=_validity(n, nulls, bitmap),
        length=n,
        null_count=null_count,
        offset=0,
    )


def _var_col(
    at: ArrowType, values: List[String], nulls: List[Int], wide: Bool
) -> Column[HeapRegion]:
    """A STRING / BINARY (wide=False) or LARGE_* (wide=True) column."""
    var n = len(values)
    var total = 0
    for i in range(n):
        total += len(values[i].as_bytes())
    var ow = 8 if wide else 4
    var offs = OwnedAlignedBuffer((n + 1) * ow)
    var data = OwnedAlignedBuffer(total)
    var cur = 0
    if wide:
        offs.set_typed[Int64](0, Int64(0))
    else:
        offs.set_typed[Int32](0, Int32(0))
    for i in range(n):
        var bs = values[i].as_bytes()
        for k in range(len(bs)):
            data.write_u8_at(cur + k, bs[k])
        cur += len(bs)
        if wide:
            offs.set_typed[Int64](i + 1, Int64(cur))
        else:
            offs.set_typed[Int32](i + 1, Int32(cur))
    return Column[HeapRegion](
        arrow_type=at,
        data=data^,
        offsets=offs^,
        validity=_validity(n, nulls, len(nulls) > 0),
        length=n,
        null_count=len(nulls),
        offset=0,
    )


def _binary_col(
    at: ArrowType, rows: List[List[UInt8]], wide: Bool
) -> Column[HeapRegion]:
    """A BINARY / LARGE_BINARY column of arbitrary bytes, no nulls."""
    var n = len(rows)
    var total = 0
    for i in range(n):
        total += len(rows[i])
    var ow = 8 if wide else 4
    var offs = OwnedAlignedBuffer((n + 1) * ow)
    var data = OwnedAlignedBuffer(total)
    var cur = 0
    if wide:
        offs.set_typed[Int64](0, Int64(0))
    else:
        offs.set_typed[Int32](0, Int32(0))
    for i in range(n):
        for k in range(len(rows[i])):
            data.write_u8_at(cur + k, rows[i][k])
        cur += len(rows[i])
        if wide:
            offs.set_typed[Int64](i + 1, Int64(cur))
        else:
            offs.set_typed[Int32](i + 1, Int32(cur))
    return Column[HeapRegion](
        arrow_type=at,
        data=data^,
        offsets=offs^,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _empty_var_col(at: ArrowType, n: Int) -> Column[HeapRegion]:
    """`n` empty values with no offsets buffer: the all-empty var-len shape
    (`RecordBatchBuilder.build` names it legitimate), every offset 0."""
    return Column[HeapRegion](
        arrow_type=at,
        data=OwnedAlignedBuffer(0),
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _dict_col(
    entries: List[String],
    codes: List[Int],
    with_offsets: Bool,
    with_data: Bool,
) -> Column[HeapRegion]:
    """A string DICTIONARY column: Int32 codes, dictionary as VarBinary."""
    var n = len(codes)
    var d = OwnedAlignedBuffer(n * 4)
    for i in range(n):
        d.set_typed[Int32](i, Int32(codes[i]))
    var total = 0
    for i in range(len(entries)):
        total += len(entries[i].as_bytes())
    var offs = Optional[OwnedAlignedBuffer](None)
    var data = OwnedAlignedBuffer(total)
    var ob = OwnedAlignedBuffer((len(entries) + 1) * 4)
    ob.set_typed[Int32](0, Int32(0))
    var cur = 0
    for i in range(len(entries)):
        var bs = entries[i].as_bytes()
        for k in range(len(bs)):
            data.write_u8_at(cur + k, bs[k])
        cur += len(bs)
        ob.set_typed[Int32](i + 1, Int32(cur))
    if with_offsets:
        offs = ob^
    var col = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=d^,
        offsets=offs^,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )
    if with_data:
        col._set_dict_data_from_oab(data^)
    col._dict_size = len(entries)
    return col^


# =============================================================================
# Readers: the format's rules, independent of the code under test
# =============================================================================


def _bitmap_byte(c: Column[HeapRegion], i: Int) -> Int:
    return Int(c._validity.value().buffer.read_u8_at(i))


def _off(c: Column[HeapRegion], j: Int, wide: Bool) -> Int:
    if wide:
        return Int(c._offsets.value().get_typed[Int64](j))
    return Int(c._offsets.value().get_typed[Int32](j))


def _assert_var_rows(
    c: Column[HeapRegion], expected: List[String], wide: Bool
) raises:
    """Every slot j equals data[offsets[j] : offsets[j + 1]], and offsets[0]
    is 0 (both inputs' offsets start at 0, so the output's do)."""
    assert_equal(c._length, len(expected))
    assert_equal(_off(c, 0, wide), 0)
    for j in range(len(expected)):
        var s = _off(c, j, wide)
        var e = _off(c, j + 1, wide)
        var bs = expected[j].as_bytes()
        assert_equal(e - s, len(bs), msg=String("slot ") + String(j))
        for k in range(len(bs)):
            assert_equal(Int(c._data.read_u8_at(s + k)), Int(bs[k]))


def _dict_entry(c: Column[HeapRegion], code: Int) -> String:
    var s = Int(c._offsets.value().get_typed[Int32](code))
    var e = Int(c._offsets.value().get_typed[Int32](code + 1))
    var out = String()
    for k in range(s, e):
        out += chr(Int(c._dict_data.value().read_u8_at(k)))
    return out^


def _assert_dict_rows(c: Column[HeapRegion], expected: List[String]) raises:
    assert_equal(c._length, len(expected))
    for i in range(len(expected)):
        var code = Int(c._data.get_typed[Int32](i))
        assert_true(code >= 0 and code < c._dict_size)
        assert_equal(_dict_entry(c, code), expected[i])


def _letters(n: Int) -> List[String]:
    """n values, value i = (i % 4) copies of the i-th lowercase letter."""
    var out = List[String]()
    for i in range(n):
        var s = String()
        for _ in range(i % 4):
            s += chr(ord("a") + i)
        out.append(s^)
    return out^


# =============================================================================
# Validity merge (`_merge_validity`)
# =============================================================================


def test_spec_int32_example_then_nullable_int32() raises:
    """The format's Int32 `[1, null, 2, 4, 8]` ++ `[null, 16]`: values in
    order, validity bits 1,0,1,1,1,0,1 = byte 0b01011101."""
    var a = _i32_col([1, 0, 2, 4, 8], [1], True, 1)
    assert_equal(_bitmap_byte(a, 0), 0b00011101)
    var b = _i32_col([0, 16], [0], True, 1)
    var r = _concat_columns(a, b)
    assert_true(r.arrow_type == ArrowType.INT32)
    assert_equal(r._length, 7)
    assert_equal(r._null_count, 2)
    assert_equal(r._offset, 0)
    assert_equal(_bitmap_byte(r, 0), 0b01011101)
    var want: List[Int] = [1, 0, 2, 4, 8, 0, 16]
    for i in range(7):
        if i != 1 and i != 5:
            assert_equal(Int(r._data.get_typed[Int32](i)), want[i])
    assert_equal(r._data.len(), 28)


def test_all_valid_a_without_bitmap_then_nullable_b() raises:
    """a has no bitmap and no nulls: its slots are all valid in the output;
    b's null lands at a's length + its index. Bits 1,1,1,0,1 = 0b00010111."""
    var a = _i32_col([7, 8, 9], [], False, 0)
    var b = _i32_col([0, 5], [0], True, 1)
    var r = _concat_columns(a, b)
    assert_equal(r._null_count, 1)
    assert_equal(_bitmap_byte(r, 0), 0b00010111)
    assert_equal(Int(r._data.get_typed[Int32](4)), 5)


def test_nullable_a_then_all_valid_b_without_bitmap() raises:
    """Bits 0,1,1,1,1 = 0b00011110."""
    var a = _i32_col([0, 3], [0], True, 1)
    var b = _i32_col([4, 5, 6], [], False, 0)
    var r = _concat_columns(a, b)
    assert_equal(r._null_count, 1)
    assert_equal(_bitmap_byte(r, 0), 0b00011110)


def test_bitmaps_without_nulls_give_no_bitmap() raises:
    """Both inputs carry a bitmap but no null: the output is all valid and
    omits the bitmap (the format allows omitting it when null_count is 0)."""
    var a = _i32_col([1, 2], [], True, 0)
    var b = _i32_col([3], [], True, 0)
    var r = _concat_columns(a, b)
    assert_equal(r._null_count, 0)
    assert_false(Bool(r._validity))


def test_bitmapless_nulls_clear_leading_slots() raises:
    """A null count with no bitmap (outside the format: positions unknown).
    `_merge_validity`'s contract: clear that many leading slots of each side.
    a: 3 slots, 2 nulls; b: 4 slots, 1 null. Bits 0,0,1,0,1,1,1."""
    var a = _i32_col([0, 0, 9], [], False, 2)
    var b = _i32_col([0, 1, 2, 3], [], False, 1)
    var r = _concat_columns(a, b)
    assert_equal(_bitmap_byte(r, 0), 0b01110100)
    assert_equal(r._null_count, 3)


def test_bitmapless_null_count_above_length_is_clamped() raises:
    """The same contract when the count exceeds the side's length: every slot
    of that side is cleared and no slot of the other side. a: 3 slots claiming
    4 nulls, b: 2 slots claiming 5, then a valid c: bits 0,0,0,0,0,1."""
    var a = _i32_col([0, 0, 0], [], False, 4)
    var b = _i32_col([0, 0], [], False, 5)
    var ab = _concat_columns(a, b)
    assert_equal(_bitmap_byte(ab, 0), 0b00000000)
    var c = _i32_col([1], [], False, 0)
    var r = _concat_columns(ab, c)
    assert_equal(_bitmap_byte(r, 0), 0b00100000)
    assert_true(r._validity.value().test(5))


# =============================================================================
# STRING / BINARY arm (Int32 offsets)
# =============================================================================


def test_spec_varbinary_example_then_nineteen_strings() raises:
    """The format's `["joe", null, null, "mark"]` ++ 19 strings with two
    nulls: a's offsets pass through (0, 3, 3, 3, 7), b's are rebased by 7,
    the data is "joemark" then b's bytes, validity is both sides' bits."""
    var av: List[String] = [
        String("joe"), String(""), String(""), String("mark")
    ]
    var a = _var_col(ArrowType.STRING, av, [1, 2], False)
    assert_equal(_bitmap_byte(a, 0), 0b00001001)
    var bv = _letters(19)
    var b = _var_col(ArrowType.STRING, bv, [4, 16], False)
    var r = _concat_columns(a, b)
    assert_true(r.arrow_type == ArrowType.STRING)
    var want = av.copy()
    for i in range(19):
        want.append(bv[i])
    _assert_var_rows(r, want, False)
    var spec_offs: List[Int] = [0, 3, 3, 3, 7, 7, 8, 10, 13]
    for j in range(len(spec_offs)):
        assert_equal(_off(r, j, False), spec_offs[j])
    assert_equal(r._null_count, 4)
    for i in range(23):
        var is_null = i == 1 or i == 2 or i == 8 or i == 20
        assert_equal(r._validity.value().test(i), not is_null)


def test_binary_without_offsets_then_binary_bytes() raises:
    """BINARY: 2 empty values with no offsets buffer ++ 19 values holding
    0x00, 0xFF and 0x80 bytes. Offsets 0, 0, 0, then b's unchanged (base 0)."""
    var a = _empty_var_col(ArrowType.BINARY, 2)
    var rows = List[List[UInt8]]()
    for i in range(19):
        var row = List[UInt8]()
        for k in range(i % 3):
            row.append(UInt8((i * 37 + k * 128) & 0xFF))
        if i == 5:
            row.append(UInt8(0x00))
            row.append(UInt8(0xFF))
        rows.append(row^)
    var b = _binary_col(ArrowType.BINARY, rows, False)
    var r = _concat_columns(a, b)
    assert_true(r.arrow_type == ArrowType.BINARY)
    assert_equal(r._length, 21)
    assert_equal(_off(r, 0, False), 0)
    assert_equal(_off(r, 1, False), 0)
    assert_equal(_off(r, 2, False), 0)
    for i in range(19):
        var s = _off(r, i + 2, False)
        assert_equal(_off(r, i + 3, False) - s, len(rows[i]))
        for k in range(len(rows[i])):
            assert_equal(Int(r._data.read_u8_at(s + k)), Int(rows[i][k]))
    assert_false(Bool(r._validity))


def test_string_then_nineteen_empty_without_offsets() raises:
    """["hello", "world!"] ++ 19 empty values with no offsets buffer: every
    one of b's offsets is a's data length, 11."""
    var av: List[String] = [String("hello"), String("world!")]
    var a = _var_col(ArrowType.STRING, av, [], False)
    var b = _empty_var_col(ArrowType.STRING, 19)
    var r = _concat_columns(a, b)
    var want = av.copy()
    for _ in range(19):
        want.append(String(""))
    _assert_var_rows(r, want, False)
    for j in range(3, 22):
        assert_equal(_off(r, j, False), 11)


# =============================================================================
# LARGE_STRING / LARGE_BINARY arm (Int64 offsets)
# =============================================================================


def test_large_spec_example_then_nineteen_strings() raises:
    """The VarBinary example at Int64 offsets (LargeUtf8): the output keeps
    the LARGE_STRING tag and 8-byte offsets, b rebased by 7."""
    var av: List[String] = [
        String("joe"), String(""), String(""), String("mark")
    ]
    var a = _var_col(ArrowType.LARGE_STRING, av, [1, 2], True)
    var bv = _letters(19)
    var b = _var_col(ArrowType.LARGE_STRING, bv, [0, 12], True)
    var r = _concat_columns(a, b)
    assert_true(r.arrow_type == ArrowType.LARGE_STRING)
    assert_equal(r._offsets.value().len(), 24 * 8)
    var want = av.copy()
    for i in range(19):
        want.append(bv[i])
    _assert_var_rows(r, want, True)
    var spec_offs: List[Int] = [0, 3, 3, 3, 7, 7, 8, 10, 13]
    for j in range(len(spec_offs)):
        assert_equal(_off(r, j, True), spec_offs[j])
    assert_equal(r._null_count, 4)
    for i in range(23):
        var is_null = i == 1 or i == 2 or i == 4 or i == 16
        assert_equal(r._validity.value().test(i), not is_null)


def test_large_binary_without_offsets_then_bytes() raises:
    """LARGE_BINARY: 3 empty values, no offsets ++ 19 byte values."""
    var a = _empty_var_col(ArrowType.LARGE_BINARY, 3)
    var rows = List[List[UInt8]]()
    for i in range(19):
        var row = List[UInt8]()
        for k in range((i % 3) + 1):
            row.append(UInt8(255 - i - k))
        rows.append(row^)
    var b = _binary_col(ArrowType.LARGE_BINARY, rows, True)
    var r = _concat_columns(a, b)
    assert_true(r.arrow_type == ArrowType.LARGE_BINARY)
    assert_equal(r._length, 22)
    for j in range(4):
        assert_equal(_off(r, j, True), 0)
    for i in range(19):
        var s = _off(r, i + 3, True)
        assert_equal(_off(r, i + 4, True) - s, len(rows[i]))
        for k in range(len(rows[i])):
            assert_equal(Int(r._data.read_u8_at(s + k)), Int(rows[i][k]))
    assert_false(Bool(r._validity))


def test_large_string_then_empty_without_offsets() raises:
    """["ab", "cde"] ++ 4 empty values with no offsets: b's offsets all 5."""
    var av: List[String] = [String("ab"), String("cde")]
    var a = _var_col(ArrowType.LARGE_STRING, av, [], True)
    var b = _empty_var_col(ArrowType.LARGE_STRING, 4)
    var r = _concat_columns(a, b)
    var want = av.copy()
    for _ in range(4):
        want.append(String(""))
    _assert_var_rows(r, want, True)
    for j in range(3, 7):
        assert_equal(_off(r, j, True), 5)


# =============================================================================
# DICTIONARY arm, identical dictionaries (no remap)
# =============================================================================


def test_identical_dictionaries_concat_codes() raises:
    """Same dictionary ["x", "y", "z"] on both sides: codes are concatenated
    unchanged and the dictionary is a's, so rows read z,x,y then y,y,z,x."""
    var dict: List[String] = [String("x"), String("y"), String("z")]
    var a = _dict_col(dict, [2, 0, 1], True, True)
    var b = _dict_col(dict, [1, 1, 2, 0], True, True)
    var r = _concat_columns(a, b)
    assert_true(r.arrow_type == ArrowType.DICTIONARY)
    assert_equal(r._dict_size, 3)
    var want_codes: List[Int] = [2, 0, 1, 1, 1, 2, 0]
    for i in range(7):
        assert_equal(Int(r._data.get_typed[Int32](i)), want_codes[i])
    var want: List[String] = [
        String("z"), String("x"), String("y"),
        String("y"), String("y"), String("z"), String("x"),
    ]
    _assert_dict_rows(r, want)
    assert_equal(r._offsets.value().len(), 16)
    assert_equal(r._dict_data.value().len(), 3)
    assert_equal(r._null_count, 0)
    assert_false(Bool(r._validity))


def test_dictionary_of_one_empty_string() raises:
    """Dictionary [""] on both sides, its data buffer present and empty:
    every row is the empty string. With b's empty data buffer absent (a
    zero-length buffer may be omitted) the dictionaries are still equal."""
    var dict: List[String] = [String("")]
    var a = _dict_col(dict, [0, 0], True, True)
    var b = _dict_col(dict, [0], True, True)
    var r = _concat_columns(a, b)
    var want: List[String] = [String(""), String(""), String("")]
    _assert_dict_rows(r, want)
    assert_equal(r._dict_size, 1)
    assert_equal(r._dict_data.value().len(), 0)

    var b2 = _dict_col(dict, [0, 0, 0], True, False)
    var r2 = _concat_columns(a, b2)
    var want2: List[String] = [
        String(""), String(""), String(""), String(""), String("")
    ]
    _assert_dict_rows(r2, want2)


def test_empty_dictionary_columns() raises:
    """Two zero-length dictionary columns with an empty dictionary and no
    buffers: a zero-length dictionary column."""
    var none = List[String]()
    var a = _dict_col(none, [], False, False)
    var b = _dict_col(none, [], False, False)
    var r = _concat_columns(a, b)
    assert_true(r.arrow_type == ArrowType.DICTIONARY)
    assert_equal(r._length, 0)
    assert_equal(r._dict_size, 0)
    assert_false(Bool(r._offsets))
    assert_false(Bool(r._dict_data))


def test_dictionaries_differing_in_one_byte_are_merged() raises:
    """["ab", "cd"] vs ["ab", "ce"]: same size and byte length, one byte
    differs, so b's codes are remapped into ["ab", "cd", "ce"]."""
    var da: List[String] = [String("ab"), String("cd")]
    var db: List[String] = [String("ab"), String("ce")]
    var a = _dict_col(da, [0, 1], True, True)
    var b = _dict_col(db, [1, 0], True, True)
    var r = _concat_columns(a, b)
    assert_equal(r._dict_size, 3)
    var want: List[String] = [
        String("ab"), String("cd"), String("ce"), String("ab")
    ]
    _assert_dict_rows(r, want)


# =============================================================================
# Zero-length sides and byte-aligned BOOL
# =============================================================================


def _bool_col(bits: List[Int]) -> Column[HeapRegion]:
    """A boolean array of `bits`, bit-packed LSB first, no nulls."""
    var n = len(bits)
    var nbytes = (n + 7) // 8
    var d = OwnedAlignedBuffer(nbytes)
    for i in range(nbytes):
        d.write_u8_at(i, UInt8(0))
    for i in range(n):
        if bits[i] != 0:
            d.write_u8_at(i // 8, d.read_u8_at(i // 8) | UInt8(1 << (i % 8)))
    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=d^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _assert_bool_bits(c: Column[HeapRegion], bits: List[Int]) raises:
    assert_true(c.arrow_type == ArrowType.BOOL)
    assert_equal(c._length, len(bits))
    for i in range(len(bits)):
        var got = (Int(c._data.read_u8_at(i // 8)) >> (i % 8)) & 1
        assert_equal(got, bits[i], msg=String("bit ") + String(i))


def test_bool_empty_then_three() raises:
    """[] ++ [T, F, T] is [T, F, T]."""
    var e = List[Int]()
    var b: List[Int] = [1, 0, 1]
    var r = _concat_columns(_bool_col(e), _bool_col(b))
    _assert_bool_bits(r, b)


def test_bool_full_byte_then_three() raises:
    """A byte-aligned a (8 values, no partial byte to mask) ++ [T, T, F]:
    byte 0 is a's byte unchanged, byte 1 holds b at bits 0..2."""
    var a: List[Int] = [0, 1, 1, 0, 1, 0, 0, 1]
    var b: List[Int] = [1, 1, 0]
    var r = _concat_columns(_bool_col(a), _bool_col(b))
    var want = a.copy()
    for i in range(3):
        want.append(b[i])
    _assert_bool_bits(r, want)
    assert_equal(Int(r._data.read_u8_at(0)), 0b10010110)


def test_fixed_width_empty_sides() raises:
    """[] ++ [1, 2] is [1, 2]; [3] ++ [] is [3]."""
    var e = List[Int]()
    var r1 = _concat_columns(_i32_col(e, e, False, 0), _i32_col([1, 2], e, False, 0))
    assert_equal(r1._length, 2)
    assert_equal(Int(r1._data.get_typed[Int32](0)), 1)
    assert_equal(Int(r1._data.get_typed[Int32](1)), 2)
    var r2 = _concat_columns(_i32_col([3], e, False, 0), _i32_col(e, e, False, 0))
    assert_equal(r2._length, 1)
    assert_equal(Int(r2._data.get_typed[Int32](0)), 3)
    assert_equal(r2._data.len(), 4)


def test_zero_entry_dictionary_with_empty_offsets_buffer() raises:
    """Two zero-length dictionary columns whose zero-entry dictionary has an
    offsets buffer of zero bytes: a zero-length, zero-entry result."""
    var none = List[String]()
    var a = Column[HeapRegion](
        arrow_type=ArrowType.DICTIONARY,
        data=OwnedAlignedBuffer(0),
        offsets=Optional[OwnedAlignedBuffer](OwnedAlignedBuffer(0)),
        validity=None,
        length=0,
        null_count=0,
        offset=0,
    )
    a._set_dict_data_from_oab(OwnedAlignedBuffer(0))
    var b = _dict_col(none, [], False, True)
    var r = _concat_columns(a, b)
    assert_true(r.arrow_type == ArrowType.DICTIONARY)
    assert_equal(r._length, 0)
    assert_equal(r._dict_size, 0)


def main() raises:
    var t = TestSuite()
    t.test[test_spec_int32_example_then_nullable_int32]()
    t.test[test_all_valid_a_without_bitmap_then_nullable_b]()
    t.test[test_nullable_a_then_all_valid_b_without_bitmap]()
    t.test[test_bitmaps_without_nulls_give_no_bitmap]()
    t.test[test_bitmapless_nulls_clear_leading_slots]()
    t.test[test_bitmapless_null_count_above_length_is_clamped]()
    t.test[test_spec_varbinary_example_then_nineteen_strings]()
    t.test[test_binary_without_offsets_then_binary_bytes]()
    t.test[test_string_then_nineteen_empty_without_offsets]()
    t.test[test_large_spec_example_then_nineteen_strings]()
    t.test[test_large_binary_without_offsets_then_bytes]()
    t.test[test_large_string_then_empty_without_offsets]()
    t.test[test_identical_dictionaries_concat_codes]()
    t.test[test_dictionary_of_one_empty_string]()
    t.test[test_empty_dictionary_columns]()
    t.test[test_dictionaries_differing_in_one_byte_are_merged]()
    t.test[test_bool_empty_then_three]()
    t.test[test_bool_full_byte_then_three]()
    t.test[test_fixed_width_empty_sides]()
    t.test[test_zero_entry_dictionary_with_empty_offsets_buffer]()
    t^.run()
