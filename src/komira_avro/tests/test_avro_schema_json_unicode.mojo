# =============================================================================
# test_avro_schema_json_unicode.mojo — non-ASCII text in Avro schema JSON
# strings: `\u` escapes (including UTF-16 surrogate pairs) and raw UTF-8.
# =============================================================================
#
# The schema JSON comes from the `avro.schema` header entry of a file, so it is
# untrusted. Two defects lived in the JSON string decoder:
#
#   (a) each `\uXXXX` escape was decoded alone and handed to `chr()`; a
#       surrogate code point (half of a pair, or a lone one) ABORTED the
#       process. A crafted schema could kill the reader.
#   (b) each raw byte was widened with `chr(byte)`, so the UTF-8 bytes of `ü`
#       (C3 BC) came back as `Ã¼` (C3 83 C2 BC). The OCF header decoder did
#       the same widening on the whole `avro.schema` value before the JSON
#       parser ever saw it.
#
# What each test proves, and the defect it catches:
#   T1  "😀" decodes to U+1F600 (F0 9F 98 80), in a `default` and
#       next to a `doc`. Catches: pair not joined (abort, U+FFFD, or two
#       separately-encoded halves).
#   T2  lone high, lone low, reversed pair, high + non-`\u` escape, high + raw
#       char, high + high, high at end of string: each raises
#       MALFORMED_JSON. Catches: a surrogate reaching `chr()` (abort) or being
#       silently replaced.
#   T3  a non-hex digit in `\u` raises. Catches: `_hex_digit` mapping a bad
#       digit to 0 and mis-decoding.
#   T4  BMP escapes (1-, 2- and 3-byte UTF-8 results) still decode. Catches a
#       regression in the ordinary `\u` path.
#   T5  raw UTF-8 (2- and 4-byte) reads back byte-exact, also mixed with
#       escapes, in a default and in the refusal of a non-name enum symbol.
#       Catches: raw bytes widened through `chr()`.
#   T6  an OCF header whose `avro.schema` holds raw UTF-8 keeps it byte-exact
#       through `decode_ocf_header` and `parse_schema`. Catches the header-side
#       widening.
#   T7  an OCF header whose `avro.schema` is not UTF-8 (bad continuation, a
#       stray 0xFF, an encoded surrogate, a truncated sequence) is refused
#       with MALFORMED_JSON. Catches: invalid bytes accepted into a String.
#   T7b decode_ocf_header ALONE refuses a non-UTF-8 avro.schema with the exact
#       header-level text, whether the bad bytes sit inside a JSON string or
#       outside one. Catches: the header copy going unchecked (then only the
#       JSON parser, or nothing, would refuse).
#   T8  a header whose `avro.codec` value or a metadata key is not UTF-8 is
#       refused with MALFORMED_HEADER (the other two callers of the header's
#       byte-to-String copy).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import AvroSchema, decode_ocf_header, OCF_SYNC_LEN


