# Direct tests of the PLAIN decoders in `plain.mojo`: the fixed-width
# decoders, their zero-copy twins, BOOLEAN, BYTE_ARRAY (both walks) and INT96.
# Every expected value comes from the format's definition (Encodings.md:
# PLAIN is the values back to back, little-endian; BOOLEAN is bit-packed
# LSB-first; BYTE_ARRAY is a 4-byte little-endian length then the bytes).
# Each refusal is asserted on its message, so a mutant that refuses for a
# different reason, or later, is caught as surely as one that accepts.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from komira_parquet.plain import (
    _require_plain_extent,
    decode_plain_boolean,
    decode_plain_byte_array,
    decode_plain_float32,
    decode_plain_float32_zero_copy,
    decode_plain_float64,
    decode_plain_float64_zero_copy,
    decode_plain_int32,
    decode_plain_int32_zero_copy,
    decode_plain_int64,
    decode_plain_int64_zero_copy,
    decode_plain_int96_to_int64,
)
from komira_parquet.scan_copy_trace import (
    plain_ba_fused_alloc_bytes,
    plain_ba_fused_count,
    plain_ba_slack_bytes,
    plain_ba_two_pass_count,
    reset_scan_copy_counts,
    reset_scan_copy_gates,
    set_plain_ba_fused_enabled,
)

comptime _HUGE = 1 << 62
"""A header-supplied count whose byte size wraps Int at widths 4, 8 and 12."""


def _le(v: UInt64, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for k in range(width):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))
    return out^


def _extend(mut dst: List[UInt8], src: List[UInt8]):
    for i in range(len(src)):
        dst.append(src[i])


def _ba_page(values: List[String]) -> List[UInt8]:
    """A PLAIN BYTE_ARRAY page: [u32 LE length][bytes] per value."""
    var page = List[UInt8]()
    for i in range(len(values)):
        var n = values[i].byte_length()
        _extend(page, _le(UInt64(n), 4))
        var b = values[i].as_bytes()
        for k in range(n):
            page.append(b[k])
    return page^


