# =============================================================================
# test_fast_copy_edges — the fast_copy arms the other fast_copy tests miss
# =============================================================================
#
# X1  `fast_copy_route` at RUNTIME sizes. `test_fast_copy_erms_band` asks the
#     ladder with literal sizes; the function is `@always_inline`, so those
#     calls fold at compile time and the low rungs (none / small / mid) never
#     execute as code. Here every size comes out of a `List`, so each rung runs.
# X2  `fast_copy_bytes[nt_ok=True]` at and above `NT_MIN`: the AUTO ladder's
#     non-temporal arm, byte-compared against stdlib `memcpy` with guard bytes.
#     (`VARIANT_NT` forces the same worker but never asks the ladder.)
# X3  `_copy_small(n=0)` writes nothing. `fast_copy_bytes` returns before
#     reaching it for n <= 0, so the guard is reached only by a direct call.
# X4  `fast_move_bytes` on an empty span leaves the destination alone, and a
#     one-byte move still moves.
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset
from std.testing import TestSuite, assert_equal, assert_true

from komira_simd.fast_copy import (
    fast_copy_bytes,
    fast_copy_route,
    fast_move_bytes,
    _copy_small,
    NT_MIN,
    ROUTE_NONE,
    ROUTE_SMALL,
    ROUTE_MID,
    ROUTE_UNROLLED,
    ROUTE_ERMS,
    ROUTE_LIBC,
    ROUTE_NT,
)

comptime GUARD: UInt8 = 0xA5
comptime PAD: Int = 96


@always_inline
def _pattern(i: Int) -> UInt8:
    return UInt8(((i * 151) + 7) & 0xFF)


# =============================================================================
# X1 — route ladder at runtime sizes.
# =============================================================================


def test_route_runtime_sizes() raises -> None:
    """Each row is (size, the arm the ladder must name), written out by hand
    from the documented thresholds: none for n <= 0, small below 32, mid up to
    and including 128, unrolled to 128 KiB, ERMS to 16 MiB, memmove above."""
    var sizes: List[Int] = [
        -5, 0, 1, 31, 32, 128, 129, 131071, 131072, 16777216, 16777217
    ]
    var want: List[Int] = [
        ROUTE_NONE, ROUTE_NONE, ROUTE_SMALL, ROUTE_SMALL, ROUTE_MID,
        ROUTE_MID, ROUTE_UNROLLED, ROUTE_UNROLLED, ROUTE_ERMS, ROUTE_ERMS,
        ROUTE_LIBC,
    ]
    for i in range(len(sizes)):
        assert_equal(
            fast_copy_route(sizes[i]), want[i], "route(" + String(sizes[i]) + ")"
        )
    # With nt_ok the low rungs are the same arms; NT outranks only from 4 MiB.
    var nt_sizes: List[Int] = [0, 1, 31, 32, 128, 4194303, 4194304]
    var nt_want: List[Int] = [
        ROUTE_NONE, ROUTE_SMALL, ROUTE_SMALL, ROUTE_MID, ROUTE_MID,
        ROUTE_ERMS, ROUTE_NT,
    ]
    for i in range(len(nt_sizes)):
        assert_equal(
            fast_copy_route[True](nt_sizes[i]),
            nt_want[i],
            "route[nt](" + String(nt_sizes[i]) + ")",
        )


# =============================================================================
# X2 — the AUTO ladder's NT arm, byte oracle.
# =============================================================================


def _first_diff(a_list: List[UInt8], b_list: List[UInt8], n: Int) -> Int:
    """Index of the first differing byte, or -1. 64-byte vector compares, so a
    4 MiB arena costs a few thousand steps rather than millions."""
    var a = a_list.unsafe_ptr()
    var b = b_list.unsafe_ptr()
    var i = 0
    while i + 64 <= n:
        if a.load[width=64](i).ne(b.load[width=64](i)).reduce_or():
            break
        i += 64
    while i < n:
        if a[i] != b[i]:
            return i
        i += 1
    return -1


def _arena(n: Int, fill: UInt8) -> List[UInt8]:
    """An `n`-byte arena filled by one memset: the list takes its length
    uninitialized, so no per-element fill of several MiB dominates the
    test's run time (UInt8 has no per-element teardown either)."""
    var a = List[UInt8](capacity=n)
    a.resize(unsafe_uninit_length=n)
    unsafe_memset(a.unsafe_ptr(), fill, n)
    return a^


