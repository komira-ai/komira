# Crypto: the primitives the network stack depends on

## What is it for, and what is out of scope?

Connectors and servers need hashes, message authentication codes, key derivation, authenticated encryption, signatures and key agreement. `komira_crypto` provides them as Mojo functions and types over AWS-LC's `libcrypto`, which the build compiles from source as the static library `//third_party/aws-lc:crypto`. It is not a Mojo implementation of the algorithms. Twelve `internal/asm/*_ffi.mojo` files and `internal/asm/sha256_compress.mojo` call AWS-LC through `external_call`, and the public modules wrap those calls in APIs that take `Span` and `Array` values. Mojo code in the package covers hex, the PBKDF2 iteration loop, constant-time comparison, RFC 6979 nonce derivation for ECDSA, ASN.1 and X.509 parsing, and certificate chain validation.

`komira_crypto` (`src/komira_crypto`) holds the primitives, hex encoding, and the certificate code under `cert/`. Besides the standard library it imports `komira_encoding` (base64, base64url and base32), and its `mojo_library` lists two dependencies, `komira_encoding` and AWS-LC.

Out of scope:

- TLS connections. They run on s2n-tls (`third_party/s2n-tls`), which verifies certificates against its own trust store and calls no code in this library. s2n-tls is built against the same AWS-LC, so a binary that links both links one `libcrypto`; its own symbols carry the prefix `komira_s2n_`.
- Building AWS-LC: see `third_party/aws-lc/BUCK` and [the C and C++ rules](../../tools/build/mojo/README.md).
- The protocols built on these primitives, such as SCRAM-SHA-256, AWS SigV4 and signed URLs, which belong to the libraries that implement them.

## How does it work?

A caller imports a public module of `komira_crypto`. The module calls a wrapper in `internal/asm/`, which passes the caller's bytes to AWS-LC and returns the result as a Mojo `Array`, `List` or `Bool`.

```
caller ──► komira_crypto public module (hash, hmac, hkdf, aes_gcm, ed25519, ...)
               │   Span / Array in, Array / List / Bool out
               ▼
           internal/asm/*_ffi.mojo ──external_call──► AWS-LC libcrypto (linked statically)
```

### Which primitives does komira_crypto provide?

The table lists each family and the AWS-LC functions behind it.

| Family | Public names | Backend |
|---|---|---|
| Hashes | `Sha256`, `Sha384`, `Sha512` (streaming), `sha256`, `sha256_string`, `Sha1`, `sha1`, `blake2b_256` | `EVP_Digest*`, `SHA256`, `SHA1`, `BLAKE2B256` |
| HMAC | `hmac_sha256`, `hmac_sha256_string`, `Hmac[H]` | `HMAC`, `HMAC_CTX_*` |
| Key derivation | `Hkdf[H]`, `pbkdf2_hmac_sha256_32`, `pbkdf2_hmac_sha256` | `HKDF_extract`, `HKDF_expand`; PBKDF2 is a Mojo loop over `hmac_sha256` |
| AEAD | `AesGcm128`, `AesGcm256`, `ChaCha20Poly1305` | `EVP_AEAD_CTX_*` |
| Signatures | `ed25519_*`, `ecdsa_p256_*`, `ecdsa_p384_*`, `rsa_sha256_sign`, `rsa_pkcs1_sha256_verify`, `rsa_pss_verify` | `ED25519_*`, `EC_KEY`, `ECDSA_*`, `EVP_DigestSign`, `RSA_verify`, `RSA_verify_pss_mgf1` |
| Key agreement | `x25519`, `x25519_base_mult`, `x25519_4way`, `p256_ecdh` | `X25519`; `EC_POINT_oct2point`, `EC_POINT_mul` |
| Randomness | `system_entropy`, `SystemEntropy`, `ChaCha20Drbg` | `RAND_bytes` |
| Encoding | `hex_lower`, `hex_lower_array_32`, `hex_upper` | Mojo. Base64, base64url and base32 are `komira_encoding`'s, which this package imports and does not re-export |
| Certificates | `cert/`: `x509_parse_certificate`, `chain_verify`, `match_hostname`, `mozilla_root_store`, `root_store_verify` | Mojo, verifying through the signature wrappers |
| Hygiene | `zeroize_inline_array*`, `constant_time_eq_32`, `constant_time_eq_n` | libc `explicit_bzero` (Linux) or `memset_s` (macOS); Mojo byte compares |

