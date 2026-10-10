# =============================================================================
# komira_crypto/internal/asm/chacha20_poly1305_ffi.mojo
# =============================================================================
#
# ChaCha20-Poly1305 AEAD via AWS-LC's EVP_AEAD API — FFI wrapper.
#
# # Why this exists
#
# The FFI-to-AWS-LC pattern of `aes_gcm_ffi.mojo` transposes mechanically
# to ChaCha20-Poly1305: the only difference vs AES-GCM is the EVP_AEAD
# method selector (`EVP_aead_chacha20_poly1305` vs
# `EVP_aead_aes_{128,256}_gcm`). A pure-Mojo composed AEAD (ChaCha20
# stream cipher + Poly1305 MAC + manual AEAD framing) is functionally
# correct (RFC 8439 §2.8.2 KATs pass) but orders of magnitude slower than
# AWS-LC's hand-tuned NEON / AVX2 ChaCha20 + Poly1305 path.
#
# # Approach: the high-level EVP_AEAD API
#
# Three approaches considered:
#   1. Low-level: ChaCha20_ctr32_neon + CRYPTO_poly1305_{init,update,finish}
#      (5+ symbols; caller orchestrates AEAD framing)
#   2. Mid-level: chacha20_poly1305_{seal,open} (AWS-LC internal direct
#      AEAD entry points; less stable across versions)
#   3. **High-level**: EVP_AEAD_CTX_{new,seal,open,free} +
#      EVP_aead_chacha20_poly1305 method selector
#
# Approach 3 is used: an identical FFI shape to AES-GCM (`AesGcmCtx`), so
# all the same encapsulation + aliasing patterns apply.
#
# # Symbols used
#
#   * EVP_aead_chacha20_poly1305 — method selector singleton
#   * EVP_AEAD_CTX_new           — allocates + initializes CTX from key
#   * EVP_AEAD_CTX_free          — clears + frees CTX
#   * EVP_AEAD_CTX_seal          — encrypt + authenticate in place
#   * EVP_AEAD_CTX_open          — verify tag + decrypt in place
#   * EVP_AEAD_CTX_open          — verify tag + decrypt in place (reused)
#
# # Encapsulation discipline
#
# Public API:
#   * ChaCha20Poly1305Ctx opaque-wrapper struct holds AWS-LC's
#     EVP_AEAD_CTX via `_FfiHandle`
#     private field. FFI-POD opaque-handle carve-out — same
#     shape as `AesGcmCtx._ctx`.
#   * Methods seal_in_place / open_in_place take typed Mojo args
#     (InlineArray + Span); FFI is internal to the method body.
#
# Internal FFI:
#   * external_call sites use `_span_ptr_mut` coercion (mirror of
#     `aes_gcm_ffi.mojo:_span_ptr_mut` — load-bearing for EVP_AEAD_CTX_
#     seal/open in==out aliasing).
#   * ZERO `unsafe_from_address`.
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
# Coercion helper: Span[UInt8, _] -> MutExternalOrigin pointer for FFI
#
# Same shape as `_span_ptr_mut` in `aes_gcm_ffi.mojo`. The MutExternalOrigin
# cast is the FFI-BOUNDARY contract: erases Mojo-side lifetime so the
# noalias inference is suppressed (required for EVP_AEAD_CTX_seal/open
# in==out aliasing).
# -----------------------------------------------------------------------------


@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce a `Span[UInt8, _]` to a `MutExternalOrigin`-cast pointer for FFI.

    # SAFETY: caller MUST hold the Span's origin (and the underlying
    # buffer it borrows from) in scope across the external_call site.
    # AWS-LC's EVP_AEAD path retains no pointer past the synchronous
    # call. Identical SAFETY contract to `_span_ptr_mut` in
    # `aes_gcm_ffi.mojo`.
    """
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


# -----------------------------------------------------------------------------
# EVP_AEAD method selector (singleton; never freed).
#
# AWS-LC returns a const-static pointer to the per-algorithm method
# struct; we hold it as an opaque _FfiHandle
# and pass it unchanged to EVP_AEAD_CTX_new.
# -----------------------------------------------------------------------------


@always_inline
def _evp_aead_chacha20_poly1305() -> _FfiHandle:
    """Return AWS-LC's ChaCha20-Poly1305 AEAD method singleton."""
    # SAFETY: AWS-LC's EVP_aead_chacha20_poly1305() returns a pointer
    # to a static const struct (lives forever in libcrypto.a's
    # .rodata). Never freed; held only as opaque handle until passed
    # back to EVP_AEAD_CTX_new. MutExternalOrigin is the FFI-POD
    # carve-out shape (matches the `EVP_aead_aes_128_gcm` precedent in
    # `aes_gcm_ffi.mojo`).
    return external_call[
        "komira_awslc_EVP_aead_chacha20_poly1305",
        _FfiHandle,
    ]()


