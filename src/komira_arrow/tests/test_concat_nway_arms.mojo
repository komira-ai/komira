# =============================================================================
# concat.mojo, N-way `concat_record_batches_nway`: the arms the pair-wise fold
# does not share (Int32 and Int64 var-len kernels, the dictionary
# byte-identity predicate, the BOOL fold, bitmap-less nulls), checked against
# the Arrow columnar format by hand.
# =============================================================================
#
# Oracles, as in test_concat_pairwise_arms.mojo: validity is one bit per slot,
# LSB first, 1 = valid; a boolean array's values are bit-packed the same way;
# var-len offsets have `length + 1` entries and slot j is
# `data[offsets[j] : offsets[j + 1]]`; a dictionary column's rows are its
# Int32 codes resolved through a VarBinary dictionary. The N-way result of
# batches B0..Bk is the array whose slots are B0's, then B1's, and so on, and
# a dictionary result is judged by its resolved rows, not by its codes.
#
# Batches of 19 rows make the Int32 and Int64 offset rebase run both the SIMD
# loop and the scalar tail at any lane width up to 16.
#
# Not here, on purpose: batches holding a sliced column (`_offset > 0`). Every
# N-way kernel reads each input from position 0 of its buffers, so such a test
# would have to pin a wrong answer.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.concat import (
    concat_record_batches_nway,
    _concat_columns_nway_var_len,
    _concat_one_column_nway,
)
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, Field
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab


# =============================================================================
# Builders
# =============================================================================


def _validity(n: Int, nulls: List[Int]) -> Optional[Bitmap[HeapRegion]]:
    if len(nulls) == 0:
        return Optional[Bitmap[HeapRegion]](None)
    var bm = Bitmap.create_all_valid(n)
    for j in range(len(nulls)):
        bm.clear(nulls[j])
    return Optional[Bitmap[HeapRegion]](bm^)


def _batch(var c: Column[HeapRegion], at: ArrowType) raises -> RecordBatch:
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(c^)
    return b.build(Schema.from_fields_1(Field("c", at, True)))


def _var_col(
    at: ArrowType, values: List[String], nulls: List[Int], wide: Bool
) -> Column[HeapRegion]:
    var n = len(values)
    var total = 0
    for i in range(n):
        total += len(values[i].as_bytes())
    var offs = OwnedAlignedBuffer((n + 1) * (8 if wide else 4))
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
        validity=_validity(n, nulls),
        length=n,
        null_count=len(nulls),
        offset=0,
    )


def _empty_var_col(at: ArrowType, n: Int) -> Column[HeapRegion]:
    """`n` empty values with no offsets buffer (every offset 0)."""
    return Column[HeapRegion](
        arrow_type=at,
        data=OwnedAlignedBuffer(0),
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def _i32_col(vals: List[Int], null_count: Int) -> Column[HeapRegion]:
    """Int32 with no bitmap and the given null count."""
    var n = len(vals)
    var d = OwnedAlignedBuffer(n * 4)
    for i in range(n):
        d.set_typed[Int32](i, Int32(vals[i]))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT32,
        data=d^,
        offsets=None,
        validity=None,
        length=n,
        null_count=null_count,
        offset=0,
    )


def _bool_col(
    bits: List[Int], nulls: List[Int], pad_ones: Bool
) -> Column[HeapRegion]:
    """A boolean array, bit-packed LSB first. `pad_ones` sets every unused bit
    of the last byte: the format leaves them unspecified."""
    var n = len(bits)
    var nbytes = (n + 7) // 8
    var d = OwnedAlignedBuffer(nbytes)
    for i in range(nbytes):
        d.write_u8_at(i, UInt8(0))
    for i in range(n):
        if bits[i] != 0:
            d.write_u8_at(i // 8, d.read_u8_at(i // 8) | UInt8(1 << (i % 8)))
    if pad_ones and n % 8 != 0:
        var last = nbytes - 1
        var pad = UInt8(0xFF) ^ UInt8((1 << (n % 8)) - 1)
        d.write_u8_at(last, d.read_u8_at(last) | pad)
    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=d^,
        offsets=None,
        validity=_validity(n, nulls),
        length=n,
        null_count=len(nulls),
        offset=0,
    )


