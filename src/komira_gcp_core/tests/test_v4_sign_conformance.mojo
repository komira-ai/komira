# =============================================================================
# komira_gcp_core/tests/test_v4_sign_conformance.mojo
# =============================================================================
#
# Cloud Storage V4 signing (GOOG4-RSA-SHA256) against Google's published
# conformance vectors, read at test time: storage/v1/v4_signatures.json and
# the vectors' signing key, storage/v1/test_service_account.not-a-test.json
# (a service account Google publishes as an inactive dummy). Neither is
# copied here: //third_party/googleapis_conformance_tests pins the
# conformance-tests archive by sha256 and extracts both, staged under
# conformance/. The JSON is parsed with komira_json.
#
# Per vector, with the signing instant its `timestamp`:
#   - the canonical request, byte for byte;
#   - the string to sign, byte for byte;
#   - the RSA signature with the dummy key, and the whole URL after the
#     authority (path, canonical query, signature).
# The canonical request is asserted, and not only the URL, because a
# canonicalization tested through one happy-path URL is tested at one input.
#
# ONE PUBLISHED VECTOR CONTRADICTS ITSELF: "Universe domain with virtual
# hosted style". Its expectedStringToSign, expectedUrl and signature are the
# virtual-hosted request (path /test-object), but its expectedCanonicalRequest
# has the path-style path /test-bucket/test-object, so sha256 of that
# canonical request is not the hash its own string to sign carries. This
# test signs the vector's inputs as they are (virtual-hosted, path
# /test-object) and checks the string to sign, signature and URL like any
# other. For the canonical request it asserts, by that exact name, that the
# published one still disagrees with its own string to sign and differs from
# ours only by that path, and that it is the only vector to. An upstream fix
# turns the test red, so the assertion is removed rather than left to rot.
#
# Hand-written gates cover what no vector does (a query name that is a
# prefix of another, refusals, expiry bounds, the time stamps).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import hex_lower_array_32, sha256_string
from komira_json import JsonValue, parse_json_value

from komira_gcp_core import (
    GCS_V4_DEFAULT_HOST,
    GCS_V4_MAX_EXPIRES_SECONDS,
    GcsV4Header,
    GcsV4QueryParam,
    GcsV4ServiceAccount,
    gcs_v4_build_canonical_request,
    gcs_v4_canonical_path,
    gcs_v4_canonical_query,
    gcs_v4_credential_scope,
    gcs_v4_percent_encode,
    gcs_v4_signed_url,
    gcs_v4_stamps_from_unix_seconds,
    gcs_v4_string_to_sign,
    pkcs8_private_key_der_from_pem,
)


comptime _VECTORS = "conformance/storage/v1/v4_signatures.json"
comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"

# The number of signingV4Tests at the pinned commit. Update it with the pin.
comptime _EXPECTED_VECTORS = 29

# The one vector whose canonical request disagrees with its string to sign.
comptime _SELF_CONTRADICTORY = "Universe domain with virtual hosted style"

comptime _SIG_MARKER = "&X-Goog-Signature="


# -----------------------------------------------------------------------------
# Reading the vectors
# -----------------------------------------------------------------------------


