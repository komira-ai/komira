# =============================================================================
# tests/test_L2_h2_response_validation.mojo
# =============================================================================
#
# The client-side RFC 9113 response rules of codec/h2/response_validation.mojo,
# driven directly (the module is pure: no frames, no streams, no connection).
#
# What each group proves, and the clause it holds the code to:
#   * reason text      every reason code renders its own clause; an unknown
#                      code renders the fallback (no arm swapped or dropped).
#   * verdict          the POD verdict's defaults and is_malformed().
#   * tchar            RFC 9110 §5.6.2 tchar minus A-Z (RFC 9113 §8.2.1), all
#                      256 octets against a literal oracle.
#   * field name       RFC 9113 §8.2.1: non-empty lowercase token.
#   * field value      RFC 9113 §8.2.1: no NUL, LF, CR; every other octet of
#                      0..127 accepted, and obs-text (octets >= 0x80) too (the
#                      leading/trailing SP/HTAB clause is out of scope by the
#                      module's own statement).
#   * pseudo name      RFC 9113 §8.3: a name whose first octet is ':'.
#   * te               RFC 9113 §8.2.2: in a request, exactly the token
#                      "trailers", folded for case (the ABNF quoted literal
#                      "trailers" is case-insensitive, RFC 5234 §2.3). In a
#                      response the code accepts te: trailers, a deviation
#                      from §8.2.2 (request-only) pinned on purpose (#873).
#   * conn-specific    RFC 9113 §8.2.2's five names, and nothing else.
#   * :status          RFC 9113 §8.3.2 requires it; RFC 9110 §15 gives the
#                      three-digit form.
#   * content-length   RFC 9110 §8.6: 1*DIGIT, at most 18 digits (no Int64
#                      overflow).
#   * no-content       RFC 9113 §8.1.1 -> RFC 9110 §6.4.1: 1xx, 204, 304, and
#                      any response to HEAD; RFC 9110 §15.2: 1xx is interim.
#   * head block       RFC 9113 §8.1.1, §8.2.1, §8.2.2, §8.3, §8.3.2 and RFC
#                      9110 §8.6, each malformed shape with its reason code.
#   * trailer block    RFC 9113 §8.1: no pseudo-header at all; §8.2.1/§8.2.2
#                      unchanged.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec.h2.hpack import HpackHeader
from komira_http_core.codec.h2.response_validation import (
    H2BlockVerdict,
    H2_MALFORMED_BAD_CONTENT_LENGTH,
    H2_MALFORMED_BAD_FIELD_NAME,
    H2_MALFORMED_BAD_FIELD_VALUE,
    H2_MALFORMED_BAD_STATUS,
    H2_MALFORMED_BAD_TE,
    H2_MALFORMED_CONFLICTING_CONTENT_LENGTH,
    H2_MALFORMED_CONNECTION_SPECIFIC,
    H2_MALFORMED_CONTENT_LENGTH_MISMATCH,
    H2_MALFORMED_DATA_BEFORE_HEAD,
    H2_MALFORMED_DUPLICATE_PSEUDO,
    H2_MALFORMED_NO_STATUS,
    H2_MALFORMED_OK,
    H2_MALFORMED_PSEUDO_AFTER_REGULAR,
    H2_MALFORMED_PSEUDO_IN_TRAILER,
    H2_MALFORMED_TRAILER_NOT_END_STREAM,
    H2_MALFORMED_UNDEFINED_PSEUDO,
    h2_content_length_of,
    h2_field_name_is_valid,
    h2_field_value_is_valid,
    h2_is_connection_specific_field,
    h2_is_lowercase_tchar,
    h2_is_pseudo_name,
    h2_malformed_reason_text,
    h2_status_code_of,
    h2_status_has_no_content,
    h2_status_is_informational,
    h2_te_value_is_trailers,
    h2_validate_response_head,
    h2_validate_response_trailers,
)


# =============================================================================
# Helpers
# =============================================================================


