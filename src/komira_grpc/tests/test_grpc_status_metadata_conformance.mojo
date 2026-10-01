# =============================================================================
# test_grpc_status_metadata_conformance.mojo — status mapping + metadata wire
# =============================================================================
#
# HTTP/gRPC CONFORMANCE. Surfaces whose bar is a peer we do not control,
# checked against grpc-go / grpc-java / the spec rather than against our own
# assumptions:
#
#   §2  HTTP non-200 -> gRPC status.  grpc-go `HTTPStatusConvTab`
#       (`internal/transport/http_util.go`).
#   §3  The RETRY consequence of §2 — the half that makes it a correctness
#       question and not a cosmetic mismatch.
#   §4  `-bin` metadata base64.  PROTOCOL-HTTP2.md "Binary-Value", grpc-go's
#       own `Zm9vAGJhcg` vector.
#   §5  Metadata key handling on the wire.  PROTOCOL-HTTP2.md "Custom-Metadata",
#       the interop `custom_metadata` case.
#   §6  `te: trailers`.  PROTOCOL-HTTP2.md "Request-Headers".
#   §7  Header injection through user-supplied metadata.
#
# The unit tests for the same surfaces (`test_L5_error` t10, `test_L5_metadata`
# t10, `test_L5_headers` t7) assert the same conformant answers.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import (
    GRPC_METADATA_HEADER_PREFIX,
    RpcMetadata,
    RetryPolicy,
    CallOptions,
    ProtocolGrpcProto,
    ProtocolConnectProto,
    base64_encode_standard,
    base64_decode_standard,
    build_unary_request_headers,
    build_stream_request_headers,
    format_grpc_error_message,
    grpc_error_from_http_non_200,
    is_retryable_grpc_error,
    GRPC_HEADER_GRPC_TIMEOUT,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_PERMISSION_DENIED,
    GRPC_STATUS_UNAUTHENTICATED,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_UNIMPLEMENTED,
    GRPC_STATUS_UNKNOWN,
)
from komira_http.client.header_map import HeaderMap


# =============================================================================
# §1 — Helpers.
# =============================================================================

comptime HDR_TE: String = "te"
comptime HDR_TE_TRAILERS: String = "trailers"
"""Spelled as LITERALS, not as `komira_grpc.headers.GRPC_HEADER_TE`, on
purpose: this is a WIRE assertion. A test that reads the same constant the
producer writes cannot tell you the bytes are right, only that they are
self-consistent."""


def _bytes_of(s: String) -> List[UInt8]:
    """The ASCII bytes of `s` as a List."""
    var out = List[UInt8]()
    var n = s.byte_length()
    var i = 0
    while i < n:
        out.append(UInt8(ord(s[byte=i])))
        i = i + 1
    return out^


def _strip_padding(s: String) -> String:
    """`s` with its trailing `=` padding removed — the UNPADDED spelling that
    grpc-go and grpc-java emit by default."""
    var n = s.byte_length()
    var end = n
    while end > 0 and ord(s[byte = end - 1]) == ord("="):
        end = end - 1
    if end == 0:
        return String("")
    var out = List[UInt8]()
    var i = 0
    while i < end:
        out.append(UInt8(ord(s[byte=i])))
        i = i + 1
    return String(unsafe_from_utf8=Span(out))


def _decode_raises(s: String) -> Bool:
    """Did `base64_decode_standard(s)` raise?"""
    try:
        var _d = base64_decode_standard(s)
        return False
    except:
        return True


def _lists_equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    var i = 0
    while i < len(a):
        if a[i] != b[i]:
            return False
        i = i + 1
    return True


# =============================================================================
# §2 — ★ HTTP-STATUS MAPPING. grpc-go `HTTPStatusConvTab`, one row per test.
# =============================================================================
#
#   var HTTPStatusConvTab = map[int]codes.Code{
#       http.StatusBadRequest:           codes.Internal,          // 400
#       http.StatusUnauthorized:         codes.Unauthenticated,   // 401
#       http.StatusForbidden:            codes.PermissionDenied,  // 403
#       http.StatusNotFound:             codes.Unimplemented,     // 404
#       http.StatusTooManyRequests:      codes.Unavailable,       // 429
#       http.StatusBadGateway:           codes.Unavailable,       // 502
#       http.StatusServiceUnavailable:   codes.Unavailable,       // 503
#       http.StatusGatewayTimeout:       codes.Unavailable,       // 504
#   }
#
# `grpc_error_from_http_non_200` (error.mojo) must map through this table;
# collapsing every non-200 to UNKNOWN(2) is the failure these rows catch.
# =============================================================================