def _shared(bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    var buf = OwnedAlignedBuffer(max(len(bytes), 1))
    for i in range(len(bytes)):
        buf.write_u8_at(i, bytes[i])
    buf.set_length(Int64(len(bytes)))
    return SharedAlignedBuffer[HeapRegion].from_owned(buf^)


def _err_plain_int32(data: Span[UInt8, _], n: Int) raises -> String:
    try:
        _ = decode_plain_int32(data, n)
    except e:
        return String(e)
    return String("")


def _err_ba(data: Span[UInt8, _], n: Int, fused: Bool) raises -> String:
    set_plain_ba_fused_enabled(fused)
    var msg = String("")
    try:
        _ = decode_plain_byte_array(data, n)
    except e:
        msg = String(e)
    reset_scan_copy_gates()
    return msg^


# --- the extent check ---------------------------------------------------------


def test_extent_check_refusals_and_passes() raises:
    _require_plain_extent("X", 3, 4, 12)  # exact fit
    _require_plain_extent("X", 0, 4, 0)
    _require_plain_extent("X", 1 << 40, 0, 0)  # zero width reads nothing
    var cases: List[Tuple[Int, Int, Int, String]] = [
        (-1, 4, 12, "parquet: corrupt X page: negative value count -1"),
        (1, 4, -1, "parquet: corrupt X page: negative body length -1"),
        (
            4,
            4,
            12,
            "parquet: corrupt X page: declares 4 values (16 bytes at 4"
            " bytes/value) but the page body holds only 12 bytes",
        ),
    ]
    for i in range(len(cases)):
        var msg = String("")
        try:
            _require_plain_extent("X", cases[i][0], cases[i][1], cases[i][2])
        except e:
            msg = String(e)
        assert_equal(msg, cases[i][3])


def test_extent_check_refuses_a_count_whose_byte_size_wraps() raises:
    # 2^62 values of 12 bytes is 3 * 2^64 bytes: 0 after the wrap. A product
    # comparison passes it; the division refuses it.
    var refused = False
    try:
        _require_plain_extent("X", _HUGE, 12, 12)
    except:
        refused = True
    assert_true(refused, "a count whose byte size wraps must be refused")


# --- fixed width ----------------------------------------------------------------


def test_fixed_width_round_trips() raises:
    var page = List[UInt8]()
    for i in range(24):
        page.append(UInt8(i * 11 + 1))
    var i32 = decode_plain_int32(Span(page), 6)
    var i64 = decode_plain_int64(Span(page), 3)
    var f32 = decode_plain_float32(Span(page), 6)
    var f64 = decode_plain_float64(Span(page), 3)
    assert_equal(i32.length, 6)
    assert_equal(i64.length, 3)
    for k in range(6):
        var w = UInt32(0)
        for b in range(4):
            w |= UInt32(page[4 * k + b]) << UInt32(8 * b)
        assert_equal(i32.get(k), Int32(w))
        assert_equal(Int(f32.get(k).to_bits()), Int(w))
    for k in range(3):
        var w = UInt64(0)
        for b in range(8):
            w |= UInt64(page[8 * k + b]) << UInt64(8 * b)
        assert_equal(i64.get(k), Int64(w))
        assert_equal(Int(f64.get(k).to_bits()), Int(w))


def test_fixed_width_zero_values_and_short_pages() raises:
    var empty = List[UInt8]()
    assert_equal(decode_plain_int32(Span(empty), 0).length, 0)
    assert_equal(decode_plain_int64(Span(empty), 0).length, 0)
    assert_equal(decode_plain_float32(Span(empty), 0).length, 0)
    assert_equal(decode_plain_float64(Span(empty), 0).length, 0)
    var page = List[UInt8](length=7, fill=0)
    assert_equal(
        _err_plain_int32(Span(page), 2),
        "parquet: corrupt PLAIN fixed-width page: declares 2 values (8 bytes"
        " at 4 bytes/value) but the page body holds only 7 bytes",
    )
    assert_equal(
        _err_plain_int32(Span(page), -3),
        "parquet: corrupt PLAIN fixed-width page: negative value count -3",
    )


def test_fixed_width_refuses_a_count_whose_byte_size_wraps() raises:
    # 2^62 Int32s is 2^64 bytes, 0 after the wrap: the old product check
    # passed a 16-byte page and returned an array claiming 2^62 values.
    var page = List[UInt8](length=16, fill=0)
    var msg = _err_plain_int32(Span(page), _HUGE)
    assert_true(
        msg.startswith("parquet: corrupt PLAIN fixed-width page: declares "),
        "a wrapped byte size must be refused, got: " + msg,
    )


# --- zero copy ------------------------------------------------------------------


def test_zero_copy_aliases_the_page() raises:
    var page = List[UInt8]()
    for i in range(32):
        page.append(UInt8(255 - i))
    var a = decode_plain_int32_zero_copy(_shared(page), 8)
    var b = decode_plain_int64_zero_copy(_shared(page), 4)
    var c = decode_plain_float32_zero_copy(_shared(page), 5)
    var d = decode_plain_float64_zero_copy(_shared(page), 2)
    assert_equal(a.length, 8)
    assert_equal(b.length, 4)
    assert_equal(c.length, 5)
    assert_equal(d.length, 2)
    assert_equal(a.get(7), Int32(Int(page[28]) | (Int(page[29]) << 8) | (Int(page[30]) << 16) | (Int(page[31]) << 24)))
    var w = UInt64(0)
    for k in range(8):
        w |= UInt64(page[8 + k]) << UInt64(8 * k)
    assert_equal(b.get(1), Int64(w))
    assert_equal(Int(d.get(1).to_bits()), Int(w))
    # The buffer is trimmed to the values it holds.
    assert_equal(Int(c.data.len()), 20)


def test_zero_copy_zero_negative_short_and_wrapped_counts() raises:
    var page = List[UInt8](length=16, fill=0)
    assert_equal(decode_plain_int32_zero_copy(_shared(page), 0).length, 0)
    var counts: List[Int] = [-1, 5, _HUGE]
    for i in range(len(counts)):
        var msg = String("")
        try:
            _ = decode_plain_int32_zero_copy(_shared(page), counts[i])
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "parquet: PLAIN zero-copy decode declares "
            + String(counts[i])
            + " values ("
            + String(counts[i] * 4)
            + " bytes) but the page buffer holds only 16 bytes",
        )


# --- boolean ----------------------------------------------------------------------


def test_boolean_values_and_tail_mask() raises:
    var page: List[UInt8] = [UInt8(0xA5), UInt8(0xFF)]
    var full = decode_plain_boolean(Span(page), 16)
    assert_equal(full.length, 16)
    var expect: List[Bool] = [True, False, True, False, False, True, False, True]
    for k in range(8):
        assert_equal(full.get(k), expect[k])
        assert_true(full.get(8 + k))
    # 11 values: the last byte keeps 3 bits; the 5 above are cleared.
    var part = decode_plain_boolean(Span(page), 11)
    assert_equal(part.length, 11)
    assert_equal(part.true_count(), 4 + 3)
    assert_equal(decode_plain_boolean(Span(page)[0:0], 0).length, 0)


def test_boolean_refuses_short_and_negative_counts() raises:
    var page: List[UInt8] = [UInt8(1)]
    var cases: List[Tuple[Int, String]] = [
        (
            9,
            "parquet: corrupt PLAIN BOOLEAN page: declares 2 values (2 bytes at"
            " 1 bytes/value) but the page body holds only 1 bytes",
        ),
        # A negative count rounds to zero bytes, which every page holds: it
        # is refused on its own, before a bitmap of negative length exists.
        (-1, "parquet: corrupt PLAIN BOOLEAN page: negative value count -1"),
    ]
    for i in range(len(cases)):
        var msg = String("")
        try:
            _ = decode_plain_boolean(Span(page), cases[i][0])
        except e:
            msg = String(e)
        assert_equal(msg, cases[i][1])


