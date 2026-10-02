# =============================================================================
# komira_gcp_core/v4_sign.mojo -- Cloud Storage V4 signed URLs
#   (GOOG4-RSA-SHA256): canonicalization and signing.
# =============================================================================
#
# A V4 signed URL is an ordinary Cloud Storage URL with six query parameters
# appended, the last an RSA signature over a canonical form of the whole
# request. Whoever holds the URL may perform exactly the signed method on
# exactly the signed object until X-Goog-Date + X-Goog-Expires, with no Google
# credential of their own. Minting needs the service account's private key;
# using the URL needs nothing.
#
# This module is pure: no clock, no network, no environment. The signing
# instant is a parameter (`gcs_v4_stamps_from_unix_seconds` renders it), so
# every function here is deterministic and checked against Google's published
# conformance vectors (tests/test_v4_sign_conformance.mojo).
#
# -----------------------------------------------------------------------------
# Where this is NOT AWS SigV4
# -----------------------------------------------------------------------------
# The shape follows SigV4 (komira_aws_core/sigv4.mojo), and each of these
# four differences signs a URL that Cloud Storage refuses if carried over:
#
#   1. The path is NOT normalized. SigV4's canonical URI collapses `//` and
#      resolves `.` and `..` (RFC 3986 section 5.2.4) for every service but
#      S3; GCS does none of it. Vector "Forward Slashes should not be
#      stripped" expects `/test-bucket//path/with/slashes/...`.
#      `gcs_v4_canonical_path` percent-encodes and does nothing else.
#
#   2. The query sorts by (name, value) as two fields. Google's text says
#      "sorted by name using a lexicographical sort by code point value";
#      sorting the joined `name=value` strings puts `a0=y` before `a=x`
#      (`=` is 0x3D, the digits 0x30-0x39).
#
#   3. The payload line is `UNSIGNED-PAYLOAD`, unless the caller signs an
#      `x-goog-content-sha256` header, whose value is then the payload line
#      (vector "Signed Payload Instead of UNSIGNED-PAYLOAD").
#
#   4. The signature is RSASSA-PKCS1-v1_5 over SHA-256 of the string to
#      sign, hex-lowercase: no derived-key chain and nothing to cache. The
#      conformance vectors' signatures over their dummy key fix both the
#      padding (PKCS#1 v1.5, not PSS, which is randomized) and the encoding.
#
# Header canonicalization (lowercase names, trimmed values with inner runs of
# space and tab collapsed, sorted, duplicates joined with `,`), the blank line
# after the header block and the `;`-joined signed-header list match SigV4.
#
# Specification:
#   canonical request  https://cloud.google.com/storage/docs/authentication/canonical-requests
#   string to sign     https://cloud.google.com/storage/docs/authentication/signatures
#   signed URLs        https://cloud.google.com/storage/docs/access-control/signed-urls
#   vectors            https://github.com/googleapis/conformance-tests
#                      storage/v1/v4_signatures.json
#
# The private key is PKCS#8 DER (pem.mojo decodes a key file's PEM). It is
# passed to the RSA call and nowhere else: never into a URL, an error message
# or a log line.
# =============================================================================

from komira_crypto import (
    hex_lower,
    hex_lower_array_32,
    rsa_sha256_sign,
    sha256_string,
)

from komira_gcp_core._text import _from_utf8_bytes, _percent_encode


# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

comptime GCS_V4_ALGORITHM: StaticString = "GOOG4-RSA-SHA256"
"""The one algorithm signed here. `GOOG4-HMAC-SHA256` (HMAC keys) is not
implemented."""

comptime GCS_V4_REQUEST_TYPE: StaticString = "goog4_request"
comptime GCS_V4_SERVICE: StaticString = "storage"
comptime GCS_V4_UNSIGNED_PAYLOAD: StaticString = "UNSIGNED-PAYLOAD"
comptime GCS_V4_CONTENT_SHA256_HEADER: StaticString = "x-goog-content-sha256"
comptime GCS_V4_DEFAULT_HOST: StaticString = "storage.googleapis.com"