def test_http_400_maps_to_internal() raises:
    """400 Bad Request -> INTERNAL(13). The request never reached a handler;
    the fault is in the frame/headers we sent."""
    assert_equal(
        grpc_error_from_http_non_200(UInt16(400)).code,
        GRPC_STATUS_INTERNAL,
        "400 -> INTERNAL",
    )


def test_http_401_maps_to_unauthenticated() raises:
    """401 Unauthorized -> UNAUTHENTICATED(16). Distinguishing this from
    PERMISSION_DENIED is what tells a caller to REFRESH A TOKEN rather than
    give up: an OAuth2 refresh loop keyed on 16 never fires on a 2."""
    assert_equal(
        grpc_error_from_http_non_200(UInt16(401)).code,
        GRPC_STATUS_UNAUTHENTICATED,
        "401 -> UNAUTHENTICATED",
    )


def test_http_403_maps_to_permission_denied() raises:
    """403 Forbidden -> PERMISSION_DENIED(7)."""
    assert_equal(
        grpc_error_from_http_non_200(UInt16(403)).code,
        GRPC_STATUS_PERMISSION_DENIED,
        "403 -> PERMISSION_DENIED",
    )


def test_http_404_maps_to_unimplemented() raises:
    """404 Not Found -> UNIMPLEMENTED(12). NOT_FOUND(5) is the wrong answer
    and grpc-go says so: a 404 from an HTTP layer means the ROUTE is absent
    (no such service/method at this endpoint), not that a requested entity is
    missing. A caller that treats 5 as "the row isn't there" would silently
    swallow a misrouted request."""
    assert_equal(
        grpc_error_from_http_non_200(UInt16(404)).code,
        GRPC_STATUS_UNIMPLEMENTED,
        "404 -> UNIMPLEMENTED",
    )


def test_http_429_maps_to_unavailable() raises:
    """429 Too Many Requests -> UNAVAILABLE(14) — retryable with backoff."""
    assert_equal(
        grpc_error_from_http_non_200(UInt16(429)).code,
        GRPC_STATUS_UNAVAILABLE,
        "429 -> UNAVAILABLE",
    )


def test_http_502_maps_to_unavailable() raises:
    """502 Bad Gateway -> UNAVAILABLE(14).

    `test_L5_error`'s t10 asserts the same row.
    """
    assert_equal(
        grpc_error_from_http_non_200(UInt16(502)).code,
        GRPC_STATUS_UNAVAILABLE,
        "502 -> UNAVAILABLE",
    )


def test_http_503_maps_to_unavailable() raises:
    """503 Service Unavailable -> UNAVAILABLE(14). This is the literal
    response a Cloud Run service produces while it is degraded."""
    assert_equal(
        grpc_error_from_http_non_200(UInt16(503)).code,
        GRPC_STATUS_UNAVAILABLE,
        "503 -> UNAVAILABLE",
    )


def test_http_504_maps_to_unavailable() raises:
    """504 Gateway Timeout -> UNAVAILABLE(14). This is the response a Cloud
    Run service produces when its own request ceiling is reached because the
    upstream request hung."""
    assert_equal(
        grpc_error_from_http_non_200(UInt16(504)).code,
        GRPC_STATUS_UNAVAILABLE,
        "504 -> UNAVAILABLE",
    )


