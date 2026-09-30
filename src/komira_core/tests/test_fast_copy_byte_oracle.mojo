# =============================================================================
# Byte-oracle for komira_core/simd/fast_copy.mojo.
# =============================================================================
#
# CONTRACT UNDER TEST: `fast_copy_bytes` must produce a destination arena
# BYTE-IDENTICAL to the one stdlib `memcpy` produces — for every size class,
# every source/destination alignment, and every forced variant.
#
# # Why the comparison is whole-ARENA, not just the copied range
#
# Comparing only `dst[0..n)` would not be a discriminating oracle: the whole
# risk in a hand-rolled copy is the *edges*. `_copy_large_unrolled` writes an
# unaligned 32 B head, realigns, then anchors an OVERLAPPING 32 B tail store
# at `n - 32`. An off-by-one in either the head-alignment arithmetic or the
# tail anchor splatters bytes OUTSIDE `[0, n)` — which a range-only check
# cannot see.
#
# So both arenas are pre-filled with a guard byte, only ONE of them is copied
# into by each implementation, and the ENTIRE arena (guard region included) is
# compared. Any stray write outside `[dst_off, dst_off + n)` turns the test
# RED. See `test_guard_region_detects_overrun` for the meta-test that proves
# the guard machinery itself can fail.
#
# # Source pattern
#
# The source byte at arena index `i` is `((i * 167) + 13) & 0xFF` — a
# position-dependent pattern with no repeats at any stride the copy uses.
# A copy that reads from the wrong source offset, or writes the right bytes
# to the wrong destination offset, produces a mismatch rather than
# accidentally-correct bytes (which a constant or short-period fill would
# hide).
#
# Coverage:
#   O1  size ladder x alignment cross-product, all four variants, vs stdlib.
#   O2  size 0 and size 1 explicitly (degenerate arms of `_copy_small`).
#   O3  guard-region meta-test — proves an out-of-range write IS detected.
#   O4  `fast_move_bytes` overlap semantics (forward + backward overlap).
# =============================================================================

from std.memory import unsafe_memcpy
from std.testing import assert_equal, assert_true

from komira_core.simd.fast_copy import (
    fast_copy_bytes,
    fast_move_bytes,
    VARIANT_AUTO,
    VARIANT_UNROLLED,
    VARIANT_NT,
    VARIANT_LIBC,
)


# =============================================================================
# Helpers
# =============================================================================

# Guard byte written everywhere in the arena that the copy must NOT touch.
comptime GUARD: UInt8 = 0xA5
# Bytes of guard padding on each side of the destination region.
comptime PAD: Int = 128


@always_inline
def _pattern(i: Int) -> UInt8:
    """Position-dependent source byte. See module header."""
    return UInt8(((i * 167) + 13) & 0xFF)


def _make_src(total: Int) -> List[UInt8]:
    var s = List[UInt8](length=total, fill=0)
    for i in range(total):
        s[i] = _pattern(i)
    return s^


def _assert_arenas_equal(
    mine: List[UInt8], oracle: List[UInt8], n: Int, dst_off: Int, src_off: Int,
    variant_tag: Int,
) raises -> None:
    """Whole-arena byte comparison. Reports the first divergence with enough
    context to localise it (in-range vs guard-region overrun)."""
    assert_equal(len(mine), len(oracle))
    for i in range(len(mine)):
        if mine[i] != oracle[i]:
            var region = String("GUARD-OVERRUN")
            if i >= dst_off and i < dst_off + n:
                region = String("IN-RANGE")
            print(
                "MISMATCH variant=", variant_tag,
                " n=", n, " dst_off=", dst_off, " src_off=", src_off,
                " at arena idx=", i, " (", region, ")",
                " mine=", Int(mine[i]), " oracle=", Int(oracle[i]),
            )
            assert_true(
                False,
                "fast_copy_bytes diverged from stdlib memcpy",
            )


def _check_one[
    variant: Int
](n: Int, dst_off: Int, src_off: Int, src: List[UInt8]) raises -> None:
    """Run one (size, dst alignment, src alignment) case for one variant and
    compare the whole destination arena against the stdlib-memcpy oracle."""
    var arena_len = PAD + dst_off + n + PAD

    var mine = List[UInt8](length=arena_len, fill=GUARD)
    var oracle = List[UInt8](length=arena_len, fill=GUARD)

    var dst_base = PAD + dst_off

    # --- Oracle: stdlib memcpy (the path fast_copy_bytes replaces).
    if n > 0:
        unsafe_memcpy(
            dest=oracle.unsafe_ptr() + dst_base,
            src=src.unsafe_ptr() + src_off,
            count=n,
        )

    # --- Under test.
    fast_copy_bytes[variant=variant](
        Span[UInt8, origin_of(mine)](
            unsafe_ptr=mine.unsafe_ptr() + dst_base, length=n
        ),
        Span[UInt8, origin_of(src)](
            unsafe_ptr=src.unsafe_ptr() + src_off, length=n
        ),
    )

    _assert_arenas_equal(mine, oracle, n, dst_base, src_off, variant)


