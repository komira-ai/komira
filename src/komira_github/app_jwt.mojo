# =============================================================================
# komira_github/app_jwt.mojo -- the GitHub App's own credential: an RS256 JWT
#   signed with the App's private key.
# =============================================================================
#
# GitHub's rules for the App JWT ("Generating a JSON Web Token (JWT) for a
# GitHub App"):
#   * header `{"alg":"RS256","typ":"JWT"}`, signed with the App's RSA key;
#   * `iss` is the App's client ID or App ID;
#   * `exp` is no more than 10 minutes into the future;
#   * `iat` should be set 60 seconds in the past against clock drift.
#
# So a JWT minted at `now` carries `iat = now - 60` and `exp = now + 540`:
# its whole span is the 600 seconds GitHub allows, and `exp` is a minute
# short of GitHub's limit should this host's clock run ahead of GitHub's.
#
# `check_app_jwt_window(iat, exp, now)` is the rule a JWT must meet at the
# moment it is sent; it refuses an expired JWT, one whose `exp` is more
# than 600 seconds ahead or more than 600 seconds after its `iat`, and one
# issued in the future. The client checks every JWT against it before
# sending, and re-mints one with `APP_JWT_REMINT_MARGIN_S` or fewer
# seconds left (`app_jwt_needs_remint`), so a JWT that would expire in
# flight is never sent. komira_github_fake refuses a JWT by the same rule.
#
# The key is a PKCS#8 `PRIVATE KEY` (komira_crypto's `rsa_sha256_sign`
# form); `AppCredentials.from_pem` reads the PEM GitHub's settings page
# gives once it is converted from PKCS#1 (`openssl pkcs8 -topk8 -nocrypt`;
# komira_crypto names that conversion when it refuses an `RSA PRIVATE KEY`
# block). The key bytes are wiped when the credentials are destroyed.
# =============================================================================

from komira_crypto import rsa_pkcs8_der_from_pem, rsa_sha256_sign, zeroize_list
from komira_encoding import base64_url_encode_nopad

from .error import KIND_AUTH, KIND_BAD_INPUT, github_error


comptime APP_JWT_BACKDATE_S: Int64 = 60
"""`iat` is this many seconds before the minting instant."""
comptime APP_JWT_TTL_S: Int64 = 540
"""`exp` is this many seconds after the minting instant."""
comptime APP_JWT_MAX_SPAN_S: Int64 = 600
"""GitHub's limit: `exp` at most 10 minutes ahead (and after `iat`)."""
comptime APP_JWT_REMINT_MARGIN_S: Int64 = 60
"""A cached JWT with fewer seconds than this left is replaced, not sent."""
comptime APP_JWT_HEADER_JSON: String = '{"alg":"RS256","typ":"JWT"}'


def _check_issuer(issuer: String) raises:
    """A client ID (`Iv1.` followed by hex, `Iv23` and letters) or an App ID
    (digits): a non-empty run of `[A-Za-z0-9.]`, at most 64 bytes. The value
    is written into JSON unescaped, so nothing else may pass."""
    var b = issuer.as_bytes()
    if len(b) == 0 or len(b) > 64:
        raise github_error(
            KIND_BAD_INPUT, "the App issuer (client ID or App ID) is empty or longer than 64 bytes"
        )
    for i in range(len(b)):
        var c = b[i]
        var ok = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("."))
        )
        if not ok:
            raise github_error(
                KIND_BAD_INPUT, "the App issuer holds a byte outside [A-Za-z0-9.]"
            )