def test_http_statuses_outside_the_table_map_to_unknown() raises:
    """Anything NOT in `HTTPStatusConvTab` stays UNKNOWN(2).

    This is the half that keeps the table honest: a mapping that answered
    "UNAVAILABLE" for every 5xx would make a 500 INTERNAL SERVER ERROR — which
    carries NO not-processed guarantee — look replayable, and a replayed
    CREATE whose first attempt landed is two resources.
    """
    assert_equal(
        grpc_error_from_http_non_200(UInt16(405)).code,
        GRPC_STATUS_UNKNOWN,
        "405 not in table",
    )
    assert_equal(
        grpc_error_from_http_non_200(UInt16(415)).code,
        GRPC_STATUS_UNKNOWN,
        "415 not in table",
    )
    assert_equal(
        grpc_error_from_http_non_200(UInt16(418)).code,
        GRPC_STATUS_UNKNOWN,
        "418 not in table",
    )
    assert_equal(
        grpc_error_from_http_non_200(UInt16(500)).code,
        GRPC_STATUS_UNKNOWN,
        "500 not in table -- deliberately NOT retryable",
    )
    assert_equal(
        grpc_error_from_http_non_200(UInt16(505)).code,
        GRPC_STATUS_UNKNOWN,
        "505 not in table",
    )


def test_http_status_diagnostic_message_survives_the_mapping() raises:
    """Whatever the code becomes, the HTTP status must stay IN the message —
    it is the only thing that tells an operator an edge proxy answered rather
    than the service. (Pinned so a mapping change cannot drop it.)
    """
    var err = grpc_error_from_http_non_200(UInt16(504))
    var hay = err.message
    var needle = String("504")
    var found = False
    var i = 0
    while i + needle.byte_length() <= hay.byte_length():
        var ok = True
        var j = 0
        while j < needle.byte_length():
            if ord(hay[byte = i + j]) != ord(needle[byte=j]):
                ok = False
                break
            j = j + 1
        if ok:
            found = True
            break
        i = i + 1
    assert_true(found, "the HTTP status stays in the diagnostic message")


# =============================================================================
# §3 — ★ THE RETRY CONSEQUENCE. Why §2 is not a cosmetic mismatch.
# =============================================================================


def test_edge_proxy_504_is_retryable_under_the_shipped_policy() raises:
    """★ THE END-TO-END HALF, through PRODUCTION FUNCTIONS ONLY, no network.

    `RetryPolicy.idempotent()` carries `RETRY_CODES_AIP194` — UNAVAILABLE(14)
    and nothing else, which `test_unary_status_retry.mojo` (r3)/(r6) pin
    deliberately. So the status a proxy failure MAPS TO decides whether it is
    ever replayed.

    Compose the two shipped functions the client composes:
        grpc_error_from_http_non_200 -> format_grpc_error_message
                                     -> is_retryable_grpc_error

    If every edge-proxy failure became UNKNOWN(2), 2 is not in the AIP-194
    set, and therefore a Cloud Run 503/504 — what a degraded service
    produces — would NEVER BE RETRIED. The retry machinery would be present,
    correct, and unreachable for this entire failure class.
    """
    var policy = RetryPolicy.idempotent()
    var statuses = List[Int]()
    statuses.append(429)
    statuses.append(502)
    statuses.append(503)
    statuses.append(504)
    var i = 0
    while i < len(statuses):
        var hs = statuses[i]
        var err = grpc_error_from_http_non_200(UInt16(hs))
        var msg = format_grpc_error_message(err.code, err.message)
        assert_true(
            is_retryable_grpc_error(msg, policy),
            String("HTTP ")
            + String(hs)
            + " must be retryable under the shipped idempotent policy; it"
            " maps to code "
            + String(Int(err.code)),
        )
        i = i + 1


def test_non_transient_http_status_is_not_retryable() raises:
    """The other direction, so §3 cannot be satisfied by making everything
    retryable: 400/401/403/404 must NOT be replayed. Replaying a 403 five
    times over ~20s of backoff spends the caller's whole budget on a
    permanent failure."""
    var policy = RetryPolicy.idempotent()
    var statuses = List[Int]()
    statuses.append(400)
    statuses.append(401)
    statuses.append(403)
    statuses.append(404)
    var i = 0
    while i < len(statuses):
        var hs = statuses[i]
        var err = grpc_error_from_http_non_200(UInt16(hs))
        var msg = format_grpc_error_message(err.code, err.message)
        assert_false(
            is_retryable_grpc_error(msg, policy),
            String("HTTP ") + String(hs) + " must NOT be retried",
        )
        i = i + 1