The package root `__init__.mojo` re-exports most names, but not the ECDSA P-256 functions or anything under `cert/`; those are imported by module path.

### How do the wrappers reach AWS-LC?

Every AWS-LC call site in `komira_crypto` is in `internal/asm/`. Outside that directory, the library's only `external_call` sites are the libc calls in `zeroize.mojo`. Each wrapper file binds one AWS-LC area: `sha256_ffi.mojo` the digests, `hmac_ffi.mojo` HMAC, `hkdf_ffi.mojo` HKDF, `aes_gcm_ffi.mojo` and `chacha20_poly1305_ffi.mojo` the AEADs, `ed25519_ffi.mojo`, `p256_ffi.mojo`, `p384_ffi.mojo`, `rsa_ffi.mojo` and `rsa_sign_ffi.mojo` the signatures, `x25519_ffi.mojo` key agreement and `rng_ffi.mojo` randomness. `sha256_compress.mojo` binds AWS-LC's `sha256_block_data_order_hw` as `sha256_compress_blocks`, through `komira_crypto_sha256_block_data_order_hw` (`native/komira_crypto_sha256_hw.c`): AWS-LC's assembly declares the function hidden, so the package exports this wrapper instead. `internal/asm/__init__.mojo` re-exports `sha256_compress_blocks` and nothing calls it. Every AWS-LC symbol carries the prefix `komira_awslc_` (`external_call["komira_awslc_SHA256", ...]`), so a process can hold this AWS-LC beside another `libcrypto` (see [the symbol prefixing](../../tools/build/native/README.md)).

`komira_crypto` lists `//third_party/aws-lc:crypto` in its `deps`. A `mojo_library` passes its C and C++ deps on to its consumers and to its own tests (see [the Mojo rules](../../tools/build/mojo/README.md)), so every binary or test with `komira_crypto` in its closure links AWS-LC statically and names nothing itself.

### How are hashes, HMAC and HKDF composed?

`traits.mojo` declares `Hash`: `OUTPUT_SIZE`, `BLOCK_SIZE`, `update`, `finalize_into`, `reset` and `fork`. `Sha256`, `Sha384` and `Sha512` in `hash.mojo` conform to it by wrapping `Sha2Hasher[OUTPUT_SIZE]` from `sha256_ffi.mojo`, which holds an `EVP_MD_CTX`. `fork()` copies the context with `EVP_MD_CTX_copy_ex`, so a caller can finish a digest and keep hashing, as a transcript hash needs.

`Hmac[H: Hash]` (`hmac_streaming.mojo`) and `Hkdf[H: Hash]` (`hkdf.mojo`) are generic over the hash type, but the AWS-LC digest they use comes from `H.OUTPUT_SIZE`: 32 selects SHA-256, 48 SHA-384 and 64 SHA-512. A `comptime assert` rejects any other size. `Hkdf` has `extract` and `expand` (RFC 5869) and the TLS 1.3 helpers `hkdf_expand_label` and `derive_secret`. `derive_secret` is the one place either type uses `H`'s own implementation: it hashes the transcript with `H`'s `update` and `finalize_into` before the expand step.

`Sha1` and `sha1` produce SHA-1 over AWS-LC, and `Sha1` is deliberately not a `Hash` conformer. `blake2b_256` is a one-shot BLAKE2b-256. The one-shot `sha256` and `hmac_sha256` functions call AWS-LC's one-shot `SHA256` and `HMAC`.

### How do the AEAD types seal and open?

`Aead` in `traits.mojo` fixes `KEY_SIZE`, `NONCE_SIZE`, `TAG_SIZE` and `SEQUENCE_LIMIT` at compile time, and has two methods that work in place on one buffer laid out as data followed by a 16-byte tag. `AesGcm128` (16-byte key), `AesGcm256` and `ChaCha20Poly1305` (32-byte keys) conform; all use 12-byte nonces. Each constructor creates an AWS-LC `EVP_AEAD_CTX` from the key, and `EVP_AEAD_CTX_free` releases it when the value is destroyed.

