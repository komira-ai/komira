# Azure Shared Key signing as a pure function. Azure publishes no vector
# suite (unlike AWS's aws4_testsuite), so the end-to-end case checks the
# Authorization header against a golden computed independently of this code
# (Python's hmac over the same string-to-sign, in the comment below), and the
# canonicalization steps each against the documented algorithm: x-ms-*
# headers lowercased, sorted, merged and trimmed; the canonicalized resource
# with its query parameters lowercased (mixed-case names included), grouped
# and sorted; and the 13-field string-to-sign.
from std.testing import assert_equal, assert_false, assert_true

from komira_azure_core import AzureSharedKey
from komira_azure_blob import (
    AzureSharedKeySigningContext,
    azure_shared_key_sign,
    build_string_to_sign,
    canonicalize_headers,
    canonicalize_resource,
)
from komira_azure_blob.azure import AzureConfig, build_azure_blob_url
from komira_azure_blob.azure_signing import Header, query_params_from


# -----------------------------------------------------------------------------
# The golden, computed independently of this code.
#
# Inputs:
#   account = "mystoraccount"
#   key_b64 = "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
#             (base64 of "This is a fake key for testing 1234567890123\n";
#              NOT a real Azure key)
#   verb = "GET"
#   resource_path = "/container/blob.txt"
#   x_ms_headers = [
#     ("x-ms-date", "Thu, 01 Oct 2026 12:00:00 GMT"),
#     ("x-ms-version", "2015-02-21"),
#   ]
#
# StringToSign:
#   GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n
#   x-ms-version:2015-02-21\n/mystoraccount/container/blob.txt
#
# Signature, by Python:
#   import hmac, hashlib, base64
#   key = base64.b64decode("VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK")
#   base64.b64encode(hmac.new(key, sts.encode(), hashlib.sha256).digest())
#     == "qzu2SLO4TnzbYyPx9EJ4tE9ipoaAOZqKOq9WNrjdsdw="
# -----------------------------------------------------------------------------


def _make_test_cred() -> AzureSharedKey:
    return AzureSharedKey(
        String("mystoraccount"),
        String(
            "VGhpcyBpcyBhIGZha2Uga2V5IGZvciB0ZXN0aW5nIDEyMzQ1Njc4OTAxMjMK"
        ),
    )


def _make_test_x_ms_headers() raises -> List[Header]:
    var out = List[Header]()
    out.append(Header(String("x-ms-date"), String("Thu, 01 Oct 2026 12:00:00 GMT")))
    out.append(Header(String("x-ms-version"), String("2015-02-21")))
    return out^


# -----------------------------------------------------------------------------
# canonicalize_headers — unit
# -----------------------------------------------------------------------------


def test_canonicalize_headers_empty() raises:
    var hdrs = List[Header]()
    assert_equal(canonicalize_headers(hdrs), String(""))


def test_canonicalize_headers_ignores_non_xms() raises:
    """Per Microsoft docs: ONLY x-ms-* headers participate."""
    var hdrs = List[Header]()
    hdrs.append(Header(String("Content-Type"), String("text/plain")))
    hdrs.append(Header(String("X-Custom"), String("ignored")))
    assert_equal(canonicalize_headers(hdrs), String(""))


def test_canonicalize_headers_lowercased_and_sorted() raises:
    """Names lowercased, lex-sorted, ":"-joined with value."""
    var hdrs = List[Header]()
    hdrs.append(Header(String("x-ms-version"), String("2015-02-21")))
    hdrs.append(Header(String("X-MS-Date"), String("Thu, 01 Oct 2026 12:00:00 GMT")))
    var got = canonicalize_headers(hdrs)
    var expected = String(
        "x-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\nx-ms-version:2015-02-21\n"
    )
    assert_equal(got, expected)


def test_canonicalize_headers_merges_duplicates_with_comma() raises:
    """Duplicate names are merged with comma."""
    var hdrs = List[Header]()
    hdrs.append(Header(String("x-ms-meta-foo"), String("v1")))
    hdrs.append(Header(String("x-ms-meta-foo"), String("v2")))
    var got = canonicalize_headers(hdrs)
    assert_equal(got, String("x-ms-meta-foo:v1,v2\n"))


# -----------------------------------------------------------------------------
# canonicalize_resource — unit
# -----------------------------------------------------------------------------


def test_canonicalize_resource_no_query() raises:
    var qparams = List[Header]()
    var got = canonicalize_resource(
        String("mystoraccount"), String("/container/blob"), qparams
    )
    assert_equal(got, String("/mystoraccount/container/blob"))


def test_canonicalize_resource_with_query() raises:
    """Sorted query params on their own lines as "name:value"."""
    var qparams = List[Header]()
    qparams.append(Header(String("comp"), String("metadata")))
    qparams.append(Header(String("restype"), String("container")))
    var got = canonicalize_resource(
        String("mystoraccount"), String("/container"), qparams
    )
    assert_equal(
        got,
        String(
            "/mystoraccount/container\ncomp:metadata\nrestype:container"
        ),
    )


