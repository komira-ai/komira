# =============================================================================
# test_proto_codec_json_nonascii_roundtrip.mojo — JSON string non-ASCII byte fidelity.
# =============================================================================
#
# REGRESSION GUARD — the Latin-1<->UTF-8 double-encode. A message body
# containing a UTF-8 em-dash (bytes e2 80 94) in a JSON string field
# (`{"Raw":"...—..."}`) must not come back as `c3 a2 c2 80 c2 94` — each of
# the 3 UTF-8 bytes re-encoded as if it were a Latin-1 code point (the classic
# double-encode).
#
# The hazard is on the ENCODE side. If `JsonValue.serialize()` ->
# `_append_json_string` emitted each raw string byte via `out += chr(Int(c))`,
# any byte >= 0x80 would become the CODEPOINT U+00XX, which the String
# re-encodes as 2-byte UTF-8 — double-encoding every multibyte UTF-8
# sequence. The DECODE side (`parse_json_value` -> `_parse_string`) copies the
# raw bytes between the quotes VERBATIM into the result String, and only
# `\uXXXX` escapes get decoded to UTF-8.
#
# `test_serialize_emdash_verbatim` asserts
# `JsonValue.from_string(em-dash).serialize()` == `"—"` byte-for-byte
# (`22 e2 80 94 22`). A double-encoding serializer produces
# `22 c3 a2 c2 80 c2 94 22` (8 bytes), so the assertion fails on it.
#
# The encoder must NOT break `\uXXXX` escape decoding or ASCII pass-through.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_json import JsonValue, parse_json_value


# =============================================================================
# Byte helpers.
# =============================================================================


def _s(b: List[UInt8]) -> String:
    """A String built from raw UTF-8 bytes VERBATIM (no re-encode)."""
    return String(unsafe_from_utf8=Span(b))


def _byte_list(s: String) -> List[UInt8]:
    """Materialize a String's raw UTF-8 bytes into an owned List."""
    var out = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        out.append(src[i])
    return out^


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789abcdef")
    var hb = digits.as_bytes()
    var out = String("")
    for i in range(len(b)):
        if i > 0:
            out += " "
        out += chr(Int(hb[(Int(b[i]) >> 4) & 0xF]))
        out += chr(Int(hb[Int(b[i]) & 0xF]))
    return out^


def _assert_bytes_eq(got: List[UInt8], want: List[UInt8], label: String) raises:
    if len(got) != len(want):
        print(
            "  FAIL",
            label,
            "len got=",
            len(got),
            "want=",
            len(want),
            "| got[",
            _hex(got),
            "] want[",
            _hex(want),
            "]",
        )
    assert_equal(len(got), len(want), label + " (length)")
    for i in range(len(want)):
        if got[i] != want[i]:
            print(
                "  FAIL",
                label,
                "byte",
                i,
                "got=",
                Int(got[i]),
                "want=",
                Int(want[i]),
                "| got[",
                _hex(got),
                "] want[",
                _hex(want),
                "]",
            )
        assert_equal(Int(got[i]), Int(want[i]), label + " (byte)")


# Three canonical non-ASCII sequences (2-, 3- and 4-byte UTF-8).
def _emdash() -> List[UInt8]:
    # U+2014 EM DASH
    var o: List[UInt8] = [0xE2, 0x80, 0x94]
    return o^


def _eacute() -> List[UInt8]:
    # U+00E9 LATIN SMALL LETTER E WITH ACUTE
    var o: List[UInt8] = [0xC3, 0xA9]
    return o^


def _emoji() -> List[UInt8]:
    # U+1F600 GRINNING FACE (4-byte UTF-8)
    var o: List[UInt8] = [0xF0, 0x9F, 0x98, 0x80]
    return o^


# =============================================================================
# The encode-side double-encode.
# =============================================================================


def test_serialize_emdash_verbatim() raises:
    """`JsonValue.from_string(em-dash).serialize()` must emit the raw UTF-8
    bytes `e2 80 94` between the quotes — NOT the double-encoded
    `c3 a2 c2 80 c2 94`."""
    var v = JsonValue.from_string(_s(_emdash()))
    var got = _byte_list(v.serialize())
    # Expected: `"` + e2 80 94 + `"`
    var want: List[UInt8] = [0x22, 0xE2, 0x80, 0x94, 0x22]
    _assert_bytes_eq(got, want, "serialize(em-dash) verbatim")


def test_serialize_multibyte_verbatim() raises:
    """The é (2-byte) and emoji (4-byte) sequences must also serialize with
    their raw UTF-8 bytes verbatim, wrapped in quotes."""
    # é
    var ge = _byte_list(JsonValue.from_string(_s(_eacute())).serialize())
    var want_e: List[UInt8] = [0x22, 0xC3, 0xA9, 0x22]
    _assert_bytes_eq(ge, want_e, "serialize(é) verbatim")
    # emoji
    var gm = _byte_list(JsonValue.from_string(_s(_emoji())).serialize())
    var want_m: List[UInt8] = [0x22, 0xF0, 0x9F, 0x98, 0x80, 0x22]
    _assert_bytes_eq(gm, want_m, "serialize(emoji) verbatim")


