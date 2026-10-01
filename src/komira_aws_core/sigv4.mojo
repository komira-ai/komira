# =============================================================================
# komira_aws_core/sigv4.mojo -- AWS Signature Version 4
# =============================================================================
#
# Signs a request with AWS SigV4, either in its headers (`sigv4_sign*`, the
# Authorization header) or in its query string (`sigv4_presign`, a presigned
# URL):
#
#   1. Canonical request:
#        METHOD \n CanonicalURI \n CanonicalQuery \n
#        CanonicalHeaders \n SignedHeaders \n HashedPayload
#   2. String to sign:
#        AWS4-HMAC-SHA256 \n amz_date \n scope \n hex(SHA256(canonical request))
#      where scope = short_date/region/service/aws4_request
#   3. Signing key: HMAC-SHA256 chain "AWS4"+secret -> date -> region ->
#      service -> "aws4_request"
#   4. Signature: hex(HMAC-SHA256(signing key, string to sign))
#
# It is pure computation: no clock, no network, no environment. The caller
# supplies the signing time (`amz_date`) and the credential, so a test signs
# with a fixed clock. Every case of the official AWS SigV4 signing test suite
# (read from the aws-c-auth archive //third_party/aws_c_auth pins) is checked
# byte for byte by tests/test_sigv4_test_suite.mojo, in both header and query
# signing.
#
# The signer owns the headers and query parameters it writes: a request that
# already carries one (Authorization, X-Amz-Date, X-Amz-Security-Token,
# x-amz-content-sha256, or an X-Amz-* presign parameter) is refused rather than
# signed with two values. A request with no Host header is refused: the host
# is signed, and it is never guessed. A header name or value holding CR or LF
# is refused.
#
# Errors never carry the secret access key, the session token or a key.
# =============================================================================

from komira_crypto import (
    hex_lower_array_32,
    hmac_sha256,
    hmac_sha256_string,
    sha256,
    zeroize_inline_array,
)

from .credential import AwsCredential


comptime SIGV4_ALGORITHM: StaticString = "AWS4-HMAC-SHA256"

# SHA-256 of the empty payload: the payload hash of a request with no body.
comptime EMPTY_PAYLOAD_SHA256: StaticString = (
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
)

# The payload hash S3 accepts in place of a digest.
comptime UNSIGNED_PAYLOAD: StaticString = "UNSIGNED-PAYLOAD"

# The longest validity AWS accepts for a presigned URL: seven days.
comptime MAX_PRESIGN_EXPIRES_SECONDS = 604800

comptime _SLASH = UInt8(0x2F)
comptime _DOT = UInt8(0x2E)
comptime _SP = UInt8(0x20)
comptime _HT = UInt8(0x09)
comptime _CR = UInt8(0x0D)
comptime _LF = UInt8(0x0A)
comptime _PERCENT = UInt8(0x25)
comptime _AMP = UInt8(0x26)
comptime _EQ = UInt8(0x3D)


