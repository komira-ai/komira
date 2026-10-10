# =============================================================================
# src/kci_pkg_upload/github_oidc_credential.mojo — `GithubOidcCredential`:
#   trusted publishing from a GitHub Actions job. No long-lived token exists;
#   the job's OIDC identity token is exchanged for a short-lived upload token.
# =============================================================================
#
# THE TWO STEPS, each one request over the credential's own transport:
#
#   1. the ID token. GET <ACTIONS_ID_TOKEN_REQUEST_URL>&audience=<aud>
#      (the URL already carries `?api-version=...`), header
#      `Authorization: Bearer <ACTIONS_ID_TOKEN_REQUEST_TOKEN>`; the answer is
#      JSON `{"value": "<jwt>"}`. Both variables exist only in a job granted
#      `permissions: id-token: write`.
#   2. the exchange, per surface:
#      PREFIX_DEV   audience `prefix.dev` for prefix.dev and *.prefix.dev, the
#                   server's host name otherwise;
#                   POST https://<host>/api/oidc/mint_token, JSON
#                   `{"token": "<jwt>"}`; a 2xx BODY is the token, raw (not
#                   JSON), presented as `Bearer <token>`.
#      PYPI_UPLOAD  GET https://<index>/_/oidc/audience -> `{"audience": ...}`;
#                   POST https://<index>/_/oidc/mint-token, JSON
#                   `{"token": "<jwt>"}` -> `{"token": "<upload token>"}`,
#                   presented as Basic `__token__:<token>`.
#
# ⚠ The prefix.dev raw-body shape is the reference client's (rattler); it is
# UNVERIFIED against a live exchange. A 2xx body that is empty, or holds
# whitespace, a quote or a non-ASCII byte, is REFUSED rather than guessed at.
#
# THE ONLY ENVIRONMENT READ IN THIS PACKAGE is `from_actions_env`: the two
# handshake variables the Actions runner sets for this purpose. Everything
# else — which server, which index, which environment is required — arrives
# from the caller. Tests construct the credential explicitly.
#
# ⛔ NOTHING SECRET IS EVER PRINTED. The request token, the JWT and the minted
# token are held in zeroizing `SecretValue`s, and every refusal that quotes a
# server answer passes through `withhold_if_echoes` / `excerpt_unless_echoes`
# against each of them.
#
# THE CLAIMS ARE DECODED, NOT VERIFIED. The registry verifies the JWT; this
# credential reads its payload only to state who it is (`claims()`) and to
# refuse, BEFORE any exchange, a token whose `environment` claim is not the one
# the caller requires (`with_required_environment`) — a second check beside the
# registry's own trusted-publisher restriction, never instead of it.
#
# THE ID-TOKEN REQUEST IS RETRIED; nothing else is. The runner's token
# service is a GET with no effect, and a release job that cannot reach it on
# the first try (a connect timeout, a 5xx, a 429) would otherwise fail the
# whole PUBLISH step. `ID_TOKEN_RETRY_*` bound it: at most 4 sends; before
# retry n a full-jitter wait drawn from [0, 1 s], [0, 2 s], [0, 4 s]; a
# `Retry-After` of delta-seconds up to 10 s waited out when it is longer, one
# over 10 s final after that send; nothing started past 60 s from the first
# send. Any other answer (a 403: the job lacks `id-token: write`; a 404; a
# malformed body) is final at once. The exchanges that MINT a token are not retried. The
# credential waits through the caller's `Sleeper` (komira_retry), so a test
# never sleeps and a binary that links komira_async picks a sleeper that
# does not redeclare `nanosleep`.
#
# Minting is lazy: the first `authorization(surface, host)` fetches one ID token per
# audience and mints once; later calls reuse the minted token. The token is
# presented only to the host it was minted at: the prefix.dev host for
# PREFIX_DEV, the python index's host for PYPI_UPLOAD. Any other host is
# refused before minting.
#
# Encapsulation: owned values; no pointer, no wildcard origin.
# =============================================================================

from komira_libc.posix import _read_env