def _dict_col(
    entries: List[String],
    codes: List[Int],
    with_offsets: Bool,
    with_data: Bool,
) -> Column[HeapRegion]:
    var n = len(codes)
    var d = OwnedAlignedBuffer(n * 4)
    for i in range(n):
        d.set_typed[Int32](i, Int32(codes[i]))
    var total = 0
    for i in range(len(entries)):
        total += len(entries[i].as_bytes())
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
    var offs = Optional[OwnedAlignedBuffer](None)
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
# Readers
# =============================================================================


def _off(c: Column[HeapRegion], j: Int, wide: Bool) -> Int:
    if wide:
        return Int(c._offsets.value().get_typed[Int64](j))
    return Int(c._offsets.value().get_typed[Int32](j))


def _assert_var_rows(
    c: Column[HeapRegion], expected: List[String], wide: Bool
) raises:
    assert_equal(c._length, len(expected))
    assert_equal(_off(c, 0, wide), 0)
    for j in range(len(expected)):
        var s = _off(c, j, wide)
        var bs = expected[j].as_bytes()
        assert_equal(_off(c, j + 1, wide) - s, len(bs), msg=String(j))
        for k in range(len(bs)):
            assert_equal(Int(c._data.read_u8_at(s + k)), Int(bs[k]))


def _assert_dict_rows(c: Column[HeapRegion], expected: List[String]) raises:
    assert_true(c.arrow_type == ArrowType.DICTIONARY)
    assert_equal(c._length, len(expected))
    for i in range(len(expected)):
        var code = Int(c._data.get_typed[Int32](i))
        assert_true(code >= 0 and code < c._dict_size)
        var s = Int(c._offsets.value().get_typed[Int32](code))
        var e = Int(c._offsets.value().get_typed[Int32](code + 1))
        var got = String()
        for k in range(s, e):
            got += chr(Int(c._dict_data.value().read_u8_at(k)))
        assert_equal(got, expected[i], msg=String("row ") + String(i))


def _letters(n: Int, first: Int) -> List[String]:
    """n values, value i = (i % 4) copies of letter `first + i` (mod 26)."""
    var out = List[String]()
    for i in range(n):
        var s = String()
        for _ in range(i % 4):
            s += chr(ord("a") + (first + i) % 26)
        out.append(s^)
    return out^


def _spec_varbinary() -> List[String]:
    """The format's VarBinary example ["joe", null, null, "mark"], nulls as
    empty values (offsets 0, 3, 3, 3, 7)."""
    var v: List[String] = [
        String("joe"), String(""), String(""), String("mark")
    ]
    return v^


# =============================================================================
# STRING / BINARY N-way kernel (Int32 offsets)
# =============================================================================


def test_nway_string_spec_example_simd_batch_and_offsetless_batch() raises:
    """["joe", null, null, "mark"] ++ 19 strings ++ 3 empty values with no
    offsets buffer ++ ["!"]: slots in order, the empty batch's offsets equal
    the running data length, nulls only at 1 and 2."""
    var s0 = _spec_varbinary()
    var s1 = _letters(19, 0)
    var last: List[String] = [String("!")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_var_col(ArrowType.STRING, s0, [1, 2], False), ArrowType.STRING))
    batches.append(_batch(_var_col(ArrowType.STRING, s1, [], False), ArrowType.STRING))
    batches.append(_batch(_empty_var_col(ArrowType.STRING, 3), ArrowType.STRING))
    batches.append(_batch(_var_col(ArrowType.STRING, last, [], False), ArrowType.STRING))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_true(r.arrow_type == ArrowType.STRING)
    var want = s0.copy()
    var s1_bytes = 0
    for i in range(19):
        want.append(s1[i])
        s1_bytes += len(s1[i].as_bytes())
    for _ in range(3):
        want.append(String(""))
    want.append(String("!"))
    _assert_var_rows(r, want, False)
    var spec_offs: List[Int] = [0, 3, 3, 3, 7, 7, 8, 10, 13]
    for j in range(len(spec_offs)):
        assert_equal(_off(r, j, False), spec_offs[j])
    for j in range(24, 27):
        assert_equal(_off(r, j, False), 7 + s1_bytes)
    assert_equal(r._null_count, 2)
    for i in range(27):
        assert_equal(r._validity.value().test(i), i != 1 and i != 2)


# =============================================================================
# LARGE_STRING / LARGE_BINARY N-way kernel (Int64 offsets)
# =============================================================================


