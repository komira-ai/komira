"""`komira_crypto` — cryptographic primitives for Mojo.

Hashes, MACs, KDFs, AEADs, key agreement, signatures, a health-tested
entropy source and DRBG, hex encoding, and X.509 chain validation. The
heavy primitives call AWS-LC's `libcrypto` through `internal/asm/`; the
traits, the hex codec and the DER / X.509 layer are Mojo. Base64, base64url
and base32 live in `komira_encoding`; this package uses them and does not
re-export them.

Layout:
  - traits.mojo          Hash / Aead / KeySchedule trait surface
  - hash.mojo            Sha256 / Sha384 / Sha512
                         (+ Sha1: a witness digest,
                          NOT a `Hash` conformer)
  - hmac.mojo            Hmac[H: Hash]
  - hkdf.mojo            Hkdf[H: Hash]
  - aead.mojo            AesGcm128 / AesGcm256 /
                         ChaCha20Poly1305
  - x25519.mojo          single + batched 4-way
  - ecdh_p256.mojo       P-256 ECDH shared secret
  - ecdsa_p256.mojo      sign + verify
  - rsa.mojo             RSA-SHA256 sign (PKCS#8 DER) + RS256 verify
  - rsa_pem_key.mojo     PEM RSA `PRIVATE KEY` -> the PKCS#8 DER rsa.mojo signs
  - rsa_pss.mojo         verify-only
  - rng.mojo             SystemEntropy + ChaCha20Drbg
  - cert/                X.509 + ChainValidator
  - zeroize.mojo         no-elide memset
  - internal/asm/        FFI bridges into AWS-LC

Encapsulation discipline:
  * ZERO UnsafePointer in any public trait signature.
  * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
  * ZERO `unsafe_from_address`.
  * Span[UInt8, _] over open origin is the cross-module byte-buffer surface.
  * Internal SIMD bodies use UnsafePointer with concrete origin + # SAFETY:.
"""

from .traits import (
    Aead,
    Hash,
    KeySchedule,
)

# Streaming Sha256, a conformer of the Hash trait. The one-shot
# `sha256(data)` free function (re-exported below from `.sha256`) is a thin
# wrapper around it, not a parallel implementation.
from .hash import Sha256

# Streaming Sha384 + Sha512 conformers of Hash (FIPS 180-4 §6.3 + §6.4).
from .hash import Sha384, Sha512

# SHA-1 — a WITNESS digest (npm `dist.shasum`), deliberately NOT a `Hash`
# conformer, so no HMAC / HKDF / signature / transcript can be built over it.
# Streaming `Sha1` + one-shot `sha1`, both over AWS-LC.
from .hash import Sha1, sha1

# One-shot BLAKE2b-256 over AWS-LC: a package index's `blake2_256_digest`.
from .hash import blake2b_256

from .zeroize import (
    zeroize_inline_array,
    zeroize_inline_array_u32,
    zeroize_inline_array_u64,
    zeroize_list,
)

# Streaming Hmac[H: Hash]. The one-shot `hmac_sha256(key, data)` free
# function (re-exported below from `.hmac`) is a thin wrapper around
# `Hmac[Sha256]`.
from .hmac_streaming import Hmac

# Stateless Hkdf[H: Hash]: RFC 5869 HKDF-Extract + HKDF-Expand, plus the
# TLS 1.3 (RFC 8446 §7.1) HKDF-Expand-Label and Derive-Secret. A TLS 1.3 key
# schedule instantiates it with Sha256 or Sha384 depending on the negotiated
# ciphersuite (RFC 8446 §B.4).
from .hkdf import Hkdf

# AES-128-GCM + AES-256-GCM conformers of the Aead trait. The round-key
# arrays hold 11 / 15 round keys (44 / 60 words), with the initial
# AddRoundKey(K0) applied before the first round (FIPS 197 §5.1).
# SEQUENCE_LIMIT = 1 << 24 (RFC 8446 §5.5).
from .aead import constant_time_eq_n
from .aes_gcm import AesGcm128, AesGcm256

# ChaCha20-Poly1305 AEAD (RFC 8439 §2.8), routed through AWS-LC's
# EVP_aead_chacha20_poly1305 via internal/asm/chacha20_poly1305_ffi.mojo.
# There is no standalone ChaCha20 or Poly1305 export: the AEAD composition
# is the only supported use. SEQUENCE_LIMIT = 1 << 48 (RFC 8446 §5.5 +
# [AEAD-LIMITS]); a record layer enforces it per record.
from .chacha20_poly1305 import ChaCha20Poly1305