def _h(var name: String, var value: String) -> HpackHeader:
    return HpackHeader(name^, value^)


def _block1(a: HpackHeader) -> List[HpackHeader]:
    var l = List[HpackHeader]()
    l.append(a)
    return l^


def _block2(a: HpackHeader, b: HpackHeader) -> List[HpackHeader]:
    var l = List[HpackHeader]()
    l.append(a)
    l.append(b)
    return l^


def _block3(
    a: HpackHeader, b: HpackHeader, c: HpackHeader,
) -> List[HpackHeader]:
    var l = List[HpackHeader]()
    l.append(a)
    l.append(b)
    l.append(c)
    return l^


def _status200() -> HpackHeader:
    return _h(":status", "200")


def _assert_head(
    var block: List[HpackHeader], want: UInt16, label: String,
) raises:
    """A head block refused with `want`; a refused verdict carries no status
    and no content-length (the caller must not apply them)."""
    var v = h2_validate_response_head(block)
    assert_equal(Int(v.reason_code), Int(want), label)
    assert_true(v.is_malformed(), label)
    assert_equal(v.status, -1, label)
    assert_equal(Int(v.content_length), -1, label)


def _assert_trailer(
    var block: List[HpackHeader], want: UInt16, label: String,
) raises:
    var v = h2_validate_response_trailers(block)
    assert_equal(Int(v.reason_code), Int(want), label)
    assert_equal(v.status, -1, label)
    assert_equal(Int(v.content_length), -1, label)


# =============================================================================
# Reason text
# =============================================================================


def _assert_text(code: UInt16, needle: String) raises:
    var t = h2_malformed_reason_text(code)
    assert_true(
        needle in t,
        String("code ") + String(Int(code)) + ": '" + needle + "' not in '"
        + t + "'",
    )


def test_reason_text_each_code_names_its_clause() raises:
    # Each needle occurs in exactly one arm's text, so a swapped or dropped
    # arm fails here.
    _assert_text(H2_MALFORMED_NO_STATUS, "no :status pseudo-header")
    _assert_text(H2_MALFORMED_BAD_STATUS, "three ASCII digits")
    _assert_text(H2_MALFORMED_UNDEFINED_PSEUDO, "undefined or request-only")
    _assert_text(H2_MALFORMED_PSEUDO_AFTER_REGULAR, "after a regular field")
    _assert_text(H2_MALFORMED_DUPLICATE_PSEUDO, "a repeated pseudo-header")
    _assert_text(H2_MALFORMED_BAD_FIELD_NAME, "a field name that is empty")
    _assert_text(H2_MALFORMED_BAD_FIELD_VALUE, "NUL, LF or CR")
    _assert_text(H2_MALFORMED_CONNECTION_SPECIFIC, "a connection-specific")
    _assert_text(H2_MALFORMED_BAD_TE, "a 'te' field")
    _assert_text(H2_MALFORMED_BAD_CONTENT_LENGTH, "is not 1*DIGIT")
    _assert_text(
        H2_MALFORMED_CONFLICTING_CONTENT_LENGTH, "two content-length fields"
    )
    _assert_text(H2_MALFORMED_CONTENT_LENGTH_MISMATCH, "sum of the DATA")
    _assert_text(H2_MALFORMED_DATA_BEFORE_HEAD, "DATA on a stream")
    _assert_text(H2_MALFORMED_PSEUDO_IN_TRAILER, "in a trailer section")
    _assert_text(H2_MALFORMED_TRAILER_NOT_END_STREAM, "does not end the stream")
    # OK and any code past the last are not a rule: the fallback.
    _assert_text(H2_MALFORMED_OK, "unclassified")
    _assert_text(UInt16(16), "unclassified")
    _assert_text(UInt16(65535), "unclassified")