@fieldwise_init
struct Header(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One HTTP header (or, in a presign result, one query parameter)."""

    var name: String
    var value: String


struct SigV4SigningContext(Copyable, Movable, Deinitable):
    """Everything about one signature that is not the request itself.

    - `cred`: the credential to sign with.
    - `region`, `service`: the credential scope, e.g. "us-east-1", "logs".
    - `amz_date`: the signing time, "YYYYMMDDTHHMMSSZ" in UTC. Supplied by the
      caller's clock; a test passes a fixed one.
    - `sign_payload_header`: add and sign `x-amz-content-sha256` (S3 needs it;
      most other services do not). Header signing only.
    - `normalize_path`: remove `.`/`..` segments and repeated slashes from the
      path before encoding it. True for every service but S3.
    - `uri_encode_path`: percent-encode the path as given, so a path already
      encoded on the wire is encoded twice. True for every service but S3,
      whose canonical path is the wire path as is.
    - `omit_session_token`: add the session token to the request but leave it
      out of the signature (services that sign before the token is attached).
    """

    var cred: AwsCredential
    var region: String
    var service: String
    var amz_date: String
    var sign_payload_header: Bool
    var normalize_path: Bool
    var uri_encode_path: Bool
    var omit_session_token: Bool

    def __init__(
        out self,
        cred: AwsCredential,
        region: String,
        service: String,
        amz_date: String,
        *,
        sign_payload_header: Bool = False,
        normalize_path: Bool = True,
        uri_encode_path: Bool = True,
        omit_session_token: Bool = False,
    ):
        self.cred = cred
        self.region = region
        self.service = service
        self.amz_date = amz_date
        self.sign_payload_header = sign_payload_header
        self.normalize_path = normalize_path
        self.uri_encode_path = uri_encode_path
        self.omit_session_token = omit_session_token

    def short_date(self) raises -> String:
        """The date half of `amz_date`, "YYYYMMDD". Raises unless `amz_date`
        is the 16 ASCII bytes "YYYYMMDDTHHMMSSZ", so the cut at byte 8 is at
        an ASCII byte and the date is a real one, not a prefix of garbage."""
        _check_amz_date(self.amz_date)
        return _sub(self.amz_date, 0, 8)

    def credential_scope(self) raises -> String:
        """short_date/region/service/aws4_request."""
        return (
            self.short_date()
            + "/"
            + self.region
            + "/"
            + self.service
            + "/aws4_request"
        )

    def signs_session_token(self) -> Bool:
        return self.cred.has_session_token() and not self.omit_session_token

    def validate(self) raises:
        """Refuses a context that would sign a malformed scope."""
        _check_amz_date(self.amz_date)
        _check_scope_part("access key id", self.cred.access_key_id)
        _check_scope_part("region", self.region)
        _check_scope_part("service", self.service)
        if self.cred.secret_access_key.byte_length() == 0:
            raise Error("SigV4: the credential has an empty secret access key")
        _check_no_crlf("session token", self.cred.session_token)


@fieldwise_init
struct SigV4Result(Copyable, Movable, Deinitable):
    """A header signature.

    `headers_to_add` is what the caller attaches to the request, in order:
    X-Amz-Date, x-amz-content-sha256 (when `sign_payload_header`),
    X-Amz-Security-Token (when the credential has one, signed or not), and
    Authorization. The other fields are the intermediate values, for tests and
    diagnostics.
    """

    var canonical_request: String
    var string_to_sign: String
    var signature: String
    var signed_headers: String
    var authorization: String
    var headers_to_add: List[Header]


@fieldwise_init
struct SigV4PresignResult(Copyable, Movable, Deinitable):
    """A query-string signature (presigned URL).

    `query_to_add` holds the parameters the signer appends, raw (not
    percent-encoded), in order: X-Amz-Algorithm, X-Amz-Credential,
    X-Amz-Date, X-Amz-SignedHeaders, X-Amz-Expires, X-Amz-Security-Token (when
    the credential has one), X-Amz-Signature. `signed_target` is the request
    target with them appended, encoded.
    """

    var canonical_request: String
    var string_to_sign: String
    var signature: String
    var signed_headers: String
    var query_to_add: List[Header]
    var signed_target: String


# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------


def _is_digit(c: UInt8) -> Bool:
    return c >= UInt8(0x30) and c <= UInt8(0x39)


def _check_amz_date(d: String) raises:
    var b = d.as_bytes()
    var ok = len(b) == 16 and b[8] == UInt8(0x54) and b[15] == UInt8(0x5A)
    if ok:
        for i in range(15):
            if i != 8 and not _is_digit(b[i]):
                ok = False
    if not ok:
        raise Error(
            "SigV4: amz_date must be YYYYMMDDTHHMMSSZ (UTC), got '"
            + d
            + "'"
        )


def _check_scope_part(what: String, s: String) raises:
    """A credential-scope component: non-empty printable ASCII with no '/',
    ',', '=' or space, so it cannot change the scope's shape."""
    var b = s.as_bytes()
    if len(b) == 0:
        raise Error("SigV4: the " + what + " is empty")
    for i in range(len(b)):
        var c = b[i]
        if (
            c <= _SP
            or c >= UInt8(0x7F)
            or c == _SLASH
            or c == UInt8(0x2C)
            or c == _EQ
        ):
            raise Error(
                "SigV4: the "
                + what
                + " holds a byte that is not allowed in a credential scope"
            )


def _check_no_crlf(what: String, s: String) raises:
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] == _CR or b[i] == _LF:
            raise Error("SigV4: the " + what + " holds CR or LF")


