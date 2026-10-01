# =============================================================================
# src/komira_http/tests/test_L2_response_framing_precedence.mojo
# =============================================================================
# RFC 9112 §6.3 — the message-body-length ladder, RESPONSE direction.
#
# WHY THIS FILE EXISTS. `parse_response_head` pins roughly three rungs of
# the eight-step ladder and nothing pins the rest. The three malformed
# suites this package already ships (test_L2_codec_malformed_fuzz,
# test_e2e_malformed_inputs, test_L2_conformance_rfc7230_corpus) are ALL
# REQUEST-direction — not one of them calls `parse_response_head`. So the
# response side, which is the side that reads bytes an attacker's origin
# server chose, had the thinnest coverage in the package.
#
# The bar is the conformance corpus the reference implementations agree
# on: llhttp's Content-Length lexical table, Go's `parseContentLength` +
# `fixLength`, hyper's `decode`, and Envoy's TestResponseSplit family.
# Where they DISAGREE the divergence is named in the test's docstring and
# the reference we follow is stated.
#
# ⚠ SCOPE: this file is socket-free and tests ONE function. The framing
# DECISIONS that live in the driver (304/204/1xx/HEAD -> empty body,
# pre-body residue) are in `test_L2_special_status_framing.mojo`.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.client.response_parser import (
    ResponseParseLimits,
    _parse_decimal,
    _parse_decimal_bytes,
    parse_response_head,
)


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _parse(s: String) raises -> Bool:
    """Parse `s` and return True iff the head parsed OK. Used where only
    the accept/reject verdict matters."""
    var buf = _b(s)
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    return r.is_ok()


def _cl_head(value: String) -> String:
    """A minimal 200 response carrying exactly one Content-Length whose
    field-value is `value` (an SP already separates it from the colon)."""
    return String("HTTP/1.1 200 OK\r\nContent-Length: ") + value + String(
        "\r\n\r\n"
    )


def _cl_of(value: String) raises -> Int:
    """Parse a one-CL response and return `content_length`. Returns -2
    when the parse was REJECTED, so a test can tell "rejected" from
    "absent" (-1) from a real value."""
    var buf = _b(_cl_head(value))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    if not r.is_ok():
        return -2
    return r.content_length


def _te_head(value: String) -> String:
    return String("HTTP/1.1 200 OK\r\nTransfer-Encoding: ") + value + String(
        "\r\n\r\n"
    )


def _is_chunked_framed(s: String) raises -> Bool:
    """True iff the parse SUCCEEDED and selected chunked framing. This is
    the security-relevant predicate: 'will we run the chunked decoder over
    this body'. A rejected message answers False, which is a safe outcome."""
    var buf = _b(s)
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    return r.is_ok() and r.is_chunked


# =============================================================================
# §1 — Content-Length lexical table (llhttp + Go `parseContentLength`).
# =============================================================================


def test_cl_leading_zeros_are_decimal() raises:
    """`003` is 3. Leading zeros are legal DIGIT bytes, not a radix hint."""
    assert_equal(_cl_of(String("003")), 3)


def test_cl_0200_is_two_hundred_never_octal_128() raises:
    """★ THE SMUGGLING CHAIN. `Content-Length: 0200` MUST be 200.

    LiteSpeed parsed this with `strtoll(v, NULL, 0)` — radix INFERENCE —
    so a leading zero made it OCTAL and `0200` became 128, while ATS,
    nghttpx, Squid, Varnish and Google's own GCLB all forwarded the field
    unnormalized. Two participants in one chain disagreeing about the
    length of a body by 72 bytes is a complete request-smuggling
    primitive: the 72-byte tail of body N is read as the head of N+1.

    Our parser is a hand-rolled decimal accumulator with no radix
    inference, so this is a PIN, not a repair — it exists so that
    'just call strtoll' never looks like a simplification.
    """
    assert_equal(_cl_of(String("0200")), 200)
    assert_equal(_cl_of(String("010")), 10)
    assert_equal(_cl_of(String("0")), 0)


