# =============================================================================
# komira_gcp_core/token_wire.mojo -- the token requests and responses, pure
# =============================================================================
#
# Every byte the token fetchers (token_sources.mojo) send, and every reading
# of what comes back, with no clock, no environment and no socket: the time
# is a parameter and the exchange is the caller's (token_http.mojo).
#
#   * the metadata server (GCE, Cloud Run, GKE): a GET of
#     `/computeMetadata/v1/instance/service-accounts/default/token` with
#     `Metadata-Flavor: Google`, and `?scopes=` when the caller names scopes
#     (Google's Go `compute/metadata` and Python `google.auth.compute_engine`
#     both send them comma-joined). The host is a parameter: adc.mojo reads
#     GCE_METADATA_HOST.
#     https://cloud.google.com/compute/docs/access/authenticate-workloads
#   * a service-account key file (`"type": "service_account"`): the RS256 JWT
#     of the OAuth 2.0 JWT bearer grant (RFC 7523), POSTed to the key's
#     `token_uri`; or, for an API that accepts one, a self-signed JWT used as
#     the bearer token itself, with no exchange. The claims are those of
#     google-auth for Python (`google/oauth2/service_account.py`,
#     `_make_authorization_grant_assertion`, and `google/auth/jwt.py`,
#     `Credentials._make_jwt`): `iat` is now and `exp` an hour later.
#     https://developers.google.com/identity/protocols/oauth2/service-account
#   * an `authorized_user` file (what `gcloud auth application-default
#     login` writes): the refresh-token grant (RFC 6749 §6), POSTed to the
#     file's `token_uri`, else Google's.
#   * the token response (RFC 6749 §5.1): `access_token` and `expires_in`;
#     and an error response (§5.2), of which only the `error` code is
#     repeated, never `error_description` or a body byte.
#
# ⛔ A key, an assertion, a refresh token, a client secret and an access token
# are credentials. None of the types here is `Writable`; every error names a
# file by the path it was given and a field by its name, never a value.
# =============================================================================

from komira_crypto import rsa_pkcs8_der_from_pem, rsa_sha256_sign
from komira_encoding import base64_url_encode_nopad
from komira_json import (
    JsonValue,
    parse_json_bytes,
    write_i64_dec,
    write_json_string,
)

from ._text import _form_encode, _from_utf8_bytes, _sub
from .token import AccessToken
from .token_http import TokenHttpRequest, TokenHttpResponse


comptime GOOGLE_OAUTH2_TOKEN_URI: StaticString = "https://oauth2.googleapis.com/token"
"""Google's OAuth 2.0 token endpoint: the `token_uri` of a key file that
names none (Go's `golang.org/x/oauth2/google`, `Endpoint.TokenURL`), and of
an `authorized_user` file (google-auth's `_GOOGLE_OAUTH2_TOKEN_ENDPOINT`)."""

comptime GOOGLE_DEFAULT_UNIVERSE: StaticString = "googleapis.com"
"""The default `universe_domain`. A key file of another universe is refused:
its tokens are not minted by Google's token endpoint."""

comptime METADATA_DEFAULT_HOST: StaticString = "metadata.google.internal"
"""The metadata server's host name (google-auth's `_GCE_DEFAULT_HOST`)."""

comptime METADATA_IP: StaticString = "169.254.169.254"
"""The metadata server's link-local address, which adc.mojo probes (Go's
`compute/metadata` `metadataIP`)."""

comptime METADATA_FLAVOR_HEADER: StaticString = "Metadata-Flavor"
comptime METADATA_FLAVOR_VALUE: StaticString = "Google"

comptime METADATA_TOKEN_PATH: StaticString = (
    "/computeMetadata/v1/instance/service-accounts/default/token"
)

comptime JWT_BEARER_GRANT_TYPE: StaticString = "urn:ietf:params:oauth:grant-type:jwt-bearer"
comptime REFRESH_GRANT_TYPE: StaticString = "refresh_token"

comptime JWT_LIFETIME_SECONDS: Int64 = 3600
"""The life of a JWT signed here: an hour, the most Google accepts for a
grant assertion and google-auth's `_DEFAULT_TOKEN_LIFETIME_SECS`."""

