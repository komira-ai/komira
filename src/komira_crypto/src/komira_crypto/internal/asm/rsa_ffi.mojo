# =============================================================================
# komira_crypto/internal/asm/rsa_ffi.mojo
# =============================================================================
#
# RSA-PSS verify — FFI wrapper to AWS-LC's RSA + EVP_MD + BIGNUM symbols
# (libcrypto.a; vendored from BoringSSL / OpenSSL via AWS-LC; Apache 2.0 /
# OpenSSL dual licensed).
#
# # Why this exists
#
# A pure-Mojo RSA-PSS verify (InlineArray-backed schoolbook bigint mul +
# bit-by-bit shift-and-subtract reduction + square-and-multiply modexp on
# the PUBLIC exponent + EMSA-PSS-VERIFY + MGF1 + I2OSP4) is correct per
# RFC 8017 §8.1.2 + §9.1.2 but orders of magnitude slower than AWS-LC's
# hand-tuned bignum implementation. This file delegates the entire PSS
# verify body to AWS-LC's RSA_verify_pss_mgf1 (which does modexp +
# EMSA-PSS-DECODE + MGF1 + salt-length check + hash compare all in one
# FFI call).
#
# # Approach: RSA_verify_pss_mgf1 (high-level; Approach C)
#
# Three approaches considered:
#   A. EVP_PKEY_verify — REJECTED: 7-8 alloc/free pairs per call + multi-
#      step EVP_PKEY_CTX init dance for zero verify-side benefit.
#   B. BN_mod_exp_mont + retain a Mojo EMSA-PSS-VERIFY + mgf1 — REJECTED:
#      keeps ~250 LOC of EMSA + MGF1 internals in Mojo for no performance
#      benefit.
#   C. RSA_verify_pss_mgf1 (high-level; entire PSS body in AWS-LC) —
#      CHOSEN. One FFI call; a strict superset of the RFC 8017 §9.1.2
#      verify body.
#
# # Symbols used (verified via nm libcrypto.a)
#
# # Symbols used (verified via nm libcrypto.a)
#
#   * RSA_new() -> RSA*
#   * RSA_free(RSA*) — no-op on NULL
#   * RSA_set0_key(rsa, n, e, d=NULL) -> int — TAKES OWNERSHIP of n + e
#   * RSA_verify_pss_mgf1(rsa, hash, hlen, md, mgf1_md, salt_len, sig, slen) -> int
#   * EVP_sha256() -> const EVP_MD*  (singleton; MUST NOT be freed)
#   * EVP_sha384() -> const EVP_MD*
#   * EVP_sha512() -> const EVP_MD*
#   * BN_new() / BN_free() — no-op on NULL
#   * BN_bin2bn(in, len, ret=NULL) -> BIGNUM*
#
# # Architecture: per-call alloc OK; RSA verify body dominates
#
# RSA-2048 verify costs ~0.5-2 ms (modexp dominates); RSA-4096 ~5-15 ms.
# Per-call RSA + 2x BIGNUM allocations: ~1-5us combined. The alloc
# overhead is <0.1% of per-op cost — negligible. No opaque-handle-CTX
# struct wrapper (unlike AesGcmCtx); simpler 1-fn API.
#
# # Encapsulation discipline
#
# Public API:
#   * 1 free function (rsa_pss_verify_ffi). Takes Span[UInt8, _] +
#     scalar args. ZERO UnsafePointer in public signatures. Non-raising
#     (returns Bool); matches public rsa_pss_verify[N_LIMBS, H] contract.
#
# Internal FFI:
#   * `_span_ptr_mut` helper coerces Span[UInt8, _] to MutExternalOrigin
#     pointer (mirror of `p256_ffi.mojo:_span_ptr_mut`).
#   * AWS-LC opaque handles (RSA*, BIGNUM*, EVP_MD*) held as
#     _FfiHandle — the FFI-POD
#     opaque-handle carve-out. Same shape as
#     AesGcmCtx._ctx / p256_ffi's handles.
#   * NULL sentinels constructed via `_ffi_null()` (canonical pattern;
#     same as p256_ffi.mojo).
#   * Per-call try/finally cleanup: each opaque handle is freed in the
#     finally block (idempotent, NULL-safe). RSA_set0_key TAKES OWNERSHIP
#     of bn_n + bn_e, so we track `rsa_owns_ne` flag to skip BN_free.
#   * ZERO `take_pointee`.
#   * ZERO ArcPointer.
#   * Every external_call site carries a multi-line `# SAFETY:` comment.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# -----------------------------------------------------------------------------
# The package's FFI origin (FFI-BOUNDARY).
#
# Mojo 1.0.0b2 removed the `UnsafePointer[T]()` null constructor and
# `Boolable`/`__bool__` (non-null-by-design; see
# the Mojo non-null-pointer proposal). A wildcard origin such as
# `MutExternalOrigin` is banned; this uses `StaticConstantOrigin`,
# a CONCRETE (non-wildcard) origin valid for the FFI ABI boundary whose
# lifetime is not expressible in Mojo's origin system. Opaque AWS-LC heap
# handles are passed BY VALUE to `external_call` and never written through
# Mojo-side, so an immutable static origin is sound. Data-buffer pointers
# (Span/InlineArray/scalar out-params) carry the same origin; the SAFETY
# contract is that the caller holds the buffer's real origin in scope across
# the synchronous external_call (AWS-LC retains no pointer past the call).
# -----------------------------------------------------------------------------
comptime _FFI_ORIGIN = ImmStaticOrigin
comptime _FfiHandle = UnsafePointer[NoneType, _FFI_ORIGIN]
comptime _FfiByte = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def _ffi_null() -> _FfiHandle:
    """A raw NULL opaque-handle (stands in for the removed `UnsafePointer[T]()`
    null ctor) for pre-declared-then-reassigned handle locals and explicit
    C-NULL arguments.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (the Mojo non-null-pointer proposal), and `None`
    # is the all-zero (NULL) bit pattern. We reinterpret an `Optional`-None
    # slot to obtain a raw NULL handle WITHOUT the removed null ctor and
    # WITHOUT the banned `unsafe_from_address=Int(0)`. Downstream sites
    # detect NULL via `Int(h) == 0` and AWS-LC free fns are NULL-safe.
    """
    var none: Optional[_FfiHandle] = None
    return UnsafePointer(to=none).bitcast[_FfiHandle]()[]