def test_nway_large_string_three_kinds_of_batch() raises:
    """The same slots at Int64 offsets: the output keeps LARGE_STRING and
    8-byte offsets; a null in the 19-row batch lands at 4 + its index."""
    var s0 = _spec_varbinary()
    var s1 = _letters(19, 3)
    var last: List[String] = [String("xyz"), String("")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_var_col(ArrowType.LARGE_STRING, s0, [1, 2], True), ArrowType.LARGE_STRING))
    batches.append(_batch(_var_col(ArrowType.LARGE_STRING, s1, [8], True), ArrowType.LARGE_STRING))
    batches.append(_batch(_empty_var_col(ArrowType.LARGE_STRING, 2), ArrowType.LARGE_STRING))
    batches.append(_batch(_var_col(ArrowType.LARGE_STRING, last, [], True), ArrowType.LARGE_STRING))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_true(r.arrow_type == ArrowType.LARGE_STRING)
    assert_equal(r._offsets.value().len(), 28 * 8)
    var want = s0.copy()
    var s1_bytes = 0
    for i in range(19):
        want.append(s1[i])
        s1_bytes += len(s1[i].as_bytes())
    want.append(String(""))
    want.append(String(""))
    want.append(String("xyz"))
    want.append(String(""))
    _assert_var_rows(r, want, True)
    assert_equal(_off(r, 24, True), 7 + s1_bytes)
    assert_equal(_off(r, 25, True), 7 + s1_bytes)
    assert_equal(_off(r, 27, True), 10 + s1_bytes)
    assert_equal(r._null_count, 3)
    for i in range(27):
        var is_null = i == 1 or i == 2 or i == 12
        assert_equal(r._validity.value().test(i), not is_null)


def test_nway_large_binary_all_valid_has_no_bitmap() raises:
    """LARGE_BINARY, no nulls anywhere: no bitmap; slots in order."""
    var v0: List[String] = [String("a"), String("bc")]
    var v1: List[String] = [String("def")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_var_col(ArrowType.LARGE_BINARY, v0, [], True), ArrowType.LARGE_BINARY))
    batches.append(_batch(_var_col(ArrowType.LARGE_BINARY, v1, [], True), ArrowType.LARGE_BINARY))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_true(r.arrow_type == ArrowType.LARGE_BINARY)
    var want: List[String] = [String("a"), String("bc"), String("def")]
    _assert_var_rows(r, want, True)
    assert_false(Bool(r._validity))
    assert_equal(r._null_count, 0)


# =============================================================================
# Bitmap-less nulls in the N-way validity merge
# =============================================================================


def test_nway_bitmapless_nulls_clear_leading_slots() raises:
    """Int32 batches with no bitmap: 2 valid; 3 slots claiming 2 nulls; 4
    valid. `_merge_validity_nway`'s contract (leading slots cleared) gives
    bits 1,1,0,0,1,1,1,1,1."""
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_i32_col([1, 2], 0), ArrowType.INT32))
    batches.append(_batch(_i32_col([0, 0, 5], 2), ArrowType.INT32))
    batches.append(_batch(_i32_col([6, 7, 8, 9], 0), ArrowType.INT32))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_equal(r._length, 9)
    assert_equal(r._null_count, 2)
    for i in range(9):
        assert_equal(r._validity.value().test(i), i != 2 and i != 3)
    var want: List[Int] = [1, 2, 0, 0, 5, 6, 7, 8, 9]
    for i in range(9):
        if i != 2 and i != 3:
            assert_equal(Int(r._data.get_typed[Int32](i)), want[i])


def test_nway_bitmapless_null_count_above_length_is_clamped() raises:
    """A batch claiming more nulls than slots clears its own slots only:
    1 valid, then 2 slots claiming 7, then 1 valid: bits 1,0,0,1."""
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_i32_col([4], 0), ArrowType.INT32))
    batches.append(_batch(_i32_col([0, 0], 7), ArrowType.INT32))
    batches.append(_batch(_i32_col([3], 0), ArrowType.INT32))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_true(r._validity.value().test(0))
    assert_false(r._validity.value().test(1))
    assert_false(r._validity.value().test(2))
    assert_true(r._validity.value().test(3))
    assert_equal(Int(r._data.get_typed[Int32](3)), 3)


# =============================================================================
# BOOL: the pair-wise fold
# =============================================================================