def test_cl_empty_value_is_rejected() raises:
    """`Content-Length:` with no field-value is an invalid CL, and
    RFC 9112 §6.3(4) makes an invalid CL an unrecoverable error."""
    var buf = _b(String("HTTP/1.1 200 OK\r\nContent-Length:\r\n\r\n"))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(r.is_error(), "empty Content-Length must be rejected")


def test_cl_signed_values_are_rejected() raises:
    """`+3` and `-3` are not 1*DIGIT. Both MUST be rejected.

    `-3` is the load-bearing half: Mongoose accepted a negative
    Content-Length and then drove a read loop with it, which is the
    infinite-busy-loop CVE. The assertion is deliberately two-sided —
    rejected AND never surfaced as a negative length.
    """
    assert_equal(_cl_of(String("+3")), -2)
    assert_equal(_cl_of(String("-3")), -2)
    # And the byte-level primitive itself must never return a negative
    # LENGTH (it returns -1 as its invalid sentinel, never -3).
    var neg = _b(String("-3"))
    assert_equal(_parse_decimal_bytes(Span[UInt8](neg), 0, 2), -1)


def test_cl_interior_whitespace_is_rejected() raises:
    """`4 2` is not 1*DIGIT — it is two tokens. Accepting it as 42 (or as
    4) is the classic length-disagreement primitive."""
    assert_equal(_cl_of(String("4 2")), -2)
    assert_equal(_cl_of(String("13 37")), -2)


def test_cl_surrounding_ows_is_stripped() raises:
    """OWS around the field-value is not part of it (RFC 9112 §5). SP and
    HTAB both count."""
    assert_equal(_cl_of(String("  42  ")), 42)
    assert_equal(_cl_of(String("\t42\t")), 42)


def test_cl_twenty_one_digits_is_rejected() raises:
    """`1000000000000000000000` (10^21) exceeds any representable length
    and MUST be rejected rather than truncated."""
    assert_equal(_cl_of(String("1000000000000000000000")), -2)


# =============================================================================
# §2 — Content-Length integer overflow AT OUR OWN GUARD.
# =============================================================================
# `_parse_decimal_bytes` carries a MEASURED comment: at ASSERT=none with
# the old post-multiply guard, `Content-Length: 18446744073709551621`
# parsed to **5** — we would consume 5 body bytes and read the attacker's
# remaining bytes as the next response's status line. No test pinned it.
# These do, at the exact boundary and through BOTH twins.


comptime _TWO_POW_62: Int = 1 << 62
"""`_MAX_PARSED_DECIMAL` — the parser's ceiling, restated here so the test
fails if the constant moves silently."""


def test_cl_guard_boundary_byte_span_twin() raises:
    """2^62 is the last accepted value; 2^62 + 1 is rejected."""
    var at = _b(String("4611686018427387904"))
    assert_equal(
        _parse_decimal_bytes(Span[UInt8](at), 0, 19), _TWO_POW_62,
    )
    var over = _b(String("4611686018427387905"))
    assert_equal(_parse_decimal_bytes(Span[UInt8](over), 0, 19), -1)


def test_cl_guard_boundary_string_twin() raises:
    """`_parse_decimal` is kept in lockstep with `_parse_decimal_bytes`
    deliberately — the round-1 overflow pass fixed one accumulator of this
    shape and left its twins. Pin both at the same two points."""
    assert_equal(_parse_decimal(String("4611686018427387904")), _TWO_POW_62)
    assert_equal(_parse_decimal(String("4611686018427387905")), -1)


def test_cl_twenty_digit_wrap_value_never_parses_to_five() raises:
    """★ THE MEASURED REGRESSION. `18446744073709551621` is 2^64 + 5.

    With a POST-multiply guard the accumulator wraps Int64 and lands on
    **5**. Both twins must return the invalid sentinel, and the full
    message must be REJECTED — not framed as a 5-byte body.
    """
    var wrap = _b(String("18446744073709551621"))
    assert_equal(_parse_decimal_bytes(Span[UInt8](wrap), 0, 20), -1)
    assert_equal(_parse_decimal(String("18446744073709551621")), -1)
    var got = _cl_of(String("18446744073709551621"))
    assert_false(got == 5, "2^64+5 must never frame a 5-byte body")
    assert_equal(got, -2)