# -----------------------------------------------------------------------------
# Hash kind enum — maps to AWS-LC's EVP_sha{256,384,512} singleton getters.
#
# Non-parametric (avoids exposing EVP_MD* opaque type at the FFI module
# boundary). The public wrapper rsa_pss_verify[N_LIMBS, H] picks the
# right md_kind via comptime branching on H.
# -----------------------------------------------------------------------------
comptime MD_SHA256: Int32 = 0
comptime MD_SHA384: Int32 = 1
comptime MD_SHA512: Int32 = 2


# -----------------------------------------------------------------------------
# Coercion helper — Span -> MutExternalOrigin ptr for FFI.
#
# Mirror of `p256_ffi.mojo:_span_ptr_mut`. The MutExternalOrigin cast is
# the FFI-BOUNDARY contract: the resulting pointer's Mojo-side lifetime
# is erased; aliasing inference is suppressed. AWS-LC reads the bytes
# synchronously and retains no pointer past the call.
# -----------------------------------------------------------------------------


@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce Span[UInt8, _] to MutExternalOrigin ptr for FFI consumption.

    # SAFETY: caller MUST hold the Span's origin (and the underlying
    # buffer it borrows from) in scope across the external_call site.
    # AWS-LC's RSA / BN FFI retains no pointer past the synchronous call.
    # Same SAFETY contract as `_span_ptr_mut` in `p256_ffi.mojo`.
    """
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


# -----------------------------------------------------------------------------
# Low-level FFI helpers
# -----------------------------------------------------------------------------


@always_inline
def _rsa_new() -> _FfiHandle:
    """RSA_new() — heap-alloc empty RSA struct (no key material yet).

    # SAFETY: AWS-LC allocates a fresh RSA*. Caller owns until RSA_free.
    # Returns NULL on OOM (caller MUST check via `Int(ptr) != 0`).
    """
    return external_call[
        "komira_awslc_RSA_new",
        _FfiHandle,
    ]()


@always_inline
def _rsa_free(rsa: _FfiHandle):
    """RSA_free — no-op on NULL.

    # SAFETY: rsa must be a valid RSA pointer from RSA_new or NULL.
    # AWS-LC tolerates NULL. Frees any internal BIGNUMs the rsa owns
    # (via RSA_set0_key).
    """
    if Int(rsa) != 0:
        external_call[
            "komira_awslc_RSA_free", NoneType,
            _FfiHandle,
        ](rsa)


@always_inline
def _bn_free(bn: _FfiHandle):
    """BN_free — no-op on NULL.

    # SAFETY: bn must be a valid BIGNUM pointer or NULL.
    """
    if Int(bn) != 0:  # cov: unreachable called only when RSA_set0_key did not take n and e, which happens only after an allocation failure
        external_call[
            "komira_awslc_BN_free", NoneType,
            _FfiHandle,
        ](bn)  # cov: unreachable see the line above


@always_inline
def _bn_bin2bn_from_span(
    src: Span[UInt8, _],
) -> _FfiHandle:
    """BN_bin2bn(src, len(src), NULL) — alloc fresh BIGNUM from BE bytes.

    Returns NULL on OOM (caller MUST check via `Int(ptr) != 0`).

    # SAFETY: AWS-LC reads `len(src)` bytes from src as big-endian and
    # returns a heap-allocated BIGNUM. Returns NULL on OOM. The 3rd arg
    # (ret) is NULL — AWS-LC ABI documented to allocate a fresh BIGNUM
    # when ret is NULL.
    """
    var src_ptr = _span_ptr_mut(src)
    # NULL sentinel via _ffi_null()
    # (canonical pattern; same shape as p256_ffi.mojo).
    var ret_null = _ffi_null()
    return external_call[
        "komira_awslc_BN_bin2bn",
        _FfiHandle,
        _FfiByte,   # in
        UInt,                                       # len
        _FfiHandle, # ret (NULL = alloc fresh)
    ](src_ptr, UInt(len(src)), ret_null)


@always_inline
def _bn_new_from_u64(v: UInt64) -> _FfiHandle:
    """Allocate a fresh BIGNUM holding the UInt64 `v` (as BE bytes).

    Used to encode the public exponent e (typically 65537) for
    RSA_set0_key.

    # SAFETY: thin wrapper over BN_bin2bn over 8 BE bytes derived from v.
    # AWS-LC reads exactly 8 bytes synchronously. Returns NULL on OOM.
    """
    var be = Array[UInt8, 8](fill=UInt8(0))
    be[0] = UInt8((v >> UInt64(56)) & UInt64(0xFF))
    be[1] = UInt8((v >> UInt64(48)) & UInt64(0xFF))
    be[2] = UInt8((v >> UInt64(40)) & UInt64(0xFF))
    be[3] = UInt8((v >> UInt64(32)) & UInt64(0xFF))
    be[4] = UInt8((v >> UInt64(24)) & UInt64(0xFF))
    be[5] = UInt8((v >> UInt64(16)) & UInt64(0xFF))
    be[6] = UInt8((v >> UInt64(8)) & UInt64(0xFF))
    be[7] = UInt8(v & UInt64(0xFF))
    return _bn_bin2bn_from_span(Span[UInt8, origin_of(be)](be))


@always_inline
def _evp_md_for_kind(
    md_kind: Int32,
) -> _FfiHandle:
    """Return the EVP_MD* singleton for the given hash kind.

    # SAFETY: AWS-LC's EVP_sha{256,384,512}() return const singleton
    # pointers; MUST NOT be freed. Returned ptr is valid for process
    # lifetime. Returns the canonical zero (NULL ptr) for an unknown
    # md_kind — caller MUST validate before passing in.
    """
    if md_kind == MD_SHA256:
        return external_call[
            "komira_awslc_EVP_sha256",
            _FfiHandle,
        ]()
    if md_kind == MD_SHA384:
        return external_call[
            "komira_awslc_EVP_sha384",
            _FfiHandle,
        ]()
    if md_kind == MD_SHA512:
        return external_call[
            "komira_awslc_EVP_sha512",
            _FfiHandle,
        ]()
    return _ffi_null()  # cov: unreachable the only caller, rsa_pss_verify_ffi, checks md_kind at entry


# -----------------------------------------------------------------------------
# Public API — single free function
# -----------------------------------------------------------------------------


def rsa_pss_verify_ffi(
    n_be: Span[UInt8, _],
    e_value: UInt64,
    digest: Span[UInt8, _],
    md_kind: Int32,
    salt_len: Int32,
    sig: Span[UInt8, _],
) -> Bool:
    """RSA-PSS verify via AWS-LC RSA_verify_pss_mgf1.

    Non-raising; returns False on any failure (OOM / invalid signature /
    invalid input / md_kind out of range).

    Args:
        n_be: RSA modulus as big-endian bytes. Length is the modulus
            byte-length (256 for 2048-bit, 384 for 3072-bit, 512 for
            4096-bit).
        e_value: Public exponent as UInt64 (typically 65537 = 0x10001).
        digest: Pre-hashed message (32 bytes for SHA-256, 48 for SHA-384,
            64 for SHA-512).
        md_kind: MD_SHA256 / MD_SHA384 / MD_SHA512 (Int32 enum).
        salt_len: Expected salt length in bytes (typically equal to
            digest length per the TLS 1.3 / Mozilla cert profile). AWS-LC
            also accepts -1 (auto-detect) and -2 (recover) but we pass
            the explicit length per our public API contract.
        sig: Signature bytes. Length MUST equal len(n_be) (RFC 8017 §8.1.2
            step 1); AWS-LC enforces this internally.

    Returns:
        True iff signature is a valid RSA-PSS signature of digest under
        (n_be, e_value), with the given salt_len and MD.
    """
    # Pre-check md_kind to avoid calling AWS-LC with NULL EVP_MD*.
    if md_kind != MD_SHA256 and md_kind != MD_SHA384 and md_kind != MD_SHA512:
        return False
    # Pre-check digest length matches md_kind (defensive; AWS-LC also rejects).
    if md_kind == MD_SHA256 and len(digest) != 32:
        return False
    if md_kind == MD_SHA384 and len(digest) != 48:
        return False
    if md_kind == MD_SHA512 and len(digest) != 64:
        return False
    # Pre-check sig length equals modulus length (RFC 8017 §8.1.2 step 1).
    if len(sig) != len(n_be):
        return False
    # n must be non-empty.
    if len(n_be) == 0:
        return False

    var rsa = _rsa_new()
    var bn_n = _ffi_null()
    var bn_e = _ffi_null()
    var ok: Bool
    var rsa_owns_ne = False  # set true once RSA_set0_key takes ownership
    try:
        if Int(rsa) == 0:
            return False  # cov: unreachable an allocation failure

        bn_n = _bn_bin2bn_from_span(n_be)
        if Int(bn_n) == 0:
            return False  # cov: unreachable an allocation failure
        bn_e = _bn_new_from_u64(e_value)
        if Int(bn_e) == 0:
            return False  # cov: unreachable an allocation failure

        # SAFETY: RSA_set0_key(rsa, n, e, d) TAKES OWNERSHIP of n + e
        # on success (returns 1). On failure (returns 0) ownership stays
        # with the caller. d = NULL (no private key for verify path).
        var d_null = _ffi_null()
        var rc_set = external_call[
            "komira_awslc_RSA_set0_key", Int32,
            _FfiHandle,  # rsa
            _FfiHandle,  # n
            _FfiHandle,  # e
            _FfiHandle,  # d (NULL)
        ](rsa, bn_n, bn_e, d_null)
        if rc_set != 1:
            return False  # cov: unreachable RSA_set0_key fails only on a NULL n or e, refused above
        rsa_owns_ne = True

        # SAFETY: EVP_sha{256,384,512}() return const singleton EVP_MD*
        # pointers. MUST NOT be freed.
        var md_ptr = _evp_md_for_kind(md_kind)
        if Int(md_ptr) == 0:
            return False  # cov: unreachable md_kind was checked at entry, so the digest is never NULL
        # mgf1_md = NULL means "use the same hash as md" — universal
        # cert-chain convention. Our existing in-tree code matches this
        # (MGF1 instantiated with the same H: Hash trait param).
        var mgf1_md_null = _ffi_null()

        # SAFETY: RSA_verify_pss_mgf1 reads len(digest) bytes from
        # digest_ptr (the pre-hashed message), len(sig) bytes from
        # sig_ptr, and the modulus + exponent stored in rsa. Performs
        # RFC 8017 §8.1.2 verify (modexp via internal Montgomery
        # arithmetic + EMSA-PSS-DECODE + MGF1 + salt-length check +
        # hash compare). Returns 1 on valid, 0 on invalid, -1 on
        # internal error. AWS-LC retains no pointer past the call.
        var digest_ptr = _span_ptr_mut(digest)
        var sig_ptr = _span_ptr_mut(sig)
        var rc_v = external_call[
            "komira_awslc_RSA_verify_pss_mgf1", Int32,
            _FfiHandle,  # rsa
            _FfiByte,     # hash (digest)
            UInt,                                         # hash_len
            _FfiHandle,  # md (EVP_MD*)
            _FfiHandle,  # mgf1_md (NULL = same as md)
            Int32,                                        # salt_len
            _FfiByte,     # sig
            UInt,                                         # sig_len
        ](
            rsa, digest_ptr, UInt(len(digest)), md_ptr, mgf1_md_null,
            salt_len, sig_ptr, UInt(len(sig)),
        )
        ok = (rc_v == Int32(1))
    finally:
        # SAFETY: RSA_free frees rsa + its internal n/e BIGNUMs if rsa
        # owns them (via successful RSA_set0_key). If set0 failed,
        # bn_n + bn_e ownership stayed with us — free them ourselves.
        # _rsa_free and _bn_free are no-ops on NULL.
        _rsa_free(rsa)
        if not rsa_owns_ne:
            _bn_free(bn_e)  # cov: unreachable n and e are unowned only after an allocation failure
            _bn_free(bn_n)  # cov: unreachable see the line above
    return ok


# =============================================================================
# RSASSA-PKCS1-v1_5 verify (RFC 8017 §8.2.2) — the RS256 half.
#
# ★ WHY A SECOND VERIFY FUNCTION AND NOT A `padding` PARAMETER ON THE FIRST.
# PSS and PKCS#1 v1.5 are DIFFERENT signature schemes with different encodings
# and different failure modes; AWS-LC exposes them as two symbols
# (`RSA_verify_pss_mgf1` / `RSA_verify`) precisely because neither is a mode of
# the other. A single "verify with the padding you're told" entry point is one
# refactor away from taking the padding from an attacker-supplied JWS header,
# which is the RS256/PS256 shape of the classic algorithm-confusion break. Two
# functions, each naming its scheme, cannot be dispatched into by accident.
#
# WHAT THIS IS FOR: verifying a THIRD-PARTY platform attestation (a Google
# metadata-server ID token is RS256 per RFC 7518 §3.3). It is called by
# komira_jose's RS256 `JwsVerifier`, which is pinned to that one algorithm, so
# a verifier pinned to another algorithm never reaches it.
#
# SYMBOL (BoringSSL / AWS-LC v1.39.0 `rsa.h`):
#   int RSA_verify(int hash_nid, const uint8_t *digest, size_t digest_len,
#                  const uint8_t *sig, size_t sig_len, RSA *rsa);
# It takes the DIGEST (not the message) — the same shape as
# `RSA_verify_pss_mgf1` above — and performs the strict RFC 8017 §9.2 check:
# it CONSTRUCTS the expected `DigestInfo` encoding and compares, rather than
# parsing the recovered block (the parse-then-trust shape is what Bleichenbacher
# e=3 forgeries exploit).
# =============================================================================

# `NID_sha256` from OpenSSL/BoringSSL `obj_mac.h`. This is an ABI constant fixed
# by the OID registry entry for id-sha256 (2.16.840.1.101.3.4.2.1) and shared by
# every OpenSSL-lineage library; it has never changed value.
#
# ⚠ IT IS NOT TAKEN ON TRUST. A wrong NID here does not mis-verify — it makes
# `RSA_verify` build a DigestInfo prefix that no real signer emits, so EVERY
# signature fails. `test_rsa_pkcs1_verify.mojo` verifies a signature produced by
# an INDEPENDENT implementation (the RFC 7515 A.2 published vector, and OpenSSL
# via python-cryptography), which is exactly the falsifier for this constant.
comptime NID_SHA256: Int32 = 672


def rsa_pkcs1_sha256_verify_ffi(
    n_be: Span[UInt8, _],
    e_value: UInt64,
    digest: Span[UInt8, _],
    sig: Span[UInt8, _],
) -> Bool:
    """RSASSA-PKCS1-v1_5-SHA-256 verify via AWS-LC `RSA_verify`.

    Non-raising; returns False on any failure (OOM / invalid signature /
    malformed input). This is the RFC 7518 §3.3 **RS256** verification
    primitive.

    Args:
        n_be: RSA modulus as big-endian bytes (256 for 2048-bit, 384 for
            3072-bit, 512 for 4096-bit). Caller-owned.
        e_value: Public exponent as UInt64 (typically 65537 = 0x10001).
        digest: The SHA-256 digest of the signed message — exactly 32 bytes.
        sig: Signature bytes. Length MUST equal `len(n_be)` (RFC 8017 §8.2.2
            step 1); checked here as well as inside AWS-LC.

    Returns:
        True iff `sig` is a valid RSASSA-PKCS1-v1_5-SHA-256 signature over
        `digest` under `(n_be, e_value)`.
    """
    # SHA-256 digests are 32 bytes. A caller passing anything else is a
    # programming error, not a verification failure — but this path is fed by
    # attacker-controlled documents, so it CUTS rather than trusting.
    if len(digest) != 32:
        return False
    # RFC 8017 §8.2.2 step 1: signature length MUST equal modulus length.
    if len(sig) != len(n_be):
        return False
    if len(n_be) == 0:
        return False

    var rsa = _rsa_new()
    var bn_n = _ffi_null()
    var bn_e = _ffi_null()
    var ok: Bool
    var rsa_owns_ne = False  # set true once RSA_set0_key takes ownership
    try:
        if Int(rsa) == 0:
            return False  # cov: unreachable an allocation failure

        bn_n = _bn_bin2bn_from_span(n_be)
        if Int(bn_n) == 0:
            return False  # cov: unreachable an allocation failure
        bn_e = _bn_new_from_u64(e_value)
        if Int(bn_e) == 0:
            return False  # cov: unreachable an allocation failure

        # SAFETY: RSA_set0_key(rsa, n, e, d) TAKES OWNERSHIP of n + e on
        # success (returns 1). On failure (returns 0) ownership stays with the
        # caller. d = NULL (no private key on the verify path).
        var d_null = _ffi_null()
        var rc_set = external_call[
            "komira_awslc_RSA_set0_key", Int32,
            _FfiHandle,  # rsa
            _FfiHandle,  # n
            _FfiHandle,  # e
            _FfiHandle,  # d (NULL)
        ](rsa, bn_n, bn_e, d_null)
        if rc_set != 1:
            return False  # cov: unreachable RSA_set0_key fails only on a NULL n or e, refused above
        rsa_owns_ne = True

        # SAFETY: RSA_verify reads len(digest) bytes from digest_ptr and
        # len(sig) bytes from sig_ptr, plus the modulus + exponent stored in
        # rsa. Returns 1 on a valid signature, 0 otherwise. AWS-LC retains no
        # pointer past the synchronous call.
        var digest_ptr = _span_ptr_mut(digest)
        var sig_ptr = _span_ptr_mut(sig)
        var rc_v = external_call[
            "komira_awslc_RSA_verify", Int32,
            Int32,      # hash_nid
            _FfiByte,   # digest
            UInt,       # digest_len
            _FfiByte,   # sig
            UInt,       # sig_len
            _FfiHandle, # rsa
        ](
            NID_SHA256, digest_ptr, UInt(len(digest)),
            sig_ptr, UInt(len(sig)), rsa,
        )
        ok = (rc_v == Int32(1))
    finally:
        # SAFETY: RSA_free frees rsa + its internal n/e BIGNUMs if rsa owns them
        # (via a successful RSA_set0_key). If set0 failed, bn_n + bn_e ownership
        # stayed with us — free them ourselves. Both frees are NULL-safe.
        _rsa_free(rsa)
        if not rsa_owns_ne:
            _bn_free(bn_e)  # cov: unreachable n and e are unowned only after an allocation failure
            _bn_free(bn_n)  # cov: unreachable see the line above
    return ok