def test_nway_bool_fold_three_batches() raises:
    """[T, F, T] (unused bits of its byte set) ++ [T, null] ++
    [F, T, T, F, T, T, T, T, T]. Values bits 1,0,1,1,_,0,1,1,0,1,1,1,1,1:
    with the null slot's value bit unspecified, byte 0 is 0b11011101 or
    0b11001101 and byte 1 is 0b00111110; validity clears slot 4 only."""
    var b0: List[Int] = [1, 0, 1]
    var b1: List[Int] = [1, 0]
    var b2: List[Int] = [0, 1, 1, 0, 1, 1, 1, 1, 1]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_bool_col(b0, [], True), ArrowType.BOOL))
    batches.append(_batch(_bool_col(b1, [1], False), ArrowType.BOOL))
    batches.append(_batch(_bool_col(b2, [], False), ArrowType.BOOL))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_true(r.arrow_type == ArrowType.BOOL)
    assert_equal(r._length, 14)
    var byte0 = Int(r._data.read_u8_at(0)) & ~0b00010000
    assert_equal(byte0, 0b11001101)
    assert_equal(Int(r._data.read_u8_at(1)) & 0b00111111, 0b00111110)
    assert_equal(r._null_count, 1)
    for i in range(14):
        assert_equal(r._validity.value().test(i), i != 4)


# =============================================================================
# DICTIONARY: byte-identity predicate and both paths
# =============================================================================