`seal_in_place` encrypts the data and writes the tag into the trailing 16 bytes. `open_in_place` calls `EVP_AEAD_CTX_open` and raises when it reports a tag mismatch; the AES-GCM wrapper's message is `"AesGcm.open_in_place: authentication failure"`. The caller supplies each nonce, and the types keep no sequence counter.

### How are signatures and key agreement computed?

- **Ed25519** (`ed25519.mojo`): `ed25519_sign` takes a 32-byte seed rather than an expanded key, and `ed25519_pubkey_from_seed` derives the public key. Both raise when the seed is shorter than 32 bytes. `ed25519_verify` returns `False` for a public key shorter than 32 bytes or a signature shorter than 64.
- **ECDSA P-256 and P-384** (`ecdsa_p256.mojo`, `ecdsa_p384.mojo`): keys and signatures are fixed-width big-endian bytes, with public keys as `x || y` and no `0x04` prefix. `ecdsa_p256_sign_deterministic` hashes the message, derives the nonce `k` in Mojo per RFC 6979 using `Hmac[Sha256]`, and passes it to AWS-LC's `ECDSA_sign_with_nonce_and_leak_private_key_for_testing`. `ecdsa_p256_sign_random` takes a caller-supplied `k` instead.
- **RSA**: `rsa_sha256_sign` signs with a PKCS#8 DER private key through `EVP_DigestSign`. `rsa_pkcs1_sha256_verify` takes the modulus as big-endian bytes and the exponent as a `UInt64`. `rsa_pss_verify[N_LIMBS, H]` takes an `RsaPublicKey[N_LIMBS]`, which holds the modulus as `UInt64` limbs and the exponent `e`; `rsa_public_key_from_bytes` builds one from big-endian modulus bytes and a `UInt64` exponent.
- **X25519** (`x25519.mojo`): `x25519` computes a shared secret and `x25519_base_mult` a public key. When AWS-LC's `X25519` rejects the input, as it does for a small-order point, the result is 32 zero bytes. `x25519_4way` in `x25519_simd.mojo` makes four sequential calls to the same AWS-LC function and uses no SIMD.
- **P-256 ECDH** (`ecdh_p256.mojo`, bound in `internal/asm/p256_ecdh_ffi.mojo`): `p256_ecdh(priv, peer_pub_uncompressed)` returns the x-coordinate of `priv * peer`, the SP 800-56A shared secret Z that RFC 8291 Web Push encryption uses. The private key is 32 big-endian bytes and the peer key the 65-byte uncompressed point `0x04 || x || y`. It raises, with a message naming the reason, for the point at infinity, a peer key of another length or leading byte, a peer point off the curve, and a private key that is not 32 bytes or not in [1, n-1].

### Where does randomness come from?

`system_entropy` fills a buffer from AWS-LC's `RAND_bytes` and raises if that call fails. `SystemEntropy` and `ChaCha20Drbg` in `rng.mojo` are wrappers over the same call: `ChaCha20Drbg` holds no cipher state, and its seeded constructor and `reseed` read one byte from the `SystemEntropy` they are given and otherwise ignore it.

### How is a certificate chain validated?

`cert/` is a Mojo X.509 stack. `asn1.mojo` parses DER, `x509.mojo` parses a certificate into `X509Certificate`, and `name_matcher.mojo`'s `match_hostname` checks a host name against a certificate per RFC 6125. `root_store.mojo`'s `mozilla_root_store` parses ten root certificates whose DER bytes live in the generated `root_store_data.mojo`.

`chain_verify` in `chain.mojo` takes the chain leaf first, the trust anchors, and the current time from the caller. It runs three phases:

1. Each certificate must be inside its validity period and carry no unknown critical extension.
2. Each link must match the issuer name to the next subject name, the issuer must carry `basicConstraints` with `cA` set and, if it has a key usage, `keyCertSign`, and the signature must verify. Supported signatures are ECDSA P-256 with SHA-256, ECDSA P-384 with SHA-384, Ed25519, and RSA-PSS with SHA-256 over a 2048-bit key.
3. The last certificate passes if its subject name equals an anchor's subject name, or if an anchor with its issuer's name verifies its signature.

