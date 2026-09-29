# =============================================================================
# komira_crypto/tests/test_ed25519_length_guard.mojo
# =============================================================================
#
# REGRESSION GUARD for `debug_assert` USED AS THE SOLE LENGTH CHECK in the
# Ed25519 FFI wrappers (`internal/asm/ed25519_ffi.mojo`).
#
# THE DEFECT SHAPE
# ----------------
# Guarding the buffer lengths of `ed25519_verify` /
# `ed25519_sign_from_seed` / `ed25519_pubkey_from_seed` with:
#
#     debug_assert(len(sig) >= 64, "ed25519_verify: sig must be >= 64 bytes")
#
# is not a guard: `debug_assert` COMPILES OUT in a release build. AWS-LC's
# `ED25519_verify` then reads exactly 64 bytes from `sig.unsafe_ptr()` and
# exactly 32 from `pubkey.unsafe_ptr()` regardless of the Span's actual
# length — so in a shipped binary the "check" is a no-op and the read runs
# past the buffer.
#
# WHY IT MATTERS (this path takes REMOTE input): a token-verifying request
# middleware derives `sig` from `base64_url_decode(seg_sig)` and may check
# only that the segment is NON-EMPTY — the decoded length is entirely
# attacker-controlled. A one-byte signature segment would then cause a
# 64-byte read off a one-byte heap buffer, on unauthenticated input, inside
# a request path.
#
# THE GUARD BELOW IS DETERMINISTIC, NOT UB-DEPENDENT. Each case hands the
# verifier a SHORT SPAN OVER A LONGER, FULLY-VALID BUFFER (`span[0:n]`), so
# the bytes the missing check would have let AWS-LC read are genuinely
# present and genuinely valid. Without the check the verifier reads them and returns
# TRUE — i.e. it ACCEPTS an 8-byte signature as a valid 64-byte one. That is
# the security failure stated as an assertion, and it does not depend on
# whatever happens to sit past the end of a real allocation.
#
# EXPECTED SHAPE OF THE FIX
#   * `ed25519_verify`  -> `False` on a short pubkey/sig. FAIL-CLOSED, not a
#     raise: a truncated signature IS an invalid signature, and the caller
#     (the middleware) must keep answering 401 rather than start throwing on
#     malformed input.
#   * `ed25519_sign_from_seed` / `ed25519_pubkey_from_seed` -> RAISE on a
#     short seed. There is no "invalid signature" value to return; a short
#     seed is a caller/config defect and must be loud.
#   * `ed25519_sign_from_seed` must also RAISE when `ED25519_sign` returns 0
#     instead of discarding the code and handing back the all-zero buffer.
# =============================================================================

from std.testing import assert_true, assert_false

from komira_crypto.ed25519 import (
    ed25519_sign,
    ed25519_verify,
    ed25519_pubkey_from_seed,
)


def _seed() -> Array[UInt8, 32]:
    """A fixed, valid 32-byte Ed25519 seed. Every 32-byte string is a valid
    Ed25519 seed per RFC 8032 §5.1.5, so no range check is needed."""
    var s = Array[UInt8, 32](fill=UInt8(0))
    for i in range(32):
        s[i] = UInt8((i * 7 + 13) & 0xFF)
    return s^


# -----------------------------------------------------------------------------
# 1 — a TRUNCATED SIGNATURE must be rejected.
# -----------------------------------------------------------------------------


