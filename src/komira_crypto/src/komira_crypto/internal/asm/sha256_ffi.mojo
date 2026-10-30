# =============================================================================
# komira_crypto/internal/asm/sha256_ffi.mojo
# =============================================================================
#
# SHA-2 family streaming hashers via AWS-LC's EVP_MD_CTX_* API.
#
# It routes everything through AWS-LC — padding, buffering, bit-counting
# and the per-block compression — rather than keeping a Mojo Merkle-Damgård
# scaffold around an FFI'd compression body (sha256_compress.mojo).
#
# # Symbols used (verified via nm libcrypto.a)
#
#   * SHA256(data, len, md)   — one-shot SHA-256
#   * SHA384(data, len, md)   — one-shot SHA-384
#   * SHA512(data, len, md)   — one-shot SHA-512
#   * SHA1(data, len, md)     — one-shot SHA-1 (see "SHA-1 IS HERE AS A
#                               WITNESS" below)
#   * BLAKE2B256(data, len, md) — one-shot BLAKE2b-256 (a registry-protocol
#                               digest; see `blake2b_256_oneshot`)
#   * EVP_MD_CTX_new          — alloc opaque context
#   * EVP_MD_CTX_free         — free context + zeroize internal state
#   * EVP_MD_CTX_copy_ex      — clone context (for fork())
#   * EVP_DigestInit_ex      — initialize context for a given EVP_MD
#   * EVP_DigestUpdate        — absorb bytes
#   * EVP_DigestFinal_ex      — emit digest (consumes ctx state)
#   * EVP_sha256              — method singleton for SHA-256
#   * EVP_sha384              — method singleton for SHA-384
#   * EVP_sha512              — method singleton for SHA-512
#   * EVP_sha1                — method singleton for SHA-1
#
# # C signatures (from AWS-LC's include/openssl/digest.h)
#
#   uint8_t *SHA256(const uint8_t *data, size_t len, uint8_t out[32]);
#   uint8_t *SHA384(const uint8_t *data, size_t len, uint8_t out[48]);
#   uint8_t *SHA512(const uint8_t *data, size_t len, uint8_t out[64]);
#   uint8_t *SHA1(const uint8_t *data, size_t len, uint8_t out[20]);   (sha.h)
#
#   EVP_MD_CTX *EVP_MD_CTX_new(void);
#   void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
#   int EVP_MD_CTX_copy_ex(EVP_MD_CTX *out, const EVP_MD_CTX *in);
#
#   int EVP_DigestInit_ex(EVP_MD_CTX *ctx, const EVP_MD *type, ENGINE *impl);
#   int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *d, size_t cnt);
#   int EVP_DigestFinal_ex(EVP_MD_CTX *ctx, uint8_t *md, unsigned int *s);
#
#   const EVP_MD *EVP_sha256(void);
#   const EVP_MD *EVP_sha384(void);
#   const EVP_MD *EVP_sha512(void);
#   const EVP_MD *EVP_sha1(void);
#
# # SHA-1 IS HERE AS A WITNESS, NOT AS A SECURITY PRIMITIVE
#
# `Sha2Hasher` is the EVP_MD_CTX wrapper, and OUTPUT_SIZE selects the EVP_MD.
# 20 selects SHA-1 (FIPS 180-4 §6.1), which is NOT a SHA-2 member: the struct's
# name predates it. The four output sizes (20/32/48/64) are pairwise distinct, so
# the size alone names the algorithm. SHA-1 is collision-broken; it is reachable
# only for registries that publish it as a content witness (npm's
# `dist.shasum`), and the public `Sha1` wrapper deliberately does NOT conform to
# the `Hash` trait, so no HMAC / HKDF / signature / transcript path can be
# instantiated over it.
# # Encapsulation discipline
#
# Public API:
#   * `sha2_oneshot[N]` free function takes `Span[UInt8, _]` + returns
#     `InlineArray[UInt8, N]`. ZERO UnsafePointer in public signature.
#   * `Sha2Hasher[OUTPUT_SIZE]` struct: opaque wrapper around AWS-LC's
#     heap-allocated EVP_MD_CTX*. Private `_ctx` field is the
#     FFI-OPAQUE-HANDLE carve-out (same shape as AesGcmCtx._ctx in
#     aes_gcm_ffi.mojo:201).
#   * `update(self, mut: data: Span[UInt8, _])`, `finalize_into[o](self, dst: Span[UInt8, o])`,
#     `fork(self) -> Self`, `reset(mut self)` — all take typed Mojo args;
#     no UnsafePointer surface.
#
# Internal FFI:
#   * external_call sites use the `MutExternalOrigin` shape via
#     `unsafe_origin_cast[_FFI_ORIGIN]()` for the in/out byte pointers
#     (canonical FFI-boundary pattern; mirror of aes_gcm_ffi.mojo's
#     `_span_ptr_mut` helper).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
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
# Coercion helper — Span[UInt8, _] -> MutExternalOrigin pointer for FFI.
# Mirror of `_span_ptr_mut` in aes_gcm_ffi.mojo:120.
# -----------------------------------------------------------------------------