def test_reason_codes_are_distinct_and_dense() raises:
    # The codes are stored on a POD stream; a duplicated value would make two
    # rules indistinguishable at the raise site.
    var codes = List[UInt16]()
    codes.append(H2_MALFORMED_OK)
    codes.append(H2_MALFORMED_NO_STATUS)
    codes.append(H2_MALFORMED_BAD_STATUS)
    codes.append(H2_MALFORMED_UNDEFINED_PSEUDO)
    codes.append(H2_MALFORMED_PSEUDO_AFTER_REGULAR)
    codes.append(H2_MALFORMED_DUPLICATE_PSEUDO)
    codes.append(H2_MALFORMED_BAD_FIELD_NAME)
    codes.append(H2_MALFORMED_BAD_FIELD_VALUE)
    codes.append(H2_MALFORMED_CONNECTION_SPECIFIC)
    codes.append(H2_MALFORMED_BAD_TE)
    codes.append(H2_MALFORMED_BAD_CONTENT_LENGTH)
    codes.append(H2_MALFORMED_CONFLICTING_CONTENT_LENGTH)
    codes.append(H2_MALFORMED_CONTENT_LENGTH_MISMATCH)
    codes.append(H2_MALFORMED_DATA_BEFORE_HEAD)
    codes.append(H2_MALFORMED_PSEUDO_IN_TRAILER)
    codes.append(H2_MALFORMED_TRAILER_NOT_END_STREAM)
    for i in range(len(codes)):
        assert_equal(Int(codes[i]), i, "code at position " + String(i))


# =============================================================================
# Verdict
# =============================================================================


def test_verdict_default_and_fields() raises:
    var d = H2BlockVerdict()
    assert_equal(Int(d.reason_code), Int(H2_MALFORMED_OK))
    assert_equal(d.status, -1)
    assert_equal(Int(d.content_length), -1)
    assert_false(d.is_malformed())
    var v = H2BlockVerdict(
        reason_code=H2_MALFORMED_BAD_TE, status=7, content_length=Int64(9),
    )
    assert_equal(Int(v.reason_code), Int(H2_MALFORMED_BAD_TE))
    assert_equal(v.status, 7)
    assert_equal(Int(v.content_length), 9)
    assert_true(v.is_malformed())


# =============================================================================
# Octet predicates
# =============================================================================


def test_lowercase_tchar_all_octets() raises:
    # RFC 9110 §5.6.2: tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+"
    # / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA; RFC 9113
    # §8.2.1 removes uppercase ALPHA. The oracle is this literal, not the code.
    var oracle = String(
        "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"
    ).as_bytes()
    var accepted = 0
    for c in range(256):
        var want = False
        for j in range(len(oracle)):
            if Int(oracle[j]) == c:
                want = True
        assert_equal(
            h2_is_lowercase_tchar(c), want, "octet " + String(c),
        )
        if want:
            accepted += 1
    assert_equal(accepted, 15 + 10 + 26)


def test_field_name_rules() raises:
    # RFC 9113 §8.2.1: a regular field name is a non-empty lowercase token.
    assert_true(h2_field_name_is_valid(String("content-type")))
    assert_true(h2_field_name_is_valid(String("x")))
    assert_true(h2_field_name_is_valid(String("a1!#$%&'*+-.^_`|~z")))
    assert_false(h2_field_name_is_valid(String("")), "empty")
    assert_false(h2_field_name_is_valid(String("Content-Type")), "upper first")
    assert_false(h2_field_name_is_valid(String("content-typE")), "upper last")
    assert_false(h2_field_name_is_valid(String("x y")), "SP")
    assert_false(h2_field_name_is_valid(String("a:b")), "':' inside")
    assert_false(h2_field_name_is_valid(String(":status")), "leading ':'")
    assert_false(h2_field_name_is_valid(String("x") + chr(1)), "control")
    assert_false(h2_field_name_is_valid(String("x") + chr(127)), "DEL")
    assert_false(h2_field_name_is_valid(String("caf") + chr(0xE9)), "non-ASCII")


