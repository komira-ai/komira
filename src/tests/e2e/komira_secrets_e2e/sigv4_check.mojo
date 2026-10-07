# =============================================================================
# sigv4_check.mojo -- the fake's own SigV4 verifier
# =============================================================================
#
# The fake checks every request's signature WITHOUT komira_aws_core: it
# rebuilds the canonical request from the request as the server parsed it
# (method, path, the headers the Authorization header lists, the body's
# SHA-256), the string to sign and the signing key from the secret it holds
# for the access key id, with komira_crypto's SHA-256 and HMAC only, and
# compares the hex signature. A client that signs with a different scope,
# key, header set or body than the one it sends is refused, as the service
# refuses it.
#
# The credential scope is the FAKE's: the date from X-Amz-Date, the region
# and the service signing name the fake was built with. A request scoped to
# another service is refused before the signature is compared, with the
# service's own wording, so a client signing as the wrong service is told
# why.
#
# What it does not check: the request's age (X-Amz-Date against a clock; the
# real service refuses a signature older than five minutes), session tokens
# (the canned credentials are long-term ones), and a query string (the fake
# serves awsJson, which posts to "/" with none; a request carrying one is
# refused).
# =============================================================================

from komira_crypto import hex_lower_array_32, hmac_sha256_string, sha256

comptime SIGV4_ALGORITHM = "AWS4-HMAC-SHA256"


struct SigV4Verdict(Copyable, Movable):
    """A signature check's outcome: `ok`, or the AWS error code and message
    the service answers with."""

    var ok: Bool
    var code: String
    var message: String

    def __init__(out self, ok: Bool, var code: String, var message: String):
        self.ok = ok
        self.code = code^
        self.message = message^

    @staticmethod
    def accept() -> SigV4Verdict:
        return SigV4Verdict(True, String(""), String(""))

    @staticmethod
    def refuse(var code: String, var message: String) -> SigV4Verdict:
        return SigV4Verdict(False, code^, message^)


struct CannedCredential(Copyable, Movable):
    """An access key id and its secret, as the fake holds them."""

    var access_key_id: String
    var secret_access_key: String

    def __init__(out self, var access_key_id: String, var secret_access_key: String):
        self.access_key_id = access_key_id^
        self.secret_access_key = secret_access_key^


def _sub(s: String, i: Int, j: Int) -> String:
    """Bytes [i, j) of `s`, clamped. Every cut here is at an ASCII byte."""
    var n = s.byte_length()
    var lo = max(0, min(i, n))
    var hi = max(lo, min(j, n))
    return String(s[byte=lo:hi])


def _is_space(c: UInt8) -> Bool:
    return c == UInt8(0x20) or c == UInt8(0x09)


def canonical_header_value(v: String) -> String:
    """SigV4's header value: leading and trailing spaces trimmed and every
    run of spaces inside collapsed to one."""
    var b = v.as_bytes()
    var out = List[UInt8]()
    var pending_space = False
    for i in range(len(b)):
        var c = b[i]
        if _is_space(c):
            pending_space = len(out) > 0
            continue
        if pending_space:
            out.append(UInt8(0x20))
            pending_space = False
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def _hex_sha256(data: Span[UInt8, _]) -> String:
    return hex_lower_array_32(sha256(data))


def sigv4_signature(
    secret_access_key: String,
    amz_date: String,
    scope_date: String,
    region: String,
    service: String,
    canonical_request: String,
) -> String:
    """The hex signature of `canonical_request` for that scope: the string
    to sign, and the key derived from the secret, date, region and service
    (the SigV4 key derivation, HMAC-SHA256 at each step)."""
    var scope = scope_date + "/" + region + "/" + service + "/aws4_request"
    var sts = (
        String(SIGV4_ALGORITHM)
        + "\n"
        + amz_date
        + "\n"
        + scope
        + "\n"
        + _hex_sha256(canonical_request.as_bytes())
    )
    var k_secret = String("AWS4") + secret_access_key
    var k_date = hmac_sha256_string(k_secret.as_bytes(), scope_date)
    var k_region = hmac_sha256_string(Span[UInt8](k_date), region)
    var k_service = hmac_sha256_string(Span[UInt8](k_region), service)
    var k_signing = hmac_sha256_string(Span[UInt8](k_service), "aws4_request")
    return hex_lower_array_32(hmac_sha256_string(Span[UInt8](k_signing), sts))


def _param(auth: String, name: String) -> String:
    """The value of `name=` in the Authorization header's parameter list,
    "" when absent. Values end at ',' or the end of the header."""
    var key = name + "="
    var at = auth.find(key)
    if at < 0:
        return String("")
    var start = at + key.byte_length()
    var end = auth.find(",", start)
    if end < 0:
        end = auth.byte_length()
    return canonical_header_value(_sub(auth, start, end))


