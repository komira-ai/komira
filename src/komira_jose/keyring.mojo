# =============================================================================
# komira_jose/keyring.mojo: an issuer's signing keys over time: one key
#   signs, the next is published before it may sign, and the previous one
#   stays published until every token it signed has expired.
# =============================================================================
#
# A `Keyring` holds keys of ONE algorithm (a verifier is pinned to one, so a
# key of another algorithm would publish tokens nobody can verify) in three
# roles:
#
#   * the signing key: at most one; `sign` uses it and nothing else;
#   * the staged key: at most one, added by `rotate`. It is published (in
#     every `render_jwks` document) but never signs until `promote`;
#   * retiring keys: former signing keys, at most
#     `JOSE_KEYRING_MAX_RETIRING`. Only the public half is kept: the private
#     key is dropped (and its `SecretValue` wiped) when it stops signing, so a
#     retiring key cannot sign again by any path.
#
# The rules, each refused with a fixed `JoseError: ...` text:
#
#   1. publish before sign. `render_jwks(now)` records the first time the
#      staged key went out in a document; `promote(kid, now)` refuses until it
#      has, and until `publish_lead_s` has passed since then (time for
#      verifiers' caches to fetch it). The keyring cannot see whether the
#      document reached anyone: the caller serves every document it renders.
#      `promote` names the staged key's `kid`, so the key the operator checked
#      is the one that starts signing;
#   2. retire only after the max token TTL. `promote` makes the old signing
#      key a retiring key at `now`. `retire(kid, now)` removes it from the
#      document only when `now >= since + max_token_ttl_s + leeway_s`: by
#      then every token it signed has expired, leeway included. A staged key
#      has signed nothing and is removed at once. The signing key cannot be
#      retired (promote a successor first);
#   3. no token outlives the retirement rule. `sign(payload, typ, now)` reads
#      the payload as a JWT claims object and refuses it unless `exp` is a
#      non-negative integer with `exp - now <= max_token_ttl_s`;
#   4. time only moves forward: every call takes `now` (seconds since the
#      epoch), and a `now` earlier than one already seen is refused, so a
#      clock step back cannot shorten a retirement;
#   5. `rotate` refuses a key of another algorithm, a second staged key, and
#      a key whose `kid` the keyring already holds.
#
# `rotate` clears the publication record, so a staged key counts as published
# only from a document rendered after it was staged.
#
# `render_jwks` lists the signing key, then the staged key, then the
# retiring keys, each as `JwsSigner.public_jwk()` renders it.
#
# ENCAPSULATION: `JwsSigner` moved in, `String` out. No pointer crosses this
# file's API; private keys never leave their `JwsSigner`.
# =============================================================================

from komira_json import (
    JSON_OBJECT,
    JsonValue,
    parse_json_bytes,
    refuse_duplicate_keys,
)
from komira_jwks import Jwk, render_jwk_set

from komira_jose.claims import JOSE_MAX_LEEWAY_S, JOSE_MAX_TTL_S, _required_int
from komira_jose.signer import JwsSigner
from komira_jose.verifier import JWS_ALG_EDDSA, JWS_ALG_ES256, JWS_ALG_RS256


# The most retiring keys a keyring keeps published at once.
comptime JOSE_KEYRING_MAX_RETIRING: Int = 4
# The longest publish lead a keyring accepts, in seconds.
comptime JOSE_MAX_PUBLISH_LEAD_S: Int64 = 86400
comptime _PAYLOAD_MAX_DEPTH: Int = 16


def _refuse(reason: String) raises:
    raise Error(String("JoseError: ") + reason)


@fieldwise_init
struct _RetiringKey(Copyable, Movable):
    """A former signing key: its public half and when it stopped signing."""

    var jwk: Jwk
    var since: Int64


def _kid_of(key: Jwk) -> String:
    return key.kid().value()