comptime FORM_CONTENT_TYPE: StaticString = "application/x-www-form-urlencoded"

comptime _MAX_DEPTH = 16
"""Nesting limit for a credentials file or token response (both are flat
objects)."""


# =============================================================================
# Endpoints
# =============================================================================


@fieldwise_init
struct TokenEndpoint(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Where a token request goes: "http" or "https", the host (an IPv6
    literal in brackets), the port and the path (with any query)."""

    var scheme: String
    var host: String
    var port: Int
    var path: String

    def host_header(self) -> String:
        """The Host header value: the port is omitted when it is the
        scheme's default."""
        if (self.scheme == "http" and self.port == 80) or (
            self.scheme == "https" and self.port == 443
        ):
            return self.host
        return self.host + ":" + String(self.port)

    def url(self) -> String:
        """The endpoint as a URL, for an error message."""
        return self.scheme + "://" + self.host_header() + self.path


def _parse_port(text: String, what: String) raises -> Int:
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 5:
        raise Error(what + ": the port is not a number from 1 to 65535")
    var v = 0
    for i in range(len(b)):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            raise Error(what + ": the port is not a number from 1 to 65535")
        v = v * 10 + Int(b[i] - UInt8(0x30))
    if v < 1 or v > 65535:
        raise Error(what + ": the port is not a number from 1 to 65535")
    return v


def _split_authority(
    authority: String, default_port: Int, what: String
) raises -> Tuple[String, Int]:
    """`host[:port]`, an IPv6 literal in brackets. Refuses userinfo, an
    empty host, and a byte that is not printable ASCII."""
    var b = authority.as_bytes()
    if len(b) == 0:
        raise Error(what + ": the host is empty")
    for i in range(len(b)):
        if b[i] <= UInt8(0x20) or b[i] >= UInt8(0x7F) or b[i] == UInt8(0x40):
            raise Error(what + ": the host holds a byte a host cannot")
        if b[i] == UInt8(0x2F) or b[i] == UInt8(0x3F) or b[i] == UInt8(0x23):
            raise Error(what + ": the host holds a byte a host cannot")
    if b[0] == UInt8(0x5B):
        var close = authority.find("]")
        if close < 0:
            raise Error(what + ": an IPv6 host has no closing bracket")
        var host = _sub(authority, 0, close + 1)
        var rest = _sub(authority, close + 1, len(b))
        if rest.byte_length() == 0:
            return (host^, default_port)
        if not rest.startswith(":"):
            raise Error(what + ": bytes follow the IPv6 host")
        return (host^, _parse_port(_sub(rest, 1, rest.byte_length()), what))
    var colon = authority.find(":")
    if colon < 0:
        return (authority.copy(), default_port)
    if colon == 0:
        raise Error(what + ": the host is empty")
    return (
        _sub(authority, 0, colon),
        _parse_port(_sub(authority, colon + 1, len(b)), what),
    )


def parse_token_endpoint(url: String, what: String) raises -> TokenEndpoint:
    """An `http://` or `https://` URL as a `TokenEndpoint`. Refuses any other
    scheme, userinfo and a fragment. `what` names the URL's source in the
    error."""
    var scheme: String
    var rest: String
    if url.startswith("https://"):
        scheme = String("https")
        rest = _sub(url, 8, url.byte_length())
    elif url.startswith("http://"):
        scheme = String("http")
        rest = _sub(url, 7, url.byte_length())
    else:
        raise Error(what + ": the token URI is not an http or https URL")
    if rest.find("#") >= 0:
        raise Error(what + ": the token URI has a fragment")
    var slash = rest.find("/")
    var q = rest.find("?")
    var cut = rest.byte_length()
    if slash >= 0:
        cut = slash
    if q >= 0 and q < cut:
        cut = q
    var authority = _sub(rest, 0, cut)
    var path = _sub(rest, cut, rest.byte_length())
    if path.byte_length() == 0 or path.startswith("?"):
        path = String("/") + path
    var hp = _split_authority(authority, 443 if scheme == "https" else 80, what)
    return TokenEndpoint(scheme^, hp[0].copy(), hp[1], path^)


def metadata_endpoint(host: String) raises -> TokenEndpoint:
    """The metadata server at `host`, a host name or IP literal with an
    optional `:port`, as GCE_METADATA_HOST gives it (Go's
    `compute/metadata`: "the host:port of the metadata server"). Plain
    HTTP, port 80 when none is given. The path is the token path."""
    var hp = _split_authority(host, 80, String("the metadata server host"))
    return TokenEndpoint(
        String("http"), hp[0].copy(), hp[1], String(METADATA_TOKEN_PATH)
    )


# =============================================================================
# The metadata server
# =============================================================================


def metadata_token_request(
    endpoint: TokenEndpoint, scopes: List[String]
) -> TokenHttpRequest:
    """The GET of the default service account's token. With scopes, the
    query `scopes=<comma-joined>`, form-encoded."""
    var target = endpoint.path.copy()
    if len(scopes) > 0:
        var joined = String("")
        for i in range(len(scopes)):
            if i > 0:
                joined += ","
            joined += scopes[i]
        target += "?scopes=" + _form_encode(joined)
    var req = TokenHttpRequest(
        String("GET"), endpoint.scheme, endpoint.host, endpoint.port, target
    )
    req.add_header(String("Host"), endpoint.host_header())
    req.add_header(String(METADATA_FLAVOR_HEADER), String(METADATA_FLAVOR_VALUE))
    return req^


def metadata_ping_request(endpoint: TokenEndpoint) -> TokenHttpRequest:
    """The GET of the metadata server's root, which only a metadata server
    answers with `Metadata-Flavor: Google` (google-auth's `ping`, Go's
    `testOnGCE`)."""
    var req = TokenHttpRequest(
        String("GET"), endpoint.scheme, endpoint.host, endpoint.port, String("/")
    )
    req.add_header(String("Host"), endpoint.host_header())
    req.add_header(String(METADATA_FLAVOR_HEADER), String(METADATA_FLAVOR_VALUE))
    return req^


def metadata_ping_answered(res: TokenHttpResponse) -> Bool:
    """Whether a ping's response is a metadata server's: a 200 carrying
    `Metadata-Flavor: Google`."""
    return res.status == 200 and res.header(String(METADATA_FLAVOR_HEADER)) == String(
        METADATA_FLAVOR_VALUE
    )


# =============================================================================
# The token response
# =============================================================================


def _is_error_code(s: String) -> Bool:
    """An RFC 6749 §5.2 `error` value as Google sends one: 1 to 64 bytes of
    lower-case ASCII letters, digits and `_`. Only such a value is repeated in
    an error message."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 64:
        return False
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(0x61) and c <= UInt8(0x7A))
            or (c >= UInt8(0x30) and c <= UInt8(0x39))
            or c == UInt8(0x5F)
        )
        if not ok:
            return False
    return True


def token_error(res: TokenHttpResponse, what: String) -> Error:
    """The error for a token response that is not a 200: `what` answered
    HTTP <status>, and the RFC 6749 §5.2 `error` code when the body is a
    JSON object holding one that is a plain code. Never the description or
    any other body byte."""
    var msg = what + " answered HTTP " + String(res.status)
    try:
        var doc = parse_json_bytes(res.body, _MAX_DEPTH)
        if doc.is_object() and doc.has("error"):
            var e = doc.get("error")
            if e.is_string():
                var code = e.as_string()
                if _is_error_code(code):
                    msg += " (" + code + ")"
    except:
        pass
    return Error(msg)


def parse_token_response(
    res: TokenHttpResponse, what: String, now_ms: Int64
) raises -> AccessToken:
    """The token of a token response: a 200 whose body is a JSON object with
    a non-empty string `access_token` and a positive integer `expires_in`
    (seconds from `now_ms`, RFC 6749 §5.1). Any other status raises
    `token_error`. `what` names the endpoint in every error, and no error
    repeats a body byte."""
    if res.status != 200:
        raise token_error(res, what)
    var doc: JsonValue
    try:
        doc = parse_json_bytes(res.body, _MAX_DEPTH)
    except:
        raise Error(what + " answered 200 with a body that is not JSON")
    if not doc.is_object():
        raise Error(what + " answered 200 with a body that is not a JSON object")
    if not doc.has("access_token"):
        raise Error(what + " answered 200 with no access_token")
    var t = doc.get("access_token")
    if not t.is_string():
        raise Error(what + " answered 200 with an access_token that is not a string")
    var token = t.as_string()
    if token.byte_length() == 0:
        raise Error(what + " answered 200 with an empty access_token")
    if not doc.has("expires_in"):
        raise Error(what + " answered 200 with no expires_in")
    var e = doc.get("expires_in")
    if not e.is_number() or not e.is_integral_number():
        raise Error(what + " answered 200 with an expires_in that is not an integer")
    var secs: Int64
    try:
        secs = e.as_int64()
    except:
        raise Error(what + " answered 200 with an expires_in out of range")
    if secs <= 0:
        raise Error(what + " answered 200 with an expires_in that is not positive")
    return AccessToken.expiring_in(token^, now_ms, secs)


# =============================================================================
# Credentials files
# =============================================================================


def parse_credentials_json(text: String, where: String) raises -> JsonValue:
    """A credentials file's JSON object. `where` names the file."""
    var b = List[UInt8]()
    b.extend(Span(text.as_bytes()))
    var doc: JsonValue
    try:
        doc = parse_json_bytes(b, _MAX_DEPTH)
    except:
        raise Error("the credentials file " + where + " is not JSON")
    if not doc.is_object():
        raise Error("the credentials file " + where + " is not a JSON object")
    return doc^


def credentials_type(doc: JsonValue, where: String) raises -> String:
    """A credentials file's `type`."""
    if not doc.has("type"):
        raise Error("the credentials file " + where + " has no \"type\"")
    var t = doc.get("type")
    if not t.is_string():
        raise Error("the credentials file " + where + "'s \"type\" is not a string")
    return t.as_string()


def _required(doc: JsonValue, field: String, where: String) raises -> String:
    if not doc.has(field):
        raise Error("the credentials file " + where + " has no \"" + field + "\"")
    var v = doc.get(field)
    if not v.is_string() or v.as_string().byte_length() == 0:
        raise Error(
            "the credentials file " + where + "'s \"" + field
            + "\" is not a non-empty string"
        )
    return v.as_string()


def _optional(doc: JsonValue, field: String, where: String) raises -> String:
    if not doc.has(field):
        return String("")
    var v = doc.get(field)
    if v.is_null():
        return String("")
    if not v.is_string():
        raise Error(
            "the credentials file " + where + "'s \"" + field + "\" is not a string"
        )
    return v.as_string()


struct ServiceAccountKey(Copyable, Movable, Deinitable):
    """A service-account key file, read: the account's email, the key's id,
    the private key as PKCS#8 DER, and the token endpoint. Not `Writable`:
    it holds a private key."""

    var client_email: String
    var private_key_id: String
    var private_key_der: List[UInt8]
    var token_endpoint: TokenEndpoint
    var token_uri: String

    def __init__(
        out self,
        var client_email: String,
        var private_key_id: String,
        var private_key_der: List[UInt8],
        var token_endpoint: TokenEndpoint,
        var token_uri: String,
    ):
        self.client_email = client_email^
        self.private_key_id = private_key_id^
        self.private_key_der = private_key_der^
        self.token_endpoint = token_endpoint^
        self.token_uri = token_uri^


def service_account_key_from_json(
    doc: JsonValue, where: String
) raises -> ServiceAccountKey:
    """A `"type": "service_account"` object as a `ServiceAccountKey`.
    Requires `client_email` and `private_key` (a PEM `PRIVATE KEY`, RSA);
    `private_key_id` becomes the JWT's `kid` when present; `token_uri`
    defaults to Google's. A `universe_domain` other than googleapis.com is
    refused."""
    var t = credentials_type(doc, where)
    if t != "service_account":
        raise Error(
            "the credentials file " + where + " is not a service_account key"
        )
    var email = _required(doc, String("client_email"), where)
    var pem = _required(doc, String("private_key"), where)
    var der: List[UInt8]
    try:
        der = rsa_pkcs8_der_from_pem(pem)
    except e:
        raise Error(
            "the credentials file " + where
            + "'s private_key is not an RSA PKCS#8 PEM key: " + String(e)
        )
    var universe = _optional(doc, String("universe_domain"), where)
    if universe.byte_length() > 0 and universe != GOOGLE_DEFAULT_UNIVERSE:
        raise Error(
            "the credentials file " + where + " is for the universe "
            + universe + "; komira_gcp_core mints tokens for "
            + String(GOOGLE_DEFAULT_UNIVERSE) + " only"
        )
    var uri = _optional(doc, String("token_uri"), where)
    if uri.byte_length() == 0:
        uri = String(GOOGLE_OAUTH2_TOKEN_URI)
    var endpoint = parse_token_endpoint(
        uri, String("the credentials file ") + where + "'s token_uri"
    )
    return ServiceAccountKey(
        email^,
        _optional(doc, String("private_key_id"), where),
        der^,
        endpoint^,
        uri^,
    )


def parse_service_account_key(text: String, where: String) raises -> ServiceAccountKey:
    """A service-account key file's text as a `ServiceAccountKey`."""
    return service_account_key_from_json(parse_credentials_json(text, where), where)


struct AuthorizedUser(Copyable, Movable, Deinitable):
    """An `authorized_user` file, read. Not `Writable`: it holds a client
    secret and a refresh token."""

    var client_id: String
    var client_secret: String
    var refresh_token: String
    var token_endpoint: TokenEndpoint
    var token_uri: String

    def __init__(
        out self,
        var client_id: String,
        var client_secret: String,
        var refresh_token: String,
        var token_endpoint: TokenEndpoint,
        var token_uri: String,
    ):
        self.client_id = client_id^
        self.client_secret = client_secret^
        self.refresh_token = refresh_token^
        self.token_endpoint = token_endpoint^
        self.token_uri = token_uri^


def authorized_user_from_json(doc: JsonValue, where: String) raises -> AuthorizedUser:
    """A `"type": "authorized_user"` object: `client_id`, `client_secret`
    and `refresh_token` are required (google-auth's
    `Credentials.from_authorized_user_info`); `token_uri` defaults to
    Google's."""
    var t = credentials_type(doc, where)
    if t != "authorized_user":
        raise Error(
            "the credentials file " + where + " is not an authorized_user file"
        )
    var id = _required(doc, String("client_id"), where)
    var secret = _required(doc, String("client_secret"), where)
    var refresh = _required(doc, String("refresh_token"), where)
    var uri = _optional(doc, String("token_uri"), where)
    if uri.byte_length() == 0:
        uri = String(GOOGLE_OAUTH2_TOKEN_URI)
    var endpoint = parse_token_endpoint(
        uri, String("the credentials file ") + where + "'s token_uri"
    )
    return AuthorizedUser(id^, secret^, refresh^, endpoint^, uri^)


# =============================================================================
# The RS256 JWT
# =============================================================================


def _scope_claim(scopes: List[String]) -> String:
    var out = String("")
    for i in range(len(scopes)):
        if i > 0:
            out += " "
        out += scopes[i]
    return out


def _member(mut buf: List[UInt8], name: String, value: String, first: Bool):
    if not first:
        buf.append(UInt8(0x2C))
    write_json_string(buf, name)
    buf.append(UInt8(0x3A))
    write_json_string(buf, value)


def _int_member(mut buf: List[UInt8], name: String, value: Int64):
    buf.append(UInt8(0x2C))
    write_json_string(buf, name)
    buf.append(UInt8(0x3A))
    write_i64_dec(buf, value)


def _jwt_header(key: ServiceAccountKey) -> List[UInt8]:
    """`{"typ":"JWT","alg":"RS256","kid":<private_key_id>}`, without `kid`
    when the key has no id (google-auth's `jwt.encode` order)."""
    var buf = List[UInt8]()
    buf.append(UInt8(0x7B))
    _member(buf, String("typ"), String("JWT"), True)
    _member(buf, String("alg"), String("RS256"), False)
    if key.private_key_id.byte_length() > 0:
        _member(buf, String("kid"), key.private_key_id, False)
    buf.append(UInt8(0x7D))
    return buf^


def _sign_jwt(key: ServiceAccountKey, claims: List[UInt8]) raises -> String:
    var signing_input = base64_url_encode_nopad(Span(_jwt_header(key)))
    signing_input += "."
    signing_input += base64_url_encode_nopad(Span(claims))
    var sig = rsa_sha256_sign(
        Span(key.private_key_der), signing_input.as_bytes()
    )
    return signing_input + "." + base64_url_encode_nopad(Span(sig))


def jwt_grant_assertion(
    key: ServiceAccountKey,
    scopes: List[String],
    subject: String,
    now_unix_seconds: Int64,
) raises -> String:
    """The RS256 assertion of the JWT bearer grant: claims `iat`, `exp` (an
    hour on), `iss` (the account), `aud` (the token URI), `scope` (the
    scopes, space-joined), and `sub` when `subject` names a user to act as
    (domain-wide delegation)."""
    var buf = List[UInt8]()
    buf.append(UInt8(0x7B))
    write_json_string(buf, String("iat"))
    buf.append(UInt8(0x3A))
    write_i64_dec(buf, now_unix_seconds)
    _int_member(buf, String("exp"), now_unix_seconds + JWT_LIFETIME_SECONDS)
    _member(buf, String("iss"), key.client_email, False)
    _member(buf, String("aud"), key.token_uri, False)
    _member(buf, String("scope"), _scope_claim(scopes), False)
    if subject.byte_length() > 0:
        _member(buf, String("sub"), subject, False)
    buf.append(UInt8(0x7D))
    return _sign_jwt(key, buf)


def self_signed_jwt(
    key: ServiceAccountKey,
    audience: String,
    scopes: List[String],
    now_unix_seconds: Int64,
) raises -> String:
    """A self-signed JWT, used as the bearer token itself: claims `iss` and
    `sub` (the account), `iat`, `exp` (an hour on), then `aud` when an
    audience is given (`https://<service>.googleapis.com/`) and `scope` when
    scopes are. One of the two is required."""
    if audience.byte_length() == 0 and len(scopes) == 0:
        raise Error("a self-signed JWT needs an audience or scopes")
    var buf = List[UInt8]()
    buf.append(UInt8(0x7B))
    _member(buf, String("iss"), key.client_email, True)
    _member(buf, String("sub"), key.client_email, False)
    _int_member(buf, String("iat"), now_unix_seconds)
    _int_member(buf, String("exp"), now_unix_seconds + JWT_LIFETIME_SECONDS)
    if audience.byte_length() > 0:
        _member(buf, String("aud"), audience, False)
    if len(scopes) > 0:
        _member(buf, String("scope"), _scope_claim(scopes), False)
    buf.append(UInt8(0x7D))
    return _sign_jwt(key, buf)


# =============================================================================
# The token endpoint's grants
# =============================================================================


def _form_post(endpoint: TokenEndpoint, body: String) -> TokenHttpRequest:
    var req = TokenHttpRequest(
        String("POST"), endpoint.scheme, endpoint.host, endpoint.port, endpoint.path
    )
    req.add_header(String("Host"), endpoint.host_header())
    req.add_header(String("Content-Type"), String(FORM_CONTENT_TYPE))
    req.set_body_text(body)
    return req^


def service_account_grant_request(
    key: ServiceAccountKey, assertion: String
) -> TokenHttpRequest:
    """The POST of the JWT bearer grant to the key's token URI:
    `grant_type=<jwt-bearer>&assertion=<jwt>`, form-encoded."""
    return _form_post(
        key.token_endpoint,
        String("grant_type=")
        + _form_encode(String(JWT_BEARER_GRANT_TYPE))
        + "&assertion="
        + _form_encode(assertion),
    )


def authorized_user_refresh_request(
    user: AuthorizedUser, scopes: List[String]
) -> TokenHttpRequest:
    """The POST of the refresh-token grant to the file's token URI:
    `grant_type`, `client_id`, `client_secret`, `refresh_token`, and `scope`
    (space-joined) when scopes are given, in google-auth's order
    (`google/oauth2/_client.py`, `refresh_grant`)."""
    var body = (
        String("grant_type=")
        + _form_encode(String(REFRESH_GRANT_TYPE))
        + "&client_id="
        + _form_encode(user.client_id)
        + "&client_secret="
        + _form_encode(user.client_secret)
        + "&refresh_token="
        + _form_encode(user.refresh_token)
    )
    if len(scopes) > 0:
        body += "&scope=" + _form_encode(_scope_claim(scopes))
    return _form_post(user.token_endpoint, body)