def test_field_value_rules() raises:
    # RFC 9113 §8.2.1: a value MUST NOT contain NUL, LF or CR, at any position.
    assert_true(h2_field_value_is_valid(String("")), "empty value is legal")
    assert_true(h2_field_value_is_valid(String("text/plain; q=1")))
    for c in range(128):
        var s = String("a") + chr(c) + String("b")
        var want = not (c == 0 or c == 0x0A or c == 0x0D)
        assert_equal(h2_field_value_is_valid(s), want, "octet " + String(c))
    # The three, first and last.
    assert_false(h2_field_value_is_valid(chr(0) + String("ab")), "NUL first")
    assert_false(h2_field_value_is_valid(String("ab") + chr(0x0A)), "LF last")
    assert_false(h2_field_value_is_valid(chr(0x0D)), "CR alone")
    # The module states it does not enforce §8.2.1's leading/trailing
    # SP/HTAB clause; pin that scope so a change to it is deliberate.
    assert_true(h2_field_value_is_valid(String(" padded\t")), "OWS kept")
    # obs-text (RFC 9110 §5.5): octets 0x80..0xFF are not among the three, so
    # they are accepted. chr(0xE9) is U+00E9, which String stores as the UTF-8
    # octets C3 A9; pin that both octets are >= 0x80 so the case tests what it
    # claims (a refusal of c > 0x7F goes red here).
    var obs = String("caf") + chr(0xE9)
    var ob = obs.as_bytes()
    assert_equal(len(ob), 5, "caf + C3 A9")
    assert_equal(Int(ob[3]), 0xC3)
    assert_equal(Int(ob[4]), 0xA9)
    assert_true(h2_field_value_is_valid(obs), "obs-text accepted")


def test_pseudo_name() raises:
    # RFC 9113 §8.3: a pseudo-header is a name beginning with ':'.
    assert_true(h2_is_pseudo_name(String(":status")))
    assert_true(h2_is_pseudo_name(String(":")))
    assert_false(h2_is_pseudo_name(String("")), "empty")
    assert_false(h2_is_pseudo_name(String("status")))
    assert_false(h2_is_pseudo_name(String("a:status")), "':' not first")


def test_te_value() raises:
    # RFC 9113 §8.2.2: te is allowed only in a request, and there MUST NOT
    # carry any value other than "trailers". The case fold comes from the
    # ABNF quoted literal "trailers", which is case-insensitive (RFC 5234
    # §2.3).
    assert_true(h2_te_value_is_trailers(String("trailers")))
    assert_true(h2_te_value_is_trailers(String("TRAILERS")))
    assert_true(h2_te_value_is_trailers(String("Trailers")))
    # 'A' is the low edge of the folded range.
    assert_true(h2_te_value_is_trailers(String("trAilers")), "A folds")
    assert_false(h2_te_value_is_trailers(String("")), "empty")
    assert_false(h2_te_value_is_trailers(String("trailer")), "7 octets")
    assert_false(h2_te_value_is_trailers(String("trailers ")), "9 octets")
    assert_false(h2_te_value_is_trailers(String("gzip")), "other coding")
    assert_false(h2_te_value_is_trailers(String("xrailers")), "first octet")
    assert_false(h2_te_value_is_trailers(String("trailerz")), "last octet")
    # An octet below 'A' takes the not-folded arm of the case fold (every
    # octet above is a letter, so without these that arm never runs).
    assert_false(h2_te_value_is_trailers(String("tr@ilers")), "'@' not 'a'")
    assert_false(h2_te_value_is_trailers(String("1railers")), "digit first")
    # The neighbours of the 8-octet length: a list is not "trailers".
    assert_false(
        h2_te_value_is_trailers(String("trailers, gzip")), "a list",
    )


def test_connection_specific_names() raises:
    # RFC 9113 §8.2.2: "connection, keep-alive, proxy-connection,
    # transfer-encoding, upgrade" (te is a value rule, not a name ban).
    assert_true(h2_is_connection_specific_field(String("connection")))
    assert_true(h2_is_connection_specific_field(String("keep-alive")))
    assert_true(h2_is_connection_specific_field(String("proxy-connection")))
    assert_true(h2_is_connection_specific_field(String("transfer-encoding")))
    assert_true(h2_is_connection_specific_field(String("upgrade")))
    assert_false(h2_is_connection_specific_field(String("te")), "te")
    assert_false(h2_is_connection_specific_field(String("content-length")))
    assert_false(h2_is_connection_specific_field(String("connections")))
    assert_false(h2_is_connection_specific_field(String("upgrade-insecure")))
    assert_false(h2_is_connection_specific_field(String("")))


