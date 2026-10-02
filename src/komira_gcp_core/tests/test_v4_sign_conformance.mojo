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
# Per vector, signing at its `timestamp` (turned into unix seconds here and
# rendered by gcs_v4_stamps_from_unix_seconds, as a caller would):
#   - the canonical request, byte for byte;
#   - the string to sign, byte for byte;
#   - the RSA signature with the dummy key, and the whole URL: scheme,
#     authority with its port, path, canonical query and signature.
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

from komira_crypto import (
    hex_lower_array_32,
    rsa_pkcs8_der_from_pem,
    sha256_string,
)
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
    gcs_v4_signed_url,
    gcs_v4_stamps_from_unix_seconds,
    gcs_v4_string_to_sign,
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


struct Vector(Copyable, Movable, Deinitable):
    var description: String
    var scheme: String
    var method: String
    var authority: String
    var path: String
    var headers: List[GcsV4Header]
    var query: List[GcsV4QueryParam]
    var expires: Int
    var unix_seconds: Int64
    var expected_cr: String
    var expected_sts: String
    var expected_url: String

    def __init__(out self):
        self.description = String()
        self.scheme = String()
        self.method = String()
        self.authority = String()
        self.path = String()
        self.headers = List[GcsV4Header]()
        self.query = List[GcsV4QueryParam]()
        self.expires = 0
        self.unix_seconds = 0
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


def _authority_of(endpoint: String) -> String:
    """An endpoint as a URL authority: no scheme, nothing from the first `/`
    on, and the port KEPT. The signer drops the port from the signed host:
    vector "Simple GET with non-default hostname" sets `localhost:8080`,
    sends to `http://localhost:8080/...` and signs `host:localhost`."""
    var start = 0
    if endpoint.startswith("https://"):
        start = 8
    elif endpoint.startswith("http://"):
        start = 7
    var end = endpoint.byte_length()
    var slash = endpoint.find("/", start)
    if slash >= 0:
        end = slash
    return String(endpoint[byte=start:end])


def _resolve_authority(t: JsonValue) raises -> String:
    """The URL authority, from the vector's inputs.

    hostname > clientEndpoint > emulatorHostname > storage.<universeDomain>
    > storage.googleapis.com (vectors "Endpoint on client takes precedence
    over emulator" and "Hostname takes precendence over endpoint and
    emulator"); a bucket-bound hostname is the authority itself;
    virtual-hosted style prefixes the bucket."""
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
    base = _authority_of(base)
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


