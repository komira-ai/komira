# =============================================================================
# tests/test_L2_h2_hpack.mojo — RFC 7541 HPACK encode/decode
# =============================================================================
#
# L2 unit tests. Covers:
#   * Integer encode/decode (5/6/7-bit prefix variants) per RFC 7541 §5.1
#   * String encode/decode (raw + Huffman decode) per RFC 7541 §5.2
#   * Static table lookups (RFC 7541 Appendix A)
#   * Dynamic table FIFO + eviction (RFC 7541 §4.4)
#   * 4 header-field representations (indexed / literal-incremental /
#     literal-no-index / literal-never-indexed) per RFC 7541 §6
#   * Dynamic-table-size-update (RFC 7541 §6.3 + §4.2)
#   * pending_min / pending_final two-field pipeline — the
#     double-SETTINGS scenario emits TWO size-update instructions
#
#
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.codec.h2 import (
    HpackDecoder,
    HpackDynamicTable,
    HpackEncoder,
    HpackHeader,
    decode_integer,
    decode_string,
    encode_integer,
    encode_string,
    hpack_static_lookup,
)


# =============================================================================
# §1 — Integer codec.
# =============================================================================


def test_integer_encode_decode_small_5bit() raises:
    """Per RFC 7541 §5.1: value=10, prefix=5 → encoded in low 5 bits
    of first byte = 0x0a (high 3 bits represent the discriminator)."""
    var out = List[UInt8]()
    encode_integer(UInt32(10), 5, UInt8(0x00), out)
    assert_equal(len(out), 1)
    assert_equal(Int(out[0]), 0x0a)
    var dec = decode_integer(Span(out), 0, 5)
    assert_true(dec.ok)
    assert_equal(Int(dec.value), 10)
    assert_equal(dec.consumed, 1)


def test_integer_encode_decode_at_prefix_boundary_5bit() raises:
    """value = 31 (2**5 - 1) is the prefix-saturation boundary; emits
    a continuation byte of 0."""
    var out = List[UInt8]()
    encode_integer(UInt32(31), 5, UInt8(0x00), out)
    assert_equal(len(out), 2)
    assert_equal(Int(out[0]), 0x1f)  # prefix all-1s
    assert_equal(Int(out[1]), 0x00)
    var dec = decode_integer(Span(out), 0, 5)
    assert_true(dec.ok)
    assert_equal(Int(dec.value), 31)


def test_integer_encode_decode_large_5bit() raises:
    """RFC 7541 §5.1 example: value=1337, prefix=5 →
       I = 0001 1111 (high 3 bits unused here) 0x1f
       remainder = 1337 - 31 = 1306
       1306 = 10100011010 → 10011010, 00001010 in 7-bit chunks reversed
       Encoded bytes: 0x1f, 0x9a, 0x0a."""
    var out = List[UInt8]()
    encode_integer(UInt32(1337), 5, UInt8(0x00), out)
    assert_equal(len(out), 3)
    assert_equal(Int(out[0]), 0x1f)
    assert_equal(Int(out[1]), 0x9a)
    assert_equal(Int(out[2]), 0x0a)
    var dec = decode_integer(Span(out), 0, 5)
    assert_true(dec.ok)
    assert_equal(Int(dec.value), 1337)


def test_integer_encode_decode_7bit() raises:
    """7-bit prefix used by string-length and the size-update update."""
    var out = List[UInt8]()
    encode_integer(UInt32(200), 7, UInt8(0x00), out)
    var dec = decode_integer(Span(out), 0, 7)
    assert_true(dec.ok)
    assert_equal(Int(dec.value), 200)


# =============================================================================
# §2 — String codec — raw round-trip.
# =============================================================================


def test_string_encode_decode_raw() raises:
    var out = List[UInt8]()
    encode_string(String("custom-header"), False, out)
    # First byte: H=0, length=13 → 0x0d. Then 13 bytes.
    assert_equal(len(out), 14)
    assert_equal(Int(out[0]), 0x0d)
    var dec = decode_string(Span(out), 0)
    assert_true(dec.ok)
    assert_equal(dec.value, String("custom-header"))
    assert_equal(dec.consumed, 14)


