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
# A stale set stays in use while refreshes fail, up to the max-stale bound
# below.
#
# WHAT MAY REPLACE THE SET. A fetched document replaces the current keys only
# if ALL of these hold; otherwise the current set is kept, unchanged:
#   1. HTTP 200 and a body of 1..256 KiB (komira_jwks' JWKS_MAX_DOCUMENT_BYTES);
#   2. the body is strict JSON (komira_json, which also refuses ill-formed
#      UTF-8) with no repeated object key at any depth;
#   3. it is an object whose `keys` is an array of 1..64 objects;
#   4. every RSA entry is one this package can classify: an RSA entry whose
#      `alg` or `use` is present but not a string is refused, and every RSA
#      signing entry (kty "RSA", alg absent or "RS256", use absent or "sig")
#      has a `kid` of printable ASCII (the header gate, token.mojo, accepts
#      no other kid, so a key under any other kid could never be selected);
#   5. no two RSA signing entries share a `kid`. Two keys under one kid make
#      every token with that kid unverifiable (komira_jose refuses the
#      ambiguity), and because the kid is "known" no refetch would ever fix
#      it; so such a document never replaces a working set;
#   6. komira_jwks' `parse_jwk_set` accepts the document, and the RSA signing
#      keys it lifts carry EXACTLY the kids of those entries, in document
#      order, and at least one;
#   7. komira_jose accepts the lifted keys as an RS256 key set (at least one
#      of them suits RS256: `JwsVerifier`).
# Check 6 is what catches a key the parser skipped: `parse_jwk_set` leaves out
# a key it cannot use (a modulus outside 2048..4096 bits, a member that is not
# base64url without padding, a `key_ops` that is not an array of strings) and
# only records why, so its key list alone cannot tell a whole set from a
# partial one. It compares kids, not counts, so two readers that each drop a
# different entry cannot agree by accident. One unreadable RSA signing entry
# therefore refuses the whole document; the last good set stays.
#
# THE SET HELD is the lifted RSA signing keys only. A kid that names a key of
# another type or algorithm is unknown here, so it is refused as an unknown
# kid (and may cause a refetch), never handed to the signature check.
#
# STALE KEYS. A failed refresh keeps the last good set, but only for a
# bounded time: `keys_usable(now)` is true while `now` is at most the set's
# expiry (fetch time + max-age) plus the configured max-stale (default 1 h,
# 0..86400 s). Past that, and with no refresh succeeding, the verifier refuses
# every token as REASON_KEYS_UNAVAILABLE, which the middleware answers 503
# with `Retry-After`. Without the bound, an attacker who can block the HTTPS
# fetch (no certificate needed) would keep a key the issuer has withdrawn
# trusted for as long as the block lasted; with it, the exposure ends
# max-stale after the set went stale. A set never fetched is unusable too.
# The first successful refresh makes the set usable again.
#
# RETRY-AFTER. `retry_after_s(now)` is the time left until the next refresh
# may start (the rest of the refetch window, counted from the last attempt),
# at least 1 s: before then no request can make the keys usable again.
#
# Each verifier owns its cache; N serving workers make N fetches.
# =============================================================================

from komira_jose import JWS_ALG_RS256, JwsVerifier, VerifiedJws
from komira_json import JsonValue, parse_json_bytes
from komira_jwks import (
    JWK_KTY_RSA,
    JWKS_MAX_DOCUMENT_BYTES,
    JWKS_MAX_KEYS,
    Jwk,
    JwkSet,
    parse_jwk_set,
)

from komira_http_auth.config import MAX_JWKS_MAX_AGE_S, TYP_JWT
from komira_http_auth.dup_keys import refuse_duplicate_keys
from komira_http_auth.jwks_fetch import JwksFetcher
from komira_http_auth.token import is_printable_ascii, string_member


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


def _rsa_signing_kid(e: JsonValue) raises -> Optional[String]:
    """The kid of `e` when it is an RSA signing entry (check 4 of the module
    header); None for an entry that is not one (not RSA, or labelled for
    another alg or use). Raises on an RSA entry this reader cannot
    classify."""
    var kty = string_member(e, String("kty"))
    if not kty or kty.value() != String("RSA"):
        return Optional[String]()
    if e.has(String("alg")):
        var alg = string_member(e, String("alg"))
        if not alg:
            raise Error(String("komira_http_auth: JWKS RSA alg is not a string"))
        if alg.value() != String("RS256"):
            return Optional[String]()
    if e.has(String("use")):
        var use = string_member(e, String("use"))
        if not use:
            raise Error(String("komira_http_auth: JWKS RSA use is not a string"))
        if use.value() != String("sig"):
            return Optional[String]()
    var kid = string_member(e, String("kid"))
    if not kid or not is_printable_ascii(kid.value()):
        raise Error(String("komira_http_auth: JWKS RSA kid is not usable"))
    return kid^


def _is_rsa_signing_key(k: Jwk) -> Bool:
    """Whether komira_jwks' `k` is an RSA signing key: the same test as
    `_rsa_signing_kid`, over the parsed key."""
    if k.kty() != JWK_KTY_RSA:
        return False
    var alg = k.alg()
    if alg and alg.value() != JWS_ALG_RS256:
        return False
    var use = k.key_use()
    if use and use.value() != String("sig"):
        return False
    return True


