# =============================================================================
# komira_http_auth/config.mojo: one trust anchor and the middleware settings.
# =============================================================================
#
# A TRUST ANCHOR answers "whose signature do we accept, for whom": one issuer,
# one audience (ours), one JWKS URL, one `alg`, one `typ`, one longest token
# lifetime. This slice has one anchor kind: RS256 ID tokens checked against the
# issuer's published JWK Set (Google service-account ID tokens are the case it
# is built for). `validate_trust_anchor` refuses anything else at startup, so
# a misconfiguration is a startup error and never a silently weaker check.
#
# One verifier per trust anchor (see komira_jose's verifier.mojo header): an
# anchor is never widened to accept a second issuer or a second `alg`.
#
# What this file refuses at startup:
#   * a JWKS URL that is not `https://<host>/...` (no userinfo, no fragment);
#   * an `alg` other than RS256;
#   * a `typ` other than JWT. The signature check pins the header's `typ` to
#     "JWT" (jwks_cache.mojo, `verify_signature`), so no other value could
#     ever verify in this slice; refusing it here makes that visible at
#     startup;
#   * a max TTL outside 1..86400 seconds;
#   * a clock leeway outside 0..60 seconds;
#   * a JWKS fetch timeout outside 100 ms..60 s (the fetch stalls a serving
#     worker: jwks_fetch.mojo header; below 100 ms a TLS handshake to a
#     distant issuer cannot finish, so every refresh would fail);
#   * a JWKS max-stale outside 0..86400 seconds (how long past its freshness
#     a key set stays in use while every refresh fails: jwks_cache.mojo);
#   * a copy-claim name that is empty, repeated, or reserved: one of
#     RESERVED_CLAIM_NAMES below (the claims the principal sets itself, the
#     claim its subject comes from, and the names of the Principal's own
#     fields, which a reader of the claims map could take for them).
#
# No pointer in any signature; plain values.
# =============================================================================

from komira_http_client.url import Url


comptime ALG_RS256: String = "RS256"

# The claim names this package writes into `Principal.claims` itself
# (claims.mojo, `principal_from_claims`), and the claim the subject is read
# from. claims.mojo writes through these constants.
comptime CLAIM_ISS: StaticString = "iss"
comptime CLAIM_AUD: StaticString = "aud"
comptime CLAIM_SUB: StaticString = "sub"

# The names a --copy-claim may never name, refused at startup by
# `BearerJwtConfig.validate`. A copied claim is written into the same map
# as the claims above, so copying one of these would let a token choose its
# value:
#   * iss, aud: written by this package (copying one would overwrite it);
#   * sub: the principal's subject;
#   * scheme, subject, claims, presented: the Principal's own field names. A
#     reader that flattens a principal into one map, or looks a field up in
#     the claims (an embedder decoding `claims['scheme']`), would take a
#     copied claim of that name for the field.
# The set is built from CLAIM_ISS and CLAIM_AUD, so a claim this package
# writes is reserved by construction.
comptime RESERVED_CLAIM_NAMES: InlineArray[StaticString, 7] = [
    CLAIM_ISS,
    CLAIM_AUD,
    CLAIM_SUB,
    "scheme",
    "subject",
    "claims",
    "presented",
]


def is_reserved_claim_name(name: String) -> Bool:
    """True when `name` is one of RESERVED_CLAIM_NAMES."""
    var names = materialize[RESERVED_CLAIM_NAMES]()
    for i in range(len(names)):
        if name == String(names[i]):
            return True
    return False
comptime TYP_JWT: String = "JWT"

# The longest lifetime (exp - iat) a token of this anchor may claim. Google
# service-account ID tokens are issued for one hour.
comptime DEFAULT_MAX_TTL_S: Int64 = 3600
comptime MAX_TTL_CEILING_S: Int64 = 86400

# The clock skew forgiven on exp / iat / nbf, and its cap.
comptime DEFAULT_LEEWAY_S: Int64 = 30
comptime MAX_LEEWAY_S: Int64 = 60