def test_cl_int64_max_is_rejected_by_our_ceiling() raises:
    """DIVERGENCE, PINNED DELIBERATELY. Go's `parseContentLength` accepts
    up to int64 max (9223372036854775807) and rejects ...808.

    We cap at 2^62 (`_MAX_PARSED_DECIMAL`), so we reject BOTH. That is the
    fail-CLOSED direction — no body of either size exists — and the
    property that actually matters is pinned by the test above: an
    over-ceiling value must never WRAP to a small one. This test exists so
    that raising the ceiling to int64 is a deliberate edit with a failing
    test attached, not a silent drift.
    """
    assert_equal(_cl_of(String("9223372036854775807")), -2)
    assert_equal(_cl_of(String("9223372036854775808")), -2)


# =============================================================================
# §3 — Duplicate Content-Length.
# =============================================================================


def test_cl_duplicate_differing_values_is_unrecoverable() raises:
    """RFC 9112 §6.3(4): multiple Content-Length fields with DIFFERING
    field-values make the framing invalid and the recipient MUST treat it
    as unrecoverable. Every reference implementation agrees."""
    var buf = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nContent-Length: 11\r\n\r\n"
    ))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(r.is_error(), "differing duplicate CL must be rejected")


def test_cl_duplicate_identical_values_is_accepted() raises:
    """RFC 9112 §6.3(4) scopes the unrecoverable case to DIFFERING values.
    RFC 9110 §8.6 says a recipient that receives several identical
    Content-Length field-values MAY replace them with the single value.

    Go (`http.fixLength`), hyper and nginx ACCEPT; llhttp REJECTS.
    The majority and the RFC text agree: accept, length 7.

    ⚠ FAILS ON CURRENT CODE. `parse_response_head`'s CL fan-out reads

        elif content_length_seen != v: content_length_dupe = True
        else:                          content_length_dupe = True

    — two branches that were split to distinguish the cases and then do
    the same thing, which is the signature of an unfinished accept path.
    The observable effect is that a legitimate response carrying a
    duplicated-but-identical Content-Length (proxies do emit these) is
    failed outright.
    """
    var buf = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nContent-Length: 7\r\n\r\n"
    ))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(
        r.is_ok(),
        "RFC 9112 6.3(4) + RFC 9110 8.6: identical duplicate CL is not a"
        " conflict",
    )
    assert_equal(r.content_length, 7)


def test_cl_duplicate_differing_only_by_ows_is_not_a_conflict() raises:
    """`7` and `  7  ` are the SAME field-value — OWS is not part of it.

    Stated as a RELATIVE assertion against the byte-identical pair so it
    pins the real invariant (OWS must never manufacture a conflict)
    whichever way the identical-duplicate question above is settled.
    """
    var same = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nContent-Length: 7\r\n\r\n"
    ))
    var owsy = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nContent-Length:   7  \r\n\r\n"
    ))
    var r_same = parse_response_head(
        Span[UInt8](same), ResponseParseLimits.defaults(),
    )
    var r_ows = parse_response_head(
        Span[UInt8](owsy), ResponseParseLimits.defaults(),
    )
    assert_equal(
        r_ows.is_ok(), r_same.is_ok(),
        "an OWS-only difference must not change the verdict",
    )
    assert_equal(r_ows.content_length, r_same.content_length)


# =============================================================================
# §4 — Header-NAME precision (the prefix-match class).
# =============================================================================


def test_content_length_x_is_not_content_length() raises:
    """`Content-Length-X: 0` is a DIFFERENT field. A prefix match here
    would let an attacker frame a body with a header no proxy in the
    chain recognises as Content-Length."""
    var buf = _b(String("HTTP/1.1 200 OK\r\nContent-Length-X: 0\r\n\r\n"))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(r.is_ok())
    assert_equal(
        r.content_length, -1,
        "Content-Length-X must not be read as Content-Length",
    )
    assert_false(r.is_chunked)


