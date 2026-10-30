# =============================================================================
# komira_crypto/x25519_simd.mojo — X25519 4-way batched
# =============================================================================
#
# A 4-iteration loop around the AWS-LC FFI single-key X25519. AWS-LC's
# X25519 is single-key only; no batched 4-way symbol exists, so the
# throughput is that of 4 single-key AWS-LC calls. The batched API keeps
# its lane-major calling convention for callers that hold 4 key shares.
#
# Functional contract: x25519_4way(scalars, bases, out) is byte-identical
# to 4 sequential x25519(scalar, base) calls — same input slot ordering
# (lane-major 32-byte packing), same output layout.
#
# # Public surface
#
#   * x25519_4way[o: Origin[mut=True]](
#         scalars: Span[UInt8, _],
#         bases:   Span[UInt8, _],
#         output:  Span[UInt8, o])
#
#     scalars/bases each are 4*32=128 bytes; output is 128 bytes for 4
#     shared secrets, lane k at bytes [32k..32k+32).
# =============================================================================

from komira_crypto.internal.asm.x25519_ffi import x25519_scalarmult


def x25519_4way[o: Origin[mut=True]](
    scalars: Span[UInt8, _],
    bases: Span[UInt8, _],
    output: Span[UInt8, o],
):
    """Compute 4 X25519(scalar_i, base_i) -> shared_i via AWS-LC FFI.

    Inputs (lane-major 32-byte packing):
      scalars: 4 * 32 = 128 bytes (4 private scalars packed sequentially)
      bases:   4 * 32 = 128 bytes (4 peer-public u-coordinates)
      output:  128 bytes mut (4 shared secrets)

    Per lane k, output[32k..32k+32) = x25519(scalars[32k..32k+32),
    bases[32k..32k+32)) — byte-identical to 4 sequential single-key
    X25519 calls.

    Runs as sequential FFI calls: throughput is 4x single-key AWS-LC
    (no SIMD lane-packing).
    """
    debug_assert(len(scalars) >= 128, "x25519_4way: scalars must be >= 128 bytes")
    debug_assert(len(bases) >= 128, "x25519_4way: bases must be >= 128 bytes")
    debug_assert(len(output) >= 128, "x25519_4way: output must be >= 128 bytes")

    for i in range(4):
        var off = i * 32
        var scalar_slice = scalars[off : off + 32]
        var base_slice = bases[off : off + 32]
        var shared = Array[UInt8, 32](fill=0)
        _ = x25519_scalarmult(scalar_slice, base_slice, shared)
        for j in range(32):
            output[off + j] = shared[j]