# =============================================================================
# Value parsers
# =============================================================================


def test_status_code_of() raises:
    # RFC 9110 §15: a status code is three digits (RFC 9113 §8.3.2 carries it
    # in :status); anything else is -1, never a partial value.
    assert_equal(h2_status_code_of(String("200")), 200)
    assert_equal(h2_status_code_of(String("103")), 103)
    assert_equal(h2_status_code_of(String("451")), 451)
    assert_equal(h2_status_code_of(String("599")), 599)
    assert_equal(h2_status_code_of(String("")), -1, "empty")
    assert_equal(h2_status_code_of(String("20")), -1, "two digits")
    assert_equal(h2_status_code_of(String("0200")), -1, "four digits")
    assert_equal(h2_status_code_of(String("2oo")), -1, "letter o")
    assert_equal(h2_status_code_of(String(" 20")), -1, "SP first")
    # '/' and ':' bracket the DIGIT range, at each of the three positions.
    assert_equal(h2_status_code_of(String("/00")), -1, "'/' first")
    assert_equal(h2_status_code_of(String("2:0")), -1, "':' middle")
    assert_equal(h2_status_code_of(String("20/")), -1, "'/' last")
    assert_equal(h2_status_code_of(String("20:")), -1, "':' last")


def test_content_length_of() raises:
    # RFC 9110 §8.6: Content-Length = 1*DIGIT.
    assert_equal(Int(h2_content_length_of(String("0"))), 0)
    assert_equal(Int(h2_content_length_of(String("42"))), 42)
    assert_equal(Int(h2_content_length_of(String("007"))), 7, "leading 0s")
    assert_equal(Int(h2_content_length_of(String(""))), -1, "empty")
    assert_equal(Int(h2_content_length_of(String("+5"))), -1, "sign")
    assert_equal(Int(h2_content_length_of(String("-1"))), -1, "negative")
    assert_equal(Int(h2_content_length_of(String(" 5"))), -1, "SP first")
    assert_equal(Int(h2_content_length_of(String("5 "))), -1, "SP last")
    assert_equal(Int(h2_content_length_of(String("1,1"))), -1, "a list")
    assert_equal(Int(h2_content_length_of(String("/"))), -1, "'/'")
    assert_equal(Int(h2_content_length_of(String(":"))), -1, "':'")
    # 18 digits is the widest accepted; 19 is refused before it can overflow.
    assert_equal(
        Int(h2_content_length_of(String("999999999999999999"))),
        999999999999999999,
        "18 digits",
    )
    assert_equal(
        Int(h2_content_length_of(String("1000000000000000000"))),
        -1,
        "19 digits",
    )


def test_no_content_statuses() raises:
    # RFC 9113 §8.1.1 -> RFC 9110 §6.4.1: 1xx, 204, 304 and any response to
    # HEAD have no content.
    assert_true(h2_status_has_no_content(200, True), "HEAD 200")
    assert_true(h2_status_has_no_content(500, True), "HEAD 500")
    assert_true(h2_status_has_no_content(100, False))
    assert_true(h2_status_has_no_content(199, False))
    assert_true(h2_status_has_no_content(204, False))
    assert_true(h2_status_has_no_content(304, False))
    assert_false(h2_status_has_no_content(99, False))
    assert_false(h2_status_has_no_content(200, False))
    assert_false(h2_status_has_no_content(203, False))
    assert_false(h2_status_has_no_content(205, False))
    assert_false(h2_status_has_no_content(303, False))
    assert_false(h2_status_has_no_content(305, False))