def test_string_encode_decode_empty() raises:
    var out = List[UInt8]()
    encode_string(String(""), False, out)
    assert_equal(len(out), 1)
    assert_equal(Int(out[0]), 0x00)
    var dec = decode_string(Span(out), 0)
    assert_true(dec.ok)
    assert_equal(dec.value, String(""))


# =============================================================================
# §3 — Huffman decode (one common header value).
# =============================================================================


def test_huffman_decode_ascii_space() raises:
    """Huffman code for space (0x20) is 010100 (6 bits). One space + EOS
    padding (2 bits of 1s) = 1 byte: 010100|11 = 0x53."""
    var buf = List[UInt8]()
    buf.append(UInt8(0x53))
    # H=1, length=1, data=0x53
    var wire = List[UInt8]()
    wire.append(UInt8(0x81))  # H=1, length=1
    wire.append(UInt8(0x53))
    var dec = decode_string(Span(wire), 0)
    assert_true(dec.ok)
    assert_equal(dec.value, String(" "))


# =============================================================================
# §4 — Static table lookups (RFC 7541 Appendix A).
# =============================================================================


def test_static_table_method_get() raises:
    var p = hpack_static_lookup(2)
    assert_equal(p[0], String(":method"))
    assert_equal(p[1], String("GET"))


def test_static_table_status_200() raises:
    var p = hpack_static_lookup(8)
    assert_equal(p[0], String(":status"))
    assert_equal(p[1], String("200"))


def test_static_table_user_agent_name_only() raises:
    var p = hpack_static_lookup(58)
    assert_equal(p[0], String("user-agent"))
    assert_equal(p[1], String(""))


def test_static_table_out_of_range() raises:
    var p = hpack_static_lookup(62)
    assert_equal(p[0], String(""))
    assert_equal(p[1], String(""))


# =============================================================================
# §5 — Dynamic table FIFO + eviction.
# =============================================================================


def test_dynamic_table_add_and_lookup() raises:
    var t = HpackDynamicTable(max_size=4096)
    t.add(String("custom-name"), String("custom-value"))
    assert_equal(t.count(), 1)
    var lk = t.lookup(0)
    assert_equal(lk[0], String("custom-name"))
    assert_equal(lk[1], String("custom-value"))
    # Entry size = len("custom-name") (11) + len("custom-value") (12) + 32 = 55.
    assert_equal(t.size, 55)


def test_dynamic_table_eviction_on_size_limit() raises:
    """RFC 7541 §4.4 — when adding an entry would exceed max_size,
    evict from the tail until it fits."""
    # max_size = 100. Two 55-byte entries fit (110 > 100, so the SECOND
    # add must evict the first).
    var t = HpackDynamicTable(max_size=100)
    t.add(String("a-name-1234"), String("a-value-9876"))  # 11+12+32=55
    assert_equal(t.count(), 1)
    t.add(String("b-name-1234"), String("b-value-9876"))  # 11+12+32=55, total 110 > 100
    # First should be evicted to make room.
    assert_equal(t.count(), 1)
    var lk = t.lookup(0)
    assert_equal(lk[0], String("b-name-1234"))


def test_dynamic_table_oversized_entry_empties_table() raises:
    """Per RFC 7541 §4.4: an entry larger than max_size leaves the
    table empty."""
    var t = HpackDynamicTable(max_size=50)
    t.add(String("short"), String("v"))  # 5+1+32=38 — fits
    assert_equal(t.count(), 1)
    # Now add an entry of 11+12+32=55 bytes — exceeds max_size=50.
    t.add(String("a-name-1234"), String("a-value-9876"))
    assert_equal(t.count(), 0)


