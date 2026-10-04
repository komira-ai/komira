# =============================================================================
# test_token_wire.mojo — the token requests and responses, byte for byte.
# =============================================================================
#
# token_wire.mojo is pure, so every case here is a value in and a value out:
#
#   * the key file: Google's published dummy service-account key (read from
#     the conformance-tests archive //third_party/googleapis_conformance_tests
#     pins, staged at conformance/; not copied here) parses, and every
#     malformed variant is refused by name without echoing a value;
#   * the RS256 JWTs: the header and claims decode to the exact JSON
#     google-auth writes (compactly), and the signature of each equals the one
#     an independent RSA implementation (OpenSSL, through Python's
#     `cryptography`) computed over the same signing input with the same key;
#   * each request: the metadata GET (default host, a GCE_METADATA_HOST
#     host:port, scopes), the probe, the JWT bearer grant and the
#     refresh-token grant, on the wire;
#   * the token response: `expires_in` to expiry on the caller's clock, and
#     every malformed or failed answer refused, naming at most an RFC 6749
#     error code and never a token, a description or a body byte.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import base64_url_decode_nopad
from komira_gcp_core import (
    GOOGLE_OAUTH2_TOKEN_URI,
    JWT_LIFETIME_SECONDS,
    MAX_EXPIRES_IN_SECONDS,
    METADATA_DEFAULT_HOST,
    AuthorizedUser,
    ServiceAccountKey,
    TokenEndpoint,
    TokenHttpRequest,
    TokenHttpResponse,
    authorized_user_from_json,
    authorized_user_refresh_request,
    jwt_grant_assertion,
    metadata_endpoint,
    metadata_ping_answered,
    metadata_ping_request,
    metadata_token_request,
    parse_credentials_json,
    parse_service_account_key,
    parse_token_endpoint,
    parse_token_response,
    self_signed_jwt,
    service_account_grant_request,
)
from komira_json import JsonValue, parse_json_bytes


comptime _ACCOUNT = "conformance/storage/v1/test_service_account.not-a-test.json"
comptime _T0: Int64 = 1_790_000_000
comptime _CLOUD = "https://www.googleapis.com/auth/cloud-platform"
comptime _LOGGING_AUD = "https://logging.googleapis.com/"

# RS256 signatures of the dummy key over the signing inputs below, computed
# by OpenSSL through Python's `cryptography` (RSASSA-PKCS1-v1_5, SHA-256),
# base64url without padding. PKCS#1 v1.5 is deterministic: the same key and
# input give the same bytes. To reproduce both with the openssl CLI, with K
# the archive's storage/v1/test_service_account.not-a-test.json:
#
#   b64() { basenc --base64url -w0 | tr -d '='; }
#   jq -r .private_key "$K" > key.pem
#   KID=$(jq -r .private_key_id "$K"); EM=$(jq -r .client_email "$K")
#   H=$(printf '{"typ":"JWT","alg":"RS256","kid":"%s"}' "$KID" | b64)
#   C=$(printf '{"iat":1790000000,"exp":1790003600,"iss":"%s","aud":"https://oauth2.googleapis.com/token","scope":"https://www.googleapis.com/auth/cloud-platform"}' "$EM" | b64)
#   printf '%s.%s' "$H" "$C" | openssl dgst -sha256 -sign key.pem | b64    # _GRANT_SIG
#   C=$(printf '{"iss":"%s","sub":"%s","iat":1790000000,"exp":1790003600,"aud":"https://logging.googleapis.com/"}' "$EM" "$EM" | b64)
#   printf '%s.%s' "$H" "$C" | openssl dgst -sha256 -sign key.pem | b64    # _SELF_SIG
comptime _GRANT_SIG = (
    "WGf5rEAcb4ZueHBeG1tNAUatKL0lq3bK3jJqqvOWobSUE2YdqY3ohctvcFKh_1Xnc4seMid"
    "SQeuHBHtIdQx8WK3XetEOaZctvt0AAuIg5xnlMJYG6JBjw37oB6gZXhF-EimlEPpFSLOlSt"
    "9iEX5SajVpsC_BPjs47Sz5muV6dl7jb9gQpHbvoDYo_Y9fPd88ZItCHmZNtwP-spDxLZQ9b"
    "7K-f7L1ePCVkQsgpXWJyw2YnABRzVFJ3Qb9l9G-WQ2Wal36Q9f0xtUiGgmpv1M1HYVrMr5v"
    "fZVmkHCwmGJdm6cGL79GVLqmot0YMowsJJ_nxIAoc-fLHj_sDcO2tlouag"
)
"""The JWT bearer grant at `_T0` for `_CLOUD`."""

