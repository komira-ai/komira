# =============================================================================
# komira_crypto/internal/asm/p256_ecdh_ffi.mojo
# =============================================================================
#
# P-256 elliptic-curve Diffie-Hellman (SP 800-56A ECC CDH primitive, the
# shared-secret step RFC 8291 Web Push encryption uses) over AWS-LC's P-256.
# It reuses the opaque-handle types and helpers of `p256_ffi.mojo`, which
# binds the same AWS-LC EC_KEY / EC_POINT / BIGNUM API for ECDSA.
#
# # Symbols used (AWS-LC libcrypto)
#
#   * EC_KEY_new_by_curve_name / EC_KEY_get0_group / EC_KEY_free
#     (through the p256_ffi helpers)
#   * EC_KEY_set_private_key(eckey, BN*): returns 0 unless 0 < priv < n
#   * BN_bin2bn (through p256_ffi) / BN_clear_free
#   * EC_POINT_new(group) / EC_POINT_free / EC_POINT_clear_free
#   * EC_POINT_oct2point(group, point, buf, len, ctx): returns 0 for an
#     uncompressed encoding that is not a point on the curve or has a
#     coordinate >= p; it also accepts the hybrid forms 0x06/0x07, so the
#     0x04 prefix check is the caller's (`p256_ecdh` in ecdh_p256.mojo)
#   * EC_POINT_mul(group, r, NULL, q, m, ctx): r = m*q; constant-time in m
#   * EC_POINT_point2oct(group, point, UNCOMPRESSED, buf, 65, ctx): returns
#     65 and writes 0x04 || x || y; for the point at infinity it returns 1
#     and writes the single byte 0x00
#
# # FFI-BOUNDARY: ownership of every pointer crossing into AWS-LC
#
#   * eckey (EC_KEY*): allocated here by EC_KEY_new_by_curve_name, freed
#     here by EC_KEY_free in the `finally` block. EC_KEY_set_private_key
#     copies the scalar into eckey; EC_KEY_free clears that copy.
#   * group (EC_GROUP*): borrowed from eckey; never freed here.
#   * priv_bn (BIGNUM*): allocated here by BN_bin2bn, freed here by
#     BN_clear_free (zeroes the scalar before release).
#   * peer_pt (EC_POINT*): allocated here by EC_POINT_new, freed here by
#     EC_POINT_free (public data).
#   * shared_pt (EC_POINT*): allocated here by EC_POINT_new, freed here by
#     EC_POINT_clear_free (it holds the shared secret).
#   * Byte buffers (the caller's Spans, the local 65-byte `raw65`, the
#     caller's 32-byte `z_out`): owned by Mojo, lent to AWS-LC for the
#     duration of one synchronous call; AWS-LC retains no pointer to them.
#     `raw65` holds the shared point and is zeroized before return.
#   * The BN_CTX arguments are NULL: AWS-LC allocates and frees its own.
#
# No pointer type appears in this file's public signature.
# =============================================================================

from std.ffi import external_call

from komira_crypto.zeroize import zeroize_inline_array

from .p256_ffi import (
    POINT_CONVERSION_UNCOMPRESSED,
    _FfiByte,
    _FfiHandle,
    _bn_bin2bn_from_span,
    _ec_key_free,
    _ec_key_get0_group,
    _ec_key_new,
    _ffi_null,
    _inline65_ptr_mut,
    _span_ptr_mut,
)