def test_canonicalize_resource_with_duplicate_query_keys() raises:
    """Duplicate query keys: values comma-joined, then sorted within key."""
    var qparams = List[Header]()
    qparams.append(Header(String("k"), String("b")))
    qparams.append(Header(String("k"), String("a")))
    var got = canonicalize_resource(
        String("acct"), String("/p"), qparams
    )
    assert_equal(got, String("/acct/p\nk:a,b"))


def test_canonicalize_resource_lowercases_mixed_case_query_names() raises:
    """Microsoft's Shared Key spec (the canonicalized resource of the
    current format): convert every query parameter NAME to lowercase, sort by that lowercased name,
    and on a name that repeats, list its values sorted and comma-separated.
    VALUES keep their case. A query written `Comp=list&RESTYPE=container`
    therefore canonicalizes exactly as `comp=list&restype=container` does,
    a name that differs only in case is the same parameter, and the sort is
    on the lowercased name (`Zeta` after `alpha`, where a byte-wise sort of
    the names as written would put it first)."""
    var got = canonicalize_resource(
        String("mystoraccount"),
        String("/container"),
        query_params_from(String("Comp=list&RESTYPE=container")),
    )
    assert_equal(
        got,
        String("/mystoraccount/container\ncomp:list\nrestype:container"),
    )
    var lower = canonicalize_resource(
        String("mystoraccount"),
        String("/container"),
        query_params_from(String("comp=list&restype=container")),
    )
    assert_equal(got, lower)

    var mixed = canonicalize_resource(
        String("acct"),
        String("/p"),
        query_params_from(String("Zeta=Up&alpha=x&Prefix=b&PREFIX=A")),
    )
    assert_equal(mixed, String("/acct/p\nalpha:x\nprefix:A,b\nzeta:Up"))


# -----------------------------------------------------------------------------
# build_string_to_sign — the 13-field structure
# -----------------------------------------------------------------------------


def test_string_to_sign_get_blob() raises:
    """Build the StringToSign for a simple GET /container/blob.txt with
    x-ms-date + x-ms-version, no Content-* / If-* headers."""
    var ctx = AzureSharedKeySigningContext.for_get(
        _make_test_cred(),
        String("/container/blob.txt"),
        _make_test_x_ms_headers(),
    )
    var sts = build_string_to_sign(ctx)
    # The 13 mandatory fields are all empty except verb + the
    # canonicalized headers + canonicalized resource at the tail.
    var expected = String("GET\n\n\n\n\n\n\n\n\n\n\n\n")
    expected += String("x-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n")
    expected += String("x-ms-version:2015-02-21\n")
    expected += String("/mystoraccount/container/blob.txt")
    assert_equal(sts, expected)


# -----------------------------------------------------------------------------
# Full azure_shared_key_sign — end-to-end against the hand-derived golden
# -----------------------------------------------------------------------------


def test_azure_shared_key_sign_e2e_golden() raises:
    """The Authorization header equals the independently computed golden
    (see the comment above), and the string-to-sign is asserted first so a
    canonicalization regression is told apart from an HMAC one."""
    var ctx = AzureSharedKeySigningContext.for_get(
        _make_test_cred(),
        String("/container/blob.txt"),
        _make_test_x_ms_headers(),
    )
    var result = azure_shared_key_sign(ctx)
    var expected_sts = String("GET\n\n\n\n\n\n\n\n\n\n\n\n")
    expected_sts += String("x-ms-date:Thu, 01 Oct 2026 12:00:00 GMT\n")
    expected_sts += String("x-ms-version:2015-02-21\n")
    expected_sts += String("/mystoraccount/container/blob.txt")
    assert_equal(result.string_to_sign, expected_sts)
    assert_equal(
        result.signature_b64, String("qzu2SLO4TnzbYyPx9EJ4tE9ipoaAOZqKOq9WNrjdsdw=")
    )
    assert_equal(
        result.authorization,
        String("SharedKey mystoraccount:qzu2SLO4TnzbYyPx9EJ4tE9ipoaAOZqKOq9WNrjdsdw="),
    )


def test_azure_shared_key_sign_signature_stable() raises:
    """Run twice; the signature MUST be byte-identical (algorithm is pure)."""
    var ctx1 = AzureSharedKeySigningContext.for_get(
        _make_test_cred(),
        String("/container/blob.txt"),
        _make_test_x_ms_headers(),
    )
    var r1 = azure_shared_key_sign(ctx1)
    var ctx2 = AzureSharedKeySigningContext.for_get(
        _make_test_cred(),
        String("/container/blob.txt"),
        _make_test_x_ms_headers(),
    )
    var r2 = azure_shared_key_sign(ctx2)
    assert_equal(r1.signature_b64, r2.signature_b64)
    assert_equal(r1.authorization, r2.authorization)


