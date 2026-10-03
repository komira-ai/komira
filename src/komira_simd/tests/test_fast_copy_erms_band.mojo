# =============================================================================
# test_fast_copy_erms_band — THE ROUTING ORACLE and the >= LIBC_MIN BYTE ORACLE
# =============================================================================
#
# The regression test for the ERMS routing band. Two legs.
#
# # Leg 1 — WHICH ARM, not WHICH NUMBER
#
# `test_fast_copy_call_sites_enabled.test_auto_ladder_thresholds` asserts
# `LIBC_MIN == 262144`. That stays green through a defect that is NEVER a
# wrong number: the number is right and the ARM IT POINTS AT stops being the
# fast one underneath it. A hermetic toolchain that links Zig compiler_rt
# instead of glibc takes `__memmove_avx_unaligned_erms` out of the link, and
# `_copy_libc` silently becomes a 32 B/iteration SSE loop — zero AVX2, zero
# `rep movs`.
# A constant-pinning test cannot see that. **This leg pins the ROUTE.**
#
# It asserts against `fast_copy_route`, which is not a mirror of the dispatch —
# `fast_copy_bytes` is its only consumer, so there is one ladder and it is the
# one under test.
#
# # Leg 2 — the byte oracle ABOVE `LIBC_MIN`
#
# `test_fast_copy_byte_oracle` tops out at **65536 bytes**. So every arm the
# AUTO ladder selects at or above 128 KiB — the unrolled loop, `memmove`, and
# `rep movsb` — needs byte verification at a size it is actually selected
# for. That gap is independent of any performance question and this
# leg closes it: whole-arena comparison against stdlib `memcpy`, guard bytes on
# both sides, four alignment combinations, at and around both band edges.
#
# `rep movsb` in particular is FORWARD-ONLY (the ABI guarantees DF is clear), so
# it is `memcpy` semantics and not `memmove` semantics. The overlap test for
# `fast_move_bytes` lives in the byte-oracle file and must keep passing there;
# this file deliberately never routes an overlapping region through
# `fast_copy_bytes`.
#
# # How leg 1 fails
#
# By mutation: setting `ERMS_MIN = ERMS_MAX + 1` in `fast_copy.mojo` empties
# the band; `test_route_ladder` then goes RED on the first in-band size with
# `route(131072) == 5 (LIBC/UNROLLED), want 4 (ERMS)`.
# =============================================================================

from std.memory import unsafe_memcpy
from std.testing import assert_equal, assert_true

from komira_simd.fast_copy import (
    fast_copy_bytes,
    fast_copy_route,
    SMALL_MAX,
    MID_MAX,
    LIBC_MIN,
    NT_MIN,
    ERMS_MIN,
    ERMS_MAX,
    ROUTE_NONE,
    ROUTE_SMALL,
    ROUTE_MID,
    ROUTE_UNROLLED,
    ROUTE_ERMS,
    ROUTE_LIBC,
    ROUTE_NT,
)

comptime GUARD: UInt8 = 0xA5
comptime PAD: Int = 192


@always_inline
def _pattern(i: Int) -> UInt8:
    return UInt8(((i * 167) + 13) & 0xFF)


# =============================================================================
# Leg 1 — the route ladder.
# =============================================================================


def test_route_ladder() raises -> None:
    """Every arm of the AUTO ladder, named, at the sizes that select it.

    ⛔ THE IN-BAND ASSERTIONS ARE THE REGRESSION TEST. A change that empties or
    narrows the ERMS band reds this."""
    # --- Degenerate and small.
    assert_equal(fast_copy_route(0), ROUTE_NONE, "route(0)")
    assert_equal(fast_copy_route(-1), ROUTE_NONE, "route(-1)")
    assert_equal(fast_copy_route(1), ROUTE_SMALL, "route(1)")
    assert_equal(
        fast_copy_route(SMALL_MAX - 1), ROUTE_SMALL, "route(SMALL_MAX-1)"
    )
    assert_equal(fast_copy_route(SMALL_MAX), ROUTE_MID, "route(SMALL_MAX)")
    assert_equal(fast_copy_route(MID_MAX), ROUTE_MID, "route(MID_MAX)")

    # --- Between MID_MAX and the ERMS band: the unrolled AVX2 loop.
    assert_equal(fast_copy_route(MID_MAX + 1), ROUTE_UNROLLED, "route(129)")
    assert_equal(fast_copy_route(65536), ROUTE_UNROLLED, "route(64K)")
    assert_equal(
        fast_copy_route(ERMS_MIN - 1), ROUTE_UNROLLED, "route(ERMS_MIN-1)"
    )

    # --- ⭐ THE BAND. This is the assertion the defect fails.
    assert_equal(fast_copy_route(ERMS_MIN), ROUTE_ERMS, "route(ERMS_MIN)")
    assert_equal(fast_copy_route(262144), ROUTE_ERMS, "route(256K)")
    assert_equal(fast_copy_route(1048576), ROUTE_ERMS, "route(1M)")
    assert_equal(fast_copy_route(4194304), ROUTE_ERMS, "route(4M)")
    assert_equal(fast_copy_route(ERMS_MAX), ROUTE_ERMS, "route(ERMS_MAX)")

    # --- Above the band's measured top, `memmove` is the last resort.
    assert_equal(
        fast_copy_route(ERMS_MAX + 1), ROUTE_LIBC, "route(ERMS_MAX+1)"
    )
    assert_equal(fast_copy_route(1 << 30), ROUTE_LIBC, "route(1G)")

    # --- `nt_ok` outranks the band, and ONLY with nt_ok.
    assert_equal(fast_copy_route[True](NT_MIN), ROUTE_NT, "route[nt](NT_MIN)")
    assert_equal(
        fast_copy_route[False](NT_MIN), ROUTE_ERMS, "route[!nt](NT_MIN)"
    )
    assert_equal(
        fast_copy_route[True](NT_MIN - 1), ROUTE_ERMS, "route[nt](NT_MIN-1)"
    )
    print("E1 route ladder: PASS")