Between phases 1 and 2 the leaf is checked: a key usage, if present, must allow digital signature, key agreement or key encipherment, and an extended key usage, if present, must name `serverAuth`. A rejection raises an error naming the failed check rather than returning `False`. Nothing outside `komira_crypto` calls this code; see the limits for why it is not ready to.

## Why is it built this way?

### Why are the primitives bindings over AWS-LC?

**Decision.** Every hash, MAC, KDF, AEAD, signature and key-agreement primitive calls AWS-LC; Mojo code only encodes, parses and composes.

**Because.** The binding headers record measurements against Mojo implementations. The header of `internal/asm/sha256_compress.mojo` records that a Mojo SHA-256 issuing the SHA instructions as inline assembly, even in AWS-LC's instruction order, stayed several times slower than AWS-LC. The header of `internal/asm/p256_ffi.mojo` records that a Mojo P-256 passed the RFC 6979 known-answer tests but was "orders of magnitude slower than AWS-LC's hand-tuned P-256 path".

**Alternatives weighed.**

- Mojo implementations: slower, per the two measurements under Because.
- Inline assembly per round inside Mojo: several times slower; the header attributes it to setup moves at each assembly site, register allocation across sites, and the short scheduling windows between them.

**Revisit if.** A Mojo implementation matches AWS-LC in a benchmark and the gain outweighs keeping a second implementation correct.

### Why does ECDSA pass its own nonce to AWS-LC?

**Decision.** Deterministic ECDSA signing, `ecdsa_p256_sign_deterministic` and `ecdsa_p384_sign_deterministic`, derives the RFC 6979 nonce in Mojo and signs through `ECDSA_sign_with_nonce_and_leak_private_key_for_testing`. `ecdsa_p256_sign_random` and `ecdsa_p384_sign_random` pass a caller-supplied `k` to the same function, and the argument below does not cover them: their docstrings say the caller "MUST supply a unique k per invocation" and that reuse of `k` "across different messages with the same private key leaks the private key". Only the package's tests call them.

**Because.** RFC 6979 fixes the signature for a given key and message, and the known-answer tests assert those exact bytes. The header of `p256_ffi.mojo` records that the function "accepts a caller-supplied 32-byte BE nonce, enabling RFC 6979 byte-identical output", and that its "leak" caveat "is irrelevant for our use case because RFC 6979's nonce is deterministically derivable from (privkey, message) per the spec". The caveat is the one in the AWS-LC name, `leak_private_key`.

**Alternatives weighed.**

- `EVP_DigestSign`: cannot take an explicit nonce, so RFC 6979 output is impossible.
- `ECDSA_sign`: DER-encoded output and no explicit-nonce variant.

**Revisit if.** AWS-LC offers a supported deterministic ECDSA entry point, or the testing function changes.

### Why is SHA-1 not a Hash conformer?

**Decision.** `Sha1` implements streaming SHA-1 without conforming to `Hash`.

**Because.** The comment beside its re-export in `__init__.mojo` records the purpose: SHA-1 is a witness digest, and keeping it outside `Hash` means "no HMAC / HKDF / signature / transcript can be built over it". The `comptime assert` in `HmacFfiCtx` and the HKDF wrappers would also reject a 20-byte output.

**Alternatives weighed.**

- Conform `Sha1` to `Hash`: it would type-check wherever a `Hash` is accepted, inviting SHA-1 into constructions that must not use it.

**Revisit if.** A protocol this repository implements requires HMAC-SHA-1.

## What must always hold?

