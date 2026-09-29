# =============================================================================
# komira_crypto/aead.mojo — Aead trait re-export + constant_time_eq_n helper
# =============================================================================
#
# Aead-specific shared utilities:
#
#   * `Aead` trait (declared in `traits.mojo`) — re-exported here so
#     conformers can `from komira_crypto.aead import Aead`. This file does
#     NOT redefine it.
#
#   * `constant_time_eq_n` — N-byte constant-time byte-vector equality,
#     load-bearing for AEAD tag verification (open_in_place MUST verify
#     the tag with no early exit on byte mismatch). It generalizes
#     `constant_time_eq_32` (in hmac.mojo) to variable tag lengths. The
#     TLS 1.3 AEAD tag is always 16 bytes; this helper is sized for the
#     general case to keep open_in_place uniform across AesGcm128 /
#     AesGcm256 / ChaCha20-Poly1305 (all 16-byte tags, but other AEADs
#     may differ).
#
# # Constant-time discipline
#
# The OR-accumulator pattern (XOR pairs, OR into a running accumulator,
# test if 0) is the canonical CT defense against the early-exit timing
# leak. The loop runs all N iterations regardless of mismatch position;
# the result is computed from the accumulator at the end. The compiler
# is free to vectorize but MUST NOT introduce a data-dependent branch.
#
# Length-compare branch IS a public branch (the caller's two Spans have
# publicly known lengths). A length mismatch returning False early is
# safe from a CT-defense standpoint because the length is not secret —
# but for AEAD tag verification the lengths are always equal (= TAG_SIZE)
# so this branch never fires in production.
#
# # Encapsulation invariants
#
#   * ZERO UnsafePointer in any public function signature.
#   * ZERO wildcard origins — Span[UInt8, _] is origin-inferred per call
#     site (NOT wildcard widening; same idiom as the rest of the package).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee`.
#   * ZERO new ArcPointer sites.
# =============================================================================

from komira_crypto.traits import Aead


# -----------------------------------------------------------------------------
# constant_time_eq_n — variable-length constant-time byte-vector equality
# -----------------------------------------------------------------------------


def constant_time_eq_n(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    """Constant-time equality for two byte spans.

    Use this for AEAD tag verification — comparing an attacker-controlled
    tag against a computed reference tag with `a == b` leaks timing
    information (early exit on first-byte mismatch reveals the prefix
    that matched, enabling an iterative attack).

    Implementation: OR-accumulate the XOR of every byte pair; equality
    iff the accumulator is zero. Branch-free, data-oblivious — the
    loop always runs `len(a)` iterations regardless of mismatch position.

    This is the load-bearing AEAD-verify primitive. The OR-accumulator
    pattern is the canonical CT defense against the early-exit-on-mismatch
    timing leak.

    The length-compare branch IS a public branch (the caller's two
    spans have publicly known lengths). In AEAD tag verification
    `len(a) == len(b) == TAG_SIZE == 16` always, so this branch
    never fires in production.

    Generalizes `hmac.constant_time_eq_32` to variable lengths.
    """
    if len(a) != len(b):
        return False  # NOTE: length comparison is on PUBLIC lengths.
    var diff = UInt8(0)
    for i in range(len(a)):
        diff = diff | (a[i] ^ b[i])
    return diff == UInt8(0)