@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce a `Span[UInt8, _]` to a `MutExternalOrigin`-cast pointer for FFI.

    # SAFETY: caller MUST hold the Span's origin (and the underlying
    # buffer it borrows from) in scope across the external_call site.
    # AWS-LC's SHA-2 / EVP_Digest* paths retain no pointer past the
    # synchronous call.
    """
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


# -----------------------------------------------------------------------------
# EVP_MD method singletons (lifetime: program-static; never freed).
# -----------------------------------------------------------------------------


@always_inline
def _evp_sha256() -> _FfiHandle:
    """Return AWS-LC's SHA-256 method singleton."""
    # SAFETY: AWS-LC's EVP_sha256() returns a pointer to a static const
    # struct (lives forever in libcrypto.a's .rodata). Never freed;
    # held only as opaque handle passed back to EVP_DigestInit_ex.
    return external_call[
        "komira_awslc_EVP_sha256", _FfiHandle
    ]()


@always_inline
def _evp_sha384() -> _FfiHandle:
    """Return AWS-LC's SHA-384 method singleton."""
    # SAFETY: same as _evp_sha256.
    return external_call[
        "komira_awslc_EVP_sha384", _FfiHandle
    ]()


@always_inline
def _evp_sha512() -> _FfiHandle:
    """Return AWS-LC's SHA-512 method singleton."""
    # SAFETY: same as _evp_sha256.
    return external_call[
        "komira_awslc_EVP_sha512", _FfiHandle
    ]()


@always_inline
def _evp_sha1() -> _FfiHandle:
    """Return AWS-LC's SHA-1 method singleton (a witness digest only — see
    the file header)."""
    # SAFETY: same as _evp_sha256.
    return external_call[
        "komira_awslc_EVP_sha1", _FfiHandle
    ]()


@always_inline
def _evp_md_for_size[OUTPUT_SIZE: Int]() -> _FfiHandle:
    """Comptime-dispatch the EVP_MD selector based on OUTPUT_SIZE.

    20 → SHA-1, 32 → SHA-256, 48 → SHA-384, 64 → SHA-512. Constrained
    at the caller (Sha2Hasher).
    """
    comptime if OUTPUT_SIZE == 20:
        return _evp_sha1()
    elif OUTPUT_SIZE == 32:
        return _evp_sha256()
    elif OUTPUT_SIZE == 48:
        return _evp_sha384()
    else:
        # OUTPUT_SIZE == 64 by constrained[] at caller
        return _evp_sha512()


# -----------------------------------------------------------------------------
# sha2_oneshot — single-call SHA-2 family digest.
#
# Used as the implementation of the free `sha256(data)`, `sha384(data)`,
# `sha512(data)` functions in the top-level facade. AWS-LC's SHA256()/
# SHA384()/SHA512() functions are the OpenSSL-compatible one-shots.
# -----------------------------------------------------------------------------