def test_informational_range() raises:
    # RFC 9110 §15.2: 1xx is interim.
    assert_false(h2_status_is_informational(99))
    assert_true(h2_status_is_informational(100))
    assert_true(h2_status_is_informational(103))
    assert_true(h2_status_is_informational(199))
    assert_false(h2_status_is_informational(200))


# =============================================================================
# Head block
# =============================================================================


def test_head_well_formed() raises:
    var v = h2_validate_response_head(_block1(_status200()))
    assert_false(v.is_malformed())
    assert_equal(Int(v.reason_code), Int(H2_MALFORMED_OK))
    assert_equal(v.status, 200)
    assert_equal(Int(v.content_length), -1, "absent content-length")

    # Pseudo first, then a regular field with an obs-text value, then a
    # content-length.
    var w = h2_validate_response_head(
        _block3(
            _h(":status", "404"),
            _h("x-name", String("caf") + chr(0xE9)),
            _h("content-length", "17"),
        )
    )
    assert_equal(Int(w.reason_code), Int(H2_MALFORMED_OK))
    assert_equal(w.status, 404)
    assert_equal(Int(w.content_length), 17)

    # An interim 1xx head validates as a head (RFC 9110 §15.2).
    var x = h2_validate_response_head(
        _block2(_h(":status", "103"), _h("link", "</a.css>; rel=preload"))
    )
    assert_equal(Int(x.reason_code), Int(H2_MALFORMED_OK))
    assert_equal(x.status, 103)


def test_head_te_trailers_accepted_deviation() raises:
    # DEVIATION, pinned on purpose: RFC 9113 §8.2.2 allows te only in a
    # request, so a response carrying te is malformed. The code applies only
    # the request-side value rule and accepts te: trailers in a response
    # (komira-ai/komira#873). A fix flips this test to a refusal on purpose.
    var v = h2_validate_response_head(
        _block2(_h(":status", "200"), _h("te", "trailers"))
    )
    assert_equal(Int(v.reason_code), Int(H2_MALFORMED_OK), "te in a response")
    assert_equal(v.status, 200)
    var w = h2_validate_response_head(
        _block2(_h(":status", "200"), _h("te", "Trailers"))
    )
    assert_equal(Int(w.reason_code), Int(H2_MALFORMED_OK), "te folded")


def test_head_status_required_and_exact() raises:
    # RFC 9113 §8.3.2: :status is REQUIRED; RFC 9110 §15: three digits.
    _assert_head(List[HpackHeader](), H2_MALFORMED_NO_STATUS, "empty block")
    _assert_head(
        _block1(_h("content-type", "text/plain")),
        H2_MALFORMED_NO_STATUS,
        "regular fields only",
    )
    _assert_head(
        _block1(_h(":status", "0200")), H2_MALFORMED_BAD_STATUS, "0200",
    )
    _assert_head(_block1(_h(":status", "2oo")), H2_MALFORMED_BAD_STATUS, "2oo")
    _assert_head(_block1(_h(":status", "")), H2_MALFORMED_BAD_STATUS, "empty")


def test_head_pseudo_rules() raises:
    # RFC 9113 §8.3: pseudo-headers first, once each, and only :status in a
    # response.
    _assert_head(
        _block2(_h("server", "x"), _status200()),
        H2_MALFORMED_PSEUDO_AFTER_REGULAR,
        ":status after a regular field",
    )
    # Order is checked before the name: an undefined pseudo after a regular
    # field is still PSEUDO_AFTER_REGULAR.
    _assert_head(
        _block3(_status200(), _h("server", "x"), _h(":path", "/")),
        H2_MALFORMED_PSEUDO_AFTER_REGULAR,
        ":path after a regular field",
    )
    _assert_head(
        _block2(_status200(), _status200()),
        H2_MALFORMED_DUPLICATE_PSEUDO,
        "repeated :status, same value",
    )
    _assert_head(
        _block2(_h(":status", "200"), _h(":status", "500")),
        H2_MALFORMED_DUPLICATE_PSEUDO,
        "repeated :status, other value",
    )
    _assert_head(
        _block1(_h(":method", "GET")),
        H2_MALFORMED_UNDEFINED_PSEUDO,
        "request pseudo alone",
    )
    _assert_head(
        _block2(_status200(), _h(":authority", "a")),
        H2_MALFORMED_UNDEFINED_PSEUDO,
        "request pseudo after :status",
    )
    _assert_head(
        _block2(_status200(), _h(":test", "1")),
        H2_MALFORMED_UNDEFINED_PSEUDO,
        "undefined pseudo",
    )
    _assert_head(
        _block2(_status200(), _h(":Status", "200")),
        H2_MALFORMED_UNDEFINED_PSEUDO,
        "pseudo names are case-sensitive",
    )


