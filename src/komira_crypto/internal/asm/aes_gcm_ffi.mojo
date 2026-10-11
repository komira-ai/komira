# =============================================================================
# komira_crypto/internal/asm/aes_gcm_ffi.mojo
# =============================================================================
#
# AES-GCM via AWS-LC's EVP_AEAD API — FFI wrapper.
#
# # Why this exists
#
# A scalar AES + bit-by-bit GHASH path is functionally correct (NIST SP
# 800-38D KATs pass) but orders of magnitude slower than AWS-LC's
# hand-tuned `aes_hw_*` + `gcm_*_neon` (or AES-NI + PCLMULQDQ) path. This
# file delegates to AWS-LC's high-level EVP_AEAD API, which internally
# dispatches to that hand-tuned path.
#
# # Approach: the high-level EVP_AEAD API
#
# Three approaches were considered:
#   1. Low-level: aes_hw_set_encrypt_key + aes_hw_encrypt + gcm_init_neon
#      + gcm_ghash_neon (4-6 symbols; max control, min perf gain)
#   2. Mid-level: CRYPTO_gcm128_* / aesni_gcm_encrypt (AWS-LC internal)
#   3. **High-level**: EVP_AEAD_CTX_{new,seal,open,free} + method selectors
#      EVP_aead_aes_128_gcm / EVP_aead_aes_256_gcm.
#
# Approach 3 is used: the smallest FFI surface, the same body AWS-LC's own
# bench tools use (so guaranteed perf parity), and a public API that is
# stable across AWS-LC versions.
#
# # Symbols used
#
#   * EVP_aead_aes_128_gcm    — method selector for AES-128-GCM (singleton)
#   * EVP_aead_aes_256_gcm    — method selector for AES-256-GCM (singleton)
#   * EVP_AEAD_CTX_new        — allocates + initializes a CTX from a key
#   * EVP_AEAD_CTX_free       — clears + frees a CTX (zeroizes secret material)
#   * EVP_AEAD_CTX_seal       — encrypt + authenticate in place (aliasing OK)
#   * EVP_AEAD_CTX_open       — verify tag + decrypt in place (aliasing OK)
#
# # C signatures (from AWS-LC's include/openssl/aead.h)
#
#   const EVP_AEAD *EVP_aead_aes_128_gcm(void);
#   const EVP_AEAD *EVP_aead_aes_256_gcm(void);
#
#   EVP_AEAD_CTX *EVP_AEAD_CTX_new(const EVP_AEAD *aead,
#                                  const uint8_t *key, size_t key_len,
#                                  size_t tag_len);
#   void EVP_AEAD_CTX_free(EVP_AEAD_CTX *ctx);
#
#   int EVP_AEAD_CTX_seal(const EVP_AEAD_CTX *ctx, uint8_t *out,
#                         size_t *out_len, size_t max_out_len,
#                         const uint8_t *nonce, size_t nonce_len,
#                         const uint8_t *in, size_t in_len,
#                         const uint8_t *ad, size_t ad_len);
#   int EVP_AEAD_CTX_open(...same shape as seal...);
#
# Both seal + open: "If in and out alias then out must be == in." This
# is the in-place semantic we exploit (same pointer for both arguments).
#
# # Architecture: why one FFI call per record beats Mojo's scalar loop
#
# A scalar Mojo path for a 16 KB TLS record:
#   * 1024 AES-128 single-block encrypts (one per 16-byte CTR block)
#   * Each: ~200+ scalar ops (S-box LUT + ShiftRows + MixColumns + AddRK x 10)
#   * 1024 GHASH multiplications, each 128 x bit-by-bit shift-XOR (16K ops)
#   * Combined: ~2M ops + 16M GHASH ops per record
#
# Via this FFI:
#   * ONE FFI call (~30-50 ns dispatch overhead)
#   * AWS-LC's internal C body: `aes_hw_ctr32_encrypt_blocks` (hardware
#     aese/aesmc per round, multi-block parallel pipelines) + `gcm_ghash_neon`
#     (pmull64-based polynomial multiply, 128 bits per instruction)
#   * Combined: ~5-10 microseconds for the full record
#
# # Encapsulation discipline
#
# Public API:
#   * AesGcmCtx[KEY_SIZE] opaque-wrapper struct holds the EVP_AEAD_CTX
#     via `_FfiHandle` private field. This
#     is the FFI-POD opaque-handle carve-out
#     (`_FfiHandle` holding the EVP_AEAD_CTX*).
#   * Methods seal_in_place / open_in_place take typed Mojo arguments
#     (InlineArray + Span); FFI is internal to the method body.
#
# Internal FFI:
#   * external_call sites use the `MutExternalOrigin` shape via
#     `unsafe_origin_cast[_FFI_ORIGIN]()` (the `_span_ptr` pattern below).
#     This is the FFI-boundary shape that suppresses Mojo's
#     noalias inference (load-bearing for EVP_AEAD_CTX_seal/open which
#     pass the same pointer for in + out per the AWS-LC aliasing semantic).
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
# The `_span_ptr` FFI-boundary pattern.
# The MutExternalOrigin cast is the FFI-BOUNDARY contract: the resulting
# pointer's Mojo-side lifetime is erased; aliasing inference is suppressed
# (required for EVP_AEAD_CTX_seal/open in==out aliasing).
# -----------------------------------------------------------------------------


