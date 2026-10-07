# Direct tests of `dictionary.mojo` and `dictionary_resolve.mojo`, part 1:
# loading a dictionary page, decoding RLE_DICTIONARY index pages, and the
# four numeric resolves on both arms (the fused arm of dict_gather_fused and
# the legacy gathers of dictionary_resolve), with the fire counters showing
# which arm ran. Pages are encoded here from parquet-format's Encodings.md:
# a dictionary page is PLAIN values; a data page is one bit-width byte then
# the RLE / Bit-Packing Hybrid of the codes. Expected values are
# dictionary[code].
from std.sys import simd_width_of
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.primitive_array import PrimitiveArray

from komira_parquet.dictionary import DictionaryDecoder, _check_index_count
from komira_parquet.dictionary_resolve import _validate_dict_indices
from komira_parquet.decode_arm_trace import (
    dict_resolve_fused_count,
    dict_resolve_legacy_count,
    reset_decode_arm_counts,
    reset_decode_arm_gates,
    set_dict_resolve_fused_enabled,
)


# --- encoders ----------------------------------------------------------------


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _uleb(mut out: List[UInt8], v: Int):
    var x = v
    while True:
        var b = x & 0x7F
        x >>= 7
        if x != 0:
            out.append(UInt8(b | 0x80))
        else:
            out.append(UInt8(b))
            return


def _bitpacked(mut out: List[UInt8], values: List[Int], bw: Int):
    """One bit-packed run of `values` (padded with zeros to a multiple of 8),
    LSB-first."""
    var groups = (len(values) + 7) // 8
    _uleb(out, (groups << 1) | 1)
    var acc = 0
    var nbits = 0
    for i in range(groups * 8):
        var v = values[i] if i < len(values) else 0
        acc |= v << nbits
        nbits += bw
        while nbits >= 8:
            out.append(UInt8(acc & 0xFF))
            acc >>= 8
            nbits -= 8
    if nbits > 0:
        out.append(UInt8(acc & 0xFF))


