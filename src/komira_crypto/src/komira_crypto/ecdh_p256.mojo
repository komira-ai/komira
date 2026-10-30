# =============================================================================
# komira_crypto/ecdh_p256.mojo: P-256 ECDH (SP 800-56A ECC CDH primitive)
# =============================================================================
#
# `p256_ecdh(priv, peer_pub_uncompressed)` returns the shared secret Z, the
# x-coordinate of priv * peer as 32 big-endian bytes. This is the ECDH step of
# RFC 8291 (Web Push message encryption) and of RFC 5903's 256-bit ECP group.
#
# Keys use the encodings RFC 8291 carries on the wire: the private key is a
# 32-byte big-endian scalar, the peer public key the 65-byte uncompressed SEC1
# point 0x04 || x || y. Refused, each with its own error message:
#
#   * a private key that is not 32 bytes, or not in [1, n-1];
#   * the point at infinity (its SEC1 encoding, the single byte 0x00);
#   * a peer key that is not 65 bytes, or does not start with 0x04
#     (compressed and hybrid forms are not accepted);
#   * a peer point that is not on P-256, or has a coordinate >= p.
#
# P-256 has cofactor 1, so an accepted scalar and an accepted peer point never
# produce the point at infinity.
#
# The curve arithmetic is AWS-LC's, through
# `internal/asm/p256_ecdh_ffi.mojo`. No pointer type in the public signature.
# =============================================================================

from .internal.asm.p256_ecdh_ffi import p256_ecdh_shared_x


def p256_ecdh(
    priv: Span[UInt8, _],
    peer_pub_uncompressed: Span[UInt8, _],
) raises -> Array[UInt8, 32]:
    """P-256 ECDH: the x-coordinate of priv * peer, 32 big-endian bytes.

    Args:
        priv: 32-byte big-endian private scalar in [1, n-1].
        peer_pub_uncompressed: 65-byte uncompressed point 0x04 || x || y.

    Returns:
        The shared secret Z (SP 800-56A section 5.7.1.2).

    Raises:
        "p256_ecdh: peer public key is the point at infinity"
        "p256_ecdh: peer public key must be 65 bytes, got <n>"
        "p256_ecdh: peer public key must start with 0x04 (uncompressed)"
        "p256_ecdh: private key must be 32 bytes, got <n>"
        "p256_ecdh: private key is not in [1, n-1]"
        "p256_ecdh: peer public key is not a point on P-256"
    """
    var n_peer = len(peer_pub_uncompressed)
    if n_peer == 1 and peer_pub_uncompressed[0] == UInt8(0x00):
        raise Error("p256_ecdh: peer public key is the point at infinity")
    if n_peer != 65:
        raise Error(
            "p256_ecdh: peer public key must be 65 bytes, got " + String(n_peer)
        )
    if peer_pub_uncompressed[0] != UInt8(0x04):
        raise Error(
            "p256_ecdh: peer public key must start with 0x04 (uncompressed)"
        )
    var z = Array[UInt8, 32](fill=UInt8(0))
    p256_ecdh_shared_x(priv, peer_pub_uncompressed, z)
    return z^