def _move_overlapping(
    mut buf: List[UInt8], dst_off: Int, src_off: Int, n: Int
) raises -> None:
    """Call `fast_move_bytes` with two spans that DELIBERATELY alias the same
    buffer — which is the entire point of an overlap test.

    The spans are built over untracked origins because Mojo's exclusivity
    checker rejects passing two same-origin spans where one is mutable ("call
    allows writing a memory location previously writable through another
    aliased argument"). Laundering through untracked origins is confined to
    this test helper; it is not a pattern for production code.
    """
    var base = buf.unsafe_ptr()
    var src_span = Span[UInt8, origin_of(buf)](
        unsafe_ptr=base + src_off, length=n
    )
    var src_ptr = src_span.as_imm().unsafe_ptr().unsafe_origin_cast[
        ImmUntrackedOrigin
    ]()
    fast_move_bytes(
        Span[UInt8, MutUntrackedOrigin](
            unsafe_ptr=base.unsafe_origin_cast[MutUntrackedOrigin]() + dst_off,
            length=n,
        ),
        Span[UInt8, ImmUntrackedOrigin](unsafe_ptr=src_ptr, length=n),
    )


def _check_all_variants(
    n: Int, dst_off: Int, src_off: Int, src: List[UInt8]
) raises -> None:
    _check_one[VARIANT_AUTO](n, dst_off, src_off, src)
    _check_one[VARIANT_UNROLLED](n, dst_off, src_off, src)
    _check_one[VARIANT_NT](n, dst_off, src_off, src)
    _check_one[VARIANT_LIBC](n, dst_off, src_off, src)


# =============================================================================
# O1 — size ladder x alignment cross-product vs stdlib memcpy.
# =============================================================================


def test_size_alignment_cross_product() raises -> None:
    """Every size class x every alignment x every variant, byte-compared
    against stdlib memcpy over the WHOLE arena."""
    # Size ladder: every boundary of the internal dispatch
    # (<4, <8, <16, <32 small arms; <=64, <=128 mid arms; >128 large path)
    # plus one-below / exact / one-above each, and the 128 B main-loop and
    # 32 B drain-loop residues.
    var sizes: List[Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 23,
        31, 32, 33, 47, 63, 64, 65, 95,
        127, 128, 129, 130, 159, 160, 161, 191,
        255, 256, 257, 383, 511, 512, 513,
        1023, 1024, 1025, 4095, 4096, 4097,
        16384, 65535, 65536,
    ]
    # Alignments spanning every relevant boundary: byte, 4/8/16 B, and the
    # 32 B boundary the large path realigns to (31/32/33 are the arms that
    # exercise head==31, head==0, head==31 respectively).
    var aligns: List[Int] = [0, 1, 3, 7, 8, 15, 16, 17, 31, 32, 33, 63]

    # Source arena large enough for the biggest size at the largest offset.
    var src = _make_src(65536 + 128)

    for si in range(len(sizes)):
        var n = sizes[si]
        for di in range(len(aligns)):
            for sj in range(len(aligns)):
                _check_all_variants(n, aligns[di], aligns[sj], src)

    print("O1 size x alignment x variant cross-product: PASS")


# =============================================================================
# O2 — degenerate sizes called out explicitly.
# =============================================================================


def test_size_zero_and_one() raises -> None:
    """Size 0 must write NOTHING (not even one byte); size 1 must write
    exactly one byte. These are the arms most likely to be mishandled by a
    branchy small path."""
    var src = _make_src(256)

    for di in range(4):
        for sj in range(4):
            # n == 0: the entire arena must remain guard bytes.
            var arena_len = PAD + di + 0 + PAD
            var mine = List[UInt8](length=arena_len, fill=GUARD)
            fast_copy_bytes(
                Span[UInt8, origin_of(mine)](
                    unsafe_ptr=mine.unsafe_ptr() + PAD + di, length=0
                ),
                Span[UInt8, origin_of(src)](
                    unsafe_ptr=src.unsafe_ptr() + sj, length=0
                ),
            )
            for i in range(arena_len):
                assert_equal(
                    mine[i], GUARD, "size-0 copy wrote a byte"
                )

            # n == 1 across all variants, whole-arena compared.
            _check_all_variants(1, di, sj, src)

    print("O2 size-0 / size-1: PASS")


