# =============================================================================
# komira_http_auth/jwks_cache.mojo: the current key set for one trust anchor.
# =============================================================================
#
# WHEN IT FETCHES. `ensure(kid, now)` refreshes when there are no keys yet,
# when the current set is past its max-age, or when `kid` is not in the set (a
# key rotation). Every refresh, for any of the three reasons, is rate limited:
# at most one fetch per refetch window (default 60 s), counted from the last
# ATTEMPT, successful or not. So a stream of tokens naming an unknown kid
# costs at most one fetch per window, and every one of them is refused.
#
# MAX-AGE. The `Cache-Control` of a successful fetch sets how long the set is
# fresh: the smallest `max-age=N` directive, clamped to 0..86400; `no-store`
# or `no-cache` mean 0. With neither, the configured default (300 s) applies.
# A stale set stays in use until a refresh succeeds.
#
# WHAT MAY REPLACE THE SET. A fetched document replaces the current keys only
# if ALL of these hold; otherwise the current set is kept, unchanged:
#   1. HTTP 200 and a body of 1..256 KiB;
#   2. the body is strict JSON (komira_json, which also refuses ill-formed
#      UTF-8) with no repeated object key at any depth;
#   3. it is an object whose `keys` is an array of 1..64 objects;
#   4. komira_crypto's `parse_rsa_jwks` lifts EXACTLY as many keys as the
#      document has RSA signing entries (kty "RSA", alg absent or "RS256",
#      use absent or "sig"), and at least one.
# Check 4 is what catches a partial parse: `parse_rsa_jwks` never raises and
# returns the keys read so far when a later entry is malformed, so its result
# alone cannot tell a whole set from a truncated one. One unreadable RSA entry
# therefore refuses the whole document; the last good set stays.
#
# Each verifier owns its cache; N serving workers make N fetches.
# =============================================================================

from komira_crypto.rs256_jwks import (
    RS256_MAX_JWKS_BYTES,
    RS256_MAX_JWKS_KEYS,
    RsaJwk,
    parse_rsa_jwks,
)
from komira_json import JsonValue, parse_json_bytes

from komira_http_auth.config import MAX_JWKS_MAX_AGE_S
from komira_http_auth.dup_keys import refuse_duplicate_keys
from komira_http_auth.jwks_fetch import JwksFetcher
from komira_http_auth.token import string_member


comptime _JWKS_MAX_DEPTH: Int = 8


def parse_cache_max_age(header: Optional[String], default_s: Int64) -> Int64:
    """The freshness lifetime named by a `Cache-Control` value (module
    header): the smallest `max-age`, 0 for `no-store` / `no-cache`, else
    `default_s`; always within 0..86400."""
    if not header:
        return default_s
    var best = Int64(-1)
    var parts = header.value().split(",")
    for i in range(len(parts)):
        var d = String(String(parts[i]).strip()).lower()
        if d == String("no-store") or d == String("no-cache"):
            best = Int64(0)
            continue
        if not d.startswith(String("max-age=")):
            continue
        var raw = String(d[byte=8 : d.byte_length()])
        var digits = raw.copy()
        if raw.byte_length() >= 2 and raw.startswith(String('"')) and (
            raw.endswith(String('"'))
        ):
            digits = String(raw[byte=1 : raw.byte_length() - 1])
        var b = digits.as_bytes()
        if len(b) == 0 or len(b) > 10:
            continue
        var n = Int64(0)
        var ok = True
        for j in range(len(b)):
            var c = Int(b[j])
            if c < 0x30 or c > 0x39:
                ok = False
                break
            n = n * Int64(10) + Int64(c - 0x30)
        if not ok:
            continue
        if best < Int64(0) or n < best:
            best = n
    if best < Int64(0):
        return default_s
    if best > MAX_JWKS_MAX_AGE_S:
        return MAX_JWKS_MAX_AGE_S
    return best