def _split(s: String, sep: String) -> List[String]:
    var out = List[String]()
    var start = 0
    while True:
        var at = s.find(sep, start)
        if at < 0:
            out.append(_sub(s, start, s.byte_length()))
            return out^
        out.append(_sub(s, start, at))
        start = at + sep.byte_length()


def verify_sigv4(
    method: String,
    path: String,
    query: String,
    headers: Dict[String, String],
    body: Span[UInt8, _],
    credentials: List[CannedCredential],
    region: String,
    service: String,
) raises -> SigV4Verdict:
    """Check the request's SigV4 Authorization header against the
    credentials the fake holds, scoped to (`region`, `service`). `headers`
    is keyed by lowercase name, as the server parses them."""
    if query.byte_length() > 0:
        return SigV4Verdict.refuse(
            String("InvalidSignatureException"),
            String("This fake signs no query string."),
        )
    var auth_opt = headers.get(String("authorization"))
    if not auth_opt:
        return SigV4Verdict.refuse(
            String("MissingAuthenticationTokenException"),
            String("Missing Authentication Token"),
        )
    var auth = auth_opt.value()
    if not auth.startswith(String(SIGV4_ALGORITHM) + " "):
        return SigV4Verdict.refuse(
            String("IncompleteSignatureException"),
            String("Unsupported authorization type"),
        )
    var credential = _param(auth, String("Credential"))
    var signed_headers = _param(auth, String("SignedHeaders"))
    var signature = _param(auth, String("Signature"))
    var amz_date = canonical_header_value(
        headers.get(String("x-amz-date")).or_else(String(""))
    )
    if (
        credential.byte_length() == 0
        or signed_headers.byte_length() == 0
        or signature.byte_length() == 0
        or amz_date.byte_length() != 16
    ):
        return SigV4Verdict.refuse(
            String("IncompleteSignatureException"),
            String(
                "Authorization header requires 'Credential', 'SignedHeaders'"
                " and 'Signature', and the request an X-Amz-Date."
            ),
        )
    var scope = _split(credential, String("/"))
    if len(scope) != 5 or scope[4] != "aws4_request":
        return SigV4Verdict.refuse(
            String("IncompleteSignatureException"),
            String("Credential is not <key>/<date>/<region>/<service>/aws4_request."),
        )
    var secret = String("")
    var known = False
    for i in range(len(credentials)):
        if credentials[i].access_key_id == scope[0]:
            secret = credentials[i].secret_access_key.copy()
            known = True
    if not known:
        return SigV4Verdict.refuse(
            String("UnrecognizedClientException"),
            String("The security token included in the request is invalid."),
        )
    var scope_date = _sub(amz_date, 0, 8)
    if scope[1] != scope_date:
        return SigV4Verdict.refuse(
            String("InvalidSignatureException"),
            String("Date in Credential scope does not match YYYYMMDD from ISO-8601 version of date from HTTP."),
        )
    if scope[2] != region:
        return SigV4Verdict.refuse(
            String("InvalidSignatureException"),
            String("Credential should be scoped to a valid region."),
        )
    if scope[3] != service:
        return SigV4Verdict.refuse(
            String("InvalidSignatureException"),
            String("Credential should be scoped to correct service: '") + service + "'.",
        )
    var names = _split(signed_headers, String(";"))
    var has_host = False
    var has_date = False
    var canonical_headers = String("")
    for i in range(len(names)):
        ref name = names[i]
        if name != name.lower() or (i > 0 and not (names[i - 1] < name)):
            return SigV4Verdict.refuse(
                String("InvalidSignatureException"),
                String("SignedHeaders must be lowercase, sorted and distinct."),
            )
        var value = headers.get(name)
        if not value:
            return SigV4Verdict.refuse(
                String("InvalidSignatureException"),
                String("A signed header is not on the request: ") + name,
            )
        if name == "host":
            has_host = True
        if name == "x-amz-date":
            has_date = True
        canonical_headers += name + ":" + canonical_header_value(value.value()) + "\n"
    if not has_host or not has_date:
        return SigV4Verdict.refuse(
            String("InvalidSignatureException"),
            String("SignedHeaders must include host and x-amz-date."),
        )
    var canonical_request = (
        method
        + "\n"
        + path
        + "\n"
        + query
        + "\n"
        + canonical_headers
        + "\n"
        + signed_headers
        + "\n"
        + _hex_sha256(body)
    )
    var want = sigv4_signature(secret, amz_date, scope_date, region, service, canonical_request)
    if want != signature:
        return SigV4Verdict.refuse(
            String("InvalidSignatureException"),
            String(
                "The request signature we calculated does not match the"
                " signature you provided. Check your AWS Secret Access Key"
                " and signing method."
            ),
        )
    return SigV4Verdict.accept()