def parse_complete_rsa_jwks(body: List[UInt8]) raises -> JwkSet:
    """The RSA signing keys of a JWK Set document, only if the WHOLE document
    passes checks 1..6 of the module header (status aside; check 7 is
    `ensure`'s); raises
    otherwise."""
    if len(body) == 0 or len(body) > JWKS_MAX_DOCUMENT_BYTES:
        raise Error(String("komira_http_auth: JWKS size out of range"))
    var v = parse_json_bytes(body, _JWKS_MAX_DEPTH)
    refuse_duplicate_keys(v)
    if not v.is_object() or not v.has(String("keys")):
        raise Error(String("komira_http_auth: JWKS has no keys member"))
    var keys = v.get(String("keys"))
    if not keys.is_array():
        raise Error(String("komira_http_auth: JWKS keys is not an array"))
    var n = keys.array_len()
    if n == 0 or n > JWKS_MAX_KEYS:
        raise Error(String("komira_http_auth: JWKS key count out of range"))
    var expected = List[String]()
    for i in range(n):
        var e = keys.element_at(i)
        if not e.is_object():
            raise Error(String("komira_http_auth: JWKS entry is not an object"))
        var kid = _rsa_signing_kid(e)
        if not kid:
            continue
        for j in range(len(expected)):
            if expected[j] == kid.value():
                raise Error(String("komira_http_auth: JWKS repeats a kid"))
        expected.append(kid.value())
    # SAFETY (UTF-8): parse_json_bytes above refused ill-formed UTF-8.
    var doc = String(unsafe_from_utf8=Span(body))
    var parsed = parse_jwk_set(doc)
    var lifted = List[Jwk]()
    for i in range(len(parsed.keys)):
        if _is_rsa_signing_key(parsed.keys[i]):
            lifted.append(parsed.keys[i].copy())
    if len(expected) == 0 or len(lifted) != len(expected):
        raise Error(String("komira_http_auth: JWKS parsed partially"))
    for i in range(len(lifted)):
        var kid = lifted[i].kid()
        if not kid or kid.value() != expected[i]:
            raise Error(String("komira_http_auth: JWKS parsed differently"))
    return JwkSet(lifted^, parsed.skipped.copy())


struct JwksCache[F: JwksFetcher](Movable, Deinitable):
    """The current key set for one JWKS URL, refreshed through `F` (module
    header), and the RS256 verifier built over it."""

    var _fetcher: Self.F
    var _url: String
    var _keys: JwkSet
    var _jws: Optional[JwsVerifier]
    var _expires_at_s: Int64
    var _attempted: Bool
    var _last_attempt_s: Int64
    var _window_s: Int64
    var _default_max_age_s: Int64
    var _max_stale_s: Int64

    def __init__(
        out self,
        var fetcher: Self.F,
        url: String,
        refetch_window_s: Int64,
        default_max_age_s: Int64,
        max_stale_s: Int64,
    ):
        self._fetcher = fetcher^
        self._url = url
        self._keys = JwkSet(List[Jwk](), List[String]())
        self._jws = Optional[JwsVerifier]()
        self._expires_at_s = Int64(0)
        self._attempted = False
        self._last_attempt_s = Int64(0)
        self._window_s = refetch_window_s
        self._default_max_age_s = default_max_age_s
        self._max_stale_s = max_stale_s

    def has_kid(self, kid: String) -> Bool:
        return Bool(self._keys.index_of_kid(kid))

    def key_count(self) -> Int:
        return len(self._keys.keys)

    def key_set(ref self) -> ref [self._keys] JwkSet:
        """The current RSA signing keys (possibly none)."""
        return self._keys

    def verify_signature(self, token: String) raises -> VerifiedJws:
        """`token` checked by komira_jose's `JwsVerifier` pinned to RS256 over
        the current set, with the header `typ` pinned to JWT and a `kid`
        required. Raises komira_jose's `JoseError: ...` text on any refusal,
        and when there is no set."""
        if not self._jws:
            raise Error(String("komira_http_auth: no key set"))
        return self._jws.value().verify_with_typ(
            token, Optional[String](TYP_JWT), True
        )

    def keys_usable(self, now_s: Int64) -> Bool:
        """Whether the current set may verify a token at `now_s`: there is
        one, and `now_s` is at most its expiry plus max-stale (module
        header, STALE KEYS)."""
        if len(self._keys.keys) == 0:
            return False
        return now_s - self._expires_at_s <= self._max_stale_s

    def retry_after_s(self, now_s: Int64) -> Int:
        """Seconds until the next refresh may start, at least 1 (module
        header, RETRY-AFTER)."""
        if self._may_attempt(now_s):
            return 1
        var left = self._window_s - (now_s - self._last_attempt_s)
        if left < Int64(1):
            return 1
        return Int(left)

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
            len(self._keys.keys) == 0
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
            # Check 7: raises when no lifted key suits RS256.
            var jws = JwsVerifier(JWS_ALG_RS256, keys)
            self._keys = keys^
            self._jws = Optional[JwsVerifier](jws^)
            self._expires_at_s = now_s + parse_cache_max_age(
                r.cache_control, self._default_max_age_s
            )
        except:
            return
