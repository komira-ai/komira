# =============================================================================
# komira_crypto/tests/test_ecdsa_sign_failure_raises.mojo
# =============================================================================
#
# REGRESSION GUARD against a DEAD DEFERRED-RAISE in the P-256 / P-384
# ECDSA FFI wrappers (a compiler reports every such path as
# `assignment to 'err_msg' was never used`).
#
# THE DEFECT SHAPE
# ----------------
# `p256_sign_with_nonce` / `p384_sign_with_nonce` (and the two
# `*_pubkey_from_priv`) must not be written as:
#
#     var err_msg = String(""); var should_raise = False
#     try:
#         if <AWS-LC call failed>:
#             err_msg = "..."; should_raise = True
#             return                    # <-- RETURNS FROM THE FUNCTION
#         ...
#     finally:
#         <free handles>
#     if should_raise:                  # <-- ONLY reached on FALL-THROUGH,
#         raise Error(err_msg)          #     where should_raise is False
#
# A `return` inside the `try` exits the FUNCTION (running `finally` on the
# deferred raise is unreachable from every failure path: each would return
# SUCCESS with the caller's `r_out`/`s_out` untouched.
#
# WHY IT MATTERS: `ecdsa_p256_sign_deterministic` does not range-check the
# private scalar — it hands it straight to AWS-LC. With an out-of-range
# scalar, `EC_KEY_set_private_key` returns 0, and the caller would receive
# a 64-byte ALL-ZERO "signature" and no error. A silent wrong answer in the
# signing path, not a crash.
# signing path, not a crash.
#
# THE GUARD: an out-of-range private scalar must RAISE. It must also never
# return an all-zero signature, which is the shape the defect produces.
# =============================================================================

from std.testing import assert_true

from komira_crypto.ecdsa_p256 import ecdsa_p256_sign_deterministic
from komira_crypto.ecdsa_p384 import ecdsa_p384_sign_deterministic


def _all_ff_32() -> Array[UInt8, 32]:
    """A 32-byte scalar of 0xFF..FF — larger than the P-256 group order n,
    so AWS-LC's `EC_KEY_set_private_key` refuses it."""
    return Array[UInt8, 32](fill=UInt8(0xFF))


def _all_ff_48() -> Array[UInt8, 48]:
    """The P-384 equivalent — 48 bytes of 0xFF, above the P-384 order."""
    return Array[UInt8, 48](fill=UInt8(0xFF))


def test_p256_sign_raises_on_out_of_range_privkey() raises:
    var priv = _all_ff_32()
    var msg = String("failure-path guard").as_bytes()

    var raised = False
    var sig_was_all_zero = False
    try:
        var sig = ecdsa_p256_sign_deterministic(
            Span[UInt8, origin_of(priv)](priv), msg
        )
        # We got here => no raise. Record whether the returned signature is
        # the all-zero buffer the defect produces, so the failure message
        # names the actual defect rather than just "did not raise".
        var nonzero = False
        for i in range(64):
            if sig[i] != UInt8(0):
                nonzero = True
        sig_was_all_zero = not nonzero
    except:
        raised = True

    assert_true(
        raised,
        (
            "ecdsa_p256_sign_deterministic must RAISE when AWS-LC refuses the"
            " private scalar; it returned normally"
            + (
                " with an ALL-ZERO 64-byte signature (the dead deferred-raise"
                " defect)"
                if sig_was_all_zero
                else " with a non-zero signature"
            )
        ),
    )


def test_p384_sign_raises_on_out_of_range_privkey() raises:
    var priv = _all_ff_48()
    var msg = String("failure-path guard").as_bytes()

    var raised = False
    var sig_was_all_zero = False
    try:
        var sig = ecdsa_p384_sign_deterministic(
            Span[UInt8, origin_of(priv)](priv), msg
        )
        var nonzero = False
        for i in range(96):
            if sig[i] != UInt8(0):
                nonzero = True
        sig_was_all_zero = not nonzero
    except:
        raised = True

    assert_true(
        raised,
        (
            "ecdsa_p384_sign_deterministic must RAISE when AWS-LC refuses the"
            " private scalar; it returned normally"
            + (
                " with an ALL-ZERO 96-byte signature (the dead deferred-raise"
                " defect)"
                if sig_was_all_zero
                else " with a non-zero signature"
            )
        ),
    )


def main() raises:
    print("== test_ecdsa_sign_failure_raises ==")
    test_p256_sign_raises_on_out_of_range_privkey()
    print("  P-256 out-of-range privkey raises PASS")
    test_p384_sign_raises_on_out_of_range_privkey()
    print("  P-384 out-of-range privkey raises PASS")
    print("ALL 2 ECDSA failure-path tests PASS")