def test_band_is_non_empty_and_ordered() raises -> None:
    """A band whose edges cross is silently a no-op, and every assertion above
    would still pass while the ladder routed nothing to `rep movsb`.

    This is NOT the comptime-ordering check `test_auto_ladder_thresholds`
    declines to make: that one folds to `if True` because both sides are
    constants. This asserts through `fast_copy_route`, whose answer at a runtime
    `n` is what an empty band actually changes."""
    assert_true(ERMS_MIN <= ERMS_MAX, "ERMS band edges crossed")
    var mid = ERMS_MIN + (ERMS_MAX - ERMS_MIN) // 2
    assert_equal(fast_copy_route(mid), ROUTE_ERMS, "band midpoint not ERMS")
    assert_true(
        MID_MAX < ERMS_MIN,
        "ERMS_MIN must sit above the mid path; ERMS has a startup cost",
    )
    assert_true(
        ERMS_MAX >= LIBC_MIN,
        "the band must cover LIBC_MIN or the defect is only half fixed",
    )
    print("E2 band non-empty and ordered: PASS")


# =============================================================================
# Leg 2 — the byte oracle at and above `LIBC_MIN`.
# =============================================================================


def _check_copy(n: Int, dst_off: Int, src_off: Int) raises -> None:
    """One whole-arena comparison of `fast_copy_bytes` against stdlib `memcpy`.

    Both arenas start guard-filled, so an overrun on either side of the
    destination region shows up as a divergence rather than as silence."""
    var src_total = n + src_off + PAD
    var src = List[UInt8](length=src_total, fill=0)
    for i in range(src_total):
        src[i] = _pattern(i)

    var arena = n + dst_off + PAD
    var mine = List[UInt8](length=arena, fill=GUARD)
    var oracle = List[UInt8](length=arena, fill=GUARD)

    fast_copy_bytes(
        Span[UInt8, origin_of(mine)](
            unsafe_ptr=mine.unsafe_ptr() + dst_off, length=n
        ),
        Span[UInt8, origin_of(src)](
            unsafe_ptr=src.unsafe_ptr() + src_off, length=n
        ),
    )
    unsafe_memcpy(
        dest=oracle.unsafe_ptr() + dst_off,
        src=src.unsafe_ptr() + src_off,
        count=n,
    )

    for i in range(arena):
        if mine[i] != oracle[i]:
            var region = String("GUARD-OVERRUN")
            if i >= dst_off and i < dst_off + n:
                region = String("IN-RANGE")
            print(
                "MISMATCH n=", n, " dst_off=", dst_off, " src_off=", src_off,
                " route=", fast_copy_route(n),
                " at arena idx=", i, " (", region, ")",
                " mine=", Int(mine[i]), " oracle=", Int(oracle[i]),
            )
            assert_true(False, "fast_copy_bytes diverged from stdlib memcpy")


def test_large_sizes_byte_oracle() raises -> None:
    """⭐ `test_fast_copy_byte_oracle` stops at 65536, so this is the byte
    verification of every ladder arm above 128 KiB at a size it is selected
    for.

    The offsets cross the two things that can break a wide copy: whether the
    destination is 32 B-aligned (`_copy_large_unrolled` aligns its stores and
    `rep movsb` does not) and whether source and destination share their low
    bits."""
    var sizes: List[Int] = [
        ERMS_MIN - 1,        # the unrolled arm, just below the band
        ERMS_MIN,            # the band's first size
        ERMS_MIN + 1,        # a size with a non-multiple-of-32 tail
        LIBC_MIN,            # the old handoff point
        LIBC_MIN + 37,       # awkward tail inside the band
        1048576,
        4194304 + 5,
    ]
    var offs: List[Int] = [0, 1, 3, 32, 33]

    for si in range(len(sizes)):
        var n = sizes[si]
        if n <= 0:
            continue
        for di in range(len(offs)):
            for sj in range(len(offs)):
                _check_copy(n, offs[di], offs[sj])
    print("E3 byte oracle at and above LIBC_MIN: PASS")


def test_above_band_byte_oracle() raises -> None:
    """The `memmove` arm above `ERMS_MAX` is still reachable and still has to be
    right. `ERMS_MAX + 1` is ~16 MiB, so this allocates ~64 MiB of arenas and is
    the reason this file is `large`."""
    _check_copy(ERMS_MAX + 1, 0, 0)
    _check_copy(ERMS_MAX + 1, 1, 3)
    print("E4 byte oracle above the band: PASS")


def main() raises -> None:
    test_route_ladder()
    test_band_is_non_empty_and_ordered()
    test_large_sizes_byte_oracle()
    test_above_band_byte_oracle()
    print("fast_copy ERMS band: ALL PASS")
