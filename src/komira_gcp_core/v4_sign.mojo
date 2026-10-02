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
# The URL authority may carry a port; the signed `host` header does not (the
# vectors that send to `localhost:8080` sign `host:localhost`). An input that
# would sign one request and send another is refused rather than signed: a
# control byte in a header, a path without a leading `/`, a caller's own
# X-Goog-* signing parameter, a second payload hash.
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
    the same instant it signed at.

    The one constructor renders both strings from the instant, so the date
    in the credential scope and X-Goog-Date cannot disagree."""

    var datetime_z: String
    var short_date: String
    var unix_seconds: Int64

    def __init__(out self, unix_seconds: Int64) raises:
        """The UTC stamps of `unix_seconds`, for a year in 0000-9999 (the
        four-digit field of the X-Goog-Date format); any other instant
        raises."""
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
        self.short_date = _pad(ymd[0], 4) + _pad(ymd[1], 2) + _pad(ymd[2], 2)
        self.datetime_z = (
            self.short_date
            + "T"
            + _pad(sod // 3600, 2)
            + _pad((sod % 3600) // 60, 2)
            + _pad(sod % 60, 2)
            + "Z"
        )
        self.unix_seconds = unix_seconds


# -----------------------------------------------------------------------------
# Bytes
# -----------------------------------------------------------------------------


def _is_ws(c: UInt8) -> Bool:
    return c == UInt8(0x20) or c == UInt8(0x09)


def _is_ctl(c: UInt8) -> Bool:
    """An ASCII control byte: 0x00-0x1F or DEL. Tab is one."""
    return c < UInt8(0x20) or c == UInt8(0x7F)


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(0x30) and c <= UInt8(0x39)


def _signed_host(authority: String) raises -> String:
    """The `host` header value signed for the URL authority `authority`:
    `authority` without its port.

    The vectors sign the host alone and keep the port in the URL: "Simple GET
    with non-default hostname" sends to `localhost:8080` and signs
    `host:localhost`, and "Simple GET with endpoint on client" sends to
    `storage.googleapis.com:443` and signs `host:storage.googleapis.com`.

    Refused: an empty authority or host; a space, tab or control byte; any of
    `/ ? # @ \\` (a path, query, fragment or userinfo is not an authority);
    a port that is empty or not all digits; an unbracketed second `:`; an
    unclosed `[` (an IPv6 literal is `[addr]` or `[addr]:port`)."""
    var b = authority.as_bytes()
    if len(b) == 0:
        raise Error("gcs v4: refusing to sign without a host")
    for i in range(len(b)):
        var c = b[i]
        if (
            _is_ws(c)
            or _is_ctl(c)
            or c == UInt8(0x2F)
            or c == UInt8(0x3F)
            or c == UInt8(0x23)
            or c == UInt8(0x40)
            or c == UInt8(0x5C)
        ):
            raise Error(
                "gcs v4: the host '"
                + authority
                + "' holds a byte an authority may not"
            )
    var host_end = len(b)
    if b[0] == UInt8(0x5B):
        var close = authority.find("]")
        if close < 2:
            raise Error(
                "gcs v4: an unclosed or empty '[' in the host '"
                + authority
                + "'"
            )
        host_end = close + 1
        if host_end < len(b) and b[host_end] != UInt8(0x3A):
            raise Error(
                "gcs v4: the host '" + authority + "' has bytes after ']'"
            )
    else:
        var colon = authority.find(":")
        if colon >= 0:
            if authority.find(":", colon + 1) >= 0:
                raise Error(
                    "gcs v4: the host '"
                    + authority
                    + "' has two ':' (an IPv6 address is bracketed)"
                )
            host_end = colon
    if host_end < len(b):
        # b[host_end] is ':'; the rest is the port.
        if host_end + 1 == len(b):
            raise Error("gcs v4: empty port in the host '" + authority + "'")
        for i in range(host_end + 1, len(b)):
            if not _is_digit(b[i]):
                raise Error(
                    "gcs v4: the port of '" + authority + "' is not a number"
                )
    if host_end == 0:
        raise Error("gcs v4: refusing to sign without a host")
    return String(authority[byte=0:host_end])


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


def gcs_v4_canonical_path(path: String) raises -> String:
    """`path` percent-encoded with `/` kept, and NOT normalized (difference 1
    above). An empty path is `/`; any other path must start with `/`, since
    the URL appends it to the authority as it is (`b/o` would sign one path
    and send to the host `<authority>b`)."""
    if path.byte_length() == 0:
        return String("/")
    if not path.startswith("/"):
        raise Error("gcs v4: the path '" + path + "' does not start with '/'")
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


def _check_header_name(name: String) raises:
    """A header name is a non-empty run of bytes with no space, tab, control
    byte or `:` (as given: it is not trimmed, so ` x` is refused)."""
    var b = name.as_bytes()
    if len(b) == 0:
        raise Error("gcs v4: refusing a header with an empty name")
    for i in range(len(b)):
        if _is_ws(b[i]) or _is_ctl(b[i]) or b[i] == UInt8(0x3A):
            raise Error(
                "gcs v4: the header name '"
                + name
                + "' holds a space, tab, control byte or ':'"
            )


def _check_header_value(name: String, value: String) raises:
    """A header value may hold any byte but a control byte other than tab: a
    CR or LF would put what reads as another header line into the canonical
    request. The value is not echoed (it may be a key)."""
    var b = value.as_bytes()
    for i in range(len(b)):
        if _is_ctl(b[i]) and b[i] != UInt8(0x09):
            raise Error(
                "gcs v4: the value of header '"
                + name
                + "' holds a control byte"
            )


def gcs_v4_canonical_headers(
    headers: List[GcsV4Header], authority: String
) raises -> GcsV4CanonicalHeaders:
    """Lowercase the names, trim and collapse the values, add `host`, sort
    by name (stably, so duplicates keep their order), and join duplicates
    with `,`.

    `host` is required by the specification and is synthesized here from
    the URL authority `authority` (`host` or `host:port`), without the port
    (`_signed_host`); a `host` header in `headers` is refused rather than
    joined into `host:a,b`, a well-formed request for a host that does not
    exist. The payload line is `UNSIGNED-PAYLOAD`, or the value of a signed
    `x-goog-content-sha256` header, which may appear once: a second would
    join into the header block while the payload line kept one value.

    Refused: a header name that is empty or holds a space, tab, control byte
    or `:`; a header value that holds a control byte other than tab."""
    var host_value = _signed_host(authority)

    var pairs = List[GcsV4Header](capacity=len(headers) + 1)
    var payload = String(GCS_V4_UNSIGNED_PAYLOAD)
    var payload_seen = False
    for i in range(len(headers)):
        _check_header_name(headers[i].name)
        var name = _ascii_lower(headers[i].name)
        if name == String("host"):
            raise Error(
                "gcs v4: 'host' is synthesized from the request host; a host"
                " header as well would sign two hosts"
            )
        _check_header_value(name, headers[i].value)
        var value = _collapse_inner_ws(_trim_ws(headers[i].value))
        if name == String(GCS_V4_CONTENT_SHA256_HEADER):
            if payload_seen:
                raise Error(
                    "gcs v4: a second 'x-goog-content-sha256' header; the"
                    " payload hash is one value"
                )
            payload_seen = True
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


def gcs_v4_credential_scope(
    short_date: String, location: String
) raises -> String:
    """`DATE/LOCATION/storage/goog4_request`.

    LOCATION is the bucket's region or `auto`. Every conformance vector uses
    `auto`, which Cloud Storage accepts for a bucket in any region. An empty
    LOCATION, or one holding `/`, a space, tab or control byte, is refused:
    each signs a scope with the wrong number of fields."""
    var b = location.as_bytes()
    if len(b) == 0:
        raise Error("gcs v4: refusing an empty location in the scope")
    for i in range(len(b)):
        if _is_ws(b[i]) or _is_ctl(b[i]) or b[i] == UInt8(0x2F):
            raise Error(
                "gcs v4: the location '"
                + location
                + "' holds '/', a space, tab or control byte"
            )
    return (
        short_date
        + "/"
        + location
        + "/"
        + String(GCS_V4_SERVICE)
        + "/"
        + String(GCS_V4_REQUEST_TYPE)
    )


def _is_reserved_query_name(name: String) -> Bool:
    """Whether `name` is, in any case, one of the six query parameters the
    signer adds; a caller's parameter of that name would be signed and sent
    twice."""
    var lower = _ascii_lower(name)
    return (
        lower == "x-goog-algorithm"
        or lower == "x-goog-credential"
        or lower == "x-goog-date"
        or lower == "x-goog-expires"
        or lower == "x-goog-signedheaders"
        or lower == "x-goog-signature"
    )


def _check_method(method: String) raises:
    """An HTTP method as Cloud Storage takes it: `A`-`Z` only (`GET`, `PUT`,
    `POST`, `DELETE`, `HEAD`). A lower-case method signs a request that no
    client sends."""
    var b = method.as_bytes()
    if len(b) == 0:
        raise Error("gcs v4: refusing an empty method")
    for i in range(len(b)):
        if b[i] < UInt8(0x41) or b[i] > UInt8(0x5A):
            raise Error(
                "gcs v4: the method '" + method + "' is not upper-case A-Z"
            )


def gcs_v4_build_canonical_request(
    method: String,
    authority: String,
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

    `authority` is the URL authority, `host` or `host:port`; the signed
    `host` header is the host without the port (`gcs_v4_canonical_headers`).
    The headers are canonicalized first, although they come later in the
    output: X-Goog-SignedHeaders is a query parameter whose value is their
    list.

    Refused: a method that is not `A`-`Z`; an `extra_query` name equal, in
    any case, to one of the six X-Goog-* parameters the signer adds."""
    _check_method(method)
    var ch = gcs_v4_canonical_headers(headers, authority)

    var q = List[GcsV4QueryParam](capacity=len(extra_query) + 5)
    for i in range(len(extra_query)):
        if _is_reserved_query_name(extra_query[i].name):
            raise Error(
                "gcs v4: the query parameter '"
                + extra_query[i].name
                + "' is added by the signer"
            )
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
    authority: String,
    path: String,
    headers: List[GcsV4Header],
    extra_query: List[GcsV4QueryParam],
    account: GcsV4ServiceAccount,
    location: String,
    stamps: GcsV4Stamps,
    expires_seconds: Int,
) raises -> String:
    """Canonicalize, sign, and assemble `scheme://authority/path?query&X-Goog-
    Signature=<hex>`.

    `authority` is `host` or `host:port` and goes into the URL as given; the
    signature covers the host without the port (`gcs_v4_canonical_headers`).
    The signing instant is `stamps` (`gcs_v4_stamps_from_unix_seconds`), the
    one source of both the scope's date and X-Goog-Date; nothing here reads a
    clock. The URL carries the signed canonical path and query verbatim, so
    the bytes Cloud Storage canonicalizes on receipt are the bytes that were
    signed.

    Refused: a scheme other than `http` or `https`; an expiry outside
    (0, GCS_V4_MAX_EXPIRES_SECONDS]; and whatever the canonical request and
    the credential scope refuse."""
    if scheme != "https" and scheme != "http":
        raise Error(
            "gcs v4: the scheme '" + scheme + "' is not 'https' or 'http'"
        )
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
    var scope = gcs_v4_credential_scope(stamps.short_date, location)
    var built = gcs_v4_build_canonical_request(
        method,
        authority,
        path,
        headers,
        extra_query,
        account.client_email,
        scope,
        stamps.datetime_z,
        expires_seconds,
    )
    var sts = gcs_v4_string_to_sign(
        built.canonical_request, stamps.datetime_z, scope
    )
    var sig = gcs_v4_sign_string_to_sign(sts, account.private_key_der)
    return (
        scheme
        + "://"
        + authority
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
    """Days since the Unix epoch to (year, month, day), proleptic Gregorian
    (H. Hinnant, "chrono-Compatible Low-Level Date Algorithms")."""
    var z = z_in + 719468
    # Mojo's `//` floors, so no truncation adjustment for a negative z.
    var era = z // 146097
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
    return GcsV4Stamps(unix_seconds)