@always_inline
def sha2_oneshot[OUTPUT_SIZE: Int](data: Span[UInt8, _]) -> Array[UInt8, OUTPUT_SIZE]:
    """One-shot SHA-2 digest via AWS-LC.

    OUTPUT_SIZE must be 32 (SHA-256), 48 (SHA-384), or 64 (SHA-512).
    """
    comptime assert OUTPUT_SIZE == 32 or OUTPUT_SIZE == 48 or OUTPUT_SIZE == 64, "sha2_oneshot OUTPUT_SIZE must be 32 / 48 / 64"
    var out = Array[UInt8, OUTPUT_SIZE](fill=0)

    # SAFETY: AWS-LC's SHA256/SHA384/SHA512 reads exactly len(data)
    # bytes from `data` and writes exactly OUTPUT_SIZE bytes to `out`.
    # Both buffers are caller-owned for the synchronous call duration;
    # AWS-LC retains no pointer past the call. Empty-input case
    # (len=0): AWS-LC still writes the canonical empty-string digest
    # to `out`. For SHA-256 that is `e3b0c4...7852b855` (load-bearing
    # for SigV4's empty-payload hash).
    var out_ptr = UnsafePointer(to=out[0]).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN]()
    var data_ptr = _span_ptr_mut(data)

    comptime if OUTPUT_SIZE == 32:
        _ = external_call[
            "komira_awslc_SHA256",
            _FfiByte,
            _FfiByte,
            UInt,
            _FfiByte,
        ](data_ptr, UInt(len(data)), out_ptr)
    elif OUTPUT_SIZE == 48:
        _ = external_call[
            "komira_awslc_SHA384",
            _FfiByte,
            _FfiByte,
            UInt,
            _FfiByte,
        ](data_ptr, UInt(len(data)), out_ptr)
    else:
        _ = external_call[
            "komira_awslc_SHA512",
            _FfiByte,
            _FfiByte,
            UInt,
            _FfiByte,
        ](data_ptr, UInt(len(data)), out_ptr)

    return out^


# -----------------------------------------------------------------------------
# sha1_oneshot — single-call SHA-1 digest (a witness digest only; see the
# file header). Kept apart from `sha2_oneshot` so that no SHA-2 call site can
# reach SHA-1 by getting an OUTPUT_SIZE wrong.
# -----------------------------------------------------------------------------


@always_inline
def sha1_oneshot(data: Span[UInt8, _]) -> Array[UInt8, 20]:
    """One-shot SHA-1 digest via AWS-LC's SHA1() symbol."""
    var out = Array[UInt8, 20](fill=0)

    # SAFETY: AWS-LC's SHA1 reads exactly len(data) bytes from `data` and
    # writes exactly 20 bytes to `out`. Both buffers are caller-owned for the
    # synchronous call duration; AWS-LC retains no pointer past the call.
    # Empty input (len=0) still writes the canonical empty-string digest
    # `da39a3ee...afd80709`.
    var out_ptr = UnsafePointer(to=out[0]).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN]()
    var data_ptr = _span_ptr_mut(data)
    _ = external_call[
        "komira_awslc_SHA1",
        _FfiByte,
        _FfiByte,
        UInt,
        _FfiByte,
    ](data_ptr, UInt(len(data)), out_ptr)
    return out^


# -----------------------------------------------------------------------------
# blake2b_256_oneshot — single-call BLAKE2b-256 (RFC 7693, 32-byte output,
# unkeyed). A REGISTRY-PROTOCOL digest, not a security primitive of this
# library: the Python package index's legacy upload carries a
# `blake2_256_digest` field beside `sha256_digest`, and the index keys its own
# file storage on it. Kept apart from `sha2_oneshot` for the same reason SHA-1
# is: no SHA-2 call site can reach it by getting an OUTPUT_SIZE wrong.
#
#   void BLAKE2B256(const uint8_t *data, size_t len,
#                   uint8_t out[BLAKE2B256_DIGEST_LENGTH]);        (blake2.h)
# -----------------------------------------------------------------------------


