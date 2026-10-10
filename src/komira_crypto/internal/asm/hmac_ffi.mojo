# =============================================================================
# komira_crypto/internal/asm/hmac_ffi.mojo
# =============================================================================
#
# HMAC over SHA-256 / SHA-384 / SHA-512 via AWS-LC's HMAC_CTX_* API.
#
# AWS-LC's HMAC_CTX_* gives the RFC 2104 pre-fed inner+outer pattern (the
# "pre-fed _outer + fork" shape) internally, via the HMAC_CTX_copy_ex idiom.
#
# # Symbols used
#
#   * HMAC(evp_md, key, key_len, data, data_len, md, md_len)  — one-shot
#   * HMAC_CTX_new          — alloc opaque streaming context
#   * HMAC_CTX_free         — free context + zeroize internal state
#   * HMAC_CTX_copy_ex      — clone context (for fork())
#   * HMAC_Init_ex          — initialize with key + EVP_MD method
#   * HMAC_Update           — absorb bytes
#   * HMAC_Final            — emit MAC (consumes ctx state)
#   * EVP_sha256/384/512    — method singletons (reused from sha256_ffi.mojo)
#
# # C signatures
#
#   uint8_t *HMAC(const EVP_MD *evp_md, const void *key, size_t key_len,
#                 const uint8_t *data, size_t data_len,
#                 uint8_t *out, unsigned int *out_len);
#   HMAC_CTX *HMAC_CTX_new(void);
#   void HMAC_CTX_free(HMAC_CTX *ctx);
#   int HMAC_CTX_copy_ex(HMAC_CTX *dst, const HMAC_CTX *src);
#   int HMAC_Init_ex(HMAC_CTX *ctx, const void *key, size_t key_len,
#                    const EVP_MD *md, ENGINE *impl);
#   int HMAC_Update(HMAC_CTX *ctx, const uint8_t *data, size_t len);
#   int HMAC_Final(HMAC_CTX *ctx, uint8_t *md, unsigned int *len);
#
# # Encapsulation discipline
#
# Public API:
#   * `hmac_oneshot[N]` free function takes 2x `Span[UInt8, _]` + returns
#     `InlineArray[UInt8, N]`. ZERO UnsafePointer in public signature.
#   * `HmacFfiCtx[OUTPUT_SIZE]` struct: opaque wrapper around AWS-LC's
#     HMAC_CTX*. Private `_ctx` field is the FFI-OPAQUE-HANDLE carve-out
#     (same shape as AesGcmCtx._ctx and Sha2Hasher._ctx).
#   * `update`, `finalize_into`, `fork`, `reset(key)` — typed Mojo args.
#
# Internal FFI: external_call sites use the `MutExternalOrigin` shape;
# ZERO unsafe_from_address; ZERO take_pointee; multi-line `# SAFETY:`
# comments at every site.
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


# -----------------------------------------------------------------------------
# Coercion helper (mirror of sha256_ffi._span_ptr_mut).
# -----------------------------------------------------------------------------