def test_nway_dictionaries_all_empty_and_absent() raises:
    """Three zero-length dictionary batches, empty dictionaries and no
    dictionary buffers: one zero-length dictionary column."""
    var none = List[String]()
    var batches = Slab[RecordBatch]()
    for _ in range(3):
        batches.append(_batch(_dict_col(none, [], False, False), ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_true(r.arrow_type == ArrowType.DICTIONARY)
    assert_equal(r._length, 0)
    assert_equal(r._dict_size, 0)
    assert_false(Bool(r._dict_data))
    assert_false(Bool(r._offsets))


def test_nway_dictionary_absent_then_present() raises:
    """Batch 0 has an empty dictionary and no rows, batch 1 the dictionary
    ["q"] and rows q, q: the result's rows are q, q."""
    var none = List[String]()
    var dq: List[String] = [String("q")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_dict_col(none, [], False, False), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(dq, [0, 0], True, True), ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    var want: List[String] = [String("q"), String("q")]
    _assert_dict_rows(m.column_at(0), want)


def test_nway_dictionary_empty_string_with_and_without_data_buffer() raises:
    """Dictionary [""] with an empty data buffer, then [""] with the buffer
    omitted (allowed for a zero-length buffer): every row is ""."""
    var de: List[String] = [String("")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_dict_col(de, [0], True, True), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(de, [0, 0], True, False), ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    var want: List[String] = [String(""), String(""), String("")]
    _assert_dict_rows(m.column_at(0), want)


def test_nway_dictionaries_of_different_byte_length() raises:
    """["ab"] then ["abc"]: same size, different bytes; rows ab, abc, abc."""
    var d0: List[String] = [String("ab")]
    var d1: List[String] = [String("abc")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_dict_col(d0, [0], True, True), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(d1, [0, 0], True, True), ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    var want: List[String] = [String("ab"), String("abc"), String("abc")]
    _assert_dict_rows(m.column_at(0), want)


def test_nway_dictionaries_differing_in_last_byte() raises:
    """["ab", "cd"], ["ab", "cd"], ["ab", "ce"]: the predicate must compare
    every byte of every batch; rows resolve through the merged dictionary."""
    var d0: List[String] = [String("ab"), String("cd")]
    var d2: List[String] = [String("ab"), String("ce")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_dict_col(d0, [1, 0], True, True), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(d0, [0], True, True), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(d2, [1, 1, 0], True, True), ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    var want: List[String] = [
        String("cd"), String("ab"), String("ab"),
        String("ce"), String("ce"), String("ab"),
    ]
    _assert_dict_rows(m.column_at(0), want)


def test_nway_identical_dictionaries_share_first() raises:
    """Three batches with ["x", "y"]: codes concatenated, one dictionary."""
    var d: List[String] = [String("x"), String("y")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_dict_col(d, [1], True, True), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(d, [0, 1], True, True), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(d, [0], True, True), ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_equal(r._dict_size, 2)
    var want_codes: List[Int] = [1, 0, 1, 0]
    for i in range(4):
        assert_equal(Int(r._data.get_typed[Int32](i)), want_codes[i])
    var want: List[String] = [String("y"), String("x"), String("y"), String("x")]
    _assert_dict_rows(r, want)


# =============================================================================
# Single-batch column fold
# =============================================================================


def test_one_column_fold_of_one_batch_is_a_copy() raises:
    """`_concat_one_column_nway` over one batch returns that column's slots
    (both public entry points handle one batch before reaching it)."""
    var v: List[String] = [String("joe"), String(""), String("mark")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_var_col(ArrowType.STRING, v, [1], False), ArrowType.STRING))
    var r = _concat_one_column_nway(batches, 0, 1)
    _assert_var_rows(r, v, False)
    assert_equal(r._null_count, 1)
    assert_false(r._validity.value().test(1))
    assert_true(r._validity.value().test(2))


# =============================================================================
# More shapes: BINARY, zero-row batches, zero inputs, nulls on the identical
# dictionary path, nested refusal
# =============================================================================


def test_nway_binary_dispatches_to_var_len() raises:
    """BINARY (not only STRING) takes the Int32-offset kernel: slots in
    order, the output tagged BINARY."""
    var v0: List[String] = [String("ab")]
    var v1: List[String] = [String(""), String("cde")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_var_col(ArrowType.BINARY, v0, [], False), ArrowType.BINARY))
    batches.append(_batch(_var_col(ArrowType.BINARY, v1, [], False), ArrowType.BINARY))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_true(r.arrow_type == ArrowType.BINARY)
    var want: List[String] = [String("ab"), String(""), String("cde")]
    _assert_var_rows(r, want, False)


def test_nway_fixed_width_with_zero_row_batch() raises:
    """[5, 6] ++ [] ++ [7] is [5, 6, 7]."""
    var e = List[Int]()
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_i32_col([5, 6], 0), ArrowType.INT32))
    batches.append(_batch(_i32_col(e, 0), ArrowType.INT32))
    batches.append(_batch(_i32_col([7], 0), ArrowType.INT32))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_equal(r._length, 3)
    for i in range(3):
        assert_equal(Int(r._data.get_typed[Int32](i)), 5 + i)
    assert_false(Bool(r._validity))


def test_var_len_kernel_of_zero_inputs_is_empty() raises:
    """The Int32-offset kernel over zero inputs: zero slots, offsets [0],
    no data."""
    var batches = Slab[RecordBatch]()
    var r = _concat_columns_nway_var_len(batches, 0, 0, ArrowType.STRING)
    assert_true(r.arrow_type == ArrowType.STRING)
    assert_equal(r._length, 0)
    assert_equal(r._null_count, 0)
    assert_equal(r._offsets.value().len(), 4)
    assert_equal(_off(r, 0, False), 0)
    assert_equal(r._data.len(), 0)


def _with_nulls(var c: Column[HeapRegion], nulls: List[Int]) -> Column[HeapRegion]:
    c._validity = _validity(c._length, nulls)
    c._null_count = len(nulls)
    return c^


def test_nway_identical_dictionaries_keep_nulls() raises:
    """Identical dictionaries ["x", "y"], a null in batches 0 and 2: the
    result keeps the bitmap (slots 1 and 4 null) and the valid rows."""
    var d: List[String] = [String("x"), String("y")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_with_nulls(_dict_col(d, [1, 0], True, True), [1]), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(d, [0, 1], True, True), ArrowType.DICTIONARY))
    batches.append(_batch(_with_nulls(_dict_col(d, [0], True, True), [0]), ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_equal(r._length, 5)
    assert_equal(r._null_count, 2)
    for i in range(5):
        assert_equal(r._validity.value().test(i), i != 1 and i != 4)
    var want_codes: List[Int] = [1, 0, 0, 1, 0]
    for i in range(5):
        if i != 1 and i != 4:
            assert_equal(Int(r._data.get_typed[Int32](i)), want_codes[i])


def test_nway_identical_dictionaries_of_one_empty_string() raises:
    """Dictionary [""] (empty data buffer) in every batch: rows all ""."""
    var de: List[String] = [String("")]
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_dict_col(de, [0, 0], True, True), ArrowType.DICTIONARY))
    batches.append(_batch(_dict_col(de, [0], True, True), ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    var want: List[String] = [String(""), String(""), String("")]
    _assert_dict_rows(r, want)
    assert_equal(r._dict_data.value().len(), 0)


def test_nway_zero_entry_dictionary_with_empty_offsets_buffer() raises:
    """Zero-length batches whose zero-entry dictionary has an offsets buffer
    of zero bytes: a zero-length, zero-entry result."""
    var batches = Slab[RecordBatch]()
    for _ in range(2):
        var c = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=OwnedAlignedBuffer(0),
            offsets=Optional[OwnedAlignedBuffer](OwnedAlignedBuffer(0)),
            validity=None,
            length=0,
            null_count=0,
            offset=0,
        )
        c._set_dict_data_from_oab(OwnedAlignedBuffer(0))
        batches.append(_batch(c^, ArrowType.DICTIONARY))
    var m = concat_record_batches_nway(batches^)
    ref r = m.column_at(0)
    assert_true(r.arrow_type == ArrowType.DICTIONARY)
    assert_equal(r._length, 0)
    assert_equal(r._dict_size, 0)


def _spec_list_int8() -> Column[HeapRegion]:
    """The format's List<Int8> example [[12, -7, 25], null, [0, -127, 127,
    50], []]: offsets 0, 3, 3, 7, 7, validity 0b00001101."""
    var child_vals: List[Int] = [12, -7, 25, 0, -127, 127, 50]
    var cd = OwnedAlignedBuffer(7)
    for i in range(7):
        cd.write_u8_at(i, UInt8(child_vals[i] & 0xFF))
    var child = Column[HeapRegion](
        arrow_type=ArrowType.INT8,
        data=cd^,
        offsets=None,
        validity=None,
        length=7,
        null_count=0,
        offset=0,
    )
    var offs = OwnedAlignedBuffer(20)
    var o: List[Int] = [0, 3, 3, 7, 7]
    for i in range(5):
        offs.set_typed[Int32](i, Int32(o[i]))
    var col = Column[HeapRegion](
        arrow_type=ArrowType.LIST,
        data=OwnedAlignedBuffer(0),
        offsets=Optional[OwnedAlignedBuffer](offs^),
        validity=_validity(4, [1]),
        length=4,
        null_count=1,
        offset=0,
    )
    col._children.append(child^)
    return col^


def test_nway_nested_list_is_refused_not_reinterpreted() raises:
    """Two batches of the format's List<Int8> example: no N-way or pair-wise
    kernel concatenates lists, and the documented answer is the named
    refusal, never fixed-width cells."""
    var batches = Slab[RecordBatch]()
    batches.append(_batch(_spec_list_int8(), ArrowType.LIST))
    batches.append(_batch(_spec_list_int8(), ArrowType.LIST))
    var raised = False
    try:
        _ = concat_record_batches_nway(batches^)
    except e:
        raised = True
        assert_true(String(e).find("ArrowFixedWidthFallthrough") >= 0)
    assert_true(raised)


def main() raises:
    var t = TestSuite()
    t.test[test_nway_string_spec_example_simd_batch_and_offsetless_batch]()
    t.test[test_nway_large_string_three_kinds_of_batch]()
    t.test[test_nway_large_binary_all_valid_has_no_bitmap]()
    t.test[test_nway_bitmapless_nulls_clear_leading_slots]()
    t.test[test_nway_bitmapless_null_count_above_length_is_clamped]()
    t.test[test_nway_bool_fold_three_batches]()
    t.test[test_nway_dictionaries_all_empty_and_absent]()
    t.test[test_nway_dictionary_absent_then_present]()
    t.test[test_nway_dictionary_empty_string_with_and_without_data_buffer]()
    t.test[test_nway_dictionaries_of_different_byte_length]()
    t.test[test_nway_dictionaries_differing_in_last_byte]()
    t.test[test_nway_identical_dictionaries_share_first]()
    t.test[test_one_column_fold_of_one_batch_is_a_copy]()
    t.test[test_nway_binary_dispatches_to_var_len]()
    t.test[test_nway_fixed_width_with_zero_row_batch]()
    t.test[test_var_len_kernel_of_zero_inputs_is_empty]()
    t.test[test_nway_identical_dictionaries_keep_nulls]()
    t.test[test_nway_identical_dictionaries_of_one_empty_string]()
    t.test[test_nway_zero_entry_dictionary_with_empty_offsets_buffer]()
    t.test[test_nway_nested_list_is_refused_not_reinterpreted]()
    t^.run()