# -----------------------------------------------------------------------------
# ChaCha20Poly1305Ctx — opaque wrapper around AWS-LC's EVP_AEAD_CTX
#
# Owns the heap-allocated CTX via _FfiHandle
# (FFI-POD opaque-handle carve-out). Constructed from a 32-byte key. Drops
# via EVP_AEAD_CTX_free which zeroizes the key + any precomputed state.
#
# Single fixed key size = 32 (no parametric KEY_SIZE — ChaCha20 has one
# key shape, unlike AES which has 128/192/256 variants).
# -----------------------------------------------------------------------------


struct ChaCha20Poly1305Ctx(Movable, Deinitable):
    """Opaque wrapper around AWS-LC's EVP_AEAD_CTX for ChaCha20-Poly1305.

    KEY_SIZE is fixed at 32 (256-bit ChaCha20 key per RFC 8439).

    The internal `_ctx` field holds AWS-LC's heap-allocated CTX as
    `_FfiHandle` — the FFI-POD
    opaque-handle carve-out. AWS-LC owns the
    heap allocation + secret-bearing state (the 32-byte key copied in
    at __init__); we hold only the opaque handle. Same shape as
    `AesGcmCtx._ctx`.

    Movable: on move, the source's _ctx is bitcopied to the destination
    + the synthesized source __del__ is suppressed (Mojo's standard
    Movable contract). The destination's __del__ runs EVP_AEAD_CTX_free
    on the moved handle; no double-free.
    """

    var _ctx: _FfiHandle
    # SAFETY: _ctx is the opaque heap-allocated EVP_AEAD_CTX owned by
    # AWS-LC. Pointer lifetime is the wrapper's lifetime: allocated in
    # __init__ via EVP_AEAD_CTX_new, freed in __del__ via
    # EVP_AEAD_CTX_free. The pointer is never bitcast to a typed Mojo
    # pointer + never dereferenced from Mojo code. Only passed back to
    # AWS-LC's EVP_AEAD_CTX_{seal,open,free} FFI sites in this file.
    # FFI-POD opaque-handle carve-out: opaque C-handle, no Mojo-side
    # heap, no aliasing concern.

    def __init__(out self, key: Span[UInt8, _]):
        """Construct an EVP_AEAD_CTX for ChaCha20-Poly1305 from a 32-byte key.

        NON-RAISING by design — the `Aead` trait's `__init__` signature
        is non-raising, so all conformers must match. AWS-LC's
        `EVP_AEAD_CTX_new` only returns NULL under memory exhaustion or
        invalid args (key_len != 32 / tag_len != 16). For valid args +
        non-OOM conditions this is a process-level invariant; on NULL
        we debug_assert (which aborts in debug builds + becomes a NULL
        pointer + downstream FFI failure in release).
        """
        debug_assert(
            len(key) == 32,
            "ChaCha20Poly1305Ctx: key length must be 32 (256 bits)",
        )

        var method = _evp_aead_chacha20_poly1305()

        # SAFETY: EVP_AEAD_CTX_new reads 32 bytes from key_ptr (the key
        # material) and allocates a heap CTX, returning a pointer to
        # it. Key buffer (`key: Span[UInt8, _]`) is caller-owned for
        # the duration of this synchronous call; AWS-LC copies the key
        # into the CTX and retains no pointer past the call. key_ptr
        # cast to MutExternalOrigin via _span_ptr_mut (canonical
        # FFI-boundary shape).
        var key_ptr = _span_ptr_mut(key)
        self._ctx = external_call[
            "komira_awslc_EVP_AEAD_CTX_new",
            _FfiHandle,
            _FfiHandle,  # method
            _FfiByte,     # key
            UInt,                                         # key_len
            UInt,                                         # tag_len
        ](
            method,
            key_ptr,
            UInt(32),
            UInt(16),  # tag_len = 16 (full 128-bit Poly1305 tag per RFC 8439)
        )
        debug_assert(
            Int(self._ctx) != 0,
            "ChaCha20Poly1305Ctx: EVP_AEAD_CTX_new returned NULL (OOM"
            " / invalid args)",
        )

    @always_inline
    def seal_in_place[o: Origin[mut=True]](
        self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        plaintext_then_tag: Span[UInt8, o],
    ) raises:
        """Seal in place via EVP_AEAD_CTX_seal (RFC 8439 §2.8).

        `plaintext_then_tag` layout:
          [plaintext (N - 16 bytes)][tag (16 bytes uninitialized)]
        Post-call: plaintext replaced with ciphertext; tag region
        filled with the 16-byte Poly1305 auth tag.

        Implementation: passes the same pointer for both in and out
        (the aliasing semantic AWS-LC explicitly permits). AWS-LC's
        internal body runs `ChaCha20_ctr32_neon` for the stream
        encryption + NEON-accelerated Poly1305 for the MAC.

        Raises:
          - "ChaCha20Poly1305: buffer too small" if buffer < 16 bytes.
          - "ChaCha20Poly1305.seal_in_place: EVP_AEAD_CTX_seal failed"
            on AWS-LC error (should not occur for valid args).
        """
        var total = len(plaintext_then_tag)
        if total < 16:
            raise Error(
                "ChaCha20Poly1305.seal_in_place: buffer too small (<"
                " TAG_SIZE)"
            )
        var pt_len = total - 16

        var out_len = UInt(0)

        # In/out aliasing: same pointer for both. MutExternalOrigin
        # coercion suppresses Mojo's noalias inference (required —
        # without it, the compiler rejects in==out as aliased writable
        # arguments).
        var buf_ptr = _span_ptr_mut(plaintext_then_tag)
        var nonce_span = Span[UInt8, origin_of(nonce)](nonce)
        var nonce_ptr = _span_ptr_mut(nonce_span)

        # AAD pointer: when ad_len=0 AWS-LC reads zero bytes, so the
        # pointer value is unused. We pass `buf_ptr` as a safe non-null
        # dummy (Mojo 1.0.0b1 deprecated `UnsafePointer[T]()` null ctor).
        var aad_ptr: _FfiByte
        if len(aad) == 0:
            aad_ptr = buf_ptr
        else:
            aad_ptr = _span_ptr_mut(aad)

        # SAFETY: EVP_AEAD_CTX_seal contract:
        #   - reads `pt_len` bytes from `buf_ptr` (plaintext)
        #   - reads 12 bytes from `nonce_ptr` (nonce)
        #   - reads `len(aad)` bytes from `aad_ptr` (AAD; may be NULL+0)
        #   - writes `pt_len + 16` bytes to `buf_ptr` (ciphertext || tag)
        #   - writes 1 UInt to `out_len` ptr (the actual output length)
        #   - aliasing: `in == out` explicitly permitted when buffers
        #     are exactly equal (NOT partially overlapping)
        # All buffers caller-owned for the synchronous call duration;
        # AWS-LC retains no pointer past the call. MutExternalOrigin
        # coercion via _span_ptr_mut suppresses Mojo's noalias inference
        # so the in==out alias is accepted.
        var rc = external_call[
            "komira_awslc_EVP_AEAD_CTX_seal",
            Int,
            _FfiHandle,  # ctx
            _FfiByte,     # out
            UnsafePointer[UInt, _FFI_ORIGIN],      # out_len
            UInt,                                         # max_out_len
            _FfiByte,     # nonce
            UInt,                                         # nonce_len
            _FfiByte,     # in
            UInt,                                         # in_len
            _FfiByte,     # ad
            UInt,                                         # ad_len
        ](
            self._ctx,
            buf_ptr,
            UnsafePointer(to=out_len).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN](),
            UInt(pt_len + 16),
            nonce_ptr,
            UInt(12),
            buf_ptr,
            UInt(pt_len),
            aad_ptr,
            UInt(len(aad)),
        )
        if rc != 1:
            raise Error(  # cov: unreachable seal fails only on arguments fixed here (key, nonce, tag sizes) or a plaintext of hundreds of GiB
                "ChaCha20Poly1305.seal_in_place: EVP_AEAD_CTX_seal failed"
            )

    @always_inline
    def open_in_place[o: Origin[mut=True]](
        self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        ciphertext_then_tag: Span[UInt8, o],
    ) raises:
        """Verify-and-decrypt in place via EVP_AEAD_CTX_open (RFC 8439 §2.8).

        `ciphertext_then_tag` layout:
          [ciphertext (N - 16 bytes)][tag (16 bytes)]
        Post-success: ciphertext replaced with plaintext.
        Post-failure: RAISES; AWS-LC zeros the output region on failure
        (per AWS-LC contract).

        AWS-LC performs verify-then-decrypt order (the AEAD contract): it
        recomputes the Poly1305 MAC over the ciphertext + AAD +
        lengths, constant-time-compares against the transmitted tag,
        and ONLY emits plaintext on auth success.

        Raises:
          - "ChaCha20Poly1305: buffer too small" if buffer < 16 bytes.
          - "ChaCha20Poly1305.open_in_place: authentication failure"
            on tag mismatch.
        """
        var total = len(ciphertext_then_tag)
        if total < 16:
            raise Error(
                "ChaCha20Poly1305.open_in_place: buffer too small (<"
                " TAG_SIZE)"
            )
        var ct_with_tag_len = total  # in_len passed to EVP_AEAD_CTX_open
        var pt_len = total - 16      # max_out_len

        var out_len = UInt(0)
        var buf_ptr = _span_ptr_mut(ciphertext_then_tag)
        var nonce_span = Span[UInt8, origin_of(nonce)](nonce)
        var nonce_ptr = _span_ptr_mut(nonce_span)

        # See seal_in_place: ad_len=0 lets AWS-LC skip the AAD read; pass
        # `buf_ptr` as a safe non-null dummy.
        var aad_ptr: _FfiByte
        if len(aad) == 0:
            aad_ptr = buf_ptr
        else:
            aad_ptr = _span_ptr_mut(aad)

        # SAFETY: EVP_AEAD_CTX_open contract:
        #   - reads `ct_with_tag_len` bytes from `buf_ptr` (ciphertext || tag)
        #   - reads 12 bytes from `nonce_ptr` (nonce)
        #   - reads `len(aad)` bytes from `aad_ptr` (AAD; may be NULL+0)
        #   - writes `pt_len` bytes to `buf_ptr` (plaintext, ONLY on
        #     auth success; on failure writes zeros)
        #   - writes 1 UInt to `out_len` ptr
        #   - aliasing: in == out explicitly permitted (strict equality)
        # All buffers caller-owned; AWS-LC retains no pointer past the
        # call. MutExternalOrigin coercion suppresses noalias inference.
        var rc = external_call[
            "komira_awslc_EVP_AEAD_CTX_open",
            Int,
            _FfiHandle,
            _FfiByte,
            UnsafePointer[UInt, _FFI_ORIGIN],
            UInt,
            _FfiByte,
            UInt,
            _FfiByte,
            UInt,
            _FfiByte,
            UInt,
        ](
            self._ctx,
            buf_ptr,
            UnsafePointer(to=out_len).unsafe_mut_cast[False]().unsafe_origin_cast[_FFI_ORIGIN](),
            UInt(pt_len),
            nonce_ptr,
            UInt(12),
            buf_ptr,
            UInt(ct_with_tag_len),
            aad_ptr,
            UInt(len(aad)),
        )
        if rc != 1:
            raise Error(
                "ChaCha20Poly1305.open_in_place: authentication failure"
            )

    def __deinit__(deinit self):
        """Free AWS-LC's EVP_AEAD_CTX (zeroizes secret-bearing state).

        AWS-LC's EVP_AEAD_CTX_free internally clears the stored key
        + any precomputed Poly1305-init state before freeing the heap
        allocation. No additional zeroize.mojo helper needed.
        """
        # SAFETY: self._ctx is the heap-allocated CTX from __init__'s
        # EVP_AEAD_CTX_new. AWS-LC's EVP_AEAD_CTX_free is the matching
        # destructor; safe to call exactly once per CTX. The Movable
        # contract suppresses source-side __del__ after a move, so this
        # runs exactly once per CTX even across moves.
        if Int(self._ctx) != 0:
            external_call[
                "komira_awslc_EVP_AEAD_CTX_free",
                NoneType,
                _FfiHandle,
            ](self._ctx)
