# komira_http_auth

Bearer-JWT authentication for `komira_http_server`.

`BearerJwtMiddleware[V]` goes in the server's auth slot (the user middleware of
`serve_one_iteration_dispatch_chained`). For every request it:

1. clears `ctx.principal`;
2. reads `Authorization: Bearer <token>`. A missing or malformed header,
   including two headers folded into one, is answered
   `401` with `WWW-Authenticate: Bearer error="invalid_request"`;
3. asks the verifier `V`. Any refusal is answered `401` with
   `WWW-Authenticate: Bearer error="invalid_token"`;
4. on success sets `ctx.principal` to a new `Principal` with scheme `jwt`,
   subject `sub`, claims `iss`, `aud` (our audience) and each `--copy-claim`.
   The principal is replaced, never merged with an earlier one.

**Authentication is not authorization.** For Google service-account ID tokens,
a token that passes every check here proves only that SOME Google service
account asked for a token with your audience. The audience is any string the
requester chooses, so it is not a secret: anyone can create a service account in
their own project and get an ID token for `https://api.example.com/`, and that
token is accepted here. The embedder MUST then authorize the principal against an
allowlist, by `sub` (the account's stable numeric id) or by the `email` claim
together with `email_verified` being `true` (copy both with `--copy-claim`). Do
not treat "a principal is set" as "the caller is allowed".

The 401 body is fixed text. No response carries any part of the token, and the
middleware logs nothing. `last_reason()` returns the reason code of the last
decision (`reasons.mojo`), which is safe to log.

## The RS256 trust anchor

`Rs256JwksVerifier` accepts RS256 tokens from one issuer, such as Google
service-account ID tokens. It checks each token in this order:

- **Header gate**, before any key work. These are refused:
  - an `alg` other than the anchor's (`none`, `HS256`, `ES256` and the rest);
  - a `jwk`, `jku`, `x5u` or `x5c` member;
  - any `crit` member;
  - a `typ` other than the accepted one;
  - a missing `kid`, or one that is not printable ASCII;
  - a repeated JSON key;
  - padded or malformed segments.
- **Keys**, from the issuer's JWK Set, fetched over HTTPS:
  - freshness follows `Cache-Control: max-age`, with a default of 300 s;
  - an unknown `kid` causes at most one refetch per 60 s window and is then
    refused;
  - a document that does not parse whole, or that publishes one `kid` twice,
    never replaces the current keys;
  - when a refresh fails, the last good keys stay in use with no age limit
    (an open policy question: see `jwks_cache.mojo`);
  - a fetch runs on the serving worker's thread and stalls that worker while it
    runs, at most once per refetch window. The fetch timeout (5 s by default,
    at most 60 s, set with `BearerJwtConfig.with_jwks_fetch_timeout_us`)
    bounds the TLS handshake and the request separately. The TCP connect adds
    up to 5 s, and DNS resolution has no bound, so a fetch takes the DNS time
    plus at most 5 s + 2 x the fetch timeout.
- **Signature**, checked by `komira_crypto`'s `verify_rs256_jws`. This package
  adds no RS256 verifier of its own.
- **Claims**:
  - `iss` must match exactly;
  - `aud` must be ours, or an array that contains ours;
  - `sub` must be non-empty;
  - `exp` and `iat` are required;
  - `exp`, `iat` and `nbf` are checked with 30 s of leeway;
  - `exp - iat` must be at most the max TTL (3600 s by default).

There is one verifier per trust anchor. In this release a process accepts one
anchor. A second `--trust-anchor` is refused; choosing an anchor per token is
planned for a later release.

## Flags

All flags use the form `--name=value`. The clock leeway and the JWKS refetch
window, default max-age and fetch timeout have no flags: set them with
`BearerJwtConfig`'s `with_*` methods. No setting of this package is read from
the environment. The TLS library's default trust store, used for the JWKS
fetch, does honour `SSL_CERT_FILE` and `SSL_CERT_DIR`.

| flag | meaning |
|---|---|
| `--issuer` | the exact `iss` accepted |
| `--audience` | our audience |
| `--jwks-url` | the issuer's JWK Set; must be `https://` |
| `--jwks-alg` | `RS256`, the only value accepted, and the default |
| `--accept-typ` | `JWT`, the only value accepted, and the default |
| `--max-ttl` | the longest `exp - iat` accepted, in seconds (default 3600) |
| `--copy-claim` | a claim copied into the principal (may be repeated) |
| `--trust-anchor` | `name=,issuer=,audience=,jwks_url=[,alg=][,typ=][,max_ttl=]`: the general form of the first six flags, and cannot be combined with them |

## Example

In production the verifier is
`Rs256JwksVerifier[HttpsJwksFetcher, SystemAuthClock](config, HttpsJwksFetcher(), SystemAuthClock())`.
This example uses the test doubles, so it does no network I/O:

```mojo
from std.testing import assert_equal, assert_false
from komira_http_auth import BearerJwtMiddleware, Rs256JwksVerifier, parse_bearer_jwt_flags
from komira_http_auth import FixedAuthClock, ScriptedJwksFetcher, WWW_AUTHENTICATE_INVALID_REQUEST
from komira_http_core.codec.types import HttpRequest
from komira_http_server.middleware import RequestContext

comptime ExampleVerifier = Rs256JwksVerifier[ScriptedJwksFetcher, FixedAuthClock]

var args = List[String]()
args.append("--issuer=https://accounts.google.com")
args.append("--audience=https://api.example.com/")
args.append("--jwks-url=https://www.googleapis.com/oauth2/v3/certs")
args.append("--copy-claim=email")
args.append("--copy-claim=email_verified")
var config = parse_bearer_jwt_flags(args)

var verifier = ExampleVerifier(config, ScriptedJwksFetcher(), FixedAuthClock(1800000000))
var auth = BearerJwtMiddleware[ExampleVerifier](verifier^)

# A request with no Authorization header is refused before any key work.
var req = HttpRequest()
var ctx = RequestContext.new()
var refused = auth.before(req, ctx)
assert_equal(Int(refused.value().status), 401)
assert_equal(refused.value().headers["www-authenticate"], WWW_AUTHENTICATE_INVALID_REQUEST)
assert_false(Bool(ctx.principal))
```