def _check_token(what: String, s: String) raises:
    """Non-empty, no whitespace and no control byte (method, payload hash)."""
    var b = s.as_bytes()
    if len(b) == 0:
        raise Error("SigV4: the " + what + " is empty")
    for i in range(len(b)):
        if b[i] <= _SP or b[i] == UInt8(0x7F):
            raise Error("SigV4: the " + what + " holds whitespace or a control byte")


# -----------------------------------------------------------------------------
# Byte helpers
# -----------------------------------------------------------------------------


def _sub(s: String, i: Int, j: Int) -> String:
    """Bytes [i, j) of `s`. Callers cut only at ASCII bytes."""
    var b = s.as_bytes()
    var lo = max(0, min(i, len(b)))
    var hi = max(lo, min(j, len(b)))
    return String(StringSlice(unsafe_from_utf8=b[lo:hi]))


def _from_bytes(b: List[UInt8]) -> String:
    """A String from bytes that are valid UTF-8 by construction (ASCII output
    of the encoder, or input bytes cut only at ASCII bytes)."""
    return String(unsafe_from_utf8=Span(b))


def _ascii_lower(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= UInt8(0x41) and c <= UInt8(0x5A):
            c += 0x20
        out.append(c)
    return _from_bytes(out)


def _is_unreserved(c: UInt8) -> Bool:
    """RFC 3986 unreserved: ALPHA / DIGIT / '-' / '.' / '_' / '~'."""
    return (
        (c >= UInt8(0x41) and c <= UInt8(0x5A))
        or (c >= UInt8(0x61) and c <= UInt8(0x7A))
        or _is_digit(c)
        or c == UInt8(0x2D)
        or c == _DOT
        or c == UInt8(0x5F)
        or c == UInt8(0x7E)
    )


def _hex_upper(v: UInt8) -> UInt8:
    return v + 0x30 if v < 10 else v - 10 + 0x41


def _append_encoded(mut out: List[UInt8], b: Span[UInt8, _], keep_slash: Bool):
    """Percent-encodes every byte but the unreserved set (and '/' when
    `keep_slash`), with uppercase hex, as SigV4 requires."""
    for i in range(len(b)):
        var c = b[i]
        if _is_unreserved(c) or (keep_slash and c == _SLASH):
            out.append(c)
        else:
            out.append(_PERCENT)
            out.append(_hex_upper(c >> 4))
            out.append(_hex_upper(c & 0x0F))


def uri_encode(s: String, keep_slash: Bool = False) -> String:
    """SigV4 percent-encoding of `s` (uppercase hex; '/' kept only when
    `keep_slash`)."""
    var out = List[UInt8]()
    _append_encoded(out, s.as_bytes(), keep_slash)
    return _from_bytes(out)


def _hex_value(c: UInt8) -> Int:
    if _is_digit(c):
        return Int(c) - 0x30
    if c >= UInt8(0x41) and c <= UInt8(0x46):
        return Int(c) - 0x41 + 10
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return Int(c) - 0x61 + 10
    return -1


def _decode_into(mut out: List[UInt8], b: Span[UInt8, _]):
    """Percent-decodes; a '%' not followed by two hex digits stays as is."""
    var i = 0
    var n = len(b)
    while i < n:
        if b[i] == _PERCENT and i + 2 < n:
            var hi = _hex_value(b[i + 1])
            var lo = _hex_value(b[i + 2])
            if hi >= 0 and lo >= 0:
                out.append(UInt8(hi * 16 + lo))
                i += 3
                continue
        out.append(b[i])
        i += 1


# -----------------------------------------------------------------------------
# Canonical URI and query
# -----------------------------------------------------------------------------


def _split_target(target: String) -> Tuple[String, String]:
    """(path, query) of a request target; the query excludes the '?'."""
    var q = target.find("?")
    if q < 0:
        return (target, String(""))
    return (_sub(target, 0, q), _sub(target, q + 1, target.byte_length()))


def _normalize_path(path: Span[UInt8, _]) -> List[UInt8]:
    """RFC 3986 remove_dot_segments, with runs of '/' collapsed. The result
    starts with '/' and ends with one when the input names a directory."""
    var starts = List[Int]()
    var ends = List[Int]()
    var n = len(path)
    var i = 0
    var last_was_dot = False
    while i < n:
        while i < n and path[i] == _SLASH:
            i += 1
        var s = i
        while i < n and path[i] != _SLASH:
            i += 1
        if i == s:
            continue
        var ln = i - s
        if ln == 1 and path[s] == _DOT:
            last_was_dot = True
        elif ln == 2 and path[s] == _DOT and path[s + 1] == _DOT:
            if len(starts) > 0:
                _ = starts.pop()
                _ = ends.pop()
            last_was_dot = True
        else:
            starts.append(s)
            ends.append(i)
            last_was_dot = False
    var trailing = (n > 0 and path[n - 1] == _SLASH) or last_was_dot
    var out = List[UInt8]()
    out.append(_SLASH)
    for k in range(len(starts)):
        if k > 0:
            out.append(_SLASH)
        for j in range(starts[k], ends[k]):
            out.append(path[j])
    if trailing and len(starts) > 0:
        out.append(_SLASH)
    return out^


def canonical_uri(
    path: String, normalize: Bool = True, uri_encode_path: Bool = True
) -> String:
    """The CanonicalURI line for `path` (no query). See SigV4SigningContext
    for the two flags; S3 passes False for both."""
    var bytes = List[UInt8]()
    if normalize:
        bytes = _normalize_path(path.as_bytes())
    else:
        var b = path.as_bytes()
        for i in range(len(b)):
            bytes.append(b[i])
    if len(bytes) == 0:
        return String("/")
    if not uri_encode_path:
        return _from_bytes(bytes)
    var out = List[UInt8]()
    _append_encoded(out, Span(bytes), keep_slash=True)
    return _from_bytes(out)


def _query_pairs(query: String) -> List[Header]:
    """The query's parameters, percent-decoded then re-encoded the SigV4 way,
    so a parameter is canonical whether it arrived encoded or raw. A
    parameter without '=' has an empty value; empty parameters are dropped."""
    var out = List[Header]()
    var b = query.as_bytes()
    var n = len(b)
    var i = 0
    while i <= n:
        var s = i
        while i < n and b[i] != _AMP:
            i += 1
        if i > s:
            var eq = s
            while eq < i and b[eq] != _EQ:
                eq += 1
            var key = List[UInt8]()
            _decode_into(key, b[s:eq])
            var val = List[UInt8]()
            if eq < i:
                _decode_into(val, b[eq + 1 : i])
            var ek = List[UInt8]()
            _append_encoded(ek, Span(key), keep_slash=False)
            var ev = List[UInt8]()
            _append_encoded(ev, Span(val), keep_slash=False)
            out.append(Header(_from_bytes(ek), _from_bytes(ev)))
        i += 1
    return out^


def _join_sorted_pairs(var pairs: List[Header]) -> String:
    """key=value pairs sorted by key, then value (byte order), joined '&'."""
    var n = len(pairs)
    for i in range(1, n):
        var cur = pairs[i]
        var j = i - 1
        while j >= 0 and (
            pairs[j].name > cur.name
            or (pairs[j].name == cur.name and pairs[j].value > cur.value)
        ):
            pairs[j + 1] = pairs[j]
            j -= 1
        pairs[j + 1] = cur
    var out = String()
    for i in range(n):
        if i > 0:
            out += "&"
        out += pairs[i].name
        out += "="
        out += pairs[i].value
    return out^


def canonical_query(query: String) -> String:
    """The CanonicalQueryString line for a query (without the '?')."""
    return _join_sorted_pairs(_query_pairs(query))


# -----------------------------------------------------------------------------
# Canonical headers
# -----------------------------------------------------------------------------


def _trim_collapse(s: String) -> String:
    """Trims SP/HT at both ends and collapses each inner run to one space."""
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    var pending_space = False
    for i in range(len(b)):
        var c = b[i]
        if c == _SP or c == _HT:
            pending_space = len(out) > 0
        else:
            if pending_space:
                out.append(_SP)
                pending_space = False
            out.append(c)
    return _from_bytes(out)


def _is_signer_owned_header(name: String) -> Bool:
    return (
        name == "authorization"
        or name == "x-amz-date"
        or name == "x-amz-security-token"
        or name == "x-amz-content-sha256"
    )


def _canonical_header_pairs(headers: List[Header]) raises -> List[Header]:
    """Lowercased, trimmed headers; refuses CR/LF, an empty name, a
    signer-owned header, and a request with no Host."""
    var out = List[Header]()
    var have_host = False
    for i in range(len(headers)):
        _check_no_crlf("header name", headers[i].name)
        _check_no_crlf("value of header " + headers[i].name, headers[i].value)
        var name = _trim_collapse(_ascii_lower(headers[i].name))
        if name.byte_length() == 0:
            raise Error("SigV4: a request header has an empty name")
        if _is_signer_owned_header(name):
            raise Error(
                "SigV4: the request already has a "
                + name
                + " header; the signer writes it"
            )
        if name == "host":
            have_host = True
        out.append(Header(name, _trim_collapse(headers[i].value)))
    if not have_host:
        raise Error("SigV4: the request has no Host header")
    return out^


@fieldwise_init
struct _CanonicalHeaders(Movable):
    var block: String  # "name:value\n" per header
    var signed: String  # "name1;name2"


def _canonicalize_headers(var pairs: List[Header]) -> _CanonicalHeaders:
    """Stable sort by name (so repeated headers keep their order), then one
    line per name with repeated values joined by ','."""
    var n = len(pairs)
    for i in range(1, n):
        var cur = pairs[i]
        var j = i - 1
        while j >= 0 and pairs[j].name > cur.name:
            pairs[j + 1] = pairs[j]
            j -= 1
        pairs[j + 1] = cur
    var block = String()
    var signed = String()
    var k = 0
    while k < n:
        var name = pairs[k].name
        block += name
        block += ":"
        block += pairs[k].value
        var m = k + 1
        while m < n and pairs[m].name == name:
            block += ","
            block += pairs[m].value
            m += 1
        block += "\n"
        if k > 0:
            signed += ";"
        signed += name
        k = m
    return _CanonicalHeaders(block^, signed^)


# -----------------------------------------------------------------------------
# Key derivation and the string to sign
# -----------------------------------------------------------------------------


def derive_signing_key(ctx: SigV4SigningContext) raises -> Array[UInt8, 32]:
    """kSigning = HMAC chain over "AWS4"+secret, date, region, service,
    "aws4_request". The intermediate keys are zeroized. Raises on a context
    `validate()` refuses (a malformed amz_date would derive a wrong key)."""
    ctx.validate()
    var k_secret = String("AWS4") + ctx.cred.secret_access_key
    var k_date = hmac_sha256_string(k_secret.as_bytes(), ctx.short_date())
    var k_region = hmac_sha256_string(Span[UInt8](k_date), ctx.region)
    var k_service = hmac_sha256_string(Span[UInt8](k_region), ctx.service)
    var k_signing = hmac_sha256_string(
        Span[UInt8](k_service), String("aws4_request")
    )
    zeroize_inline_array(k_date)
    zeroize_inline_array(k_region)
    zeroize_inline_array(k_service)
    return k_signing^


def sigv4_string_to_sign(
    canonical_request: String, ctx: SigV4SigningContext
) raises -> String:
    """AWS4-HMAC-SHA256, amz_date, the credential scope and the hex SHA-256 of
    the canonical request, one per line. Raises on a context `validate()`
    refuses."""
    ctx.validate()
    var sts = String(SIGV4_ALGORITHM)
    sts += "\n"
    sts += ctx.amz_date
    sts += "\n"
    sts += ctx.credential_scope()
    sts += "\n"
    sts += hex_lower_array_32(sha256(canonical_request.as_bytes()))
    return sts^


struct SigningKeyCache(Movable, Deinitable):
    """One derived signing key, reused while (access key id, date, region,
    service, secret) are unchanged. A cache hit skips the four-HMAC chain and
    yields the same signature byte for byte."""

    var _access_key_id: String
    var _secret_digest: Array[UInt8, 32]
    var _short_date: String
    var _region: String
    var _service: String
    var _key: Array[UInt8, 32]
    var _valid: Bool

    def __init__(out self):
        self._access_key_id = String()
        self._secret_digest = Array[UInt8, 32](fill=0)
        self._short_date = String()
        self._region = String()
        self._service = String()
        self._key = Array[UInt8, 32](fill=0)
        self._valid = False

    def signing_key(
        mut self, ctx: SigV4SigningContext
    ) raises -> Array[UInt8, 32]:
        """The signing key for `ctx`, derived or reused. Raises on a context
        `validate()` refuses."""
        ctx.validate()
        # The secret is compared through its digest, so the cache never holds
        # a second copy of it.
        var secret_digest = sha256(ctx.cred.secret_access_key.as_bytes())
        var short_date = ctx.short_date()
        var hit = (
            self._valid
            and self._access_key_id == ctx.cred.access_key_id
            and self._short_date == short_date
            and self._region == ctx.region
            and self._service == ctx.service
        )
        if hit:
            for i in range(32):
                if self._secret_digest[i] != secret_digest[i]:
                    hit = False
        if hit:
            return self._key.copy()
        var k = derive_signing_key(ctx)
        self._access_key_id = ctx.cred.access_key_id
        self._secret_digest = secret_digest.copy()
        self._short_date = short_date
        self._region = ctx.region
        self._service = ctx.service
        self._key = k.copy()
        self._valid = True
        return k^

    def __deinit__(deinit self):
        zeroize_inline_array(self._key)


# -----------------------------------------------------------------------------
# Header signing
# -----------------------------------------------------------------------------


def _sign_headers(
    method: String,
    target: String,
    headers: List[Header],
    payload_hash: String,
    ctx: SigV4SigningContext,
    var key: Array[UInt8, 32],
) raises -> SigV4Result:
    ctx.validate()
    _check_token("method", method)
    _check_token("payload hash", payload_hash)
    var pairs = _canonical_header_pairs(headers)
    var to_add = List[Header]()
    pairs.append(Header(String("x-amz-date"), ctx.amz_date))
    to_add.append(Header(String("X-Amz-Date"), ctx.amz_date))
    if ctx.sign_payload_header:
        pairs.append(Header(String("x-amz-content-sha256"), payload_hash))
        to_add.append(Header(String("x-amz-content-sha256"), payload_hash))
    if ctx.cred.has_session_token():
        if not ctx.omit_session_token:
            pairs.append(
                Header(String("x-amz-security-token"), ctx.cred.session_token)
            )
        to_add.append(
            Header(String("X-Amz-Security-Token"), ctx.cred.session_token)
        )
    var ch = _canonicalize_headers(pairs^)
    var split = _split_target(target)

    var cr = method + "\n"
    cr += canonical_uri(split[0], ctx.normalize_path, ctx.uri_encode_path)
    cr += "\n"
    cr += canonical_query(split[1])
    cr += "\n"
    cr += ch.block
    cr += "\n"
    cr += ch.signed
    cr += "\n"
    cr += payload_hash

    var sts = sigv4_string_to_sign(cr, ctx)
    var sig = hex_lower_array_32(hmac_sha256_string(Span[UInt8](key), sts))
    zeroize_inline_array(key)

    var auth = String(SIGV4_ALGORITHM) + " Credential="
    auth += ctx.cred.access_key_id
    auth += "/"
    auth += ctx.credential_scope()
    auth += ", SignedHeaders="
    auth += ch.signed
    auth += ", Signature="
    auth += sig
    to_add.append(Header(String("Authorization"), auth))
    return SigV4Result(cr^, sts^, sig^, ch.signed, auth^, to_add^)


def sigv4_sign_payload_hash(
    method: String,
    target: String,
    headers: List[Header],
    payload_hash: String,
    ctx: SigV4SigningContext,
) raises -> SigV4Result:
    """Header-signs a request whose payload hash the caller computed
    (hex SHA-256, `UNSIGNED_PAYLOAD`, or a streaming marker). `target` is the
    request target: path, then '?' and the query when there is one."""
    ctx.validate()
    return _sign_headers(
        method, target, headers, payload_hash, ctx, derive_signing_key(ctx)
    )


def sigv4_sign(
    method: String,
    target: String,
    headers: List[Header],
    body: Span[UInt8, _],
    ctx: SigV4SigningContext,
) raises -> SigV4Result:
    """Header-signs a request, hashing `body` for the payload hash."""
    return sigv4_sign_payload_hash(
        method, target, headers, hex_lower_array_32(sha256(body)), ctx
    )


def sigv4_sign_cached(
    method: String,
    target: String,
    headers: List[Header],
    payload_hash: String,
    ctx: SigV4SigningContext,
    mut cache: SigningKeyCache,
) raises -> SigV4Result:
    """`sigv4_sign_payload_hash` with the signing key taken from `cache`."""
    ctx.validate()
    return _sign_headers(
        method, target, headers, payload_hash, ctx, cache.signing_key(ctx)
    )


# -----------------------------------------------------------------------------
# Query signing (presigned URLs)
# -----------------------------------------------------------------------------


def _is_presign_param(name: String) -> Bool:
    return (
        name == "X-Amz-Algorithm"
        or name == "X-Amz-Credential"
        or name == "X-Amz-Date"
        or name == "X-Amz-Expires"
        or name == "X-Amz-SignedHeaders"
        or name == "X-Amz-Security-Token"
        or name == "X-Amz-Signature"
    )


def sigv4_presign(
    method: String,
    target: String,
    headers: List[Header],
    payload_hash: String,
    ctx: SigV4SigningContext,
    expires_seconds: Int,
) raises -> SigV4PresignResult:
    """Query-signs a request: the signature travels in X-Amz-* query
    parameters valid for `expires_seconds` (1 to MAX_PRESIGN_EXPIRES_SECONDS).
    Only the request's own headers are signed; `sign_payload_header` does not
    apply."""
    ctx.validate()
    _check_token("method", method)
    _check_token("payload hash", payload_hash)
    if expires_seconds < 1 or expires_seconds > MAX_PRESIGN_EXPIRES_SECONDS:
        raise Error(
            "SigV4: presign expiry must be 1 to "
            + String(MAX_PRESIGN_EXPIRES_SECONDS)
            + " seconds, got "
            + String(expires_seconds)
        )
    var ch = _canonicalize_headers(_canonical_header_pairs(headers))
    var split = _split_target(target)
    var pairs = _query_pairs(split[1])
    for i in range(len(pairs)):
        if _is_presign_param(pairs[i].name):
            raise Error(
                "SigV4: the request query already has "
                + pairs[i].name
                + "; the signer writes it"
            )

    var params = List[Header]()
    params.append(Header(String("X-Amz-Algorithm"), String(SIGV4_ALGORITHM)))
    params.append(
        Header(
            String("X-Amz-Credential"),
            ctx.cred.access_key_id + "/" + ctx.credential_scope(),
        )
    )
    params.append(Header(String("X-Amz-Date"), ctx.amz_date))
    params.append(Header(String("X-Amz-SignedHeaders"), ch.signed))
    params.append(Header(String("X-Amz-Expires"), String(expires_seconds)))
    for i in range(len(params)):
        pairs.append(
            Header(uri_encode(params[i].name), uri_encode(params[i].value))
        )
    if ctx.cred.has_session_token():
        var tok = Header(String("X-Amz-Security-Token"), ctx.cred.session_token)
        if not ctx.omit_session_token:
            pairs.append(Header(uri_encode(tok.name), uri_encode(tok.value)))
        params.append(tok^)

    var cr = method + "\n"
    cr += canonical_uri(split[0], ctx.normalize_path, ctx.uri_encode_path)
    cr += "\n"
    cr += _join_sorted_pairs(pairs^)
    cr += "\n"
    cr += ch.block
    cr += "\n"
    cr += ch.signed
    cr += "\n"
    cr += payload_hash

    var sts = sigv4_string_to_sign(cr, ctx)
    var key = derive_signing_key(ctx)
    var sig = hex_lower_array_32(hmac_sha256_string(Span[UInt8](key), sts))
    zeroize_inline_array(key)
    params.append(Header(String("X-Amz-Signature"), sig))

    var signed_target = target
    var tb = target.as_bytes()
    if target.find("?") < 0:
        signed_target += "?"
    elif len(tb) > 0 and tb[len(tb) - 1] != UInt8(0x3F) and tb[len(tb) - 1] != _AMP:
        signed_target += "&"
    for i in range(len(params)):
        if i > 0:
            signed_target += "&"
        signed_target += uri_encode(params[i].name)
        signed_target += "="
        signed_target += uri_encode(params[i].value)
    return SigV4PresignResult(
        cr^, sts^, sig^, ch.signed, params^, signed_target^
    )