def test_transfer_encoding_x_is_not_transfer_encoding() raises:
    """The same class on the TE side: `Transfer-Encoding-X: chunked` must
    not select chunked framing."""
    var buf = _b(String(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding-X: chunked\r\n\r\n"
    ))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(r.is_ok())
    assert_false(
        r.is_chunked, "Transfer-Encoding-X must not select chunked framing",
    )


def test_cr_inside_header_name_is_not_a_token() raises:
    """`Content\\rLength: 003` — CR is not a tchar, so the line is a
    malformed header, not a Content-Length."""
    assert_false(
        _parse(String("HTTP/1.1 200 OK\r\nContent\rLength: 003\r\n\r\n")),
    )


def test_space_before_colon_rejects_the_message() raises:
    """RFC 9112 §5.1, a MUST: no whitespace is allowed between the field
    name and the colon. A recipient MUST reject the message (a proxy MUST
    remove it before forwarding) precisely because the alternative is two
    participants disagreeing about whether the field exists."""
    assert_false(
        _parse(String("HTTP/1.1 200 OK\r\nContent-Length : 4\r\n\r\n")),
    )
    assert_false(
        _parse(String("HTTP/1.1 200 OK\r\nTransfer-Encoding : chunked\r\n\r\n")),
    )


# =============================================================================
# §5 — Transfer-Encoding list handling (RFC 9112 §6.1, §6.3(3)).
# =============================================================================


def test_te_chunked_last_applies_chunked() raises:
    """`deflate, chunked` — chunked IS the final coding, so the message
    body length is determined by decoding the chunked data."""
    assert_true(_is_chunked_framed(_te_head(String("deflate, chunked"))))


def test_te_chunked_not_final_must_not_frame_as_chunked() raises:
    """★ RFC 9112 §6.3(3), the ORDER rule. Chunked must be the FINAL
    encoding for chunked framing to apply.

    `chunked, gzip` says: chunked was applied first, THEN gzip. What is on
    the wire is gzip, not chunk-framed bytes. Running the chunked decoder
    over it reads attacker-controlled bytes as chunk-size lines — the
    exact primitive CVE-2019-... class desyncs are built from — and the
    RFC's own answer for a RESPONSE is 'read until the connection closes'.

    ⚠ FAILS ON CURRENT CODE. `_str_contains_token_ci` answers 'is the
    token `chunked` ANYWHERE in this list', which is position-INSENSITIVE,
    so `chunked, gzip` and `chunked, deflate` both select chunked framing.
    The package's only TE-rejection test uses a bare `gzip`, which this
    predicate also answers correctly — so the ordering half was never
    exercised.
    """
    assert_false(
        _is_chunked_framed(_te_head(String("chunked, gzip"))),
        "chunked is not the final coding — must not run the chunked decoder",
    )
    assert_false(
        _is_chunked_framed(_te_head(String("chunked, deflate"))),
        "chunked is not the final coding — must not run the chunked decoder",
    )


def test_te_across_two_header_lines_is_one_list() raises:
    """Two `Transfer-Encoding` lines are one comma-joined list, so
    `deflate` then `chunked` still has chunked final."""
    assert_true(_is_chunked_framed(String(
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: deflate\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
    )))


def test_te_chunked_not_final_across_two_header_lines() raises:
    """★ The same ordering rule when the list is SPLIT across lines:
    `chunked` then `deflate` still leaves chunked non-final.

    ⚠ FAILS ON CURRENT CODE, same root cause as the single-line case.
    """
    assert_false(
        _is_chunked_framed(String(
            "HTTP/1.1 200 OK\r\n"
            "Transfer-Encoding: chunked\r\n"
            "Transfer-Encoding: deflate\r\n"
            "\r\n"
        )),
        "chunked is not the final coding — must not run the chunked decoder",
    )


def test_te_token_lookalikes_are_not_chunked() raises:
    """`chunkedchunked` and `xchunked` are single tokens that are NOT
    `chunked`. A substring match would frame both as chunked."""
    assert_false(_is_chunked_framed(_te_head(String("chunkedchunked"))))
    assert_false(_is_chunked_framed(_te_head(String("xchunked"))))
    assert_false(_is_chunked_framed(_te_head(String("chunked-x"))))