@always_inline
def blake2b_256_oneshot(data: Span[UInt8, _]) -> Array[UInt8, 32]:
    """One-shot BLAKE2b-256 digest via AWS-LC's BLAKE2B256() symbol."""
    var out = Array[UInt8, 32](fill=0)

    # SAFETY: AWS-LC's BLAKE2B256 reads exactly len(data) bytes from `data` and
    # writes exactly 32 bytes (BLAKE2B256_DIGEST_LENGTH) to `out`. Both buffers
    # are caller-owned for the synchronous call duration; AWS-LC retains no
    # pointer past the call. It returns void. Empty input (len=0) still writes
    # the canonical empty-message digest `0e5751c0...f12fe3a8`.
    var out_ptr = UnsafePointer(to=out[0]).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN]()
    var data_ptr = _span_ptr_mut(data)
    external_call[
        "komira_awslc_BLAKE2B256",
        NoneType,
        _FfiByte,
        UInt,
        _FfiByte,
    ](data_ptr, UInt(len(data)), out_ptr)
    return out^


# -----------------------------------------------------------------------------
# Sha2Hasher[OUTPUT_SIZE] — streaming SHA-2 family hasher.
#
# Opaque wrapper around AWS-LC's heap-allocated EVP_MD_CTX*. Single
# struct definition; OUTPUT_SIZE selects which EVP_sha*() method to
# initialize against.
#
# Conforms to the `Hash` trait (Movable + Deinitable).
# -----------------------------------------------------------------------------


