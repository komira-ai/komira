# =============================================================================
# komira_crypto/internal/asm/hkdf_ffi.mojo
# =============================================================================
#
# HKDF over SHA-256 / SHA-384 / SHA-512 via AWS-LC's HKDF_extract +
# HKDF_expand APIs.
#
# Backs Hkdf[H: Hash] in hkdf.mojo.
# RFC 5869 Extract + Expand are HMAC-based by construction; AWS-LC's
# HKDF_extract/HKDF_expand are direct one-shot calls (no opaque CTX).
#
# # Symbols used
#
#   * HKDF_extract(out_key, out_len, digest, secret, secret_len, salt, salt_len)
#   * HKDF_expand (out_key, out_len, digest, prk, prk_len, info, info_len)
#   * EVP_sha256/384/512 — reused from sha256_ffi.mojo
#
# # C signatures (from AWS-LC's include/openssl/hkdf.h)
#
#   int HKDF_extract(uint8_t *out_key, size_t *out_len, const EVP_MD *digest,
#                    const uint8_t *secret, size_t secret_len,
#                    const uint8_t *salt, size_t salt_len);
#   int HKDF_expand(uint8_t *out_key, size_t out_len, const EVP_MD *digest,
#                   const uint8_t *prk, size_t prk_len,
#                   const uint8_t *info, size_t info_len);
#
# Both return 1 on success, 0 on failure.
#
# # Encapsulation discipline
#
#   * ZERO UnsafePointer in public sigs (functions take/return InlineArray
#     + Span over open origin).
#   * ZERO wildcard origins on public surface.
#   * ZERO unsafe_from_address / take_pointee / ArcPointer.
#   * Every external_call carries a `# SAFETY:` comment.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer

from komira_crypto.internal.asm.sha256_ffi import (
    _evp_sha256,
    _evp_sha384,
    _evp_sha512,
)



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


@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce a `Span[UInt8, _]` to an FFI byte pointer (_FFI_ORIGIN)."""
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


@always_inline
def _evp_md_for_size[OUTPUT_SIZE: Int]() -> _FfiHandle:
    """Comptime-dispatch EVP_MD selector based on OUTPUT_SIZE."""
    comptime if OUTPUT_SIZE == 32:
        return _evp_sha256()
    elif OUTPUT_SIZE == 48:
        return _evp_sha384()
    else:
        return _evp_sha512()


# -----------------------------------------------------------------------------
# HKDF-Extract — RFC 5869 §2.2
# -----------------------------------------------------------------------------


def hkdf_extract_ffi[OUTPUT_SIZE: Int](
    salt: Span[UInt8, _], ikm: Span[UInt8, _]
) -> Array[UInt8, OUTPUT_SIZE]:
    """HKDF-Extract: PRK = HMAC-Hash(salt, IKM).

    Returns OUTPUT_SIZE bytes (32 for SHA-256, 48 for SHA-384, 64 for SHA-512).
    Empty `salt` is treated as a zero-filled buffer of HashLen bytes per
    RFC 5869 §2.2.
    """
    comptime assert OUTPUT_SIZE == 32 or OUTPUT_SIZE == 48 or OUTPUT_SIZE == 64, "hkdf_extract_ffi OUTPUT_SIZE must be 32 / 48 / 64"
    var prk = Array[UInt8, OUTPUT_SIZE](fill=0)

    # SAFETY: HKDF_extract reads len(salt) bytes from salt_ptr (may be
    # empty), len(ikm) bytes from ikm_ptr, writes OUTPUT_SIZE bytes to
    # prk_ptr, writes 1 size_t to out_len. All buffers caller-owned for
    # the synchronous call; AWS-LC retains no pointer past the call.
    # When salt is empty, AWS-LC substitutes 0^HashLen internally
    # (RFC 5869 §2.2).
    var md = _evp_md_for_size[OUTPUT_SIZE]()
    var prk_ptr = UnsafePointer(to=prk[0]).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN]()
    var salt_ptr = _span_ptr_mut(salt)
    var ikm_ptr = _span_ptr_mut(ikm)
    var out_len = UInt(OUTPUT_SIZE)
    var rc = external_call[
        "komira_awslc_HKDF_extract",
        Int,
        _FfiByte,     # out_key
        UnsafePointer[UInt, _FFI_ORIGIN],      # out_len (in/out)
        _FfiHandle,  # digest
        _FfiByte,     # secret (ikm)
        UInt,                                         # secret_len
        _FfiByte,     # salt
        UInt,                                         # salt_len
    ](
        prk_ptr,
        UnsafePointer(to=out_len).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN](),
        md,
        ikm_ptr,
        UInt(len(ikm)),
        salt_ptr,
        UInt(len(salt)),
    )
    debug_assert(rc == 1, "hkdf_extract_ffi: HKDF_extract failed")
    debug_assert(Int(out_len) == OUTPUT_SIZE, "hkdf_extract_ffi: out_len mismatch")

    return prk^


# -----------------------------------------------------------------------------
# HKDF-Expand — RFC 5869 §2.3
# -----------------------------------------------------------------------------


def hkdf_expand_ffi[OUTPUT_SIZE: Int, o: Origin[mut=True]](
    prk: Span[UInt8, _],
    info: Span[UInt8, _],
    dst: Span[UInt8, o],
):
    """HKDF-Expand: OKM = T(1) || T(2) || ... || T(N).

    `prk` must be OUTPUT_SIZE bytes (the PRK from HKDF-Extract).
    `info` is application-specific context (may be empty).
    `dst` length determines output length; must satisfy
    `len(dst) <= 255 * HashLen` per RFC 5869 §2.3.
    """
    comptime assert OUTPUT_SIZE == 32 or OUTPUT_SIZE == 48 or OUTPUT_SIZE == 64, "hkdf_expand_ffi OUTPUT_SIZE must be 32 / 48 / 64"
    if len(dst) == 0:
        return

    # SAFETY: HKDF_expand reads len(prk) bytes from prk_ptr (must be
    # OUTPUT_SIZE), len(info) bytes from info_ptr (may be empty),
    # writes len(dst) bytes to dst_ptr. All buffers caller-owned for
    # the synchronous call.
    var md = _evp_md_for_size[OUTPUT_SIZE]()
    var dst_ptr = _span_ptr_mut(dst)
    var prk_ptr = _span_ptr_mut(prk)
    var info_ptr = _span_ptr_mut(info)
    var rc = external_call[
        "komira_awslc_HKDF_expand",
        Int,
        _FfiByte,     # out_key
        UInt,                                         # out_len
        _FfiHandle,  # digest
        _FfiByte,     # prk
        UInt,                                         # prk_len
        _FfiByte,     # info
        UInt,                                         # info_len
    ](
        dst_ptr,
        UInt(len(dst)),
        md,
        prk_ptr,
        UInt(len(prk)),
        info_ptr,
        UInt(len(info)),
    )
    debug_assert(rc == 1, "hkdf_expand_ffi: HKDF_expand failed")