comptime _SELF_SIG = (
    "a6y4ySbLwaHoCWz0LKJFpuozv9CPKwvpiQPCFBekgVNcqXSTulbkcoZFise64c58hKiLi5D"
    "pwSGyI9HDatPbEcMKfOgi14u2Ab3v7JYIoEo-14WDFTApcrZ7Q0P4mTzF2YgSClhWabRyJb"
    "PbuFqDZuLEXwdom-d7dLoO2AOCB3Gsqw1fKk9sngigb43cq0qnPImyIiHAlvumRIj0I1sqz"
    "5w78eZZ3wVsXpe97gchUwlhNFAClcQVFGOL1TcL444Cl9U6eTEj3CFAbbbcRf5GppVS9QQL"
    "WlpQ30CRVeGwkkTpHVri6wXH3Z_a9BJML_BJSvV7QzV3NTj56UUrXpnRFA"
)
"""The self-signed JWT at `_T0` for the audience `_LOGGING_AUD`."""


# =============================================================================
# Helpers
# =============================================================================


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _account_text() raises -> String:
    return _read(String(_ACCOUNT))


def _account_doc() raises -> JsonValue:
    return parse_credentials_json(_account_text(), String("dummy.json"))


def _field(doc: JsonValue, name: String) raises -> String:
    return doc.get(name).as_string()