def test_dynamic_table_set_max_size_evicts() raises:
    var t = HpackDynamicTable(max_size=200)
    t.add(String("a-name-1234"), String("a-value-9876"))  # 55
    t.add(String("b-name-1234"), String("b-value-9876"))  # 55, total 110
    assert_equal(t.count(), 2)
    # Shrink max_size — must evict tail.
    t.set_max_size(60)
    assert_equal(t.count(), 1)


# =============================================================================
# §6 — Encoder/decoder round-trip (literal-incremental representation).
# =============================================================================


def test_encoder_decoder_block_roundtrip() raises:
    """Encode a block of 3 headers through the encoder, decode through
    a peer decoder, assert all 3 names/values match."""
    var enc = HpackEncoder(max_table_size=4096)
    var dec = HpackDecoder(max_table_size=4096)

    var headers = List[HpackHeader]()
    headers.append(HpackHeader(String(":method"), String("POST")))
    headers.append(HpackHeader(String(":path"), String("/api")))
    headers.append(HpackHeader(String("content-type"), String("application/json")))

    var wire = enc.encode_block(headers^)
    var got = dec.decode_block(Span(wire))
    assert_equal(len(got), 3)
    assert_equal(got[0].name, String(":method"))
    assert_equal(got[0].value, String("POST"))
    assert_equal(got[1].name, String(":path"))
    assert_equal(got[1].value, String("/api"))
    assert_equal(got[2].name, String("content-type"))
    assert_equal(got[2].value, String("application/json"))


def test_decoder_indexed_static_entry() raises:
    """Encode "0x82" by hand (indexed static idx 2 = :method GET) and
    decode."""
    var dec = HpackDecoder()
    var wire = List[UInt8]()
    wire.append(UInt8(0x82))  # 1 0000010 → indexed, idx=2
    var got = dec.decode_block(Span(wire))
    assert_equal(len(got), 1)
    assert_equal(got[0].name, String(":method"))
    assert_equal(got[0].value, String("GET"))


# =============================================================================
# §7 — pending_min / pending_final two-field pipeline.
# =============================================================================
# This is thessue 1 cover test: the double-SETTINGS
# scenario where SETTINGS_HEADER_TABLE_SIZE changes 4096 → 256 → 4096
# between two HEADERS blocks. The encoder MUST emit TWO dynamic-table-
# size-update instructions at the start of the next block — the minimum
# (256) first, then the final (4096).


def test_size_update_single_change_emits_one() raises:
    """Single SETTINGS_HEADER_TABLE_SIZE change → ONE size-update
    instruction."""
    var enc = HpackEncoder(max_table_size=4096)
    enc.on_settings_ack_table_size(UInt32(2048))
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String("x-test"), String("v")))
    var wire = enc.encode_block(hdrs^)
    # The first byte(s) of `wire` MUST be a dynamic-table-size-update.
    # Encoded as 001xxxxx prefix (5-bit integer).
    # 2048 ≥ 31 → 0x3f + continuation bytes.
    assert_equal(Int(wire[0]), 0x3f)
    # remainder = 2048 - 31 = 2017 = 0b11111100001 = 7-bit chunks
    # low7 = 0b1100001 = 0x61 (with continuation bit set → 0xe1)
    # high4 = 0b1111 = 0x0f
    assert_equal(Int(wire[1]), 0xe1)
    assert_equal(Int(wire[2]), 0x0f)