def _read_text(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _str(v: JsonValue, key: String) raises -> String:
    """`v[key]` as a string, or "" when absent."""
    if not v.has(key):
        return String()
    return v.get(key).as_string()


struct Vector(Copyable, Movable):
    var description: String
    var scheme: String
    var method: String
    var host: String
    var path: String
    var headers: List[GcsV4Header]
    var query: List[GcsV4QueryParam]
    var expires: Int
    var short_date: String
    var datetime_z: String
    var expected_cr: String
    var expected_sts: String
    var expected_url: String

    def __init__(out self):
        self.description = String()
        self.scheme = String()
        self.method = String()
        self.host = String()
        self.path = String()
        self.headers = List[GcsV4Header]()
        self.query = List[GcsV4QueryParam]()
        self.expires = 0
        self.short_date = String()
        self.datetime_z = String()
        self.expected_cr = String()
        self.expected_sts = String()
        self.expected_url = String()


# The keys a signingV4Tests entry may hold. Any other is an input this test
# does not apply, so it fails rather than ignore it.
def _vector_keys() -> List[String]:
    var out = List[String]()
    out.append("bucket")
    out.append("bucketBoundHostname")
    out.append("clientEndpoint")
    out.append("description")
    out.append("emulatorHostname")
    out.append("expectedCanonicalRequest")
    out.append("expectedStringToSign")
    out.append("expectedUrl")
    out.append("expiration")
    out.append("headers")
    out.append("hostname")
    out.append("method")
    out.append("object")
    out.append("queryParameters")
    out.append("scheme")
    out.append("timestamp")
    out.append("universeDomain")
    out.append("urlStyle")
    return out^


def _strip_endpoint(base: String) -> String:
    """An endpoint as a bare host: no scheme, no trailing `/`, no port.

    Vector "Simple GET with non-default hostname" sets `localhost:8080` and
    expects `host:localhost`, as Google's client libraries do."""
    var start = 0
    if base.startswith("https://"):
        start = 8
    elif base.startswith("http://"):
        start = 7
    var end = base.byte_length()
    var colon = base.find(":", start)
    if colon >= 0:
        end = colon
    var slash = base.find("/", start)
    if slash >= 0 and slash < end:
        end = slash
    return String(base[byte=start:end])


def _resolve_host(t: JsonValue) raises -> String:
    """The host the signature covers, from the vector's inputs.

    hostname > clientEndpoint > emulatorHostname > storage.<universeDomain>
    > storage.googleapis.com (vectors "Endpoint on client takes precedence
    over emulator" and "Hostname takes precendence over endpoint and
    emulator"); a bucket-bound hostname is the host itself; virtual-hosted
    style prefixes the bucket."""
    var style = _str(t, "urlStyle")
    if style == "BUCKET_BOUND_HOSTNAME":
        return _str(t, "bucketBoundHostname")
    var base = String(GCS_V4_DEFAULT_HOST)
    var universe = _str(t, "universeDomain")
    if universe.byte_length() > 0:
        base = "storage." + universe
    var keys = List[String]()
    keys.append("emulatorHostname")
    keys.append("clientEndpoint")
    keys.append("hostname")
    for i in range(len(keys)):
        var v = _str(t, keys[i])
        if v.byte_length() > 0:
            base = v
    base = _strip_endpoint(base)
    if style == "VIRTUAL_HOSTED_STYLE":
        return _str(t, "bucket") + "." + base
    return base^


def _resolve_path(t: JsonValue) raises -> String:
    """The path the signature covers, raw: `/<object>` when the bucket is in
    the host, else `/<bucket>/<object>` (`/<bucket>` with no object)."""
    var style = _str(t, "urlStyle")
    var obj = _str(t, "object")
    if style == "VIRTUAL_HOSTED_STYLE" or style == "BUCKET_BOUND_HOSTNAME":
        return "/" + obj
    if obj.byte_length() == 0:
        return "/" + _str(t, "bucket")
    return "/" + _str(t, "bucket") + "/" + obj


def _vector(t: JsonValue) raises -> Vector:
    var known = _vector_keys()
    for i in range(t.num_members()):
        var k = t.key_at(i)
        var ok = False
        for j in range(len(known)):
            if known[j] == k:
                ok = True
        if not ok:
            raise Error("vector key not applied by this test: " + k)

    var v = Vector()
    v.description = _str(t, "description")
    v.scheme = _str(t, "scheme")
    if v.scheme.byte_length() == 0:
        v.scheme = "https"
    v.method = _str(t, "method")
    v.host = _resolve_host(t)
    v.path = _resolve_path(t)
    if t.has("headers"):
        var h = t.get("headers")
        for i in range(h.num_members()):
            v.headers.append(
                GcsV4Header(h.key_at(i), h.value_at(i).as_string())
            )
    if t.has("queryParameters"):
        var q = t.get("queryParameters")
        for i in range(q.num_members()):
            v.query.append(
                GcsV4QueryParam(q.key_at(i), q.value_at(i).as_string())
            )
    v.expires = Int(t.get("expiration").as_int64())
    # "2019-02-01T09:00:00Z" -> 20190201 and 20190201T090000Z.
    var ts = _str(t, "timestamp")
    assert_equal(ts.byte_length(), 20, "timestamp " + ts)
    v.short_date = (
        String(ts[byte=0:4]) + String(ts[byte=5:7]) + String(ts[byte=8:10])
    )
    v.datetime_z = (
        v.short_date
        + "T"
        + String(ts[byte=11:13])
        + String(ts[byte=14:16])
        + String(ts[byte=17:19])
        + "Z"
    )
    v.expected_cr = _str(t, "expectedCanonicalRequest")
    v.expected_sts = _str(t, "expectedStringToSign")
    v.expected_url = _str(t, "expectedUrl")
    return v^


def _vectors() raises -> List[Vector]:
    var doc = parse_json_value(_read_text(_VECTORS))
    var tests = doc.get("signingV4Tests")
    var out = List[Vector]()
    for i in range(tests.array_len()):
        out.append(_vector(tests.element_at(i)))
    assert_equal(len(out), _EXPECTED_VECTORS, "signingV4Tests count")
    return out^


def _account() raises -> GcsV4ServiceAccount:
    var a = parse_json_value(_read_text(_ACCOUNT))
    var der = pkcs8_private_key_der_from_pem(a.get("private_key").as_string())
    return GcsV4ServiceAccount(a.get("client_email").as_string(), der^)


def _last_line(s: String) -> String:
    var at = s.rfind("\n")
    return String(s[byte = at + 1 :])


def _self_consistent(v: Vector) -> Bool:
    """Whether sha256 of the published canonical request is the hash the
    published string to sign carries."""
    return hex_lower_array_32(sha256_string(v.expected_cr)) == _last_line(
        v.expected_sts
    )


def _replace_line(s: String, index: Int, line: String) raises -> String:
    var parts = s.split("\n")
    var out = String()
    for i in range(len(parts)):
        if i > 0:
            out += "\n"
        out += line if i == index else String(parts[i])
    return out^


def _diff(what: String, v: Vector, got: String, want: String) -> Error:
    return Error(
        what
        + " mismatch for vector '"
        + v.description
        + "'\n GOT:\n"
        + got
        + "\n EXPECTED:\n"
        + want
    )


# -----------------------------------------------------------------------------
# The vectors
# -----------------------------------------------------------------------------


def test_every_published_vector() raises:
    var vs = _vectors()
    var account = _account()
    var cr_checked = 0
    var contradictory = 0
    for i in range(len(vs)):
        ref v = vs[i]
        var scope = gcs_v4_credential_scope(v.short_date, "auto")
        var built = gcs_v4_build_canonical_request(
            v.method,
            v.host,
            v.path,
            v.headers,
            v.query,
            account.client_email,
            scope,
            v.datetime_z,
            v.expires,
        )

        # The canonical request.
        if _self_consistent(v):
            if built.canonical_request != v.expected_cr:
                raise _diff(
                    "canonical request", v, built.canonical_request, v.expected_cr
                )
            cr_checked += 1
        else:
            # The self-contradictory vector, by name: its published canonical
            # request is ours with the path-style path on line 2.
            assert_equal(v.description, String(_SELF_CONTRADICTORY))
            assert_true(built.canonical_request != v.expected_cr)
            assert_equal(
                String(built.canonical_request.split("\n")[1]), "/test-object"
            )
            var published_path = String(v.expected_cr.split("\n")[1])
            assert_equal(published_path, "/test-bucket/test-object")
            assert_equal(
                _replace_line(built.canonical_request, 1, published_path),
                v.expected_cr,
            )
            contradictory += 1

        # The string to sign.
        var sts = gcs_v4_string_to_sign(
            built.canonical_request, v.datetime_z, scope
        )
        if sts != v.expected_sts:
            raise _diff("string to sign", v, sts, v.expected_sts)

        # The signature, and the URL after the authority.
        var url = gcs_v4_signed_url(
            v.scheme,
            v.method,
            v.host,
            v.path,
            v.headers,
            v.query,
            account,
            "auto",
            v.short_date,
            v.datetime_z,
            v.expires,
        )
        var got_sig = String(url[byte = url.find(_SIG_MARKER) + 18 :])
        var want_at = v.expected_url.find(_SIG_MARKER)
        assert_true(want_at > 0, "no signature in " + v.expected_url)
        var want_sig = String(v.expected_url[byte = want_at + 18 :])
        if got_sig != want_sig:
            raise _diff("signature", v, got_sig, want_sig)
        var scheme_end = v.expected_url.find("://") + 3
        var want_tail = String(
            v.expected_url[
                byte = v.expected_url.find("/", scheme_end) :
            ]
        )
        var got_tail = String(url[byte = url.find("/", url.find("://") + 3) :])
        if got_tail != want_tail:
            raise _diff("url", v, got_tail, want_tail)
        assert_true(url.startswith(v.scheme + "://" + v.host + "/"))
    # A loop that skips everything also passes: pin the counts.
    assert_equal(cr_checked, _EXPECTED_VECTORS - 1)
    assert_equal(contradictory, 1)


# -----------------------------------------------------------------------------
# Hand-written gates
# -----------------------------------------------------------------------------


def test_path_is_encoded_but_never_normalized() raises:
    assert_equal(
        gcs_v4_canonical_path("/b/amper&sand/file.ext"),
        "/b/amper%26sand/file.ext",
    )
    assert_equal(gcs_v4_canonical_path("/test-bucket//path/x"), "/test-bucket//path/x")
    assert_equal(gcs_v4_canonical_path("/b/./x"), "/b/./x")
    assert_equal(gcs_v4_canonical_path("/b/a/../x"), "/b/a/../x")
    assert_equal(gcs_v4_canonical_path(""), "/")


def test_percent_encoding_is_unreserved_only() raises:
    assert_equal(gcs_v4_percent_encode("aA0-._~", True), "aA0-._~")
    assert_equal(gcs_v4_percent_encode(" ", True), "%20")
    assert_equal(gcs_v4_percent_encode("%", True), "%25")
    assert_equal(gcs_v4_percent_encode("=", True), "%3D")
    assert_equal(gcs_v4_percent_encode("+", True), "%2B")
    assert_equal(gcs_v4_percent_encode("/", True), "%2F")
    assert_equal(gcs_v4_percent_encode("/", False), "/")
    # U+00E9 is two UTF-8 octets, so two escapes, upper-case hex.
    assert_equal(gcs_v4_percent_encode("é", True), "%C3%A9")
    # A four-octet code point.
    assert_equal(gcs_v4_percent_encode("\U0001F600", False), "%F0%9F%98%80")


def test_query_sorts_by_name_then_value() raises:
    # Sorting the joined strings would give `a0=y&a=x` (`=` sorts after the
    # digits). No vector has a name that is a prefix of another.
    var q = List[GcsV4QueryParam]()
    q.append(GcsV4QueryParam("a0", "y"))
    q.append(GcsV4QueryParam("a", "x"))
    assert_equal(gcs_v4_canonical_query(q), "a=x&a0=y")

    var q2 = List[GcsV4QueryParam]()
    q2.append(GcsV4QueryParam("k", "b"))
    q2.append(GcsV4QueryParam("k", "a"))
    assert_equal(gcs_v4_canonical_query(q2), "k=a&k=b")

    assert_equal(gcs_v4_canonical_query(List[GcsV4QueryParam]()), "")


def _cr(host: String, headers: List[GcsV4Header]) raises -> String:
    return gcs_v4_build_canonical_request(
        "GET",
        host,
        "/b/o",
        headers,
        List[GcsV4QueryParam](),
        "sa@p.iam.gserviceaccount.com",
        "20190201/auto/storage/goog4_request",
        "20190201T090000Z",
        10,
    ).canonical_request


def test_headers_join_duplicates_and_refuse_host() raises:
    var h = List[GcsV4Header]()
    h.append(GcsV4Header("X-B", " 2 "))
    h.append(GcsV4Header("x-a", "1"))
    h.append(GcsV4Header("X-b", "3"))
    var cr = _cr("storage.googleapis.com", h)
    assert_true(
        cr.find("\nhost:storage.googleapis.com\nx-a:1\nx-b:2,3\n\nhost;x-a;x-b\n")
        > 0,
        cr,
    )

    # A host header would be joined into `host:a,b`; refused.
    var with_host = List[GcsV4Header]()
    with_host.append(GcsV4Header("Host", "other.example"))
    var raised = False
    try:
        _ = _cr("storage.googleapis.com", with_host)
    except:
        raised = True
    assert_true(raised, "a host header was signed")

    # No host at all is refused rather than signed as "".
    raised = False
    try:
        _ = _cr(" ", List[GcsV4Header]())
    except:
        raised = True
    assert_true(raised, "an empty host was signed")

    # An empty header name is refused.
    var empty_name = List[GcsV4Header]()
    empty_name.append(GcsV4Header(" ", "v"))
    raised = False
    try:
        _ = _cr("storage.googleapis.com", empty_name)
    except:
        raised = True
    assert_true(raised, "an empty header name was signed")


def test_non_ascii_header_value_is_kept_byte_for_byte() raises:
    var h = List[GcsV4Header]()
    h.append(GcsV4Header("x-goog-meta-name", "\tcafé  au  lait "))
    var cr = _cr("storage.googleapis.com", h)
    assert_true(cr.find("\nx-goog-meta-name:café au lait\n") > 0, cr)


def _expiry_raises(account: GcsV4ServiceAccount, expires: Int) raises -> Bool:
    try:
        _ = gcs_v4_signed_url(
            "https",
            "GET",
            "storage.googleapis.com",
            "/b/o",
            List[GcsV4Header](),
            List[GcsV4QueryParam](),
            account,
            "auto",
            "20190201",
            "20190201T090000Z",
            expires,
        )
    except:
        return True
    return False


def test_expiry_bounds_are_refused_not_clamped() raises:
    var account = _account()
    assert_true(_expiry_raises(account, GCS_V4_MAX_EXPIRES_SECONDS + 1))
    assert_true(_expiry_raises(account, 0))
    assert_true(_expiry_raises(account, -1))
    assert_false(_expiry_raises(account, GCS_V4_MAX_EXPIRES_SECONDS))
    assert_false(_expiry_raises(account, 1))


def test_signing_needs_a_key() raises:
    var raised = False
    try:
        _ = gcs_v4_signed_url(
            "https",
            "GET",
            "storage.googleapis.com",
            "/b/o",
            List[GcsV4Header](),
            List[GcsV4QueryParam](),
            GcsV4ServiceAccount("sa@p.iam.gserviceaccount.com", List[UInt8]()),
            "auto",
            "20190201",
            "20190201T090000Z",
            10,
        )
    except:
        raised = True
    assert_true(raised, "signed with no key")


def test_stamps_render_iso8601_basic() raises:
    # 2019-02-01T09:00:00Z, the vectors' timestamp.
    var s = gcs_v4_stamps_from_unix_seconds(Int64(1549011600))
    assert_equal(s.short_date, "20190201")
    assert_equal(s.datetime_z, "20190201T090000Z")
    assert_equal(s.unix_seconds, Int64(1549011600))
    assert_equal(
        gcs_v4_stamps_from_unix_seconds(Int64(0)).datetime_z,
        "19700101T000000Z",
    )
    assert_equal(
        gcs_v4_stamps_from_unix_seconds(Int64(1582934400)).short_date,
        "20200229",
    )
    assert_equal(
        gcs_v4_stamps_from_unix_seconds(Int64(-1)).datetime_z,
        "19691231T235959Z",
    )
    assert_equal(
        gcs_v4_stamps_from_unix_seconds(Int64(253402300799)).datetime_z,
        "99991231T235959Z",
    )
    var raised = False
    try:
        _ = gcs_v4_stamps_from_unix_seconds(Int64(253402300800))
    except:
        raised = True
    assert_true(raised, "a five-digit year was rendered")


def main() raises:
    test_every_published_vector()
    test_path_is_encoded_but_never_normalized()
    test_percent_encoding_is_unreserved_only()
    test_query_sorts_by_name_then_value()
    test_headers_join_duplicates_and_refuse_host()
    test_non_ascii_header_value_is_kept_byte_for_byte()
    test_expiry_bounds_are_refused_not_clamped()
    test_signing_needs_a_key()
    test_stamps_render_iso8601_basic()
    print("all gcs v4 signing conformance tests passed")