def test_head_field_name_and_value() raises:
    # RFC 9113 §8.2.1.
    _assert_head(
        _block2(_status200(), _h("Server", "x")),
        H2_MALFORMED_BAD_FIELD_NAME,
        "uppercase name",
    )
    _assert_head(
        _block2(_status200(), _h("", "x")),
        H2_MALFORMED_BAD_FIELD_NAME,
        "empty name",
    )
    _assert_head(
        _block2(_status200(), _h("x-a", String("1") + chr(0x0D) + "2")),
        H2_MALFORMED_BAD_FIELD_VALUE,
        "CR in a regular value",
    )
    _assert_head(
        _block2(_status200(), _h("x-a", String("1") + chr(0x0A))),
        H2_MALFORMED_BAD_FIELD_VALUE,
        "LF in a regular value",
    )
    # The value rule is checked for every field, :status included, and first.
    _assert_head(
        _block1(_h(":status", String("20") + chr(0))),
        H2_MALFORMED_BAD_FIELD_VALUE,
        "NUL in :status",
    )


def test_head_connection_specific() raises:
    # RFC 9113 §8.2.2: each of the five is a malformed response.
    var names = List[String]()
    names.append("connection")
    names.append("keep-alive")
    names.append("proxy-connection")
    names.append("transfer-encoding")
    names.append("upgrade")
    for i in range(len(names)):
        _assert_head(
            _block2(_status200(), _h(String(names[i]), "x")),
            H2_MALFORMED_CONNECTION_SPECIFIC,
            names[i],
        )
    # te: only "trailers".
    _assert_head(
        _block2(_status200(), _h("te", "gzip")), H2_MALFORMED_BAD_TE, "te gzip",
    )
    _assert_head(
        _block2(_status200(), _h("te", "trailers, deflate")),
        H2_MALFORMED_BAD_TE,
        "te list",
    )


def test_head_content_length() raises:
    # RFC 9110 §8.6: 1*DIGIT, and repeated fields must agree.
    _assert_head(
        _block2(_status200(), _h("content-length", "abc")),
        H2_MALFORMED_BAD_CONTENT_LENGTH,
        "not digits",
    )
    _assert_head(
        _block2(_status200(), _h("content-length", "")),
        H2_MALFORMED_BAD_CONTENT_LENGTH,
        "empty",
    )
    _assert_head(
        _block3(
            _status200(),
            _h("content-length", "5"),
            _h("content-length", "6"),
        ),
        H2_MALFORMED_CONFLICTING_CONTENT_LENGTH,
        "5 then 6",
    )
    # A first value of 0 is a value: 0 then 1 conflicts.
    _assert_head(
        _block3(
            _status200(),
            _h("content-length", "0"),
            _h("content-length", "1"),
        ),
        H2_MALFORMED_CONFLICTING_CONTENT_LENGTH,
        "0 then 1",
    )
    # Equal repeats are accepted and keep the value.
    var v = h2_validate_response_head(
        _block3(
            _status200(),
            _h("content-length", "5"),
            _h("content-length", "005"),
        )
    )
    assert_equal(Int(v.reason_code), Int(H2_MALFORMED_OK), "5 then 005")
    assert_equal(Int(v.content_length), 5)
    var z = h2_validate_response_head(
        _block2(_status200(), _h("content-length", "0"))
    )
    assert_equal(Int(z.reason_code), Int(H2_MALFORMED_OK))
    assert_equal(Int(z.content_length), 0)