@always_inline
def _span_ptr_mut(s: Span[UInt8, _]) -> _FfiByte:
    """Coerce a `Span[UInt8, _]` to a `MutExternalOrigin`-cast pointer for FFI.

    The unsafe_mut_cast[True]() step lifts an immutable-origin span to
    mutable; the unsafe_origin_cast[_FFI_ORIGIN]() step erases
    the Mojo-side lifetime annotation (required to bind into an FFI
    arg signature typed `_FfiByte`).

    # SAFETY: caller MUST hold the Span's origin (and the underlying
    # buffer it borrows from) in scope across the external_call site.
    # AWS-LC's EVP_AEAD path retains no pointer past the synchronous
    # call.
    """
    return (
        s.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[_FFI_ORIGIN]()
    )


# -----------------------------------------------------------------------------
# EVP_AEAD method selectors (singletons; never freed).
#
# AWS-LC returns a const-static pointer to the per-algorithm method
# struct; we hold it as an opaque _FfiHandle
# and pass it unchanged to EVP_AEAD_CTX_new.
# -----------------------------------------------------------------------------


@always_inline
def _evp_aead_aes_128_gcm() -> _FfiHandle:
    """Return AWS-LC's AES-128-GCM method singleton."""
    # SAFETY: AWS-LC's EVP_aead_aes_128_gcm() returns a pointer to a
    # static const struct (lives forever in libcrypto.a's .rodata).
    # Never freed; held only as opaque handle until passed back to
    # EVP_AEAD_CTX_new. MutExternalOrigin is the FFI-POD carve-out
    # shape for a static library-owned handle.
    return external_call[
        "komira_awslc_EVP_aead_aes_128_gcm", _FfiHandle
    ]()


@always_inline
def _evp_aead_aes_256_gcm() -> _FfiHandle:
    """Return AWS-LC's AES-256-GCM method singleton."""
    # SAFETY: Same as _evp_aead_aes_128_gcm above.
    return external_call[
        "komira_awslc_EVP_aead_aes_256_gcm", _FfiHandle
    ]()


# -----------------------------------------------------------------------------
# AesGcmCtx — opaque wrapper around AWS-LC's EVP_AEAD_CTX
#
# Owns the heap-allocated CTX via _FfiHandle
# (FFI-POD opaque-handle carve-out). Constructed from a key; the CTX expands
# the key schedule + computes GHASH H internally. Drops via EVP_AEAD_CTX_free
# which zeroizes the secret-bearing internal state.
# -----------------------------------------------------------------------------