from komira_encoding import base64_url_decode
from komira_http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST
from komira_json import JSON_STRING, JsonValue, parse_json_value, write_json_string
from komira_retry import (
    MAX_WAIT_MS,
    Backoff,
    Jitter,
    RetryLoop,
    RetryPolicy,
    Sleeper,
    SplitMix64Rng,
    SystemClock,
    Verdict,
)
from komira_secret_store import SecretValue

from .coordinate import repo_host, repo_path
from .credential import (
    SURFACE_PREFIX_DEV,
    SURFACE_PYPI_UPLOAD,
    RegistryCredential,
    bearer_authorization,
    pypi_upload_authorization,
    refuse_other_host,
    refuse_surface,
)
from .identity import ascii_lower
from .outcome import excerpt_unless_echoes, withhold_if_echoes
from .transport import PkgRequest, PkgResponse, PkgTransport, try_exchange
from .wire import bytes_of, decode_utf8


comptime ACTIONS_ID_TOKEN_REQUEST_URL: StaticString = "ACTIONS_ID_TOKEN_REQUEST_URL"
comptime ACTIONS_ID_TOKEN_REQUEST_TOKEN: StaticString = "ACTIONS_ID_TOKEN_REQUEST_TOKEN"
comptime PREFIX_DEV_MINT_PATH: String = "/api/oidc/mint_token"
comptime PYPI_OIDC_AUDIENCE_PATH: String = "/_/oidc/audience"
comptime PYPI_OIDC_MINT_PATH: String = "/_/oidc/mint-token"
comptime PREFIX_DEV_AUDIENCE: String = "prefix.dev"
comptime ID_TOKEN_RETRY_MAX_ATTEMPTS: Int = 4
comptime ID_TOKEN_RETRY_INITIAL_MS: Int64 = 1000
comptime ID_TOKEN_RETRY_MAX_MS: Int64 = 4000
comptime ID_TOKEN_RETRY_DEADLINE_MS: Int64 = 60_000
comptime ID_TOKEN_RETRY_MAX_SERVER_DELAY_MS: Int64 = 10_000


def id_token_retry_policy() raises -> RetryPolicy:
    """How the ID-token request is retried (file header)."""
    return RetryPolicy(
        Backoff(
            initial_ms=ID_TOKEN_RETRY_INITIAL_MS,
            multiplier=2.0,
            max_ms=ID_TOKEN_RETRY_MAX_MS,
            jitter=Jitter.full(),
        ),
        max_attempts=ID_TOKEN_RETRY_MAX_ATTEMPTS,
        deadline_ms=ID_TOKEN_RETRY_DEADLINE_MS,
        max_server_delay_ms=ID_TOKEN_RETRY_MAX_SERVER_DELAY_MS,
    )


def _retry_after_ms(resp: PkgResponse) -> Int64:
    """A `Retry-After` of delta-seconds, in ms; -1 when absent or not
    digits (an HTTP-date is not honoured: the backoff applies). More than 6
    digits saturates to `MAX_WAIT_MS`, over any limit, never to absent."""
    var v = String(resp.header(String("Retry-After")).strip())
    var b = v.as_bytes()
    if len(b) == 0:
        return -1
    for i in range(len(b)):
        if b[i] < UInt8(ord("0")) or b[i] > UInt8(ord("9")):
            return -1
    if len(b) > 6:
        return MAX_WAIT_MS
    var secs = Int64(0)
    for i in range(len(b)):
        secs = secs * 10 + Int64(Int(b[i]) - ord("0"))
    return secs * 1000


def id_token_verdict(ok: Bool, resp: PkgResponse, fault: String) -> Verdict:
    """One failed ID-token send, read for the retry loop: a transport fault
    and a 5xx are transient, a 429 is a throttle (with its `Retry-After`),
    any other status is final. The reason is never shown: the caller's error
    is built from the last answer."""
    if not ok:
        return Verdict.transient(String("fault: ") + fault)
    var status = resp.status
    if status == 429:
        return Verdict.throttle(String("HTTP 429"), _retry_after_ms(resp))
    if status >= 500 and status <= 599:
        return Verdict.transient(String("HTTP ") + String(status), _retry_after_ms(resp))
    return Verdict.stop(String("HTTP ") + String(status))


