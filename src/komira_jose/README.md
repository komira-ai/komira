# komira_jose

Signing and verification of JSON Web Signatures (RFC 7515) and JSON Web Tokens
(RFC 7519) with exactly one algorithm per signer or verifier: ES256, EdDSA
(Ed25519, RFC 8037) or RS256 (RFC 7518). Keys come from `komira_jwks`.

- `JwsVerifier(alg, keys)` pins one algorithm and takes a `JwkSet`; the
  token's `kid` selects the key, and a `kid` that names no key is refused
  rather than answered by trying the others. `JwsVerifier.single_key(alg,
  key)` takes one configured key and accepts a token without `kid`. Either
  raises for an algorithm other than the three, and for keys none of which
  suits the algorithm.
- `verifier.verify(token)` returns a `VerifiedJws` (`alg()`, `kid()`, `typ()`,
  `payload()`): the payload is authentic, and what it claims is the caller's
  to check. Before any key work the header gate refuses anything but three
  segments, a header that is not a JSON object or names a member twice,
  `alg` `none` and every `HS*` by name, any other algorithm than the pinned
  one, the members `jwk`, `jku`, `x5u` and `x5c` (the key never comes from
  the token), any `crit`, and a `kid` that is not printable ASCII. Then the
  key must suit the algorithm (type, length, and its `alg`, `use` and
  `key_ops` when present), the signature must have the algorithm's length
  (64 bytes for ES256 and EdDSA, the modulus length for RS256) and verify
  over the original signing input.
- `ClaimPolicy(issuer=, audience=, accept_typ=, now=, leeway_s=, max_ttl_s=)`
  holds one issuer, our audience, one header `typ` (`at+jwt` or `JWT`, never
  a set), the time, a leeway of 0 to 60 s and a longest lifetime of 1 to
  86400 s; `with_now(t)` is the same policy at another time.
- `verify_jwt(token, verifier, policy)` verifies with `typ` pinned and `kid`
  required, then refuses a payload that names a member twice, an `iss` other
  than the issuer, an `aud` that is neither our audience nor a non-empty array
  of strings holding it, an empty `sub`, a missing `exp` or `iat`, a time
  claim that is not a non-negative integer, `exp <= now - leeway`, an `iat` or
  `nbf` after `now + leeway`, and an `exp - iat` that is not positive or is
  above the max lifetime. It returns a `VerifiedJwt` with those claims and the
  whole claims object.

Every refusal raises `JoseError: <fixed text>`, and no text carries any byte
of the token. A verifier never accepts a second algorithm: a deployment that
trusts two issuers with different algorithms builds two verifiers.

## Signing

- `JwsSigner.es256(d)`, `JwsSigner.eddsa(seed)` and `JwsSigner.rs256(der)`
  take the private key as a zeroizing `SecretValue` (`komira_secret_store`):
  the 32-byte P-256 scalar (1 to n - 1), the 32-byte Ed25519 seed, or an RSA
  PKCS#8 DER key of 2048 to 4096 bits, counted in bits (as `komira_crypto`'s
  `rsa_pkcs8_der_from_pem` returns it). `JwsSigner(alg=, private_key=)` is the
  same with the algorithm named. Every constructor derives the public key from
  the private key, so the `kid` is always the RFC 7638 thumbprint of the
  signer's own key (`jwk_thumbprint`); `public_jwk()` is the key to publish,
  with `kid`, `alg` and `use` `sig`. A `komira_crypto` failure is raised as a
  `JoseError` too.
- `signer.sign(payload, typ)` returns `b64url(header).b64url(payload).b64url(sig)`
  with the header `{"alg":..,"kid":..,"typ":..}` (no `typ` when none is given).
  ES256 uses RFC 6979 deterministic nonces.
