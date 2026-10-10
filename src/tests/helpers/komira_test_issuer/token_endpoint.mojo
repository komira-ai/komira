# =============================================================================
# komira_test_issuer/token_endpoint.mojo: the clients a test issuer knows,
#   and the checks its token endpoint makes on a client's request before it
#   signs an access token (issuer.mojo, `TestIssuer.token_request`).
# =============================================================================
#
# `ClientRegistry` holds one komira_oauth `ClientMetadata` record per client,
# with the resources (audiences) the client may ask for, and the `jti`s of
# the client assertions it has accepted.
#
# `ClientRegistry.authenticate(request, ...)` answers a parsed
# `client_credentials` request (komira_oauth `ClientCredentialsRequest`) with
# an `EndpointDecision`: the RFC 6749 error code to answer with, or the
# client id and the scope to put in the token. In this order:
#   1. the client: the request's `client_id` when sent, else the `iss` of the
#      assertion's payload, read without verifying it only to find the record
#      (the verification below pins `iss` to the record): an assertion whose
#      payload cannot be read, or a client with no record     invalid_client
#   2. a record with a `jwks_uri` and no `jwks` (this issuer fetches no key
#      set)                                                    invalid_client
#   3. the assertion, through komira_jose `verify_client_assertion` with a
#      verifier pinned to the record's signing algorithm over the record's
#      keys, read on every request, and a policy pinning `iss` to the client,
#      `typ` `JWT`, the issuer's time and leeway and a lifetime of at most
#      300 s; the audience is the issuer identifier, or the token endpoint
#      URL (RFC 7523 section 3 allows either); `sub == iss`; a `jti`
#      is required                                             invalid_client
#   4. the `jti`: refused when this client's assertion with the same `jti`
#      was accepted and its `exp` plus the leeway has not passed (until
#      then a copy of it would still verify); accepted assertions are
#      remembered from here on, whatever the answer          invalid_client
#   5. the `resource`: one of the client's resources, byte for byte
#                                                              invalid_target
#   6. the `scope`: every requested scope token among the record's; with no
#      scope requested the record's whole scope is given   invalid_scope
# Remembered `jti`s are dropped once their `exp` plus the leeway has passed.
#
# Every refusal of `register` and `remove` raises `TestIssuerError: <fixed
# text>`.
#
# ENCAPSULATION: owned values in and out. No pointer crosses this file's
# API.
# =============================================================================

from komira_encoding import base64_url_decode_nopad
from komira_jose import (
    JOSE_ASSERTION_MAX_TTL_S,
    JWT_TYP_JWT,
    ClaimPolicy,
    JwsVerifier,
    VerifiedAssertion,
    verify_client_assertion,
)
from komira_json import JSON_OBJECT, JSON_STRING, parse_json_bytes
from komira_oauth import (
    OAUTH_ERROR_INVALID_CLIENT,
    OAUTH_ERROR_INVALID_SCOPE,
    OAUTH_ERROR_INVALID_TARGET,
    ClientCredentialsRequest,
    ClientMetadata,
)


def _refuse(reason: String) raises:
    raise Error(String("TestIssuerError: ") + reason)


struct EndpointDecision(Copyable, Movable):
    """`error` is "" and `client_id` and `scope` say what to sign, or
    `error` is the code to answer with."""

    var error: String
    var client_id: String
    var scope: String

    def __init__(out self, var error: String, var client_id: String, var scope: String):
        self.error = error^
        self.client_id = client_id^
        self.scope = scope^


def _deny(code: String) -> EndpointDecision:
    return EndpointDecision(code.copy(), String(""), String(""))


@fieldwise_init
struct _Client(Copyable, Movable):
    var record: ClientMetadata
    var resources: List[String]


@fieldwise_init
struct _Seen(Copyable, Movable):
    var client_id: String
    var jti: String
    var until: Int64


def _unverified_issuer(assertion: String) -> String:
    """The `iss` string of the payload segment, or "" when there is none.
    Used only to find a record; never trusted."""
    var parts = assertion.split(".")
    if len(parts) != 3:
        return String("")
    try:
        var payload = base64_url_decode_nopad(String(parts[1]))
        var v = parse_json_bytes(payload, 16)
        if v.kind != JSON_OBJECT:
            return String("")
        for i in range(len(v.obj_keys)):
            if v.obj_keys[i] == "iss" and v.children[i].kind == JSON_STRING:
                return v.children[i].text.copy()
    except:
        pass
    return String("")


def _verify(
    assertion: String,
    verifier: JwsVerifier,
    client_id: String,
    audience: String,
    now: Int64,
    leeway_s: Int64,
) raises -> VerifiedAssertion:
    var policy = ClaimPolicy(
        issuer=client_id,
        audience=audience,
        accept_typ=JWT_TYP_JWT,
        now=now,
        leeway_s=leeway_s,
        max_ttl_s=JOSE_ASSERTION_MAX_TTL_S,
    )
    return verify_client_assertion(assertion, verifier, policy)