def _after_attempts(n: Int) -> String:
    """` (after N attempts)` when the request was retried, else empty."""
    if n <= 1:
        return String("")
    return String(" (after ") + String(n) + String(" attempts)")


def prefix_dev_audience(host: String) -> String:
    """The OIDC audience a prefix.dev server expects: `prefix.dev` for
    prefix.dev and every *.prefix.dev host, the host name otherwise."""
    var h = ascii_lower(host)
    if h == String(PREFIX_DEV_AUDIENCE) or h.endswith(String(".prefix.dev")):
        return String(PREFIX_DEV_AUDIENCE)
    return h^


def _percent_encode(s: String) -> String:
    """RFC 3986 unreserved bytes as is, every other byte `%XX`."""
    var hex = String("0123456789ABCDEF")
    var hb = hex.as_bytes()
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        var unreserved = (
            (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
            or (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
            or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
            or c == UInt8(ord("-"))
            or c == UInt8(ord("."))
            or c == UInt8(ord("_"))
            or c == UInt8(ord("~"))
        )
        if unreserved:
            out += chr(Int(c))
        else:
            out += String("%") + chr(Int(hb[Int(c >> 4)])) + chr(Int(hb[Int(c & 15)]))
    return out^


struct IdTokenEndpoint(Copyable, Movable, Deinitable):
    """Where the ID token is requested: the host, and the path WITH its query.

    Layout: two owned Strings. No pointer field."""

    var host: String
    var path_and_query: String

    def __init__(out self, var host: String, var path_and_query: String):
        self.host = host^
        self.path_and_query = path_and_query^

    @staticmethod
    def parse(request_url: String) raises -> IdTokenEndpoint:
        """`https://<host><path>?<query>` split into host and path. RAISES
        (naming the variable, never the URL: it is the runner's) unless it is
        an https URL with a host, no port, no userinfo and a path."""
        var scheme = String("https://")
        if not request_url.startswith(scheme):
            raise Error(
                String("GithubOidcCredential: the ID-token request URL is not")
                + String(" an https:// URL")
            )
        var rest = String(request_url[byte = scheme.byte_length() :])
        var slash = rest.find(String("/"))
        if slash <= 0:
            raise Error(
                String("GithubOidcCredential: the ID-token request URL has no")
                + String(" host or no path")
            )
        var host = String(rest[byte=:slash])
        if host.find(String(":")) >= 0 or host.find(String("@")) >= 0:
            raise Error(
                String("GithubOidcCredential: the ID-token request URL names")
                + String(" a port or userinfo")
            )
        return IdTokenEndpoint(host^, String(rest[byte=slash:]))

    def path_for(self, audience: String) -> String:
        """The request path for `audience`, appended as a query parameter."""
        var sep = String("&")
        if self.path_and_query.find(String("?")) < 0:
            sep = String("?")
        return (
            self.path_and_query
            + sep
            + String("audience=")
            + _percent_encode(audience)
        )


struct OidcClaims(Copyable, Movable, Deinitable):
    """The JWT payload claims this credential reads. EMPTY = absent.

    Layout: owned Strings. No pointer field."""

    var repository: String
    var job_workflow_ref: String
    var environment: String
    var git_ref: String

    def __init__(out self):
        self.repository = String("")
        self.job_workflow_ref = String("")
        self.environment = String("")
        self.git_ref = String("")


def _string_claim(doc: JsonValue, name: String) raises -> String:
    if not doc.has(name):
        return String("")
    var v = doc.get(name)
    if v.kind_tag() != JSON_STRING:
        raise Error(
            String("GithubOidcCredential: '")
            + name
            + String("' is not a string")
        )
    return v.as_string()


def decode_jwt_claims(jwt: String) raises -> OidcClaims:
    """The payload claims of a compact JWS, DECODED, NOT VERIFIED. RAISES
    (never quoting the token) when it is not three base64url segments with a
    JSON object payload."""
    var first = jwt.find(String("."))
    var second = -1
    if first > 0:
        second = jwt.find(String("."), first + 1)
    if first <= 0 or second <= first + 1 or jwt.find(String("."), second + 1) >= 0:
        raise Error("GithubOidcCredential: the ID token is not a compact JWT")
    var payload = List[UInt8]()
    try:
        payload = base64_url_decode(String(jwt[byte = first + 1 : second]))
    except:
        raise Error(
            "GithubOidcCredential: the ID token's payload is not base64url"
        )
    var doc = parse_json_value(decode_utf8(Span(payload), String("the ID token's payload")))
    if not doc.is_object():
        raise Error("GithubOidcCredential: the ID token's payload is not an object")
    var c = OidcClaims()
    c.repository = _string_claim(doc, String("repository"))
    c.job_workflow_ref = _string_claim(doc, String("job_workflow_ref"))
    c.environment = _string_claim(doc, String("environment"))
    c.git_ref = _string_claim(doc, String("ref"))
    return c^


def _json_token_body(jwt: String) -> List[UInt8]:
    var out = bytes_of(String('{"token":'))
    write_json_string(out, jwt)
    out.extend(String("}").as_bytes())
    return out^


def _as_bearer(secret: String) -> String:
    """A secret in the `Authorization` shape `withhold_if_echoes` reads, so
    the secret itself is one of the shapes it withholds."""
    return String("Bearer ") + secret


def _secret_string(v: SecretValue) -> String:
    return String(unsafe_from_utf8=v.revealed_bytes())


def _refuse_raw_token(body: List[UInt8], what: String) raises:
    """A raw-body token must be a non-empty run of printable, non-space,
    non-quote ASCII."""
    if len(body) == 0:
        raise Error(String("GithubOidcCredential: ") + what + String(" answered an EMPTY token"))
    for i in range(len(body)):
        var c = body[i]
        if c <= UInt8(32) or c >= UInt8(127) or c == UInt8(ord('"')) or c == UInt8(ord("'")):
            raise Error(
                String("GithubOidcCredential: ")
                + what
                + String(
                    " answered a body that is not a bare token (whitespace, a"
                    " quote or a non-ASCII byte); it is refused, not guessed at"
                )
            )


struct GithubOidcCredential[T: PkgTransport, S: Sleeper](RegistryCredential, Deinitable):
    """Trusted publishing from a GitHub Actions job (see the file header).

    `prefix_dev_host` — the prefix.dev server host whose mint endpoint serves
                        PREFIX_DEV; EMPTY = PREFIX_DEV is not served.
    `pypi_index`      — the warehouse (`pypi.org`, `test.pypi.org`) whose mint
                        endpoint serves PYPI_UPLOAD; EMPTY = not served.
    `S`               — the `Sleeper` the ID-token retry waits through.

    Layout: the transport and the retry loop by value, owned Strings, zeroizing `SecretValue`s
    and Bools. No pointer field."""

    var _transport: Self.T
    var _id_token_retry: RetryLoop[SystemClock, Self.S, SplitMix64Rng]
    var _endpoint: IdTokenEndpoint
    var _request_token: SecretValue
    var _prefix_dev_host: String
    var _pypi_index: String
    var _required_environment: String
    var _prefix_token: SecretValue
    var _has_prefix_token: Bool
    var _pypi_token: SecretValue
    var _has_pypi_token: Bool
    var _claims: OidcClaims
    var _has_claims: Bool

    def __init__(
        out self,
        var transport: Self.T,
        var sleeper: Self.S,
        request_url: String,
        var request_token: SecretValue,
        var prefix_dev_host: String,
        var pypi_index: String,
    ) raises:
        """Explicit construction (tests; a caller that read the handshake
        some other way). RAISES for a malformed request URL, an empty request
        token, or neither surface served."""
        if request_token.is_empty():
            raise Error(
                String("GithubOidcCredential: the ID-token request token is EMPTY")
            )
        if prefix_dev_host.byte_length() == 0 and pypi_index.byte_length() == 0:
            raise Error(
                String("GithubOidcCredential: serves no surface: name a")
                + String(" prefix.dev host, a python index, or both")
            )
        if pypi_index.byte_length() > 0:
            _ = repo_host(pypi_index)
        if prefix_dev_host.byte_length() > 0:
            if repo_path(prefix_dev_host).byte_length() > 0:
                raise Error(
                    String("GithubOidcCredential: the prefix.dev host '")
                    + prefix_dev_host
                    + String("' must be a bare host")
                )
        self._endpoint = IdTokenEndpoint.parse(request_url)
        self._transport = transport^
        self._id_token_retry = RetryLoop[SystemClock, Self.S, SplitMix64Rng](
            id_token_retry_policy(),
            SystemClock(),
            sleeper^,
            SplitMix64Rng.seeded_from_clock(),
        )
        self._request_token = request_token^
        self._prefix_dev_host = prefix_dev_host^
        self._pypi_index = pypi_index^
        self._required_environment = String("")
        self._prefix_token = SecretValue(Span(List[UInt8]()))
        self._has_prefix_token = False
        self._pypi_token = SecretValue(Span(List[UInt8]()))
        self._has_pypi_token = False
        self._claims = OidcClaims()
        self._has_claims = False

    @staticmethod
    def from_actions_env(
        var transport: Self.T,
        var sleeper: Self.S,
        var prefix_dev_host: String,
        var pypi_index: String,
    ) raises -> GithubOidcCredential[Self.T, Self.S]:
        """From the Actions runner's two handshake variables — the ONLY
        environment this package reads. RAISES naming each one that is unset
        or empty: the job lacks `permissions: id-token: write`, or is not a
        GitHub Actions job."""
        # Read through komira_libc, the one getenv declaration: a second
        # (std.os.getenv) in the same binary is a conflicting-signature
        # link error once komira_libc is linked too (bin/kci links both).
        var url = _read_env(ACTIONS_ID_TOKEN_REQUEST_URL)
        var token = _read_env(ACTIONS_ID_TOKEN_REQUEST_TOKEN)
        var missing = String("")
        if url.byte_length() == 0:
            missing += String(ACTIONS_ID_TOKEN_REQUEST_URL)
        if token.byte_length() == 0:
            if missing.byte_length() > 0:
                missing += String(", ")
            missing += String(ACTIONS_ID_TOKEN_REQUEST_TOKEN)
        if missing.byte_length() > 0:
            raise Error(
                String("GithubOidcCredential: ")
                + missing
                + String(
                    " not set. Trusted publishing needs a GitHub Actions job"
                    " with `permissions: id-token: write`"
                )
            )
        var secret = SecretValue.from_string(token)
        return GithubOidcCredential[Self.T, Self.S](
            transport^, sleeper^, url, secret^, prefix_dev_host^, pypi_index^
        )

    def with_required_environment(mut self, var environment: String):
        """Refuse, before any exchange, an ID token whose `environment` claim
        is not `environment`. EMPTY = no requirement."""
        self._required_environment = environment^

    def transport(ref self) -> ref [self._transport] Self.T:
        """Borrow the transport (a test asserts over the conversation)."""
        return self._transport

    def id_token_retry(
        ref self,
    ) -> ref [self._id_token_retry] RetryLoop[SystemClock, Self.S, SplitMix64Rng]:
        """Borrow the ID-token retry loop (a test reads its sleeper and
        attempts)."""
        return self._id_token_retry

    def has_claims(self) -> Bool:
        return self._has_claims

    def claims(self) -> OidcClaims:
        """The claims of the last ID token fetched (EMPTY fields before
        any)."""
        return self._claims.copy()

    def _fetch_id_token(mut self, audience: String) raises -> SecretValue:
        var req = PkgRequest(
            HTTP_METHOD_GET,
            self._endpoint.host.copy(),
            self._endpoint.path_for(audience),
        )
        req.with_header(String("Accept"), String("application/json"))
        var auth = _as_bearer(_secret_string(self._request_token))
        req.with_authorization(auth)
        self._id_token_retry.start()
        var ex = try_exchange(self._transport, req)
        while not (ex.ok and ex.response.status == 200):
            var d = self._id_token_retry.after_failure(
                id_token_verdict(ex.ok, ex.response, ex.fault)
            )
            if not d.retry:
                break
            ex = try_exchange(self._transport, req)
        var tries = _after_attempts(self._id_token_retry.attempts())
        if not ex.ok:
            raise Error(
                withhold_if_echoes(
                    String("GithubOidcCredential: the ID-token request faulted")
                    + tries
                    + String(": ")
                    + ex.fault,
                    auth,
                )
            )
        if ex.response.status != 200:
            raise Error(
                withhold_if_echoes(
                    String("GithubOidcCredential: the ID-token request answered HTTP ")
                    + String(ex.response.status)
                    + tries
                    + String(": ")
                    + excerpt_unless_echoes(ex.response.body, auth),
                    auth,
                )
            )
        var jwt = _value_of_id_token_answer(ex.response)
        var claims = decode_jwt_claims(_secret_string(jwt))
        self._claims = claims^
        self._has_claims = True
        if self._required_environment.byte_length() > 0:
            if self._claims.environment != self._required_environment:
                raise Error(
                    String("GithubOidcCredential: the job's environment is '")
                    + self._claims.environment
                    + String("', not the required '")
                    + self._required_environment
                    + String("'. No token was exchanged")
                )
        return jwt^

    def _mint_prefix_dev(mut self) raises:
        var jwt = self._fetch_id_token(prefix_dev_audience(self._prefix_dev_host))
        var jwt_auth = _as_bearer(_secret_string(jwt))
        var req = PkgRequest(
            HTTP_METHOD_POST,
            self._prefix_dev_host.copy(),
            String(PREFIX_DEV_MINT_PATH),
        )
        req.with_header(String("Content-Type"), String("application/json"))
        req.body = _json_token_body(_secret_string(jwt))
        var ex = try_exchange(self._transport, req)
        if not ex.ok:
            raise Error(
                withhold_if_echoes(
                    String("GithubOidcCredential: the prefix.dev token exchange")
                    + String(" faulted: ")
                    + ex.fault,
                    jwt_auth,
                )
            )
        if ex.response.status < 200 or ex.response.status >= 300:
            raise Error(
                withhold_if_echoes(
                    String("GithubOidcCredential: the prefix.dev token exchange")
                    + String(" answered HTTP ")
                    + String(ex.response.status)
                    + String(": ")
                    + excerpt_unless_echoes(ex.response.body, jwt_auth),
                    jwt_auth,
                )
            )
        _refuse_raw_token(ex.response.body, String("the prefix.dev token exchange"))
        self._prefix_token = SecretValue(Span(ex.response.body))
        self._has_prefix_token = True

    def _mint_pypi(mut self) raises:
        var host = repo_host(self._pypi_index)
        var base = repo_path(self._pypi_index)
        var aud_req = PkgRequest(
            HTTP_METHOD_GET, host.copy(), base + String(PYPI_OIDC_AUDIENCE_PATH)
        )
        aud_req.with_header(String("Accept"), String("application/json"))
        var aud_ex = try_exchange(self._transport, aud_req)
        if not aud_ex.ok:
            raise Error(
                String("GithubOidcCredential: the index's audience request")
                + String(" faulted: ")
                + aud_ex.fault
            )
        if aud_ex.response.status != 200:
            raise Error(
                String("GithubOidcCredential: the index's audience request")
                + String(" answered HTTP ")
                + String(aud_ex.response.status)
                + String(": ")
                + excerpt_unless_echoes(aud_ex.response.body, String(""))
            )
        var aud_doc = parse_json_value(
            decode_utf8(Span(aud_ex.response.body), String("the index's audience"))
        )
        var audience = _string_claim(aud_doc, String("audience"))
        if audience.byte_length() == 0:
            raise Error(
                "GithubOidcCredential: the index's audience answer names no"
                " audience"
            )
        var jwt = self._fetch_id_token(audience)
        var jwt_auth = _as_bearer(_secret_string(jwt))
        var req = PkgRequest(
            HTTP_METHOD_POST, host.copy(), base + String(PYPI_OIDC_MINT_PATH)
        )
        req.with_header(String("Content-Type"), String("application/json"))
        req.body = _json_token_body(_secret_string(jwt))
        var ex = try_exchange(self._transport, req)
        if not ex.ok:
            raise Error(
                withhold_if_echoes(
                    String("GithubOidcCredential: the index's token exchange")
                    + String(" faulted: ")
                    + ex.fault,
                    jwt_auth,
                )
            )
        if ex.response.status != 200:
            raise Error(
                withhold_if_echoes(
                    String("GithubOidcCredential: the index's token exchange")
                    + String(" answered HTTP ")
                    + String(ex.response.status)
                    + String(": ")
                    + excerpt_unless_echoes(ex.response.body, jwt_auth),
                    jwt_auth,
                )
            )
        var token = _token_of_json_answer(ex.response.body, jwt_auth)
        self._pypi_token = token^
        self._has_pypi_token = True

    def authorization(mut self, surface: Int, host: String) raises -> String:
        """The minted token's shape for `surface`, only for the host it was
        minted at. The host check runs BEFORE any minting, so a mismatched
        host costs zero requests."""
        if surface == SURFACE_PREFIX_DEV and self._prefix_dev_host.byte_length() > 0:
            refuse_other_host(
                String("GithubOidcCredential"), surface, host, self._prefix_dev_host
            )
            if not self._has_prefix_token:
                self._mint_prefix_dev()
            return bearer_authorization(_secret_string(self._prefix_token))
        if surface == SURFACE_PYPI_UPLOAD and self._pypi_index.byte_length() > 0:
            refuse_other_host(
                String("GithubOidcCredential"),
                surface,
                host,
                repo_host(self._pypi_index),
            )
            if not self._has_pypi_token:
                self._mint_pypi()
            return pypi_upload_authorization(_secret_string(self._pypi_token))
        refuse_surface(String("GithubOidcCredential"), surface)
        return String("")  # cov: unreachable refuse_surface above always raises


def _value_of_id_token_answer(resp: PkgResponse) raises -> SecretValue:
    """The `value` of the ID-token answer, as a SecretValue. RAISES (never
    quoting the body: it holds the token) when it is not that shape."""
    var doc = JsonValue()
    try:
        doc = parse_json_value(decode_utf8(Span(resp.body), String("the ID-token answer")))
    except:
        raise Error("GithubOidcCredential: the ID-token answer is not JSON")
    var v = String("")
    try:
        v = _string_claim(doc, String("value"))
    except:
        raise Error("GithubOidcCredential: the ID-token answer's 'value' is not a string")
    if v.byte_length() == 0:
        raise Error("GithubOidcCredential: the ID-token answer carries no 'value'")
    return SecretValue.from_string(v)


def _token_of_json_answer(body: List[UInt8], jwt_auth: String) raises -> SecretValue:
    """The `token` of a warehouse mint answer. RAISES (never quoting the
    body) when it is not that shape."""
    var doc = JsonValue()
    try:
        doc = parse_json_value(decode_utf8(Span(body), String("the mint answer")))
    except:
        raise Error("GithubOidcCredential: the index's token exchange answer is not JSON")
    var t = String("")
    try:
        t = _string_claim(doc, String("token"))
    except:
        raise Error(
            "GithubOidcCredential: the index's token exchange answer's 'token' is"
            " not a string"
        )
    if t.byte_length() == 0:
        raise Error("GithubOidcCredential: the index's token exchange answered no token")
    _refuse_raw_token(bytes_of(t), String("the index's token exchange"))
    return SecretValue.from_string(t)