def test_verify_rejects_truncated_signature() raises:
    var seed = _seed()
    var msg = String("ed25519 length-guard").as_bytes()
    var pubkey = ed25519_pubkey_from_seed(Span[UInt8, origin_of(seed)](seed))
    var sig = ed25519_sign(Span[UInt8, origin_of(seed)](seed), msg)

    # Sanity: the FULL signature verifies. If this fails the test is wrong,
    # not the code under test.
    assert_true(
        ed25519_verify(
            Span[UInt8, origin_of(pubkey)](pubkey),
            msg,
            Span[UInt8, origin_of(sig)](sig),
        ),
        "precondition: the full 64-byte signature must verify",
    )

    # The attack: an 8-byte Span over the SAME buffer. The remaining 56 bytes
    # of a valid signature are still in memory behind it, so a verifier that
    # does not check the length reads them and returns True.
    var truncated = Span[UInt8, origin_of(sig)](sig)[0:8]
    assert_false(
        ed25519_verify(
            Span[UInt8, origin_of(pubkey)](pubkey), msg, truncated
        ),
        (
            "ed25519_verify ACCEPTED an 8-byte signature as valid — it read"
            " past the Span and consumed the full 64 bytes behind it. The"
            " length check is a `debug_assert`, which is compiled out of the"
            " shipped binary. A token verifier passes an"
            " attacker-controlled base64url-decoded length straight into this"
            " call, so this is a remote out-of-bounds read on a"
            " request path."
        ),
    )


# -----------------------------------------------------------------------------
# 2 — a TRUNCATED PUBLIC KEY must be rejected.
# -----------------------------------------------------------------------------


def test_verify_rejects_truncated_pubkey() raises:
    var seed = _seed()
    var msg = String("ed25519 length-guard").as_bytes()
    var pubkey = ed25519_pubkey_from_seed(Span[UInt8, origin_of(seed)](seed))
    var sig = ed25519_sign(Span[UInt8, origin_of(seed)](seed), msg)

    var truncated_pub = Span[UInt8, origin_of(pubkey)](pubkey)[0:8]
    assert_false(
        ed25519_verify(truncated_pub, msg, Span[UInt8, origin_of(sig)](sig)),
        (
            "ed25519_verify ACCEPTED an 8-byte public key — it read the full"
            " 32 bytes behind the Span. A JWKS entry whose `x` member decodes"
            " short must not be usable as a verification key."
        ),
    )


# -----------------------------------------------------------------------------
# 3 — a SHORT SEED must RAISE rather than sign with bytes it does not own.
# -----------------------------------------------------------------------------


def test_sign_raises_on_short_seed() raises:
    var seed = _seed()
    var msg = String("ed25519 length-guard").as_bytes()
    var short_seed = Span[UInt8, origin_of(seed)](seed)[0:8]

    var raised = False
    var signed_anyway = False
    try:
        var sig = ed25519_sign(short_seed, msg)
        # No raise. Record whether it produced a real signature by reading
        # the 24 bytes it does not own — which is what the missing check
        # allows, and which makes the result indistinguishable from a
        # legitimate signature.
        for i in range(64):
            if sig[i] != UInt8(0):
                signed_anyway = True
    except:
        raised = True

    assert_true(
        raised,
        (
            "ed25519_sign must RAISE on a seed shorter than 32 bytes; it"
            " returned normally"
            + (
                " with a full signature produced from 24 bytes past the end of"
                " the caller's buffer (the `debug_assert` length check is"
                " compiled out of the shipped binary)"
                if signed_anyway
                else " with an all-zero signature"
            )
        ),
    )


def test_pubkey_from_seed_raises_on_short_seed() raises:
    var seed = _seed()
    var short_seed = Span[UInt8, origin_of(seed)](seed)[0:8]

    var raised = False
    try:
        var _pub = ed25519_pubkey_from_seed(short_seed)
    except:
        raised = True

    assert_true(
        raised,
        (
            "ed25519_pubkey_from_seed must RAISE on a seed shorter than 32"
            " bytes rather than derive a key from bytes past the end of the"
            " caller's buffer. This derivation feeds a PUBLISHED JWKS,"
            " where a wrong key rejects"
            " every token minted against it, forever, with no other signal."
        ),
    )


def main() raises:
    print("== test_ed25519_length_guard ==")
    test_verify_rejects_truncated_signature()
    print("  truncated signature rejected PASS")
    test_verify_rejects_truncated_pubkey()
    print("  truncated pubkey rejected PASS")
    test_sign_raises_on_short_seed()
    print("  short seed raises on sign PASS")
    test_pubkey_from_seed_raises_on_short_seed()
    print("  short seed raises on pubkey derive PASS")
    print("ALL 4 Ed25519 length-guard tests PASS")
