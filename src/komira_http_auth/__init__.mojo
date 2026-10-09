"""`komira_http_auth`: bearer-JWT authentication for komira_http_server.

`BearerJwtMiddleware[V]` sits in the server's auth slot. It reads
`Authorization: Bearer <token>`, hands the token to a `BearerVerifier` `V`,
and either sets `ctx.principal` (scheme "jwt") or refuses as RFC 6750 says:
401 with a bare `Bearer` challenge when no credential or one credential of
another scheme was sent; 400 `invalid_request` for a malformed header or for
two credentials of any schemes (two Authorization fields, which the HTTP/1
parser folds into `a, b`: a comma outside a quoted-string followed by a
second credential, an empty element, or a list holding Bearer; middleware.mojo
states the rule exactly); 401 `invalid_token` for a token that fails
verification; and 503 with `Retry-After` when no usable key set exists. A
trust anchor configured by flags has no defaults: every member is required. This release ships one verifier kind,
`Rs256JwksVerifier`: RS256 tokens of one issuer (for example Google
service-account ID tokens) checked against that issuer's JWK Set, which it
fetches over HTTPS and caches.

AUTHENTICATION IS NOT AUTHORIZATION. A Google service-account ID token that
passes every check proves only that SOME service account asked for a token
with our audience, and the audience is not a secret: anyone can mint such a
token from their own project. The embedder must authorize the principal
against an allowlist, by `sub` (the stable numeric id) or by `email` together
with `email_verified` (both copied with --copy-claim).

Modules:
  - middleware.mojo : `BearerJwtMiddleware`, the Authorization header parse,
                      the 400 / 401 / 503 responses.
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

The package root exports what an embedder needs: the middleware and its
challenge values, the verifier and its trait, the configuration and flags,
the fetcher and clock traits with their production and test conformers. The
parsing and validation helpers and the reason codes stay importable by module
path (`komira_http_auth.reasons` and so on).

No pointer type in any public signature; configuration comes from flags,
never from the environment. RS256 signatures are checked by komira_jose's
`JwsVerifier`; this package adds no verifier of its own.
"""

from .clock import AuthClock, FixedAuthClock, SystemAuthClock
from .config import BearerJwtConfig, TrustAnchor
from .flags import bearer_jwt_flag_names, parse_bearer_jwt_flags
from .jwks_fetch import (
    HttpsJwksFetcher,
    JwksFetchResult,
    JwksFetcher,
    ScriptedJwksFetcher,
)
from .middleware import (
    BearerJwtMiddleware,
    WWW_AUTHENTICATE_BEARER,
    WWW_AUTHENTICATE_INVALID_REQUEST,
    WWW_AUTHENTICATE_INVALID_TOKEN,
)
from .verifier import BearerVerifier, Rs256JwksVerifier, VerifyOutcome