- `Keyring(alg=, max_token_ttl_s=, publish_lead_s=, now=)` holds one
  algorithm's keys over time. `rotate(signer, now)` stages a key;
  `render_jwks(now)` returns the JWK Set to publish (signing key, staged key,
  retiring keys) and records the staged key's first publication;
  `promote(kid, now)` lets the staged key sign only once it has been in a
  rendered set for `publish_lead_s`, and the old signing key starts retiring
  (its private key is dropped); `retire(kid, now)` removes a retiring key only
  after `max_token_ttl_s + JOSE_MAX_LEEWAY_S` (60 s, the largest leeway any
  `ClaimPolicy` may have, so no verifier still accepts a token of a key that
  left the set), and a staged key at once. `sign(payload, typ, now)` refuses a
  payload without integer `exp` and `iat` (as `verify_jwt` does) or whose
  `exp` is after `now + max_token_ttl_s`, so no token outlives its key's
  publication. Time never moves backwards.
- RFC 7523 assertions: `mint_assertion(signer, issuer=, subject=, audience=,
  now=, ttl_s=)` and `mint_client_assertion(signer, client_id=, audience=,
  now=, ttl_s=)` (where `iss` and `sub` are the client id) sign
  `{"iss","sub","aud","iat","exp","jti"}` with `typ` `JWT`, a lifetime of 1 to
  300 s and a `jti` of 128 random bits the caller cannot omit.
  `verify_assertion(token, verifier, policy)` is `verify_jwt` plus
  `exp - iat` of at most 300 s (whatever the policy's max TTL, so a replay
  cache holds a `jti` for at most 300 s plus the leeway) and a required
  non-empty `jti`; `verify_client_assertion` also requires `sub == iss`.
  Refusing a replayed `jti` is the caller's: it is the one that sees every
  assertion.

It does not fetch key sets, cache them, or remember `jti`s. Assertions from
other clients must carry `typ` (the policy pins one); a client that omits it is
refused.

## Example

The RFC 8037 appendix A.4 token, verified with its public key, and refused by
a verifier pinned to ES256:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_encoding import base64_url_decode_nopad
from komira_jose import JwsVerifier
from komira_jwks import Jwk

var token = (
    String("eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc.hgyY0il_MGCj")
    + "P0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g7sVvpAr_Mu"
    + "M0KAg"
)
var x = base64_url_decode_nopad("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo")
var verifier = JwsVerifier.single_key("EdDSA", Jwk.ed25519(Span(x)))
var payload = verifier.verify(token).payload()
assert_equal(len(payload), 26)

var other = base64_url_decode_nopad("f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU")
var other_y = base64_url_decode_nopad("x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0")
var es256 = JwsVerifier.single_key("ES256", Jwk.ec_p256(Span(other), Span(other_y)))
var refused = String("")
try:
    _ = es256.verify(token)
except e:
    refused = String(e)
assert_equal(refused, "JoseError: alg is not the pinned algorithm")
```

A signer's token, verified through the key set it publishes:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_encoding import base64_url_decode_nopad
from komira_jose import ClaimPolicy, JwsSigner, JwsVerifier, verify_jwt
from komira_jwks import Jwk, parse_jwk_set, render_jwk_set
from komira_secret_store import SecretValue

var seed = base64_url_decode_nopad("nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A")
var signer = JwsSigner.eddsa(SecretValue(Span(seed)))
assert_equal(signer.kid(), "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k")
var claims = String(
    '{"iss":"https://issuer.example/a","aud":"service-a","sub":"user-1",'
) + '"iat":1000000,"exp":1000300}'
var token = signer.sign(claims.as_bytes(), String("at+jwt"))
var published = List[Jwk]()
published.append(signer.public_jwk())
var verifier = JwsVerifier("EdDSA", parse_jwk_set(render_jwk_set(published)))
var policy = ClaimPolicy(
    issuer="https://issuer.example/a",
    audience="service-a",
    accept_typ="at+jwt",
    now=1000000,
    leeway_s=30,
    max_ttl_s=300,
)
assert_equal(verify_jwt(token, verifier, policy).subject, "user-1")
```