- **In `komira_crypto`, AWS-LC is called only from `internal/asm/`.** Outside that directory, the library's only `external_call` sites are the libc calls in `zeroize.mojo`, and no function signature outside `internal/asm/` names a pointer type; see [the pointer rule](mojo_safety_and_idioms.md#why-must-a-raw-pointer-stay-inside-one-module). Not enforced by any check in this library's build.
- **A consumer links AWS-LC.** Held by the library's `deps`, which carry `//third_party/aws-lc:crypto` into every link that includes `komira_crypto`.
- **The AWS-LC digest follows `OUTPUT_SIZE`.** The AWS-LC HMAC and HKDF calls behind `Hmac[H]` and `Hkdf[H]` use SHA-256, SHA-384 or SHA-512 by `H.OUTPUT_SIZE`, not `H`'s own implementation. `Hkdf.derive_secret` also hashes its transcript with `H` itself, so its result depends on `H` computing the digest its size selects. Only the size is enforced, at compile time, by `comptime assert` in `hmac_ffi.mojo` and `hkdf_ffi.mojo`; the asserts do not look at `H`'s implementation.
- **A failed tag check raises.** `open_in_place` raises rather than return unauthenticated plaintext. Enforced by the tamper cases in `test_aes_gcm_smoke` and `test_chacha20_poly1305_kat`.
- **A rejected X25519 input yields zeros.** `x25519` returns 32 zero bytes, and a caller must reject that value. Enforced by `test_x25519_small_order`.
- **A rejected P-256 ECDH input raises.** `p256_ecdh` never returns a value for a peer point off the curve, the point at infinity, or a private key outside [1, n-1]. Enforced by `test_p256_ecdh_refusals`.
- **Ed25519 length guards.** Signing raises on a seed shorter than 32 bytes and verification returns `False` on short inputs. Enforced by `test_ed25519_length_guard`.
- **ECDSA signing failures raise.** Enforced by `test_ecdsa_sign_failure_raises`. `ecdsa_p256_generate_pubkey` does not raise: on failure it returns 64 zero bytes.
- **Ownership.** The hash, HMAC and AEAD types each own one AWS-LC context and are `Movable` but not `Copyable`; `fork()` is the only way to duplicate a hash or HMAC state. Enforced by the types.

## Where is the code?

| File | Holds | Key types and functions |
|---|---|---|
| `src/komira_crypto/traits.mojo` | the `Hash`, `Aead` and `KeySchedule` traits | `Hash`, `Aead`, `KeySchedule` |
| `src/komira_crypto/hash.mojo` | streaming SHA-2 and SHA-1, one-shot SHA-1 and BLAKE2b-256 | `Sha256`, `Sha384`, `Sha512`, `Sha1`, `sha1`, `blake2b_256` |
| `src/komira_crypto/sha256.mojo`, `hmac.mojo`, `hmac_streaming.mojo`, `hkdf.mojo`, `pbkdf2.mojo` | one-shot SHA-256 and HMAC, generic HMAC and HKDF, PBKDF2 | `sha256`, `hmac_sha256`, `constant_time_eq_32`, `Hmac`, `Hkdf`, `pbkdf2_hmac_sha256_32` |
| `src/komira_crypto/aes_gcm.mojo`, `chacha20_poly1305.mojo`, `aead.mojo` | the AEAD conformers and a variable-length constant-time compare | `AesGcm128`, `AesGcm256`, `ChaCha20Poly1305`, `constant_time_eq_n` |
| `src/komira_crypto/ed25519.mojo`, `ecdsa_p256.mojo`, `ecdsa_p384.mojo`, `rsa.mojo`, `rsa_pss.mojo` | signatures | `ed25519_sign`, `ecdsa_p256_sign_deterministic`, `rsa_sha256_sign`, `rsa_pss_verify` |
| `src/komira_crypto/x25519.mojo`, `x25519_simd.mojo` | X25519 | `x25519`, `x25519_base_mult`, `x25519_4way` |
| `src/komira_crypto/ecdh_p256.mojo` | P-256 ECDH | `p256_ecdh` |
| `src/komira_crypto/rng.mojo`, `zeroize.mojo` | randomness and wiping | `system_entropy`, `SystemEntropy`, `ChaCha20Drbg`, `zeroize_inline_array` |
| `src/komira_crypto/hex.mojo` | hex | `hex_lower_array_32` |
| `src/komira_crypto/internal/asm/` | the AWS-LC bindings | `Sha2Hasher`, `HmacFfiCtx`, `rand_bytes_ffi`, `p256_sign_with_nonce`, `x25519_scalarmult` |
| `src/komira_crypto/cert/` | ASN.1, X.509, host-name matching, roots, chain validation | `x509_parse_certificate`, `match_hostname`, `mozilla_root_store`, `chain_verify` |
| `src/komira_crypto/BUCK` | the `komira_crypto` library and its gated tests | `mojo_library(name = "komira_crypto")` |

Entry points:

- **Public API:** the free functions and types re-exported by `src/komira_crypto/__init__.mojo`; `ecdsa_p256` and `cert` by module path.
- **Execution starts at:** the caller's first call into a public function; the libraries have no initialization step.