# =============================================================================
# §4 — ★ UNPADDED BASE64 IN `-bin` METADATA.
# =============================================================================
#
# PROTOCOL-HTTP2.md:
#   "Binary-Value -> {base64 encoded value}"
#   "Implementations MUST accept padded and un-padded values and should emit
#    un-padded values."
#
# grpc-go and grpc-java EMIT UNPADDED. A decoder that raises when
# `len % 4 != 0` fails to decode every `-bin` header from a Go or Java peer
# whose payload length is not a multiple of 3.
# =============================================================================


def test_grpc_go_unpadded_bin_vector() raises:
    """★ grpc-go's own vector: decode('key-bin', 'Zm9vAGJhcg') == "foo\\x00bar".

    Ten characters — `10 % 4 == 2`. Contains an embedded NUL, because the
    whole point of a `-bin` header is that the value is not text.

    `test_L5_metadata`'s t10 asserts the same boundary (only 4k+1 raises).
    """
    var got = base64_decode_standard(String("Zm9vAGJhcg"))
    var want = List[UInt8]()
    want.append(UInt8(ord("f")))
    want.append(UInt8(ord("o")))
    want.append(UInt8(ord("o")))
    want.append(UInt8(0x00))
    want.append(UInt8(ord("b")))
    want.append(UInt8(ord("a")))
    want.append(UInt8(ord("r")))
    assert_equal(len(got), 7, "7 bytes decoded from the unpadded vector")
    assert_true(_lists_equal(got, want), "bytes match 'foo\\x00bar'")


def test_padded_and_unpadded_decode_identically_1_to_6_bytes() raises:
    """Exhaustive padding table: source lengths 1..6 cover every residue of
    `len % 3`, and therefore every padding shape (`==`, `=`, none). Each is
    decoded in BOTH spellings and the bytes must be identical.

    Lengths whose base64 is `len % 4 in (2, 3)` are the ones a quad-only
    decoder rejects outright.
    """
    var failures = 0
    var n = 1
    while n <= 6:
        var src = List[UInt8]()
        var i = 0
        while i < n:
            src.append(UInt8(0xA0 + i))
            i = i + 1
        var padded = base64_encode_standard(Span(src))
        var unpadded = _strip_padding(padded)
        var via_padded = base64_decode_standard(padded)
        if _decode_raises(unpadded):
            failures = failures + 1
            print(
                "  unpadded base64 REJECTED for a ",
                n,
                "-byte value: '",
                unpadded,
                "' (len%4 = ",
                unpadded.byte_length() % 4,
                ")",
            )
        else:
            var via_unpadded = base64_decode_standard(unpadded)
            if not _lists_equal(via_padded, via_unpadded):
                failures = failures + 1
                print("  padded/unpadded DISAGREE for ", n, " bytes")
        n = n + 1
    assert_equal(failures, 0, "source lengths whose unpadded form fails")


def test_bin_value_round_trips_every_byte_unpadded() raises:
    """A `-bin` value containing every byte 0x00..0xFF, including embedded
    NULs, must survive the UNPADDED spelling exactly. 256 % 3 == 1, so the
    padded form ends `==` and the unpadded form is `len % 4 == 2` — the shape
    a quad-only decoder rejects."""
    var src = List[UInt8]()
    var i = 0
    while i < 256:
        src.append(UInt8(i))
        i = i + 1
    var unpadded = _strip_padding(base64_encode_standard(Span(src)))
    var got = base64_decode_standard(unpadded)
    assert_equal(len(got), 256, "256 bytes back from the unpadded form")
    assert_true(_lists_equal(got, src), "every byte 0x00..0xFF preserved")


def test_bin_header_is_split_on_comma_before_base64_decode() raises:
    """PROTOCOL-HTTP2.md mandates splitting a Binary-Header on `,` BEFORE
    base64-decoding, because HPACK and intermediaries may legitimately join
    duplicate header lines into one comma-separated value.

    A decoder that does not split sees a joined `-bin` header as one blob
    that either raises on the `,` or decodes to garbage.

    Asserted here at its cheapest expressible altitude: the decoder must not
    turn a joined pair into a failure.
    """
    var joined = String("Zm9v,YmFy")  # base64("foo") + "," + base64("bar")
    assert_false(
        _decode_raises(joined),
        "a comma-joined -bin value must not fail to decode",
    )


