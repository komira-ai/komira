# =============================================================================
# komira_test_issuer/issuer.mojo: `TestIssuer`, an in-process token issuer
#   for tests: it serves a JWK Set document and mints user access tokens,
#   and rotates its keys the way the HTTP auth design requires.
# =============================================================================
#
# A `TestIssuer` is one issuer URL, one algorithm (ES256 or EdDSA), one
# header `typ` (`at+jwt` or `JWT`), a max token lifetime, a leeway, a
# publish lead and a clock of its own, over a komira_jose `Keyring`. Its keys
# are derived from a seed (keys.mojo): key 0 signs first, then 1, 2, ...
#
#   * `jwks()` is the document to serve: the signing key, the staged key and
#     the retiring keys (`Keyring.render_jwks`). Serving it counts as
#     publishing the staged key, so a rotation cannot finish unless the
#     test has asked for the document after `begin_rotation`.
#   * `mint_user_token(subject, audience, client_id, scope)` signs the claims
#     of user_token.mojo with a fresh random `jti` (komira_jose `new_jti`),
#     `iat` now and the max lifetime; `mint` takes the lifetime. `sign_claims`
#     signs any claims object and header `typ`, for tests that need a token
#     this issuer would never mint (the keyring still refuses an `exp` past
#     the max lifetime).
#   * `begin_rotation()` stages the next key; `finish_rotation()` makes it
#     the signing key once it has been in a served document for the publish
#     lead (the keyring refuses earlier). The former key is kept in the
#     document and leaves it when the clock reaches the switch time plus the
#     max lifetime plus the leeway: by then every token it signed has expired
#     for a verifier with that leeway.
#   * `advance(seconds)` moves the clock forward and removes every former key
#     whose time has come. The clock never moves back.
#   * The token endpoint (token_endpoint.mojo): `register_client(record,
#     resources)` adds a komira_oauth `ClientMetadata` record and the
#     audiences the client may ask for; `remove_client` deletes it.
#     `token_request(form)` answers a `client_credentials` request with
#     `private_key_jwt` as an RFC 6749 token endpoint does: 200 with
#     `{access_token, token_type, expires_in, scope?}`, the token signed now
#     with `sub` and `client_id` the client, `aud` the requested resource,
#     the max lifetime and a fresh `jti`; or 401 `invalid_client` and 400
#     for every other error code, with `{"error":"<code>"}`. An HTTP
#     adapter adds `Cache-Control: no-store`. `token_endpoint_url()` is the
#     issuer plus `/token`, `jwks_uri()` the issuer plus `/jwks`, and
#     `metadata_document()` the RFC 8414 document naming both.
#
# The first key counts as published `publish_lead_s` before the start time,
# so a new issuer signs at once; the start time must be at least the publish
# lead. Max lifetime, leeway and publish lead are checked by the keyring
# (1 to 86400 s, 0 to 60 s, 0 to 86400 s).
#
# Every refusal of this file raises `TestIssuerError: <fixed text>`; the
# keyring's raise `JoseError: ...`.
#
# ENCAPSULATION: values in and out; the keys never leave the keyring. No
# pointer crosses this file's API.
# =============================================================================

from komira_jose import (
    JWS_ALG_EDDSA,
    JWS_ALG_ES256,
    JWT_TYP_AT_JWT,
    JWT_TYP_JWT,
    Keyring,
    new_jti,
)

from komira_oauth import (
    OAUTH_ERROR_INVALID_CLIENT,
    AuthorizationServerMetadata,
    ClientMetadata,
    TokenEndpointReply,
    parse_client_credentials_request,
    render_oauth_error,
    render_token_response,
)

from komira_test_issuer.keys import derived_key
from komira_test_issuer.token_endpoint import ClientRegistry
from komira_test_issuer.under_test import IssuerUnderTest
from komira_test_issuer.user_token import user_token_claims


def _refuse(reason: String) raises:
    raise Error(String("TestIssuerError: ") + reason)


@fieldwise_init
struct _Retirement(Copyable, Movable):
    """A former signing key and the time it leaves the document."""

    var kid: String
    var at: Int64