# X25519 (RFC 7748 §5, Montgomery ladder over Curve25519): single-key
# `x25519(scalar, u)` and the base-point variant `x25519_base_mult(scalar)`
# for keypair generation.
from .x25519 import x25519, x25519_base_mult

# `x25519_4way(scalars, bases, out)` computes 4 independent X25519 with a
# lane-major 32-byte packing; its output is byte-identical to 4 scalar
# `x25519` calls.
from .x25519_simd import x25519_4way

# P-256 ECDH (SP 800-56A ECC CDH primitive; the ECDH step of RFC 8291 Web
# Push encryption): `p256_ecdh(priv, peer_pub_uncompressed)` returns the
# 32-byte x-coordinate of priv * peer and raises on an invalid key or point.
from .ecdh_p256 import p256_ecdh

# SHA-256 / HMAC-SHA256 / hex free functions consumed by request
# signing (SigV4, Azure Shared Key, GCS OAuth). These are the STABLE-CONTRACT
# public surface: a faster implementation can be swapped in behind the
# identical free-function signatures.
from .sha256 import sha256, sha256_string
from .hmac import hmac_sha256, hmac_sha256_string, constant_time_eq_32

# PBKDF2-HMAC-SHA256. SCRAM-SHA-256's `Hi` (SaltedPassword) is the dkLen==32
# convenience; the general dkLen form is reusable as a password-stretching
# KDF. Validated against the RFC 7677 §3 4096-iteration vector.
from .pbkdf2 import pbkdf2_hmac_sha256, pbkdf2_hmac_sha256_32
from .hex import hex_lower, hex_lower_array_32, hex_upper
from .rsa import rsa_sha256_sign, rsa_pkcs1_sha256_verify

# A PEM RSA `PRIVATE KEY` block -> the PKCS#8 DER `rsa_sha256_sign` takes. The
# armor comes off through komira_encoding.pem; PKCS#1 (`RSA PRIVATE KEY`) and
# encrypted keys are refused by name, and the DER is checked to be an RSA
# PrivateKeyInfo envelope. The RSAPrivateKey inside is left to AWS-LC.
from .rsa_pem_key import rsa_pkcs8_der_from_pem

# RSA-PSS verify-only (RFC 4055 / RFC 8017 §8.1.2 + §9.1.2), for certificate
# chain validation where an intermediate or root CA uses RSA-PSS. There is no
# RSA-PSS sign. Comptime-parametric on N_LIMBS (32 for 2048-bit; extends to
# 48 / 64 for 3072 / 4096) and on H: Hash. Verify needs no constant-time
# discipline: every input is public.
from .rsa_pss import RsaPublicKey, rsa_public_key_from_bytes, rsa_pss_verify

# ECDSA-P384 sign + verify (FIPS 186-4 §6.4 + RFC 6979 §A.2.6 deterministic
# k). The public API mirrors ecdsa_p256_*; curve arithmetic is delegated to
# AWS-LC via internal/asm/p384_ffi.mojo, while the RFC 6979 HMAC-DRBG over
# SHA-384 stays in Mojo for byte-identical §A.2.6 KAT compliance. Needed to
# verify chains from CAs that issue P-384 leaves (USERTrust ECC, ISRG Root
# X2, etc.); cert/chain.mojo dispatches ecdsa-with-SHA384
# (1.2.840.10045.4.3.3) here.
from .ecdsa_p384 import (
    ecdsa_p384_sign_deterministic,
    ecdsa_p384_sign_random,
    ecdsa_p384_verify,
    ecdsa_p384_generate_pubkey,
)

# Ed25519 sign + verify + pubkey-from-seed + keypair-generate (RFC 8032
# §5.1). Stateless: no opaque handle, no per-call allocation; mirrors the
# x25519 API shape. Used for SSH key authentication and for the CA roots
# that use Ed25519; cert/chain.mojo dispatches Ed25519 (1.3.101.112) here.
from .ed25519 import (
    ed25519_sign,
    ed25519_verify,
    ed25519_pubkey_from_seed,
    ed25519_keypair_generate,
)

# RNG primitives over AWS-LC's RAND_bytes (a NIST SP 800-90A DRBG seeded
# from getrandom / getentropy with SP 800-90B continuous health tests):
# SystemEntropy and ChaCha20Drbg (explicit-handle forms) + the
# system_entropy() free function.
from .rng import SystemEntropy, ChaCha20Drbg, system_entropy