def _bl(*xs: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for x in xs:
        out.append(UInt8(x))
    return out^


def _bytes(s: String) -> List[UInt8]:
    var out = _bl()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _assert_bytes(got: String, want: List[UInt8], what: String) raises:
    var g = got.as_bytes()
    assert_equal(len(g), len(want), what + ": byte length")
    for i in range(len(want)):
        assert_equal(Int(g[i]), Int(want[i]), what + ": byte " + String(i))


def _record_with(lit: String) -> String:
    """A record whose single string field carries `lit` (a JSON string
    literal, quotes included) as both its `doc` and its `default`."""
    return (
        String('{"type":"record","name":"R","doc":')
        + lit
        + ',"fields":[{"name":"a","type":"string","doc":'
        + lit
        + ',"default":'
        + lit
        + "}]}"
    )


def _default_of(lit: String) raises -> String:
    var s = AvroSchema.parse(_record_with(lit))
    return s.nodes[s.root_idx].field_defaults[0].str_val


def _assert_malformed(lit: String, what: String) raises:
    var raised = False
    try:
        var _s = AvroSchema.parse(_record_with(lit))
    except e:
        raised = True
        assert_true(
            "AvroSchemaError.MALFORMED_JSON" in String(e),
            what + ": wrong error: " + String(e),
        )
    assert_true(raised, what + ": expected MALFORMED_JSON")


def test_surrogate_pair_joins() raises:
    """T1."""
    var want = _bl(0xF0, 0x9F, 0x98, 0x80)
    _assert_bytes(_default_of(String('"\\uD83D\\uDE00"')), want, "pair")
    # Lower-case hex, and a pair embedded between ASCII.
    var want2 = _bl(0x78, 0xF0, 0x9F, 0x98, 0x80, 0x79)
    _assert_bytes(_default_of(String('"x\\ud83d\\ude00y"')), want2, "pair mid")
    # The highest code point, U+10FFFF = DBFF DFFF.
    var want3 = _bl(0xF4, 0x8F, 0xBF, 0xBF)
    _assert_bytes(_default_of(String('"\\uDBFF\\uDFFF"')), want3, "max")


def test_bad_surrogates_refused() raises:
    """T2."""
    _assert_malformed(String('"\\uD83D"'), "lone high")
    _assert_malformed(String('"\\uDE00"'), "lone low")
    _assert_malformed(String('"\\uDE00\\uD83D"'), "reversed pair")
    _assert_malformed(String('"\\uD83D\\n"'), "high + \\n")
    _assert_malformed(String('"\\uD83Dx"'), "high + raw char")
    _assert_malformed(String('"\\uD83D\\uD83D"'), "high + high")
    _assert_malformed(String('"\\uD83D\\u0041"'), "high + BMP")
    _assert_malformed(String('"\\uD83D\\uDE0"'), "high + short low")


def test_bad_hex_refused() raises:
    """T3."""
    _assert_malformed(String('"\\u00G1"'), "G")
    _assert_malformed(String('"\\u00 1"'), "space")
    _assert_malformed(String('"\\uD83D\\uDEz0"'), "bad hex in low half")


def test_bmp_escapes() raises:
    """T4."""
    _assert_bytes(_default_of(String('"\\u0041"')), _bl(0x41), "A")
    _assert_bytes(
        _default_of(String('"\\u00fc"')), _bl(0xC3, 0xBC), "u-umlaut"
    )
    _assert_bytes(
        _default_of(String('"\\u20AC"')),
        _bl(0xE2, 0x82, 0xAC),
        "euro",
    )
    _assert_bytes(
        _default_of(String('"\\uFFFF"')), _bl(0xEF, 0xBF, 0xBF), "FFFF"
    )
    _assert_bytes(
        _default_of(String('"\\uE000"')), _bl(0xEE, 0x80, 0x80), "E000"
    )


def test_raw_utf8_byte_exact() raises:
    """T5."""
    var raw = String("ü😀")
    _assert_bytes(
        _default_of(String('"') + raw + '"'),
        _bl(0xC3, 0xBC, 0xF0, 0x9F, 0x98, 0x80),
        "raw",
    )
    # Raw and escaped text interleaved: `aüüb\"€`.
    _assert_bytes(
        _default_of(String('"aü\\u00fcb\\"€"')),
        _bl(0x61, 0xC3, 0xBC, 0xC3, 0xBC, 0x62, 0x22, 0xE2, 0x82, 0xAC),
        "mixed",
    )
    # Enum symbols travel through the same decoder. `ü` is not an Avro name,
    # so the parser refuses it; the refusal quotes the decoded symbol, raw
    # or escaped, byte-exact.
    var want_err = String(
        "AvroSchemaError.INVALID_NAME: enum symbol 'ü' does not match"
        " [A-Za-z_][A-Za-z0-9_]*"
    )
    for lit in [String('"ü"'), String('"\\u00fc"')]:
        var got = String("<accepted>")
        try:
            _ = AvroSchema.parse(
                String('{"type":"enum","name":"E","symbols":[') + lit + "]}"
            )
        except e:
            got = String(e)
        assert_equal(got, want_err)


# -----------------------------------------------------------------------------
# OCF header path.
# -----------------------------------------------------------------------------

def _encode_long(n: Int64, mut out: List[UInt8]):
    var zz = UInt64((n << 1) ^ (n >> 63))
    while True:
        var b = UInt8(zz & 0x7F)
        zz >>= 7
        if zz != 0:
            out.append(b | 0x80)
        else:
            out.append(b)
            break


def _encode_raw(data: List[UInt8], mut out: List[UInt8]):
    _encode_long(Int64(len(data)), out)
    for i in range(len(data)):
        out.append(data[i])


def _header_with_schema_bytes(schema: List[UInt8]) -> List[UInt8]:
    return _header_with(schema, _bl(), _bl())


def _header_with(
    schema: List[UInt8], extra_key: List[UInt8], codec: List[UInt8]
) -> List[UInt8]:
    """A header with `avro.schema` = `schema`, then (when non-empty) a pair
    `extra_key` -> "x", then (when non-empty) `avro.codec` = `codec`."""
    var out = _bl()
    out.append(UInt8(ord("O")))
    out.append(UInt8(ord("b")))
    out.append(UInt8(ord("j")))
    out.append(0x01)
    var pairs = 1
    if len(extra_key) > 0:
        pairs += 1
    if len(codec) > 0:
        pairs += 1
    _encode_long(Int64(pairs), out)
    _encode_raw(_bytes(String("avro.schema")), out)
    _encode_raw(schema, out)
    if len(extra_key) > 0:
        _encode_raw(extra_key, out)
        _encode_raw(_bytes(String("x")), out)
    if len(codec) > 0:
        _encode_raw(_bytes(String("avro.codec")), out)
        _encode_raw(codec, out)
    _encode_long(Int64(0), out)
    for i in range(OCF_SYNC_LEN):
        out.append(UInt8(0xA0 + i))
    return out^


def test_ocf_header_raw_utf8_byte_exact() raises:
    """T6."""
    var json = _record_with(String('"ü😀"'))
    var want = _bytes(json)
    var buf = _header_with_schema_bytes(want)
    var hdr = decode_ocf_header(Span(buf))
    _assert_bytes(hdr.schema_json, want, "header schema_json")
    var s = hdr.parse_schema()
    _assert_bytes(
        s.nodes[s.root_idx].field_defaults[0].str_val,
        _bl(0xC3, 0xBC, 0xF0, 0x9F, 0x98, 0x80),
        "header default",
    )


def _assert_header_refused(bad: List[UInt8], what: String) raises:
    # `"type":"string","doc":"<bad>"` — the bad bytes sit inside a JSON string.
    var schema = _bytes(String('{"type":"string","doc":"'))
    for i in range(len(bad)):
        schema.append(bad[i])
    var tail = _bytes(String('"}'))
    for i in range(len(tail)):
        schema.append(tail[i])
    var buf = _header_with_schema_bytes(schema)
    var raised = False
    try:
        var hdr = decode_ocf_header(Span(buf))
        var _s = hdr.parse_schema()
    except e:
        raised = True
        assert_true(
            "AvroSchemaError.MALFORMED_JSON" in String(e),
            what + ": wrong error: " + String(e),
        )
    assert_true(raised, what + ": invalid UTF-8 accepted")


def test_ocf_header_invalid_utf8_refused() raises:
    """T7."""
    _assert_header_refused(_bl(0xC3, 0x28), "bad continuation")
    _assert_header_refused(_bl(0xFF), "stray FF")
    _assert_header_refused(_bl(0x80), "lone continuation")
    _assert_header_refused(_bl(0xED, 0xA0, 0x80), "encoded surrogate")
    _assert_header_refused(_bl(0xC0, 0xAF), "overlong")
    _assert_header_refused(_bl(0xF0, 0x9F, 0x98), "truncated")
    _assert_header_refused(_bl(0xF4, 0x90, 0x80, 0x80), "> U+10FFFF")


def _assert_header_error(buf: List[UInt8], needle: String, what: String) raises:
    var raised = False
    try:
        var _hdr = decode_ocf_header(Span(buf))
    except e:
        raised = True
        assert_true(needle in String(e), what + ": wrong error: " + String(e))
    assert_true(raised, what + ": invalid UTF-8 accepted")


def test_ocf_header_schema_utf8_refused_alone() raises:
    """T7b."""
    var want = String("AvroSchemaError.MALFORMED_JSON: avro.schema: not valid UTF-8")
    var inside = _bytes(String('{"type":"string","doc":"'))
    inside.append(0xC3)
    inside.append(0x28)
    var tail = _bytes(String('"}'))
    for i in range(len(tail)):
        inside.append(tail[i])
    _assert_header_error(_header_with_schema_bytes(inside), want, "in string")
    # Outside any JSON string: a stray FF between tokens.
    var outside = _bytes(String('{"type":'))
    outside.append(0xFF)
    var tail2 = _bytes(String('"string"}'))
    for i in range(len(tail2)):
        outside.append(tail2[i])
    _assert_header_error(_header_with_schema_bytes(outside), want, "outside")


def test_ocf_header_codec_and_key_utf8() raises:
    """T8."""
    var schema = _bytes(String('"string"'))
    # Well-formed non-ASCII key: accepted (and ignored).
    var ok = decode_ocf_header(
        Span(_header_with(schema, _bytes(String("user.ü")), _bl()))
    )
    assert_equal(ok.schema_json, String('"string"'))
    _assert_header_error(
        _header_with(schema, _bl(), _bl(0x6E, 0xFF)),
        String("AvroOcfError.MALFORMED_HEADER: avro.codec: not valid UTF-8"),
        "codec",
    )
    _assert_header_error(
        _header_with(schema, _bl(0x6B, 0xC3), _bl()),
        String("AvroOcfError.MALFORMED_HEADER: metadata key: not valid UTF-8"),
        "key",
    )


def main() raises:
    test_surrogate_pair_joins()
    test_bad_surrogates_refused()
    test_bad_hex_refused()
    test_bmp_escapes()
    test_raw_utf8_byte_exact()
    test_ocf_header_raw_utf8_byte_exact()
    test_ocf_header_invalid_utf8_refused()
    test_ocf_header_schema_utf8_refused_alone()
    test_ocf_header_codec_and_key_utf8()
    print("test_avro_schema_json_unicode: ALL PASS")
