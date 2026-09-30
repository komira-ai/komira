# =============================================================================
# Regression: OwnedAlignedBuffer.reserve must preserve EVERY existing byte
# across a regrow -- and above all the LEADING 8, which is where the Mojo
# 1.0.0 use-after-free actually landed.
# =============================================================================
#
# THIS IS THE DIRECT FALSIFIER FOR THE LOAD-BEARING LINE IN
# `OwnedAlignedBuffer.reserve` (`var _alive = len(self._bytes)`).
#
# WHY A PRIMITIVE-LEVEL TEST. A `RowBlock` regrow test two layers up also
# reaches this code, but it asserts about rows, not bytes, so it names neither
# `OwnedAlignedBuffer` nor `reserve`: someone deleting the line in `reserve`
# would get a failure in a file that never mentions the struct they edited.
# This test fails next to the edit and says why.
#
# THE BUG (Mojo 1.0.0, fixed in `owned_aligned_buffer.mojo`). `reserve` copies
# the surviving bytes with
#     memcpy(dest=aligned, src=self._ptr, count=keep)
# where `_ptr` is `UnsafePointer[UInt8, MutExternalOrigin]` -- a WILDCARD
# origin. The compiler therefore cannot see that the copy reads THROUGH
# `self._bytes`. Nothing else in the function touched `self._bytes` between
# entry and `self._bytes = fresh^`, so under 1.0.0's destruction timing the old
# `List` became destroyable BEFORE the memcpy ran. tcmalloc writes its
# free-list linkage over the first bytes of a freed block, and a tail-of-list
# `next` is NULL -- so the damage was EXACTLY 8 BYTES AT OFFSET 0, with every
# later byte intact. That is the signature both tests below pin.
#
# FAIL-BEFORE / PASS-AFTER: deleting `var _alive = len(self._bytes)` from
# `OwnedAlignedBuffer.reserve` makes `test_reserve_preserves_leading_eight_bytes`
# fail on the very first assertion, reading 0 where the sentinel was written.
#
# ⚠ DO NOT "FIX" A FAILURE HERE BY RELAXING AN ASSERTION. A regrow that loses
# bytes is silent data loss in every engine buffer; the assertions are the
# product.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer


def _pat(i: Int) -> UInt8:
    """A position-dependent byte that is NEVER 0.

    Never-zero matters: the failure mode overwrites bytes with NUL, so a
    pattern containing legitimate zeros could not distinguish "preserved"
    from "clobbered". 251 is prime, so the pattern does not align with any
    power-of-two stride or alignment boundary.
    """
    return UInt8((i % 251) + 1)


def test_reserve_preserves_leading_eight_bytes() raises:
    """The precise signature of the 1.0.0 regression: the first 8 bytes.

    Writes a non-zero sentinel u64 at offset 0, forces one large regrow, and
    reads it straight back. Under the bug this reads 0.
    """
    var initial = 4096
    var buf = OwnedAlignedBuffer(capacity=initial)

    # A sentinel with no zero byte in it, so ANY partial clobber is visible.
    var sentinel: UInt64 = 0xA1B2C3D4E5F60718
    buf.write_u64_le_at(0, sentinel)
    for i in range(8, initial):
        buf.write_u8_at(i, _pat(i))

    # Force a regrow well past the current capacity. `reserve` preserves
    # `_length` (= 4096 here, set by the ctor), so the read-back below stays
    # in bounds without touching `set_length`.
    buf.reserve(1 << 20)

    assert_equal(
        buf.read_u64_le_at(0),
        sentinel,
        msg=(
            "OwnedAlignedBuffer.reserve LOST THE LEADING 8 BYTES across a"
            " regrow -- the Mojo 1.0.0 use-after-free signature. The memcpy"
            " in `reserve` read through the wildcard-origin `_ptr` after the"
            " old `_bytes` List had already been destroyed. Restore the"
            " `var _alive = len(self._bytes)` borrow that pins the"
            " destruction below the copy."
        ),
    )

    # The rest of the buffer must be intact too -- this separates "lost the
    # first 8" from "lost everything".
    for i in range(8, initial):
        assert_equal(
            buf.read_u8_at(i),
            _pat(i),
            msg="OwnedAlignedBuffer.reserve corrupted a byte past offset 8",
        )


def test_reserve_preserves_bytes_across_repeated_doubling() raises:
    """The shape the engine actually uses: amortized doubling.

    Every regrow generation re-runs the memcpy, and each spans a different
    allocator size class -- from the size-classed ThreadCache up into the
    page heap -- so this covers the reuse behaviour the single-shot test
    above cannot.
    """
    var cap = 128
    var buf = OwnedAlignedBuffer(capacity=cap)
    for i in range(cap):
        buf.write_u8_at(i, _pat(i))

    var generations = 0
    while cap < (1 << 18):
        var next_cap = cap * 2
        buf.reserve(next_cap)

        # EVERY byte written before this regrow must have survived it.
        for i in range(cap):
            assert_equal(
                buf.read_u8_at(i),
                _pat(i),
                msg=(
                    "OwnedAlignedBuffer.reserve lost a byte on a doubling"
                    " regrow -- existing bytes must be preserved"
                ),
            )

        # Admit the newly reserved range and extend the pattern into it, so
        # the next generation has a full buffer to preserve.
        buf.set_length(Int64(next_cap))
        for i in range(cap, next_cap):
            buf.write_u8_at(i, _pat(i))

        cap = next_cap
        generations += 1

    # Guard the guard: if the loop never regrew, the assertions above are
    # vacuous and this test would pass while checking nothing.
    assert_equal(
        generations,
        11,
        msg="expected 11 doubling regrows from 128 up to 262144",
    )


def main() raises:
    var s = TestSuite()
    s.test[test_reserve_preserves_leading_eight_bytes]()
    s.test[test_reserve_preserves_bytes_across_repeated_doubling]()
    s^.run()