@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce a `Span[UInt8, _]` to a `MutExternalOrigin`-cast pointer for FFI.

    # SAFETY: caller MUST hold the Span's origin in scope across the
    # external_call site. AWS-LC's HMAC_* paths retain no pointer past
    # the synchronous call.
    """
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
# hmac_oneshot — single-call HMAC over SHA-2 family.
# -----------------------------------------------------------------------------


@always_inline
def hmac_oneshot[OUTPUT_SIZE: Int](
    key: Span[UInt8, _], data: Span[UInt8, _]
) -> Array[UInt8, OUTPUT_SIZE]:
    """One-shot HMAC-SHA{256,384,512} via AWS-LC's HMAC() symbol.

    Implements RFC 2104 + FIPS 198-1; key handling per RFC 2104 §2:
      * len(key) > BLOCK_SIZE: K' = H(K)
      * len(key) < BLOCK_SIZE: K' = K || 0x00...
      * else:                  K' = K
    AWS-LC handles all three cases internally.
    """
    comptime assert OUTPUT_SIZE == 32 or OUTPUT_SIZE == 48 or OUTPUT_SIZE == 64, "hmac_oneshot OUTPUT_SIZE must be 32 / 48 / 64"
    var out = Array[UInt8, OUTPUT_SIZE](fill=0)

    # SAFETY: HMAC() reads len(key) bytes from key, len(data) bytes
    # from data, writes OUTPUT_SIZE bytes to out, writes 1 UInt32 to
    # out_len. All buffers caller-owned; AWS-LC retains no pointer past
    # the call.
    var md = _evp_md_for_size[OUTPUT_SIZE]()
    var key_ptr = _span_ptr_mut(key)
    var data_ptr = _span_ptr_mut(data)
    var out_ptr = UnsafePointer(to=out[0]).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN]()
    var out_len = UInt32(0)
    var ret = external_call[
        "komira_awslc_HMAC",
        _FfiByte,
        _FfiHandle,  # evp_md
        _FfiByte,     # key
        UInt,                                         # key_len
        _FfiByte,     # data
        UInt,                                         # data_len
        _FfiByte,     # md
        UnsafePointer[UInt32, _FFI_ORIGIN],    # md_len
    ](
        md,
        key_ptr,
        UInt(len(key)),
        data_ptr,
        UInt(len(data)),
        out_ptr,
        UnsafePointer(to=out_len).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN](),
    )
    debug_assert(Int(ret) != 0, "hmac_oneshot: HMAC() returned NULL")
    debug_assert(
        Int(out_len) == OUTPUT_SIZE,
        "hmac_oneshot: out_len != OUTPUT_SIZE",
    )

    return out^


# -----------------------------------------------------------------------------
# HmacFfiCtx[OUTPUT_SIZE] — streaming HMAC over SHA-2 family.
# -----------------------------------------------------------------------------


struct HmacFfiCtx[OUTPUT_SIZE: Int](Movable, Deinitable):
    """Streaming HMAC over AWS-LC's HMAC_CTX.

    OUTPUT_SIZE: 32 (HMAC-SHA-256), 48 (HMAC-SHA-384), 64 (HMAC-SHA-512).

    Conforms structurally to the Hmac[H: Hash] surface:
      * __init__(key) — construct from a key (RFC 2104 §2 key handling
        is internal to AWS-LC's HMAC_Init_ex).
      * update(data) — absorb bytes
      * finalize_into(dst) — emit MAC (idempotent via HMAC_CTX_copy_ex
        on a fork-clone)
      * fork() -> Self — clone running state (load-bearing for TLS 1.3
        transcript-MAC snapshot flows)
      * reset(key) — re-initialize with a new key (avoids alloc churn)

    The internal `_ctx` field holds AWS-LC's heap-allocated HMAC_CTX
    as `_FfiHandle` (FFI-OPAQUE-HANDLE
    carve-out; same shape as Sha2Hasher._ctx).

    Non-Copyable: copying secret-bearing inner state is a leak. Use
    `fork()` for the explicit transcript-snapshot opt-in.
    """

    var _ctx: _FfiHandle
    # SAFETY: _ctx is the opaque heap-allocated HMAC_CTX owned by
    # AWS-LC. Allocated in __init__ via HMAC_CTX_new, freed in __del__
    # via HMAC_CTX_free. Never bitcast to typed Mojo pointer; never
    # dereferenced from Mojo code; only passed back to AWS-LC FFI sites
    # in this file. FFI-OPAQUE-HANDLE carve-out (precedent:
    # Sha2Hasher._ctx in sha256_ffi.mojo).

    def __init__(out self, key: Span[UInt8, _]):
        """Allocate + initialize an HMAC_CTX with the given key.

        Non-raising. AWS-LC's HMAC_CTX_new returns NULL only on OOM;
        debug_assert on NULL.
        """
        comptime assert Self.OUTPUT_SIZE == 32 or Self.OUTPUT_SIZE == 48 or Self.OUTPUT_SIZE == 64, "HmacFfiCtx OUTPUT_SIZE must be 32 / 48 / 64"
        # SAFETY: HMAC_CTX_new() allocates a heap CTX. Retained in
        # self._ctx; freed in __del__.
        self._ctx = external_call[
            "komira_awslc_HMAC_CTX_new", _FfiHandle
        ]()
        debug_assert(
            Int(self._ctx) != 0,
            "HmacFfiCtx: HMAC_CTX_new returned NULL (OOM)",
        )

        # SAFETY: HMAC_Init_ex reads len(key) bytes from key_ptr (key
        # material) into self._ctx; AWS-LC retains no pointer past the
        # call (the key is hashed-down / XOR'd into the inner/outer
        # pads). ENGINE* = NULL.
        var md = _evp_md_for_size[Self.OUTPUT_SIZE]()
        var key_ptr = _span_ptr_mut(key)
        var rc = external_call[
            "komira_awslc_HMAC_Init_ex",
            Int,
            _FfiHandle,  # ctx
            _FfiByte,     # key
            UInt,                                         # key_len
            _FfiHandle,  # md
            _FfiHandle,  # engine = NULL
        ](
            self._ctx,
            key_ptr,
            UInt(len(key)),
            md,
            _ffi_null(),
        )
        debug_assert(rc == 1, "HmacFfiCtx: HMAC_Init_ex failed")

    def __init__(out self, *, _ctx: _FfiHandle):
        """Private ctor for fork(). Caller owns the ctx pointer."""
        self._ctx = _ctx

    def update(mut self, data: Span[UInt8, _]):
        """Absorb `data` into the running MAC."""
        if len(data) == 0:
            return

        # SAFETY: HMAC_Update reads len(data) bytes from data_ptr.
        # Buffer caller-owned for the synchronous call.
        var data_ptr = _span_ptr_mut(data)
        var rc = external_call[
            "komira_awslc_HMAC_Update",
            Int,
            _FfiHandle,
            _FfiByte,
            UInt,
        ](self._ctx, data_ptr, UInt(len(data)))
        debug_assert(rc == 1, "HmacFfiCtx: HMAC_Update failed")

    def finalize_into[o: Origin[mut=True]](
        self,
        dst: Span[UInt8, o],
    ):
        """Emit the final MAC into `dst` (>= OUTPUT_SIZE bytes).

        Idempotent: clones self._ctx via HMAC_CTX_copy_ex
        and finalizes the clone, leaving self._ctx at the pre-finalize
        state. Subsequent update() + finalize_into() calls work
        identically to a fresh stream.

        Idempotency is load-bearing for TLS 1.3 verify_data / KeyUpdate /
        exporter flows (RFC 8446 §4.4.4).
        """
        debug_assert(
            len(dst) >= Self.OUTPUT_SIZE,
            "HmacFfiCtx.finalize_into: dst too small",
        )

        # Allocate a fresh ctx for the clone.
        # SAFETY: clone_ctx is local-owned; freed before this fn returns.
        var clone_ctx = external_call[
            "komira_awslc_HMAC_CTX_new", _FfiHandle
        ]()
        debug_assert(
            Int(clone_ctx) != 0,
            "HmacFfiCtx.finalize_into: HMAC_CTX_new returned NULL",
        )
        var rc = external_call[
            "komira_awslc_HMAC_CTX_copy_ex",
            Int,
            _FfiHandle,  # dst
            _FfiHandle,  # src
        ](clone_ctx, self._ctx)
        debug_assert(rc == 1, "HmacFfiCtx.finalize_into: HMAC_CTX_copy_ex failed")

        # SAFETY: HMAC_Final writes OUTPUT_SIZE bytes to dst_ptr + 1
        # UInt32 to out_len. The clone ctx is invalidated by this call
        # (we free it next).
        var dst_ptr = _span_ptr_mut(dst)
        var out_len = UInt32(0)
        var rc2 = external_call[
            "komira_awslc_HMAC_Final",
            Int,
            _FfiHandle,
            _FfiByte,
            UnsafePointer[UInt32, _FFI_ORIGIN],
        ](
            clone_ctx,
            dst_ptr,
            UnsafePointer(to=out_len).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN](),
        )
        debug_assert(rc2 == 1, "HmacFfiCtx.finalize_into: HMAC_Final failed")
        debug_assert(
            Int(out_len) == Self.OUTPUT_SIZE,
            "HmacFfiCtx.finalize_into: out_len != OUTPUT_SIZE",
        )

        # Free the clone.
        external_call[
            "komira_awslc_HMAC_CTX_free",
            NoneType,
            _FfiHandle,
        ](clone_ctx)

    def fork(self) -> Self:
        """Clone the streaming MAC state.

        Allocates a new HMAC_CTX and copies self._ctx into it. Returned
        Self owns the clone; original self._ctx unchanged.
        """
        # SAFETY: clone_ctx is owned by returned Self; freed by its
        # __del__. Original self._ctx is separate heap allocation.
        var clone_ctx = external_call[
            "komira_awslc_HMAC_CTX_new", _FfiHandle
        ]()
        debug_assert(
            Int(clone_ctx) != 0,
            "HmacFfiCtx.fork: HMAC_CTX_new returned NULL",
        )
        var rc = external_call[
            "komira_awslc_HMAC_CTX_copy_ex",
            Int,
            _FfiHandle,
            _FfiHandle,
        ](clone_ctx, self._ctx)
        debug_assert(rc == 1, "HmacFfiCtx.fork: HMAC_CTX_copy_ex failed")
        return Self(_ctx=clone_ctx)

    def __deinit__(deinit self):
        """Free the HMAC_CTX (AWS-LC clears secret state internally)."""
        # SAFETY: HMAC_CTX_free matches HMAC_CTX_new. Movable contract
        # suppresses source-side __del__ post-move; runs exactly once.
        if Int(self._ctx) != 0:
            external_call[
                "komira_awslc_HMAC_CTX_free",
                NoneType,
                _FfiHandle,
            ](self._ctx)


# -----------------------------------------------------------------------------
# Public type aliases.
# -----------------------------------------------------------------------------


comptime HmacSha256Ffi = HmacFfiCtx[32]
"""Streaming HMAC-SHA-256 via AWS-LC."""

comptime HmacSha384Ffi = HmacFfiCtx[48]
"""Streaming HMAC-SHA-384 via AWS-LC."""

comptime HmacSha512Ffi = HmacFfiCtx[64]
"""Streaming HMAC-SHA-512 via AWS-LC."""