# --- byte array ---------------------------------------------------------------------


def test_byte_array_both_walks_decode_the_same_values() raises:
    var values: List[String] = ["", "a", "bravo", "", "charlie-delta"]
    var page = _ba_page(values)
    for arm in range(2):
        set_plain_ba_fused_enabled(arm == 1)
        var arr = decode_plain_byte_array(Span(page), len(values))
        assert_equal(arr.length, len(values))
        for k in range(len(values)):
            assert_equal(arr.get(k), values[k])
    reset_scan_copy_gates()


def test_byte_array_counts_and_slack() raises:
    reset_scan_copy_counts()
    var values: List[String] = ["xy", "z"]
    var page = _ba_page(values)
    for _ in range(5):
        page.append(UInt8(0xEE))  # 5 bytes past the last value
    set_plain_ba_fused_enabled(True)
    _ = decode_plain_byte_array(Span(page), 2)
    assert_equal(plain_ba_fused_count(), 1)
    assert_equal(plain_ba_slack_bytes(), 5)
    assert_true(plain_ba_fused_alloc_bytes() >= 8)
    set_plain_ba_fused_enabled(False)
    _ = decode_plain_byte_array(Span(page), 2)
    assert_equal(plain_ba_two_pass_count(), 1)
    # Zero values: counted by neither walk.
    _ = decode_plain_byte_array(Span(page)[0:0], 0)
    assert_equal(plain_ba_two_pass_count() + plain_ba_fused_count(), 2)
    reset_scan_copy_gates()
    reset_scan_copy_counts()


def test_byte_array_refuses_a_negative_count() raises:
    var page = _ba_page(["a"])
    for arm in range(2):
        assert_equal(
            _err_ba(Span(page), -2, arm == 1),
            "parquet: decode_plain_byte_array: negative num_values -2",
        )


def test_byte_array_refuses_a_page_past_the_int32_offsets() raises:
    # A Span claiming 2^31 + 8 bytes over an 8-byte page: the refusal comes
    # before any byte is read. Without it the two-pass walk decodes the one
    # value and returns (the page itself is never past its 8 real bytes).
    var page = _ba_page(["abcd"])
    var fake = Span[UInt8, origin_of(page)](
        unsafe_ptr=page.unsafe_ptr(), length=(1 << 31) + 8
    )
    for arm in range(2):
        assert_equal(
            _err_ba(fake, 1, arm == 1),
            "parquet: decode_plain_byte_array: a page of 2147483656 bytes is"
            " past the 2147483647 bytes Int32 offsets can address",
        )
    # Exactly 2^31 - 1 bytes is not refused by that check (the walk then
    # refuses the count the page cannot hold: 2^29 values of 4 bytes).
    var at_max = Span[UInt8, origin_of(page)](
        unsafe_ptr=page.unsafe_ptr(), length=(1 << 31) - 1
    )
    var msg = _err_ba(at_max, 1 << 30, True)
    assert_true(msg.startswith("parquet: truncated PLAIN BYTE_ARRAY: the page holds"), msg)


def test_two_pass_offsets_are_sized_by_the_page_not_the_count() raises:
    # 16 MiB of zero-length values and a header count of 2^62. The two-pass
    # walk writes one offset per value until the page runs out; sized by the
    # header, `(2^62 + 1) * 4` wraps to a 4-byte buffer and those 4 Mi offset
    # writes run off its end. Sized by the page, the walk refuses at the
    # first missing prefix.
    var page = List[UInt8](length=16 << 20, fill=0)
    var msg = _err_ba(Span(page), _HUGE, False)
    assert_equal(
        msg,
        "parquet: truncated PLAIN BYTE_ARRAY: length prefix for value 4194304"
        " starts at byte 16777216 but the page holds only 16777216 bytes",
    )


# --- INT96 ------------------------------------------------------------------------


def test_int96_values_short_page_and_wrapped_count() raises:
    var page = List[UInt8]()
    _extend(page, _le(UInt64(5), 8))
    _extend(page, _le(UInt64(2440589), 4))  # one day after the epoch
    var arr = decode_plain_int96_to_int64(Span(page), 1)
    assert_equal(arr.get(0), Int64(86400000000000 + 5))
    assert_equal(decode_plain_int96_to_int64(Span(page), 0).length, 0)
    var counts: List[Int] = [2, _HUGE]
    for i in range(len(counts)):
        var msg = String("")
        try:
            _ = decode_plain_int96_to_int64(Span(page), counts[i])
        except e:
            msg = String(e)
        assert_true(
            msg.startswith("parquet: corrupt PLAIN INT96 page: declares "),
            "count " + String(counts[i]) + ": " + msg,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
