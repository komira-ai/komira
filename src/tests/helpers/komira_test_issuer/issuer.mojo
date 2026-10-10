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

from komira_test_issuer.keys import derived_key
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
