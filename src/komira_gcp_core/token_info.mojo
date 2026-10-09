# =============================================================================
# komira_gcp_core/token_info.mojo -- who an access token belongs to
# =============================================================================
#
# Google's OAuth 2.0 token-information endpoint answers, for an access token
# it issued, the principal the token acts as. No googleapis proto declares
# it, so no generated client can send it; it is hand-written here, beside
# the token requests, over the same `GcpHttpTransport` seam.
#
# THE REQUEST. A POST to `https://oauth2.googleapis.com/tokeninfo` with the
# form body `access_token=<token>`. The endpoint also takes the token in the
# query of a GET; the POST keeps the token out of the URL, so it is never in
# a request line a proxy or a log records.
#
# THE ANSWER. A 200 whose body is a JSON object. Each member read here is a
# string when present:
#   * `email`      the principal's address, present when the token carries
#                  the email scope or belongs to a service account;
#   * `sub`        the principal's stable id;
#   * `azp`        the OAuth client the token was issued to;
#   * `expires_in` seconds the token has left, a string of digits (a JSON
#                  number is taken too).
# `principal()` is the email, else the subject, else the authorized party.
# A 200 that names none of the three is refused: a check that cannot say
# who the caller is must not pass as one that did.
#
# ANY OTHER STATUS is refused naming the status and, when the body is an
# OAuth error object, its `error` word (`invalid_token`). No error repeats
# any other body byte: the body of a refusal can echo what was sent.
# =============================================================================

from komira_json import JsonValue, parse_json_bytes

from ._text import _form_encode
from .token_http import GcpHttpTransport, TokenHttpRequest, TokenHttpResponse
from .token_wire import FORM_CONTENT_TYPE


comptime TOKEN_INFO_HOST: StaticString = "oauth2.googleapis.com"
"""The token-information endpoint's host."""
comptime TOKEN_INFO_PATH: StaticString = "/tokeninfo"
"""The token-information endpoint's path."""
comptime _MAX_DEPTH: Int = 8


struct TokenInfo(Copyable, Movable, Deinitable):
    """What the token-information endpoint says of one access token: the
    principal's `email`, its `subject` id, the `authorized_party` client and
    the seconds it has left (`expires_in`, -1 when not said). Holds no
    token."""

    var email: String
    var subject: String
    var authorized_party: String
    var expires_in: Int

    def __init__(
        out self,
        email: String = String(""),
        subject: String = String(""),
        authorized_party: String = String(""),
        expires_in: Int = -1,
    ):
        self.email = email
        self.subject = subject
        self.authorized_party = authorized_party
        self.expires_in = expires_in

    def __init__(out self, *, copy: Self):
        self.email = copy.email.copy()
        self.subject = copy.subject.copy()
        self.authorized_party = copy.authorized_party.copy()
        self.expires_in = copy.expires_in

    def principal(self) -> String:
        """The email, else the subject, else the authorized party."""
        if self.email.byte_length() > 0:
            return self.email.copy()
        if self.subject.byte_length() > 0:
            return self.subject.copy()
        return self.authorized_party.copy()


def token_info_request(
    token: String,
    scheme: String = String("https"),
    host: String = String(TOKEN_INFO_HOST),
    port: Int = 443,
) -> TokenHttpRequest:
    """The POST that asks who `token` is: `access_token=<token>`,
    form-encoded, to `scheme://host:port/tokeninfo` (Google's endpoint by
    default; an emulator's in a test). Holds the token: never log it."""
    var req = TokenHttpRequest(String("POST"), scheme, host, port, String(TOKEN_INFO_PATH))
    var host_header = host.copy()
    if not ((scheme == "https" and port == 443) or (scheme == "http" and port == 80)):
        host_header = host + String(":") + String(port)
    req.add_header(String("Host"), host_header)
    req.add_header(String("Content-Type"), String(FORM_CONTENT_TYPE))
    req.set_body_text(String("access_token=") + _form_encode(token))
    return req^


def _string_member(doc: JsonValue, name: String) raises -> String:
    """Member `name` when it is a string, "" when absent; any other kind is
    refused."""
    if not doc.has(name):
        return String("")
    var v = doc.get(name)
    if not v.is_string():
        raise Error(String("token info answered 200 with a ") + name + String(" that is not a string"))
    return v.as_string()


def _is_word(s: String) -> Bool:
    """`[a-z_]{1,64}`: an OAuth error code, safe to repeat."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 64:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= ord("a") and c <= ord("z")) or c == ord("_")):
            return False
    return True


def _refusal(res: TokenHttpResponse) -> Error:
    """The error of a non-200 answer: the status, and the OAuth `error`
    word when the body is such an object; no other body byte."""
    var msg = String("token info refused: HTTP ") + String(res.status)
    try:
        var doc = parse_json_bytes(res.body, _MAX_DEPTH)
        if doc.is_object() and doc.has("error"):
            var e = doc.get("error")
            if e.is_string() and _is_word(e.as_string()):
                msg += String(" (") + e.as_string() + String(")")
    except:
        pass
    return Error(msg)


def _seconds(doc: JsonValue) raises -> Int:
    """`expires_in` as a count of seconds: a string of digits or a JSON
    integer; -1 when absent."""
    if not doc.has("expires_in"):
        return -1
    var v = doc.get("expires_in")
    var text: String
    if v.is_string():
        text = v.as_string()
    elif v.is_integral_number():
        return Int(v.as_int64())
    else:
        raise Error("token info answered 200 with an expires_in that is not a number")
    var b = text.as_bytes()
    if len(b) == 0 or len(b) > 9:
        raise Error("token info answered 200 with an expires_in that is not a number")
    var n = 0
    for i in range(len(b)):
        if b[i] < UInt8(0x30) or b[i] > UInt8(0x39):
            raise Error("token info answered 200 with an expires_in that is not a number")
        n = n * 10 + Int(b[i] - UInt8(0x30))
    return n


def parse_token_info(res: TokenHttpResponse) raises -> TokenInfo:
    """The answer of `token_info_request` (the file header): a 200 JSON
    object naming a principal, else an error that repeats no body byte but
    an OAuth error word."""
    if res.status != 200:
        raise _refusal(res)
    var doc: JsonValue
    try:
        doc = parse_json_bytes(res.body, _MAX_DEPTH)
    except:
        raise Error("token info answered 200 with a body that is not JSON")
    if not doc.is_object():
        raise Error("token info answered 200 with a body that is not a JSON object")
    var info = TokenInfo(
        _string_member(doc, String("email")),
        _string_member(doc, String("sub")),
        _string_member(doc, String("azp")),
        _seconds(doc),
    )
    if info.principal().byte_length() == 0:
        raise Error("token info answered 200 naming no principal (no email, sub or azp)")
    return info^


def fetch_token_info[
    X: GcpHttpTransport
](
    mut transport: X,
    token: String,
    scheme: String = String("https"),
    host: String = String(TOKEN_INFO_HOST),
    port: Int = 443,
) raises -> TokenInfo:
    """Ask the token-information endpoint who `token` is, over `transport`
    (`token_info_request`, then `parse_token_info`)."""
    return parse_token_info(transport.send(token_info_request(token, scheme, host, port)))
