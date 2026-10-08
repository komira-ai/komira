# HTTP authentication and authorization: bearer JWTs, trust anchors and a remote decision point

Status: partly built. One slice is in review: the bearer-JWT middleware with one RS256 trust anchor (#810, stacked
on #790). The rest is design, and each section says which. Where this document says "today" it means the code on
`main` plus #790 and #810; "target" marks what that code does not do yet, with the package that delivers it.

## What is it for, and what is out of scope?

A komira HTTP service (a resource server, in OAuth terms) needs two answers for every request: who is calling,
and may they do this. komira's answer is one generic layer that any issuer and any decision point can sit behind:

1. **Authentication.** Verify a bearer JWT access token (RFC 6750, RFC 9068) against an issuer's published JWK Set,
   then put a typed `Principal` on the request. Any OAuth or OpenID Connect issuer can be a trust anchor.
2. **Authorization as a port.** `AuthzPort.check(principal, action, resource)`. Three bindings: a remote policy
   decision point (PDP) on the OpenID AuthZEN Authorization API 1.0 wire, with the only decision cache;
   `AllowAuthenticatedAuthz` (a single-user deployment); `DenyAllAuthz` (the default when nothing is configured).
3. **Declared resources.** Every route is declared, as governed (an action on a resource kind and id) or as public,
   or it is denied.
4. **Client credentials.** A service proves its own identity to the PDP, or to another service, with a short-lived
   token from the issuer's token endpoint: OAuth `client_credentials` (RFC 6749 section 4.4) with `private_key_jwt`
   client authentication (RFC 7523 section 2.2).

Out of scope, by design: minting user tokens, a user store, sessions, MFA, API keys, a policy store or role engine, a
client registry. Those belong to whoever runs the issuer and the PDP. komira ships the verifier, the client and the
contract, and names no issuer, no deployment and no party of its own. Deferred: browser login (OIDC authorization
code with PKCE), token exchange (RFC 8693), DPoP (RFC 9449), mTLS-bound tokens (RFC 8705), AuthZEN search endpoints.

## What exists, and what is missing?

| piece | package | state |
|---|---|---|
| `Principal{scheme, subject, claims, presented}`, `PresentedCredential` | `komira_http_server` | #790. On `main` a `Principal` is a subject and claims only. |
| `AuthzPort`, `AuthzAction`, `AuthzResource{kind, id, attributes}`, the two reference conformers | `komira_authz_api` | #790 replaces `main`'s scope-shaped `AuthzResource` with an opaque `kind` and `id`. |
| strict JWK and JWK Set parse and render: OKP Ed25519, EC P-256, RSA 2048 to 4096 bits | `komira_jwks` | on `main` |
| `komira_json.refuse_duplicate_keys` | `komira_json` | on `main` |
| RS256 JWS verify against a JWK Set | `komira_crypto/rs256_jwks.mojo` | on `main` |
| `BearerJwtMiddleware[V]`, `Rs256JwksVerifier`, the JWKS cache, the flags | `komira_http_auth` | #810: one RS256 trust anchor per process |
| ES256 and EdDSA verify, a strict JOSE header and claims policy shared by every algorithm, signing, a key ring | `komira_jose` | target, not written. The RS256 verifier moves here from `komira_crypto`. |
| several trust anchors per process, chosen by exact `iss` | `komira_http_auth` | target, after `komira_jose` |
| `client_credentials` client, RFC 8414 metadata and RFC 7591 registration codecs | `komira_oauth` | target |
| `RemoteAuthzPort` on AuthZEN, with the decision cache and batch `check_many` | `komira_authz_client` | target |
| route catalog and deny-by-default gate | `komira_resource_gate` | target |
| an in-process issuer and an in-process AuthZEN PDP for tests | `src/tests/helpers/komira_test_issuer`, `komira_test_pdp` | target. They are the executable spec of this document: any issuer or PDP that claims this contract passes their scenario tables. |

## How it works

### The principal

`Principal` has four fields:

- `scheme`: `jwt` (set by `BearerJwtMiddleware`) or `session` (set by an embedder's session middleware). The
  constructor raises on any other value, so a new scheme takes a komira change. A reader that expects one scheme
  refuses the others.
- `subject`: the verified `sub`. It is never empty.
- `claims`: a string map. The middleware sets `iss` (the verified issuer, so a consumer can tell anchors apart) and
  `aud` (our audience, the value that matched, even when the token listed several), then each claim named by
  `--copy-claim` that the token carries: a string verbatim, any other JSON value as its compact JSON text. A claim
  that is not named is dropped. Target: the middleware also sets `scope` and `client_id` (RFC 9068) when present.
- `presented`: the token itself, as a `PresentedCredential`. It is not `Writable`; `redacted()` returns fixed text,
  and `expose()` is the only public way to read it; the field is private by convention only (Mojo does not enforce
  the leading underscore). `RemoteAuthzPort` forwards it to the PDP.

Open code never reads a claim by a name it did not configure. A service that keys anything on a claim (an allowlist
of callers, a data partition) names that claim with `--copy-claim` and keys on it itself.

### The middleware, request by request

`BearerJwtMiddleware[V]` sits in `komira_http_server`'s user-middleware slot. For every request it:

1. clears `ctx.principal`;
2. reads `Authorization`. The credential comes from `Authorization: Bearer <token68>` only, never from the query
   string or a cookie. Target: a route may opt in to reading the token from the password of HTTP Basic (git and
   git-lfs clients send Basic); it is off by default and scoped per route;
3. asks the verifier `V` (below);
4. on success, replaces `ctx.principal` with a new `Principal`. It never merges into an earlier one.

The middleware logs nothing. Every refusal carries a fixed reason code (`komira_http_auth/reasons.mojo`), which
`last_reason()` returns to the embedder and which is safe to log and count. No response carries any part of the token.

### Checks on a token, in order

Header, before any key work or signature check:

- the token is three unpadded base64url segments;
- the header is a JSON object with no repeated member name (RFC 7515 section 5.2);
- `alg` equals the one algorithm pinned for the trust anchor. `none`, every `HS*` and every other algorithm are
  refused by name;
- `jwk`, `jku`, `x5u` and `x5c` are refused: the key always comes from the anchor's configured key set, never from
  the token;
- `crit` is refused whatever it lists: the verifier understands no extension;
- `typ` equals the one type pinned for the trust anchor (see Trust anchors);
- `kid` is present and printable ASCII.

Key and signature: the key whose `kid` matches, from the anchor's key set. An unknown `kid` triggers at most one
refetch per refetch window (see the key set, below) and is then refused. Today the RS256 signature is checked by
`komira_crypto`'s `verify_rs256_jws`; target, every algorithm through `komira_jose`.

Claims, only after the signature verifies (the payload is decoded again from its signed segment, with no repeated
member name, RFC 7519 section 4):

- `iss` is a string equal to the anchor's issuer, byte for byte;
- `aud` is a string equal to our audience, or a non-empty array of strings that contains it;
- `sub` is a non-empty string;
- `exp` and `iat` are required; `nbf` is optional. Each is an integer number of seconds (no fraction, exponent,
  string or negative value);
- with `leeway` the configured clock skew: refused when `now >= exp + leeway`, when `iat > now + leeway`, and when
  `nbf > now + leeway`;
- `exp - iat` is positive and at most the anchor's max TTL.

### Trust anchors

A trust anchor answers "whose signature do we accept, for whom": one issuer, one audience (ours), one JWK Set URL,
one `alg`, one `typ`, one longest lifetime. An anchor never accepts a second algorithm, a second type or a second issuer. RS256 is
not widened into a verifier that accepts ES256, or the reverse: an issuer that will sign an RS256 token for anyone
(a cloud's service-account ID tokens, for example) must never reach a verifier that trusts another issuer's keys.

Today a process accepts exactly one anchor, and it must be RS256 with `typ` `JWT` (the case built first: a cloud's
service-account ID tokens). Target, in `komira_http_auth` after `komira_jose`:

- `alg` per anchor is one of `ES256`, `EdDSA` or `RS256`; `typ` per anchor is exactly one of `at+jwt` (RFC 9068) or
  `JWT`, a property of the issuer's token format. An issuer's own access tokens are `at+jwt`; `JWT` is for an issuer
  whose format is fixed elsewhere (a cloud's service-account ID tokens). An anchor never accepts a set of `typ`
  values: there is no allowance for an issuer moving between token types;
- several anchors per process. A token goes to the one anchor whose `issuer` equals its `iss` exactly, and is then
  checked only against that anchor's key set and pinned `alg`. There is no fall-through to a second anchor. The `iss`
  that chooses is unauthenticated until the signature verifies; that is safe only because each anchor pins its own
  keys and algorithm, so a token signed by issuer A that claims issuer B's `iss` reaches B's anchor and fails its
  `alg` or its signature;
- two anchors with one `issuer`, or one `name`, refuse startup.

Whether RS256 issuers beyond cloud service-account tokens (the enterprise identity providers that sign RS256 by
default) are a documented, tested configuration is an open question; the per-anchor pin is what makes it safe either way.

### The key set

Each anchor's key set is fetched from its `jwks_url`:

- **HTTPS only**, with certificate verification against the TLS library's default trust store (which honours
  `SSL_CERT_FILE` and `SSL_CERT_DIR`). An `http://` URL, a URL with userinfo or a fragment, or one with no host,
  refuses startup.
- **Freshness.** The smallest `Cache-Control: max-age=N` of a successful fetch, clamped to 0 to 86400 s; `no-store`
  or `no-cache` mean 0. With neither, a default of 300 s (code-only setting).
- **Refetch rate limit.** Every refresh (no keys yet, keys past their max-age, or an unknown `kid`) is limited to one
  fetch per refetch window (60 s by default, code-only setting), counted from the last attempt, successful or not.
  A stream of tokens naming made-up `kid`s costs at most one fetch per window, and every one of them is refused.
- **Whole documents only.** A fetched document replaces the current keys only if: the status is 200 and the body is
  1 byte to 256 KiB; the body is strict JSON with no repeated member name at any depth; `keys` is an array of 1 to 64
  objects; every signing key the anchor's algorithm can use has a printable-ASCII `kid`, and no two share one; and
  every such key parses. Otherwise the current set is kept, unchanged. A document that publishes one `kid` twice
  never replaces a working set.
- **Bounded staleness.** When refreshes fail, the last good set stays in use until its freshness plus the max-stale
  time (`--jwks-max-stale`, default 1 h, 0 s to 24 h). Past that, every token is refused with `503` until a refresh
  succeeds. Without the bound, anyone who can block the HTTPS fetch (no certificate needed) would keep a key the
  issuer has withdrawn trusted for as long as the block lasts. A set that was never fetched is also unusable.
- **Fetch cost.** The fetch runs on the serving worker's thread and stalls that worker, at most once per refetch
  window. The fetch timeout (5 s by default, 100 ms to 60 s, code-only setting) bounds the TLS handshake and the
  request separately; the TCP connect adds up to 5 s, and DNS resolution has no bound. Each verifier owns its cache,
  so N serving workers make N fetches.

An issuer that rotates keys publishes the new key before signing with it, and keeps the old key published until the
anchor's max TTL plus the leeway has passed since the switch.

### Flags

Every flag is `--name=value`. A bare word, a flag without `=`, an empty value, an unknown name and a single-valued
flag given twice are refused at startup. Nothing here is read from the environment. The embedding binary splits its
own argv: `bearer_jwt_flag_names()` lists the names `parse_bearer_jwt_flags` owns.

A trust anchor has **no defaults**: the six single-anchor flags, or all seven members of `--trust-anchor`, are
required. A later release that brought different defaults (another `alg`, `typ` or lifetime) would silently change
what a running deployment accepts.

| flag | exact semantics |
|---|---|
| `--issuer=URL` | the `iss` accepted, compared byte for byte (`https://accounts.google.com` does not accept `accounts.google.com`) |
| `--audience=STRING` | our audience: `aud` must equal it or be an array that contains it |
| `--jwks-url=URL` | the anchor's JWK Set: `https://<host>/...`, no userinfo, no fragment |
| `--jwks-alg=ALG` | the one `alg` accepted. Today `RS256` only; target `ES256`, `EdDSA` or `RS256` |
| `--accept-typ=TYP` | the one header `typ` accepted. Today `JWT` only; target `at+jwt` or `JWT`, never a set |
| `--max-ttl=SECONDS` | the longest `exp - iat` accepted, 1 to 86400. An issuer's own access tokens are typically minutes; cloud ID tokens and many identity providers issue tokens of an hour |
| `--trust-anchor=name=N,issuer=I,audience=A,jwks_url=U,alg=ALG,typ=TYP,max_ttl=S` | the general form of the six flags above, every member required; an unknown, repeated or empty member is refused, and a value cannot hold a comma. It cannot be combined with the six flags. Today a second `--trust-anchor` is refused; target, it is repeated, one per anchor |
| `--copy-claim=NAME` | repeated: a payload claim copied into `Principal.claims`. An empty name, a repeated name, or `sub`, `iss` or `aud` (which the principal sets itself) is refused at startup; target, `scope` and `client_id` too, once the middleware sets them |
| `--leeway-s=SECONDS` | the clock skew forgiven on `exp`, `iat` and `nbf`: 0 to 60, default 30 |
| `--jwks-max-stale=DURATION` | how long past its freshness the last good key set stays in use while every refresh fails: digits and one unit, `s`, `m` or `h` (`90s`, `30m`, `1h`), 0 s to 24 h, default `1h` |

`--leeway-s` and `--max-ttl` take bare seconds; `--jwks-max-stale` takes digits and a unit. A new flag uses one of
these two forms. The refetch window, the default max-age and the fetch timeout have no flags; an embedder sets them
with `BearerJwtConfig`'s `with_*` methods.

Target flags for authorization (`komira_authz_client`, `komira_oauth`): `--authz=remote` with `--authz-url` (the
PDP's evaluation URL), `--authz-token-url`, `--authz-client-id` and `--authz-client-key` (a secret-store reference,
never the key itself); or `--authz=allow-authenticated`. With no `--authz`, every governed route is denied.

### Client credentials (target: `komira_oauth`)

A service that calls the PDP, or another service, is an OAuth client. It gets a short-lived token for one audience
from the issuer's token endpoint and presents it as a bearer token:

- request: `POST` form-encoded `grant_type=client_credentials`,
  `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`, `client_assertion=<JWS>`,
  `resource=<audience>` (RFC 8707, one per request), optional `scope`;
- assertion: `alg` ES256 or EdDSA, `kid` of a key in the client's registered set; `iss = sub = client_id`, `aud` the
  issuer or the token endpoint URL, `iat`, `exp <= iat + 300`, `jti` of at least 128 random bits. An assertion is used
  once, at the token endpoint, never on a call to a service;
- the issuer verifies the assertion against the client's registered keys, read per request (deleting the record or
  the key revokes the client), refuses a `jti` seen before its `exp`, and refuses a `resource` its policy does not
  allow (`400 invalid_target`);
- response `200`, `Cache-Control: no-store`: `{access_token, token_type: "Bearer", expires_in, scope?}`; the token has
  `sub = client_id`, `client_id`, `aud` = the requested resource, `jti`;
- `ClientCredentialSource` fetches on first use, refreshes 60 s before `exp`, keeps one refresh in flight per
  (client, resource), and on failure raises: it never serves a token past its `exp`.

The registration record type and its JSON codec (RFC 7591: `client_id`, `client_name`, `jwks` or `jwks_uri`,
`token_endpoint_auth_method: "private_key_jwt"`, `grant_types: ["client_credentials"]`, `scope`, and one extension
member `resource_types`) are in `komira_oauth`. The registry is the issuer's. A client never registers itself; the
private key stays in the client's secret store and only the public key enters the record.

### The decision point (target: `komira_authz_client`)

`RemoteAuthzPort` asks a PDP on the OpenID AuthZEN Authorization API 1.0 wire, with a komira profile:

`POST {pdp}/access/v1/evaluation`, `Authorization: Bearer <the asking service's client token, aud = the PDP>`:

```json
{"subject": {"type": "jwt_sub", "id": "<sub>", "properties": {"token": "<the bearer token that reached the service>"}},
 "action": {"name": "read"},
 "resource": {"type": "<kind>", "id": "<opaque id>"},
 "context": {"audience": "<the asking service's client_id>"}}
```

The subject token is the bearer token that reached the asking service (the policy enforcement point, PEP). It is a
user's token (`subject.type` `jwt_sub`) or, when a service calls the PEP, that service's client token
(`subject.type` `client`, `subject.id` = its `client_id`). Every subject comes from a signed token; there is one
evaluation path.

**Safety conditions.** A PDP that serves this profile:

1. verifies the bearer (the asking service's client token) and requires its `aud` to be the PDP;
2. takes the subject **only** from `subject.properties.token`, verified against its own issuer's keys; requires
   `subject.id == token.sub`, `subject.type` to match the token, and `token.aud == context.audience ==
   bearer.client_id`;
3. never logs the request body (it carries a bearer token); it may log the decision, `subject.type`, `token.sub`,
   `action.name`, `resource.type` and `resource.id`;
4. maps an unknown `action.name` to its strictest tier and denies an unknown `resource.type`;
5. answers `200 {"decision": true|false, "context"?: {"max_age_s"?: <int>}}` with `Cache-Control: no-store`.

AuthZEN itself lets a PDP trust the PEP's `subject.id`. A generic AuthZEN PDP that ignores `properties.token` does
exactly that; it is AuthZEN's own trust model, acceptable for a single-operator deployment, and it does not meet
condition 2.

Batch: `POST {pdp}/access/v1/evaluations` with a shared `subject`, `action` and `context` and an `evaluations` array
of resources, answered `{"evaluations": [{"decision": ...}, ...]}` in request order, at most 100 per call
(`check_many`, for listing pages).

Client semantics (each row has a mutant in `komira_authz_client`'s tests):

| PDP answer | result | cached |
|---|---|---|
| 200 with a top-level JSON boolean `decision` | that decision | see below |
| 200 without one, a `decision` only nested inside another member, or an unreadable body | unavailable | never |
| 401 | refresh the client token once and retry once; then unavailable | never |
| 400, 403 | unavailable, logged as a misconfiguration | never |
| 429, 5xx, a timeout | unavailable | never |

The body is read with `komira_json`, never by substring search: a body `{"decision":false,"x":{"decision":true}}` is
a deny, and anything the client cannot read as a top-level boolean is unavailable.

Vocabulary: `action.name` is `read`, `write`, `delete`, `admin` or a service-namespaced verb (`<service>.<verb>`).
`resource.type` is a kind the service declares as data in its own package; the generic packages name none.
`resource.id` is an opaque string of at most 256 bytes. `attributes` are optional.

### Decision cache rules

- The PDP's and the token endpoint's responses carry `Cache-Control: no-store`. No shared or intermediary cache
  stores a decision.
- The only decision cache is in-process, inside `RemoteAuthzPort`, never shared between processes.
- Key: the PEP's own `client_id` (the credential the port presents), SHA-256 of the subject token, `audience`,
  `action`, `resource{type, id}`, and a hash of the attributes if any. Never an assertion's `jti`. The `client_id` is
  in the key so that a port holding two credentials, or two ports sharing a cache, never serve one PEP's allow to
  the other.
- Allow TTL: `min(300 s, subject token exp - now, context.max_age_s)`. The 300 s is a compile-time ceiling; a flag
  may only lower it, and the PDP may only shorten it.
- Deny TTL: at most 30 s, a compile-time ceiling, so retries do not hammer the PDP and a new grant shows within 30 s.
- Unavailable is never cached.
- Bounded buckets per credential, least recently used first; eviction never extends a TTL.

So a revoked grant stops being honoured within 300 s, or when the subject token expires, whichever comes first.

### Failure modes at the service

| situation | status | header |
|---|---|---|
| no `Authorization`, or one credential of another scheme | 401 | `WWW-Authenticate: Bearer` with no error code (RFC 6750 section 3.1) |
| a malformed `Authorization`, or two credentials (two fields, folded) | 400 | `WWW-Authenticate: Bearer error="invalid_request"` |
| any token refusal: malformed, header refused, unknown `kid`, bad signature, wrong `iss` or `aud`, expired, too long-lived | 401 | `WWW-Authenticate: Bearer error="invalid_token"`, with no `error_description`: nothing says which check failed |
| no usable key set (never fetched, or stale past max-stale) | 503 | `Retry-After`: seconds until the next refresh may start, at least 1; no challenge (the token was not judged) |
| decision false (target: the gate) | 403 | none. A service may answer 404 on an object read to hide existence |
| authorization unavailable (target: the gate) | 503 | `Retry-After` |

Today every refusal from the middleware has a fixed text body (`unauthorized`, `bad request`, `authentication
unavailable`). A denial and an outage are told apart, and neither is ever a 200: authorization fails closed. Target:
one JSON error envelope, `{"error": {"code", "message"}}`, for every service.

## What must always hold

- A token is checked against exactly one anchor, with that anchor's one `alg`, its own keys, and its own issuer.
- The key never comes from the token (`jwk`, `jku`, `x5u`, `x5c` are refused) and the header is refused before any
  key work.
- `ctx.principal` is replaced, never merged; a refused request leaves it empty.
- No response and no log line carries any part of a token; `PresentedCredential` has no printable form.
- A partial or failed key-set fetch never replaces the current keys, and stale keys stop being trusted after the
  max-stale bound.
- The decision cache is per process, keyed by the PEP's credential and the subject token's hash, and never extends
  an allow past 300 s or the subject token's `exp`.
- Unavailable is never an allow and never cached.
- Configuration is flags; an anchor has no defaults.

## Why it is built this way

- **Bearer JWTs plus a live decision.** A self-contained token proves who the caller is without a call per request;
  a short-lived cached decision keeps revocation bounded (300 s) without putting policy in the token.
- **One algorithm per anchor, no defaults.** The algorithm-confusion class closes at configuration time. With no
  defaults, upgrading komira never changes what a deployment accepts.
- **AuthZEN.** An open standard wire lets any AuthZEN PDP sit behind a komira service. The profile's safety
  conditions keep the rule that the subject comes from a signed token, never from the request body.
- **`private_key_jwt` at a token endpoint**, not a signed assertion on every call: the PDP verifies callers with the
  same bearer verifier as everyone else, `jti` replay is checked once, and any OAuth server can issue.
- **Fail closed, with 503 for outages.** A client can retry an outage and cannot mistake it for a denial.

## Where the code is

`src/komira_http_server/middleware/middleware.mojo` (`Principal`), `src/komira_authz_api`, `src/komira_jwks`,
`src/komira_crypto/rs256_jwks.mojo`; in review, `src/komira_http_auth` (`middleware.mojo`, `verifier.mojo`,
`claims.mojo`, `jwks_cache.mojo`, `jwks_fetch.mojo`, `flags.mojo`, `config.mojo`, `reasons.mojo`). Targets:
`src/komira_jose`, `src/komira_oauth`, `src/komira_authz_client`, `src/komira_resource_gate`,
`src/tests/helpers/komira_test_issuer`, `src/tests/helpers/komira_test_pdp`, `src/tests/conformance/jose_rfc_vectors`,
`src/tests/e2e/http_auth_roundtrip`.

## How it is tested

Every test is welded into its library's build. Today (#810): the header gate, the claims, the key cache, the flags
and the middleware each have a test file that asserts the reason code of every refusal, so a test proves which check
refused a token, not only that one did. Each package also scans its own sources for product vocabulary and early
dates.

Target, each step with its planted defects (a mutant that must turn a named test red):

- `komira_jose`: RFC 7515 appendix A.2 (RS256) and A.3 (ES256), RFC 8037 appendix A.4 (Ed25519) as fixed vectors;
  mutants: an EdDSA header accepted by an ES256 verifier, `alg: none`, a repeated `aud` member, a `crit` hiding an
  `alg`, `exp == now` accepted with zero leeway, an `aud` array without ours, a `kid` outside the set, `iat` in the
  future beyond the leeway.
- several anchors: the anchor chosen by `alg` instead of `iss`, or a fall-through to a second anchor (a token signed
  by one issuer that claims another's `iss` is admitted).
- `komira_oauth`: an assertion without `jti`; a replayed `jti` accepted by the test issuer; a stale token served after
  a failed refresh.
- `komira_test_pdp`: `subject.id` taken from the body instead of `properties.token` (the subject-mismatch scenario
  goes red).
- `komira_authz_client`: the nested-`decision` body read as an allow; an unescaped action; a cache key without the
  token hash (user B served user A's allow); a cache key without the PEP's `client_id`; a TTL not clipped to `exp`; the
  deny ceiling raised; an allow honoured after a revoke past 300 s on an advanced clock; a 5xx cached as a deny.
- `komira_resource_gate`: an unrouted path proceeds; a missing row is treated as public.
- the end-to-end round trip (test issuer, middleware, gate, test PDP): a gate built with `AllowAuthenticatedAuthz`
  instead of the remote port turns the revoke assertion red.

An issuer or PDP that claims this contract runs the `komira_test_issuer` and `komira_test_pdp` scenario tables
against itself.

## Limits

- Today one trust anchor per process, RS256 with `typ` `JWT` only.
- HTTP/2 requests do not reach the middleware: `komira_http_server`'s chained serving path closes HTTP/2
  connections.
- The key-set fetch stalls a serving worker, and DNS resolution has no time bound.
- Issuer discovery (RFC 8414 metadata from `--issuer` alone) is not built: `--jwks-url` is explicit.
- Optional RFC 9728 protected-resource metadata is not built.
- Authentication is not authorization. A token that passes every check here proves only that the anchor's issuer
  signed it for our audience; for an issuer that signs for anyone who asks (cloud service-account ID tokens), the
  audience is not a secret, and the service must still authorize the principal (an `AuthzPort`, or an allowlist on
  `sub`).