comptime GCS_V4_MAX_EXPIRES_SECONDS: Int = 604800
"""Google's ceiling: "The longest expiration value is 604800 seconds (7
days)" (the canonical-requests page). `gcs_v4_signed_url` refuses anything
above it as a specification check. A caller's own, lower policy limit is the
caller's to enforce."""


# -----------------------------------------------------------------------------
# Value types
# -----------------------------------------------------------------------------


@fieldwise_init
struct GcsV4Header(ImplicitlyCopyable, Copyable, Movable, Deinitable):
    """A header the signature covers. `host` is synthesized from the request
    host and is refused here."""

    var name: String
    var value: String


@fieldwise_init
struct GcsV4QueryParam(ImplicitlyCopyable, Copyable, Movable, Deinitable):
    """A query parameter the signature covers, RAW (not percent-encoded): the
    builder encodes it, so an encoded value is encoded twice."""

    var name: String
    var value: String


struct GcsV4CanonicalRequest(Copyable, Movable, Deinitable):
    """The canonical request, and the canonical query and signed-header list
    it holds.

    The URL carries `canonical_query` verbatim: building the query a second
    time at URL assembly is how a signer signs one string and sends another."""

    var canonical_request: String
    var canonical_query: String
    var signed_headers: String

    def __init__(
        out self,
        var canonical_request: String,
        var canonical_query: String,
        var signed_headers: String,
    ):
        self.canonical_request = canonical_request^
        self.canonical_query = canonical_query^
        self.signed_headers = signed_headers^


struct GcsV4ServiceAccount(Copyable, Movable, Deinitable):
    """The signing identity: the service account's email and its PKCS#8 DER
    private key.

    `client_email` is the authorizer half of X-Goog-Credential and appears in
    every URL; `private_key_der` is the secret and reaches only the RSA call."""

    var client_email: String
    var private_key_der: List[UInt8]

    def __init__(
        out self, var client_email: String, var private_key_der: List[UInt8]
    ):
        self.client_email = client_email^
        self.private_key_der = private_key_der^


struct GcsV4CanonicalHeaders(Copyable, Movable, Deinitable):
    """The `name:value\\n` block, the `;`-joined signed-header list, and the
    payload line the headers imply."""

    var block: String
    var signed_list: String
    var payload_line: String

    def __init__(
        out self,
        var block: String,
        var signed_list: String,
        var payload_line: String,
    ):
        self.block = block^
        self.signed_list = signed_list^
        self.payload_line = payload_line^


struct GcsV4Stamps(ImplicitlyCopyable, Copyable, Movable, Deinitable):
    """`datetime_z` (`YYYYMMDDTHHMMSSZ`), `short_date` (`YYYYMMDD`), and the
    unix seconds both were rendered from, so a caller reports the expiry from
    the same instant it signed at."""

    var datetime_z: String
    var short_date: String
    var unix_seconds: Int64

    def __init__(
        out self,
        var datetime_z: String,
        var short_date: String,
        unix_seconds: Int64,
    ):
        self.datetime_z = datetime_z^
        self.short_date = short_date^
        self.unix_seconds = unix_seconds


# -----------------------------------------------------------------------------
# Bytes
# -----------------------------------------------------------------------------


def _is_ws(c: UInt8) -> Bool:
    return c == UInt8(0x20) or c == UInt8(0x09)


def _ascii_lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(0x41) and c <= UInt8(0x5A):
            c += 0x20
        out.append(c)
    return _from_utf8_bytes(out)


def _trim_ws(s: String) -> String:
    """`s` without leading and trailing spaces and tabs."""
    var b = s.as_bytes()
    var i = 0
    var j = len(b)
    while i < j and _is_ws(b[i]):
        i += 1
    while j > i and _is_ws(b[j - 1]):
        j -= 1
    var out = List[UInt8](capacity=j - i)
    for k in range(i, j):
        out.append(b[k])
    return _from_utf8_bytes(out)


