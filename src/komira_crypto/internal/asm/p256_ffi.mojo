# =============================================================================
# komira_crypto/internal/asm/p256_ffi.mojo
# =============================================================================
#
# ECDSA-P256 sign + verify + scalar mult — FFI wrapper to AWS-LC's
# hand-tuned P-256 implementation (libcrypto.a; vendored from BoringSSL /
# OpenSSL via AWS-LC; Apache 2.0 / OpenSSL dual licensed).
#
# # Why this exists
#
# A pure-Mojo P-256 (base field with Solinas reduction + scalar field with
# Barrett reduction + Jacobian-coordinate group ops + Montgomery ladder) is
# functionally correct (RFC 6979 §A.2.5 byte-identical KATs pass) but
# orders of magnitude slower than AWS-LC's hand-tuned P-256 path. This
# file delegates the curve arithmetic to AWS-LC while the RFC 6979
# deterministic-k generator stays in Mojo (over the FFI-backed
# Hmac[Sha256]).
#
# # Approach: ECDSA_SIG + EC_KEY low-level (Approach C)
#
# Three approaches considered:
#   A. EVP_DigestSign/Verify (highest-level) — REJECTED: cannot pass
#      explicit nonce, so RFC 6979 byte-identical output is impossible.
#   B. ECDSA_sign / ECDSA_verify (DER output) — REJECTED: DER encoding
#      overhead + no explicit-nonce variant.
#   C. ECDSA_SIG + EC_KEY + explicit-nonce sign — CHOSEN:
#      - ECDSA_sign_with_nonce_and_leak_private_key_for_testing accepts
#        a caller-supplied 32-byte BE nonce, enabling RFC 6979 byte-
#        identical output (the "leak" caveat is irrelevant for our use
#        case because RFC 6979's nonce is deterministically derivable
#        from (privkey, message) per the spec).
#      - ECDSA_do_verify takes an ECDSA_SIG built via ECDSA_SIG_set0.
#      - generate_pubkey via EC_POINT_mul with the curve generator.
#
# # Symbols used (verified via nm libcrypto.a)
#
#   * EC_KEY_new_by_curve_name(415=NID_X9_62_prime256v1) — heap-alloc EC_KEY
#   * EC_KEY_free
#   * EC_KEY_set_private_key(eckey, BN*)
#   * EC_KEY_set_public_key_affine_coordinates(eckey, x_BN*, y_BN*)
#   * EC_KEY_get0_group(eckey) — borrowed group ptr (do NOT free)
#   * EC_POINT_new(group) — heap-alloc point
#   * EC_POINT_free
#   * EC_POINT_mul(group, r, n, q, m, ctx) — r = n*G + m*q
#   * EC_POINT_point2oct(group, point, form=UNCOMPRESSED, buf, len, ctx)
#   * BN_new / BN_free / BN_bin2bn(in, len, ret=NULL) / BN_bn2binpad(bn, out, len)
#   * ECDSA_SIG_new / ECDSA_SIG_free
#   * ECDSA_SIG_get0_r(sig) -> const BIGNUM*  (borrowed; do NOT free)
#   * ECDSA_SIG_get0_s(sig) -> const BIGNUM*  (borrowed; do NOT free)
#   * ECDSA_SIG_set0(sig, r, s) — TAKES OWNERSHIP of r + s
#   * ECDSA_do_verify(digest, dlen, sig, eckey) -> int
#   * ECDSA_sign_with_nonce_and_leak_private_key_for_testing(...) -> ECDSA_SIG*
#
# # Architecture: per-call alloc OK; sign/verify dominate
#
# ECDSA-P256 sign costs ~100-200us; verify ~200-400us. Per-call EC_KEY +
# BN + ECDSA_SIG + EC_POINT allocations: ~1-5us combined. The alloc
# overhead is <2-3% of per-op cost — negligible. No opaque-handle-CTX
# struct wrapper (unlike AesGcmCtx); simpler 3-fn API.
#
# # Encapsulation discipline
#
# Public API:
#   * 3 free functions (p256_sign_with_nonce / p256_verify /
#     p256_pubkey_from_priv). Take Span[UInt8, _] + InlineArray
#     outputs. ZERO UnsafePointer in public signatures.
#
# Internal FFI:
#   * `_span_ptr_mut` helper coerces Span[UInt8, _] to the FFI byte
#     pointer (mirror of `aes_gcm_ffi.mojo:_span_ptr_mut`). Origin is the
#     concrete static FFI origin, NOT a wildcard.
#   * AWS-LC opaque handles (EC_KEY*, EC_POINT*, ECDSA_SIG*, BIGNUM*,
#     EC_GROUP*) held as _FfiHandle —
#     the FFI-POD opaque-handle carve-out.
#     Same shape as AesGcmCtx._ctx.
#   * NULL handles via `_ffi_null()` (raw NULL from an Optional-None
#     layout-compat slot; stands in for the removed `UnsafePointer[T]()`
#     null ctor). NEVER unsafe_from_address=Int(0).
#   * Per-call try/finally cleanup: each opaque handle is freed in the
#     finally block (idempotent, NULL-safe).
#   * ZERO `take_pointee`.
#   * ZERO ArcPointer.
#   * Every external_call site carries a multi-line `# SAFETY:` comment.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# -----------------------------------------------------------------------------
# The package's FFI origin (FFI-BOUNDARY).
#
# Mojo 1.0.0b2 removed the `UnsafePointer[T]()` null constructor and the
# `Boolable`/`__bool__` conversion (non-null-by-design; see
# the Mojo non-null-pointer proposal). A wildcard origin such as
# `MutExternalOrigin` is banned; this uses `StaticConstantOrigin`,
# a CONCRETE (non-wildcard) origin valid for the FFI ABI boundary whose
# lifetime is not expressible in Mojo's origin system. Opaque AWS-LC heap
# handles (EC_KEY*, BIGNUM*, ECDSA_SIG*, EC_POINT*) are passed BY VALUE to
# `external_call` and never written through Mojo-side, so an immutable
# static origin is sound. Data-buffer pointers (Span/InlineArray bytes) are
# coerced to the same origin in the `_*_ptr_ffi` helpers; the SAFETY
# contract is that the caller holds the buffer's real origin in scope across
# the synchronous external_call (AWS-LC retains no pointer past the call).
# -----------------------------------------------------------------------------
comptime _FFI_ORIGIN = ImmStaticOrigin
comptime _FfiHandle = UnsafePointer[NoneType, _FFI_ORIGIN]
comptime _FfiByte = UnsafePointer[UInt8, _FFI_ORIGIN]