# =============================================================================
# §5 — ★ CUSTOM METADATA KEYS ON THE CLASSIC gRPC WIRE.
# =============================================================================


def test_custom_metadata_key_travels_verbatim_over_classic_grpc() raises:
    """★ The gRPC interop `custom_metadata` case, as a direct falsifier.

    Over gRPC/HTTP2 a Custom-Metadata key travels VERBATIM. The
    `grpc-metadata-` prefix is a CONNECT / gRPC-Web HTTP-GATEWAY convention
    for carrying metadata across a protocol translation — it is not part of
    the gRPC/HTTP2 wire format.

    `RpcMetadata.drain_into_request_headers` prefixes every key, so if
    `headers.mojo` called it on the CLASSIC gRPC path as well as the Connect
    path, a real gRPC server would never see `x-grpc-test-echo-initial`; it
    would see `grpc-metadata-x-grpc-test-echo-initial` and ignore it, and the
    interop case could not pass.

    `test_L5_headers`'s t7 asserts the same verbatim spelling.
    """
    var opts = CallOptions.new()
    opts.metadata.set(
        String("x-grpc-test-echo-initial"),
        String("test_initial_metadata_value"),
    )
    var trailing = List[UInt8]()
    trailing.append(UInt8(0xAB))
    trailing.append(UInt8(0xAB))
    trailing.append(UInt8(0xAB))
    opts.metadata.set_bin(
        String("x-grpc-test-echo-trailing-bin"), Span(trailing)
    )

    var hdrs = build_unary_request_headers[ProtocolGrpcProto](opts, now_us=0)

    var initial = hdrs.get(String("x-grpc-test-echo-initial"))
    assert_true(
        initial.__bool__(),
        "classic gRPC must carry the custom key VERBATIM",
    )
    assert_equal(
        initial.value(),
        String("test_initial_metadata_value"),
        "interop initial-metadata value",
    )
    var trailing_hdr = hdrs.get(String("x-grpc-test-echo-trailing-bin"))
    assert_true(
        trailing_hdr.__bool__(),
        "classic gRPC must carry the -bin key VERBATIM",
    )
    assert_false(
        hdrs.contains(
            GRPC_METADATA_HEADER_PREFIX + "x-grpc-test-echo-initial"
        ),
        "the grpc-metadata- prefix must NOT appear on the gRPC/HTTP2 wire",
    )


def test_connect_path_keeps_the_grpc_metadata_prefix() raises:
    """The other polarity, so the case above cannot be satisfied by "delete
    the prefix everywhere": over CONNECT the `Grpc-Metadata-` prefix is
    exactly right, and removing it would break every Connect peer.
    """
    var opts = CallOptions.new()
    opts.metadata.set(String("user-id"), String("42"))
    var hdrs = build_unary_request_headers[ProtocolConnectProto](opts, now_us=0)
    var got = hdrs.get(GRPC_METADATA_HEADER_PREFIX + "user-id")
    assert_true(got.__bool__(), "Connect keeps the grpc-metadata- prefix")
    assert_equal(got.value(), String("42"), "value")


def test_metadata_keys_are_case_insensitive_on_the_wire() raises:
    """HTTP/2 header names are lowercase; a metadata key set in mixed case
    must be retrievable lowercased."""
    var opts = CallOptions.new()
    opts.metadata.set(String("X-Request-Id"), String("abc"))
    var hdrs = build_unary_request_headers[ProtocolConnectProto](opts, now_us=0)
    assert_true(
        hdrs.contains(GRPC_METADATA_HEADER_PREFIX + "x-request-id"),
        "mixed-case key retrievable lowercase",
    )


# =============================================================================
# §6 — `te: trailers`.
# =============================================================================


