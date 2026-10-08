"""`komira_http_auth`: bearer-JWT authentication for komira_http_server.

`BearerJwtMiddleware[V]` sits in the server's auth slot. It reads
`Authorization: Bearer <token>`, hands the token to a `BearerVerifier` `V`,
and either sets `ctx.principal` (scheme "jwt") or answers 401 with an RFC 6750
`WWW-Authenticate` header. This release ships one verifier kind,
`Rs256JwksVerifier`: RS256 tokens of one issuer (for example Google
service-account ID tokens) checked against that issuer's JWK Set, which it
fetches over HTTPS and caches.

Modules:
  - middleware.mojo : `BearerJwtMiddleware`, the Authorization header parse,
                      the 401 responses.
  - verifier.mojo   : `BearerVerifier`, `VerifyOutcome`, `Rs256JwksVerifier`.
  - token.mojo      : compact-JWS split and the JOSE header gate.
  - claims.mojo     : iss / aud / sub / exp / iat / nbf / lifetime checks and
                      the principal.
  - jwks_cache.mojo : the key set: max-age, refetch rate limit, whole-document
                      validation before a replace.
  - jwks_fetch.mojo : `JwksFetcher`, `HttpsJwksFetcher`, `ScriptedJwksFetcher`.
  - config.mojo     : `TrustAnchor`, `BearerJwtConfig` and their validation.
  - flags.mojo      : `--name=value` flags -> `BearerJwtConfig`.
  - clock.mojo      : `AuthClock`, `SystemAuthClock`, `FixedAuthClock`.
  - reasons.mojo    : the fixed refusal codes.
  - testing.mojo    : sign test tokens and publish a test key as a JWK Set.

No pointer type in any public signature; configuration comes from flags,
never from the environment. RS256 verification is komira_crypto's
`verify_rs256_jws`; this package adds no second verifier.
"""

from .clock import AuthClock, FixedAuthClock, SystemAuthClock
from .config import (
    ALG_RS256,
    BearerJwtConfig,
    DEFAULT_LEEWAY_S,
    DEFAULT_MAX_TTL_S,
    MAX_LEEWAY_S,
    TYP_JWT,
    TrustAnchor,
    validate_jwks_url,
    validate_trust_anchor,
)
from .flags import (
    bearer_jwt_flag_names,
    parse_bearer_jwt_flags,
    parse_trust_anchor,
)
from .jwks_cache import JwksCache, parse_cache_max_age, parse_complete_rsa_jwks
from .jwks_fetch import (
    HttpsJwksFetcher,
    JwksFetchResult,
    JwksFetcher,
    ScriptedJwksFetcher,
)
from .middleware import (
    BearerJwtMiddleware,
    WWW_AUTHENTICATE_INVALID_REQUEST,
    WWW_AUTHENTICATE_INVALID_TOKEN,
    bearer_token_from_header,
)
from .reasons import (
    REASON_ALG,
    REASON_AUD,
    REASON_CRIT,
    REASON_DUPLICATE_KEY,
    REASON_EXP,
    REASON_EXPIRED,
    REASON_HEADER_JSON,
    REASON_IAT,
    REASON_INTERNAL,
    REASON_ISS,
    REASON_KEY_IN_HEADER,
    REASON_KID,
    REASON_MALFORMED_HEADER,
    REASON_MALFORMED_TOKEN,
    REASON_MISSING_HEADER,
    REASON_NBF,
    REASON_OK,
    REASON_PAYLOAD_JSON,
    REASON_SIGNATURE,
    REASON_SUB,
    REASON_TTL,
    REASON_TYP,
    REASON_UNKNOWN_KID,
)
from .verifier import BearerVerifier, Rs256JwksVerifier, VerifyOutcome