# JWKS cache defaults: the max-age used when the response names none, the
# longest max-age honoured, the refetch rate-limit window, and the fetch
# timeout with its cap. The timeout bounds the TLS handshake and the request
# each; DNS and the TCP connect are outside it (jwks_fetch.mojo header).
comptime DEFAULT_JWKS_MAX_AGE_S: Int64 = 300
comptime MAX_JWKS_MAX_AGE_S: Int64 = 86400
comptime DEFAULT_JWKS_REFETCH_WINDOW_S: Int64 = 60
comptime DEFAULT_JWKS_FETCH_TIMEOUT_US: Int = 5_000_000
comptime MIN_JWKS_FETCH_TIMEOUT_US: Int = 100_000
comptime MAX_JWKS_FETCH_TIMEOUT_US: Int = 60_000_000

# How long past its freshness the last good key set stays in use while every
# refresh fails, and the cap (jwks_cache.mojo, STALE KEYS).
comptime DEFAULT_JWKS_MAX_STALE_S: Int64 = 3600
comptime MAX_JWKS_MAX_STALE_S: Int64 = 86400


@fieldwise_init
struct TrustAnchor(Copyable, Movable, Deinitable):
    """One accepted issuer: `issuer` and `audience` are compared exactly,
    `jwks_url` is where its public keys are published, `alg` and `typ` are the
    one header values accepted, and `max_ttl_s` bounds `exp - iat`."""

    var name: String
    var issuer: String
    var audience: String
    var jwks_url: String
    var alg: String
    var typ: String
    var max_ttl_s: Int64

    @staticmethod
    def rs256(
        name: String, issuer: String, audience: String, jwks_url: String
    ) -> TrustAnchor:
        """An RS256 anchor with the default `typ` (JWT) and max TTL (3600 s)."""
        return TrustAnchor(
            name=name,
            issuer=issuer,
            audience=audience,
            jwks_url=jwks_url,
            alg=ALG_RS256,
            typ=TYP_JWT,
            max_ttl_s=DEFAULT_MAX_TTL_S,
        )


def validate_jwks_url(url: String) raises:
    """Raises unless `url` is an absolute `https://` URL with a host and no
    userinfo or fragment. Keys fetched over plain HTTP could be replaced by
    anyone on the path, so there is no opt-out."""
    if not url.startswith(String("https://")):
        raise Error(
            String("komira_http_auth: the JWKS URL must start with https://")
        )
    var u = Url.parse(url)
    if not u.is_https():
        raise Error(String("komira_http_auth: the JWKS URL must use https"))
    if u.host.byte_length() == 0:
        raise Error(String("komira_http_auth: the JWKS URL has no host"))
    if u.userinfo.byte_length() != 0:
        raise Error(
            String("komira_http_auth: the JWKS URL may not carry userinfo")
        )
    if u.fragment.byte_length() != 0:
        raise Error(
            String("komira_http_auth: the JWKS URL may not carry a fragment")
        )


def validate_trust_anchor(a: TrustAnchor) raises:
    """Raises naming the first field of `a` this slice cannot honour."""
    if a.name.byte_length() == 0:
        raise Error(String("komira_http_auth: a trust anchor needs a name"))
    if a.issuer.byte_length() == 0:
        raise Error(
            String("komira_http_auth: trust anchor ")
            + a.name
            + String(" has an empty issuer")
        )
    if a.audience.byte_length() == 0:
        raise Error(
            String("komira_http_auth: trust anchor ")
            + a.name
            + String(" has an empty audience")
        )
    validate_jwks_url(a.jwks_url)
    if a.alg != ALG_RS256:
        raise Error(
            String("komira_http_auth: trust anchor ")
            + a.name
            + String(": alg must be RS256 (the only kind in this release)")
        )
    if a.typ != TYP_JWT:
        raise Error(
            String("komira_http_auth: trust anchor ")
            + a.name
            + String(
                ": typ must be JWT (the RS256 verifier accepts no other typ)"
            )
        )
    if a.max_ttl_s < Int64(1) or a.max_ttl_s > MAX_TTL_CEILING_S:
        raise Error(
            String("komira_http_auth: trust anchor ")
            + a.name
            + String(": max_ttl must be 1..86400 seconds")
        )