def test_classic_grpc_unary_sends_te_trailers() raises:
    """`te: trailers` is MANDATORY on a classic-gRPC request — the terminal
    `grpc-status` arrives in HTTP/2 trailers, and a spec-compliant frontend
    (nghttpx / Envoy / the Google front ends) REJECTS a request without it
    with a trailers-only `grpc-status=2` and an empty body.

    `headers.mojo` appends it; this assertion keeps it from being dropped.
    """
    var opts = CallOptions.new()
    var hdrs = build_unary_request_headers[ProtocolGrpcProto](opts, now_us=0)
    var te = hdrs.get(HDR_TE)
    assert_true(te.__bool__(), "classic gRPC unary sends te")
    assert_equal(te.value(), HDR_TE_TRAILERS, "te: trailers")


def test_classic_grpc_streaming_sends_te_trailers() raises:
    """And on STREAMING too — the terminal status arrives in trailers
    regardless of unary vs streaming."""
    var opts = CallOptions.new()
    var hdrs = build_stream_request_headers[ProtocolGrpcProto](opts, now_us=0)
    var te = hdrs.get(HDR_TE)
    assert_true(te.__bool__(), "classic gRPC streaming sends te")
    assert_equal(te.value(), HDR_TE_TRAILERS, "te: trailers")


def test_connect_must_not_send_te_trailers() raises:
    """BOTH POLARITIES. Connect streaming is enveloped but does NOT use HTTP/2
    trailers, so it must NOT advertise `te: trailers`. Without this half, the
    two assertions above are satisfiable by appending `te` unconditionally —
    which is precisely the bug keying on `connect_protocol_version()` (not
    `unary_is_enveloped()`) exists to avoid, as the comment in `headers.mojo`
    warns.
    """
    var opts = CallOptions.new()
    var unary = build_unary_request_headers[ProtocolConnectProto](
        opts, now_us=0
    )
    assert_false(unary.contains(HDR_TE), "Connect unary must not send te")
    var stream = build_stream_request_headers[ProtocolConnectProto](
        opts, now_us=0
    )
    assert_false(stream.contains(HDR_TE), "Connect streaming must not send te")


def test_no_deadline_emits_no_grpc_timeout_header_at_all() raises:
    """No deadline configured => NO `grpc-timeout` header.

    Emitting `grpc-timeout: 0u` to mean "no deadline" INVERTS the meaning: to
    the server, `0u` is a deadline that has ALREADY EXPIRED. (The absent-vs-
    empty collision of `parse_grpc_timeout`, seen from the emit side.)
    """
    var opts = CallOptions.new()
    var hdrs = build_unary_request_headers[ProtocolGrpcProto](opts, now_us=0)
    assert_false(
        hdrs.contains(GRPC_HEADER_GRPC_TIMEOUT),
        "no deadline => no grpc-timeout header",
    )
    var stream = build_stream_request_headers[ProtocolGrpcProto](
        opts, now_us=0
    )
    assert_false(
        stream.contains(GRPC_HEADER_GRPC_TIMEOUT),
        "no deadline => no grpc-timeout header (streaming)",
    )


# =============================================================================
# §7 — ★ HEADER INJECTION THROUGH USER-SUPPLIED METADATA.
# =============================================================================


def _set_raises(mut md: RpcMetadata, name: String, value: String) -> Bool:
    """Did `RpcMetadata.set(name, value)` refuse the pair?"""
    try:
        md.set(name, value)
        return False
    except:
        return True


def test_metadata_rejects_crlf_in_key() raises:
    """★ Header injection through a metadata KEY.

    `HeaderMap.append` (komira_http) performs NO validation at all, so
    `RpcMetadata.set` must refuse before handing a String to it. A CR/LF in a
    caller-supplied metadata key is request smuggling on any path that ever
    serialises these headers as HTTP/1.1 text — and this same `RpcMetadata`
    feeds the Connect-over-HTTP/1.1 path.

    Per the Header-Name ABNF (PROTOCOL-HTTP2.md: `1*( %x30-39 / %x61-7A /
    "_" / "-" / "." )`) these are not merely dangerous, they are ILLEGAL.
    """
    var md = RpcMetadata.new()
    assert_true(
        _set_raises(md, String("x\r\nevil"), String("v")),
        "CRLF in a metadata KEY must be refused",
    )


def test_metadata_rejects_crlf_in_value() raises:
    """Same hazard on the value side: `set('x', 'a\\r\\nb')` splices a second
    header line."""
    var md = RpcMetadata.new()
    assert_true(
        _set_raises(md, String("x-trace"), String("a\r\nb")),
        "CRLF in a metadata VALUE must be refused",
    )