struct Keyring(Movable):
    """The signing keys of one issuer under one algorithm (see the file
    header)."""

    var _alg: String
    var _max_token_ttl_s: Int64
    var _leeway_s: Int64
    var _publish_lead_s: Int64
    var _now: Int64
    var _active: Optional[JwsSigner]
    var _staged: Optional[JwsSigner]
    var _staged_published_at: Optional[Int64]
    var _retiring: List[_RetiringKey]

    def __init__(
        out self,
        *,
        alg: String,
        max_token_ttl_s: Int64,
        leeway_s: Int64,
        publish_lead_s: Int64,
        now: Int64,
    ) raises:
        """An empty keyring. Raises `JoseError: ...` for an algorithm other
        than ES256, EdDSA and RS256, a max token TTL outside 1 to
        `JOSE_MAX_TTL_S`, a leeway outside 0 to `JOSE_MAX_LEEWAY_S`, a publish
        lead outside 0 to `JOSE_MAX_PUBLISH_LEAD_S`, or a negative time."""
        if alg != JWS_ALG_ES256 and alg != JWS_ALG_EDDSA and alg != JWS_ALG_RS256:
            _refuse("the keyring algorithm must be ES256, EdDSA or RS256")
        if max_token_ttl_s < 1 or max_token_ttl_s > JOSE_MAX_TTL_S:
            _refuse("the keyring max token TTL must be 1 to 86400 seconds")
        if leeway_s < 0 or leeway_s > JOSE_MAX_LEEWAY_S:
            _refuse("the keyring leeway must be 0 to 60 seconds")
        if publish_lead_s < 0 or publish_lead_s > JOSE_MAX_PUBLISH_LEAD_S:
            _refuse("the keyring publish lead must be 0 to 86400 seconds")
        if now < 0:
            _refuse("the keyring time is negative")
        self._alg = alg.copy()
        self._max_token_ttl_s = max_token_ttl_s
        self._leeway_s = leeway_s
        self._publish_lead_s = publish_lead_s
        self._now = now
        self._active = Optional[JwsSigner]()
        self._staged = Optional[JwsSigner]()
        self._staged_published_at = Optional[Int64]()
        self._retiring = List[_RetiringKey]()

    def _tick(mut self, now: Int64) raises:
        if now < self._now:
            _refuse("the keyring time went backwards")
        self._now = now

    def _holds(self, kid: String) -> Bool:
        # `rotate` refuses while a key is staged, so the staged key is never
        # a candidate here.
        if self._active and self._active.value().kid() == kid:
            return True
        for i in range(len(self._retiring)):
            if _kid_of(self._retiring[i].jwk) == kid:
                return True
        return False

    def alg(self) -> String:
        """The keyring's one algorithm."""
        return self._alg.copy()

    def signing_kid(self) -> Optional[String]:
        """The `kid` of the key `sign` uses, if there is one."""
        if self._active:
            return Optional[String](self._active.value().kid())
        return Optional[String]()

    def staged_kid(self) -> Optional[String]:
        """The `kid` of the staged key, if there is one."""
        if self._staged:
            return Optional[String](self._staged.value().kid())
        return Optional[String]()

    def retiring_kids(self) -> List[String]:
        """The `kid`s of the retiring keys, oldest first."""
        var out = List[String]()
        for i in range(len(self._retiring)):
            out.append(_kid_of(self._retiring[i].jwk))
        return out^

    def rotate(mut self, var signer: JwsSigner, now: Int64) raises:
        """Stage `signer`: it is published from the next `render_jwks` on and
        signs only after `promote`. Raises for a key of another algorithm,
        while another key is staged, or for a `kid` the keyring holds."""
        self._tick(now)
        if signer.alg() != self._alg:
            _refuse("the key's algorithm is not the keyring's")
        if self._staged:
            _refuse("a staged key is waiting: promote or retire it first")
        if self._holds(signer.kid()):
            _refuse("the key is already in the keyring")
        self._staged = Optional[JwsSigner](signer^)
        self._staged_published_at = Optional[Int64]()

    def render_jwks(mut self, now: Int64) raises -> String:
        """The JWK Set to publish: the signing key, the staged key, then the
        retiring keys. Records `now` as the staged key's first publication if
        it had none."""
        self._tick(now)
        var keys = List[Jwk]()
        if self._active:
            keys.append(self._active.value().public_jwk())
        if self._staged:
            keys.append(self._staged.value().public_jwk())
            if not self._staged_published_at:
                self._staged_published_at = Optional[Int64](now)
        for i in range(len(self._retiring)):
            keys.append(self._retiring[i].jwk.copy())
        return render_jwk_set(keys)

    def promote(mut self, kid: String, now: Int64) raises:
        """Make the staged key, named by `kid`, the signing key; the old
        signing key starts retiring at `now`. Raises when no key is staged,
        `kid` names another key, the staged key was never in a rendered
        document or not for `publish_lead_s`, or the retiring list is full."""
        self._tick(now)
        if not self._staged:
            _refuse("no key is staged")
        if self._staged.value().kid() != kid:
            _refuse("kid does not name the staged key")
        if not self._staged_published_at:
            _refuse("the staged key has not been in a rendered key set")
        if now - self._staged_published_at.value() < self._publish_lead_s:
            _refuse("the staged key has not been published for the publish lead")
        if self._active:
            if len(self._retiring) >= JOSE_KEYRING_MAX_RETIRING:
                _refuse("the keyring holds the most retiring keys: retire one first")
            var old = self._active.take()
            self._retiring.append(_RetiringKey(old.public_jwk(), now))
        self._active = Optional[JwsSigner](self._staged.take())

    def retire(mut self, kid: String, now: Int64) raises:
        """Remove the key `kid` from the published set: a retiring key once
        `max_token_ttl_s + leeway_s` has passed since it stopped signing, the
        staged key at once. Raises for the signing key, too early, or for a
        `kid` the keyring does not hold."""
        self._tick(now)
        if self._active and self._active.value().kid() == kid:
            _refuse("the signing key cannot be retired: promote a successor first")
        if self._staged and self._staged.value().kid() == kid:
            self._staged = Optional[JwsSigner]()
            return
        for i in range(len(self._retiring)):
            if _kid_of(self._retiring[i].jwk) == kid:
                var since = self._retiring[i].since
                if now - since < self._max_token_ttl_s + self._leeway_s:
                    _refuse(
                        "a retiring key stays published for the max token TTL"
                        " plus the leeway"
                    )
                _ = self._retiring.pop(i)
                return
        _refuse("kid names no key in the keyring")

    def sign(
        mut self, payload: String, typ: Optional[String], now: Int64
    ) raises -> String:
        """`payload` signed by the signing key (`JwsSigner.sign`). Raises when
        there is no signing key, or the payload is not a JWT claims object
        whose `exp` is at most `now + max_token_ttl_s`."""
        self._tick(now)
        if not self._active:
            _refuse("the keyring has no signing key")
        var bytes = List[UInt8]()
        bytes.extend(Span(payload.as_bytes()))
        var claims: JsonValue
        try:
            claims = parse_json_bytes(bytes, _PAYLOAD_MAX_DEPTH)
        except:
            raise Error("JoseError: the payload is not JSON")
        if claims.kind != JSON_OBJECT:
            _refuse("the payload is not a JSON object")
        try:
            refuse_duplicate_keys(claims)
        except:
            _refuse("the payload names a member twice")
        var exp = _required_int(claims, "exp")
        if exp - now > self._max_token_ttl_s:
            _refuse("the token would outlive the keyring's max token TTL")
        return self._active.value().sign(payload.as_bytes(), typ)
