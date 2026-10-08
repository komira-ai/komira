# =============================================================================
# test_L2_hpack_coverage.mojo -- codec/h2/hpack.mojo against RFC 7541's own
# vectors, every decode error by its exact message, and every boundary
# =============================================================================
#
# The oracle is RFC 7541 itself, never this decoder's output:
#   * Appendix A (the static table, all 61 rows), Appendix B (the Huffman
#     code of every printable ASCII symbol, which is every symbol hpack.mojo
#     tabulates), Appendix C.1 (integers), C.2 (one example per
#     representation), C.3 and C.4 (three requests on one connection, raw and
#     Huffman), C.5 and C.6 (three responses with a 256-octet table, raw and
#     Huffman, with evictions). The hex dumps and the dynamic tables after each
#     block are copied from the RFC text; a table is rendered in the RFC's own
#     shape (`[  1] (s =  57) :authority: www.example.com`, without the
#     padding) so the expected strings read against the RFC line by line.
#   * The normative sentences of §4.4 (eviction), §5.1 (integers), §5.2
#     (string literals: padding and EOS), §6.1 (index 0), §2.3.3 (index past
#     both tables) and §4.2/§6.3 (dynamic table size update).
#
# Defects these tests catch, each planted in hpack.mojo and seen red: an
# eviction off by one in `add` (`>=` for `>`, before adding or for an entry
# equal to the maximum) or in `set_max_size`; a wrong integer prefix boundary
# (`<=` for `<`) in the encoder or the decoder; the sixth continuation octet
# accepted; the Huffman padding check skipped or widened to 8 bits; the 19-bit
# code length cut to 18; the dynamic-index offset off by one; index 61 sent
# to the dynamic table (`<` for `<=` at the static boundary); a size update
# equal to the ceiling refused. Every decode error is matched by its exact
# message, so renaming one or merging two fails too.
#
# Not pinned here, on purpose, because hpack.mojo does not do what RFC 7541
# requires and a test of today's result would pin the defect: Huffman symbols
# outside 0x20..0x7e (Appendix B codes all 256), raw octets of 0x80 and above
# (decoded one code point per octet, so `c3 a9` reads back as 4 bytes), and a
# size update that grows the table again after an earlier block shrank it
# (refused: the ceiling checked is the table's maximum size as it stood at
# the start of the block, not the SETTINGS_HEADER_TABLE_SIZE of §4.2).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.hpack import (
    HPACK_DEFAULT_MAX_HEADER_LIST_SIZE,
    HpackDecoder,
    HpackDynamicTable,
    HpackEncoder,
    HpackHeader,
    _HpackEntry,
    decode_integer,
    decode_string,
    encode_integer,
    encode_string,
    hpack_static_lookup,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _hex(text: String) raises -> List[UInt8]:
    """Octets of an RFC hex dump (lowercase digits, spaces ignored)."""
    var out = List[UInt8]()
    var src = text.as_bytes()
    var hi = -1
    for i in range(len(src)):
        var c = Int(src[i])
        if c == 0x20:
            continue
        var v: Int
        if c >= 0x30 and c <= 0x39:
            v = c - 0x30
        elif c >= 0x61 and c <= 0x66:
            v = c - 0x61 + 10
        else:
            raise Error("_hex: not a lowercase hex digit at " + String(i))
        if hi < 0:
            hi = v
        else:
            out.append(UInt8(hi * 16 + v))
            hi = -1
    if hi >= 0:
        raise Error("_hex: odd number of digits")
    return out^


def _render_headers(got: List[HpackHeader]) -> String:
    """`name: value\\n` per header, the RFC's "Decoded header list"."""
    var s = String()
    for i in range(len(got)):
        s += got[i].name + ": " + got[i].value + "\n"
    return s


def _render_table(t: HpackDynamicTable) -> String:
    """The RFC's "Dynamic Table (after decoding)", unpadded."""
    var s = String()
    for i in range(t.count()):
        var e = t.lookup(i)
        s += (
            "[" + String(i + 1) + "] (s = " + String(t.entries[i].entry_size)
            + ") " + e[0] + ": " + e[1] + "\n"
        )
    s += "Table size: " + String(t.size) + "\n"
    return s


def _decode(mut dec: HpackDecoder, dump: String) raises -> String:
    var block = _hex(dump)
    return _render_headers(dec.decode_block(Span(block)))


