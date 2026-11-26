# OIDC issuer: endpoints, PKCE, refresh, keys, claims and the federation port

Status: design. Nothing in this document is built yet. The pieces it builds on are on `main`: signing, verifying and
the key ring in `jose`, JWK Set parse and render in `jwks`, the token-endpoint wire codecs and the client in `oauth`,
the bearer middleware in `http_auth`, and the in-process test issuer in `src/tests/helpers/komira_test_issuer`.
Items still open are marked **proposal** with the number of their open decision (D1, D2, D12), listed in
[Open decisions](#open-decisions).

## What is it for, and what is out of scope?

A deployment runs several apps. People sign in once, and every app checks their tokens itself, offline, against
published keys. There is no edge proxy that checks tokens for the apps. [http_auth.md](http_auth.md) specifies the
verifier and the client side of that contract and leaves the issuer to "whoever runs it". This document specifies
the issuer, so that it can be built and so that a conformance suite can hold it to the spec.

The issuer is an OpenID Connect provider and an OAuth 2.0 authorization server:

1. **Browser sign-in.** The authorization code flow (RFC 6749 section 4.1) with PKCE (RFC 7636), always.
2. **Short tokens and a bounded session.** Access tokens last 15 minutes. A refresh token renews them, and is rotated
   on every use, until the session ends 8 hours after sign-in (proposal, D12).
3. **Service identity.** An app calls other apps as itself with `client_credentials` and `private_key_jwt` client
   authentication (RFC 7523), on the wire `http_auth.md` already fixes.
4. **Roles per app.** A token carries a `roles` map from an app's client id to the role names that person holds in
   that app (proposal, D2).
5. **Federation.** The issuer has no passwords and no login form. It sends people to one upstream identity provider
   through a port, `UpstreamIdentity`, and admits only people who hold a membership.
6. **Removal notices.** When a member is removed, the issuer posts a signed notice to every app that asked for one.

The issuer is written in Mojo on komira's packages (proposal, D1).

Out of scope: a login form, passwords and MFA (the upstream provider owns them); a consent screen (every client is
registered by an administrator, so there is nothing for a person to consent to); dynamic client registration (RFC
7591 section 3, the endpoint); the implicit and hybrid flows; the device flow; token exchange (RFC 8693); DPoP (RFC
9449); front-channel and back-channel logout; pairwise subjects; agent identities and API keys. Each is refused by
name where a request could ask for it.

## What exists, and what is missing?

| piece | package | state |
|---|---|---|
| ES256, EdDSA and RS256 signing and verifying, one algorithm per signer | `jose` | on `main` |
| `Keyring`: one signing key, one staged key, up to 4 retiring keys; publish before sign; retire after max TTL plus leeway | `jose` | on `main`; in memory only |
| RFC 7523 assertions: `mint_client_assertion`, `verify_client_assertion` (1 to 300 s, `jti` required) | `jose` | on `main`; the `jti` replay memory is the caller's |
| explicit `typ` values `at+jwt` and `JWT` in `ClaimPolicy` | `jose` | on `main`; the removal notice needs a third, `removal+jwt` (additive) |
| JWK and JWK Set parse and render (OKP Ed25519, EC P-256, RSA) | `jwks` | on `main` |
| form codec, `client_credentials` request parser, token response and error codecs, RFC 8414 metadata, RFC 7591 client record | `oauth` | on `main`; the client record knows `client_credentials` only, and the token response has no `refresh_token` or `id_token` member |
| bearer middleware and JWKS cache | `http_auth` | on `main` for one RS256 anchor with `typ` `JWT`; ES256 anchors with `typ` `at+jwt` are its target |
| a PEM PKCS#8 loader for a P-256 private key | `crypto` | missing: only the RSA loader exists |
| cookies, redirects and TLS in front of an app handler | `http_server` | missing: the issuer runs behind a TLS-terminating front and writes its own `Set-Cookie` and `Location` headers |
| the issuer: endpoints, sessions, codes, refresh families, the ports below | `oidc_issuer` (new) | this document |

The new packages: `oidc_issuer` holds the protocol (parsers, the session, code and refresh state machines, the claim
builders, the ports and their fakes) and reads no clock and no network itself; `oidc_issuer_http` binds it to
`http_server`; `oidc_issuer_upstream_oidc` is the generic upstream adapter. The issuer names no deployment, no product
and no vendor: each package carries the product-vocabulary test the other auth packages carry.

## The issuer's identity

- **Issuer URL.** `--issuer=URL`: an `https` origin with no path, query, fragment or userinfo, no trailing slash,
  and at most 256 bytes (`https://id.example.com`). It is the `iss` of everything the issuer signs, compared byte for byte by every
  verifier. Without a path, the RFC 8414 and the OpenID Connect discovery URLs are both simple suffixes.
- **One issuer per deployment.** A person is the pair (`iss`, `sub`): two issuers may mint the same `sub`, and an app
  trusts only the one issuer it is configured with.
- **Endpoints**, all under the issuer URL:

| endpoint | method | path |
|---|---|---|
| discovery (OpenID Connect) | `GET` | `/.well-known/openid-configuration` |
| discovery (RFC 8414) | `GET` | `/.well-known/oauth-authorization-server` |
| keys | `GET` | `/.well-known/jwks.json` |
| authorization | `GET`, `POST` | `/authorize` |
| upstream return | `GET` | `/upstream/callback` |
| token | `POST`, `OPTIONS` | `/token` |
| user info | `GET`, `POST`, `OPTIONS` | `/userinfo` |
| end session | `GET`, `POST` | `/end-session` |

Any other path is `404`; a known path with another method is `405` with `Allow`. Not served: revocation (RFC 7009;
`/end-session` ends a session and its refresh tokens), introspection (RFC 7662; tokens are self-contained),
registration (RFC 7591 section 3), pushed authorization requests (RFC 9126), and `request` and `request_uri`
objects.

**Cross-origin requests.** A public client runs in a browser on its own origin and calls `/token` and `/userinfo`
from there. Those two endpoints answer CORS: when the request's `Origin` equals the origin (scheme, host and port) of
one of the redirect URIs of the client the request names (`client_id` for `/token`; the token's `client_id` for
`/userinfo`), the reply carries `Access-Control-Allow-Origin: <that origin>` and `Vary: Origin`; otherwise no CORS
header. A preflight `OPTIONS` to them answers `204` with `Access-Control-Allow-Methods: POST` (and `GET` for
`/userinfo`), `Access-Control-Allow-Headers: Authorization, Content-Type` and `Access-Control-Max-Age: 600`, and
the same `Allow-Origin` rule, which the preflight checks against every client whose redirect URIs share that origin.
Discovery and the key set answer `Access-Control-Allow-Origin: *`. No endpoint sends
`Access-Control-Allow-Credentials`; `/authorize` and `/end-session` are top-level navigations and send no CORS
header.

## Clients

A client is a registered app. The issuer reads clients from the `ClientStore` port on every request; nothing is
cached past one request, so disabling a client takes effect on its next request. A client record holds:

| member | meaning |
|---|---|
| `client_id` | 1 to 64 bytes of `[a-z0-9-]`, starting with a letter, never starting with `u-`. It is also the app's **audience**: the `aud` of tokens for that app, and the key of the app in `roles` |
| `active` | false once the app is retired, for good (a retired `client_id` is never active again): every request from it is `invalid_client`, and its roles leave new tokens |
| `token_endpoint_auth_method` | `private_key_jwt` (a confidential client: an app with a backend) or `none` (a public client: an app that runs only in the browser) |
| `jwks` or `jwks_uri` | the client's public keys, for `private_key_jwt` only; exactly one of them |
| `token_endpoint_auth_signing_alg` | `ES256` or `EdDSA`: the one algorithm its assertions are verified with |
| `grant_types` | a non-empty subset of `authorization_code`, `refresh_token`, `client_credentials`. `refresh_token` needs `authorization_code`; `client_credentials` needs `private_key_jwt` |
| `redirect_uris` | needed with `authorization_code`: 1 to 10 absolute `https` URLs with no fragment; `http://127.0.0.1:<port>/...` is allowed for local development only when the client is public |
| `post_logout_redirect_uris` | 0 to 10 URLs, same rules |
| `resources` | the audiences of other apps this client may get tokens for (RFC 8707), 0 to 64 client ids |
| `roles` | the role names the app understands, 0 to 32, each `[a-z][a-z0-9_-]{0,31}` |
| `scope` | optional, `client_credentials` only: the scope values a service token for this client may carry (RFC 7591 `scope`, `oauth`'s scope syntax) |
| `removal_notice_url` | optional: where removal notices for this app are posted (see [Removal notices](#removal-notices)) |

The record is RFC 7591 client metadata plus the extension members `resources`, `roles` and `removal_notice_url`.
`oauth`'s `ClientMetadata` grows to carry `redirect_uris`, `post_logout_redirect_uris`, the three extensions, the
auth method `none` and the two browser grant types, additively: a record it parses today still parses and means the
same. Its existing extension member `resource_types` stays as it is, with the meaning `http_auth.md` gives it; the
issuer does not read it. Two of today's parser rules are relaxed, and only for records that use the new members:
`grant_types` may be any allowed subset instead of exactly `["client_credentials"]`, and the auth method may be
`none` for a client without `client_credentials`. There is no client secret, anywhere: a confidential client proves
itself with a key whose private half never leaves it.

All client ids, redirect URIs and URLs in a record are checked when the record is read, and a record that breaks a
rule above makes that client unusable (`invalid_client`, or the `400` page at `/authorize`) rather than half-usable.

## Discovery

`GET /.well-known/openid-configuration` and `GET /.well-known/oauth-authorization-server` return the same document,
`200`, `Content-Type: application/json`, `Cache-Control: public, max-age=3600`. With `https://id.example.com` as the
issuer, the document is exactly:

```json
{"issuer":"https://id.example.com",
 "authorization_endpoint":"https://id.example.com/authorize",
 "token_endpoint":"https://id.example.com/token",
 "jwks_uri":"https://id.example.com/.well-known/jwks.json",
 "userinfo_endpoint":"https://id.example.com/userinfo",
 "end_session_endpoint":"https://id.example.com/end-session",
 "scopes_supported":["openid","profile","email"],
 "response_types_supported":["code"],
 "response_modes_supported":["query"],
 "grant_types_supported":["authorization_code","refresh_token","client_credentials"],
 "subject_types_supported":["public"],
 "id_token_signing_alg_values_supported":["ES256"],
 "token_endpoint_auth_methods_supported":["private_key_jwt","none"],
 "token_endpoint_auth_signing_alg_values_supported":["ES256","EdDSA"],
 "code_challenge_methods_supported":["S256"],
 "claims_supported":["iss","aud","sub","exp","iat","auth_time","nonce","at_hash","sid","org","roles","name","email","picture"],
 "authorization_response_iss_parameter_supported":true,
 "request_parameter_supported":false,
 "request_uri_parameter_supported":false}
```

Members appear in this order, rendered compactly on one line. `oauth`'s `parse_authorization_server_metadata` reads
it as it is (it ignores the members it does not model).

## Keys

### The algorithm: ES256

Every token, ID token and notice the issuer signs is ES256 (ECDSA on P-256 with SHA-256, RFC 7518 section 3.4).
EdDSA was the other candidate. ES256 is chosen because:

- **Relying parties outside komira verify it.** Every mainstream JOSE library and every browser's WebCrypto verify
  ES256; Ed25519 support is newer and patchier in both. An app that sits behind an off-the-shelf OIDC library must
  be able to verify our tokens; that is the reason to speak OIDC at all.
- **komira already signs and verifies it safely.** `jose`'s ES256 signer derives its nonce deterministically (RFC
  6979), so a weak random source cannot leak the key, which removes EdDSA's main practical advantage.
- **It is the algorithm `http_auth`'s target anchors take** (`--jwks-alg=ES256`, `--accept-typ=at+jwt`).

The cost: the P-256 PEM loader is missing from `crypto` and must be added (an Ed25519 key would have been a fixed
prefix and a 32-byte seed). One known departure from OpenID Connect Discovery 1.0, which says
`id_token_signing_alg_values_supported` must include `RS256`: this issuer signs ES256 only, and a relying party that
can verify only RS256 is not supported. The departure is named in the conformance profile below.

Client assertions are verified with the algorithm the client registered, ES256 or EdDSA; that is the client's key,
not the issuer's.

### Supplying the keys: files, never the environment

| flag | meaning |
|---|---|
| `--signing-key-file=PATH` | required. The active key: a PEM `PRIVATE KEY` (PKCS#8) holding a P-256 key. It signs everything |
| `--next-signing-key-file=PATH` | optional. The staged key, same format. Published in the key set, never used to sign |
| `--retiring-key-file=PATH` | optional, repeated, at most 4. A key that signed recently: a PEM `PUBLIC KEY` (SPKI), or a `PRIVATE KEY` whose public half is derived and whose private half is wiped at once. Published, never used to sign |

A key file is read once at startup into a `SecretValue`; a file that is missing, unreadable, larger than 4096 bytes,
not exactly one PEM block of the right label, or not a P-256 key refuses startup with a message that names the flag
and the path and never any byte of the file. The issuer never reads a key from an environment variable, from argv,
or from the store. Generating keys is the operator's job with ordinary tools (`openssl genpkey -algorithm EC
-pkeyopt ec_paramgen_curve:P-256`).

### The key id

`kid` is the RFC 7638 JWK thumbprint of the public key: `jose`'s `JwsSigner.kid()` and `jose.jwk_thumbprint`. It is
derived, never configured, so one key always has one `kid` and two different keys never share one.

### The published key set

`GET /.well-known/jwks.json` answers `200`, `Content-Type: application/json`, `Cache-Control: public, max-age=300`,
with the signing key, then the staged key, then the retiring keys, each rendered by `jwks` as
`{"kty":"EC","crv":"P-256","alg":"ES256","use":"sig","kid":"...","x":"...","y":"..."}`. It never holds a private
member. `http_auth`'s cache takes the 300 s from `max-age` and refetches on an unknown `kid` at most once per 60 s.

### Rotation

Rotation is three restarts, driven by the operator, and the issuer refuses each step that would break a verifier:

1. **Stage.** Generate key B. Restart with `--signing-key-file=A --next-signing-key-file=B`. B is published; A
   signs.
2. **Switch,** no sooner than the **publish lead** after step 1: one hour (a key set's `max-age` of 300 s, one 60 s
   refetch window and generous margin). Restart with `--signing-key-file=B --retiring-key-file=A`. B signs.
3. **Drop,** no sooner than the **retire lag** after step 2: 24 hours (the longest-lived signature is 15 minutes plus
   60 s of leeway; the rest is margin for verifiers whose fetches fail). Restart with `--signing-key-file=B`.

The store keeps a key publication record per `kid`: when it was first published, when it first signed, when it last
signed. It holds public facts only. At startup the issuer refuses to start when:

- the signing key was first published less than the publish lead ago (it was never staged, or staged too briefly).
  A brand-new deployment, whose store holds no record for any key, is the one exception: its first key signs at once;
- a key that last signed less than the retire lag ago is neither the signing key nor listed as retiring;
- more than 4 retiring keys, two flags naming one key, or a staged key equal to the signing key are given.

Each refusal names the `kid` and the time left. An emergency rotation (a leaked key) skips both checks on purpose with
`--allow-unstaged-signing-key=KID`, which names the one new signing key it allows: that key signs at once, and every
key that signed within the retire lag may be left out of the key set. Every token signed by a dropped key stops
verifying as soon as verifiers refetch, which is the point. It is a flag the operator types for that one restart,
not a setting; at the next restart without it, the checks apply again.

## Sign-in: the authorization code flow with PKCE

### The browser session

The issuer keeps one cookie, `__Host-issuer_session`: `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, no `Domain`,
and no `Max-Age` (it ends with the browser or the session, whichever comes first). Its value is 32 random bytes,
base64url, 43 characters; the store keeps only its SHA-256. Every response sets at most one cookie.

The cookie names a **browser session**, which is either **anonymous** (a browser on its way through its first
upstream sign-in) or **signed in** (a person, an `auth_time` and an end time). A session is not bound to an
organization: the org lives on each code and each refresh family.

- A browser session holds at most 8 **pending logins** at once (one per tab or app signing in); a ninth evicts the
  oldest. Each pending login is found by its own upstream `state`, so concurrent sign-ins in one browser all work.
- A signed-in session lasts 8 hours from sign-in (`--session-ttl`, proposal D12; 1 hour to 24 hours). It is never
  extended: refreshing tokens does not move its end.
- A successful upstream sign-in replaces the browser session, anonymous or signed in, with a new signed-in session
  under a new id (no session fixation); its other pending logins move with it. A failed one leaves the browser
  session as it was, including a signed-in one that `prompt=login` or `max_age` sent back upstream.
- A signed-in session ends at `/end-session`, at its end time, when the person holds no membership any more, or when
  the person is erased; then every refresh family started in it is revoked. Removing one of several memberships
  revokes only the families with that org and leaves the session.

### `/authorize`

Parameters come from the query string (`GET`) or a form body (`POST`), never both.

| parameter | rule |
|---|---|
| `client_id` | required; an active client with `authorization_code` |
| `redirect_uri` | required; byte-for-byte equal to one of the client's `redirect_uris`. No prefix, case, port or trailing-slash tolerance |
| `response_type` | required; exactly `code` |
| `scope` | required; space-separated, holds `openid`; the others allowed are `profile` and `email` |
| `state` | required; 1 to 512 printable ASCII bytes; returned unchanged |
| `code_challenge` | required; exactly 43 bytes of `[A-Za-z0-9_-]` (an S256 challenge is the base64url of 32 bytes, RFC 7636 section 4.2) |
| `code_challenge_method` | required; exactly `S256` |
| `nonce` | optional; 1 to 512 printable ASCII bytes; copied into the ID token |
| `org` | optional, an extension; which organization the tokens are for (see below) |
| `prompt` | optional; `none` or `login`. `consent` and `select_account` are accepted and do nothing (there is no consent or account screen) |
| `max_age` | optional; a non-negative integer of seconds. When `now - auth_time > max_age`, the request is handled as `prompt=login` (OpenID Connect Core section 3.1.2.1) |
| `response_mode` | optional; only `query` |
| `ui_locales`, `login_hint`, `acr_values`, `claims`, `display`, `id_token_hint` | ignored |

Unknown parameters are ignored (RFC 6749 section 3.1). Every refusal, and whether it redirects:

| condition | answer |
|---|---|
| `client_id` missing, repeated, unknown, inactive, or its record breaks a rule | `400` plain-text page, no redirect |
| `redirect_uri` missing, repeated or not registered for the client | `400` plain-text page, no redirect |
| `state` missing, repeated or outside its rule | `400` plain-text page, no redirect (a redirect without `state` would be unusable to the client) |
| any other parameter repeated; `code_challenge` or its method missing or outside its rule (`plain` included); `prompt=none` with another value; a bad `max_age`; `response_mode` other than `query`; `org` outside its rule; no `org` and several memberships | redirect, `invalid_request` |
| `response_type` missing or not `code` | redirect, `unsupported_response_type` |
| `scope` missing, without `openid`, or holding another value | redirect, `invalid_scope` |
| the client lacks `authorization_code` | redirect, `unauthorized_client` |
| `request` / `request_uri` present | redirect, `request_not_supported` / `request_uri_not_supported` |
| `prompt=none` (or an exceeded `max_age` with `prompt=none`) and no signed-in session, or the session's `auth_time` older than `max_age` | redirect, `login_required` |
| signed in, but no membership in the chosen org (with `prompt=none` too) | redirect, `access_denied` |
| the upstream refused or failed its checks, or the person holds no membership | redirect, `access_denied` |
| the token for this person would break the size bound (see [Token contents](#token-contents)) | redirect, `server_error` |
| the store or the upstream unreachable | redirect, `temporarily_unavailable` |

The checks run in the table's order. A `400` page never redirects: the issuer never sends a browser to a URL the
client did not register (RFC 6749 section 4.1.2.1). A redirect is `303` to the `redirect_uri` with `error`, `state`
and `iss` (RFC 9207) in the query, and no `error_description`.

**The happy path.**

1. With a signed-in session whose person holds a membership in the chosen org, no `prompt=login`, and no exceeded
   `max_age`, go to step 4.
2. Otherwise (unless `prompt=none`, which answers as the table says) the issuer adds a **pending login** to the
   browser session, creating an anonymous one and setting the cookie if there is none: the authorize request, a fresh
   upstream `state`, `nonce` and PKCE verifier, and an expiry 10 minutes away. It redirects `303` to the upstream
   (`UpstreamIdentity.begin`, with `force_login` for `prompt=login` or an exceeded `max_age`).
3. The upstream returns to `/upstream/callback`. The issuer finds the pending login by the upstream `state` and
   requires that the request carries the cookie of the browser session holding it (no login CSRF). It deletes the
   pending login (single use) and asks `UpstreamIdentity.complete` for a verified subject, then admits the person
   (see [Admission and the subject](#admission-and-the-subject)), chooses the org, and replaces the browser session
   with a signed-in one. An unknown or expired upstream `state`, or a missing or different cookie, answers `400` with
   a plain-text page (the pending login, and with it the client's redirect, is not trusted). The other failures
   redirect to the client as the table says.
4. The issuer mints a code and redirects `303` to `redirect_uri?code=...&state=...&iss=...`.

**The organization.** `org` is a slug, `[a-z][a-z0-9-]{1,30}`, naming one organization inside this issuer. It is
not the deployment. With the `org` parameter, the person must hold a membership in that org. Without it, the person
must hold exactly one membership, which is chosen; with several, the request is `invalid_request`, because the issuer
has no org picker. The code and every token after it carry that one org.

### The code

- 32 random bytes, base64url, 43 characters. The store keeps its SHA-256, the client id, the redirect URI, the code
  challenge, the session, the org, the scope, the nonce and the `auth_time`.
- It lasts 60 seconds.
- It is used once. The store's redeem step is one atomic operation: *if the code is unused, unexpired and minted for
  this client, mark it used and return it*. A code minted for another client answers `invalid_grant` and changes
  nothing, so one client can neither burn nor revoke another's code. Once the redeem step has run, the code stays
  used whatever the later checks decide.
- Presenting a used code, by the client it was minted for, answers `invalid_grant` and revokes the refresh family the
  first redemption started (RFC 6749 section 4.1.2), so a stolen code that loses the race takes the winner's tokens
  down with it.

### `/token`

`POST`, `Content-Type: application/x-www-form-urlencoded`, parsed by `oauth.parse_form` (strict: no repeated name,
no byte outside printable ASCII, at most 64 KiB). `grant_type` chooses `authorization_code`, `refresh_token` or
`client_credentials`; any other value is `unsupported_grant_type`.

#### `authorization_code`

| parameter | rule |
|---|---|
| `grant_type` | `authorization_code` |
| `code` | required |
| `redirect_uri` | required; byte-for-byte equal to the one in the authorize request |
| `code_verifier` | required; 43 to 128 bytes of `[A-Za-z0-9-._~]`; `base64url(SHA-256(code_verifier))` equals the stored challenge, compared in constant time |
| client authentication | a confidential client: `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer` and `client_assertion` (see [Client authentication](#client-authentication)). A public client: `client_id` and no assertion |
| `client_id` | required for a public client; for a confidential client, optional and then equal to the assertion's `iss` |
| `resource` | optional; an audience in the client's `resources`, or the client's own `client_id`. Default: the client's own `client_id` |

Checks, in order, each answering the first error that applies. The first two follow
`oauth.parse_client_credentials_request`, so one body gets one answer whatever its grant:

1. the body is not a form (`invalid_request`);
2. `client_secret` present, or an `Authorization` header (`invalid_client`: no client secrets);
3. `grant_type` missing (`invalid_request`) or unknown (`unsupported_grant_type`);
4. a required parameter missing or outside its rule (`invalid_request`);
5. client authentication (`invalid_client`);
6. the client lacks the grant (`unauthorized_client`);
7. `resource` not allowed (`invalid_target`);
8. the code looked up without being used: unknown, expired or minted for another client is `invalid_grant` and
   changes nothing; then the person's roles are read and the token size checked (`server_error`, the code stays
   unused);
9. the redeem step (`invalid_grant`, as in [The code](#the-code)), which settles a race between two redemptions;
10. `redirect_uri`, then `code_verifier` (`invalid_grant`);
11. the person still holds the membership in the code's org and the session is still signed in (`invalid_grant`).

The reply, `200`, `Content-Type: application/json`, `Cache-Control: no-store`:

```json
{"access_token":"<at+jwt>","token_type":"Bearer","expires_in":900,"scope":"openid profile email",
 "refresh_token":"<opaque>","id_token":"<JWT>"}
```

`refresh_token` is present when the client has the `refresh_token` grant. `oauth`'s `render_token_response` and
`parse_token_response` grow the two optional members additively.

#### Errors

`{"error":"<code>"}` and nothing else, with `Cache-Control: no-store`. The codes are `oauth`'s list,
`invalid_request`, `invalid_client`, `invalid_grant`, `unauthorized_client`, `unsupported_grant_type`,
`invalid_scope` and `invalid_target`, plus two server conditions:

| code | status |
|---|---|
| `invalid_client` after an `Authorization` header was sent | `401`, `WWW-Authenticate: Basic realm="token"` (RFC 6749 section 5.2) |
| every other client code | `400` |
| `server_error` (the size bound) | `500` |
| `temporarily_unavailable` (the store unreachable) | `503`, `Retry-After: 5` |

`oauth`'s client treats every non-`200` as a failure and reports the code it knows; the two server codes are additive
to its list. Today `komira_test_issuer` answers `invalid_client` with `401` and no challenge; it moves to this table.

### Refresh tokens: rotation and reuse detection

A refresh token is opaque: 32 random bytes, base64url, 43 characters; the store keeps its SHA-256. It is never a JWT,
so no key rotation touches it. Each one belongs to a **family**, started by one code redemption and bound to one
browser session, one client, one org, and the scope, the `nonce` and the `auth_time` of that code.

`POST /token` with `grant_type=refresh_token`, `refresh_token`, client authentication as above (a public client sends
`client_id`), optional `resource` (an audience in the client's `resources` now, or its own `client_id`), and
optional `scope`. Checks, in order:

1. form, `client_secret`, `grant_type` and parameters, as for `authorization_code` (steps 1 to 4);
2. client authentication (`invalid_client`; an inactive client fails here). Nothing below runs for an
   unauthenticated request, so no one without the client's key (or, for a public client, its refresh token) can
   revoke a family. A retired client is never active again, so its families can never be used;
3. the client holds `refresh_token` (`unauthorized_client`);
4. the token is unknown (`invalid_grant`, nothing revoked);
5. **binding**: the token was issued to another client (`invalid_grant`, and the family is revoked);
6. **reuse**: the token is used (`invalid_grant`, and the family is revoked, every token in it, used or not);
7. the family is revoked, or its session ended or is past its end time (`invalid_grant`);
8. `scope` wider than the family's (`invalid_scope`); `resource` not allowed (`invalid_target`);
9. **fresh facts**: the membership in the family's org, the person's attributes, the roles and the client are read
   again. A removed membership revokes the family (`invalid_grant`); a roles size breach is
   `server_error` with nothing consumed;
10. **rotation**: in one atomic step, mark the presented token used and insert the next one in the family. A
    concurrent refresh that loses this step sees the token used and is step 6.

A narrower `scope` applies to that one response: the family keeps its scope, and the next refresh may ask for it
whole. The reply is the `authorization_code` reply; it carries an `id_token` when the effective scope holds
`openid`. The new refresh token expires when the family does.

There is no grace window for reuse: a client keeps at most one refresh in flight, as `oauth`'s
`ClientCredentialSource` already does for its tokens. A legitimate client that races two refreshes loses its family
and signs in again; that is the price of telling theft from a race without guessing. A family ends with its session,
8 hours after sign-in at most (proposal, D12), and a changed role shows in the next access token, at most 15 minutes
after the change.

### Client authentication

A confidential client authenticates at `/token` only with `private_key_jwt` (RFC 7523 section 2.2), on the profile
`http_auth.md` fixes:

- `client_assertion_type` is exactly `urn:ietf:params:oauth:client-assertion-type:jwt-bearer`;
- the assertion's header passes `jose`'s header gate; `alg` equals the client's `token_endpoint_auth_signing_alg`;
  `kid` names a key in the client's `jwks` (or the document at `jwks_uri`, fetched with `http_auth`'s key-set rules
  and the outbound address rules of [Delivery and retry](#delivery-and-retry));
- `jose.verify_client_assertion` checks the signature, `iss == sub`, `exp - iat` of 1 to 300 s with 30 s leeway, and
  a non-empty `jti`;
- the issuer then checks what `jose` does not: `iss` equals the client named by `client_id` (when sent); `aud` is a
  JSON string, never an array, equal to the issuer URL or to the token endpoint URL;
- a `jti` already seen from that client before its `exp` plus the leeway is refused: the store keeps seen `jti`s
  until then, and records a `jti` only after every other check passed.

Each failure is `invalid_client`: a bad or missing assertion type, a bad assertion, a confidential client that sends
no assertion, a public client that sends one, a `client_id` that differs from the assertion's `iss`, and a public
client asking for `client_credentials`. `client_secret_basic`, `client_secret_post`, `client_secret_jwt` and
`tls_client_auth` are `invalid_client`.

### `client_credentials`: service tokens

Exactly the wire in [http_auth.md](http_auth.md#client-credentials-oauth), which `oauth` already speaks:

- request: `grant_type=client_credentials`, the client assertion, `resource=<audience>` (required, exactly one), and
  optional `scope`. `oauth.parse_client_credentials_request` is the parser, and its checks and their order are the
  issuer's steps 1 to 4;
- then client authentication (`invalid_client`; a public or inactive client fails here); the client must hold the
  `client_credentials` grant (`unauthorized_client`); the `resource` must be in its `resources` (`invalid_target`);
  `scope`, when sent, must be a subset of the client's registered `scope` (`invalid_scope`). Without `scope`, the
  token gets the registered `scope`, and with no registered `scope` it carries none;
- the reply: `200`, `Cache-Control: no-store`, `{"access_token", "token_type":"Bearer", "expires_in":900, "scope"?}`.
  No refresh token and no ID token.

## Token contents

Every JWT the issuer signs has the header `{"alg":"ES256","kid":"<kid>","typ":"<typ>"}`, in that order, as `jose`'s
signer writes it. Every time is an integer number of seconds since the epoch.

**Size.** `http_auth` refuses a compact token longer than 8192 bytes, so the issuer never mints one. The serialized
`roles` object is at most 3072 bytes. With the other bounds (an issuer URL of at most 256 bytes, client ids of 64,
`name` at most 512 bytes once JSON-escaped, `email` 254, `picture` 512) every other claim together stays under
2048 bytes, so the payload is under 5120 bytes, its base64url under 6830, and the whole token, with the header and
the 86-byte signature, under 7100. A person whose roles exceed 3072 bytes cannot be issued a token: `/authorize`
answers `server_error` and `/token` answers `500 server_error`, leaving the code or refresh token unused, and the
issuer logs the subject and the size. A token with roles silently cut is never issued.

### The access token (`typ` `at+jwt`, RFC 9068)

A person's token, from `authorization_code` or `refresh_token`:

| claim | value |
|---|---|
| `iss` | the issuer URL |
| `sub` | the person's subject (below) |
| `aud` | one string: the audience the token is for (the client's own `client_id` by default, or the `resource` asked for) |
| `client_id` | the client that asked for it |
| `iat`, `exp` | `exp = iat + 900` (15 minutes, proposal D12) |
| `jti` | 16 random bytes, base64url |
| `scope` | the granted scope |
| `auth_time` | when the person signed in upstream |
| `sid` | the session id: base64url of the first 16 bytes of SHA-256 of the session cookie value, never the cookie value |
| `org` | the organization slug |
| `roles` | the roles map (below) |
| `name`, `email`, `picture` | the person's attributes (below), each present only when known |

An example, for a person in org `acme` who holds roles in two apps:

```json
{"iss":"https://id.example.com","sub":"u-01jd5x3k8w2m9q7r4t6v0bny5c","aud":"reports","client_id":"portal",
 "iat":1799990000,"exp":1799990900,"jti":"0PLW1Ah3vX6H1aR0Gm9zqg","scope":"openid profile email",
 "auth_time":1799989900,"sid":"q3Xy0B6tY1vC9n2Lk8MjZw","org":"acme",
 "roles":{"reports":["editor"],"inventory":["viewer"]},
 "name":"Pat Example","email":"pat@example.com","picture":"https://img.example.com/pat.png"}
```

A service token, from `client_credentials`:

| claim | value |
|---|---|
| `iss`, `aud`, `iat`, `exp`, `jti`, `scope` | as above |
| `sub`, `client_id` | both the calling client's `client_id` |
| `roles` | `{"<the calling client_id>": [<its service roles>]}`, or `{}` |

A service token has no `org`, `auth_time`, `sid`, `name`, `email` or `picture`. A person's `sub` always starts with
`u-` and a `client_id` never does, so a verifier tells the two apart from `sub` alone, and `sub == client_id` holds
exactly for service tokens.

### The ID token (`typ` `JWT`)

Minted with every access token from `authorization_code`, and from `refresh_token` when the effective scope holds
`openid`. `iss`, `sub`, `iat`, `exp`
(`iat + 900`), `auth_time`, `sid`, `org`, `name`, `email`, `picture` as in the access token, and:

- `aud`: the client's `client_id`, one string;
- `nonce`: the authorize request's `nonce`, when it had one (also on ID tokens from a refresh, as the family keeps it);
- `at_hash`: base64url of the left 16 bytes of SHA-256 of the access token (OpenID Connect Core section 3.1.3.6).

An ID token is for the client to learn who signed in. It never carries `roles`, and it is never a bearer
credential. Its `aud` can equal an access token's (both are the client's `client_id` by default), so only the
header `typ` tells them apart: **an `http_auth` anchor for this issuer is configured `--jwks-alg=ES256` and
`--accept-typ=at+jwt`, never `JWT`**, and such an anchor refuses every ID token and every removal notice. An app that
needs roles in its sign-in step reads them from the access token or `/userinfo`.

### Admission and the subject

Admission is a membership, never the upstream: the upstream says who a person is, the `Directory` says whether they
get in. After `UpstreamIdentity.complete` returns a verified subject:

1. **A known person.** When the store maps (`upstream_issuer`, `upstream_subject`) to a `sub`, the issuer asks the
   `Directory` for that `sub`'s memberships. None is `access_denied`.
2. **A first sign-in.** Otherwise the person must have been invited: an administrator adds a membership for an email
   address before the person first signs in. The issuer asks the `Directory` for the invitations held by the
   subject's verified `email`. With no verified `email`, or no invitation, the answer is `access_denied` and nothing
   is stored. With one or more, the issuer mints a `sub` (`u-` and 26 characters of lowercase Crockford base32 of 16
   random bytes), stores the mapping, and asks the `Directory` to turn those invitations into memberships of that
   `sub`, in one step. The email is the key of an invitation only; after the first sign-in a person is found by the
   mapping, so a later change of email at the upstream changes nothing about who they are.

The mapping never changes once written. The upstream's own `sub` never appears in a token: moving to another upstream
provider keeps every person's `sub`, by mapping the new upstream subjects to the existing ones (an administrator's
step, outside the issuer's endpoints). Erasing a person deletes the mapping and the attributes, never reuses the
`sub`, and sends removal notices.

### `roles` (proposal, D2)

A JSON object. Each member's name is a client id of an active client; its value is a non-empty array of distinct role
names that client declares in its `roles`, sorted. A client in which the person holds no role is left out, so
`roles` may be `{}`; it is always present. There is no single `role` claim, and no role that holds across apps. Roles
are set per organization, per person and per app by an administrator, outside the issuer, and the issuer reads them
from the `Directory` port each time it mints. A role the `Directory` reports that the client does not declare is
dropped, and a retired client's roles are dropped.

Roles are bounded by size, not by count: the serialized object is at most 3072 bytes (see
[Token contents](#token-contents)).

### `name`, `email`, `picture`

From the upstream subject, refreshed on every sign-in and stored with the subject. `name`: 1 to 256 bytes of UTF-8,
and at most 512 bytes once JSON-escaped.
`email`: present only when the upstream asserts it verified; there is no `email_verified` claim because an unverified
address is never sent; at most 254 bytes. `picture`: an absolute `https` URL of at most 512 bytes. A value outside its rule is left out,
never truncated.

## `/userinfo`

`GET`, or `POST` with an empty or form body, with `Authorization: Bearer <access token>` only (never a query or body
token). The token must be this issuer's `at+jwt`, verified as `http_auth` would with any `aud`, be a person's token
whose `scope` holds `openid`, its session must still be signed in, and the person must still hold the membership
in its `org`. The reply, `200`, `Cache-Control: no-store`: `{"sub", "org", "roles", "name"?, "email"?,
"picture"?}`, the same values a token minted now would carry. Refusals (RFC 6750 section 3.1):

| condition | answer |
|---|---|
| no credential, or another scheme | `401`, `WWW-Authenticate: Bearer` |
| a token in the query or the body, or two credentials | `400`, `WWW-Authenticate: Bearer error="invalid_request"` |
| a token that does not verify, has expired, belongs to an ended session or a removed membership | `401`, `WWW-Authenticate: Bearer error="invalid_token"` |
| a valid service token, or a valid person's token without `openid` | `403`, `WWW-Authenticate: Bearer error="insufficient_scope"` |

No refusal carries a body that says which check failed.

The endpoint exists for relying parties whose OIDC library reads profile claims from it; the ID token already
carries the same profile claims (`sub`, `org`, `name`, `email`, `picture`); `roles` comes only from the access token
and `/userinfo`.

## `/end-session`

OpenID Connect RP-Initiated Logout 1.0. Parameters from the query (`GET`) or a form (`POST`):

| parameter | rule |
|---|---|
| `id_token_hint` | required; an ID token this issuer signed: header `typ` exactly `JWT` (an access token or a removal notice is refused), signature and `iss` verified, `aud` an active client; an expired one is accepted if its `iat` is within the longest session length (24 hours) |
| `client_id` | optional; when given, equal to the hint's `aud` |
| `post_logout_redirect_uri` | optional; byte-for-byte one of that client's `post_logout_redirect_uris` |
| `state` | optional; 1 to 512 printable ASCII bytes; returned |

When the request carries the session cookie and the hint's `sid` names that session, the session ends, every refresh
token family started in it is revoked, and the cookie is cleared (`Max-Age=0`). When the cookie is missing, or names
another session, nothing ends. In every case the answer is `303` to `post_logout_redirect_uri` with `state`, or, with
no redirect, `200` and a plain-text page. A hint that does not verify, or a redirect URI the client did not register,
is `400` and never redirects.

Requiring a hint whose `sid` matches the cookie means a third-party page cannot sign a person out (logout CSRF)
without a confirmation screen. Other apps learn of the sign-out when their refresh fails, within 15 minutes.

## The federation port

The issuer never verifies a password. It hands the browser to an upstream identity provider and receives a verified
subject through one Mojo trait:

```mojo
struct UpstreamBegin(Copyable, Movable):
    var callback_url: String      # the issuer URL + "/upstream/callback"
    var state: String             # 32 random bytes, base64url; the issuer's key for the pending login
    var nonce: String             # 32 random bytes, base64url
    var code_challenge: String    # S256 of the pending login's verifier
    var force_login: Bool         # true for prompt=login or an exceeded max_age


struct UpstreamCallback(Copyable, Movable):
    var query: List[Tuple[String, String]]   # the callback's query parameters, as received
    var code_verifier: SecretValue           # the pending login's PKCE verifier
    var nonce: String
    var now: Int64


struct VerifiedSubject(Copyable, Movable):
    var upstream_issuer: String       # the upstream's issuer identifier, exactly
    var upstream_subject: String      # the upstream's stable subject; never an email address
    var name: Optional[String]
    var email: Optional[String]       # set only when the upstream asserts the address verified
    var picture: Optional[String]
    var auth_time: Int64


struct UpstreamFailure(Copyable, Movable, Writable):
    var kind: UpstreamFailureKind     # refused | invalid_response | unavailable
    var reason: StaticString          # fixed text, never a byte of the upstream's reply


trait UpstreamIdentity(Movable):
    def begin(mut self, request: UpstreamBegin) raises -> String:
        """The URL to redirect the browser to. Raises only on a broken
        configuration."""
        ...

    def complete(mut self, callback: UpstreamCallback) -> Result[VerifiedSubject, UpstreamFailure]:
        """Exchanges and verifies the upstream's answer. Never trusts a value
        it did not verify."""
        ...
```

`Result` stands for whatever typed outcome Mojo then offers (an `Optional` and a failure, or a typed raise); the
contract is that failure is one of three named kinds and never a different subject. `refused` (the person cancelled,
or the upstream refused them) maps to `access_denied`; `invalid_response` (a signature, `iss`, `aud`, `nonce` or
`state` check failed) to `access_denied` and a log line naming the check; `unavailable` (a timeout, a 5xx) to
`temporarily_unavailable`. No raw upstream error text reaches the browser.

The issuer, not the adapter, owns: the pending login and its single use, the cookie binding, the mapping to its own
`sub`, and admission ([Admission and the subject](#admission-and-the-subject)). The adapter only proves who a
person is.

### The fake (`FakeUpstream`, for tests)

An in-process table from a code to an outcome. `begin` returns `callback_url?code=<next code>&state=<state>` without
leaving the process. `complete` reads `code` and `state` from the query, checks that `state` and the `nonce` match
what `begin` received for that code, and returns the scripted outcome: a `VerifiedSubject`, or each of the three
failure kinds. It records every call, so a test asserts that `force_login` was passed and that a code was completed at
most once. Time comes from `now`; nothing reads a clock or a socket.

### The generic upstream OIDC adapter (`OidcUpstream`)

A relying party for any OpenID Connect provider, configured by flags:

| flag | meaning |
|---|---|
| `--upstream-issuer=URL` | the upstream's issuer identifier, `https`; discovery is fetched from it at startup and its `issuer` must equal it byte for byte |
| `--upstream-client-id=ID` | our client id at the upstream |
| `--upstream-client-key-file=PATH` | our private key for `private_key_jwt` at the upstream, PEM PKCS#8 |
| `--upstream-client-secret-file=PATH` | or, for an upstream without `private_key_jwt`, a file holding the client secret (sent with `client_secret_basic`); exactly one of the two |
| `--upstream-id-token-alg=ALG` | the one algorithm the upstream's ID tokens are verified with: `RS256`, `ES256` or `EdDSA`; no default |
| `--upstream-scope=SCOPE` | default `openid profile email` |

`begin` builds the upstream authorize URL: `response_type=code`, `client_id`, `redirect_uri` (the callback),
`scope`, `state`, `nonce`, `code_challenge`, `code_challenge_method=S256`, and `prompt=login` when `force_login`.
`complete`:

1. An `error` in the query is `refused`. A missing `code`, or a `state` different from the one the pending login
   holds, is `invalid_response`.
2. Redeems the code at the upstream token endpoint with `code_verifier` and our client authentication, over HTTPS
   with certificate verification and a 10 s timeout. A 5xx or a timeout is `unavailable`; any other non-200 is
   `refused`.
3. Verifies the ID token with `jose`: `alg` pinned, the key from the upstream's JWKS (cached by `http_auth`'s
   key-set rules), `iss` equal to `--upstream-issuer`, `aud` containing our client id (and `azp` equal to it when
   `aud` holds several), `exp` and `iat` with 30 s leeway, `nonce` equal to ours. Any failure is
   `invalid_response`.
4. Maps the claims: `sub` to `upstream_subject`; `email` only when `email_verified` is `true`; `name`; `picture`
   when it is an `https` URL; `auth_time` when present, else `iat`. The upstream's userinfo endpoint is not called.

## Removal notices

When a person's membership in an org is removed, or the person is erased, the issuer first revokes the refresh
families of that org (all of them, on erasure) and ends the person's signed-in sessions when no membership is left
(so no new token is minted), then posts a signed notice to the
`removal_notice_url` of every active client that has one. Apps still holding an access token learn of the removal
from the notice instead of waiting up to 15 minutes for it to expire.

### The request

`POST <removal_notice_url>`, `Content-Type: application/jwt`, the body a compact JWS with the header
`{"alg":"ES256","kid":"<kid>","typ":"removal+jwt"}` and the claims:

```json
{"iss":"https://id.example.com","aud":"reports","iat":1799990000,"exp":1799990300,
 "jti":"Jm2b0f7nU5r1KpXwqT3h9A","sub":"u-01jd5x3k8w2m9q7r4t6v0bny5c","org":"acme",
 "removed_at":1799989990,"reason":"membership_removed"}
```

- `aud`: the receiving client's `client_id`, so a notice for one app is refused by another;
- `jti`: the notice's id, 16 random bytes, base64url: one per removal and receiving client, the same on every attempt
  to deliver it, and never reused for a later removal (a person removed, invited back and removed again gets a new
  one);
- `iat` and `exp`: the time of this attempt and 300 s later: each attempt is signed anew, so no retry ever sends an
  expired notice and no notice outlives the retire lag of the key that signed it;
- `removed_at`: when the removal happened;
- `reason`: `membership_removed` or `person_erased`. For `person_erased`, `org` is left out and the notice goes to
  every client with a `removal_notice_url`.

`typ` `removal+jwt` is distinct from `at+jwt` and `JWT`, so neither a token nor an ID token is ever accepted as a
notice, or a notice as either (RFC 8725 section 3.11). `jose`'s `ClaimPolicy` gains `removal+jwt` as a third accepted
value, additively.

### The receiver

An app verifies the notice with `jose` against the issuer's published keys: `alg` `ES256`, `typ` `removal+jwt`,
`iss` the issuer, `aud` its own `client_id`, max TTL 300 s, leeway 30 s, and `jti`, `sub` and `removed_at` present.
It keeps each `jti` it has seen for at least 330 s (the notice's 300 s plus the leeway) and treats a repeat as
already done; an `exp` past (with the leeway) is refused whatever the `jti`, so a captured notice cannot be replayed
after its window. It answers `2xx` once it has recorded the notice. What it then does
(end the person's local sessions, drop their data) is the app's own.

### Delivery and retry

- **Outbound address rules.** The `removal_notice_url` is `https`, port 443 (none written, or `:443`), with no
  userinfo or fragment. On every attempt the issuer resolves the host once, refuses the attempt when any resolved
  address is loopback (`127.0.0.0/8`, `::1`), unspecified, link-local (`169.254.0.0/16`, `fe80::/10`), private
  (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`), shared (`100.64.0.0/10`), multicast or broadcast
  (an IPv4-mapped IPv6 address is judged as its IPv4 address), and connects to one checked address itself, with the
  original host name for SNI, certificate verification and `Host`, so a second DNS answer cannot redirect it. It
  sends no cookie and no credential, does not follow redirects, and reads at most 4 KiB of the reply and ignores it.
  The same rules apply to a client's `jwks_uri`. A refused address is a permanent failure. An app on a private
  network is reached through a public address (its own proxy, for example); the issuer has no allow-list.
- `2xx` is delivered. `408`, `429`, any `5xx`, a connection failure or a timeout (10 s) is retried. Any other status,
  or a redirect, is a permanent failure: it is not retried, and the issuer logs the client id, the `jti` and the
  status.
- Retries back off from 30 s, doubling to at most 1 hour (30 s, 60 s, 120 s, ... 3600 s, 3600 s, ...), waiting
  instead for a `Retry-After` of seconds when it is longer, capped at 1 hour, for 72 hours after the removal. After that the notice is given up and logged. 72 hours outlasts the session (8 hours) and
  every token by far; the notice only shortens what expiry already bounds.
- Notices are queued in the store, written in the same step that ends the sessions, so a restart loses none.
  Delivery is at least once; notices for one client go in the order of `removed_at`, one at a time per client.

## The ports

`oidc_issuer` reads no clock, no entropy source, no network and no disk itself; each comes through a trait with a
fake in the package and one production binding:

| port | what it answers | fake | production |
|---|---|---|---|
| `UpstreamIdentity` | a verified upstream subject | `FakeUpstream` | `OidcUpstream` |
| `ClientStore` | the client record for a `client_id`, read per request | a table | the deployment's app registry |
| `Directory` | a `sub`'s memberships; the invitations held by a verified email, and turning them into memberships; roles per org, person and app; a service client's roles | a table | the deployment's member and role store |
| `IssuerStore` | sessions, pending logins, codes, refresh families, seen `jti`s, subject mappings and attributes, key publication records, the notice queue | in memory | a database binding |
| `NoticeTransport` | posts one notice and reports the status | a scripted recorder | HTTPS over `http_client` |
| `IssuerClock`, `IssuerEntropy` | the time in seconds; random bytes | fixed and scripted | the system clock; `crypto.system_entropy` |

`IssuerStore` must give one atomic step for each of: redeem a code (if unused, unexpired and for this client, mark
used), rotate a refresh token (if unused, mark used and insert the next), record a `jti` (insert if absent), first
sign-in (store the mapping and turn the invitations into memberships, with the `Directory` call made idempotent by
the `sub`), and a removal (revoke the families, end the sessions and queue the notices).
An implementation that cannot is not an `IssuerStore`. Every secret it holds (a session id, a code, a refresh token)
is held as a SHA-256, so a read of the store mints nothing.

## Flags

Every flag is `--name=value`, the rules of [http_auth.md](http_auth.md#flags): a bare word, an empty value, an unknown
name and a single-valued flag given twice refuse startup. Nothing is read from the environment, and no secret is read
from argv: secrets come from files.

| flag | default |
|---|---|
| `--issuer=URL` | required |
| `--signing-key-file=PATH`, `--next-signing-key-file=PATH`, `--retiring-key-file=PATH` | see [Keys](#keys) |
| `--allow-unstaged-signing-key=KID` | none |
| `--session-ttl=DURATION` | `8h` (proposal, D12); `1h` to `24h`, digits and one unit |
| `--upstream-*` | see the adapter |

The access token and ID token lifetime (900 s), the code lifetime (60 s), the pending-login lifetime (600 s), the
publish lead (1 h), the retire lag (24 h) and the notice retry schedule are constants: a deployment that changed them
would change what every verifier sees. The store binding and the HTTP listener take their own flags, defined with
them.

## What must always hold

- Every code is redeemed at most once, within 60 s, by the client it was minted for, with the redirect URI and the
  PKCE verifier of its authorize request.
- A redirect goes only to a URI registered for the client, compared byte for byte.
- A used refresh token, presented again, revokes its family. No refresh token outlives its session.
- Nothing the issuer signs is signed by a key that was not published for at least the publish lead, and no key that
  signed in the last 24 hours leaves the key set, except for the one restart that carries
  `--allow-unstaged-signing-key`.
- The issuer never reads a private key from the environment, argv or the store; no response and no log line holds a
  private key, a code, a refresh token, a session id or a whole token.
- Every token carries exactly one org (or none, for a service), and roles only for active clients and only roles
  those clients declare.
- Admission is a membership or an invitation to one: an upstream subject without either never gets a session, and
  nothing about it is stored.
- A removed membership's families (and, when it was the last, the person's sessions) end before the first notice is
  sent, and every notice is retried until a `2xx`, a permanent failure or 72 hours.
- No token is longer than 8192 bytes, and no token carries a cut roles map.
- An unauthenticated request to `/token` changes nothing in the store.

## Conformance

The issuer's tests and any other implementation of this document run one scenario table, an extension of
`komira_test_issuer`'s `issuer_scenarios()` with an `IssuerUnderTest` that speaks HTTP. Each row is one rule above:

| area | scenarios |
|---|---|
| discovery | both documents byte-equal to the expected text; `issuer` equals the flag |
| keys | `kid` is the thumbprint; staged and retiring keys published; no private member; startup refused for an unstaged signing key, a dropped recent key, five retiring keys, a duplicate key, a non-P-256 key and an unreadable file |
| authorize | every row of the refusal table, with its status and whether it redirects; a 42-, a 44- and a 43-byte challenge with a byte outside the alphabet; `plain` and absent `code_challenge_method`; `max_age` exceeded (sent upstream with `force_login`) and not exceeded; `prompt=none` with an exceeded `max_age`; `iss` on success and on every error redirect |
| sessions | two concurrent sign-ins in one browser both complete; a ninth pending login evicts the oldest; a failed `prompt=login` keeps the signed-in session; the session id changes at sign-in; the session ends at its end time and not before, refresh or not |
| upstream | the callback without the cookie, with another session's cookie, with an unknown `state`, after 10 minutes and a second time; each of the three failure kinds; a known subject without a membership; a first sign-in with an invitation, without one, and without a verified email (nothing stored); several memberships without `org` |
| code | redeemed twice by its client (second refused and the family revoked); presented by another client (refused, nothing changed, the rightful client still redeems it); after 61 s; with another `redirect_uri` and with a wrong verifier (the code is then used); a 42-byte verifier |
| refresh | rotation returns a new token; the old one presented again revokes the family; presented by another client (family revoked); presented without valid client authentication (nothing changes); an unknown token; after the session ends; after the membership in its org is removed, while a family of another org lives on; a wider `scope`; a narrower `scope` for one response; a role change visible in the next token |
| client authentication | `client_secret` and an `Authorization` header refused, the latter with `401` and the Basic challenge; wrong `alg`; unknown `kid`; `aud` neither the issuer nor the token endpoint; `aud` as an array; a 301 s assertion; a replayed `jti`; `client_id` different from `iss`; a public client sending an assertion; a confidential client sending none; a public client using `client_credentials` |
| service tokens | no `scope` (the registered one); a subset; a wider one (`invalid_scope`); a `resource` outside `resources` |
| tokens | every claim of each token type, against a fixed clock and fixed entropy, byte for byte; roles dropped for a retired client and for an undeclared role; a roles object of 3072 bytes issued and one of 3073 refused with nothing consumed; the largest allowed token under 8192 bytes; every access token verifies with an `http_auth` anchor configured ES256 and `at+jwt` and with `jose`, and that anchor refuses an ID token and a notice |
| userinfo | each row of its refusal table with its status and challenge; a token whose membership was removed |
| end session | without a hint; with a hint for another session; an expired hint inside and outside 24 hours; an access token and a notice as the hint; an unregistered redirect; the families revoked |
| CORS | `/token` and `/userinfo` with a registered origin, an unregistered one and a preflight; `*` on discovery and keys; no `Allow-Credentials` anywhere |
| removal | the notice verifies with `typ` `removal+jwt` and is refused as `at+jwt`; one `jti` across retries with a new `iat` each, and a new `jti` for a second removal; 2xx stops; 404 stops and logs; 503 and a timeout retry on the schedule; `Retry-After` honoured and capped; given up at 72 h; a redirect not followed; each refused address class, an IPv4-mapped loopback, a port other than 443, and a name whose second resolution is private (refused on that attempt); queued notices survive a restart of the fake store |

The OpenID Foundation's conformance suite (the Basic OP and Config OP profiles) is the external check, run against a
deployed issuer outside the pull-request check. Known departures, each refused by name: ES256 only (no RS256 ID
tokens); no `client_secret_*` methods; `state` and PKCE required; no consent screen; no `request` objects.

## Open decisions

| id | question | proposal |
|---|---|---|
| D1 | Write the issuer, or run an existing one? | write it, small, in Mojo on komira's packages: the signing, key ring, wire codecs and verifier already exist here |
| D2 | Roles global, per app, or both? | per app: the `roles` map above, with no single `role` claim and no role that holds across apps |
| D12 | Token and session lifetimes | access and ID tokens 15 minutes; a signed-in session, and every refresh family in it, 8 hours from sign-in, never extended |

## Why it is built this way

- **OIDC, not a private protocol.** Apps behind ordinary OIDC libraries can sign people in, and komira's own
  verifier and client already speak the token-endpoint wire this issuer serves.
- **PKCE and state always, exact redirects, single-use codes.** These are the OAuth 2.0 security best current
  practice (RFC 9700); none of them costs a legitimate client anything.
- **Opaque, rotated refresh tokens with no grace.** A refresh token is only ever read by the issuer, so it needs no
  signature; rotation with reuse detection turns a stolen token into a revoked family on its first double use.
- **Keys from files and operator-driven rotation.** The private key never passes through the environment or a store
  a reader could dump. The store records only when each public key was published and used, which is enough for the
  issuer to refuse a rotation step that would make verifiers refuse good tokens.
- **Federation as a port.** The issuer owns sessions, subjects and admission; the upstream only proves who a person
  is. Changing upstream providers is a new adapter and a mapping, never a new `sub`.
- **Signed removal notices on the key set apps already trust.** An app verifies a notice with the verifier it
  already runs, and the distinct `typ` keeps notices and tokens apart.