def test_te_empty_value_is_rejected() raises:
    """`Transfer-Encoding:` with no coding is not `1#transfer-coding`."""
    var buf = _b(String("HTTP/1.1 200 OK\r\nTransfer-Encoding:\r\n\r\n"))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_false(r.is_ok())
    assert_false(r.is_chunked)


def test_te_htab_is_ows_after_the_colon() raises:
    """`Transfer-Encoding:\\tchunked` — HTAB is OWS, so the value is
    `chunked`. A parser that only strips SP reads the value as
    `\\tchunked` and silently drops to a different framing."""
    assert_true(_is_chunked_framed(String(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding:\tchunked\r\n\r\n"
    )))


def test_te_leading_empty_list_element_is_chunked() raises:
    """DIVERGENCE, PINNED DELIBERATELY. `,chunked`.

    RFC 9110 §5.6.1 requires a recipient to 'parse and ignore a reasonable
    number of empty list elements', which makes `,chunked` a one-element
    list whose only element is chunked. llhttp is stricter and treats it
    as not-chunked. We follow the RFC.

    Pinned because either answer is defensible and NEITHER was tested; if
    this is ever changed to match llhttp it should be a deliberate edit.
    """
    assert_true(_is_chunked_framed(_te_head(String(",chunked"))))


def test_te_obs_fold_over_the_chunked_value_is_rejected() raises:
    """obs-fold (RFC 9112 §5.2) is exactly the primitive that lets two
    participants disagree about a TE value. It MUST be rejected, not
    unfolded."""
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chun\r\n ked\r\n\r\n"
    )))
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\tgzip\r\n\r\n"
    )))


# =============================================================================
# §6 — The request/response ASYMMETRY (RFC 9112 §6.3(3)).
# =============================================================================


def test_response_with_unusable_te_is_rejected_not_close_delimited() raises:
    """PINNED DELIBERATELY — we are STRICTER than the RFC here, in the
    fail-closed direction.

    RFC 9112 §6.3(3) is asymmetric on purpose: on a REQUEST an unusable
    Transfer-Encoding is a 400; on a RESPONSE it is NOT an error — chunked
    simply is not applied and the body becomes close-delimited. llhttp
    reports `Transfer-Encoding: yolo` on a response with flags=200 and no
    error at all.

    We reject. The cost is real (a `Transfer-Encoding: gzip` response from
    a conformant-but-unusual origin is failed outright rather than read to
    EOF); the benefit is that we never guess at framing. `test_response_parser.mojo`'s
    `test_reject_unsupported_te` already pins the bare-`gzip`
    case — this test states the RFC rule the choice departs from, so the
    departure is visible to the next reader rather than being rediscovered.
    """
    var buf = _b(_te_head(String("yolo")))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(r.is_error())
    # Whatever the verdict, the one thing that must never happen is that
    # an unrecognised coding selects chunked framing.
    assert_false(r.is_chunked)


# =============================================================================
# §7 — Content-Length AND Transfer-Encoding together (Envoy TestResponseSplit).
# =============================================================================
# Envoy tests this at CL=0, CL<body and CL>body separately because each
# produces a different desync when a participant silently prefers one.


def test_cl_zero_with_chunked_is_rejected() raises:
    """CL=0 is the one most often waved through as 'harmless'."""
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 0\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
    )))


def test_cl_shorter_than_body_with_chunked_is_rejected() raises:
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
    )))


def test_cl_longer_than_body_with_chunked_is_rejected() raises:
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 100\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
    )))


def test_cl_and_chunked_rejected_in_either_header_order() raises:
    """Header order must not change the verdict — a parser that only
    checks 'CL then TE' is beaten by emitting TE first."""
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "Content-Length: 42\r\n"
        "\r\n"
    )))


# =============================================================================
# §8 — Neither CL nor TE: close-delimited (RFC 9112 §6.3(8)).
# =============================================================================


