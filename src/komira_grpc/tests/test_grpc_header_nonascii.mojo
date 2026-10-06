# =============================================================================
# test_grpc_header_nonascii.mojo: non-ASCII metadata and routing values
# =============================================================================
#
# The client reads `-bin` metadata from the peer's trailers
# (`base64_decode_standard`), validates caller metadata (`RpcMetadata.set`)
# and builds `x-goog-request-params` from request fields (`match_path_template`
# / `build_routing_params`; a GCS object name is any UTF-8 text). Reading any
# of these with `s[byte=i]` asserts on the first UTF-8 continuation byte
# ("does not lie on a codepoint boundary") and aborts the whole process, so
# before the fix every leg below except T5 killed the test binary instead of
# answering or raising.
#
# Spec (gRPC PROTOCOL-HTTP2.md, google.api.routing, RFC 6570):
#   * A Binary-Header value is base64; a non-ASCII byte is outside the
#     alphabet, so decoding RAISES (a refusal, not an abort).
#   * Header-Name is `1*( 0-9 / a-z / _ / - / . )`: a non-ASCII key RAISES.
#     A non-ASCII value is tolerated (metadata.mojo says why).
#   * Routing values are percent-encoded per BYTE of their UTF-8: `é` is
#     `%C3%A9`; a non-ASCII segment matches `*` like any other.
#
# Invalid UTF-8 on the wire: the HPACK decoder and HeaderMap turn each wire
# byte into one char (`chr(byte)`), so a lone 0x80, 0xFF and a truncated 0xC3
# arrive as U+0080, U+00FF and U+00C3; T1 and T2 run those too.
#
# Coverage:
#   T1  base64_decode_standard on `Zm9vé`, `é`, `Zm9v,é`: raises an
#       invalid-character error; `Zm9v` still decodes (control).
#   T2  RpcMetadata.set: key `café` raises naming byte 195 at offset 3; value
#       `café` is stored.
#   T3  match_path_template on a non-ASCII field value: a `*` capture and a
#       `**` capture return the exact UTF-8 text.
#   T4  build_routing_params on a non-ASCII value: exact percent-encoding.
#   T5  resolve_redirect_location on a non-ASCII Location (komira_http_client;
#       its byte slices sit at ASCII boundaries, so it never aborted): pinned
#       so it stays that way.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_client.redirect_policy import (
    REDIRECT_RESOLVED,
    resolve_redirect_location,
)

from komira_grpc import (
    RpcMetadata,
    base64_decode_standard,
    build_routing_params,
    match_path_template,
)


def _raises_b64(s: String) -> String:
    try:
        _ = base64_decode_standard(s)
    except e:
        return String(e)
    return String("<no error>")


def test_t1_base64_nonascii() raises:
    print("  T1 base64 decode of a non-ASCII value...")
    for v in [String("Zm9vé"), String("é"), String("Zm9v,é"), String(" é ")]:
        var err = _raises_b64(v)
        assert_true(
            "invalid base64 character" in err,
            String("refused, not aborted: ") + v + " -> " + err,
        )
    for w in [chr(0x80), chr(0xFF), chr(0xC3)]:
        for v in [String("Zm9v") + w, w.copy(), String("Zm9v,") + w]:
            var err = _raises_b64(v)
            assert_true("invalid base64 character" in err, err)
    var ok = base64_decode_standard(String("Zm9v"))
    assert_equal(len(ok), 3)
    assert_equal(ok[0], UInt8(ord("f")))
    print("    OK")


def test_t2_metadata_set() raises:
    print("  T2 RpcMetadata.set...")
    var md = RpcMetadata()
    var err = String("<no error>")
    try:
        md.set(String("café"), String("x"))
    except e:
        err = String(e)
    assert_true("illegal byte 195 at offset 3" in err, err)
    assert_equal(md.count(), 0)
    md.set(String("x-name"), String("café ✓"))
    assert_equal(md.count(), 1)
    for w in [chr(0x80), chr(0xFF), chr(0xC3)]:
        var kerr = String("<no error>")
        try:
            md.set(String("k") + w, String("x"))
        except e:
            kerr = String(e)
        # U+0080 is C2 80; U+00FF and U+00C3 start with C3.
        assert_true(
            "illegal byte 194 at offset 1" in kerr
            or "illegal byte 195 at offset 1" in kerr,
            kerr,
        )
        md.set(String("x-w"), String("v") + w)
    assert_equal(md.count(), 4)
    print("    OK")


def test_t3_match_path_template() raises:
    print("  T3 routing template match...")
    var m1 = match_path_template(
        String("projects/café/locations/✓"), String("projects/{project=*}/**")
    )
    assert_true(m1.__bool__())
    assert_equal(m1.value(), String("café"))
    var m2 = match_path_template(
        String("projects/_/buckets/café"), String("{bucket=**}")
    )
    assert_true(m2.__bool__())
    assert_equal(m2.value(), String("projects/_/buckets/café"))
    var m3 = match_path_template(String("x/é"), String("x/{name=é}"))
    assert_true(m3.__bool__())
    assert_equal(m3.value(), String("é"))
    print("    OK")


def test_t4_build_routing_params() raises:
    print("  T4 routing params percent-encoding...")
    var pairs = List[Tuple[StaticString, String]]()
    pairs.append((StaticString("bucket"), String("café/x")))
    pairs.append((StaticString("name"), String("✓")))
    pairs.append((StaticString("w"), chr(0x80) + chr(0xFF)))
    assert_equal(
        build_routing_params(pairs),
        String("bucket=caf%C3%A9%2Fx&name=%E2%9C%93&w=%C2%80%C3%BF"),
    )
    print("    OK")


def test_t5_redirect_location() raises:
    print("  T5 redirect Location...")
    var t = resolve_redirect_location(
        String("h.example"), String("https://café.example/é?q=ü")
    )
    assert_equal(t.kind, REDIRECT_RESOLVED)
    assert_equal(t.host, String("café.example"))
    assert_equal(t.path, String("/é?q=ü"))
    var t2 = resolve_redirect_location(String("h.example"), String("//é/x"))
    assert_equal(t2.kind, REDIRECT_RESOLVED)
    assert_equal(t2.host, String("é"))
    assert_equal(t2.path, String("/x"))
    print("    OK")


def main() raises:
    print("== non-ASCII metadata and routing values ==")
    test_t1_base64_nonascii()
    test_t2_metadata_set()
    test_t3_match_path_template()
    test_t4_build_routing_params()
    test_t5_redirect_location()
    print("== PASSED (5 legs) ==")