def _days_from_civil(y_in: Int, m: Int, d: Int) -> Int:
    """Days since the Unix epoch of a proleptic Gregorian date (H. Hinnant,
    "chrono-Compatible Low-Level Date Algorithms"): the inverse the signer's
    stamps are checked against, written independently of it."""
    var y = y_in - 1 if m <= 2 else y_in
    var era = y // 400  # `//` floors; no truncation adjustment
    var yoe = y - era * 400
    var mp = m - 3 if m > 2 else m + 9
    var doy = (153 * mp + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _field(ts: String, start: Int, end: Int) raises -> Int:
    return Int(String(ts[byte=start:end]))


def _unix_from_rfc3339(ts: String) raises -> Int64:
    """`YYYY-MM-DDTHH:MM:SSZ`, the form of every vector's `timestamp`, as
    unix seconds."""
    assert_equal(ts.byte_length(), 20, "timestamp " + ts)
    assert_true(ts.endswith("Z"), "timestamp " + ts)
    var days = _days_from_civil(
        _field(ts, 0, 4), _field(ts, 5, 7), _field(ts, 8, 10)
    )
    return Int64(
        days * 86400
        + _field(ts, 11, 13) * 3600
        + _field(ts, 14, 16) * 60
        + _field(ts, 17, 19)
    )


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
    v.authority = _resolve_authority(t)
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
    # The signer renders its stamps from this instant, as a caller would.
    v.unix_seconds = _unix_from_rfc3339(_str(t, "timestamp"))
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
    var der = rsa_pkcs8_der_from_pem(a.get("private_key").as_string())
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


def _signature_of(url: String) raises -> String:
    var at = url.find(_SIG_MARKER)
    assert_true(at > 0, "no signature in " + url)
    return String(url[byte = at + _SIG_MARKER.byte_length() :])


def test_every_published_vector() raises:
    var vs = _vectors()
    var account = _account()
    var cr_checked = 0
    var contradictory = 0
    for i in range(len(vs)):
        ref v = vs[i]
        var stamps = gcs_v4_stamps_from_unix_seconds(v.unix_seconds)
        var scope = gcs_v4_credential_scope(stamps.short_date, "auto")
        var built = gcs_v4_build_canonical_request(
            v.method,
            v.authority,
            v.path,
            v.headers,
            v.query,
            account.client_email,
            scope,
            stamps.datetime_z,
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
            built.canonical_request, stamps.datetime_z, scope
        )
        if sts != v.expected_sts:
            raise _diff("string to sign", v, sts, v.expected_sts)

        # The signature, then the whole URL: scheme, authority (with its
        # port), path, canonical query and signature.
        var url = gcs_v4_signed_url(
            v.scheme,
            v.method,
            v.authority,
            v.path,
            v.headers,
            v.query,
            account,
            "auto",
            stamps,
            v.expires,
        )
        var got_sig = _signature_of(url)
        var want_sig = _signature_of(v.expected_url)
        if got_sig != want_sig:
            raise _diff("signature", v, got_sig, want_sig)
        if url != v.expected_url:
            raise _diff("url", v, url, v.expected_url)
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


def _q(value: String) -> String:
    """The canonical query of one parameter `k=<value>`."""
    var q = List[GcsV4QueryParam]()
    q.append(GcsV4QueryParam("k", value))
    return gcs_v4_canonical_query(q)


def test_percent_encoding_is_unreserved_only() raises:
    # Through the path and the query, the two places the encoder is used.
    assert_equal(_q("aA0-._~"), "k=aA0-._~")
    assert_equal(_q(" "), "k=%20")
    assert_equal(_q("%"), "k=%25")
    assert_equal(_q("="), "k=%3D")
    assert_equal(_q("+"), "k=%2B")
    # `/` is encoded in a query and kept in a path.
    assert_equal(_q("/"), "k=%2F")
    assert_equal(gcs_v4_canonical_path("/a b/%"), "/a%20b/%25")
    # A query name is encoded like a value.
    var named = List[GcsV4QueryParam]()
    named.append(GcsV4QueryParam("a/b c", "v"))
    assert_equal(gcs_v4_canonical_query(named), "a%2Fb%20c=v")
    # U+00E9 is two UTF-8 octets, so two escapes, upper-case hex.
    assert_equal(_q("é"), "k=%C3%A9")
    # A four-octet code point.
    assert_equal(gcs_v4_canonical_path("/\U0001F600"), "/%F0%9F%98%80")


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


# An arbitrary signing instant for the hand-written gates:
# 20261001T090000Z.
comptime _GATE_UNIX_SECONDS: Int64 = 1790845200


def _cr(authority: String, headers: List[GcsV4Header]) raises -> String:
    return _cr_with(authority, "GET", "/b/o", headers, List[GcsV4QueryParam]())


def _cr_with(
    authority: String,
    method: String,
    path: String,
    headers: List[GcsV4Header],
    query: List[GcsV4QueryParam],
) raises -> String:
    var stamps = gcs_v4_stamps_from_unix_seconds(_GATE_UNIX_SECONDS)
    return gcs_v4_build_canonical_request(
        method,
        authority,
        path,
        headers,
        query,
        "sa@p.iam.gserviceaccount.com",
        gcs_v4_credential_scope(stamps.short_date, "auto"),
        stamps.datetime_z,
        10,
    ).canonical_request


def _cr_raises(
    authority: String,
    method: String,
    path: String,
    headers: List[GcsV4Header],
    query: List[GcsV4QueryParam],
) -> Bool:
    try:
        _ = _cr_with(authority, method, path, headers, query)
    except:
        return True
    return False


def _authority_raises(authority: String) -> Bool:
    return _cr_raises(
        authority, "GET", "/b/o", List[GcsV4Header](), List[GcsV4QueryParam]()
    )


def _header_raises(name: String, value: String) -> Bool:
    var h = List[GcsV4Header]()
    h.append(GcsV4Header(name, value))
    return _cr_raises(
        "storage.googleapis.com", "GET", "/b/o", h, List[GcsV4QueryParam]()
    )


def _query_raises(name: String) -> Bool:
    var q = List[GcsV4QueryParam]()
    q.append(GcsV4QueryParam(name, "v"))
    return _cr_raises(
        "storage.googleapis.com", "GET", "/b/o", List[GcsV4Header](), q
    )


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
    assert_true(_header_raises("Host", "other.example"), "a host header")
    # An empty header name.
    assert_true(_header_raises("", "v"), "an empty header name")


def test_header_refusals() raises:
    # A name holding a space, tab, control byte or `:`; names are not
    # trimmed, so surrounding whitespace is refused too.
    assert_true(_header_raises(" ", "v"))
    assert_true(_header_raises(" x-a", "v"))
    assert_true(_header_raises("x-a ", "v"))
    assert_true(_header_raises("x a", "v"))
    assert_true(_header_raises("x\ta", "v"))
    assert_true(_header_raises("x:a", "v"))
    assert_true(_header_raises("x\na", "v"))
    # A value holding CR, LF, NUL or DEL; tab is allowed.
    assert_true(_header_raises("x-a", "1\nx-b:2"))
    assert_true(_header_raises("x-a", "1\r"))
    assert_true(_header_raises("x-a", "1\x002"))
    assert_true(_header_raises("x-a", "1\x7f"))
    assert_false(_header_raises("x-a", "1\t2"))
    # The refusal names the header, not the value.
    var msg = String()
    var h = List[GcsV4Header]()
    h.append(GcsV4Header("x-goog-encryption-key", "secret\nvalue"))
    try:
        _ = _cr("storage.googleapis.com", h)
    except e:
        msg = String(e)
    assert_true(msg.find("x-goog-encryption-key") >= 0, msg)
    assert_true(msg.find("secret") < 0, msg)

    # A second payload hash, in any case: the header block would carry
    # both values and the payload line one.
    var two = List[GcsV4Header]()
    two.append(GcsV4Header("x-goog-content-sha256", "aa"))
    two.append(GcsV4Header("X-Goog-Content-SHA256", "bb"))
    assert_true(
        _cr_raises(
            "storage.googleapis.com",
            "GET",
            "/b/o",
            two,
            List[GcsV4QueryParam](),
        ),
        "two payload hashes were signed",
    )


def test_non_ascii_header_value_is_kept_byte_for_byte() raises:
    var h = List[GcsV4Header]()
    h.append(GcsV4Header("x-goog-meta-name", "\tcafé  au  lait "))
    var cr = _cr("storage.googleapis.com", h)
    assert_true(cr.find("\nx-goog-meta-name:café au lait\n") > 0, cr)


def test_authority_port_is_not_signed() raises:
    # The vectors cover `host:port`; an IPv6 literal is bracketed and keeps
    # its brackets in the signed host.
    var cr = _cr("[::1]:9000", List[GcsV4Header]())
    assert_true(cr.find("\nhost:[::1]\n") > 0, cr)
    cr = _cr("[::1]", List[GcsV4Header]())
    assert_true(cr.find("\nhost:[::1]\n") > 0, cr)
    cr = _cr("h.example:8080", List[GcsV4Header]())
    assert_true(cr.find("\nhost:h.example\n") > 0, cr)


def test_authority_refusals() raises:
    assert_true(_authority_raises(""))
    assert_true(_authority_raises(" "))
    # Whitespace is refused, not trimmed: the URL carries the authority
    # as given, so a trimmed signed host would differ from it.
    assert_true(_authority_raises(" storage.googleapis.com"))
    assert_true(_authority_raises("storage.googleapis.com "))
    assert_true(_authority_raises("a b"))
    assert_true(_authority_raises("h\r"))
    # A path, query, fragment or userinfo is not an authority.
    assert_true(_authority_raises("h/x"))
    assert_true(_authority_raises("h?x"))
    assert_true(_authority_raises("h#x"))
    assert_true(_authority_raises("u@h"))
    assert_true(_authority_raises("h\\x"))
    # Ports.
    assert_true(_authority_raises("h:"))
    assert_true(_authority_raises("h:80x"))
    assert_true(_authority_raises(":80"))
    assert_true(_authority_raises("a:b:c"))
    assert_true(_authority_raises("::1"))
    # IPv6 brackets.
    assert_true(_authority_raises("[::1"))
    assert_true(_authority_raises("[]"))
    assert_true(_authority_raises("[::1]x"))
    assert_true(_authority_raises("[::1]:"))
    assert_false(_authority_raises("[::1]:443"))


def test_request_refusals() raises:
    var no_h = List[GcsV4Header]()
    var no_q = List[GcsV4QueryParam]()
    var host = "storage.googleapis.com"
    # A path that does not start with `/` would run into the authority.
    assert_true(_cr_raises(host, "GET", "b/o", no_h, no_q), "b/o was signed")
    assert_false(_cr_raises(host, "GET", "", no_h, no_q))
    # A method that is empty or not upper-case A-Z.
    assert_true(_cr_raises(host, "", "/b/o", no_h, no_q))
    assert_true(_cr_raises(host, "get", "/b/o", no_h, no_q))
    assert_true(_cr_raises(host, "GET ", "/b/o", no_h, no_q))
    assert_false(_cr_raises(host, "DELETE", "/b/o", no_h, no_q))
    # The six parameters the signer adds, in any case.
    assert_true(_query_raises("X-Goog-Algorithm"))
    assert_true(_query_raises("X-Goog-Credential"))
    assert_true(_query_raises("X-Goog-Date"))
    assert_true(_query_raises("X-Goog-Expires"))
    assert_true(_query_raises("X-Goog-SignedHeaders"))
    assert_true(_query_raises("X-Goog-Signature"))
    assert_true(_query_raises("x-goog-signature"))
    assert_true(_query_raises("X-GOOG-EXPIRES"))
    # Other X-Goog-* names are the caller's (vector "Query Parameter
    # Ordering" signs X-Goog-Meta-Foo).
    assert_false(_query_raises("X-Goog-Meta-Foo"))
    assert_false(_query_raises("X-Goog-Signatures"))
    # A location that is empty or holds `/` or whitespace.
    var raised = 0
    var bad = List[String]()
    bad.append("")
    bad.append("us/east1")
    bad.append("us east1")
    bad.append("auto\n")
    for i in range(len(bad)):
        try:
            _ = gcs_v4_credential_scope("20261001", bad[i])
        except:
            raised += 1
    assert_equal(raised, len(bad))
    assert_equal(
        gcs_v4_credential_scope("20261001", "us-east1"),
        "20261001/us-east1/storage/goog4_request",
    )


def _url_raises(
    account: GcsV4ServiceAccount, scheme: String, expires: Int
) raises -> Bool:
    try:
        _ = gcs_v4_signed_url(
            scheme,
            "GET",
            "storage.googleapis.com",
            "/b/o",
            List[GcsV4Header](),
            List[GcsV4QueryParam](),
            account,
            "auto",
            gcs_v4_stamps_from_unix_seconds(_GATE_UNIX_SECONDS),
            expires,
        )
    except:
        return True
    return False


def test_expiry_bounds_are_refused_not_clamped() raises:
    var account = _account()
    assert_true(_url_raises(account, "https", GCS_V4_MAX_EXPIRES_SECONDS + 1))
    assert_true(_url_raises(account, "https", 0))
    assert_true(_url_raises(account, "https", -1))
    assert_false(_url_raises(account, "https", GCS_V4_MAX_EXPIRES_SECONDS))
    assert_false(_url_raises(account, "https", 1))


def test_scheme_is_http_or_https() raises:
    var account = _account()
    assert_false(_url_raises(account, "http", 10))
    assert_true(_url_raises(account, "ftp", 10))
    assert_true(_url_raises(account, "", 10))
    assert_true(_url_raises(account, "HTTPS", 10))
    assert_true(_url_raises(account, "https://", 10))


def test_url_carries_the_signed_authority_and_instant() raises:
    var url = gcs_v4_signed_url(
        "http",
        "GET",
        "h.example:8080",
        "/b/o",
        List[GcsV4Header](),
        List[GcsV4QueryParam](),
        _account(),
        "auto",
        gcs_v4_stamps_from_unix_seconds(_GATE_UNIX_SECONDS),
        10,
    )
    assert_true(url.startswith("http://h.example:8080/b/o?"), url)
    assert_true(url.find("%2F20261001%2Fauto%2Fstorage%2Fgoog4_request&") > 0, url)
    assert_true(url.find("&X-Goog-Date=20261001T090000Z&") > 0, url)


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
            gcs_v4_stamps_from_unix_seconds(_GATE_UNIX_SECONDS),
            10,
        )
    except:
        raised = True
    assert_true(raised, "signed with no key")