struct AesGcmCtx[KEY_SIZE: Int](Movable, Deinitable):
    """Opaque wrapper around AWS-LC's EVP_AEAD_CTX for AES-GCM.

    KEY_SIZE must be 16 (AES-128-GCM) or 32 (AES-256-GCM).

    The internal `_ctx` field holds AWS-LC's heap-allocated CTX as
    `_FfiHandle` — the FFI-POD
    opaque-handle carve-out. AWS-LC owns the
    heap allocation + secret-bearing state (expanded key schedule +
    GHASH H table); we hold only the opaque handle.

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
    # AWS-LC's EVP_AEAD_CTX_seal / EVP_AEAD_CTX_open / EVP_AEAD_CTX_free
    # FFI sites in this file. This is the FFI-POD opaque-handle
    # carve-out: opaque C-handle, no Mojo-side heap, no aliasing concern.

    def __init__(out self, key: Span[UInt8, _]):
        """Construct an EVP_AEAD_CTX for AES-{128,256}-GCM from a key.

        NON-RAISING by design — the `Aead` trait's `__init__` signature
        is non-raising, so all conformers must match. AWS-LC's
        `EVP_AEAD_CTX_new` only returns NULL under memory exhaustion or
        invalid args (KEY_SIZE / tag_len). For valid args + non-OOM
        conditions this is a process-level invariant; on NULL we
        debug_assert (which aborts in debug builds + becomes a NULL
        pointer + downstream FFI failure in release).

        Callers that want raise-on-OOM semantics can use the
        `try_init` factory method (not implemented yet).
        """
        comptime assert Self.KEY_SIZE == 16 or Self.KEY_SIZE == 32, "AesGcmCtx KEY_SIZE must be 16 (AES-128-GCM) or 32 (AES-256-GCM)"
        debug_assert(
            len(key) == Self.KEY_SIZE,
            "AesGcmCtx: key length must match KEY_SIZE",
        )

        # Select method singleton based on KEY_SIZE (comptime).
        var method: _FfiHandle
        comptime if Self.KEY_SIZE == 16:
            method = _evp_aead_aes_128_gcm()
        else:
            # KEY_SIZE == 32 by constrained[] above.
            method = _evp_aead_aes_256_gcm()

        # SAFETY: EVP_AEAD_CTX_new reads KEY_SIZE bytes from key_ptr
        # (the key material) and allocates a heap CTX, returning a
        # pointer to it. Key buffer (`key: Span[UInt8, _]`) is
        # caller-owned for the duration of this synchronous call; AWS-LC
        # copies the key into the CTX and retains no pointer past the
        # call. key_ptr cast to MutExternalOrigin via _span_ptr_mut
        # (canonical FFI-boundary shape).
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
            UInt(Self.KEY_SIZE),
            UInt(16),  # tag_len = 16 (full 128-bit GCM tag per RFC 5116)
        )
        debug_assert(
            Int(self._ctx) != 0,
            "AesGcmCtx: EVP_AEAD_CTX_new returned NULL (OOM / invalid args)",
        )

    @always_inline
    def seal_in_place[o: Origin[mut=True]](
        self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        plaintext_then_tag: Span[UInt8, o],
    ) raises:
        """Seal in place via EVP_AEAD_CTX_seal.

        `plaintext_then_tag` layout (NIST SP 800-38D §7.1):
          [plaintext (N - 16 bytes)][tag (16 bytes uninitialized)]
        Post-call: plaintext replaced with ciphertext; tag region
        filled with the 16-byte AES-GCM auth tag.

        Implementation: passes the same pointer for both in and out
        (the aliasing semantic AWS-LC explicitly permits in
        EVP_AEAD_CTX_seal's contract). AWS-LC's internal body runs
        `aes_hw_ctr32_encrypt_blocks` for CTR-mode encryption then
        `gcm_ghash_neon` (or equivalent) for the GHASH MAC, both via
        hand-tuned AArch64 NEON / x86 AES-NI + PCLMULQDQ.

        Raises:
          - "AesGcm: buffer too small" if len(plaintext_then_tag) < 16.
          - "AesGcm.seal_in_place: EVP_AEAD_CTX_seal failed" if AWS-LC
            returns nonzero failure (should not occur for valid args).
        """
        var total = len(plaintext_then_tag)
        if total < 16:
            raise Error("AesGcm.seal_in_place: buffer too small (< TAG_SIZE)")
        var pt_len = total - 16

        # Out-len receiver (AWS-LC writes the actual output length here).
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
        # When ad_len > 0 we pass the real AAD pointer.
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
        # AWS-LC retains no pointer past the call. The MutExternalOrigin
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
            raise Error("AesGcm.seal_in_place: EVP_AEAD_CTX_seal failed")  # cov: unreachable seal fails only on arguments fixed here (key, nonce, tag sizes) or a plaintext of tens of GiB

    @always_inline
    def open_in_place[o: Origin[mut=True]](
        self,
        nonce: Array[UInt8, 12],
        aad: Span[UInt8, _],
        ciphertext_then_tag: Span[UInt8, o],
    ) raises:
        """Verify-and-decrypt in place via EVP_AEAD_CTX_open.

        `ciphertext_then_tag` layout (NIST SP 800-38D §7.2):
          [ciphertext (N - 16 bytes)][tag (16 bytes)]
        Post-success: ciphertext replaced with plaintext; tag region
        is implementation-defined garbage.
        Post-failure: RAISES; AWS-LC zeros the output region on failure
        (per AWS-LC contract — "If any error occurs, out will be
        filled with zero bytes").

        AWS-LC's EVP_AEAD_CTX_open performs verify-then-decrypt order
        (the AEAD contract): it recomputes the GHASH MAC over the ciphertext
        + AAD + lengths, constant-time-compares against the transmitted
        tag, and ONLY emits plaintext on auth success.

        Raises:
          - "AesGcm: buffer too small" if len(ciphertext_then_tag) < 16.
          - "AesGcm.open_in_place: authentication failure" on tag mismatch
            (the canonical error for malleability oracle prevention).
        """
        var total = len(ciphertext_then_tag)
        if total < 16:
            raise Error("AesGcm.open_in_place: buffer too small (< TAG_SIZE)")
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
            raise Error("AesGcm.open_in_place: authentication failure")

    def __deinit__(deinit self):
        """Free AWS-LC's EVP_AEAD_CTX (zeroizes secret-bearing state).

        AWS-LC's EVP_AEAD_CTX_free internally clears the expanded key
        schedule + GHASH H + any other secret material before freeing
        the heap allocation. No additional zeroize.mojo helper needed.
        """
        # SAFETY: self._ctx is the heap-allocated CTX from __init__'s
        # EVP_AEAD_CTX_new. AWS-LC's EVP_AEAD_CTX_free is the matching
        # destructor; safe to call exactly once per CTX. The Movable
        # contract suppresses source-side __del__ after a move, so this
        # runs exactly once per CTX even across moves.
        # Null-check uses `Int(ptr) == 0`.
        if Int(self._ctx) != 0:
            external_call[
                "komira_awslc_EVP_AEAD_CTX_free",
                NoneType,
                _FfiHandle,
            ](self._ctx)
