# =============================================================================
# komira_http_auth/verifier.mojo: bearer token -> Principal, or a reason.
# =============================================================================
#
# `BearerVerifier` is what `BearerJwtMiddleware` is generic over: one method
# taking the token text and returning a `VerifyOutcome` (a principal, or a
# reason code from reasons.mojo). It never raises and never echoes the token.
#
# `Rs256JwksVerifier[F, C]` is the one trust-anchor kind of this release:
# RS256 tokens checked against the anchor's JWK Set. The order is the point:
#
#   1. shape: three unpadded base64url segments (token.mojo);
#   2. the JOSE header gate (token.mojo): alg, jwk/jku/x5u/x5c, crit, typ,
#      kid, repeated keys. Nothing has been fetched or computed yet;
#   3. the key set (jwks_cache.mojo): refreshed if empty, stale, or missing
#      the token's kid, at most once per refetch window. A set that is not
#      usable (never fetched, or past its freshness plus max-stale with every
#      refresh failing) refuses the token as REASON_KEYS_UNAVAILABLE, an
#      outcome that is no verdict on the token (`keys_unavailable()`, with
#      `retry_after_s`); a kid still missing is refused here;
#   4. the signature: komira_crypto's `verify_rs256_jws`, the one RS256 JWS
#      verifier in the repository. It repeats the alg/typ/crit/kid checks over
#      its own reader, so a token passes only if both readers agree;
#   5. the payload, re-decoded from its (now authentic) segment, then the
#      claims (claims.mojo);
#   6. the principal.
#
# One verifier is one trust anchor: see komira_crypto's rs256_jwks header for
# why a verifier is never widened to a second issuer or algorithm.
# =============================================================================

from komira_crypto.rs256_jwks import verify_rs256_jws
from komira_json import JsonValue

from komira_http_server.middleware import Principal

from komira_http_auth.claims import (
    check_claims,
    decode_payload,
    principal_from_claims,
)
from komira_http_auth.clock import AuthClock
from komira_http_auth.config import BearerJwtConfig, TrustAnchor
from komira_http_auth.jwks_cache import JwksCache
from komira_http_auth.jwks_fetch import JwksFetcher
from komira_http_auth.reasons import (
    REASON_INTERNAL,
    REASON_KEYS_UNAVAILABLE,
    REASON_MALFORMED_TOKEN,
    REASON_OK,
    REASON_SIGNATURE,
    REASON_UNKNOWN_KID,
)
from komira_http_auth.token import check_jose_header, split_compact_jws


struct VerifyOutcome(Copyable, Movable, Deinitable):
    """A verified principal (and `reason` REASON_OK), or no principal and the
    reason code of the check that refused the token. A refusal with reason
    REASON_KEYS_UNAVAILABLE says nothing about the token: the verifier had no
    usable keys, and `retry_after_s` is when it may have them again."""

    var principal: Optional[Principal]
    var reason: String
    var retry_after_s: Int

    def __init__(out self, var principal: Principal):
        self.principal = Optional[Principal](principal^)
        self.reason = String(REASON_OK)
        self.retry_after_s = 0

    def __init__(out self, *, refused: String):
        self.principal = Optional[Principal]()
        self.reason = refused
        self.retry_after_s = 0

    def __init__(out self, *, keys_unavailable_retry_after_s: Int):
        """No usable keys; try again in `keys_unavailable_retry_after_s`
        seconds (at least 1 is reported)."""
        self.principal = Optional[Principal]()
        self.reason = String(REASON_KEYS_UNAVAILABLE)
        self.retry_after_s = (
            keys_unavailable_retry_after_s if keys_unavailable_retry_after_s
            >= 1 else 1
        )

    def ok(self) -> Bool:
        return Bool(self.principal)

    def keys_unavailable(self) -> Bool:
        """Refused because no usable key set exists, not because of the
        token (the middleware answers 503)."""
        return not self.principal and self.reason == REASON_KEYS_UNAVAILABLE


trait BearerVerifier(Movable, Deinitable):
    """Turns a bearer token into a principal or a refusal. Must not raise."""

    def verify(mut self, token: String) -> VerifyOutcome:
        ...


struct Rs256JwksVerifier[F: JwksFetcher, C: AuthClock](
    BearerVerifier, Movable, Deinitable
):
    """RS256 bearer tokens of one trust anchor, keys from its JWK Set through
    `F`, time from `C` (module header)."""

    var _anchor: TrustAnchor
    var _copy_claims: List[String]
    var _leeway_s: Int64
    var _cache: JwksCache[Self.F]
    var _clock: Self.C

    def __init__(
        out self, config: BearerJwtConfig, var fetcher: Self.F, var clock: Self.C
    ) raises:
        """Validates `config` (raising naming the first bad setting)."""
        config.validate()
        self._anchor = config.anchor.copy()
        self._copy_claims = config.copy_claims.copy()
        self._leeway_s = config.leeway_s
        # The configured fetch timeout reaches the fetcher here, whatever
        # timeout the embedder built it with.
        fetcher.set_timeout_us(config.jwks_fetch_timeout_us)
        self._cache = JwksCache[Self.F](
            fetcher^,
            config.anchor.jwks_url,
            config.jwks_refetch_window_s,
            config.jwks_default_max_age_s,
            config.jwks_max_stale_s,
        )
        self._clock = clock^

    def key_count(self) -> Int:
        """How many keys the cache holds now."""
        return self._cache.key_count()

    def verify(mut self, token: String) -> VerifyOutcome:
        try:
            return self._verify(token)
        except:
            return VerifyOutcome(refused=REASON_INTERNAL)

    def _verify(mut self, token: String) raises -> VerifyOutcome:
        var parts_o = split_compact_jws(token)
        if not parts_o:
            return VerifyOutcome(refused=REASON_MALFORMED_TOKEN)
        var parts = parts_o.value().copy()

        var hv = check_jose_header(parts.header_seg, self._anchor)
        if hv.reason != REASON_OK:
            return VerifyOutcome(refused=hv.reason)

        var now = self._clock.now_unix_seconds()
        self._cache.ensure(hv.kid, now)
        if not self._cache.keys_usable(now):
            return VerifyOutcome(
                keys_unavailable_retry_after_s=self._cache.retry_after_s(now)
            )
        if not self._cache.has_kid(hv.kid):
            return VerifyOutcome(refused=REASON_UNKNOWN_KID)

        var authentic = verify_rs256_jws(token, self._cache.key_set())
        if not authentic:
            return VerifyOutcome(refused=REASON_SIGNATURE)

        var payload: JsonValue
        try:
            payload = decode_payload(parts.payload_seg)
        except e:
            return VerifyOutcome(refused=String(e))

        var reason = check_claims(payload, self._anchor, self._leeway_s, now)
        if reason != REASON_OK:
            return VerifyOutcome(refused=reason)
        return VerifyOutcome(
            principal_from_claims(payload, self._anchor, self._copy_claims, token)
        )