def test_size_update_double_change_emits_two() raises:
    """double-SETTINGS scenario.

    Encoder sees SETTINGS_HEADER_TABLE_SIZE change from 4096 → 256 →
    4096 between two HEADERS blocks. At the start of the NEXT block,
    encoder MUST emit TWO size-update instructions:
      1. 256 (the minimum seen in the interval)
      2. 4096 (the final value)
    Then clear both pending fields.

    nghttp2 / Netty / golang.org/x/net/http2 all have shipped bugs in
    exactly this window when they used a single Optional[UInt32] field.
    The pending_min / pending_final two-field design avoids it.
    """
    var enc = HpackEncoder(max_table_size=4096)
    enc.on_settings_ack_table_size(UInt32(256))
    enc.on_settings_ack_table_size(UInt32(4096))
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String("x-t"), String("v")))
    var wire = enc.encode_block(hdrs^)
    # First update: 256.
    # 256 ≥ 31 → 0x3f + continuation.
    # 256 - 31 = 225 = 0b11100001 → low7 = 0b1100001 = 0x61, MSB set → 0xe1
    # high1 = 0b1 = 0x01
    assert_equal(Int(wire[0]), 0x3f)
    assert_equal(Int(wire[1]), 0xe1)
    assert_equal(Int(wire[2]), 0x01)
    # Second update: 4096.
    # 4096 ≥ 31 → 0x3f + continuation.
    # 4096 - 31 = 4065 = 0b111111100001 → low7=0x61, mid7=0x1f, high0
    # bytes: 0x3f, 0xe1 | 0x80 = 0xe1, 0x1f
    assert_equal(Int(wire[3]), 0x3f)
    assert_equal(Int(wire[4]), 0xe1)
    assert_equal(Int(wire[5]), 0x1f)


def test_size_update_min_equal_final_emits_one() raises:
    """When pending_min == pending_final (single update or non-decreasing
    sequence), encoder emits ONE size-update — the final."""
    var enc = HpackEncoder(max_table_size=4096)
    enc.on_settings_ack_table_size(UInt32(4096))
    enc.on_settings_ack_table_size(UInt32(4096))
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String("x"), String("v")))
    var wire = enc.encode_block(hdrs^)
    # 4096 ≥ 31 → 0x3f + 2 continuation bytes.
    # Then NO second size-update — block payload follows directly.
    assert_equal(Int(wire[0]), 0x3f)
    assert_equal(Int(wire[1]), 0xe1)
    assert_equal(Int(wire[2]), 0x1f)
    # Next byte must be the start of the header literal-incremental
    # representation, not another 001xxxxx size-update.
    var b3 = Int(wire[3])
    var is_size_update_prefix = ((b3 & 0xe0) == 0x20)
    assert_false(is_size_update_prefix)


# =============================================================================
# §8 — main.
# =============================================================================


def main() raises:
    print("test_L2_h2_hpack: start")
    test_integer_encode_decode_small_5bit()
    print(" integer_small_5bit PASS")
    test_integer_encode_decode_at_prefix_boundary_5bit()
    print(" integer_boundary_5bit PASS")
    test_integer_encode_decode_large_5bit()
    print(" integer_large_5bit PASS")
    test_integer_encode_decode_7bit()
    print(" integer_7bit PASS")
    test_string_encode_decode_raw()
    print(" string_raw PASS")
    test_string_encode_decode_empty()
    print(" string_empty PASS")
    test_huffman_decode_ascii_space()
    print(" huffman_decode_space PASS")
    test_static_table_method_get()
    print(" static_method_get PASS")
    test_static_table_status_200()
    print(" static_status_200 PASS")
    test_static_table_user_agent_name_only()
    print(" static_user_agent PASS")
    test_static_table_out_of_range()
    print(" static_out_of_range PASS")
    test_dynamic_table_add_and_lookup()
    print(" dynamic_add_lookup PASS")
    test_dynamic_table_eviction_on_size_limit()
    print(" dynamic_eviction PASS")
    test_dynamic_table_oversized_entry_empties_table()
    print(" dynamic_oversized_empties PASS")
    test_dynamic_table_set_max_size_evicts()
    print(" dynamic_set_max_evicts PASS")
    test_encoder_decoder_block_roundtrip()
    print(" encoder_decoder_block PASS")
    test_decoder_indexed_static_entry()
    print(" decoder_indexed_static PASS")
    test_size_update_single_change_emits_one()
    print(" size_update_single PASS")
    test_size_update_double_change_emits_two()
    print(" size_update_double PASS")
    test_size_update_min_equal_final_emits_one()
    print(" size_update_min_eq_final PASS")
    print("test_L2_h2_hpack: ALL 20 TESTS PASS")