struct AppCredentials(Movable, Deinitable):
    """The App's issuer (client ID or App ID) and its PKCS#8 RSA private key.
    The key is wiped when this is destroyed."""

    var issuer: String
    var _pkcs8_der: List[UInt8]

    def __init__(out self, var issuer: String, var pkcs8_der: List[UInt8]) raises:
        """Refused: an issuer outside `[A-Za-z0-9.]{1,64}`, an empty key."""
        _check_issuer(issuer)
        if len(pkcs8_der) == 0:
            raise github_error(KIND_BAD_INPUT, "the App private key is empty")
        self.issuer = issuer^
        self._pkcs8_der = pkcs8_der^

    @staticmethod
    def from_pem(var issuer: String, pem: String) raises -> AppCredentials:
        """The credentials from a PEM `PRIVATE KEY` block (komira_crypto's
        `rsa_pkcs8_der_from_pem`, which names the conversion for a PKCS#1
        or encrypted block)."""
        return AppCredentials(issuer^, rsa_pkcs8_der_from_pem(pem))

    def __deinit__(deinit self):
        zeroize_list(self._pkcs8_der)

    def sign(self, signing_input: String) raises -> List[UInt8]:
        """RS256 over `signing_input` with the App key."""
        return rsa_sha256_sign(
            Span[UInt8, origin_of(self._pkcs8_der)](self._pkcs8_der),
            signing_input.as_bytes(),
        )


struct AppJwt(Copyable, Movable, Deinitable):
    """A minted App JWT and the two times it carries."""

    var token: String
    var iat: Int64
    var exp: Int64

    def __init__(out self, var token: String, iat: Int64, exp: Int64):
        self.token = token^
        self.iat = iat
        self.exp = exp


def app_jwt_payload_json(issuer: String, iat: Int64, exp: Int64) -> String:
    """The claims exactly as signed: `{"iat":<iat>,"exp":<exp>,"iss":"<iss>"}`."""
    return (
        String('{"iat":')
        + String(iat)
        + String(',"exp":')
        + String(exp)
        + String(',"iss":"')
        + issuer
        + String('"}')
    )


def mint_app_jwt(creds: AppCredentials, now_unix_s: Int64) raises -> AppJwt:
    """An App JWT for the instant `now_unix_s`: `iat = now - 60`,
    `exp = now + 540` (module header)."""
    var iat = now_unix_s - APP_JWT_BACKDATE_S
    var exp = now_unix_s + APP_JWT_TTL_S
    var h = base64_url_encode_nopad(String(APP_JWT_HEADER_JSON).as_bytes())
    var payload = app_jwt_payload_json(creds.issuer, iat, exp)
    var p = base64_url_encode_nopad(payload.as_bytes())
    var signing_input = h + String(".") + p
    var sig: List[UInt8]
    try:
        sig = creds.sign(signing_input)
    except:
        # komira_crypto's text names the key's shape; nothing of the key.
        raise github_error(KIND_AUTH, "the App JWT could not be signed with the App key")
    var token = (
        signing_input
        + String(".")
        + base64_url_encode_nopad(Span[UInt8, origin_of(sig)](sig))
    )
    return AppJwt(token^, iat, exp)


def check_app_jwt_window(iat: Int64, exp: Int64, now_unix_s: Int64) raises:
    """Raises `GitHubError[AUTH]` unless a JWT with these times may be sent
    at `now_unix_s`: not expired (`exp > now`), not issued in the future
    (`iat <= now`, so `exp` is after `iat`), and neither `exp - now` nor
    `exp - iat` above 600 seconds."""
    if exp <= now_unix_s:
        raise github_error(KIND_AUTH, "the App JWT has expired (exp is not after now)")
    if iat > now_unix_s:
        raise github_error(KIND_AUTH, "the App JWT is issued in the future (iat is after now)")
    if exp - now_unix_s > APP_JWT_MAX_SPAN_S:
        raise github_error(KIND_AUTH, "the App JWT's exp is more than 10 minutes ahead")
    if exp - iat > APP_JWT_MAX_SPAN_S:
        raise github_error(KIND_AUTH, "the App JWT spans more than 10 minutes")


def app_jwt_needs_remint(jwt: AppJwt, now_unix_s: Int64) -> Bool:
    """True when a cached JWT must be replaced before it is sent:
    `APP_JWT_REMINT_MARGIN_S` (60) seconds or fewer left, or issued after
    `now` (the clock went back)."""
    if jwt.iat > now_unix_s:
        return True
    return now_unix_s >= jwt.exp - APP_JWT_REMINT_MARGIN_S