def _rsa_signing_entry(e: JsonValue) -> Bool:
    var kty = string_member(e, String("kty"))
    if not kty or kty.value() != String("RSA"):
        return False
    if e.has(String("alg")):
        var alg = string_member(e, String("alg"))
        if not alg or alg.value() != String("RS256"):
            return False
    if e.has(String("use")):
        var use = string_member(e, String("use"))
        if not use or use.value() != String("sig"):
            return False
    return True


def parse_complete_rsa_jwks(body: List[UInt8]) raises -> List[RsaJwk]:
    """The RSA keys of a JWK Set document, only if the WHOLE document passes
    checks 1..4 of the module header (status aside); raises otherwise."""
    if len(body) == 0 or len(body) > RS256_MAX_JWKS_BYTES:
        raise Error(String("komira_http_auth: JWKS size out of range"))
    var v = parse_json_bytes(body, _JWKS_MAX_DEPTH)
    refuse_duplicate_keys(v)
    if not v.is_object() or not v.has(String("keys")):
        raise Error(String("komira_http_auth: JWKS has no keys member"))
    var keys = v.get(String("keys"))
    if not keys.is_array():
        raise Error(String("komira_http_auth: JWKS keys is not an array"))
    var n = keys.array_len()
    if n == 0 or n > RS256_MAX_JWKS_KEYS:
        raise Error(String("komira_http_auth: JWKS key count out of range"))
    var expected = 0
    for i in range(n):
        var e = keys.element_at(i)
        if not e.is_object():
            raise Error(String("komira_http_auth: JWKS entry is not an object"))
        if _rsa_signing_entry(e):
            expected += 1
    # SAFETY (UTF-8): parse_json_bytes above refused ill-formed UTF-8.
    var doc = String(unsafe_from_utf8=Span(body))
    var parsed = parse_rsa_jwks(doc)
    if expected == 0 or len(parsed) != expected:
        raise Error(String("komira_http_auth: JWKS parsed partially"))
    return parsed^


struct JwksCache[F: JwksFetcher](Movable, Deinitable):
    """The current key set for one JWKS URL, refreshed through `F` (module
    header)."""

    var _fetcher: Self.F
    var _url: String
    var _keys: List[RsaJwk]
    var _expires_at_s: Int64
    var _attempted: Bool
    var _last_attempt_s: Int64
    var _window_s: Int64
    var _default_max_age_s: Int64

    def __init__(
        out self,
        var fetcher: Self.F,
        url: String,
        refetch_window_s: Int64,
        default_max_age_s: Int64,
    ):
        self._fetcher = fetcher^
        self._url = url
        self._keys = List[RsaJwk]()
        self._expires_at_s = Int64(0)
        self._attempted = False
        self._last_attempt_s = Int64(0)
        self._window_s = refetch_window_s
        self._default_max_age_s = default_max_age_s

    def has_kid(self, kid: String) -> Bool:
        for i in range(len(self._keys)):
            if self._keys[i].kid == kid:
                return True
        return False

    def key_count(self) -> Int:
        return len(self._keys)

    def key_set(ref self) -> ref [self._keys] List[RsaJwk]:
        """The current keys (possibly empty)."""
        return self._keys

    def _may_attempt(self, now_s: Int64) -> Bool:
        if not self._attempted:
            return True
        # A clock that stepped backwards must not lock refreshes out.
        if now_s < self._last_attempt_s:
            return True
        return now_s - self._last_attempt_s >= self._window_s

    def ensure(mut self, kid: String, now_s: Int64):
        """Refresh if the set is empty, stale, or lacks `kid`, subject to the
        refetch window. Never raises: a failed refresh keeps the current set."""
        var need = (
            len(self._keys) == 0
            or now_s >= self._expires_at_s
            or not self.has_kid(kid)
        )
        if not need or not self._may_attempt(now_s):
            return
        self._attempted = True
        self._last_attempt_s = now_s
        try:
            var r = self._fetcher.fetch(self._url)
            if r.status != 200:
                return
            var keys = parse_complete_rsa_jwks(r.body)
            self._keys = keys^
            self._expires_at_s = now_s + parse_cache_max_age(
                r.cache_control, self._default_max_age_s
            )
        except:
            return