struct BearerJwtConfig(Copyable, Movable, Deinitable):
    """Everything a bearer-JWT verifier needs: its one trust anchor, the claim
    names copied into the principal, the clock leeway, and the JWKS cache
    settings. Build one with `BearerJwtConfig(anchor)` and the `with_*`
    setters, or from flags (`parse_bearer_jwt_flags`); `validate` runs when a
    verifier is built from it."""

    var anchor: TrustAnchor
    var copy_claims: List[String]
    var leeway_s: Int64
    var jwks_default_max_age_s: Int64
    var jwks_refetch_window_s: Int64
    var jwks_fetch_timeout_us: Int
    var jwks_max_stale_s: Int64

    def __init__(out self, var anchor: TrustAnchor):
        self.anchor = anchor^
        self.copy_claims = List[String]()
        self.leeway_s = DEFAULT_LEEWAY_S
        self.jwks_default_max_age_s = DEFAULT_JWKS_MAX_AGE_S
        self.jwks_refetch_window_s = DEFAULT_JWKS_REFETCH_WINDOW_S
        self.jwks_fetch_timeout_us = DEFAULT_JWKS_FETCH_TIMEOUT_US
        self.jwks_max_stale_s = DEFAULT_JWKS_MAX_STALE_S

    def with_copy_claim(var self, name: String) -> BearerJwtConfig:
        self.copy_claims.append(name)
        return self^

    def with_leeway_s(var self, seconds: Int64) -> BearerJwtConfig:
        self.leeway_s = seconds
        return self^

    def with_jwks_refetch_window_s(var self, seconds: Int64) -> BearerJwtConfig:
        self.jwks_refetch_window_s = seconds
        return self^

    def with_jwks_fetch_timeout_us(var self, micros: Int) -> BearerJwtConfig:
        """The JWKS fetch timeout: the bound on the TLS handshake and on the
        request, each (jwks_fetch.mojo header has the whole worst case)."""
        self.jwks_fetch_timeout_us = micros
        return self^

    def with_jwks_max_stale_s(var self, seconds: Int64) -> BearerJwtConfig:
        """How long past its freshness the last good key set stays in use
        while every refresh fails (0..86400 s, default 3600); after that every
        token is refused with 503 until a refresh succeeds."""
        self.jwks_max_stale_s = seconds
        return self^

    def with_jwks_default_max_age_s(
        var self, seconds: Int64
    ) -> BearerJwtConfig:
        self.jwks_default_max_age_s = seconds
        return self^

    def validate(self) raises:
        """Raises naming the first setting that cannot be honoured."""
        validate_trust_anchor(self.anchor)
        if self.leeway_s < Int64(0) or self.leeway_s > MAX_LEEWAY_S:
            raise Error(
                String("komira_http_auth: clock leeway must be 0..60 seconds")
            )
        if self.jwks_refetch_window_s < Int64(1):
            raise Error(
                String(
                    "komira_http_auth: the JWKS refetch window must be at least"
                    " 1 second"
                )
            )
        if (
            self.jwks_default_max_age_s < Int64(0)
            or self.jwks_default_max_age_s > MAX_JWKS_MAX_AGE_S
        ):
            raise Error(
                String(
                    "komira_http_auth: the default JWKS max-age must be"
                    " 0..86400 seconds"
                )
            )
        if (
            self.jwks_fetch_timeout_us < MIN_JWKS_FETCH_TIMEOUT_US
            or self.jwks_fetch_timeout_us > MAX_JWKS_FETCH_TIMEOUT_US
        ):
            raise Error(
                String(
                    "komira_http_auth: the JWKS fetch timeout must be 100 ms..60"
                    " seconds"
                )
            )
        if (
            self.jwks_max_stale_s < Int64(0)
            or self.jwks_max_stale_s > MAX_JWKS_MAX_STALE_S
        ):
            raise Error(
                String(
                    "komira_http_auth: the JWKS max-stale must be 0..86400"
                    " seconds"
                )
            )
        for i in range(len(self.copy_claims)):
            ref n = self.copy_claims[i]
            if n.byte_length() == 0:
                raise Error(
                    String("komira_http_auth: --copy-claim names an empty claim")
                )
            if is_reserved_claim_name(n):
                raise Error(
                    String("komira_http_auth: --copy-claim=")
                    + n
                    + String(
                        " is a reserved claim name and cannot be copied (the"
                        " principal sets it, or it names a Principal field)"
                    )
                )
            for j in range(i):
                if self.copy_claims[j] == n:
                    raise Error(
                        String("komira_http_auth: --copy-claim=")
                        + n
                        + String(" is given more than once")
                    )