# =============================================================================
# Trailer block
# =============================================================================


def test_trailers() raises:
    # RFC 9113 §8.1: a trailer section carries no pseudo-header.
    var e = h2_validate_response_trailers(List[HpackHeader]())
    assert_false(e.is_malformed(), "empty trailer section")
    var g = h2_validate_response_trailers(
        _block2(_h("grpc-status", "0"), _h("grpc-message", ""))
    )
    assert_equal(Int(g.reason_code), Int(H2_MALFORMED_OK))
    assert_equal(g.status, -1, "a trailer never carries a status")
    assert_equal(Int(g.content_length), -1)

    _assert_trailer(
        _block1(_h(":status", "200")),
        H2_MALFORMED_PSEUDO_IN_TRAILER,
        ":status in a trailer",
    )
    _assert_trailer(
        _block2(_h("grpc-status", "0"), _h(":path", "/")),
        H2_MALFORMED_PSEUDO_IN_TRAILER,
        "pseudo after a regular trailer field",
    )
    # The pseudo rule comes first: a pseudo with a bad value is still a pseudo.
    _assert_trailer(
        _block1(_h(":status", String("2") + chr(0x0A))),
        H2_MALFORMED_PSEUDO_IN_TRAILER,
        "pseudo with LF",
    )
    # RFC 9113 §8.2.1 and §8.2.2 apply unchanged.
    _assert_trailer(
        _block1(_h("grpc-message", String("a") + chr(0))),
        H2_MALFORMED_BAD_FIELD_VALUE,
        "NUL in a trailer value",
    )
    _assert_trailer(
        _block1(_h("Grpc-Status", "0")),
        H2_MALFORMED_BAD_FIELD_NAME,
        "uppercase trailer name",
    )
    _assert_trailer(
        _block2(_h("grpc-status", "0"), _h("transfer-encoding", "chunked")),
        H2_MALFORMED_CONNECTION_SPECIFIC,
        "connection-specific trailer",
    )


# =============================================================================
# main
# =============================================================================


def main() raises:
    print("test_L2_h2_response_validation: start")
    test_reason_text_each_code_names_its_clause()
    print(" reason_text_each_code_names_its_clause PASS")
    test_reason_codes_are_distinct_and_dense()
    print(" reason_codes_are_distinct_and_dense PASS")
    test_verdict_default_and_fields()
    print(" verdict_default_and_fields PASS")
    test_lowercase_tchar_all_octets()
    print(" lowercase_tchar_all_octets PASS")
    test_field_name_rules()
    print(" field_name_rules PASS")
    test_field_value_rules()
    print(" field_value_rules PASS")
    test_pseudo_name()
    print(" pseudo_name PASS")
    test_te_value()
    print(" te_value PASS")
    test_connection_specific_names()
    print(" connection_specific_names PASS")
    test_status_code_of()
    print(" status_code_of PASS")
    test_content_length_of()
    print(" content_length_of PASS")
    test_no_content_statuses()
    print(" no_content_statuses PASS")
    test_informational_range()
    print(" informational_range PASS")
    test_head_well_formed()
    print(" head_well_formed PASS")
    test_head_te_trailers_accepted_deviation()
    print(" head_te_trailers_accepted_deviation PASS")
    test_head_status_required_and_exact()
    print(" head_status_required_and_exact PASS")
    test_head_pseudo_rules()
    print(" head_pseudo_rules PASS")
    test_head_field_name_and_value()
    print(" head_field_name_and_value PASS")
    test_head_connection_specific()
    print(" head_connection_specific PASS")
    test_head_content_length()
    print(" head_content_length PASS")
    test_trailers()
    print(" trailers PASS")
    print("test_L2_h2_response_validation: ALL 21 TESTS PASS")
