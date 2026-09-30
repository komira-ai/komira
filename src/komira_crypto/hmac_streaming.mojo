# =============================================================================
# komira_crypto/hmac_streaming.mojo — streaming Hmac[H: Hash] via AWS-LC FFI
# =============================================================================
#
# A thin Movable wrapper over AWS-LC's HMAC_CTX_*.
#
#   * Hmac[Sha256] / Hmac[Sha384] / Hmac[Sha512] are the public surface
#   * __init__ / update / finalize_into / fork
#   * finalize_into is idempotent (it clones the underlying HMAC_CTX via
#     HMAC_CTX_copy_ex), so a caller may finalize and keep updating.
# =============================================================================

from komira_crypto.traits import Hash
from komira_crypto.internal.asm.hmac_ffi import HmacFfiCtx


struct Hmac[H: Hash](Movable, Deinitable):
    """Streaming HMAC over any `H: Hash` conformer (RFC 2104 + FIPS 198-1).

    Backed by AWS-LC's HMAC_CTX (the same pre-fed inner+outer pattern
    the native impl hand-rolled; AWS-LC implements it internally).
    finalize_into is idempotent via HMAC_CTX_copy_ex on a fork-clone
    (load-bearing for TLS 1.3 verify_data / KeyUpdate / exporter flows).

    Non-Copyable: copying secret-bearing inner state is a leak. Use
    `fork()` explicitly for transcript-snapshot flows.
    """

    comptime OUTPUT_SIZE: Int = Self.H.OUTPUT_SIZE
    comptime BLOCK_SIZE: Int = Self.H.BLOCK_SIZE

    var _inner: HmacFfiCtx[Self.H.OUTPUT_SIZE]

    def __init__(out self, key: Span[UInt8, _]):
        """Construct an HMAC over `key`.

        AWS-LC's HMAC_Init_ex handles key normalization per RFC 2104 §2
        (hash-down if > BLOCK_SIZE; zero-pad if < BLOCK_SIZE; pre-feed
        inner+outer with K' XOR ipad/opad).
        """
        self._inner = HmacFfiCtx[Self.H.OUTPUT_SIZE](key)

    def update(mut self, data: Span[UInt8, _]):
        """Absorb `data` into the running MAC."""
        self._inner.update(data)

    def finalize_into[o: Origin[mut=True]](
        self,
        dst: Span[UInt8, o],
    ):
        """Emit the final MAC into `dst` (>= OUTPUT_SIZE bytes). Idempotent."""
        self._inner.finalize_into(dst)

    def fork(self) -> Self:
        """Clone the streaming MAC state."""
        return Self(_inner=self._inner.fork())

    def __init__(out self, *, var _inner: HmacFfiCtx[Self.H.OUTPUT_SIZE]):
        """Private ctor for fork()."""
        self._inner = _inner^