def _rle_run(mut out: List[UInt8], count: Int, value: Int, bw: Int):
    _uleb(out, count << 1)
    _le(out, value, (bw + 7) // 8)


def _index_page(values: List[Int], bw: Int) -> List[UInt8]:
    var page: List[UInt8] = [UInt8(bw)]
    _bitpacked(page, values, bw)
    return page^


def _ramp(n: Int, modulo: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        out.append((i * 5 + 2) % modulo)
    return out^


def _codes(values: List[Int]) raises -> PrimitiveArray[DType.int32]:
    var arr = PrimitiveArray[DType.int32].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, Int32(values[i]))
    return arr^


def _i32_page(values: List[Int]) -> List[UInt8]:
    var page = List[UInt8]()
    for i in range(len(values)):
        _le(page, values[i], 4)
    return page^


def _i64_page(values: List[Int]) -> List[UInt8]:
    var page = List[UInt8]()
    for i in range(len(values)):
        _le(page, values[i], 8)
    return page^


def _f32_page(values: List[Float32]) -> List[UInt8]:
    var page = List[UInt8]()
    for i in range(len(values)):
        _le(page, Int(values[i].to_bits()), 4)
    return page^


def _f64_page(values: List[Float64]) -> List[UInt8]:
    var page = List[UInt8]()
    for i in range(len(values)):
        _le(page, Int(values[i].to_bits()), 8)
    return page^


def _raises(msg_part: String, err: String) raises:
    assert_true(msg_part in err, "expected '" + msg_part + "' in: " + err)


# --- loading the dictionary --------------------------------------------------


def test_dictionary_readout_int64_int32_and_none() raises:
    var d = DictionaryDecoder()
    assert_false(d.has_int64_dict())
    assert_false(d.has_int32_dict())
    try:
        _ = d.dict_entries_as_int64()
        assert_true(False, "no numeric dictionary must raise")
    except e:
        _raises("no numeric dictionary", String(e))
    var v64: List[Int] = [5, -9, 1 << 40]
    var _p1 = _i64_page(v64)
    d.init_dict_int64(Span(_p1), 3)
    assert_true(d.has_int64_dict())
    var e64 = d.dict_entries_as_int64()
    assert_equal(len(e64), 3)
    assert_equal(e64[2], Int64(1 << 40))
    var d32 = DictionaryDecoder()
    var v32: List[Int] = [7, -3]
    var _p2 = _i32_page(v32)
    d32.init_dict_int32(Span(_p2), 2)
    assert_true(d32.has_int32_dict())
    var e32 = d32.dict_entries_as_int64()
    assert_equal(e32[1], Int64(-3))


def test_declared_size_past_the_decoded_entries_is_refused() raises:
    """`dict_size` is the page's declared count; the readout walks the decoded
    array only after checking the two agree (and that the count is not
    negative). Both numeric arms check."""
    var v: List[Int] = [1, 2]
    var d = DictionaryDecoder()
    var _p3 = _i64_page(v)
    d.init_dict_int64(Span(_p3), 2)
    d.dict_size = 3
    try:
        _ = d.dict_entries_as_int64()
        assert_true(False, "a declared size past the decoded entries")
    except e:
        _raises("declares 3 entries but only 2", String(e))
    d.dict_size = -1
    try:
        _ = d.dict_entries_as_int64()
        assert_true(False, "a negative declared size")
    except e:
        _raises("INT64", String(e))
    var d32 = DictionaryDecoder()
    var _p4 = _i32_page(v)
    d32.init_dict_int32(Span(_p4), 2)
    d32.dict_size = 5
    try:
        _ = d32.dict_entries_as_int64()
        assert_true(False, "INT32 arm")
    except e:
        _raises("INT32", String(e))


def test_init_every_type_and_a_short_page() raises:
    var d = DictionaryDecoder()
    var f32: List[Float32] = [Float32(1.5), Float32(-0.0)]
    var _p5 = _f32_page(f32)
    d.init_dict_float32(Span(_p5), 2)
    assert_equal(d.dict_values_float32.value().get(1).to_bits(), Float32(-0.0).to_bits())
    var f64: List[Float64] = [Float64(2.25)]
    var _p6 = _f64_page(f64)
    d.init_dict_float64(Span(_p6), 1)
    assert_equal(d.dict_values_float64.value().get(0), Float64(2.25))
    var flba: List[UInt8] = [1, 2, 3, 4, 5, 6]
    d.init_dict_fixed_len_byte_array(Span(flba), 2, 3)
    assert_equal(d.dict_flba_type_length, 3)
    assert_equal(d.dict_size, 2)
    var ba = List[UInt8]()
    _le(ba, 2, 4)
    ba.append(UInt8(ord("h")))
    ba.append(UInt8(ord("i")))
    d.init_dict_byte_array(Span(ba), 1)
    assert_equal(d.dict_values_bytes.value().get(0), String("hi"))
    # A page too short for its declared count is refused by the PLAIN decode.
    var three: List[Int] = [1, 2, 3]
    var short = _i32_page(three)
    var refused = False
    try:
        d.init_dict_int32(Span(short)[:11], 3)
    except e:
        refused = True
    assert_true(refused, "a short dictionary page must be refused")


# --- decoding index pages ----------------------------------------------------


def test_decode_indices_bitpacked_rle_and_width_zero() raises:
    var d = DictionaryDecoder()
    for bw in range(1, 12):
        var vals = _ramp(37, 1 << bw)
        var _p7 = _index_page(vals, bw)
        var got = d.decode_indices(Span(_p7), 37)
        assert_equal(got.length, 37)
        for i in range(37):
            assert_equal(Int(got.get(i)), vals[i], "bw " + String(bw))
    var rle: List[UInt8] = [UInt8(9)]
    _rle_run(rle, 6, 300, 9)
    var r = d.decode_indices(Span(rle), 6)
    for i in range(6):
        assert_equal(Int(r.get(i)), 300)
    var zero: List[UInt8] = [UInt8(0)]
    var z = d.decode_indices(Span(zero), 5)
    assert_equal(z.length, 5)
    for i in range(5):
        assert_equal(Int(z.get(i)), 0)


def test_decode_indices_truncated_empty_and_refused() raises:
    var d = DictionaryDecoder()
    # Eight codes encoded, twenty asked for: the rest are zero.
    var vals: List[Int] = [3, 1, 2, 3, 1, 2, 3, 1]
    var _p8 = _index_page(vals, 2)
    var got = d.decode_indices(Span(_p8), 20)
    assert_equal(got.length, 20)
    for i in range(20):
        assert_equal(Int(got.get(i)), vals[i] if i < 8 else 0)
    # No bytes, or no values: an empty array.
    var _p9 = List[UInt8]()
    assert_equal(d.decode_indices(Span(_p9), 4).length, 0)
    var _p10 = _index_page(vals, 2)
    assert_equal(d.decode_indices(Span(_p10), 0).length, 0)
    var counts: List[Int] = [-1, 2147483648]
    for ci in range(len(counts)):
        try:
            var _p11 = _index_page(vals, 2)
            _ = d.decode_indices(Span(_p11), counts[ci])
            assert_true(False, "count " + String(counts[ci]))
        except e:
            _raises("cannot hold", String(e))
    var wide: List[UInt8] = [UInt8(33), UInt8(1), UInt8(0)]
    var refused = False
    try:
        _ = d.decode_indices(Span(wide), 1)
    except e:
        refused = True
    assert_true(refused, "a bit width past 32 must be refused")


def test_decode_indices_into_writes_only_its_count() raises:
    var d = DictionaryDecoder()
    var vals = _ramp(13, 16)
    var dest = List[Int32](length=16, fill=Int32(-7))
    var _p12 = _index_page(vals, 4)
    d.decode_indices_into(Span(_p12), 13, Span(dest))
    for i in range(16):
        assert_equal(Int(dest[i]), vals[i] if i < 13 else -7, "slot " + String(i))
    # Width zero, truncated, empty data, zero values.
    var zero: List[UInt8] = [UInt8(0)]
    d.decode_indices_into(Span(zero), 3, Span(dest))
    assert_equal(Int(dest[2]), 0)
    assert_equal(Int(dest[3]), vals[3])
    var eight: List[Int] = [1, 1, 1, 1, 1, 1, 1, 1]
    var _p13 = _index_page(eight, 1)
    d.decode_indices_into(Span(_p13), 12, Span(dest))
    assert_equal(Int(dest[7]), 1)
    assert_equal(Int(dest[8]), 0)
    assert_equal(Int(dest[11]), 0)
    assert_equal(Int(dest[12]), vals[12])
    var _p14 = List[UInt8]()
    d.decode_indices_into(Span(_p14), 4, Span(dest))
    d.decode_indices_into(Span(zero), 0, Span(dest))
    assert_equal(Int(dest[0]), 1, "no bytes, or no values, writes nothing")
    assert_equal(Int(dest[12]), vals[12])


def test_decode_indices_into_refusals() raises:
    var d = DictionaryDecoder()
    var dest = List[Int32](length=4, fill=Int32(9))
    var vals: List[Int] = [1, 0, 1, 0, 1]
    try:
        var _p15 = _index_page(vals, 1)
        d.decode_indices_into(Span(_p15), 5, Span(dest))
        assert_true(False, "more indices than the destination holds")
    except e:
        _raises("do not fit a destination of 4", String(e))
    for i in range(4):
        assert_equal(Int(dest[i]), 9, "nothing written before the refusal")
    try:
        var _p16 = _index_page(vals, 1)
        d.decode_indices_into(Span(_p16), -2, Span(dest))
        assert_true(False, "a negative count")
    except e:
        _raises("cannot hold -2", String(e))


def test_check_index_count_bounds() raises:
    _check_index_count("x", 0)
    _check_index_count("x", 2147483647)
    var bad: List[Int] = [-1, 2147483648]
    for i in range(len(bad)):
        try:
            _check_index_count("x", bad[i])
            assert_true(False, "count " + String(bad[i]))
        except e:
            _raises("DictionaryDecoder.x", String(e))


# --- numeric resolves, both arms ---------------------------------------------


def _resolve_both_arms_int64(d: DictionaryDecoder, codes: List[Int]) raises:
    ref dv = d.dict_values_int64.value()
    for arm in range(2):
        set_dict_resolve_fused_enabled(arm == 0)
        reset_decode_arm_counts()
        var got = d.resolve_int64(_codes(codes))
        assert_equal(got.length, len(codes))
        for i in range(len(codes)):
            assert_equal(got.get(i), dv.get(codes[i]), "row " + String(i))
        assert_equal(dict_resolve_fused_count(), 1 if arm == 0 else 0)
        assert_equal(dict_resolve_legacy_count(), 0 if arm == 0 else 1)
    reset_decode_arm_gates()


def test_resolve_int64_both_arms_every_length() raises:
    """Lengths around the SIMD width and past the prefetch distance (16), so
    the legacy arm runs its SIMD body with and without the prefetch and its
    scalar tail."""
    comptime W = simd_width_of[DType.int64]()
    var vals = List[Int]()
    for i in range(40):
        vals.append(i * 1000000007 - 5)
    var d = DictionaryDecoder()
    var _p17 = _i64_page(vals)
    d.init_dict_int64(Span(_p17), 40)
    var counts: List[Int] = [0, 1, W - 1, W, W + 1, 16, 17, 33, 100]
    for ci in range(len(counts)):
        _resolve_both_arms_int64(d, _ramp(counts[ci], 40))


def test_resolve_int32_float32_float64_both_arms() raises:
    var n = 23
    var iv = List[Int]()
    var fv = List[Float32]()
    var dv = List[Float64]()
    for i in range(n):
        iv.append(-i * 77 + 11)
        fv.append(Float32(i) * 0.25 - 1.0)
        dv.append(Float64(i) * -3.5 + 0.125)
    var d = DictionaryDecoder()
    var _p18 = _i32_page(iv)
    d.init_dict_int32(Span(_p18), n)
    var _p19 = _f32_page(fv)
    d.init_dict_float32(Span(_p19), n)
    var _p20 = _f64_page(dv)
    d.init_dict_float64(Span(_p20), n)
    var counts: List[Int] = [0, 1, 7, 8, 9, 16, 17, 31, 32, 33, 40, 101]
    for arm in range(2):
        set_dict_resolve_fused_enabled(arm == 0)
        for ci in range(len(counts)):
            var codes = _ramp(counts[ci], n)
            reset_decode_arm_counts()
            var a = d.resolve_int32(_codes(codes))
            var b = d.resolve_float32(_codes(codes))
            var c = d.resolve_float64(_codes(codes))
            for i in range(len(codes)):
                assert_equal(Int(a.get(i)), iv[codes[i]])
                assert_equal(b.get(i).to_bits(), fv[codes[i]].to_bits())
                assert_equal(c.get(i).to_bits(), dv[codes[i]].to_bits())
            assert_equal(dict_resolve_fused_count(), 3 if arm == 0 else 0)
            assert_equal(dict_resolve_legacy_count(), 0 if arm == 0 else 3)
    reset_decode_arm_gates()


def test_resolve_without_a_dictionary_raises() raises:
    var d = DictionaryDecoder()
    var codes: List[Int] = [0]
    var names: List[String] = ["Int32", "Int64", "Float32", "Float64"]
    for k in range(4):
        try:
            if k == 0:
                _ = d.resolve_int32(_codes(codes))
            elif k == 1:
                _ = d.resolve_int64(_codes(codes))
            elif k == 2:
                _ = d.resolve_float32(_codes(codes))
            else:
                _ = d.resolve_float64(_codes(codes))
            assert_true(False, names[k])
        except e:
            _raises("no " + names[k] + " dictionary loaded", String(e))


def test_corrupt_codes_raise_the_same_message_on_both_arms() raises:
    """The fused arm gathers nothing for an out-of-range code and falls
    through to the whole-array validator; the legacy arm runs it first. Both
    raise naming the min and max over the WHOLE stream, and the fall-through
    counts as a legacy fire."""
    var vals: List[Int] = [1, 2, 3]
    var d = DictionaryDecoder()
    var _p21 = _i32_page(vals)
    d.init_dict_int32(Span(_p21), 3)
    var _p22 = _i64_page(vals)
    d.init_dict_int64(Span(_p22), 3)
    var f: List[Float32] = [Float32(1), Float32(2), Float32(3)]
    var g: List[Float64] = [Float64(1), Float64(2), Float64(3)]
    var _p23 = _f32_page(f)
    d.init_dict_float32(Span(_p23), 3)
    var _p24 = _f64_page(g)
    d.init_dict_float64(Span(_p24), 3)
    var codes: List[Int] = [0, 1, 2, 2, 1, 0, 1, 2, 3, 0, -4]
    for arm in range(2):
        set_dict_resolve_fused_enabled(arm == 0)
        for k in range(4):
            reset_decode_arm_counts()
            try:
                if k == 0:
                    _ = d.resolve_int32(_codes(codes))
                elif k == 1:
                    _ = d.resolve_int64(_codes(codes))
                elif k == 2:
                    _ = d.resolve_float32(_codes(codes))
                else:
                    _ = d.resolve_float64(_codes(codes))
                assert_true(False, "corrupt codes must raise")
            except e:
                _raises("codes in [-4, 3]", String(e))
                _raises("holds only 3 entries", String(e))
            assert_equal(dict_resolve_fused_count(), 0)
            assert_equal(dict_resolve_legacy_count(), 1)
    reset_decode_arm_gates()


def test_validate_dict_indices_every_shape() raises:
    comptime W = simd_width_of[DType.int32]()
    _validate_dict_indices(_codes(List[Int]()), 0, "empty")
    var one: List[Int] = [0]
    try:
        _validate_dict_indices(_codes(one), 0, "w")
        assert_true(False, "codes and no dictionary")
    except e:
        _raises("w has 1 codes to resolve but the dictionary holds no entries", String(e))
    var lengths: List[Int] = [1, W - 1, W, W + 1, 3 * W + 2]
    for li in range(len(lengths)):
        var n = lengths[li]
        var vals = _ramp(n, 6)
        _validate_dict_indices(_codes(vals), 6, "ok")
        var low = vals.copy()
        low[n - 1] = -1
        var high = vals.copy()
        high[0] = 6
        for which in range(2):
            var bad = _codes(low) if which == 0 else _codes(high)
            try:
                _validate_dict_indices(bad, 6, "v")
                assert_true(False, "out of range n=" + String(n))
            except e:
                _raises("holds only 6 entries", String(e))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