def _collapse_inner_ws(s: String) -> String:
    """Every run of spaces and tabs as one space.

    Unconditional, with no regard to quoting or commas: vector "Header value
    with multiple inline values" sends `' xyz ,  abc, def  , xyz   '` and
    expects `xyz , abc, def , xyz`."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var prev_ws = False
    for i in range(len(b)):
        var c = b[i]
        if _is_ws(c):
            if not prev_ws:
                out.append(UInt8(0x20))
            prev_ws = True
        else:
            out.append(c)
            prev_ws = False
    return _from_utf8_bytes(out)


# -----------------------------------------------------------------------------
# Canonical path (line 2)
# -----------------------------------------------------------------------------
#
# The encode set comes from the vectors, not from the prose. The
# canonical-requests page lists a reserved set to encode, which would leave
# a space and `%` alone; vector "Query Parameter Encoding" sends
# `~ ._-%=/é0Aa` and expects `~%20._-%25%3D%2F%C3%A90Aa`: everything outside
# the RFC 3986 unreserved set is encoded, octet by octet of the UTF-8
# (`_text._percent_encode`, the package's one encoder).


def gcs_v4_canonical_path(path: String) -> String:
    """`path` percent-encoded with `/` kept, and NOT normalized (difference 1
    above). An empty path is `/`."""
    if path.byte_length() == 0:
        return String("/")
    return _percent_encode(path, keep_slash=True)


# -----------------------------------------------------------------------------
# Canonical query (line 3)
# -----------------------------------------------------------------------------


def _query_less(a: GcsV4QueryParam, b: GcsV4QueryParam) -> Bool:
    """By name, then by value (difference 2 above). Both are percent-encoded
    ASCII, so String order is code point order."""
    if a.name != b.name:
        return a.name < b.name
    return a.value < b.value


def _sort_query(mut params: List[GcsV4QueryParam]):
    """A stable insertion sort; a request has a handful of parameters."""
    for i in range(1, len(params)):
        var key = params[i]
        var j = i - 1
        while j >= 0 and _query_less(key, params[j]):
            params[j + 1] = params[j]
            j -= 1
        params[j + 1] = key


def gcs_v4_canonical_query(params: List[GcsV4QueryParam]) -> String:
    """Every name and value percent-encoded (`/` too), sorted by (name,
    value), joined `name=value` with `&`. No parameters is the empty string,
    which the specification makes the whole third line."""
    var encoded = List[GcsV4QueryParam](capacity=len(params))
    for i in range(len(params)):
        encoded.append(
            GcsV4QueryParam(
                _percent_encode(params[i].name, keep_slash=False),
                _percent_encode(params[i].value, keep_slash=False),
            )
        )
    _sort_query(encoded)
    var out = String()
    for i in range(len(encoded)):
        if i > 0:
            out += "&"
        out += encoded[i].name
        out += "="
        out += encoded[i].value
    return out^


# -----------------------------------------------------------------------------
# Canonical headers and the signed-header list
# -----------------------------------------------------------------------------


def gcs_v4_canonical_headers(
    headers: List[GcsV4Header], host: String
) raises -> GcsV4CanonicalHeaders:
    """Lowercase the names, trim and collapse the values, add `host`, sort
    by name (stably, so duplicates keep their order), and join duplicates
    with `,`.

    `host` is required by the specification and is synthesized from `host`
    here; a `host` header in `headers` is refused rather than joined into
    `host:a,b`, a well-formed request for a host that does not exist. The
    payload line is `UNSIGNED-PAYLOAD`, or the value of a signed
    `x-goog-content-sha256` header."""
    var host_value = _trim_ws(host)
    if host_value.byte_length() == 0:
        raise Error("gcs v4: refusing to sign without a host")

    var pairs = List[GcsV4Header](capacity=len(headers) + 1)
    var payload = String(GCS_V4_UNSIGNED_PAYLOAD)
    for i in range(len(headers)):
        var name = _ascii_lower(_trim_ws(headers[i].name))
        if name.byte_length() == 0:
            raise Error("gcs v4: refusing a header with an empty name")
        if name == String("host"):
            raise Error(
                "gcs v4: 'host' is synthesized from the request host; a host"
                " header as well would sign two hosts"
            )
        var value = _collapse_inner_ws(_trim_ws(headers[i].value))
        if name == String(GCS_V4_CONTENT_SHA256_HEADER):
            payload = value
        pairs.append(GcsV4Header(name^, value^))
    pairs.append(GcsV4Header(String("host"), host_value^))

    for i in range(1, len(pairs)):
        var key = pairs[i]
        var j = i - 1
        while j >= 0 and key.name < pairs[j].name:
            pairs[j + 1] = pairs[j]
            j -= 1
        pairs[j + 1] = key

    var block = String()
    var signed = String()
    var k = 0
    while k < len(pairs):
        var name = pairs[k].name
        var joined = pairs[k].value
        var m = k + 1
        while m < len(pairs) and pairs[m].name == name:
            joined += ","
            joined += pairs[m].value
            m += 1
        block += name
        block += ":"
        block += joined
        block += "\n"
        if k > 0:
            signed += ";"
        signed += name
        k = m
    return GcsV4CanonicalHeaders(block^, signed^, payload^)


# -----------------------------------------------------------------------------
# Credential scope, canonical request, string to sign
# -----------------------------------------------------------------------------


def gcs_v4_credential_scope(short_date: String, location: String) -> String:
    """`DATE/LOCATION/storage/goog4_request`.

    LOCATION is the bucket's region or `auto`. Every conformance vector uses
    `auto`, which Cloud Storage accepts for a bucket in any region."""
    return (
        short_date
        + "/"
        + location
        + "/"
        + String(GCS_V4_SERVICE)
        + "/"
        + String(GCS_V4_REQUEST_TYPE)
    )


def gcs_v4_build_canonical_request(
    method: String,
    host: String,
    path: String,
    headers: List[GcsV4Header],
    extra_query: List[GcsV4QueryParam],
    authorizer: String,
    credential_scope: String,
    datetime_z: String,
    expires_seconds: Int,
) raises -> GcsV4CanonicalRequest:
    """The canonical request, with the five required X-Goog-* parameters
    added to the caller's query:

        METHOD \\n PATH \\n QUERY \\n HEADERS \\n (blank) \\n SIGNED_HEADERS
        \\n PAYLOAD

    The headers are canonicalized first, although they come later in the
    output: X-Goog-SignedHeaders is a query parameter whose value is their
    list."""
    var ch = gcs_v4_canonical_headers(headers, host)

    var q = List[GcsV4QueryParam](capacity=len(extra_query) + 5)
    for i in range(len(extra_query)):
        q.append(extra_query[i])
    q.append(GcsV4QueryParam("X-Goog-Algorithm", String(GCS_V4_ALGORITHM)))
    q.append(
        GcsV4QueryParam("X-Goog-Credential", authorizer + "/" + credential_scope)
    )
    q.append(GcsV4QueryParam("X-Goog-Date", datetime_z))
    q.append(GcsV4QueryParam("X-Goog-Expires", String(expires_seconds)))
    q.append(GcsV4QueryParam("X-Goog-SignedHeaders", ch.signed_list))
    var cq = gcs_v4_canonical_query(q)

    var cr = String()
    cr += method
    cr += "\n"
    cr += gcs_v4_canonical_path(path)
    cr += "\n"
    cr += cq
    cr += "\n"
    cr += ch.block
    cr += "\n"
    cr += ch.signed_list
    cr += "\n"
    cr += ch.payload_line
    return GcsV4CanonicalRequest(cr^, cq^, ch.signed_list)


def gcs_v4_string_to_sign(
    canonical_request: String, datetime_z: String, credential_scope: String
) -> String:
    """`GOOG4-RSA-SHA256 \\n DATETIME \\n SCOPE \\n hex(sha256(request))`."""
    var sts = String(GCS_V4_ALGORITHM)
    sts += "\n"
    sts += datetime_z
    sts += "\n"
    sts += credential_scope
    sts += "\n"
    sts += hex_lower_array_32(sha256_string(canonical_request))
    return sts^


# -----------------------------------------------------------------------------
# The signature and the URL
# -----------------------------------------------------------------------------


def gcs_v4_sign_string_to_sign(
    string_to_sign: String, private_key_der: List[UInt8]
) raises -> String:
    """RSASSA-PKCS1-v1_5 over SHA-256 of `string_to_sign` with the PKCS#8
    DER key, hex-lowercase. A malformed key raises from the RSA call; no
    message carries a key byte."""
    if len(private_key_der) == 0:
        raise Error("gcs v4: no private key")
    var sig = rsa_sha256_sign(Span(private_key_der), string_to_sign.as_bytes())
    return hex_lower(Span(sig))


def gcs_v4_signed_url(
    scheme: String,
    method: String,
    host: String,
    path: String,
    headers: List[GcsV4Header],
    extra_query: List[GcsV4QueryParam],
    account: GcsV4ServiceAccount,
    location: String,
    short_date: String,
    datetime_z: String,
    expires_seconds: Int,
) raises -> String:
    """Canonicalize, sign, and assemble `scheme://host/path?query&X-Goog-
    Signature=<hex>`.

    The signing instant is `short_date` and `datetime_z`
    (`gcs_v4_stamps_from_unix_seconds`); nothing here reads a clock. The URL
    carries the signed canonical query verbatim, so the bytes Cloud Storage
    canonicalizes on receipt are the bytes that were signed. Expiry must be
    in (0, GCS_V4_MAX_EXPIRES_SECONDS]."""
    if expires_seconds <= 0:
        raise Error(
            "gcs v4: refusing a non-positive X-Goog-Expires ("
            + String(expires_seconds)
            + ")"
        )
    if expires_seconds > GCS_V4_MAX_EXPIRES_SECONDS:
        raise Error(
            "gcs v4: X-Goog-Expires "
            + String(expires_seconds)
            + "s exceeds Google's maximum of "
            + String(GCS_V4_MAX_EXPIRES_SECONDS)
            + "s (7 days)"
        )
    var scope = gcs_v4_credential_scope(short_date, location)
    var built = gcs_v4_build_canonical_request(
        method,
        host,
        path,
        headers,
        extra_query,
        account.client_email,
        scope,
        datetime_z,
        expires_seconds,
    )
    var sts = gcs_v4_string_to_sign(built.canonical_request, datetime_z, scope)
    var sig = gcs_v4_sign_string_to_sign(sts, account.private_key_der)
    return (
        scheme
        + "://"
        + host
        + gcs_v4_canonical_path(path)
        + "?"
        + built.canonical_query
        + "&X-Goog-Signature="
        + sig
    )


# -----------------------------------------------------------------------------
# Time stamps
# -----------------------------------------------------------------------------


def _civil_from_days(z_in: Int) -> Tuple[Int, Int, Int]:
    """Days since 1970-01-01 to (year, month, day), proleptic Gregorian
    (H. Hinnant, "chrono-Compatible Low-Level Date Algorithms")."""
    var z = z_in + 719468
    var era = (z if z >= 0 else z - 146096) // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + 3 if mp < 10 else mp - 9
    var year = y + 1 if m <= 2 else y
    return Tuple[Int, Int, Int](year, m, d)


def _pad(v: Int, width: Int) -> String:
    var s = String(v)
    var out = String()
    for _ in range(width - s.byte_length()):
        out += "0"
    out += s
    return out^


def gcs_v4_stamps_from_unix_seconds(unix_seconds: Int64) raises -> GcsV4Stamps:
    """The UTC stamps of an instant, for a year in 0000-9999 (the four-digit
    field of the X-Goog-Date format); any other instant raises."""
    var total = Int(unix_seconds)
    # Floor division, so an instant before 1970 lands on the right day.
    var days = total // 86400
    var sod = total - days * 86400
    var ymd = _civil_from_days(days)
    if ymd[0] < 0 or ymd[0] > 9999:
        raise Error(
            "gcs v4: unix time "
            + String(unix_seconds)
            + " is outside years 0000-9999"
        )
    var short_date = _pad(ymd[0], 4) + _pad(ymd[1], 2) + _pad(ymd[2], 2)
    var dtz = (
        short_date
        + "T"
        + _pad(sod // 3600, 2)
        + _pad((sod % 3600) // 60, 2)
        + _pad(sod % 60, 2)
        + "Z"
    )
    return GcsV4Stamps(dtz^, short_date^, unix_seconds)