def test_metadata_rejects_empty_key() raises:
    """The Header-Name ABNF is `1*(...)` — one or more. An empty key is not a
    header."""
    var md = RpcMetadata.new()
    assert_true(
        _set_raises(md, String(""), String("v")),
        "an empty metadata key must be refused",
    )


def test_metadata_rejects_pseudo_header_smuggling() raises:
    """★ A `:`-prefixed name is an HTTP/2 PSEUDO-header. Accepting one through
    user metadata lets a caller-supplied value reach HPACK as `:authority` /
    `:path` / `:method`, i.e. re-point the request.

    The `grpc-metadata-` prefix in the Connect drain path incidentally
    defuses this on the prefixed path — but `RpcMetadata` also backs
    `opts.raw_metadata`, whose `drain_raw_into_request_headers` emits keys
    VERBATIM. So the refusal has to be at `set`, not at drain.
    """
    var md = RpcMetadata.new()
    assert_true(
        _set_raises(md, String(":authority"), String("evil.example.com")),
        "a pseudo-header name must be refused as user metadata",
    )


def test_metadata_rejects_key_outside_the_header_name_abnf() raises:
    """Space, uppercase-with-punctuation, and the HPACK-illegal `:` inside a
    name are all outside `1*( DIGIT / lowercase / "_" / "-" / "." )`."""
    var md = RpcMetadata.new()
    assert_true(
        _set_raises(md, String("bad key"), String("v")),
        "a space in a metadata key must be refused",
    )
    assert_true(
        _set_raises(md, String("key:with:colons"), String("v")),
        "a colon inside a metadata key must be refused",
    )


# =============================================================================
# §N — The run harness.
# =============================================================================
#
# ⚠ EVERY CASE RUNS, EVEN AFTER ONE FAILS. A sequential `main()` that lets the
# first `assert_*` abort reports ONE finding per run, and this file
# enumerates a conformance surface — "the first row of the table is wrong" and
# "every row of the table is wrong" are different bugs with different fixes.
# The overall verdict is unchanged: one RED case fails the target.
# =============================================================================


