# komira_jose

Verification of JSON Web Signatures (RFC 7515) and JSON Web Tokens (RFC 7519)
with exactly one algorithm per verifier: ES256, EdDSA (Ed25519, RFC 8037) or
RS256 (RFC 7518). Keys come from `komira_jwks`.

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
of the token. It does not sign, fetch key sets or cache them. A verifier never
accepts a second algorithm: a deployment that trusts two issuers with
different algorithms builds two verifiers.

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
