# =============================================================================
# komira_crypto/internal/asm — hardware-accelerated crypto primitives
# =============================================================================
#
# This subdirectory bridges Mojo to hand-tuned crypto assembly. Two
# implementation strategies are available:
#
#  1. **FFI to AWS-LC's libcrypto** — the PREFERRED strategy: link AWS-LC
#     and call into it via Mojo FFI. The function bodies ARE the AWS-LC
#     implementation, so performance is identical to AWS-LC's. Inline
#     assembly issued per call cannot match it: the per-call boundary cost
#     dominates at block sizes a hash sees.
#
#  2. **Mojo `inlined_assembly`** — used by nothing today. It stays an
#     option for primitives where FFI overhead dominates (small inputs,
#     tight inner loops with no equivalent AWS-LC symbol).
#
# # Patterns sourced (re-expressed via FFI; not copied)
#
# Each primitive's instruction-level recipe comes from production crypto
# libraries. SHA-256 specifically:
#   * SHA-256: AWS-LC's `crypto/fipsmodule/sha/asm/sha512-armv8.pl` (and the
#     x86-64 equivalent) → the `sha256_block_data_order_hw` and
#     `sha256_block_data_order_nohw` bodies in libcrypto (Apache 2.0 /
#     OpenSSL dual license). Called verbatim by `sha256_compress.mojo`
#     through the C wrappers `komira_crypto_sha256_block_data_order` (CPUID
#     dispatch) and `komira_crypto_sha256_block_data_order_nohw`
#     (`native/komira_crypto_sha256_hw.c`) — the instruction sequences are
#     AWS-LC's; the wrappers are ours.
#
# # The public API of `komira_crypto` does not expose this directory
#
# Modules here are private implementation primitives — they are NOT
# re-exported from `komira_crypto/__init__.mojo`. Internal callers
# (`komira_crypto/hash.mojo` etc.) import them directly.
#
# # Encapsulation invariants
#
# Every primitive in this subdirectory MUST satisfy:
#   * ZERO UnsafePointer in public function signatures.
#   * ZERO wildcard origins in public signatures (FFI carve-out
#     wildcards are permitted only inside the FFI binding helper
#     fn at the file scope, with `# SAFETY:` documentation).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO ArcPointer sites.
#   * Every `external_call` or `inlined_assembly` site carries a
#     multi-line `# SAFETY:` comment documenting register / flag /
#     memory effect assumptions.
# =============================================================================

# SHA-256 block compression via AWS-LC FFI.
from .sha256_compress import sha256_compress_blocks

# Full SHA-2 family streaming via AWS-LC EVP_MD_CTX_*. Sha2Hasher[N] is the
# trait-conforming streaming wrapper; sha2_oneshot[N] is the one-shot free
# function.
from .sha256_ffi import (
    Sha2Hasher,
    Sha256Ffi,
    Sha384Ffi,
    Sha512Ffi,
    sha2_oneshot,
)

# Streaming HMAC over the SHA-2 family.
from .hmac_ffi import (
    HmacFfiCtx,
    HmacSha256Ffi,
    HmacSha384Ffi,
    HmacSha512Ffi,
    hmac_oneshot,
)

# RFC 5869 HKDF over the SHA-2 family.
from .hkdf_ffi import hkdf_extract_ffi, hkdf_expand_ffi

# RAND_bytes, the entropy source under SystemEntropy + ChaCha20Drbg.
from .rng_ffi import rand_bytes_ffi

# RSA-SHA256 PKCS#1 v1.5 signing (e.g. a GCS OAuth2 service-account JWT).
from .rsa_sign_ffi import rsa_sha256_sign_ffi

# AES-GCM via AWS-LC EVP_AEAD FFI.
from .aes_gcm_ffi import AesGcmCtx

# ChaCha20-Poly1305 via AWS-LC EVP_AEAD FFI. Same opaque-handle pattern as
# AesGcmCtx; the only FFI symbol difference is the EVP_aead_chacha20_poly1305
# method selector (EVP_AEAD_CTX_{new,seal,open,free} are shared with
# AES-GCM).
from .chacha20_poly1305_ffi import ChaCha20Poly1305Ctx

# X25519 scalar mult via AWS-LC FFI. Bare `X25519` symbol (stateless; no
# opaque-handle lifecycle).
from .x25519_ffi import x25519_scalarmult

# ECDSA-P256 sign / verify / pubkey-derive via AWS-LC FFI. Uses the
# low-level ECDSA_SIG + EC_KEY + explicit-nonce sign API
# (ECDSA_sign_with_nonce_and_leak_private_key_for_testing) to preserve
# RFC 6979 §A.2.5 byte-identical deterministic-k output.
from .p256_ffi import (
    p256_sign_with_nonce,
    p256_verify,
    p256_pubkey_from_priv,
)

# RSA-PSS verify via AWS-LC FFI. Uses the high-level RSA_verify_pss_mgf1
# entry point — a single FFI call handles modexp + EMSA-PSS-DECODE + MGF1 +
# salt-length check + hash compare. Per-call alloc of RSA + 2x BIGNUM
# handles (modulus + exponent) inside try/finally; same shape as p256_ffi's
# ECDSA_SIG + EC_KEY + explicit-nonce sign pattern.
from .rsa_ffi import (
    rsa_pss_verify_ffi,
    MD_SHA256,
    MD_SHA384,
    MD_SHA512,
)

# ECDSA-P384 sign / verify / pubkey-derive via AWS-LC FFI. The P-256
# binding with NID_secp384r1 + 48-byte field/scalar sizes + SHA-384 digests
# + 97-byte uncompressed pubkey. Same symbol set as p256_ffi (EC_KEY_* /
# ECDSA_SIG_* / BN_* / EC_POINT_* /
# ECDSA_sign_with_nonce_and_leak_private_key_for_testing). Needed to
# verify chains from CAs that issue P-384 leaves (USERTrust ECC, ISRG Root
# X2, etc.).
from .p384_ffi import (
    p384_sign_with_nonce,
    p384_verify,
    p384_pubkey_from_priv,
)

# Ed25519 sign / verify / pubkey-derive / keypair-generate via AWS-LC FFI.
# Stateless (no opaque handle), no per-call alloc, no curve-param fetching.
# 4 free AWS-LC symbols: ED25519_sign / ED25519_verify / ED25519_keypair /
# ED25519_keypair_from_seed. Mirrors the x25519_ffi.mojo pattern. Used for
# SSH key authentication and for chains from the CAs that use Ed25519.
from .ed25519_ffi import (
    ed25519_sign_from_seed,
    ed25519_verify,
    ed25519_pubkey_from_seed,
    ed25519_keypair_generate,
)
