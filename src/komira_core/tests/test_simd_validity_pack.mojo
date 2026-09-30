# =============================================================================
# Correctness tests for the shared null-flag → Arrow validity bitmap packer in
# `komira_core.simd.validity_pack`.
# =============================================================================
#
# Coverage:
#   1. Correctness: for several row counts (exercising the 16-row SIMD body and
#      the scalar tail at every alignment) and several null densities, the SIMD
#      `pack_validity_from_null_flags` output must be bit-for-bit identical to
#      an independent scalar oracle (all-valid + per-null clear), and the
#      returned null count must match.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.simd.validity_pack import pack_validity_from_null_flags


# =============================================================================
# Scalar reference oracle (independent of the production module).
# =============================================================================


def _ref_pack(
    null_flags: Span[Bool, _], mut bitmap: List[UInt8]
) -> Int:
    """Scalar all-valid + per-null clear — the correctness oracle.

    Arrow validity: bit r (LSB-first) == 1 iff row r is VALID (not null).
    """
    var n = len(null_flags)
    var num_bytes = (n + 7) >> 3
    bitmap.resize(unsafe_uninit_length=num_bytes)
    # Start all-valid (every bit 1) for full bytes; partial trailing byte keeps
    # only the valid low bits.
    for b in range(num_bytes):
        bitmap[b] = 0xFF
    # Clear bits beyond n in the final byte.
    var tail_bits = n & 7
    if tail_bits != 0:
        var mask = UInt8((1 << tail_bits) - 1)
        bitmap[num_bytes - 1] = bitmap[num_bytes - 1] & mask
    var nc = 0
    for r in range(n):
        if null_flags[r]:
            nc += 1
            var b = r >> 3
            bitmap[b] = bitmap[b] & ~(UInt8(1) << UInt8(r & 7))
    return nc


def _make_flags(n: Int, null_every: Int) -> List[Bool]:
    """Deterministic null-flag column: row r is null iff (r % null_every) == 0.
    `null_every == 0` -> no nulls (all present)."""
    var flags = List[Bool]()
    flags.resize(unsafe_uninit_length=n)
    for r in range(n):
        if null_every == 0:
            flags[r] = False
        else:
            flags[r] = (r % null_every) == 0
    return flags^


def _check(n: Int, null_every: Int) raises:
    var flags = _make_flags(n, null_every)

    var oracle = List[UInt8]()
    var oracle_nc = _ref_pack(Span(flags), oracle)

    var num_bytes = (n + 7) >> 3
    var got = List[UInt8]()
    got.resize(unsafe_uninit_length=num_bytes if num_bytes > 0 else 1)
    var got_span = Span(got)
    var got_nc = pack_validity_from_null_flags(Span(flags), got_span)

    assert_equal(
        got_nc, oracle_nc,
        "n=" + String(n) + " every=" + String(null_every)
        + " null_count mismatch",
    )
    for b in range(num_bytes):
        assert_equal(
            Int(got[b]), Int(oracle[b]),
            "n=" + String(n) + " every=" + String(null_every)
            + " byte " + String(b) + " mismatch",
        )


# =============================================================================
# Correctness — body + tail across alignments and null densities.
# =============================================================================


def test_all_present() raises:
    # The hot path for lineitem_null (zero actual nulls): every bit must be 1.
    _check(1024, 0)
    _check(1000, 0)
    _check(1003, 0)  # partial final byte


def test_all_null() raises:
    _check(1024, 1)
    _check(999, 1)


def test_sparse_nulls() raises:
    _check(1000, 7)
    _check(1000, 13)
    _check(997, 5)
    _check(1001, 64)


def test_tail_alignments() raises:
    # Every (n % 16) tail length, plus every (n % 8) bitmap-byte tail.
    for n in range(0, 40):
        _check(n, 3)
        _check(n, 0)


def test_small_counts() raises:
    _check(1, 1)
    _check(1, 0)
    _check(8, 2)
    _check(15, 4)
    _check(16, 4)
    _check(17, 4)


def main() raises:
    var suite = TestSuite()
    suite.test[test_all_present]()
    suite.test[test_all_null]()
    suite.test[test_sparse_nulls]()
    suite.test[test_tail_alignments]()
    suite.test[test_small_counts]()
    suite^.run()
