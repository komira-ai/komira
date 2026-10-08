# komira_jwks

The public-key half of an Ed25519 token stack: the key id and the JWK Set
document (RFC 7517, OKP keys per RFC 8037) a verifier fetches to learn which
keys sign tokens.

- `kid_for_pubkey(pubkey)` is the key id: base64url without padding of the
  SHA-256 of the 32-byte public key, the whole digest (43 characters). It is
  a function of the key alone, so a signer and the published document agree
  on it with nothing stored.
- `render_jwks_json(keys)` renders `{"keys":[...]}` from a list of
  `(kid, pubkey)` pairs, one
  `{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":...,"x":...}`
  per key in list order; an empty list renders `{"keys":[]}`. It only ever sees
  public keys, so it never emits a private `d` member.
- `jwks_json_from_seed(seed)` derives the public key from a 32-byte Ed25519
  seed, held in a zeroizing `komira_secret_store.SecretValue` that it
  consumes, and renders the one-key set. It raises on a seed shorter than 32
  bytes.
- `komira_jwks.well_known.IDENTITY_JWKS_PATH` is the path an issuer serves
  its key set at, `/.well-known/identity-jwks.json`.

It does not sign or verify tokens, fetch a key set, or serve one.

## Examples

The RFC 8037 appendix A key: its key id, and the same document rendered from
the public key and derived from the seed:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises -->
```mojo
from komira_encoding import base64_url_decode_nopad, hex_decode
from komira_jwks import jwks_json_from_seed, kid_for_pubkey, render_jwks_json
from komira_secret_store import SecretValue

comptime X = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
comptime KID = "If4x36FUomFia_hUBG_SJxt77UtqvkWqWId-9H-XIbk"
comptime SEED = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"

var raw = base64_url_decode_nopad(X)
assert_equal(len(raw), 32)
assert_equal(kid_for_pubkey(Span(raw)), KID)

var pubkey = Array[UInt8, 32](fill=0)
for i in range(32):
    pubkey[i] = raw[i]
var keys = List[Tuple[String, Array[UInt8, 32]]]()
keys.append((kid_for_pubkey(Span(raw)), pubkey^))
var doc = render_jwks_json(keys)
assert_equal(
    doc,
    String('{"keys":[{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":"')
    + KID + '","x":"' + X + '"}]}',
)

var seed = hex_decode(SEED)
assert_equal(jwks_json_from_seed(SecretValue(Span(seed))), doc)
assert_false('"d"' in doc)  # public members only

assert_equal(render_jwks_json(List[Tuple[String, Array[UInt8, 32]]]()), '{"keys":[]}')
var short = hex_decode("00112233")
with assert_raises(contains="32 bytes"):
    _ = jwks_json_from_seed(SecretValue(Span(short)))
```

The path a key set is served at:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_jwks.well_known import IDENTITY_JWKS_PATH

assert_equal(IDENTITY_JWKS_PATH, "/.well-known/identity-jwks.json")
```