struct Sha2Hasher[OUTPUT_SIZE: Int](Movable, Deinitable):
    """Streaming SHA-2 family hasher over AWS-LC's EVP_MD_CTX.

    OUTPUT_SIZE: 32 (SHA-256), 48 (SHA-384), 64 (SHA-512) — and 20 (SHA-1,
    not a SHA-2 member; a witness digest only, see the file header).

    The internal `_ctx` field holds AWS-LC's heap-allocated EVP_MD_CTX
    as `_FfiHandle` — the
    FFI-OPAQUE-HANDLE carve-out. Same shape as `AesGcmCtx._ctx` in
    aes_gcm_ffi.mojo:201.

    Movable: on move, the source's _ctx is bitcopied to the destination
    + the synthesized source __del__ is suppressed (Mojo's standard
    Movable contract). The destination's __del__ runs EVP_MD_CTX_free
    on the moved handle; no double-free.

    Non-Copyable: copying secret-bearing state is a leak. Use `fork()`
    explicitly when transcript-snapshot semantics are needed.
    """

    var _ctx: _FfiHandle
    # SAFETY: _ctx is the opaque heap-allocated EVP_MD_CTX owned by
    # AWS-LC. Allocated in __init__ via EVP_MD_CTX_new, freed in __del__
    # via EVP_MD_CTX_free. Never bitcast to typed Mojo pointer; never
    # dereferenced from Mojo code; only passed back to AWS-LC FFI sites
    # in this file. FFI-OPAQUE-HANDLE carve-out (same
    # shape as AesGcmCtx._ctx).

    def __init__(out self):
        """Allocate + initialize an EVP_MD_CTX for the OUTPUT_SIZE algorithm.

        NON-RAISING by design — the `Hash` trait's `__init__` signature
        is non-raising, so all conformers must match. AWS-LC's
        `EVP_MD_CTX_new` only returns NULL under memory exhaustion; on
        NULL we debug_assert.
        """
        comptime assert Self.OUTPUT_SIZE == 20 or Self.OUTPUT_SIZE == 32 or Self.OUTPUT_SIZE == 48 or Self.OUTPUT_SIZE == 64, "Sha2Hasher OUTPUT_SIZE must be 20 (SHA-1) / 32 / 48 / 64"
        # SAFETY: EVP_MD_CTX_new() allocates a heap CTX and returns a
        # pointer to it. We retain that pointer in self._ctx; freed in
        # __del__ via EVP_MD_CTX_free.
        self._ctx = external_call[
            "komira_awslc_EVP_MD_CTX_new", _FfiHandle
        ]()
        debug_assert(
            Int(self._ctx) != 0,
            "Sha2Hasher: EVP_MD_CTX_new returned NULL (OOM)",
        )

        # SAFETY: EVP_DigestInit_ex initializes the ctx for the given
        # EVP_MD method. ENGINE* = NULL (we pass an UnsafePointer of the
        # all-zero address via `_ffi_null()`).
        var md = _evp_md_for_size[Self.OUTPUT_SIZE]()
        var rc = external_call[
            "komira_awslc_EVP_DigestInit_ex",
            Int,
            _FfiHandle,
            _FfiHandle,
            _FfiHandle,
        ](self._ctx, md, _ffi_null())
        debug_assert(rc == 1, "Sha2Hasher: EVP_DigestInit_ex failed")

    def __init__(out self, *, _ctx: _FfiHandle):
        """Private constructor used by fork(). Caller owns the ctx pointer."""
        self._ctx = _ctx

    def update(mut self, data: Span[UInt8, _]):
        """Absorb `data` into the running digest."""
        if len(data) == 0:
            return

        # SAFETY: EVP_DigestUpdate reads exactly len(data) bytes from
        # the data pointer. Buffer is caller-owned for the synchronous
        # call; AWS-LC retains no pointer past the call.
        var data_ptr = _span_ptr_mut(data)
        var rc = external_call[
            "komira_awslc_EVP_DigestUpdate",
            Int,
            _FfiHandle,
            _FfiByte,
            UInt,
        ](self._ctx, data_ptr, UInt(len(data)))
        debug_assert(rc == 1, "Sha2Hasher: EVP_DigestUpdate failed")

    def finalize_into[o: Origin[mut=True]](
        mut self,
        dst: Span[UInt8, o],
    ):
        """Emit the final digest into `dst` (must be >= OUTPUT_SIZE bytes).

        Idempotency contract: we work on a fork-clone
        of self._ctx so calling finalize_into multiple times produces
        the same digest (load-bearing for TLS 1.3 transcript-snapshot
        flows that finalize at multiple commit points without
        consuming the running state).

        Implementation: EVP_MD_CTX_copy_ex into a stack-local clone ctx,
        run EVP_DigestFinal_ex on the clone, free the clone. self._ctx
        stays at the pre-finalize state.
        """
        debug_assert(
            len(dst) >= Self.OUTPUT_SIZE,
            "Sha2Hasher.finalize_into: dst too small",
        )

        # Allocate a clone ctx for the idempotent finalize.
        # SAFETY: EVP_MD_CTX_new + EVP_MD_CTX_copy_ex pattern is the
        # canonical AWS-LC clone-and-finalize idiom. clone_ctx is owned
        # locally; freed below before this fn returns.
        var clone_ctx = external_call[
            "komira_awslc_EVP_MD_CTX_new", _FfiHandle
        ]()
        debug_assert(
            Int(clone_ctx) != 0,
            "Sha2Hasher.finalize_into: EVP_MD_CTX_new returned NULL",
        )
        var rc = external_call[
            "komira_awslc_EVP_MD_CTX_copy_ex",
            Int,
            _FfiHandle,  # dst
            _FfiHandle,  # src
        ](clone_ctx, self._ctx)
        debug_assert(rc == 1, "Sha2Hasher.finalize_into: EVP_MD_CTX_copy_ex failed")

        # SAFETY: EVP_DigestFinal_ex writes exactly OUTPUT_SIZE bytes
        # (we know this from the EVP_MD selected at __init__) to `dst`
        # and writes 1 UInt32 to `out_len`. dst buffer is caller-owned;
        # the clone ctx is invalidated by this call (we free it next).
        var dst_ptr = _span_ptr_mut(dst)
        var out_len = UInt32(0)
        var rc2 = external_call[
            "komira_awslc_EVP_DigestFinal_ex",
            Int,
            _FfiHandle,
            _FfiByte,
            UnsafePointer[UInt32, _FFI_ORIGIN],
        ](
            clone_ctx,
            dst_ptr,
            UnsafePointer(to=out_len).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN](),
        )
        debug_assert(rc2 == 1, "Sha2Hasher.finalize_into: EVP_DigestFinal_ex failed")
        debug_assert(
            Int(out_len) == Self.OUTPUT_SIZE,
            "Sha2Hasher.finalize_into: out_len != OUTPUT_SIZE",
        )

        # Free the clone ctx; self._ctx stays untouched.
        external_call[
            "komira_awslc_EVP_MD_CTX_free",
            NoneType,
            _FfiHandle,
        ](clone_ctx)

    def fork(self) -> Self:
        """Clone the streaming hash state.

        Allocates a new EVP_MD_CTX and copies self._ctx into it via
        EVP_MD_CTX_copy_ex. The returned Self owns the clone ctx;
        original self._ctx is unchanged.

        Load-bearing for TLS 1.3 transcript-hash flow (RFC 8446 §4.3):
        snapshot the running hash at multiple commit points without
        consuming the ability to absorb more bytes.
        """
        # SAFETY: clone_ctx is owned by the returned Self; freed by
        # the clone's __del__. No double-free (original self._ctx is
        # separate heap allocation).
        var clone_ctx = external_call[
            "komira_awslc_EVP_MD_CTX_new", _FfiHandle
        ]()
        debug_assert(
            Int(clone_ctx) != 0,
            "Sha2Hasher.fork: EVP_MD_CTX_new returned NULL",
        )
        var rc = external_call[
            "komira_awslc_EVP_MD_CTX_copy_ex",
            Int,
            _FfiHandle,
            _FfiHandle,
        ](clone_ctx, self._ctx)
        debug_assert(rc == 1, "Sha2Hasher.fork: EVP_MD_CTX_copy_ex failed")
        return Self(_ctx=clone_ctx)

    def reset(mut self):
        """Reset the streaming state to empty (post-init state).

        Re-runs EVP_DigestInit_ex on self._ctx with the same EVP_MD
        method; AWS-LC clears the internal state in-place. Faster than
        free + alloc.
        """
        # SAFETY: EVP_DigestInit_ex re-initializes self._ctx in place.
        # The previous state is overwritten (AWS-LC handles internal
        # state reset).
        var md = _evp_md_for_size[Self.OUTPUT_SIZE]()
        var rc = external_call[
            "komira_awslc_EVP_DigestInit_ex",
            Int,
            _FfiHandle,
            _FfiHandle,
            _FfiHandle,
        ](self._ctx, md, _ffi_null())
        debug_assert(rc == 1, "Sha2Hasher.reset: EVP_DigestInit_ex failed")

    def __deinit__(deinit self):
        """Free the EVP_MD_CTX (AWS-LC internally zeroizes secret state).

        Matches AWS-LC's EVP_MD_CTX_new from __init__. The Movable
        contract suppresses source-side __del__ post-move; runs exactly
        once per CTX.
        """
        # SAFETY: self._ctx is the heap-allocated CTX from __init__.
        # EVP_MD_CTX_free is the matching destructor; AWS-LC clears the
        # digest state before freeing.
        if Int(self._ctx) != 0:
            external_call[
                "komira_awslc_EVP_MD_CTX_free",
                NoneType,
                _FfiHandle,
            ](self._ctx)


# -----------------------------------------------------------------------------
# Public type aliases — the names the rest of komira_crypto re-exports.
# -----------------------------------------------------------------------------


comptime Sha256Ffi = Sha2Hasher[32]
"""Streaming SHA-256 via AWS-LC. Public surface: matches `Hash` trait."""

comptime Sha384Ffi = Sha2Hasher[48]
"""Streaming SHA-384 via AWS-LC. Public surface: matches `Hash` trait."""

comptime Sha512Ffi = Sha2Hasher[64]
"""Streaming SHA-512 via AWS-LC. Public surface: matches `Hash` trait."""

comptime Sha1Ffi = Sha2Hasher[20]
"""Streaming SHA-1 via AWS-LC — a witness digest only (see the file
header). Wrapped by `komira_crypto.hash.Sha1`, which is NOT a `Hash`."""