## How is it tested?

`komira_crypto` lists its 61 test files in `test_srcs` in `src/komira_crypto/BUCK`, so building the library runs them all (see [the `test_srcs` gate](../../tools/build/mojo/README.md#libraries-and-the-test_srcs-gate)), and each links AWS-LC through the library's `deps`.

| Test | Covers |
|---|---|
| `test_cavp_sha{256,384,512}_{short,long,monte}` | NIST CAVP vectors; the SHA-256 files check both the streaming and one-shot surfaces |
| `test_sha*_kat`, `test_sha*_smoke`, `test_sha1_kat`, `test_blake2b_256_kat` | digest known answers |
| `test_hmac_kat`, `test_hmac_streaming_smoke`, `test_hkdf_*`, `test_wycheproof_hkdf_sha{256,384,512}`, `test_derive_secret` | HMAC and HKDF, including Wycheproof vectors |
| `test_aes_gcm_kat`, `test_aes_gcm_smoke`, `test_chacha20_poly1305_kat` | AEAD known answers and tamper rejection |
| `test_ed25519_rfc8032`, `test_ecdsa_p{256,384}_rfc6979`, `test_rsa_pkcs1_verify`, `test_rsa_pss_verify` | signature vectors |
| `test_x25519_kat`, `test_x25519_iterated`, `test_x25519_small_order`, `test_x25519_4way_oracle` | X25519 |
| `test_p256_ecdh_kat`, `test_p256_ecdh_refusals` | P-256 ECDH: the 25 NIST CAVP KAS ECC CDH P-256 vectors, RFC 5903 section 8.1 and RFC 8291 appendix A; refused points and keys with their exact messages |
| `test_asn1_*`, `test_x509_*`, `test_name_matcher`, `test_root_store*`, `test_chain_validator*`, `test_bettertls_synthetic` | the certificate stack, including 19 synthetic chain and host-name cases |

Run: `./buck2 build //src/komira_crypto:komira_crypto`.

The CAVP and Wycheproof tests are generated from the upstream vector files: each file's header names its source, such as NIST CAVP `SHA256ShortMsg.rsp`, and the vectors are written into the test source.

Not tested: nothing tests `chain_verify` against a terminal certificate that carries an anchor's name with a different key.

## What are its limits and open questions?

- **Limit: a root is trusted by name.** Phase 3 of `chain_verify` accepts the last certificate when its subject name equals a trust anchor's subject name, without comparing keys or certificate bytes and without verifying that certificate's own signature. A self-issued certificate carrying a root's name therefore passes as an anchor. Nothing calls `chain_verify` outside tests, and TLS verification runs in s2n-tls, so no connection depends on it; the validator is not safe to adopt until Phase 3 compares the anchor itself.
- **Limit: other chain-validation gaps.** `chain_verify` raises for PKCS#1 v1.5 RSA signatures and for RSA-PSS keys other than 2048-bit, compares names byte for byte rather than by RFC 5280's rules, parses `pathLenConstraint` without enforcing it, and does no revocation checking.
- **Limit: TLS-shaped pieces with no user.** The `KeySchedule` trait has no conformer, and nothing reads `SEQUENCE_LIMIT`, although the `Aead` docstring says a record layer asserts it. `Hkdf.hkdf_expand_label` and `Hkdf.derive_secret` have no caller outside the package's tests.
- **Limit: helpers that fail quietly.** `ChaCha20Drbg.next` fills its output with zeros if `RAND_bytes` fails, and ignores the seed it is constructed with. `x25519_4way` discards each lane's status, so a rejected lane yields zeros with no signal. Neither has a caller outside tests.
- **Limit: keys are not wiped by the AEAD constructors.** The `Aead` docstring says a conformer zeroes its key; `AesGcm128`, `AesGcm256` and `ChaCha20Poly1305` borrow the key array and do not, so wiping it is the caller's job.
- **Open question:** should `cert/` and the TLS 1.3 key-schedule helpers stay? They have no caller, and TLS verification lives in s2n-tls. Fixing the anchor check would make `cert/` usable by code that verifies certificates outside a TLS handshake; deleting both removes code that nothing calls.