def _key() raises -> ServiceAccountKey:
    return parse_service_account_key(_account_text(), String("dummy.json"))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _text(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _segments(jwt: String) -> List[String]:
    var out = List[String]()
    for part in jwt.split("."):
        out.append(String(part))
    return out^


def _decoded(segment: String) raises -> String:
    return _text(base64_url_decode_nopad(segment))


def _scopes(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


def _no_scopes() -> List[String]:
    return List[String]()


def _response(status: Int, body: String) -> TokenHttpResponse:
    return TokenHttpResponse(status, _bytes(body))


def _parse_error(status: Int, body: String) -> String:
    try:
        _ = parse_token_response(_response(status, body), String("the endpoint E"), 0)
    except e:
        return String(e)
    return String("<no error>")


def _key_error(json: String) -> String:
    try:
        _ = parse_service_account_key(json, String("k.json"))
    except e:
        return String(e)
    return String("<no error>")


def _replace(s: String, old: String, new: String) -> String:
    return s.replace(old, new)


# =============================================================================
# The service-account key file
# =============================================================================


def test_dummy_key_parses() raises:
    var doc = _account_doc()
    var key = _key()
    assert_equal(key.client_email, _field(doc, String("client_email")))
    assert_equal(key.private_key_id, _field(doc, String("private_key_id")))
    assert_equal(key.token_uri, String(GOOGLE_OAUTH2_TOKEN_URI))
    assert_equal(key.token_endpoint.scheme, "https")
    assert_equal(key.token_endpoint.host, "oauth2.googleapis.com")
    assert_equal(key.token_endpoint.port, 443)
    assert_equal(key.token_endpoint.path, "/token")
    # A 2048-bit RSA key in PKCS#8 DER: a SEQUENCE, well over 1 KiB.
    assert_equal(Int(key.private_key_der[0]), 0x30)
    assert_true(len(key.private_key_der) > 1000)


def _minimal(pem: String) -> String:
    return (
        String('{"type":"service_account","client_email":"SECRET-ACCOUNT",')
        + '"private_key":"' + pem + '"}'
    )


def _pem_json_escaped() raises -> String:
    """The dummy key's PEM with its newlines escaped back for a JSON body."""
    var pem = _field(_account_doc(), String("private_key"))
    return pem.replace("\n", "\\n")


def test_key_defaults_and_refusals() raises:
    var pem = _pem_json_escaped()
    # token_uri absent: Google's; private_key_id absent: no kid.
    var key = parse_service_account_key(_minimal(pem), String("k.json"))
    assert_equal(key.token_uri, String(GOOGLE_OAUTH2_TOKEN_URI))
    assert_equal(key.private_key_id, "")
    var header = _decoded(_segments(jwt_grant_assertion(key, _scopes(_CLOUD), String(""), _T0))[0])
    assert_equal(header, '{"typ":"JWT","alg":"RS256"}')

    assert_equal(_key_error(String("[]")), "the credentials file k.json is not a JSON object")
    assert_equal(_key_error(String("{")), "the credentials file k.json is not JSON")
    assert_equal(
        _key_error(String('{"client_email":"a"}')),
        'the credentials file k.json has no "type"',
    )
    assert_equal(
        _key_error(String('{"type":"authorized_user"}')),
        "the credentials file k.json is not a service_account key",
    )
    assert_equal(
        _key_error(String('{"type":"service_account","private_key":"x"}')),
        'the credentials file k.json has no "client_email"',
    )
    assert_equal(
        _key_error(String('{"type":"service_account","client_email":"","private_key":"x"}')),
        "the credentials file k.json's \"client_email\" is not a non-empty string",
    )
    assert_equal(
        _key_error(String('{"type":"service_account","client_email":"a"}')),
        'the credentials file k.json has no "private_key"',
    )
    # A private key that is not PEM: refused, its bytes not repeated.
    var bad = _key_error(_minimal(String("not-a-key-SECRETBYTES")))
    assert_true(
        bad.startswith(
            "the credentials file k.json's private_key is not an RSA PKCS#8 PEM key"
        ),
        bad,
    )
    assert_false("SECRETBYTES" in bad, bad)
    # Another universe.
    var other = _replace(
        _minimal(pem), String('"type"'), String('"universe_domain":"example.test","type"')
    )
    assert_equal(
        _key_error(other),
        "the credentials file k.json is for the universe example.test;"
        " komira_gcp_core mints tokens for googleapis.com only",
    )
    var dflt = _replace(
        _minimal(pem), String('"type"'), String('"universe_domain":"googleapis.com","type"')
    )
    _ = parse_service_account_key(dflt, String("k.json"))
    # A token_uri that is not http(s).
    var ftp = _replace(
        _minimal(pem), String('"type"'), String('"token_uri":"ftp://x/token","type"')
    )
    assert_equal(
        _key_error(ftp),
        "the credentials file k.json's token_uri: the token URI is not an http"
        " or https URL",
    )


# =============================================================================
# The RS256 JWTs
# =============================================================================


def test_grant_assertion_matches_an_independent_signer() raises:
    var doc = _account_doc()
    var key = _key()
    var jwt = jwt_grant_assertion(key, _scopes(_CLOUD), String(""), _T0)
    var seg = _segments(jwt)
    assert_equal(len(seg), 3)
    assert_equal(
        _decoded(seg[0]),
        String('{"typ":"JWT","alg":"RS256","kid":"')
        + _field(doc, String("private_key_id"))
        + '"}',
    )
    assert_equal(
        _decoded(seg[1]),
        String('{"iat":1790000000,"exp":1790003600,"iss":"')
        + _field(doc, String("client_email"))
        + '","aud":"https://oauth2.googleapis.com/token","scope":"'
        + _CLOUD
        + '"}',
    )
    assert_equal(seg[2], String(_GRANT_SIG))


def test_grant_assertion_scopes_and_subject() raises:
    var key = _key()
    var scopes = List[String]()
    scopes.append(String("a"))
    scopes.append(String("b"))
    var claims = _decoded(
        _segments(jwt_grant_assertion(key, scopes, String("delegated-user"), _T0))[1]
    )
    assert_true(claims.endswith(',"scope":"a b","sub":"delegated-user"}'), claims)


def test_self_signed_jwt_matches_an_independent_signer() raises:
    var doc = _account_doc()
    var key = _key()
    var jwt = self_signed_jwt(key, String(_LOGGING_AUD), _no_scopes(), _T0)
    var seg = _segments(jwt)
    var email = _field(doc, String("client_email"))
    assert_equal(
        _decoded(seg[1]),
        String('{"iss":"') + email + '","sub":"' + email
        + '","iat":1790000000,"exp":1790003600,"aud":"' + _LOGGING_AUD + '"}',
    )
    assert_equal(seg[2], String(_SELF_SIG))


def test_self_signed_jwt_with_scopes() raises:
    var key = _key()
    var claims = _decoded(
        _segments(self_signed_jwt(key, String(""), _scopes(_CLOUD), _T0))[1]
    )
    assert_true(claims.endswith(',"exp":1790003600,"scope":"' + String(_CLOUD) + '"}'), claims)
    assert_false('"aud"' in claims, claims)
    var msg = String("")
    try:
        _ = self_signed_jwt(key, String(""), _no_scopes(), _T0)
    except e:
        msg = String(e)
    assert_equal(msg, "a self-signed JWT needs an audience or scopes")
    assert_equal(JWT_LIFETIME_SECONDS, 3600)


# =============================================================================
# The requests
# =============================================================================


def test_metadata_token_request_default_host() raises:
    var ep = metadata_endpoint(String(METADATA_DEFAULT_HOST))
    assert_equal(ep.url(), "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token")
    var req = metadata_token_request(ep, _no_scopes())
    assert_equal(req.scheme, "http")
    assert_equal(req.host, "metadata.google.internal")
    assert_equal(req.port, 80)
    assert_equal(
        req.to_wire(),
        "GET /computeMetadata/v1/instance/service-accounts/default/token HTTP/1.1\r\n"
        "Host: metadata.google.internal\r\n"
        "Metadata-Flavor: Google\r\n"
        "\r\n",
    )


def test_metadata_token_request_scopes_and_host_override() raises:
    var ep = metadata_endpoint(String("127.0.0.1:8080"))
    var scopes = List[String]()
    scopes.append(String(_CLOUD))
    scopes.append(String("https://www.googleapis.com/auth/logging.read"))
    var req = metadata_token_request(ep, scopes)
    assert_equal(req.host, "127.0.0.1")
    assert_equal(req.port, 8080)
    assert_equal(
        req.to_wire(),
        "GET /computeMetadata/v1/instance/service-accounts/default/token"
        "?scopes=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform%2C"
        "https%3A%2F%2Fwww.googleapis.com%2Fauth%2Flogging.read HTTP/1.1\r\n"
        "Host: 127.0.0.1:8080\r\n"
        "Metadata-Flavor: Google\r\n"
        "\r\n",
    )
    var v6 = metadata_endpoint(String("[::1]:9"))
    assert_equal(v6.host, "[::1]")
    assert_equal(v6.port, 9)
    assert_equal(metadata_endpoint(String("[::1]")).port, 80)


def _host_error(host: String) -> String:
    try:
        _ = metadata_endpoint(host)
    except e:
        return String(e)
    return String("<no error>")


def test_metadata_host_refusals() raises:
    assert_equal(_host_error(String("")), "the metadata server host: the host is empty")
    assert_equal(_host_error(String(":80")), "the metadata server host: the host is empty")
    assert_equal(
        _host_error(String("h:0")),
        "the metadata server host: the port is not a number from 1 to 65535",
    )
    assert_equal(
        _host_error(String("h:65536")),
        "the metadata server host: the port is not a number from 1 to 65535",
    )
    assert_equal(
        _host_error(String("h:x")),
        "the metadata server host: the port is not a number from 1 to 65535",
    )
    assert_equal(
        _host_error(String("u@h")),
        "the metadata server host: the host holds a byte a host cannot",
    )
    assert_equal(
        _host_error(String("h/p")),
        "the metadata server host: the host holds a byte a host cannot",
    )
    assert_equal(
        _host_error(String("[::1")),
        "the metadata server host: an IPv6 host has no closing bracket",
    )


def test_probe_request_and_answer() raises:
    var ep = TokenEndpoint(String("http"), String("169.254.169.254"), 80, String("/"))
    assert_equal(
        metadata_ping_request(ep).to_wire(),
        "GET / HTTP/1.1\r\nHost: 169.254.169.254\r\nMetadata-Flavor: Google\r\n\r\n",
    )
    var yes = _response(200, "")
    yes.add_header(String("metadata-flavor"), String("Google"))
    assert_true(metadata_ping_answered(yes))
    var no_header = _response(200, "")
    assert_false(metadata_ping_answered(no_header))
    var other = _response(200, "")
    other.add_header(String("Metadata-Flavor"), String("Other"))
    assert_false(metadata_ping_answered(other))
    var not_ok = _response(404, "")
    not_ok.add_header(String("Metadata-Flavor"), String("Google"))
    assert_false(metadata_ping_answered(not_ok))


def test_token_endpoint_parse() raises:
    var a = parse_token_endpoint(String("https://oauth2.googleapis.com/token"), String("t"))
    assert_equal(a.url(), "https://oauth2.googleapis.com/token")
    var b = parse_token_endpoint(String("http://127.0.0.1:8443/o/token?x=1"), String("t"))
    assert_equal(b.scheme, "http")
    assert_equal(b.host, "127.0.0.1")
    assert_equal(b.port, 8443)
    assert_equal(b.path, "/o/token?x=1")
    var c = parse_token_endpoint(String("https://h"), String("t"))
    assert_equal(c.path, "/")
    assert_equal(c.host_header(), "h")
    var msg = String("")
    try:
        _ = parse_token_endpoint(String("https://h/t#f"), String("t"))
    except e:
        msg = String(e)
    assert_equal(msg, "t: the token URI has a fragment")


def test_service_account_grant_request() raises:
    var key = _key()
    var jwt = jwt_grant_assertion(key, _scopes(_CLOUD), String(""), _T0)
    var req = service_account_grant_request(key, jwt)
    assert_equal(req.scheme, "https")
    assert_equal(req.port, 443)
    # A JWT is base64url and dots: every byte is unreserved, none encoded.
    assert_equal(
        req.to_wire(),
        String("POST /token HTTP/1.1\r\n")
        + "Host: oauth2.googleapis.com\r\n"
        + "Content-Type: application/x-www-form-urlencoded\r\n"
        + "\r\n"
        + "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"
        + "&assertion=" + jwt,
    )


comptime _USER = (
    '{"type":"authorized_user","client_id":"cid.apps.example.test",'
    '"client_secret":"s+cr/t=","refresh_token":"1//r t"}'
)


def test_authorized_user_refresh_request() raises:
    var user = authorized_user_from_json(
        parse_credentials_json(String(_USER), String("u.json")), String("u.json")
    )
    assert_equal(user.token_uri, String(GOOGLE_OAUTH2_TOKEN_URI))
    var req = authorized_user_refresh_request(user, _no_scopes())
    assert_equal(
        req.to_wire(),
        "POST /token HTTP/1.1\r\n"
        "Host: oauth2.googleapis.com\r\n"
        "Content-Type: application/x-www-form-urlencoded\r\n"
        "\r\n"
        "grant_type=refresh_token&client_id=cid.apps.example.test"
        "&client_secret=s%2Bcr%2Ft%3D&refresh_token=1%2F%2Fr+t",
    )
    var scopes = List[String]()
    scopes.append(String("a"))
    scopes.append(String("b"))
    var with_scope = authorized_user_refresh_request(user, scopes)
    assert_true(with_scope.body_text().endswith("&scope=a+b"), with_scope.body_text())


def test_authorized_user_refusals() raises:
    var msg = String("")
    try:
        _ = authorized_user_from_json(
            parse_credentials_json(
                String('{"type":"authorized_user","client_id":"c","client_secret":"s"}'),
                String("u.json"),
            ),
            String("u.json"),
        )
    except e:
        msg = String(e)
    assert_equal(msg, 'the credentials file u.json has no "refresh_token"')
    var custom = authorized_user_from_json(
        parse_credentials_json(
            String(
                '{"type":"authorized_user","client_id":"c","client_secret":"s",'
                '"refresh_token":"r","token_uri":"http://127.0.0.1:9/t"}'
            ),
            String("u.json"),
        ),
        String("u.json"),
    )
    assert_equal(custom.token_endpoint.url(), "http://127.0.0.1:9/t")


# =============================================================================
# The token response
# =============================================================================


def test_token_response_to_expiry() raises:
    var tok = parse_token_response(
        _response(
            200,
            '{"access_token":"ya29.TOKEN","expires_in":3599,"token_type":"Bearer"}',
        ),
        String("E"),
        5_000,
    )
    assert_equal(tok.token, "ya29.TOKEN")
    assert_equal(tok.expires_at_ms, 5_000 + 3_599_000)
    # A string of digits is read as its number (google-auth's `int()`).
    var s = parse_token_response(
        _response(200, '{"access_token":"ya29.TOKEN","expires_in":"3599"}'),
        String("E"),
        5_000,
    )
    assert_equal(s.expires_at_ms, 5_000 + 3_599_000)
    # The bound itself is accepted.
    var most = parse_token_response(
        _response(200, '{"access_token":"ya29.TOKEN","expires_in":31536000}'),
        String("E"),
        0,
    )
    assert_equal(most.expires_at_ms, MAX_EXPIRES_IN_SECONDS * 1000)
    assert_equal(MAX_EXPIRES_IN_SECONDS, 31_536_000)


def test_token_response_refusals() raises:
    assert_equal(
        _parse_error(200, "not json ya29.SECRET"),
        "the endpoint E answered 200 with a body that is not JSON",
    )
    assert_equal(
        _parse_error(200, '["ya29.SECRET"]'),
        "the endpoint E answered 200 with a body that is not a JSON object",
    )
    assert_equal(
        _parse_error(200, '{"expires_in":3599}'),
        "the endpoint E answered 200 with no access_token",
    )
    assert_equal(
        _parse_error(200, '{"access_token":7,"expires_in":3599}'),
        "the endpoint E answered 200 with an access_token that is not a string",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"","expires_in":3599}'),
        "the endpoint E answered 200 with an empty access_token",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET"}'),
        "the endpoint E answered 200 with no expires_in",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":"35x9"}'),
        "the endpoint E answered 200 with an expires_in that is not an integer",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":""}'),
        "the endpoint E answered 200 with an expires_in that is not an integer",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":"-5"}'),
        "the endpoint E answered 200 with an expires_in that is not an integer",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":"0"}'),
        "the endpoint E answered 200 with an expires_in that is not positive",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":31536001}'),
        "the endpoint E answered 200 with an expires_in out of range",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":9223372036854775807}'),
        "the endpoint E answered 200 with an expires_in out of range",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":"99999999999"}'),
        "the endpoint E answered 200 with an expires_in out of range",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":"9999999999999999999"}'),
        "the endpoint E answered 200 with an expires_in out of range",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":3599.5}'),
        "the endpoint E answered 200 with an expires_in that is not an integer",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":0}'),
        "the endpoint E answered 200 with an expires_in that is not positive",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":-5}'),
        "the endpoint E answered 200 with an expires_in that is not positive",
    )
    assert_equal(
        _parse_error(200, '{"access_token":"ya29.SECRET","expires_in":99999999999999999999}'),
        "the endpoint E answered 200 with an expires_in out of range",
    )


def test_token_error_names_only_the_code() raises:
    # RFC 6749 §5.2: the code is repeated, the description is not.
    var bad_grant = _parse_error(
        400,
        '{"error":"invalid_grant","error_description":"Invalid JWT for'
        ' SECRET-ACCOUNT"}',
    )
    assert_equal(bad_grant, "the endpoint E answered HTTP 400 (invalid_grant)")
    # A code that is not a plain code is not repeated.
    assert_equal(
        _parse_error(401, '{"error":"Bad thing: SECRET-ACCOUNT"}'),
        "the endpoint E answered HTTP 401",
    )
    assert_equal(
        _parse_error(500, "<html>ya29.SECRET</html>"),
        "the endpoint E answered HTTP 500",
    )
    assert_equal(
        _parse_error(404, '{"error":{"code":404,"message":"x"}}'),
        "the endpoint E answered HTTP 404",
    )


def main() raises:
    test_dummy_key_parses()
    test_key_defaults_and_refusals()
    test_grant_assertion_matches_an_independent_signer()
    test_grant_assertion_scopes_and_subject()
    test_self_signed_jwt_matches_an_independent_signer()
    test_self_signed_jwt_with_scopes()
    test_metadata_token_request_default_host()
    test_metadata_token_request_scopes_and_host_override()
    test_metadata_host_refusals()
    test_probe_request_and_answer()
    test_token_endpoint_parse()
    test_service_account_grant_request()
    test_authorized_user_refresh_request()
    test_authorized_user_refusals()
    test_token_response_to_expiry()
    test_token_response_refusals()
    test_token_error_names_only_the_code()
    print("OK")