def _check_nt_copy(n: Int, dst_off: Int, src_off: Int) raises -> None:
    var src_total = n + src_off + PAD
    var src = _arena(src_total, 0)
    # `_pattern` has period 256: build one period, then tile it by memcpy.
    var period = InlineArray[UInt8, 256](fill=0)
    for i in range(256):
        period[i] = _pattern(i)
    var filled = 0
    while filled < src_total:
        var step = min(256, src_total - filled)
        unsafe_memcpy(
            dest=src.unsafe_ptr() + filled, src=period.unsafe_ptr(), count=step
        )
        filled += step
    var arena = n + dst_off + PAD
    var mine = _arena(arena, GUARD)
    var oracle = _arena(arena, GUARD)

    fast_copy_bytes[nt_ok=True](
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
    var at = _first_diff(mine, oracle, arena)
    var got = Int(mine[at]) if at >= 0 else -1
    var exp = Int(oracle[at]) if at >= 0 else -1
    if at >= 0:
        print(
            "NT MISMATCH n=", n, " dst_off=", dst_off, " src_off=", src_off,
            " at=", at, " mine=", got, " oracle=", exp,
        )
    assert_equal(at, -1, "fast_copy_bytes[nt_ok] diverged from memcpy")


def test_nt_ok_auto_byte_oracle() raises -> None:
    """NT_MIN itself, and NT_MIN + 37 (a tail that is not a multiple of 32)
    with a destination that is not 32-byte aligned."""
    _check_nt_copy(NT_MIN, 0, 0)
    _check_nt_copy(NT_MIN + 37, 3, 1)


# =============================================================================
# X3 — _copy_small(n=0) touches nothing.
# =============================================================================


def test_copy_small_zero_writes_nothing() raises -> None:
    """The destination pointer sits in the middle of a guard-filled buffer:
    a zero-length call that stored anything (the 1..3 arm stores d[0], d[n>>1]
    and d[n-1], i.e. d[-1] at n = 0) changes a guard byte."""
    var src = List[UInt8](length=8, fill=0x11)
    var dst = List[UInt8](length=8, fill=GUARD)
    # FFI-BOUNDARY: `_copy_small`'s raw-pointer signature spells its
    # destination with MutUntrackedOrigin, so the pointer into `dst` is cast
    # to it (tests/pointer_lint_ffi.tsv lists this file). Ownership: `dst`
    # owns and frees the bytes when this test returns; `_copy_small` only
    # borrows the pointer for the call and neither stores nor frees it.
    var d = dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]() + 4
    var s = Span(src).as_imm().unsafe_ptr().unsafe_origin_cast[
        ImmUntrackedOrigin
    ]() + 4
    # A runtime zero: `_copy_small` is `@always_inline`, and a literal 0 folds
    # the guard away at compile time instead of running it.
    var sizes: List[Int] = [0]
    _copy_small(d, s, sizes[0])
    for i in range(8):
        assert_equal(dst[i], GUARD, "_copy_small(n=0) wrote at " + String(i))


# =============================================================================
# X4 — fast_move_bytes empty and one-byte.
# =============================================================================


def test_fast_move_empty_and_one() raises -> None:
    var src: List[UInt8] = [0x42, 0x43]
    var dst = List[UInt8](length=2, fill=GUARD)
    # Runtime lengths, for the same folding reason as X3.
    var lens: List[Int] = [0, 1]
    fast_move_bytes(
        Span[UInt8, origin_of(dst)](unsafe_ptr=dst.unsafe_ptr(), length=lens[0]),
        Span[UInt8, origin_of(src)](unsafe_ptr=src.unsafe_ptr(), length=lens[0]),
    )
    assert_equal(dst[0], GUARD, "empty move wrote byte 0")
    assert_equal(dst[1], GUARD, "empty move wrote byte 1")
    fast_move_bytes(
        Span[UInt8, origin_of(dst)](unsafe_ptr=dst.unsafe_ptr(), length=lens[1]),
        Span[UInt8, origin_of(src)](unsafe_ptr=src.unsafe_ptr(), length=lens[1]),
    )
    assert_equal(dst[0], UInt8(0x42), "one-byte move did not move")
    assert_equal(dst[1], GUARD, "one-byte move wrote past its end")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