struct TestIssuer(IssuerUnderTest, Movable, Deinitable):
    """An in-process issuer for tests (see the file header)."""

    var _issuer: String
    var _alg: String
    var _typ: String
    var _seed: String
    var _max_ttl_s: Int64
    var _leeway_s: Int64
    var _publish_lead_s: Int64
    var _now: Int64
    var _next_key: Int
    var _ring: Keyring
    var _retirements: List[_Retirement]
    var _clients: ClientRegistry

    def __init__(
        out self,
        *,
        issuer: String,
        alg: String,
        typ: String,
        max_ttl_s: Int64,
        leeway_s: Int64,
        publish_lead_s: Int64,
        seed: String,
        now: Int64,
    ) raises:
        """An issuer whose key 0 of `seed` signs from `now` on. Raises
        `TestIssuerError: ...` for an empty issuer or seed, an algorithm
        other than ES256 and EdDSA, a `typ` other than `at+jwt` and `JWT`, or
        a start time earlier than the publish lead; and `JoseError: ...` for
        a lifetime, leeway or publish lead the keyring refuses."""
        if issuer.byte_length() == 0:
            _refuse("the issuer is empty")
        if alg != JWS_ALG_ES256 and alg != JWS_ALG_EDDSA:
            _refuse("the test issuer signs ES256 or EdDSA")
        if typ != JWT_TYP_AT_JWT and typ != JWT_TYP_JWT:
            _refuse("the token typ must be at+jwt or JWT")
        if now < publish_lead_s:
            _refuse("the start time is earlier than the publish lead")
        # An empty seed is refused by `derived_key`, with the same text.
        var start = now - publish_lead_s
        var ring = Keyring(
            alg=alg,
            max_token_ttl_s=max_ttl_s,
            leeway_s=leeway_s,
            publish_lead_s=publish_lead_s,
            now=start,
        )
        var first = derived_key(alg, seed, 0)
        var kid = first.kid()
        ring.rotate(first^, start)
        _ = ring.render_jwks(start)
        ring.promote(kid, now)
        self._issuer = issuer.copy()
        self._alg = alg.copy()
        self._typ = typ.copy()
        self._seed = seed.copy()
        self._max_ttl_s = max_ttl_s
        self._leeway_s = leeway_s
        self._publish_lead_s = publish_lead_s
        self._now = now
        self._next_key = 1
        self._ring = ring^
        self._retirements = List[_Retirement]()
        self._clients = ClientRegistry()

    def issuer(self) -> String:
        """The `iss` of every token."""
        return self._issuer.copy()

    def alg(self) -> String:
        """The one signing algorithm."""
        return self._alg.copy()

    def typ(self) -> String:
        """The header `typ` of every minted token."""
        return self._typ.copy()

    def max_ttl_s(self) -> Int64:
        """The longest token lifetime, in seconds."""
        return self._max_ttl_s

    def leeway_s(self) -> Int64:
        """The leeway a former key's retirement waits for, in seconds."""
        return self._leeway_s

    def publish_lead_s(self) -> Int64:
        """How long a new key is served before it signs, in seconds."""
        return self._publish_lead_s

    def now(self) -> Int64:
        """The issuer's clock, in seconds since the epoch."""
        return self._now

    def signing_kid(self) -> String:
        """The `kid` of the key that signs now."""
        return self._ring.signing_kid().value()

    def staged_kid(self) -> Optional[String]:
        """The `kid` of the key a rotation in progress will switch to."""
        return self._ring.staged_kid()

    def retiring_kids(self) -> List[String]:
        """The `kid`s of the former keys still served, oldest first."""
        return self._ring.retiring_kids()

    def advance(mut self, seconds: Int64) raises:
        """Move the clock `seconds` forward and remove every former key whose
        time has come. Raises `TestIssuerError: ...` for a negative step."""
        if seconds < 0:
            _refuse("the clock only moves forward")
        self._now += seconds
        var i = 0
        while i < len(self._retirements):
            if self._retirements[i].at <= self._now:
                self._ring.retire(self._retirements[i].kid, self._now)
                _ = self._retirements.pop(i)
            else:
                i += 1

    def jwks(mut self) raises -> String:
        """The JWK Set document to serve now (see the file header)."""
        return self._ring.render_jwks(self._now)

    def jwks_document(mut self) raises -> String:
        """`jwks()`, under the name the scenario runner calls."""
        return self.jwks()

    def begin_rotation(mut self) raises:
        """Stage the next derived key. Raises `JoseError: ...` while another
        rotation is in progress."""
        self._ring.rotate(
            derived_key(self._alg, self._seed, self._next_key), self._now
        )
        self._next_key += 1

    def finish_rotation(mut self) raises:
        """Make the staged key the signing key; the former key is served
        until now plus the max lifetime plus the leeway. Raises
        `TestIssuerError: ...` when no rotation is in progress and
        `JoseError: ...` when the staged key has not been served for the
        publish lead."""
        var staged = self._ring.staged_kid()
        if not staged:
            _refuse("no rotation is in progress")
        var former = self._ring.signing_kid().value()
        self._ring.promote(staged.value(), self._now)
        self._retirements.append(
            _Retirement(
                former^, self._now + self._max_ttl_s + self._leeway_s
            )
        )

    def mint(
        mut self,
        *,
        subject: String,
        audience: String,
        client_id: String,
        scope: String,
        ttl_s: Int64,
    ) raises -> String:
        """A user access token signed now, living `ttl_s` seconds. Raises as
        `user_token_claims` does, and `JoseError: ...` for a lifetime past
        the max."""
        var claims = user_token_claims(
            issuer=self._issuer,
            subject=subject,
            audience=audience,
            client_id=client_id,
            scope=scope,
            now=self._now,
            ttl_s=ttl_s,
            jti=new_jti(),
        )
        return self._ring.sign(claims, Optional[String](self._typ), self._now)

    def mint_user_token(
        mut self,
        subject: String,
        audience: String,
        client_id: String,
        scope: String,
    ) raises -> String:
        """`mint` with the max lifetime."""
        return self.mint(
            subject=subject,
            audience=audience,
            client_id=client_id,
            scope=scope,
            ttl_s=self._max_ttl_s,
        )

    def sign_claims(
        mut self, claims: String, typ: Optional[String]
    ) raises -> String:
        """`claims` signed now by the signing key, with header `typ` when
        given (see the file header)."""
        return self._ring.sign(claims, typ, self._now)

    def token_endpoint_url(self) -> String:
        """The token endpoint: the issuer plus `/token`."""
        return self._issuer + "/token"

    def jwks_uri(self) -> String:
        """Where the JWK Set is served: the issuer plus `/jwks`."""
        return self._issuer + "/jwks"

    def metadata_document(self) raises -> String:
        """The RFC 8414 metadata document (komira_oauth): the issuer, the
        token endpoint, the JWK Set URL, `private_key_jwt` with ES256 and
        EdDSA assertions."""
        var algs = List[String]()
        algs.append(JWS_ALG_ES256)
        algs.append(JWS_ALG_EDDSA)
        return AuthorizationServerMetadata.for_client_credentials(
            issuer=self._issuer,
            token_endpoint=self.token_endpoint_url(),
            jwks_uri=self.jwks_uri(),
            signing_algs=algs,
        ).render()

    def register_client(
        mut self, record: ClientMetadata, resources: List[String]
    ) raises:
        """Add a client that may ask for tokens for `resources` (see
        token_endpoint.mojo). Raises `TestIssuerError: ...`."""
        self._clients.register(record, resources)

    def remove_client(mut self, client_id: String) raises:
        """Delete a client's record. Raises `TestIssuerError: ...` for an
        unknown client."""
        self._clients.remove(client_id)

    def token_request(mut self, form: String) raises -> TokenEndpointReply:
        """Answer a token request body (see the file header). Raises only
        when signing fails."""
        var parsed = parse_client_credentials_request(form)
        if not parsed.ok():
            return _error_reply(parsed.error)
        var d = self._clients.authenticate(
            parsed.request,
            issuer=self._issuer,
            token_endpoint=self.token_endpoint_url(),
            now=self._now,
            leeway_s=self._leeway_s,
        )
        if d.error.byte_length() > 0:
            return _error_reply(d.error)
        var claims = user_token_claims(
            issuer=self._issuer,
            subject=d.client_id,
            audience=parsed.request.resource,
            client_id=d.client_id,
            scope=d.scope,
            now=self._now,
            ttl_s=self._max_ttl_s,
            jti=new_jti(),
        )
        var token = self._ring.sign(
            claims, Optional[String](self._typ), self._now
        )
        return TokenEndpointReply(
            200, render_token_response(token, self._max_ttl_s, d.scope)
        )


def _error_reply(code: String) -> TokenEndpointReply:
    var status = 400
    if code == OAUTH_ERROR_INVALID_CLIENT:
        status = 401
    return TokenEndpointReply(status, render_oauth_error(code))