def test_no_cl_no_te_is_close_delimited() raises:
    """The final rung of the ladder. `content_length == -1` and
    `is_chunked == False` is how this parser spells 'read until close'."""
    var buf = _b(String("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(r.is_ok())
    assert_equal(r.content_length, -1)
    assert_false(r.is_chunked)


def test_http10_keep_alive_cannot_rescue_an_unframed_body() raises:
    """`HTTP/1.0 200 OK` + `Connection: keep-alive` + no CL is STILL
    close-delimited. Keep-alive changes whether the connection may be
    reused; it does NOT supply a length.

    A client that reads `keep-alive` as 'so the body must be zero-length'
    truncates every HTTP/1.0 response body it ever sees; one that treats
    the connection as reusable after a close-delimited body desyncs.
    """
    var buf = _b(String(
        "HTTP/1.0 200 OK\r\nConnection: keep-alive\r\n\r\n"
    ))
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(r.is_ok())
    assert_equal(Int(r.http_version_minor), 0)
    assert_false(r.connection_close)
    assert_equal(
        r.content_length, -1, "keep-alive supplies no length — still EOF-framed",
    )
    assert_false(r.is_chunked)


# =============================================================================
# §9 — The malformed-RESPONSE corpus. This did not exist anywhere.
# =============================================================================
# All three existing malformed suites are REQUEST-direction and never call
# `parse_response_head`. These are the response twins.


def test_malformed_bare_lf_line_endings_never_parse_ok() raises:
    """A response framed with bare LF instead of CRLF must never be
    accepted. Accepting it is how a header an upstream saw as data becomes
    a header here."""
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\nContent-Length: 0\n\n"
    )))
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 0\n\r\n"
    )))


def test_malformed_cr_without_lf_in_status_line() raises:
    """A lone CR inside the reason-phrase is a control character and MUST
    be rejected (RFC 9112 §4: reason-phrase is HTAB / SP / VCHAR /
    obs-text)."""
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\rContent-Length: 0\r\n\r\n"
    )))


def test_malformed_nul_in_header_value() raises:
    """NUL is not VCHAR, not obs-text and not OWS."""
    var buf = _b(String("HTTP/1.1 200 OK\r\nX-Nul: a"))
    buf.append(UInt8(0))
    var tail = _b(String("b\r\n\r\n"))
    var i = 0
    while i < tail.__len__():
        buf.append(tail[i])
        i = i + 1
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_false(r.is_ok(), "NUL in a header value must be rejected")


def test_malformed_bare_lf_in_header_value_is_response_splitting() raises:
    """A lone LF inside a field-value is the response-splitting
    primitive: a participant that unfolds it sees a header the emitter
    thought was data."""
    assert_false(_parse(String(
        "HTTP/1.1 200 OK\r\nX-Foo: a\nInjected: 1\r\n\r\n"
    )))


def test_malformed_leading_crlf_before_status_line() raises:
    """RFC 9112 §2.2's leniency is scoped to a SERVER reading a request
    line. A client MUST NOT skip junk before a status line — that junk is
    the tail of something else."""
    assert_false(_parse(String("\r\nHTTP/1.1 200 OK\r\n\r\n")))


def test_malformed_space_padded_header_name() raises:
    """`Foo : bar` — see §5.1 above; asserted here too because the
    malformed corpus is the place a reader looks for it."""
    assert_false(_parse(String("HTTP/1.1 200 OK\r\nFoo : bar\r\n\r\n")))


def test_malformed_empty_header_name() raises:
    """`: value` has a zero-length field name."""
    assert_false(_parse(String("HTTP/1.1 200 OK\r\n: value\r\n\r\n")))


def test_obs_text_in_reason_phrase_is_accepted() raises:
    """PINNED: 8-bit obs-text IS legal in a reason-phrase (RFC 9112 §4
    keeps obs-text for compatibility). Servers in non-UTF-8 locales emit
    it; rejecting would fail real responses. The status code is what we
    act on, and it must still be read correctly."""
    var buf = _b(String("HTTP/1.1 500 Interne"))
    buf.append(UInt8(0xC3))
    buf.append(UInt8(0xA9))
    var tail = _b(String(" Erreur\r\nContent-Length: 0\r\n\r\n"))
    var i = 0
    while i < tail.__len__():
        buf.append(tail[i])
        i = i + 1
    var r = parse_response_head(
        Span[UInt8](buf), ResponseParseLimits.defaults(),
    )
    assert_true(r.is_ok(), "obs-text in reason-phrase is legal")
    assert_equal(Int(r.status), 500)