@always_inline
def _ffi_null() -> _FfiHandle:
    """A raw NULL opaque-handle (replaces the removed `UnsafePointer[T]()`
    null ctor) for pre-declared-then-reassigned handle locals and explicit
    C-NULL arguments.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer (the Mojo non-null-pointer proposal), and `None`
    # is the all-zero (NULL) bit pattern. We reinterpret an `Optional`-None
    # slot to obtain a raw NULL handle WITHOUT the removed null ctor and
    # WITHOUT the banned `unsafe_from_address=Int(0)`. Downstream sites
    # detect NULL via `Int(h) == 0` and AWS-LC's free fns are NULL-safe.
    """
    var none: Optional[_FfiHandle] = None
    return UnsafePointer(to=none).bitcast[_FfiHandle]()[]


# -----------------------------------------------------------------------------
# Curve NID constant: NID_X9_62_prime256v1 = 415 per openssl/nid.h.
# -----------------------------------------------------------------------------
comptime NID_P256: Int = 415

# Point conversion form: UNCOMPRESSED = 4 per openssl/ec.h.
comptime POINT_CONVERSION_UNCOMPRESSED: Int = 4


# -----------------------------------------------------------------------------
# Coercion helpers — Span / InlineArray -> FFI byte ptr (_FFI_ORIGIN).
#
# Mirror of `aes_gcm_ffi.mojo:_span_ptr_mut`.
# The _FFI_ORIGIN
# (StaticConstantOrigin) is a CONCRETE origin, NOT a wildcard: the
# resulting pointer is handed to AWS-LC which reads/writes the bytes
# synchronously and retains no pointer past the call.
# -----------------------------------------------------------------------------