def _contains(values: List[String], v: String) -> Bool:
    for i in range(len(values)):
        if values[i] == v:
            return True
    return False


def _scope_list(scope: String) -> List[String]:
    var out = List[String]()
    if scope.byte_length() == 0:
        return out^
    for t in scope.split(" "):
        out.append(String(t))
    return out^


struct ClientRegistry(Movable):
    """The clients a test issuer knows (see the file header)."""

    var _clients: List[_Client]
    var _seen: List[_Seen]

    def __init__(out self):
        self._clients = List[_Client]()
        self._seen = List[_Seen]()

    def _index(self, client_id: String) -> Int:
        for i in range(len(self._clients)):
            if self._clients[i].record.client_id == client_id:
                return i
        return -1

    def register(mut self, record: ClientMetadata, resources: List[String]) raises:
        """Add a client that may ask for `resources`. Raises
        `TestIssuerError: ...` for a client id already registered, no
        resource, or an empty or repeated resource."""
        if self._index(record.client_id) >= 0:
            _refuse("the client is already registered")
        if len(resources) == 0:
            _refuse("a client needs a resource")
        for i in range(len(resources)):
            if resources[i].byte_length() == 0:
                _refuse("a resource is empty")
            for j in range(i):
                if resources[j] == resources[i]:
                    _refuse("a resource is named twice")
        self._clients.append(_Client(record.copy(), resources.copy()))

    def remove(mut self, client_id: String) raises:
        """Delete a client's record: its assertions are refused from now
        on. Raises `TestIssuerError: ...` for an unknown client."""
        var at = self._index(client_id)
        if at < 0:
            _refuse("no such client")
        _ = self._clients.pop(at)

    def _purge(mut self, now: Int64):
        var i = 0
        while i < len(self._seen):
            if self._seen[i].until <= now:
                _ = self._seen.pop(i)
            else:
                i += 1

    def _replayed(self, client_id: String, jti: String) -> Bool:
        for i in range(len(self._seen)):
            if self._seen[i].client_id == client_id and self._seen[i].jti == jti:
                return True
        return False

    def authenticate(
        mut self,
        request: ClientCredentialsRequest,
        *,
        issuer: String,
        token_endpoint: String,
        now: Int64,
        leeway_s: Int64,
    ) -> EndpointDecision:
        """Check a client's request (see the file header). Never raises."""
        self._purge(now)
        var client_id = request.client_id.copy()
        if client_id.byte_length() == 0:
            client_id = _unverified_issuer(request.client_assertion)
        var at = self._index(client_id)
        if at < 0:
            return _deny(OAUTH_ERROR_INVALID_CLIENT)
        var record = self._clients[at].record.copy()
        if not record.jwks:
            return _deny(OAUTH_ERROR_INVALID_CLIENT)
        var verifier: JwsVerifier
        try:
            verifier = JwsVerifier(
                record.token_endpoint_auth_signing_alg, record.jwks.value()
            )
        except:
            return _deny(OAUTH_ERROR_INVALID_CLIENT)
        var verified = Optional[VerifiedAssertion]()
        try:
            verified = Optional[VerifiedAssertion](
                _verify(request.client_assertion, verifier, client_id, issuer, now, leeway_s)
            )
        except:
            pass
        # The two policies differ only in the audience, so an assertion the
        # first refused for anything else fails the second too.
        if not verified:
            try:
                verified = Optional[VerifiedAssertion](
                    _verify(
                        request.client_assertion,
                        verifier,
                        client_id,
                        token_endpoint,
                        now,
                        leeway_s,
                    )
                )
            except:
                pass
        if not verified:
            return _deny(OAUTH_ERROR_INVALID_CLIENT)
        var jti = verified.value().jti.copy()
        var exp = verified.value().jwt.exp
        if self._replayed(client_id, jti):
            return _deny(OAUTH_ERROR_INVALID_CLIENT)
        self._seen.append(_Seen(client_id.copy(), jti^, exp + leeway_s))
        if not _contains(self._clients[at].resources, request.resource):
            return _deny(OAUTH_ERROR_INVALID_TARGET)
        var allowed = _scope_list(record.scope)
        var asked = _scope_list(request.scope)
        for i in range(len(asked)):
            if not _contains(allowed, asked[i]):
                return _deny(OAUTH_ERROR_INVALID_SCOPE)
        var given = request.scope.copy()
        if given.byte_length() == 0:
            given = record.scope.copy()
        return EndpointDecision(String(""), client_id^, given^)