def main() raises:
    var failed = List[String]()
    var passed = 0
    try:
        test_http_400_maps_to_internal()
        passed = passed + 1
    except e:
        failed.append(String("test_http_400_maps_to_internal -- ") + String(e))
    try:
        test_http_401_maps_to_unauthenticated()
        passed = passed + 1
    except e:
        failed.append(String("test_http_401_maps_to_unauthenticated -- ") + String(e))
    try:
        test_http_403_maps_to_permission_denied()
        passed = passed + 1
    except e:
        failed.append(String("test_http_403_maps_to_permission_denied -- ") + String(e))
    try:
        test_http_404_maps_to_unimplemented()
        passed = passed + 1
    except e:
        failed.append(String("test_http_404_maps_to_unimplemented -- ") + String(e))
    try:
        test_http_429_maps_to_unavailable()
        passed = passed + 1
    except e:
        failed.append(String("test_http_429_maps_to_unavailable -- ") + String(e))
    try:
        test_http_502_maps_to_unavailable()
        passed = passed + 1
    except e:
        failed.append(String("test_http_502_maps_to_unavailable -- ") + String(e))
    try:
        test_http_503_maps_to_unavailable()
        passed = passed + 1
    except e:
        failed.append(String("test_http_503_maps_to_unavailable -- ") + String(e))
    try:
        test_http_504_maps_to_unavailable()
        passed = passed + 1
    except e:
        failed.append(String("test_http_504_maps_to_unavailable -- ") + String(e))
    try:
        test_http_statuses_outside_the_table_map_to_unknown()
        passed = passed + 1
    except e:
        failed.append(String("test_http_statuses_outside_the_table_map_to_unknown -- ") + String(e))
    try:
        test_http_status_diagnostic_message_survives_the_mapping()
        passed = passed + 1
    except e:
        failed.append(String("test_http_status_diagnostic_message_survives_the_mapping -- ") + String(e))
    try:
        test_edge_proxy_504_is_retryable_under_the_shipped_policy()
        passed = passed + 1
    except e:
        failed.append(String("test_edge_proxy_504_is_retryable_under_the_shipped_policy -- ") + String(e))
    try:
        test_non_transient_http_status_is_not_retryable()
        passed = passed + 1
    except e:
        failed.append(String("test_non_transient_http_status_is_not_retryable -- ") + String(e))
    try:
        test_grpc_go_unpadded_bin_vector()
        passed = passed + 1
    except e:
        failed.append(String("test_grpc_go_unpadded_bin_vector -- ") + String(e))
    try:
        test_padded_and_unpadded_decode_identically_1_to_6_bytes()
        passed = passed + 1
    except e:
        failed.append(String("test_padded_and_unpadded_decode_identically_1_to_6_bytes -- ") + String(e))
    try:
        test_bin_value_round_trips_every_byte_unpadded()
        passed = passed + 1
    except e:
        failed.append(String("test_bin_value_round_trips_every_byte_unpadded -- ") + String(e))
    try:
        test_bin_header_is_split_on_comma_before_base64_decode()
        passed = passed + 1
    except e:
        failed.append(String("test_bin_header_is_split_on_comma_before_base64_decode -- ") + String(e))
    try:
        test_custom_metadata_key_travels_verbatim_over_classic_grpc()
        passed = passed + 1
    except e:
        failed.append(String("test_custom_metadata_key_travels_verbatim_over_classic_grpc -- ") + String(e))
    try:
        test_connect_path_keeps_the_grpc_metadata_prefix()
        passed = passed + 1
    except e:
        failed.append(String("test_connect_path_keeps_the_grpc_metadata_prefix -- ") + String(e))
    try:
        test_metadata_keys_are_case_insensitive_on_the_wire()
        passed = passed + 1
    except e:
        failed.append(String("test_metadata_keys_are_case_insensitive_on_the_wire -- ") + String(e))
    try:
        test_classic_grpc_unary_sends_te_trailers()
        passed = passed + 1
    except e:
        failed.append(String("test_classic_grpc_unary_sends_te_trailers -- ") + String(e))
    try:
        test_classic_grpc_streaming_sends_te_trailers()
        passed = passed + 1
    except e:
        failed.append(String("test_classic_grpc_streaming_sends_te_trailers -- ") + String(e))
    try:
        test_connect_must_not_send_te_trailers()
        passed = passed + 1
    except e:
        failed.append(String("test_connect_must_not_send_te_trailers -- ") + String(e))
    try:
        test_no_deadline_emits_no_grpc_timeout_header_at_all()
        passed = passed + 1
    except e:
        failed.append(String("test_no_deadline_emits_no_grpc_timeout_header_at_all -- ") + String(e))
    try:
        test_metadata_rejects_crlf_in_key()
        passed = passed + 1
    except e:
        failed.append(String("test_metadata_rejects_crlf_in_key -- ") + String(e))
    try:
        test_metadata_rejects_crlf_in_value()
        passed = passed + 1
    except e:
        failed.append(String("test_metadata_rejects_crlf_in_value -- ") + String(e))
    try:
        test_metadata_rejects_empty_key()
        passed = passed + 1
    except e:
        failed.append(String("test_metadata_rejects_empty_key -- ") + String(e))
    try:
        test_metadata_rejects_pseudo_header_smuggling()
        passed = passed + 1
    except e:
        failed.append(String("test_metadata_rejects_pseudo_header_smuggling -- ") + String(e))
    try:
        test_metadata_rejects_key_outside_the_header_name_abnf()
        passed = passed + 1
    except e:
        failed.append(String("test_metadata_rejects_key_outside_the_header_name_abnf -- ") + String(e))

    var total = passed + len(failed)
    if len(failed) > 0:
        print("")
        print("==== test_grpc_status_metadata_conformance: RED ====")
        var i = 0
        while i < len(failed):
            print("  [FAIL]", failed[i])
            i = i + 1
        print("")
        raise Error(
            String("test_grpc_status_metadata_conformance: ")
            + String(len(failed))
            + " of "
            + String(total)
            + " conformance cases FAILED (see [FAIL] lines above)"
        )
    print("test_grpc_status_metadata_conformance: ", total, "/", total, " PASS")