@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce Span[UInt8, _] to an FFI byte ptr (_FFI_ORIGIN).

    # SAFETY: caller MUST hold the Span's origin (and the underlying
    # buffer it borrows from) in scope across the external_call site.
    # AWS-LC's ECDSA/EC_KEY/BN FFI retains no pointer past the
    # synchronous call. The origin is erased to the concrete static FFI
    # origin (NOT a wildcard); the buffer is read/written only by AWS-LC
    # C code during the synchronous call.
    """
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


@always_inline
def _inline32_ptr_mut(
    mut a: Array[UInt8, 32],
) -> _FfiByte:
    """Coerce InlineArray[UInt8, 32] -> FFI byte ptr (_FFI_ORIGIN).

    # SAFETY: a is caller-owned local in this fn's scope (held in scope
    # across the external_call site). AWS-LC writes exactly the documented
    # number of bytes (BN_bn2binpad: 32).
    """
    return (
        UnsafePointer(to=a[0])
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


@always_inline
def _inline65_ptr_mut(
    mut a: Array[UInt8, 65],
) -> _FfiByte:
    """Coerce InlineArray[UInt8, 65] -> FFI byte ptr (_FFI_ORIGIN) (point2oct).

    # SAFETY: a is caller-owned local. AWS-LC's EC_POINT_point2oct writes
    # exactly `len` bytes (65 for uncompressed P-256 = format||x||y).
    """
    return (
        UnsafePointer(to=a[0])
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


# -----------------------------------------------------------------------------
# Low-level FFI helpers (raising on failure; cleanup is caller's
# responsibility via the explicit free pattern below).
# -----------------------------------------------------------------------------


@always_inline
def _ec_key_new() -> _FfiHandle:
    """EC_KEY_new_by_curve_name(NID_P256).

    Returns a heap-allocated EC_KEY for P-256, or NULL on OOM (caller MUST
    check via `Int(ptr) != 0`).

    # SAFETY: AWS-LC allocates a heap EC_KEY initialized for P-256.
    # Caller owns the pointer until EC_KEY_free is called.
    """
    return external_call[
        "komira_awslc_EC_KEY_new_by_curve_name",
        _FfiHandle,
        Int32,  # nid
    ](Int32(NID_P256))


@always_inline
def _ec_key_free(ptr: _FfiHandle):
    """EC_KEY_free — no-op on NULL.

    # SAFETY: ptr must be a valid EC_KEY pointer from EC_KEY_new_by_curve_name
    # or NULL. AWS-LC tolerates NULL.
    """
    if Int(ptr) != 0:
        external_call[
            "komira_awslc_EC_KEY_free", NoneType,
            _FfiHandle,
        ](ptr)


@always_inline
def _bn_free(ptr: _FfiHandle):
    """BN_free — no-op on NULL.

    # SAFETY: ptr must be a valid BIGNUM pointer or NULL.
    """
    if Int(ptr) != 0:
        external_call[
            "komira_awslc_BN_free", NoneType,
            _FfiHandle,
        ](ptr)


@always_inline
def _bn_bin2bn_from_span(
    src: Span[UInt8, _],
) -> _FfiHandle:
    """BN_bin2bn(src.unsafe_ptr(), len(src), NULL) — alloc fresh BIGNUM from BE bytes.

    Returns NULL on OOM (caller MUST check via `Int(ptr) != 0`).

    # SAFETY: AWS-LC reads `len(src)` bytes from src as big-endian and
    # returns a heap-allocated BIGNUM. Returns NULL on OOM.
    # The 3rd arg (ret) is NULL — AWS-LC ABI documented to allocate a
    # fresh BIGNUM when ret is NULL.
    """
    var src_ptr = _span_ptr_mut(src)
    # NULL sentinel via _ffi_null()
    # (canonical pattern).
    var ret_null = _ffi_null()
    return external_call[
        "komira_awslc_BN_bin2bn",
        _FfiHandle,
        _FfiByte,   # in
        UInt,                                       # len
        _FfiHandle, # ret (NULL = alloc fresh)
    ](src_ptr, UInt(len(src)), ret_null)


@always_inline
def _bn_bn2binpad_to_inline(
    bn: _FfiHandle,
    mut out: Array[UInt8, 32],
) -> Int32:
    """BN_bn2binpad(bn, out, 32) — write bn as 32 BE bytes with leading
    zero-pad. Returns 32 on success, -1 if bn doesn't fit.

    # SAFETY: bn must be a valid BIGNUM pointer; out must have ≥32 bytes
    # writable. AWS-LC writes exactly 32 bytes to out (or returns -1
    # without writing if bn's encoded length > 32).
    """
    var out_ptr = _inline32_ptr_mut(out)
    return external_call[
        "komira_awslc_BN_bn2binpad", Int32,
        _FfiHandle,  # bn
        _FfiByte,     # out
        Int32,                                        # len
    ](bn, out_ptr, Int32(32))


@always_inline
def _ec_key_get0_group(
    eckey: _FfiHandle,
) -> _FfiHandle:
    """EC_KEY_get0_group(eckey) -> borrowed EC_GROUP*.

    # SAFETY: returned ptr is borrowed from eckey; valid for eckey's
    # lifetime. MUST NOT be freed by caller.
    """
    return external_call[
        "komira_awslc_EC_KEY_get0_group",
        _FfiHandle,
        _FfiHandle,
    ](eckey)


# -----------------------------------------------------------------------------
# Public API — 3 free functions
# -----------------------------------------------------------------------------


def p256_sign_with_nonce(
    priv_be: Span[UInt8, _],
    digest: Span[UInt8, _],
    nonce_be: Span[UInt8, _],
    mut r_out: Array[UInt8, 32],
    mut s_out: Array[UInt8, 32],
) raises:
    """ECDSA-P256 sign with caller-supplied nonce.

    Args:
        priv_be: 32-byte big-endian private scalar (caller's responsibility
            for priv in [1, n-1]).
        digest: 32-byte SHA-256 digest of the message.
        nonce_be: 32-byte big-endian nonce k (caller's responsibility for
            k in [1, n-1]; for RFC 6979 deterministic-k, derived from
            HMAC-DRBG(priv, hash) per RFC 6979 §3.2).
        r_out: 32-byte output for the r component.
        s_out: 32-byte output for the s component.

    Calls AWS-LC's `ECDSA_sign_with_nonce_and_leak_private_key_for_testing`
    — accepts the explicit nonce per AWS-LC's docstring ("nonce interpreted
    as big-endian; must be reduced mod n and padded to BN_num_bytes(order)
    = 32 for P-256"), which RFC 6979 already guarantees.

    The "_for_testing" / "leak_private_key" name reflects that this fn
    leaks information about k. For RFC 6979 deterministic-k, k is already
    derivable from (priv, message) per spec — so the security model is
    identical to computing k inside AWS-LC.

    Raises:
        "p256_sign: invalid input size" if buffers wrong length.
        "p256_sign: OOM" if AWS-LC EC_KEY/BN allocation fails.
        "p256_sign: signing failed" if the AWS-LC call returns NULL.
    """
    if len(priv_be) != 32:
        raise Error("p256_sign: priv_be must be 32 bytes")
    if len(digest) != 32:
        raise Error("p256_sign: digest must be 32 bytes")
    if len(nonce_be) != 32:
        raise Error("p256_sign: nonce_be must be 32 bytes")

    var eckey = _ec_key_new()
    var priv_bn = _ffi_null()
    var sig = _ffi_null()
    # ⚠ FAILURE PATHS RAISE DIRECTLY FROM INSIDE THE `try` — do NOT convert
    # them back to a deferred `should_raise` flag checked after the block.
    # That shape is DEAD: a `return`
    # inside the `try` exits the FUNCTION, so the `if should_raise: raise`
    # after it was reachable only on the fall-through path where the flag
    # is False, so every AWS-LC failure would return SUCCESS with the caller's
    # out-buffers untouched (an all-zero signature). There is no `except`
    # clause here, only `finally` — so a `raise` runs the cleanup below and
    # then propagates, which is exactly what the deferred flag was trying
    # to emulate. (A "raise must not be inside the try" rule is
    # about try/EXCEPT swallowing the new Error;
    # it does not apply to a try/FINALLY.)
    try:
        if Int(eckey) == 0:
            raise Error("p256_sign: EC_KEY_new_by_curve_name OOM")  # cov: unreachable an allocation failure

        priv_bn = _bn_bin2bn_from_span(priv_be)
        if Int(priv_bn) == 0:
            raise Error("p256_sign: BN_bin2bn(priv) OOM")  # cov: unreachable an allocation failure

        # SAFETY: EC_KEY_set_private_key copies priv_bn into eckey;
        # priv_bn ownership stays with caller (must free after).
        # Returns 1 on success, 0 on invalid (e.g., out-of-range).
        var rc1 = external_call[
            "komira_awslc_EC_KEY_set_private_key", Int32,
            _FfiHandle,  # eckey
            _FfiHandle,  # priv (const BN*)
        ](eckey, priv_bn)
        if rc1 != 1:
            raise Error("p256_sign: EC_KEY_set_private_key failed")

        # SAFETY: ECDSA_sign_with_nonce_and_leak_private_key_for_testing
        # reads 32 bytes from digest_ptr (the message hash) and 32 bytes
        # from nonce_ptr (RFC 6979 k). Returns a heap-allocated ECDSA_SIG*
        # (NULL on failure). Caller owns the returned sig until free.
        var digest_ptr = _span_ptr_mut(digest)
        var nonce_ptr = _span_ptr_mut(nonce_be)
        sig = external_call[
            "komira_awslc_ECDSA_sign_with_nonce_and_leak_private_key_for_testing",
            _FfiHandle,
            _FfiByte,     # digest
            UInt,                                         # digest_len
            _FfiHandle,  # eckey
            _FfiByte,     # nonce
            UInt,                                         # nonce_len
        ](digest_ptr, UInt(32), eckey, nonce_ptr, UInt(32))
        if Int(sig) == 0:
            raise Error("p256_sign: ECDSA signing failed")

        # Extract r and s as 32 BE bytes.
        # ECDSA_SIG_get0_r/s return borrowed const BIGNUM*; sig owns them.
        # SAFETY: r_bn / s_bn are valid for sig's lifetime; MUST NOT be freed.
        var r_bn = external_call[
            "komira_awslc_ECDSA_SIG_get0_r",
            _FfiHandle,
            _FfiHandle,
        ](sig)
        var s_bn = external_call[
            "komira_awslc_ECDSA_SIG_get0_s",
            _FfiHandle,
            _FfiHandle,
        ](sig)
        var pad_r = _bn_bn2binpad_to_inline(r_bn, r_out)
        var pad_s = _bn_bn2binpad_to_inline(s_bn, s_out)
        if pad_r != Int32(32) or pad_s != Int32(32):
            raise Error("p256_sign: BN_bn2binpad encoding failed")  # cov: unreachable r and s are below n, so both always pad to the field width
    finally:
        # Cleanup all owned heap handles (in reverse alloc order).
        # SAFETY: ECDSA_SIG_free frees the sig + its internal r,s BIGNUMs
        # (sig-owned per ECDSA_SIG_set0/get0 semantics). BN_free +
        # EC_KEY_free are no-ops on NULL.
        if Int(sig) != 0:
            external_call[
                "komira_awslc_ECDSA_SIG_free", NoneType,
                _FfiHandle,
            ](sig)
        _bn_free(priv_bn)
        _ec_key_free(eckey)


def p256_verify(
    pub_xy_be: Span[UInt8, _],
    digest: Span[UInt8, _],
    sig_rs_be: Span[UInt8, _],
) -> Bool:
    """ECDSA-P256 verify. Non-raising; returns False on any failure.

    Args:
        pub_xy_be: 64 bytes (x || y) big-endian uncompressed public point
            (no leading 0x04 format byte; matches our public API).
        digest: 32-byte SHA-256 digest.
        sig_rs_be: 64 BE bytes (signature r || s, 32 bytes each).

    Returns:
        True iff the signature is valid for the (pubkey, digest) pair.
    """
    if len(pub_xy_be) != 64:
        return False
    if len(digest) != 32:
        return False
    if len(sig_rs_be) != 64:
        return False
    # Slice r + s halves from the single sig buffer (avoids the caller's
    # noalias inference flagging two distinct same-origin spans as
    # potentially-aliased; the slice is local to this fn body).
    var r_be = sig_rs_be[0:32]
    var s_be = sig_rs_be[32:64]

    var eckey = _ec_key_new()
    var x_bn = _ffi_null()
    var y_bn = _ffi_null()
    var r_bn = _ffi_null()
    var s_bn = _ffi_null()
    var sig = _ffi_null()
    var ok = False
    var sig_owns_rs = False  # ECDSA_SIG_set0 transferred ownership of r/s
    try:
        if Int(eckey) == 0:
            return False  # cov: unreachable an allocation failure

        # Decode pubkey x + y from BE bytes.
        x_bn = _bn_bin2bn_from_span(pub_xy_be[0:32])
        y_bn = _bn_bin2bn_from_span(pub_xy_be[32:64])
        if Int(x_bn) == 0 or Int(y_bn) == 0:
            return False  # cov: unreachable an allocation failure

        # Set public key via affine coordinates (avoids EC_POINT alloc).
        # SAFETY: EC_KEY_set_public_key_affine_coordinates internally
        # builds an EC_POINT from (x, y), validates on-curve, stores in
        # eckey. Returns 0 if (x, y) is off-curve.
        var rc_pk = external_call[
            "komira_awslc_EC_KEY_set_public_key_affine_coordinates", Int32,
            _FfiHandle,  # eckey
            _FfiHandle,  # x
            _FfiHandle,  # y
        ](eckey, x_bn, y_bn)
        if rc_pk != 1:
            return False

        # Build ECDSA_SIG from r + s.
        sig = external_call[
            "komira_awslc_ECDSA_SIG_new",
            _FfiHandle,
        ]()
        if Int(sig) == 0:
            return False  # cov: unreachable an allocation failure
        r_bn = _bn_bin2bn_from_span(r_be)
        s_bn = _bn_bin2bn_from_span(s_be)
        if Int(r_bn) == 0 or Int(s_bn) == 0:
            return False  # cov: unreachable an allocation failure

        # SAFETY: ECDSA_SIG_set0 TAKES OWNERSHIP of r_bn + s_bn — they
        # are now owned by sig and will be freed when sig is freed.
        # MUST NOT free them separately. We flip sig_owns_rs to skip
        # freeing them in the finally block.
        var rc_set = external_call[
            "komira_awslc_ECDSA_SIG_set0", Int32,
            _FfiHandle,  # sig
            _FfiHandle,  # r
            _FfiHandle,  # s
        ](sig, r_bn, s_bn)
        if rc_set != 1:
            # set0 failed — r_bn / s_bn ownership stays with us.
            return False  # cov: unreachable ECDSA_SIG_set0 fails only on a NULL r or s, refused above
        sig_owns_rs = True

        # SAFETY: ECDSA_do_verify reads 32 bytes from digest_ptr, performs
        # the FIPS 186-4 §6.4.2 verify procedure on (sig, eckey-pubkey).
        # Returns 1 on valid, 0 on invalid, -1 on internal error.
        var digest_ptr = _span_ptr_mut(digest)
        var rc_v = external_call[
            "komira_awslc_ECDSA_do_verify", Int32,
            _FfiByte,     # digest
            UInt,                                         # digest_len
            _FfiHandle,  # sig
            _FfiHandle,  # eckey
        ](digest_ptr, UInt(32), sig, eckey)
        ok = (rc_v == Int32(1))
    finally:
        # SAFETY: ECDSA_SIG_free frees sig + its internal BIGNUMs.
        # If set0 succeeded, sig owns r_bn + s_bn so we skip BN_free for them.
        if Int(sig) != 0:
            external_call[
                "komira_awslc_ECDSA_SIG_free", NoneType,
                _FfiHandle,
            ](sig)
        if not sig_owns_rs:
            _bn_free(r_bn)
            _bn_free(s_bn)
        _bn_free(y_bn)
        _bn_free(x_bn)
        _ec_key_free(eckey)
    return ok


def p256_pubkey_from_priv(
    priv_be: Span[UInt8, _],
    mut pub_xy_out: Array[UInt8, 64],
) raises:
    """Derive P-256 public key (uncompressed x||y BE) from private scalar.

    Args:
        priv_be: 32-byte big-endian private scalar.
        pub_xy_out: 64-byte output for (x || y) BE. No leading 0x04
            format byte (matches our existing API).

    Internally: builds an EC_KEY for P-256, allocates an EC_POINT,
    computes pub = priv * G via EC_POINT_mul, serializes via
    EC_POINT_point2oct(UNCOMPRESSED), strips the format byte.

    Raises:
        "p256_pubkey: invalid input size" if priv_be wrong length.
        "p256_pubkey: OOM" if AWS-LC EC_KEY/BN/EC_POINT alloc fails.
        "p256_pubkey: derivation failed" if EC_POINT_mul fails.
    """
    if len(priv_be) != 32:
        raise Error("p256_pubkey: priv_be must be 32 bytes")

    var eckey = _ec_key_new()
    var priv_bn = _ffi_null()
    var pub_pt = _ffi_null()
    # ⚠ FAILURE PATHS RAISE DIRECTLY FROM INSIDE THE `try` — do NOT convert
    # them back to a deferred `should_raise` flag checked after the block.
    # That shape is DEAD: a `return`
    # inside the `try` exits the FUNCTION, so the `if should_raise: raise`
    # after it was reachable only on the fall-through path where the flag
    # is False, so every AWS-LC failure would return SUCCESS with the caller's
    # out-buffers untouched (an all-zero signature). There is no `except`
    # clause here, only `finally` — so a `raise` runs the cleanup below and
    # then propagates, which is exactly what the deferred flag was trying
    # to emulate. (A "raise must not be inside the try" rule is
    # about try/EXCEPT swallowing the new Error;
    # it does not apply to a try/FINALLY.)
    try:
        if Int(eckey) == 0:
            raise Error("p256_pubkey: EC_KEY_new_by_curve_name OOM")  # cov: unreachable an allocation failure

        # Borrowed group ptr; do NOT free.
        var group = _ec_key_get0_group(eckey)
        if Int(group) == 0:
            raise Error("p256_pubkey: EC_KEY_get0_group returned NULL")  # cov: unreachable an EC_KEY made for this curve always has its group

        priv_bn = _bn_bin2bn_from_span(priv_be)
        if Int(priv_bn) == 0:
            raise Error("p256_pubkey: BN_bin2bn(priv) OOM")  # cov: unreachable an allocation failure

        pub_pt = external_call[
            "komira_awslc_EC_POINT_new",
            _FfiHandle,
            _FfiHandle,  # group
        ](group)
        if Int(pub_pt) == 0:
            raise Error("p256_pubkey: EC_POINT_new OOM")  # cov: unreachable an allocation failure

        # SAFETY: EC_POINT_mul(group, r, n, q, m, ctx):
        #   r = n*G + m*q where G is the group's generator.
        # We pass q=NULL, m=NULL, ctx=NULL — AWS-LC computes r = n*G with
        # an internal BN_CTX. Returns 1 on success.
        var null_ptr = _ffi_null()
        var rc_mul = external_call[
            "komira_awslc_EC_POINT_mul", Int32,
            _FfiHandle,  # group
            _FfiHandle,  # r (out point)
            _FfiHandle,  # n (scalar)
            _FfiHandle,  # q (NULL)
            _FfiHandle,  # m (NULL)
            _FfiHandle,  # ctx (NULL)
        ](group, pub_pt, priv_bn, null_ptr, null_ptr, null_ptr)
        if rc_mul != 1:
            raise Error("p256_pubkey: EC_POINT_mul failed")  # cov: unreachable EC_POINT_mul reduces any scalar mod n and fails only on an allocation failure

        # SAFETY: EC_POINT_point2oct writes the uncompressed point
        # (1 format byte + 32 x bytes + 32 y bytes = 65 bytes) into buf
        # when form=UNCOMPRESSED. Returns the number of bytes written
        # (65) on success, or 0 on failure.
        var raw65 = Array[UInt8, 65](fill=UInt8(0))
        var raw_ptr = _inline65_ptr_mut(raw65)
        var n_written = external_call[
            "komira_awslc_EC_POINT_point2oct", UInt,
            _FfiHandle,  # group
            _FfiHandle,  # point
            Int32,                                        # form
            _FfiByte,     # buf
            UInt,                                         # len
            _FfiHandle,  # ctx (NULL)
        ](
            group, pub_pt,
            Int32(POINT_CONVERSION_UNCOMPRESSED),
            raw_ptr, UInt(65), null_ptr,
        )
        if n_written != UInt(65):
            raise Error("p256_pubkey: EC_POINT_point2oct failed")
        if raw65[0] != UInt8(0x04):
            raise Error("p256_pubkey: unexpected point format byte")  # cov: unreachable POINT_CONVERSION_UNCOMPRESSED always writes 0x04 first

        # Strip leading 0x04, copy x||y into pub_xy_out.
        for i in range(64):
            pub_xy_out[i] = raw65[1 + i]
    finally:
        # SAFETY: EC_POINT_free is no-op on NULL. BN_free is no-op on NULL.
        # EC_KEY_free is no-op on NULL.
        if Int(pub_pt) != 0:
            external_call[
                "komira_awslc_EC_POINT_free", NoneType,
                _FfiHandle,
            ](pub_pt)
        _bn_free(priv_bn)
        _ec_key_free(eckey)
