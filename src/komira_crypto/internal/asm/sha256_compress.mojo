# =============================================================================
# komira_crypto/internal/asm/sha256_compress.mojo
# =============================================================================
#
# SHA-256 compression body — FFI wrapper to AWS-LC's hand-tuned
# `sha256_block_data_order_hw` symbol from libcrypto (from OpenSSL via
# AWS-LC; Apache 2.0 / OpenSSL dual licensed).
#
# # Why FFI rather than inline assembly
#
# Issuing the SHA-256 instructions from Mojo as per-quad-round inline-asm
# sites, even in AWS-LC's canonical instruction order, leaves SHA-256
# several times slower than AWS-LC: per-asm-site setup moves, register
# allocation across sites, and an out-of-order core's preference for long
# straight-line scheduling windows form a structural ceiling. Calling
# AWS-LC's hand-tuned assembly through FFI removes that ceiling.
#
# # Symbol used
#
# `sha256_block_data_order_hw` — the hardware-SHA path within AWS-LC's
# SHA-256 (AArch64 SHA2 extensions / x86-64 SHA-NI). C signature (from
# AWS-LC's crypto/fipsmodule/sha/sha256.c):
#
#   void sha256_block_data_order_hw(uint32_t state[8], const uint8_t *data,
#                                    size_t num);
#
# Where `num` is the number of 64-byte blocks. Reads `num * 64` bytes
# from `data`; updates `state[0..7]` (32 bytes) in place.
#
# On AArch64, the symbol's body carries AWS-LC's canonical NEON
# pipelining — sha256su0 BEFORE the sha256h.4s/sha256h2.4s pair,
# sha256su1 AFTER — inside a single contiguous function body that the
# core's instruction window can fully see.
#
# # Architecture: why one FFI call beats per-block looping
#
# A per-block (or per-round) loop in Mojo pays a setup cost per block:
# 1 MB of input is ~16384 blocks. Instead, ONE FFI call passes the full
# multi-block span; AWS-LC's internal loop runs all iterations inside
# `sha256_block_data_order_hw`, with static vector-register allocation
# across the entire compress (no per-iteration mov-to-output overhead).
#
# # Build wiring
#
# The `external_call["komira_crypto_sha256_block_data_order_hw", ...]`
# decl below is a symbol REFERENCE; it is resolved at the FINAL LINK of any
# consumer binary (test or production). The name is this package's C
# wrapper (`native/komira_crypto_sha256_hw.c`, the `cxx_library`
# `:komira_crypto_sha256_hw`), which calls aws-lc's function, renamed
# `komira_awslc_sha256_block_data_order_hw` like every aws-lc symbol. aws-lc
# declares that function `.hidden`, so only a wrapper can export it from a
# shared object. The wrapper and aws-lc's libcrypto are dependencies of this
# package.
#
# # Encapsulation discipline
#
# Public API:
#   * `sha256_compress_blocks(mut state, blocks)` takes
#     `mut InlineArray[UInt32, 8]` + `Span[UInt8, _]` — ZERO UnsafePointer
#     in the public signature.
# Internal FFI:
#   * The `external_call["komira_crypto_sha256_block_data_order_hw", ...]`
#     site uses `UnsafePointer(to=...)` with inferred origin (NOT MutAnyOrigin —
#     no wildcard widening), then `bitcast` to re-type. Same shape as
#     `zeroize.mojo`'s `external_call["memset_s", Int]`
#     site (the established in-tree FFI pattern for non-libcrypto symbols
#     in this package).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO ArcPointer.
#   * The external_call site carries a multi-line `# SAFETY:` comment.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer


# -----------------------------------------------------------------------------
# Public wrapper — sha256_compress_blocks.
#
# Internal FFI invocation: AWS-LC's sha256_block_data_order_hw from
# libcrypto.a, through the wrapper komira_crypto_sha256_block_data_order_hw
# (see "Build wiring" above). The Mojo `external_call` site receives untyped-origin
# pointers (inferred from `state` + `blocks`); Mojo resolves the call at
# AOT link time. The linker needs libcrypto from aws-lc, which is why it
# is a dependency of this package.
# -----------------------------------------------------------------------------


@always_inline
def sha256_compress_blocks(
    mut state: Array[UInt32, 8],
    blocks: Span[UInt8, _],
):
    """Compress one or more 64-byte blocks into `state` via AWS-LC's
    `sha256_block_data_order_hw` (AArch64 hardware NEON path).

    Args:
        state: 8 × UInt32 SHA-256 state (FIPS 180-4 H[0..7]). Updated
               in place — caller pre-loads with either the FIPS 180-4
               initial vector (for a fresh hash) or with the running
               state from prior `update()` calls.
        blocks: Input data; `len(blocks)` MUST be a multiple of 64.
                Function silently no-ops if `len(blocks) == 0`.

    Endianness: AWS-LC reads bytes in big-endian word order internally
    (rev32.16b at function entry). Caller passes raw bytes as-is.

    No allocation, no copy. Single FFI call to AWS-LC.

    Performance: matches AWS-LC's `SHA256()` byte-identically because
    this IS the AWS-LC compress body. The ratio vs AWS-LC's full
    `SHA256(data, len, out)` differs only by the (small) per-call
    setup/finalize cost in SHA256() that this function bypasses.
    """
    var num_blocks = len(blocks) // 64
    debug_assert(
        len(blocks) == num_blocks * 64,
        "sha256_compress_blocks: blocks length must be a multiple of 64",
    )
    if num_blocks == 0:
        return

    # SAFETY: AWS-LC's `sha256_block_data_order_hw` reads exactly
    # `num_blocks * 64` bytes from the `blocks` pointer (rev32.16b at
    # function entry, then per-block compression) and writes exactly 8 ×
    # UInt32 (32 bytes) through the `state` pointer. Both buffers are
    # caller-owned for the duration of this synchronous call; AWS-LC
    # retains no pointer past the call.
    #
    # Pointers are constructed via `UnsafePointer(to=x).bitcast[T]()`
    # following the in-package pattern in `zeroize.mojo`
    # (e.g. `UnsafePointer(to=a).bitcast[UInt8]()` into memset_s). Origin
    # is INFERRED from the local `state` and the `blocks` span — NOT a
    # wildcard widening. The local pointers do not escape this function
    # body and are passed directly to the external_call below.
    #
    # The external_call typed-args list is OMITTED so Mojo infers from
    # the value types (same shape as zeroize.mojo's memset_s call);
    # alternative form with explicit type parameters would force a
    # specific origin which is incompatible with `blocks: Span[UInt8, _]`
    # potentially having immutable origin).
    external_call["komira_crypto_sha256_block_data_order_hw", NoneType](
        UnsafePointer(to=state[0]).bitcast[UInt32](),
        blocks.unsafe_ptr().bitcast[UInt8](),
        UInt(num_blocks),
    )
