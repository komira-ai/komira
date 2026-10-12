# komira_jwks

JSON Web Keys (RFC 7517) for verifying signatures: the public keys a verifier
fetches to learn which keys sign tokens.

- `Jwk` is one public key of a supported type: OKP Ed25519 (RFC 8037), EC
  P-256 or RSA (2048 to 4096 bits). `Jwk.ed25519`, `Jwk.ec_p256` and
  `Jwk.rsa` build one and refuse a wrong length or range; the accessors
  (`kty`, `crv`, `x`, `y`, `n`, `e`, `kid`, `alg`, `key_use`, `key_ops`)
  return copies. A `key_ops` array that names one value twice is refused
  (RFC 7517 section 4.3).
  It has no field for a private member, so nothing built from it carries one.
- `parse_jwk_set(doc)` reads a JWK Set strictly, on `komira_json`. It refuses
  the whole document (`JwksError: ...`) above `JWKS_MAX_DOCUMENT_BYTES` or
  `JWKS_MAX_KEYS`, for a member name repeated in any object, for any private
  member (`d`, `p`, `q`, `dp`, `dq`, `qi`, `oth`, `k`) and for two accepted
  keys with one `kid` (a skipped key does not count). A key it does not support (another `kty` or curve, a missing or
  malformed member, an RSA size out of range) is left out and named in
  `JwkSet.skipped`, so it cannot hide the others (RFC 7517 section 5).
  `parse_jwk(doc)` reads one key and raises for either kind of problem.
  `JwkSet.index_of_kid` finds a key by `kid`.
- `render_jwk`, `render_jwk_set` and `JwkSet.render` write the canonical
  form: members in the order `kty`, `crv`, `alg`, `use`, `key_ops`, `kid`, then the key
  members, optional members only when present, strings escaped.
- `kid_for_pubkey(pubkey)` is a key id for an Ed25519 key: base64url without
  padding of the SHA-256 of the 32-byte public key, the whole digest (43
  characters). It is a function of the key alone, so a signer and the
  published document agree on it with nothing stored.
- `render_jwks_json(keys)` renders `{"keys":[...]}` from a list of
  `(kid, pubkey)` Ed25519 pairs, one
  `{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":...,"x":...}`
  per key in list order; an empty list renders `{"keys":[]}`, and an empty
  kid raises.
- `jwks_json_from_seed(seed)` derives the public key from a 32-byte Ed25519
  seed, held in a zeroizing `komira_secret_store.SecretValue` that it
  consumes, and renders the one-key set. It raises on a seed shorter than 32
  bytes.

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

Parse a key set: the RFC 7517 appendix A.1 EC key is kept, a P-384 key is
skipped with its reason, and the canonical form reads back to the same keys:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_jwks import JWK_KTY_EC, JwkSet, parse_jwk_set

var doc = (
    String('{"keys":[{"kty":"EC","crv":"P-256",')
    + '"x":"MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",'
    + '"y":"4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM","use":"enc","kid":"1"},'
    + '{"kty":"EC","crv":"P-384","x":"AA","y":"AA"}]}'
)
var keys: JwkSet = parse_jwk_set(doc)
assert_equal(len(keys.keys), 1)
assert_equal(keys.keys[0].kty(), JWK_KTY_EC)
assert_equal(keys.keys[0].kid().value(), "1")
assert_equal(keys.skipped[0], 'key 1: EC curve "P-384" is not supported (P-256 is)')
assert_equal(keys.index_of_kid("1").value(), 0)
var again = parse_jwk_set(keys.render())
assert_true(again.keys[0] == keys.keys[0])
```

What refuses a whole document:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_jwks import JWKS_MAX_DOCUMENT_BYTES, JWKS_MAX_KEYS, parse_jwk, parse_jwk_set

var message = String()
try:
    _ = parse_jwk_set('{"keys":[{"kty":"OKP","crv":"Ed25519","x":"AA","x":"AB"}]}')
except e:
    message = String(e)
assert_equal(message, "JwksError: JsonError: duplicate object key 'x' at line 1")
try:
    _ = parse_jwk_set('{"keys":[{"kty":"OKP","crv":"Ed25519","x":"AA","d":"AA"}]}')
except e:
    message = String(e)
assert_equal(
    message,
    'JwksError: key 0 carries the private member "d"; a published key holds public members only',
)
assert_equal(JWKS_MAX_DOCUMENT_BYTES, 262144)
assert_equal(JWKS_MAX_KEYS, 64)
var one = parse_jwk('{"kty":"OKP","crv":"Ed25519","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}')
assert_equal(len(one.x()), 32)
```

Build keys and render them:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_jwks import JWK_CRV_ED25519, JWK_CRV_P256, JWK_KTY_OKP, JWK_KTY_RSA
from komira_jwks import JWK_RSA_MAX_MODULUS_BYTES, JWK_RSA_MIN_MODULUS_BYTES
from komira_jwks import Jwk, render_jwk, render_jwk_set

var coord = List[UInt8]()
for i in range(32):
    coord.append(UInt8(i))
var ed = Jwk.ed25519(Span(coord), kid=Optional[String](String("a")))
assert_equal(ed.kty(), JWK_KTY_OKP)
assert_equal(ed.crv(), JWK_CRV_ED25519)
assert_equal(
    render_jwk(ed),
    '{"kty":"OKP","crv":"Ed25519","kid":"a","x":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}',
)
var coord_y = coord.copy()
var ec = Jwk.ec_p256(Span(coord), Span(coord_y), alg=Optional[String](String("ES256")))
assert_equal(ec.crv(), JWK_CRV_P256)
assert_equal(len(ec.y()), 32)
assert_equal(ec.alg().value(), "ES256")
var modulus = List[UInt8]()
for _ in range(JWK_RSA_MIN_MODULUS_BYTES):
    modulus.append(0xC5)
var exponent = List[UInt8]()
exponent.append(3)
var rsa = Jwk.rsa(Span(modulus), Span(exponent), key_use=Optional[String](String("sig")))
assert_equal(rsa.kty(), JWK_KTY_RSA)
assert_equal(len(rsa.n()), 256)
assert_equal(len(rsa.e()), 1)
assert_equal(rsa.key_use().value(), "sig")
assert_equal(JWK_RSA_MAX_MODULUS_BYTES, 512)
var keys = List[Jwk]()
keys.append(ed^)
assert_equal(render_jwk_set(keys), String('{"keys":[') + render_jwk(keys[0]) + "]}")
var buf = List[UInt8]()
keys[0].write_json(buf)
assert_equal(String(unsafe_from_utf8=Span(buf)), render_jwk(keys[0]))
```