def test_azure_shared_key_sign_signature_differs_on_path_change() raises:
    """Same key, different resource path → different signature."""
    var ctx1 = AzureSharedKeySigningContext.for_get(
        _make_test_cred(),
        String("/container/blob.txt"),
        _make_test_x_ms_headers(),
    )
    var ctx2 = AzureSharedKeySigningContext.for_get(
        _make_test_cred(),
        String("/container/other.txt"),
        _make_test_x_ms_headers(),
    )
    var r1 = azure_shared_key_sign(ctx1)
    var r2 = azure_shared_key_sign(ctx2)
    assert_true(r1.signature_b64 != r2.signature_b64)


def test_azure_shared_key_sign_signature_differs_on_date_change() raises:
    """Same key + path, different x-ms-date → different signature
    (no timestamp replay)."""
    var hdrs1 = List[Header]()
    hdrs1.append(
        Header(String("x-ms-date"), String("Thu, 01 Oct 2026 12:00:00 GMT"))
    )
    hdrs1.append(Header(String("x-ms-version"), String("2015-02-21")))
    var hdrs2 = List[Header]()
    hdrs2.append(
        Header(String("x-ms-date"), String("Fri, 02 Oct 2026 00:00:00 GMT"))
    )
    hdrs2.append(Header(String("x-ms-version"), String("2015-02-21")))
    var ctx1 = AzureSharedKeySigningContext.for_get(
        _make_test_cred(), String("/c/b"), hdrs1^
    )
    var ctx2 = AzureSharedKeySigningContext.for_get(
        _make_test_cred(), String("/c/b"), hdrs2^
    )
    var r1 = azure_shared_key_sign(ctx1)
    var r2 = azure_shared_key_sign(ctx2)
    assert_true(r1.signature_b64 != r2.signature_b64)


# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# The wire path and the canonicalized resource are ONE encoded string.
#
# Shared Key's canonicalized resource carries the ENCODED URI path (only the
# query values are decoded), and the signing layer reads it off the request
# URL, which build_azure_blob_url encoded. So a blob name with a space or a
# non-ASCII character is encoded byte-wise once, and the canonical resource
# embeds that same encoding verbatim; were either side to encode differently
# the HMAC would not verify.
# -----------------------------------------------------------------------------


def _blob_path(blob: String) -> String:
    var url = build_azure_blob_url(
        AzureConfig.azure(String("mystoraccount")), String("my-container"), blob
    )
    return url.path.copy()


def test_blob_key_space_wire_matches_canonical() raises:
    var wire_path = _blob_path(String("dt=2026 10/part 0.parquet"))
    assert_equal(wire_path, String("/my-container/dt%3D2026%2010/part%200.parquet"))
    assert_false(wire_path.find(String(" ")) >= 0, wire_path)
    var canon = canonicalize_resource(
        String("mystoraccount"), wire_path, List[Header]()
    )
    assert_equal(canon, String("/mystoraccount") + wire_path)


def test_blob_key_non_ascii_encoded_bytewise_wire_matches_canonical() raises:
    # "é" is U+00E9, UTF-8 bytes C3 A9: each byte is escaped on its own.
    var bytes = List[UInt8]()
    bytes.append(UInt8(0x63))  # c
    bytes.append(UInt8(0x61))  # a
    bytes.append(UInt8(0x66))  # f
    bytes.append(UInt8(0xC3))
    bytes.append(UInt8(0xA9))
    bytes.append(UInt8(0x2F))  # /
    bytes.append(UInt8(0x64))  # d
    var blob = String(unsafe_from_utf8=Span(bytes))
    var wire_path = _blob_path(blob)
    assert_equal(wire_path, String("/my-container/caf%C3%A9/d"))
    var canon = canonicalize_resource(
        String("mystoraccount"), wire_path, List[Header]()
    )
    assert_equal(canon, String("/mystoraccount") + wire_path)


def main() raises:
    test_canonicalize_headers_empty()
    test_canonicalize_headers_ignores_non_xms()
    test_canonicalize_headers_lowercased_and_sorted()
    test_canonicalize_headers_merges_duplicates_with_comma()
    test_canonicalize_resource_no_query()
    test_canonicalize_resource_with_query()
    test_canonicalize_resource_with_duplicate_query_keys()
    test_canonicalize_resource_lowercases_mixed_case_query_names()
    test_string_to_sign_get_blob()
    test_azure_shared_key_sign_e2e_golden()
    test_azure_shared_key_sign_signature_stable()
    test_azure_shared_key_sign_signature_differs_on_path_change()
    test_azure_shared_key_sign_signature_differs_on_date_change()
    test_blob_key_space_wire_matches_canonical()
    test_blob_key_non_ascii_encoded_bytewise_wire_matches_canonical()
    print("OK")