def p256_ecdh_shared_x(
    priv_be: Span[UInt8, _],
    peer_uncompressed: Span[UInt8, _],
    mut z_out: Array[UInt8, 32],
) raises:
    """Write the x-coordinate of priv * peer (32 big-endian bytes) to z_out.

    Args:
        priv_be: 32-byte big-endian private scalar; refused unless
            0 < priv < n.
        peer_uncompressed: 65-byte SEC1 point; refused unless AWS-LC
            decodes it as a point on P-256 with x, y < p. This function
            does not check the 0x04 prefix: AWS-LC also accepts the hybrid
            forms 0x06/0x07, and `p256_ecdh` refuses anything but 0x04
            before calling here.
        z_out: receives the shared secret Z (SP 800-56A ECC CDH) on success;
            left untouched when this raises.

    Raises:
        "p256_ecdh: private key must be 32 bytes, got <n>"
        "p256_ecdh: peer public key must be 65 bytes, got <n>"
        "p256_ecdh: private key is not in [1, n-1]"
        "p256_ecdh: peer public key is not a point on P-256"
        "p256_ecdh: <AWS-LC function> failed" on allocation or internal
        failure.
    """
    if len(priv_be) != 32:
        raise Error(
            "p256_ecdh: private key must be 32 bytes, got "
            + String(len(priv_be))
        )
    if len(peer_uncompressed) != 65:
        raise Error(
            "p256_ecdh: peer public key must be 65 bytes, got "
            + String(len(peer_uncompressed))
        )

    var eckey = _ec_key_new()
    var priv_bn = _ffi_null()
    var peer_pt = _ffi_null()
    var shared_pt = _ffi_null()
    var null_ptr = _ffi_null()
    var raw65 = Array[UInt8, 65](fill=UInt8(0))
    # Failure paths raise from inside the `try`; the `finally` frees every
    # handle and zeroizes raw65 on both the raising and the returning path.
    try:
        if Int(eckey) == 0:
            raise Error("p256_ecdh: EC_KEY_new_by_curve_name failed")  # cov: unreachable an allocation failure
        var group = _ec_key_get0_group(eckey)
        if Int(group) == 0:
            raise Error("p256_ecdh: EC_KEY_get0_group failed")  # cov: unreachable an EC_KEY made for P-256 always has its group

        priv_bn = _bn_bin2bn_from_span(priv_be)
        if Int(priv_bn) == 0:
            raise Error("p256_ecdh: BN_bin2bn failed")  # cov: unreachable an allocation failure

        # SAFETY: eckey and priv_bn are live handles allocated above.
        # EC_KEY_set_private_key copies the scalar and returns 0 when it is
        # zero or not below the group order n; priv_bn stays ours.
        var rc_priv = external_call[
            "komira_awslc_EC_KEY_set_private_key", Int32,
            _FfiHandle,  # eckey
            _FfiHandle,  # priv (const BIGNUM*)
        ](eckey, priv_bn)
        if rc_priv != 1:
            raise Error("p256_ecdh: private key is not in [1, n-1]")

        # SAFETY: group is borrowed from eckey, which outlives this call.
        peer_pt = external_call[
            "komira_awslc_EC_POINT_new", _FfiHandle,
            _FfiHandle,  # group
        ](group)
        if Int(peer_pt) == 0:
            raise Error("p256_ecdh: EC_POINT_new failed")  # cov: unreachable an allocation failure

        # SAFETY: peer_uncompressed is the caller's live 65-byte buffer;
        # AWS-LC reads exactly 65 bytes during this synchronous call and
        # writes only peer_pt. For an uncompressed or hybrid encoding with
        # a coordinate >= p or a point that does not satisfy the curve
        # equation it returns 0 and sets peer_pt to the generator, so
        # ignoring rc_oct would return x(priv * G), the caller's own public
        # x-coordinate. A leading byte of 0x00 or 0x02/0x03 (whose lengths
        # must be 1 or 33) returns 0 and leaves peer_pt untouched.
        var peer_ptr = _span_ptr_mut(peer_uncompressed)
        var rc_oct = external_call[
            "komira_awslc_EC_POINT_oct2point", Int32,
            _FfiHandle,  # group
            _FfiHandle,  # point (out)
            _FfiByte,    # buf
            UInt,        # len
            _FfiHandle,  # ctx (NULL)
        ](group, peer_pt, peer_ptr, UInt(65), null_ptr)
        if rc_oct != 1:
            raise Error("p256_ecdh: peer public key is not a point on P-256")

        # SAFETY: group is borrowed from eckey.
        shared_pt = external_call[
            "komira_awslc_EC_POINT_new", _FfiHandle,
            _FfiHandle,  # group
        ](group)
        if Int(shared_pt) == 0:
            raise Error("p256_ecdh: EC_POINT_new failed")  # cov: unreachable an allocation failure

        # SAFETY: EC_POINT_mul(group, r, n, q, m, ctx) computes r = n*G + m*q.
        # n = NULL selects r = m*q, AWS-LC's constant-time variable-point
        # multiply. Every handle is live and owned (or borrowed) above.
        var rc_mul = external_call[
            "komira_awslc_EC_POINT_mul", Int32,
            _FfiHandle,  # group
            _FfiHandle,  # r (out)
            _FfiHandle,  # n (NULL)
            _FfiHandle,  # q (peer point)
            _FfiHandle,  # m (private scalar)
            _FfiHandle,  # ctx (NULL)
        ](group, shared_pt, null_ptr, peer_pt, priv_bn, null_ptr)
        if rc_mul != 1:
            raise Error("p256_ecdh: EC_POINT_mul failed")  # cov: unreachable with an on-curve peer and a scalar in [1, n-1] the multiply fails only on an allocation failure

        # SAFETY: raw65 is a local 65-byte buffer and AWS-LC writes at most
        # 65 bytes. For a finite point it writes 0x04 || x || y and returns
        # 65; for the point at infinity it writes the single byte 0x00 and
        # returns 1, which the n_written / raw65[0] check below refuses.
        # With cofactor 1, a scalar in [1, n-1] and a decoded point, the
        # product is never the point at infinity, so that branch is
        # unreachable here.
        var raw_ptr = _inline65_ptr_mut(raw65)
        var n_written = external_call[
            "komira_awslc_EC_POINT_point2oct", UInt,
            _FfiHandle,  # group
            _FfiHandle,  # point
            Int32,       # form
            _FfiByte,    # buf
            UInt,        # len
            _FfiHandle,  # ctx (NULL)
        ](
            group, shared_pt,
            Int32(POINT_CONVERSION_UNCOMPRESSED),
            raw_ptr, UInt(65), null_ptr,
        )
        if n_written != UInt(65) or raw65[0] != UInt8(0x04):
            raise Error("p256_ecdh: EC_POINT_point2oct failed")  # cov: unreachable a scalar in [1, n-1] times a point of the prime-order group is never the point at infinity

        # Z is the x-coordinate: bytes 1..32 of 0x04 || x || y.
        for i in range(32):
            z_out[i] = raw65[1 + i]
    finally:
        zeroize_inline_array(raw65)
        # SAFETY: each handle is NULL or was allocated above and is freed
        # exactly once here; the guarded calls skip NULL.
        if Int(shared_pt) != 0:
            external_call["komira_awslc_EC_POINT_clear_free", NoneType, _FfiHandle](
                shared_pt
            )
        if Int(peer_pt) != 0:
            external_call["komira_awslc_EC_POINT_free", NoneType, _FfiHandle](peer_pt)
        if Int(priv_bn) != 0:
            external_call["komira_awslc_BN_clear_free", NoneType, _FfiHandle](priv_bn)
        _ec_key_free(eckey)