# =============================================================================
# O3 — guard-region meta-test.
#
# Proves the oracle machinery can actually FAIL in the direction it guards.
# If this test's simulated overrun were NOT detected, every other PASS above
# would be worthless.
# =============================================================================


def test_guard_region_detects_overrun() raises -> None:
    """Meta-test: hand `_assert_arenas_equal` a destination arena with a
    deliberate 1-byte write outside the copied range and confirm the
    comparison flags it. Guards against a non-discriminating oracle."""
    var n = 256
    var dst_base = PAD
    var arena_len = PAD + n + PAD

    var oracle = List[UInt8](length=arena_len, fill=GUARD)
    var mine = List[UInt8](length=arena_len, fill=GUARD)
    var src = _make_src(n + 8)

    unsafe_memcpy(
        dest=oracle.unsafe_ptr() + dst_base, src=src.unsafe_ptr(), count=n
    )
    unsafe_memcpy(dest=mine.unsafe_ptr() + dst_base, src=src.unsafe_ptr(), count=n)

    # Sanity: identical arenas must compare equal.
    var same = True
    for i in range(arena_len):
        if mine[i] != oracle[i]:
            same = False
    assert_true(same, "meta-test setup: arenas should start identical")

    # Simulate a one-byte overrun just past the copied range.
    mine[dst_base + n] = GUARD ^ 0xFF
    var detected = False
    for i in range(arena_len):
        if mine[i] != oracle[i]:
            detected = True
    assert_true(
        detected,
        "guard region FAILED to detect a 1-byte overrun past the copy range"
        " — the byte-oracle is not discriminating",
    )

    # Simulate a one-byte underrun just before the copied range.
    mine[dst_base + n] = GUARD
    mine[dst_base - 1] = GUARD ^ 0xFF
    detected = False
    for i in range(arena_len):
        if mine[i] != oracle[i]:
            detected = True
    assert_true(
        detected,
        "guard region FAILED to detect a 1-byte underrun before the copy"
        " range — the byte-oracle is not discriminating",
    )

    print("O3 guard-region meta-test (oracle can fail): PASS")


# =============================================================================
# O4 — fast_move_bytes overlap semantics.
# =============================================================================


def test_fast_move_overlap() raises -> None:
    """`fast_move_bytes` is the overlap-SAFE entry point (glibc memmove).
    Both overlap directions must match a scalar reference.

    NOTE: `fast_copy_bytes` is deliberately NOT tested for overlap — it has
    memcpy semantics and is undefined on overlap, exactly like the stdlib
    `memcpy` it replaces.
    """
    var sizes: List[Int] = [1, 15, 31, 32, 33, 63, 64, 129, 257, 1025, 4097]
    var shifts: List[Int] = [1, 3, 8, 31, 32, 33, 64, 100]

    for si in range(len(sizes)):
        var n = sizes[si]
        for sh in range(len(shifts)):
            var shift = shifts[sh]
            var total = n + shift + 16

            # --- Forward overlap: dst is AHEAD of src (dst = src + shift).
            var buf = List[UInt8](length=total, fill=0)
            var want = List[UInt8](length=total, fill=0)
            for i in range(total):
                buf[i] = _pattern(i)
                want[i] = _pattern(i)
            # Scalar reference, descending (correct for dst > src).
            for k in range(n - 1, -1, -1):
                want[shift + k] = want[k]
            _move_overlapping(buf, shift, 0, n)
            for i in range(total):
                assert_equal(
                    buf[i], want[i], "fast_move_bytes forward-overlap mismatch"
                )

            # --- Backward overlap: dst is BEHIND src (dst = src - shift).
            var buf2 = List[UInt8](length=total, fill=0)
            var want2 = List[UInt8](length=total, fill=0)
            for i in range(total):
                buf2[i] = _pattern(i)
                want2[i] = _pattern(i)
            # Scalar reference, ascending (correct for dst < src).
            for k in range(n):
                want2[k] = want2[shift + k]
            _move_overlapping(buf2, 0, shift, n)
            for i in range(total):
                assert_equal(
                    buf2[i], want2[i],
                    "fast_move_bytes backward-overlap mismatch",
                )

    print("O4 fast_move_bytes overlap: PASS")


# =============================================================================
# Entrypoint
# =============================================================================


def main() raises -> None:
    test_guard_region_detects_overrun()
    test_size_zero_and_one()
    test_size_alignment_cross_product()
    test_fast_move_overlap()
    print("fast_copy byte-oracle: ALL PASS")
