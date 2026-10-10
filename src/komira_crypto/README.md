# komira_crypto

Cryptographic primitives for Mojo. The heavy algorithms call AWS-LC's
`libcrypto`; the traits, the hex codec and the DER / X.509 layer are Mojo.
Byte inputs are `Span[UInt8, _]`; fixed-size outputs are `Array[UInt8, N]`.

- Hashes: `sha256`, `Sha256` / `Sha384` / `Sha512` (the streaming `Hash`
  trait), `blake2b_256`, and the streaming `Sha1` plus one-shot `sha1` (kept for
  checksums a protocol demands; `Sha1` is not a `Hash` conformer).
- MACs and KDFs: `hmac_sha256`, the generic `Hmac[H]`, `Hkdf[H]` (extract,
  expand, the TLS 1.3 `hkdf_expand_label`), `pbkdf2_hmac_sha256`.
- AEADs: `AesGcm128`, `AesGcm256`, `ChaCha20Poly1305`, sealing and opening
  in place (`[plaintext][16-byte tag]`); opening raises on a tag mismatch.
- Key agreement: `x25519`, `x25519_base_mult`, and a 4-way batched form;
  P-256 ECDH, `p256_ecdh`.
- Signatures: Ed25519 (sign, verify, public key from seed, generate), ECDSA
  P-256 and P-384, RSA-SHA256 PKCS#1 v1.5 sign and verify (with a PEM
  `PRIVATE KEY` reader), RSA-PSS verify. RS256 JWS verification against a
  JWK Set is in `komira_jose`.
- Randomness: `SystemEntropy` / `system_entropy` and a `ChaCha20Drbg`.
- Helpers: `hex_lower` / `hex_upper`, constant-time comparison
  (`constant_time_eq_32`, `constant_time_eq_n`), zeroizing a buffer.
- `komira_crypto.cert`: X.509 parsing and chain validation against a root
  store.

It is not a TLS stack (the record layer and handshake are in
`komira_http_core`). Base64 and base32 are in `komira_encoding`.

## Examples

Digests and MACs against published vectors (FIPS 180-2, RFC 4231 test case
2, RFC 7914 section 11):

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_crypto import constant_time_eq_32, hex_lower, hex_lower_array_32
from komira_crypto import hmac_sha256, pbkdf2_hmac_sha256, sha256, sha256_string

assert_equal(
    hex_lower_array_32(sha256_string("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
)
assert_true(constant_time_eq_32(sha256("abc".as_bytes()), sha256_string("abc")))
assert_false(constant_time_eq_32(sha256_string("abc"), sha256_string("abd")))

var mac = hmac_sha256("Jefe".as_bytes(), "what do ya want for nothing?".as_bytes())
assert_equal(
    hex_lower_array_32(mac),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
)

var dk = pbkdf2_hmac_sha256("password".as_bytes(), "salt".as_bytes(), 1, 32)
assert_equal(
    hex_lower(Span(dk)),
    "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
)
```

Ed25519 (RFC 8032 section 7.1, test 1) and X25519 key agreement (RFC 7748
section 6.1):

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_crypto import ed25519_pubkey_from_seed, ed25519_sign, ed25519_verify
from komira_crypto import hex_lower, hex_lower_array_32, x25519, x25519_base_mult
from komira_encoding import hex_decode

var seed = hex_decode("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
var pubkey = ed25519_pubkey_from_seed(Span(seed))
assert_equal(
    hex_lower_array_32(pubkey),
    "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
)
var empty = List[UInt8]()
var sig = ed25519_sign(Span(seed), Span(empty))
assert_equal(
    hex_lower(Span[UInt8, origin_of(sig)](sig)),
    "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
)
assert_true(ed25519_verify(
    Span[UInt8, origin_of(pubkey)](pubkey), Span(empty), Span[UInt8, origin_of(sig)](sig)
))
assert_false(ed25519_verify(
    Span[UInt8, origin_of(pubkey)](pubkey), "x".as_bytes(), Span[UInt8, origin_of(sig)](sig)
))

var alice = hex_decode("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
var bob = hex_decode("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
var alice_pub = x25519_base_mult(Span(alice))
var bob_pub = x25519_base_mult(Span(bob))
assert_equal(
    hex_lower_array_32(alice_pub),
    "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a",
)
var shared = x25519(Span(alice), Span[UInt8, origin_of(bob_pub)](bob_pub))
assert_equal(hex_lower_array_32(shared), hex_lower_array_32(x25519(Span(bob), Span[UInt8, origin_of(alice_pub)](alice_pub))))
assert_equal(
    hex_lower_array_32(shared),
    "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742",
)
```

Sealing and opening with ChaCha20-Poly1305: the buffer holds the plaintext
followed by room for the 16-byte tag, and a changed byte fails to open:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises, assert_true -->
```mojo
from komira_crypto import ChaCha20Poly1305

var key = Array[UInt8, 32](fill=7)
var nonce = Array[UInt8, 12](fill=1)
var aad = "header".as_bytes()
var cipher = ChaCha20Poly1305(key)

var message = "attack at dawn".as_bytes()
var buf = List[UInt8]()
for i in range(len(message)):
    buf.append(message[i])
for _ in range(16):
    buf.append(0)  # room for the tag
cipher.seal_in_place(nonce, aad, Span(buf))
assert_true(buf[0] != UInt8(ord("a")))  # encrypted in place

var copy = buf.copy()
cipher.open_in_place(nonce, aad, Span(buf))
for i in range(len(message)):
    assert_equal(buf[i], message[i])  # the plaintext is back

copy[3] ^= 1
with assert_raises():
    cipher.open_in_place(nonce, aad, Span(copy))
```