def test_malformed_status_line_shapes() raises:
    """A small status-line table that nothing pinned: no SP before the
    reason, a doubled SP before the code, and a 4-digit code."""
    assert_false(_parse(String("HTTP/1.1 200OK\r\nContent-Length: 0\r\n\r\n")))
    assert_false(_parse(String("HTTP/1.1  200 OK\r\nContent-Length: 0\r\n\r\n")))
    assert_false(_parse(String("HTTP/1.1 2000 OK\r\nContent-Length: 0\r\n\r\n")))
    assert_false(_parse(String("HTTP/1.1 20 OK\r\nContent-Length: 0\r\n\r\n")))


def main() raises:
    # §1
    test_cl_leading_zeros_are_decimal()
    test_cl_0200_is_two_hundred_never_octal_128()
    test_cl_empty_value_is_rejected()
    test_cl_signed_values_are_rejected()
    test_cl_interior_whitespace_is_rejected()
    test_cl_surrounding_ows_is_stripped()
    test_cl_twenty_one_digits_is_rejected()
    # §2
    test_cl_guard_boundary_byte_span_twin()
    test_cl_guard_boundary_string_twin()
    test_cl_twenty_digit_wrap_value_never_parses_to_five()
    test_cl_int64_max_is_rejected_by_our_ceiling()
    # §3
    test_cl_duplicate_differing_values_is_unrecoverable()
    test_cl_duplicate_differing_only_by_ows_is_not_a_conflict()
    # §4
    test_content_length_x_is_not_content_length()
    test_transfer_encoding_x_is_not_transfer_encoding()
    test_cr_inside_header_name_is_not_a_token()
    test_space_before_colon_rejects_the_message()
    # §5
    test_te_chunked_last_applies_chunked()
    test_te_across_two_header_lines_is_one_list()
    test_te_token_lookalikes_are_not_chunked()
    test_te_empty_value_is_rejected()
    test_te_htab_is_ows_after_the_colon()
    test_te_leading_empty_list_element_is_chunked()
    test_te_obs_fold_over_the_chunked_value_is_rejected()
    # §6
    test_response_with_unusable_te_is_rejected_not_close_delimited()
    # §7
    test_cl_zero_with_chunked_is_rejected()
    test_cl_shorter_than_body_with_chunked_is_rejected()
    test_cl_longer_than_body_with_chunked_is_rejected()
    test_cl_and_chunked_rejected_in_either_header_order()
    # §8
    test_no_cl_no_te_is_close_delimited()
    test_http10_keep_alive_cannot_rescue_an_unframed_body()
    # §9
    test_malformed_bare_lf_line_endings_never_parse_ok()
    test_malformed_cr_without_lf_in_status_line()
    test_malformed_nul_in_header_value()
    test_malformed_bare_lf_in_header_value_is_response_splitting()
    test_malformed_leading_crlf_before_status_line()
    test_malformed_space_padded_header_name()
    test_malformed_empty_header_name()
    test_obs_text_in_reason_phrase_is_accepted()
    test_malformed_status_line_shapes()
    # -------------------------------------------------------------------
    # ⚠ KNOWN-RED CONFORMANCE BLOCK — deliberately LAST.
    # -------------------------------------------------------------------
    # These three assert RFC 9112 behaviour this parser does not have yet.
    # They are findings, not flakes, and each docstring carries the repro
    # and the exact line of `client/response_parser.mojo` responsible.
    # They sit at the END so that a run reports the whole green body first:
    # `main` is sequential (this package's idiom) and the FIRST raise ends
    # the process, so an unfixed red near the top hides forty passing
    # assertions behind it.
    # ⛔ Do not "fix" these by deleting or weakening them — the repair is
    # in the parser. Do not move them earlier either.
    # -------------------------------------------------------------------
    test_cl_duplicate_identical_values_is_accepted()
    test_te_chunked_not_final_must_not_frame_as_chunked()
    test_te_chunked_not_final_across_two_header_lines()
    print("OK: test_L2_response_framing_precedence")