def test_stamps_render_iso8601_basic() raises:
    var s = gcs_v4_stamps_from_unix_seconds(_GATE_UNIX_SECONDS)
    assert_equal(s.short_date, "20261001")
    assert_equal(s.datetime_z, "20261001T090000Z")
    assert_equal(s.unix_seconds, _GATE_UNIX_SECONDS)
    # A leap day, and the day after it.
    assert_equal(
        gcs_v4_stamps_from_unix_seconds(Int64(1835395200)).datetime_z,
        "20280229T000000Z",
    )
    assert_equal(
        gcs_v4_stamps_from_unix_seconds(Int64(1835481600)).short_date,
        "20280301",
    )
    # Floor division: the second before the epoch is the last second of
    # the day before it, not a negative time of day.
    var before = gcs_v4_stamps_from_unix_seconds(Int64(-1))
    var at = gcs_v4_stamps_from_unix_seconds(Int64(0))
    assert_true(before.datetime_z.endswith("T235959Z"), before.datetime_z)
    assert_true(at.datetime_z.endswith("T000000Z"), at.datetime_z)
    assert_true(before.short_date < at.short_date)
    # The four-digit year field, at both ends.
    assert_equal(
        gcs_v4_stamps_from_unix_seconds(Int64(253402300799)).datetime_z,
        "99991231T235959Z",
    )
    assert_true(
        gcs_v4_stamps_from_unix_seconds(Int64(-62167219200)).short_date.startswith(
            "0000"
        )
    )
    var raised = 0
    var out_of_range = List[Int64]()
    out_of_range.append(Int64(253402300800))
    out_of_range.append(Int64(-62167219201))
    for i in range(len(out_of_range)):
        try:
            _ = gcs_v4_stamps_from_unix_seconds(out_of_range[i])
        except:
            raised += 1
    assert_equal(raised, len(out_of_range), "a year outside 0000-9999")


def main() raises:
    test_every_published_vector()
    test_path_is_encoded_but_never_normalized()
    test_percent_encoding_is_unreserved_only()
    test_query_sorts_by_name_then_value()
    test_headers_join_duplicates_and_refuse_host()
    test_header_refusals()
    test_non_ascii_header_value_is_kept_byte_for_byte()
    test_authority_port_is_not_signed()
    test_authority_refusals()
    test_request_refusals()
    test_expiry_bounds_are_refused_not_clamped()
    test_scheme_is_http_or_https()
    test_url_carries_the_signed_authority_and_instant()
    test_signing_needs_a_key()
    test_stamps_render_iso8601_basic()
    print("all gcs v4 signing conformance tests passed")
