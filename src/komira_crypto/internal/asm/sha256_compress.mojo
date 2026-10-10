# =============================================================================
# komira_crypto/internal/asm/sha256_compress.mojo
# =============================================================================
#
# SHA-256 compression body — FFI wrapper to AWS-LC's hand-tuned
# `sha256_block_data_order_hw` (SHA extensions) and
# `sha256_block_data_order_nohw` (portable) bodies from libcrypto (from
# OpenSSL via AWS-LC; Apache 2.0 / OpenSSL dual licensed).
#
# # CPU-feature dispatch
#
# The hardware body executes the x86-64 SHA extensions and dies with SIGILL
# on a CPU without them. `sha256_compress_blocks` therefore calls
# `komira_crypto_sha256_block_data_order`, which reads CPUID once (cached)
# and runs the hardware body only when the CPU has the extensions, the
# portable body otherwise. `sha256_compress_blocks_portable` always runs the
# portable body, so a test can check it on a host that has the extensions;
# `sha256_compress_uses_hw` reports which body the dispatch picks.
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
# # Symbols used
#
# `sha256_block_data_order_hw` — the hardware-SHA path within AWS-LC's
# SHA-256 (x86-64 SHA extensions) — and `sha256_block_data_order_nohw`, the
# portable path. C signature of both (from AWS-LC's
# crypto/fipsmodule/sha/internal.h):
#
#   void sha256_block_data_order_hw(uint32_t state[8], const uint8_t *data,
#                                    size_t num);
#
# Where `num` is the number of 64-byte blocks. Reads `num * 64` bytes
# from `data`; updates `state[0..7]` (32 bytes) in place.
#
# # Architecture: why one FFI call beats per-block looping
#
# A per-block (or per-round) loop in Mojo pays a setup cost per block:
# 1 MB of input is ~16384 blocks. Instead, ONE FFI call passes the full
# multi-block span; AWS-LC's internal loop runs all iterations inside
# the block body, with static vector-register allocation
# across the entire compress (no per-iteration mov-to-output overhead).
#
# # Build wiring
#
# The `external_call["komira_crypto_sha256_block_data_order", ...]` and
# `external_call["komira_crypto_sha256_block_data_order_nohw", ...]` decls
# below are symbol REFERENCES; each is resolved at the FINAL LINK of any
# consumer binary (test or production). The names are this package's C
# wrappers (`native/komira_crypto_sha256_hw.c`, the `cxx_library`
# `:komira_crypto_sha256_hw`), which call aws-lc's functions, renamed
# `komira_awslc_sha256_block_data_order_{hw,nohw}` like every aws-lc symbol.
# aws-lc declares those functions `.hidden`, so only a wrapper can export
# them from a shared object. The wrapper and aws-lc's libcrypto are dependencies of this
# package.
#
# # Encapsulation discipline
#
# Public API:
#   * `sha256_compress_blocks(mut state, blocks)` and
#     `sha256_compress_blocks_portable(mut state, blocks)` take
#     `mut Array[UInt32, 8]` + `Span[UInt8, _]` — ZERO UnsafePointer
#     in the public signature; `sha256_compress_uses_hw()` returns a Bool.
# Internal FFI:
#   * The block `external_call` sites use `UnsafePointer(to=...)` with inferred origin (NOT MutAnyOrigin —
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
# Public wrappers.
#
# Internal FFI invocation: the package's C wrappers around AWS-LC's block
# bodies (see "Build wiring" above). The `external_call` sites receive
# inferred-origin pointers (from `state` + `blocks`); Mojo resolves the calls
# at AOT link time against the wrapper library and AWS-LC's libcrypto.
# -----------------------------------------------------------------------------


@always_inline
def _block_count(blocks: Span[UInt8, _]) -> Int:
    var num_blocks = len(blocks) // 64
    debug_assert(
        len(blocks) == num_blocks * 64,
        "sha256_compress_blocks: blocks length must be a multiple of 64",
    )
    return num_blocks


def sha256_compress_uses_hw() -> Bool:
    """True when `sha256_compress_blocks` runs AWS-LC's SHA-extension body
    (the CPU has the x86-64 SHA extensions), False when it runs the portable
    body."""
    # SAFETY: a nullary C function that reads CPUID once and caches the
    # answer in a static int; it takes and retains no pointer.
    return external_call["komira_crypto_sha256_hw_capable", Int32]() != 0


@always_inline
def sha256_compress_blocks(
    mut state: Array[UInt32, 8],
    blocks: Span[UInt8, _],
):
    """Compress one or more 64-byte blocks into `state` with AWS-LC's
    SHA-256 block body: the SHA-extension body when the CPU has the
    extensions (`sha256_compress_uses_hw()`), the portable body otherwise.

    Args:
        state: 8 × UInt32 SHA-256 state (FIPS 180-4 H[0..7]). Updated
               in place — caller pre-loads with either the FIPS 180-4
               initial vector (for a fresh hash) or with the running
               state from prior `update()` calls.
        blocks: Input data; `len(blocks)` MUST be a multiple of 64.
                Function silently no-ops if `len(blocks) == 0`.

    Endianness: AWS-LC reads bytes in big-endian word order internally.
    Caller passes raw bytes as-is.

    No allocation, no copy. Single FFI call to AWS-LC.
    """
    var num_blocks = _block_count(blocks)
    if num_blocks == 0:
        return

    # SAFETY: the C wrapper (and the AWS-LC body it picks) reads exactly
    # `num_blocks * 64` bytes from the `blocks` pointer and writes exactly
    # 8 × UInt32 (32 bytes) through the `state` pointer. Both buffers are
    # caller-owned for the duration of this synchronous call; neither the
    # wrapper nor AWS-LC retains a pointer past the call.
    #
    # Pointers are constructed via `UnsafePointer(to=x).bitcast[T]()`
    # following the in-package pattern in `zeroize.mojo`. Origin is
    # INFERRED from the local `state` and the `blocks` span — NOT a
    # wildcard widening. The pointers do not escape this function body.
    # The typed-args list is omitted so Mojo infers from the value types
    # (`blocks: Span[UInt8, _]` may have an immutable origin).
    external_call["komira_crypto_sha256_block_data_order", NoneType](
        UnsafePointer(to=state[0]).bitcast[UInt32](),
        blocks.unsafe_ptr().bitcast[UInt8](),
        UInt(num_blocks),
    )


@always_inline
def sha256_compress_blocks_portable(
    mut state: Array[UInt32, 8],
    blocks: Span[UInt8, _],
):
    """`sha256_compress_blocks` forced onto AWS-LC's portable block body on
    any CPU. Same arguments and result; it exists so a test can check the
    body a CPU without the SHA extensions runs."""
    var num_blocks = _block_count(blocks)
    if num_blocks == 0:
        return

    # SAFETY: as in `sha256_compress_blocks`: the wrapper reads
    # `num_blocks * 64` bytes from `blocks` and writes 32 bytes through
    # `state`, both caller-owned across this synchronous call, and retains
    # neither pointer. Origins are inferred, not widened.
    external_call["komira_crypto_sha256_block_data_order_nohw", NoneType](
        UnsafePointer(to=state[0]).bitcast[UInt32](),
        blocks.unsafe_ptr().bitcast[UInt8](),
        UInt(num_blocks),
    )