# =============================================================================
# Round-trip guard — UTF-8 in -> JSON -> UTF-8 out, byte-identical.
# =============================================================================


def _roundtrip_field(raw: List[UInt8], label: String) raises:
    """Encode `raw` as a JSON string value, wrap it in a `{"x":...}` object,
    parse it back, and assert the decoded field bytes equal `raw` verbatim."""
    var obj = JsonValue.empty_object()
    obj.set_member(String("x"), JsonValue.from_string(_s(raw)))
    var text = obj.serialize()
    var doc = parse_json_value(text)
    var decoded = _byte_list(doc.get(String("x")).as_string())
    _assert_bytes_eq(decoded, raw, "roundtrip " + label)


def test_encode_decode_roundtrip_multibyte() raises:
    """UTF-8 in -> JSON encode -> JSON decode -> UTF-8 out is byte-identical for
    the em-dash, é, and emoji. Guards BOTH the encoder's raw-UTF-8 output
    and the decode path together."""
    _roundtrip_field(_emdash(), "em-dash")
    _roundtrip_field(_eacute(), "é")
    _roundtrip_field(_emoji(), "emoji")
    # A mixed ASCII + multibyte body (the realistic message-body shape).
    var mixed = List[UInt8]()
    for b in String("Subject: hi ").as_bytes():
        mixed.append(b)
    for b in _emdash():
        mixed.append(b)
    for b in String(" bye ").as_bytes():
        mixed.append(b)
    for b in _emoji():
        mixed.append(b)
    _roundtrip_field(mixed, "mixed ascii+multibyte")


# =============================================================================
# Decode-side guards — the `\uXXXX` escape and raw-byte pass-through paths must
# stay intact alongside the encoder's raw-UTF-8 output.
# =============================================================================


def test_decode_u_escape_emdash() raises:
    """A `\\u2014`-escaped em-dash decodes to the UTF-8 bytes e2 80 94 (the
    decoder's `\\uXXXX` -> UTF-8 path)."""
    var doc = parse_json_value(String('{"x":"\\u2014"}'))
    var decoded = _byte_list(doc.get(String("x")).as_string())
    _assert_bytes_eq(decoded, _emdash(), "decode \\u2014")


def test_decode_raw_utf8_verbatim() raises:
    """A JSON body carrying the RAW em-dash bytes between the quotes decodes to
    those exact bytes verbatim (the decoder's non-escape byte pass-through)."""
    var body = List[UInt8]()
    for b in String('{"x":"').as_bytes():
        body.append(b)
    for b in _emdash():
        body.append(b)
    for b in String('"}').as_bytes():
        body.append(b)
    var doc = parse_json_value(_s(body))
    var decoded = _byte_list(doc.get(String("x")).as_string())
    _assert_bytes_eq(decoded, _emdash(), "decode raw-utf8 verbatim")


# =============================================================================
# ASCII + escape-lattice regression guard — raw-UTF-8 output must coexist with
# the mandatory RFC 8259 §7 escapes and plain ASCII.
# =============================================================================


def test_ascii_and_escapes_preserved() raises:
    """Plain ASCII plus the mandatory escapes (`"` `\\` `\\n` `\\r` `\\t`) still
    encode + round-trip correctly."""
    # ASCII round-trips unchanged.
    var ascii = _byte_list(String("Hello, world!"))
    _roundtrip_field(ascii, "ascii")

    # The escape lattice: a body with a quote, backslash, newline, tab.
    var special = List[UInt8]()
    for b in String("a\"b\\c").as_bytes():
        special.append(b)
    special.append(0x0A)  # newline
    special.append(0x09)  # tab
    for b in String("d").as_bytes():
        special.append(b)
    # The serialized form must contain the two-char escapes, and the decode
    # must reproduce the exact original bytes.
    var v = JsonValue.from_string(_s(special))
    var text = v.serialize()
    assert_true(
        text.find(String("\\\"")) >= 0, "serialize keeps \\\" escape"
    )
    assert_true(text.find(String("\\n")) >= 0, "serialize keeps \\n escape")
    assert_true(text.find(String("\\t")) >= 0, "serialize keeps \\t escape")
    _roundtrip_field(special, "escape-lattice")


def main() raises:
    print("test_proto_codec_json_nonascii_roundtrip — JSON UTF-8 byte fidelity")
    test_serialize_emdash_verbatim()
    test_serialize_multibyte_verbatim()
    test_encode_decode_roundtrip_multibyte()
    test_decode_u_escape_emdash()
    test_decode_raw_utf8_verbatim()
    test_ascii_and_escapes_preserved()
    print("test_proto_codec_json_nonascii_roundtrip: ALL PASS")