def _decode_error(mut dec: HpackDecoder, dump: String) raises -> String:
    """The decode error's message, or "" when the block decoded."""
    var block = _hex(dump)
    try:
        var got = dec.decode_block(Span(block))
        _ = len(got)
    except e:
        return String(e)
    return String("")


def _assert_refused(dump: String, expected: String) raises:
    var dec = HpackDecoder()
    assert_equal(_decode_error(dec, dump), expected, "block " + dump)


def _encode_int(value: UInt32, prefix: Int, high: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    encode_integer(value, prefix, high, out)
    return out^


def _as_hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var d = digits.as_bytes()
    var s = String()
    for i in range(len(b)):
        s += chr(Int(d[Int(b[i]) >> 4])) + chr(Int(d[Int(b[i]) & 15]))
    return s


# -----------------------------------------------------------------------------
# §5.1 integers (Appendix C.1)
# -----------------------------------------------------------------------------


def test_c1_3_integer_42_at_an_octet_boundary() raises:
    """C.1.3: 42 with an 8-bit prefix is the single octet 2a."""
    assert_equal(_as_hex(_encode_int(UInt32(42), 8, UInt8(0))), "2a")
    var buf = _hex("2a")
    var r = decode_integer(Span(buf), 0, 8)
    assert_true(r.ok)
    assert_equal(Int(r.value), 42)
    assert_equal(r.consumed, 1)


def test_c1_2_integer_1337_decodes_at_an_offset() raises:
    """C.1.2's `1f 9a 0a` (1337, 5-bit prefix) read at offset 2: `consumed`
    counts from `start`, and the 3 high bits of the first octet are the
    representation's, ignored (§5.1)."""
    var buf = _hex("aabb ff9a 0a")
    var r = decode_integer(Span(buf), 2, 5)
    assert_true(r.ok)
    assert_equal(Int(r.value), 1337)
    assert_equal(r.consumed, 3)


def test_integer_prefix_boundary_every_width() raises:
    """§5.1: a value below 2^N - 1 fits the prefix; 2^N - 1 itself takes a
    continuation octet 00. Every N from 1 to 8, both sides, encoded under
    high bits that must be kept, and decoded back."""
    for n in range(1, 9):
        var mask = (1 << n) - 1
        var high = UInt8((0xff << n) & 0xff)
        var below = _encode_int(UInt32(mask - 1), n, high)
        assert_equal(len(below), 1, "N=" + String(n))
        assert_equal(Int(below[0]), Int(high) | (mask - 1), "N=" + String(n))
        var at = _encode_int(UInt32(mask), n, high)
        assert_equal(len(at), 2, "N=" + String(n))
        assert_equal(Int(at[0]), Int(high) | mask, "N=" + String(n))
        assert_equal(Int(at[1]), 0, "N=" + String(n))
        var rb = decode_integer(Span(below), 0, n)
        assert_true(rb.ok)
        assert_equal(Int(rb.value), mask - 1, "N=" + String(n))
        assert_equal(rb.consumed, 1)
        var ra = decode_integer(Span(at), 0, n)
        assert_true(ra.ok)
        assert_equal(Int(ra.value), mask, "N=" + String(n))
        assert_equal(ra.consumed, 2)


def test_integer_continuation_octet_boundary() raises:
    """§5.1: the remainder 127 is one continuation octet (7f), 128 two
    (80 01)."""
    assert_equal(_as_hex(_encode_int(UInt32(31 + 127), 5, UInt8(0))), "1f7f")
    assert_equal(
        _as_hex(_encode_int(UInt32(31 + 128), 5, UInt8(0))), "1f8001"
    )
    var buf = _hex("1f80 01")
    var r = decode_integer(Span(buf), 0, 5)
    assert_true(r.ok)
    assert_equal(Int(r.value), 159)
    assert_equal(r.consumed, 3)


def test_integer_u32_max_round_trip_5bit_prefix() raises:
    """2^32 - 1 with a 5-bit prefix: 31 + 0xffffffe0, i.e. 1f e0 ff ff ff 0f,
    and one more (1f e1 ...) is past the implementation limit (§5.1)."""
    var enc = _encode_int(UInt32(0xFFFFFFFF), 5, UInt8(0))
    assert_equal(_as_hex(enc), "1fe0ffffff0f")
    var r = decode_integer(Span(enc), 0, 5)
    assert_true(r.ok)
    assert_equal(Int(r.value), 0xFFFFFFFF)
    assert_equal(r.consumed, 6)
    var over = _hex("1fe1 ffff ff0f")
    assert_false(decode_integer(Span(over), 0, 5).ok)


def test_integer_truncated_and_overlong_are_refused() raises:
    """No octet at `start`; a prefix asking for a continuation that is
    missing; a continuation that ends with the buffer; and a sixth
    continuation octet, past the widest 32-bit encoding (§5.1 "exceeds the
    implementation limit"). The last ends in 00, so only the octet-count
    ceiling refuses it: without it the integer ends there, ok."""
    var empty = List[UInt8]()
    var r0 = decode_integer(Span(empty), 0, 5)
    assert_false(r0.ok)
    assert_equal(r0.consumed, 0)
    var one = _hex("0a")
    assert_false(decode_integer(Span(one), 1, 5).ok)
    var t1 = _hex("1f")
    assert_false(decode_integer(Span(t1), 0, 5).ok)
    var t2 = _hex("1f80 80")
    assert_false(decode_integer(Span(t2), 0, 5).ok)
    var six = _hex("1f80 8080 8080 00")
    var r6 = decode_integer(Span(six), 0, 5)
    assert_false(r6.ok)
    assert_equal(r6.consumed, 0)


# -----------------------------------------------------------------------------
# §5.2 string literals, Appendix B Huffman
# -----------------------------------------------------------------------------


def test_string_raw_bounds() raises:
    """Raw literal at an offset; a length exactly to the end of the buffer
    decodes, one more octet of length is refused; no octet at `start` and a
    truncated length integer (7f, ff) are refused."""
    var buf = _hex("ee02 6162")
    var ok = decode_string(Span(buf), 1)
    assert_true(ok.ok)
    assert_equal(ok.value, "ab")
    assert_equal(ok.consumed, 3)
    var long = _hex("0361 62")
    assert_false(decode_string(Span(long), 0).ok)
    assert_false(decode_string(Span(buf), 4).ok)
    var t7 = _hex("7f")
    assert_false(decode_string(Span(t7), 0).ok)
    var th = _hex("ff")
    assert_false(decode_string(Span(th), 0).ok)


def test_appendix_b_every_tabulated_symbol() raises:
    """Every printable ASCII symbol 0x20..0x7e, in order, Huffman-coded by
    Appendix B (93 octets, 2 bits of EOS padding), decodes to itself: one
    wrong code in hpack.mojo's table breaks it."""
    var dump = String(
        "dd"
        "53f8fe7febff2afc7fafebfbf9ff7f4b2ec002265a6dc75e7ee7dfffc83feffc"
        "ffd4376f5fc187163c997367d1a756bd9b776fe1c797e73fdffdffff0ffe7ff9"
        "17ffd1c6490b2cd39ba75a29a8f5f6b109b7bf8f3ebdfffeff9ffefff7"
    )
    var buf = _hex(dump)
    var r = decode_string(Span(buf), 0)
    assert_true(r.ok)
    var want = String()
    for c in range(0x20, 0x7F):
        want += chr(c)
    assert_equal(r.value, want)
    assert_equal(r.consumed, 94)


def test_huffman_longest_code_and_padding_bounds() raises:
    """Appendix B: '\\' is the longest code tabulated (19 bits,
    7fff0), here with 5 bits of padding. §5.2: padding of 7 bits (five '0's,
    25 bits) is valid."""
    var bs = _hex("83ff fe1f")
    var r = decode_string(Span(bs), 0)
    assert_true(r.ok)
    assert_equal(r.value, "\\")
    var seven = _hex("8400 0000 7f")
    var r7 = decode_string(Span(seven), 0)
    assert_true(r7.ok)
    assert_equal(r7.value, "00000")
    assert_equal(r7.consumed, 5)
    # No padding at all: eight '0's are 40 bits, five whole octets; and the
    # empty Huffman string (80).
    var exact = _hex("8500 0000 0000")
    var re = decode_string(Span(exact), 0)
    assert_true(re.ok)
    assert_equal(re.value, "00000000")
    var nothing = _hex("80")
    var rn = decode_string(Span(nothing), 0)
    assert_true(rn.ok)
    assert_equal(rn.value, "")
    assert_equal(rn.consumed, 1)


def test_huffman_invalid_padding_and_eos_are_refused() raises:
    """§5.2: "A padding strictly longer than 7 bits MUST be treated as a
    decoding error" (ff: 8 bits of 1s, no symbol); "A padding not
    corresponding to the most significant bits of the code for the EOS
    symbol MUST be treated as a decoding error" (52: ' ' then padding 10);
    "A Huffman-encoded string literal containing the EOS symbol MUST be
    treated as a decoding error" (EOS, 30 bits of 1s, then 2 bits of 1s)."""
    var p8 = _hex("81ff")
    assert_false(decode_string(Span(p8), 0).ok)
    var p10 = _hex("8152")
    assert_false(decode_string(Span(p10), 0).ok)
    var eos = _hex("84ff ffff ff")
    assert_false(decode_string(Span(eos), 0).ok)


def test_encode_string_huffman_flag_emits_raw() raises:
    """The encoder's documented fallback: the Huffman flag emits a raw
    literal (H = 0), which any RFC 7541 decoder accepts (C.2.1's name)."""
    var out = List[UInt8]()
    encode_string(String("custom-key"), True, out)
    assert_equal(_as_hex(out), "0a637573746f6d2d6b6579")


# -----------------------------------------------------------------------------
# Appendix A static table, indices
# -----------------------------------------------------------------------------


def test_appendix_a_static_table_all_rows() raises:
    """Every row of Appendix A, and nothing at 0 or 62."""
    var got = String()
    for i in range(1, 62):
        var e = hpack_static_lookup(i)
        got += String(i) + " " + e[0] + ": " + e[1] + "\n"
    var want = String(
        "1 :authority: \n" "2 :method: GET\n" "3 :method: POST\n"
        "4 :path: /\n" "5 :path: /index.html\n" "6 :scheme: http\n"
        "7 :scheme: https\n" "8 :status: 200\n" "9 :status: 204\n"
        "10 :status: 206\n" "11 :status: 304\n" "12 :status: 400\n"
        "13 :status: 404\n" "14 :status: 500\n" "15 accept-charset: \n"
        "16 accept-encoding: gzip, deflate\n" "17 accept-language: \n"
        "18 accept-ranges: \n" "19 accept: \n"
        "20 access-control-allow-origin: \n" "21 age: \n" "22 allow: \n"
        "23 authorization: \n" "24 cache-control: \n"
        "25 content-disposition: \n" "26 content-encoding: \n"
        "27 content-language: \n" "28 content-length: \n"
        "29 content-location: \n" "30 content-range: \n"
        "31 content-type: \n" "32 cookie: \n" "33 date: \n" "34 etag: \n"
        "35 expect: \n" "36 expires: \n" "37 from: \n" "38 host: \n"
        "39 if-match: \n" "40 if-modified-since: \n" "41 if-none-match: \n"
        "42 if-range: \n" "43 if-unmodified-since: \n"
        "44 last-modified: \n" "45 link: \n" "46 location: \n"
        "47 max-forwards: \n" "48 proxy-authenticate: \n"
        "49 proxy-authorization: \n" "50 range: \n" "51 referer: \n"
        "52 refresh: \n" "53 retry-after: \n" "54 server: \n"
        "55 set-cookie: \n" "56 strict-transport-security: \n"
        "57 transfer-encoding: \n" "58 user-agent: \n" "59 vary: \n"
        "60 via: \n" "61 www-authenticate: \n"
    )
    assert_equal(got, want)
    var z = hpack_static_lookup(0)
    assert_equal(z[0], "")
    assert_equal(z[1], "")


def test_index_bounds() raises:
    """§6.1: "The index value of 0 is not used. It MUST be treated as a
    decoding error" (80). §2.3.3: indices 1..61 are the static table and
    62 is the first dynamic entry, so 61 is the last static row: indexed
    (bd) it is Appendix A's `www-authenticate` with an empty value, and a
    §6.2.1 literal naming it (7d 01 78) yields `www-authenticate: x` and
    indexes that field as 62 (be). An index past both tables is an error:
    62 (be) with an empty dynamic table, 63 (bf) with one entry, while 62
    then names that entry."""
    _assert_refused("80", "hpack: invalid index")
    _assert_refused("be", "hpack: invalid index")
    var d61 = HpackDecoder()
    assert_equal(_decode(d61, "bd"), "www-authenticate: \n")
    assert_equal(_decode(d61, "7d01 78"), "www-authenticate: x\n")
    assert_equal(
        _render_table(d61.table),
        "[1] (s = 49) www-authenticate: x\nTable size: 49\n",
    )
    assert_equal(
        _decode(d61, "bd be"), "www-authenticate: \nwww-authenticate: x\n"
    )
    var dec = HpackDecoder()
    assert_equal(_decode(dec, "4003 6162 6301 78"), "abc: x\n")
    assert_equal(_decode(dec, "be"), "abc: x\n")
    assert_equal(_decode_error(dec, "bf"), "hpack: invalid index")


# -----------------------------------------------------------------------------
# Appendix C.2: one example per representation
# -----------------------------------------------------------------------------


def test_c2_1_literal_with_indexing() raises:
    var dec = HpackDecoder()
    assert_equal(
        _decode(dec, "400a 6375 7374 6f6d 2d6b 6579 0d63 7573 746f 6d2d"
            " 6865 6164 6572"),
        "custom-key: custom-header\n",
    )
    assert_equal(
        _render_table(dec.table),
        "[1] (s = 55) custom-key: custom-header\nTable size: 55\n",
    )


def test_c2_1_encoder_emits_the_rfc_octets() raises:
    """The encoder's one representation (literal with incremental indexing,
    new name) is C.2.1's, octet for octet, and it indexes the field too."""
    var enc = HpackEncoder()
    var hs = List[HpackHeader]()
    hs.append(HpackHeader(String("custom-key"), String("custom-header")))
    var wire = enc.encode_block(hs^)
    assert_equal(
        _as_hex(wire),
        "400a637573746f6d2d6b65790d637573746f6d2d686561646572",
    )
    assert_equal(
        _render_table(enc.table),
        "[1] (s = 55) custom-key: custom-header\nTable size: 55\n",
    )


def test_c2_2_literal_without_indexing() raises:
    var dec = HpackDecoder()
    assert_equal(
        _decode(dec, "040c 2f73 616d 706c 652f 7061 7468"),
        ":path: /sample/path\n",
    )
    assert_equal(_render_table(dec.table), "Table size: 0\n")


def test_c2_3_literal_never_indexed() raises:
    var dec = HpackDecoder()
    assert_equal(
        _decode(dec, "1008 7061 7373 776f 7264 0673 6563 7265 74"),
        "password: secret\n",
    )
    assert_equal(_render_table(dec.table), "Table size: 0\n")


def test_c2_4_indexed() raises:
    var dec = HpackDecoder()
    assert_equal(_decode(dec, "82"), ":method: GET\n")
    assert_equal(_render_table(dec.table), "Table size: 0\n")


def test_literal_forms_the_rfc_does_not_show() raises:
    """§6.2.2 with a literal name (00), §6.2.3 with an indexed name (14 =
    :path), and each literal form naming a dynamic entry by a multi-octet
    index (62: 7e, 1f 2f, 0f 2f). Only §6.2.1 adds to the table."""
    var dec = HpackDecoder()
    assert_equal(_decode(dec, "0003 6162 6301 78"), "abc: x\n")
    assert_equal(_decode(dec, "1401 79"), ":path: y\n")
    assert_equal(_render_table(dec.table), "Table size: 0\n")
    assert_equal(_decode(dec, "4003 6e61 6d01 76"), "nam: v\n")
    assert_equal(_decode(dec, "7e01 77"), "nam: w\n")
    assert_equal(_decode(dec, "1f2f 0178"), "nam: x\n")
    assert_equal(_decode(dec, "0f2f 0179"), "nam: y\n")
    assert_equal(
        _render_table(dec.table),
        "[1] (s = 36) nam: w\n[2] (s = 36) nam: v\nTable size: 72\n",
    )


# -----------------------------------------------------------------------------
# Appendix C.3 / C.4: requests on one connection (table 4096)
# -----------------------------------------------------------------------------


def _req1() -> String:
    return String(
        ":method: GET\n:scheme: http\n:path: /\n:authority: www.example.com\n"
    )


def _req1_table() -> String:
    return String("[1] (s = 57) :authority: www.example.com\nTable size: 57\n")


def _req2() -> String:
    return _req1() + "cache-control: no-cache\n"


def _req2_table() -> String:
    return String(
        "[1] (s = 53) cache-control: no-cache\n"
        "[2] (s = 57) :authority: www.example.com\nTable size: 110\n"
    )


def _req3() -> String:
    return String(
        ":method: GET\n:scheme: https\n:path: /index.html\n"
        ":authority: www.example.com\ncustom-key: custom-value\n"
    )


def _req3_table() -> String:
    return String(
        "[1] (s = 54) custom-key: custom-value\n"
        "[2] (s = 53) cache-control: no-cache\n"
        "[3] (s = 57) :authority: www.example.com\nTable size: 164\n"
    )


def test_c3_requests_without_huffman() raises:
    var dec = HpackDecoder()
    assert_equal(
        _decode(dec, "8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d"),
        _req1(),
    )
    assert_equal(_render_table(dec.table), _req1_table())
    assert_equal(_decode(dec, "8286 84be 5808 6e6f 2d63 6163 6865"), _req2())
    assert_equal(_render_table(dec.table), _req2_table())
    assert_equal(
        _decode(dec, "8287 85bf 400a 6375 7374 6f6d 2d6b 6579 0c63 7573"
            " 746f 6d2d 7661 6c75 65"),
        _req3(),
    )
    assert_equal(_render_table(dec.table), _req3_table())


def test_c4_requests_with_huffman() raises:
    var dec = HpackDecoder()
    assert_equal(
        _decode(dec, "8286 8441 8cf1 e3c2 e5f2 3a6b a0ab 90f4 ff"), _req1()
    )
    assert_equal(_render_table(dec.table), _req1_table())
    assert_equal(_decode(dec, "8286 84be 5886 a8eb 1064 9cbf"), _req2())
    assert_equal(_render_table(dec.table), _req2_table())
    assert_equal(
        _decode(dec, "8287 85bf 4088 25a8 49e9 5ba9 7d7f 8925 a849 e95b"
            " b8e8 b4bf"),
        _req3(),
    )
    assert_equal(_render_table(dec.table), _req3_table())


# -----------------------------------------------------------------------------
# Appendix C.5 / C.6: responses, SETTINGS_HEADER_TABLE_SIZE 256, evictions
# -----------------------------------------------------------------------------


def _resp1() -> String:
    return String(
        ":status: 302\ncache-control: private\n"
        "date: Mon, 21 Oct 2013 20:13:21 GMT\n"
        "location: https://www.example.com\n"
    )


def _resp1_table() -> String:
    return String(
        "[1] (s = 63) location: https://www.example.com\n"
        "[2] (s = 65) date: Mon, 21 Oct 2013 20:13:21 GMT\n"
        "[3] (s = 52) cache-control: private\n"
        "[4] (s = 42) :status: 302\nTable size: 222\n"
    )


def _resp2() -> String:
    return String(
        ":status: 307\ncache-control: private\n"
        "date: Mon, 21 Oct 2013 20:13:21 GMT\n"
        "location: https://www.example.com\n"
    )


def _resp2_table() -> String:
    return String(
        "[1] (s = 42) :status: 307\n"
        "[2] (s = 63) location: https://www.example.com\n"
        "[3] (s = 65) date: Mon, 21 Oct 2013 20:13:21 GMT\n"
        "[4] (s = 52) cache-control: private\nTable size: 222\n"
    )


def _resp3() -> String:
    return String(
        ":status: 200\ncache-control: private\n"
        "date: Mon, 21 Oct 2013 20:13:22 GMT\n"
        "location: https://www.example.com\ncontent-encoding: gzip\n"
        "set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600;"
        " version=1\n"
    )


def _resp3_table() -> String:
    return String(
        "[1] (s = 98) set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU;"
        " max-age=3600; version=1\n"
        "[2] (s = 52) content-encoding: gzip\n"
        "[3] (s = 65) date: Mon, 21 Oct 2013 20:13:22 GMT\n"
        "Table size: 215\n"
    )


def test_c5_responses_without_huffman() raises:
    var dec = HpackDecoder(max_table_size=256)
    assert_equal(
        _decode(dec, "4803 3330 3258 0770 7269 7661 7465 611d 4d6f 6e2c"
            " 2032 3120 4f63 7420 3230 3133 2032 303a 3133 3a32 3120 474d"
            " 546e 1768 7474 7073 3a2f 2f77 7777 2e65 7861 6d70 6c65 2e63"
            " 6f6d"),
        _resp1(),
    )
    assert_equal(_render_table(dec.table), _resp1_table())
    assert_equal(_decode(dec, "4803 3330 37c1 c0bf"), _resp2())
    assert_equal(_render_table(dec.table), _resp2_table())
    assert_equal(
        _decode(dec, "88c1 611d 4d6f 6e2c 2032 3120 4f63 7420 3230 3133"
            " 2032 303a 3133 3a32 3220 474d 54c0 5a04 677a 6970 7738 666f"
            " 6f3d 4153 444a 4b48 514b 425a 584f 5157 454f 5049 5541 5851"
            " 5745 4f49 553b 206d 6178 2d61 6765 3d33 3630 303b 2076 6572"
            " 7369 6f6e 3d31"),
        _resp3(),
    )
    assert_equal(_render_table(dec.table), _resp3_table())


def test_c6_responses_with_huffman() raises:
    var dec = HpackDecoder(max_table_size=256)
    assert_equal(
        _decode(dec, "4882 6402 5885 aec3 771a 4b61 96d0 7abe 9410 54d4"
            " 44a8 2005 9504 0b81 66e0 82a6 2d1b ff6e 919d 29ad 1718 63c7"
            " 8f0b 97c8 e9ae 82ae 43d3"),
        _resp1(),
    )
    assert_equal(_render_table(dec.table), _resp1_table())
    assert_equal(_decode(dec, "4883 640e ffc1 c0bf"), _resp2())
    assert_equal(_render_table(dec.table), _resp2_table())
    assert_equal(
        _decode(dec, "88c1 6196 d07a be94 1054 d444 a820 0595 040b 8166"
            " e084 a62d 1bff c05a 839b d9ab 77ad 94e7 821d d7f2 e6c7 b335"
            " dfdf cd5b 3960 d5af 2708 7f36 72c1 ab27 0fb5 291f 9587 3160"
            " 65c0 03ed 4ee5 b106 3d50 07"),
        _resp3(),
    )
    assert_equal(_render_table(dec.table), _resp3_table())


# -----------------------------------------------------------------------------
# §4.4 eviction boundaries
# -----------------------------------------------------------------------------


def test_eviction_boundaries() raises:
    """§4.4: entries are evicted "until the size of the dynamic table is
    less than or equal to (maximum size - new entry size)", so two 55-octet
    entries fill a 110-octet table exactly; an entry equal to the maximum
    fits (only one "larger than the maximum size" empties the table); §4.3:
    a new maximum equal to the size evicts nothing, one octet less evicts
    the oldest."""
    var t = HpackDynamicTable(max_size=110)
    t.add(String("custom-key"), String("custom-value1"))
    t.add(String("custom-key"), String("custom-value2"))
    assert_equal(
        _render_table(t),
        "[1] (s = 55) custom-key: custom-value2\n"
        "[2] (s = 55) custom-key: custom-value1\nTable size: 110\n",
    )
    t.set_max_size(110)
    assert_equal(t.count(), 2)
    t.set_max_size(109)
    assert_equal(
        _render_table(t),
        "[1] (s = 55) custom-key: custom-value2\nTable size: 55\n",
    )
    var e = HpackDynamicTable(max_size=55)
    e.add(String("custom-key"), String("custom-header"))
    assert_equal(e.count(), 1)
    assert_equal(e.size, 55)
    var empty = HpackDynamicTable(max_size=54)
    empty.add(String("custom-key"), String("custom-header"))
    assert_equal(_render_table(empty), "Table size: 0\n")


def test_table_lookup_out_of_range_and_negative_max() raises:
    """`lookup` outside 0..count-1 gives an empty pair; a maximum below
    zero on an empty table returns (the eviction loop stops at an empty
    list)."""
    var t = HpackDynamicTable(max_size=100)
    t.add(String("a"), String("b"))
    var lo = t.lookup(-1)
    assert_equal(lo[0], "")
    assert_equal(lo[1], "")
    var hi = t.lookup(1)
    assert_equal(hi[0], "")
    assert_equal(hi[1], "")
    var z = HpackDynamicTable()
    z.set_max_size(-1)
    assert_equal(z.count(), 0)
    assert_equal(z.max_size, -1)


def test_defaults() raises:
    """RFC 9113 §6.5.2: SETTINGS_HEADER_TABLE_SIZE starts at 4096, for each
    constructor without an argument; the empty entry and header."""
    assert_equal(HpackDynamicTable().max_size, 4096)
    var dec = HpackDecoder()
    assert_equal(dec.table.max_size, 4096)
    assert_equal(dec.max_header_list_size, HPACK_DEFAULT_MAX_HEADER_LIST_SIZE)
    var enc = HpackEncoder()
    assert_equal(enc.table.max_size, 4096)
    assert_false(Bool(enc.pending_min))
    assert_false(Bool(enc.pending_final))
    var entry = _HpackEntry()
    assert_equal(entry.entry_size, 32)
    assert_equal(entry.name, "")
    var h = HpackHeader()
    assert_equal(h.name, "")
    assert_equal(h.value, "")


def test_decoder_set_max_table_size_evicts() raises:
    var dec = HpackDecoder()
    _ = _decode(dec, "8286 8441 0f77 7777 2e65 7861 6d70 6c65 2e63 6f6d")
    assert_equal(dec.table.count(), 1)
    dec.set_max_table_size(56)
    assert_equal(_render_table(dec.table), "Table size: 0\n")
    assert_equal(dec.table.max_size, 56)


# -----------------------------------------------------------------------------
# §4.2 / §6.3 dynamic table size update
# -----------------------------------------------------------------------------


def test_size_update_bounds() raises:
    """§6.3: the new maximum "MUST be lower than or equal to the limit";
    4096 (3f e1 1f) is accepted, 4097 (3f e2 1f) is a decoding error. A
    size update "MUST occur at the beginning of the first header block
    following the change" (§4.2): after a field (82 20) it is an error.
    Two at the start (0 then 4096, the encoder's min/final pair) are
    accepted, and the first empties the table."""
    var dec = HpackDecoder()
    assert_equal(_decode(dec, "3fe1 1f82"), ":method: GET\n")
    assert_equal(dec.table.max_size, 4096)
    _assert_refused(
        "3fe2 1f",
        "hpack: COMPRESSION_ERROR: size update above"
        " SETTINGS_HEADER_TABLE_SIZE",
    )
    _assert_refused(
        "8220", "hpack: COMPRESSION_ERROR: size update after header field"
    )
    _assert_refused("3f", "hpack: COMPRESSION_ERROR: size-update truncated")
    var d2 = HpackDecoder()
    _ = _decode(d2, "4003 6162 6301 78")
    assert_equal(d2.table.count(), 1)
    assert_equal(_decode(d2, "203f e11f 82"), ":method: GET\n")
    assert_equal(_render_table(d2.table), "Table size: 0\n")
    assert_equal(d2.table.max_size, 4096)


def test_encoder_size_update_pair_keeps_tables_in_step() raises:
    """The encoder's 0-then-4096 pair, decoded by a peer, leaves both tables
    equal: the old entry evicted, the new one indexed."""
    var enc = HpackEncoder()
    var dec = HpackDecoder()
    var h1 = List[HpackHeader]()
    h1.append(HpackHeader(String("a"), String("1")))
    var w1 = enc.encode_block(h1^)
    _ = dec.decode_block(Span(w1))
    enc.on_settings_ack_table_size(UInt32(0))
    enc.on_settings_ack_table_size(UInt32(4096))
    var h2 = List[HpackHeader]()
    h2.append(HpackHeader(String("b"), String("2")))
    var w2 = enc.encode_block(h2^)
    assert_equal(_as_hex(w2), "203fe11f4001620132")
    assert_equal(_render_headers(dec.decode_block(Span(w2))), "b: 2\n")
    var want = String("[1] (s = 34) b: 2\nTable size: 34\n")
    assert_equal(_render_table(enc.table), want)
    assert_equal(_render_table(dec.table), want)


def test_encoder_final_only_pending_update() raises:
    """`pending_final` without `pending_min` (a caller writing the public
    field) emits the one update, applies it and clears both."""
    var enc = HpackEncoder()
    enc.pending_final = Optional[UInt32](UInt32(100))
    var w = enc.encode_block(List[HpackHeader]())
    assert_equal(_as_hex(w), "3f45")
    assert_equal(enc.table.max_size, 100)
    assert_false(Bool(enc.pending_final))
    var none = enc.encode_block(List[HpackHeader]())
    assert_equal(len(none), 0)


# -----------------------------------------------------------------------------
# decode_block: every error, by its exact message
# -----------------------------------------------------------------------------


def test_every_representation_error_exact() raises:
    """Each representation's integer truncated, its name truncated or
    indexed past both tables, and its value truncated."""
    _assert_refused("ff", "hpack: indexed truncated")
    _assert_refused("7f", "hpack: literal-incremental idx truncated")
    _assert_refused("40", "hpack: name string truncated")
    _assert_refused("7e", "hpack: name index invalid")
    _assert_refused("41", "hpack: value string truncated")
    _assert_refused("1f", "hpack: never-indexed idx truncated")
    _assert_refused("10", "hpack: name truncated")
    _assert_refused("1f2f", "hpack: name index invalid")
    _assert_refused("11", "hpack: value truncated")
    _assert_refused("0f", "hpack: no-index idx truncated")
    _assert_refused("00", "hpack: name truncated")
    _assert_refused("0f2f", "hpack: name index invalid")
    _assert_refused("01", "hpack: value truncated")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
