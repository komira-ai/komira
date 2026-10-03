# =============================================================================
# CALL-SITE ORACLE — the five buffer-copy sites that route through
# `fast_copy_bytes` unconditionally.
# =============================================================================
#
# # Why this file exists, and what the two EXISTING fast_copy tests do NOT do
#
# `test_fast_copy_byte_oracle.mojo` and `test_fast_copy_size_ladder.mojo` both
# call `fast_copy_bytes` DIRECTLY, and the ladder forces every variant
# explicitly. They are excellent tests of the PRIMITIVE — and they pass
# BYTE-IDENTICALLY however the buffer-copy sites are wired. Neither one is
# evidence that those five branches are reachable, correct, or even compiled.
#
# This file closes exactly that gap. It drives the FIVE buffer-copy call
# sites through a size x offset ladder, byte-comparing every one against
# stdlib `memcpy` over a GUARDED arena.
#
#   arrow/owned_aligned_buffer.mojo     OwnedAlignedBuffer.copy_from_view
#   arrow/owned_aligned_buffer.mojo     OwnedAlignedBuffer.copy_from_view_at
#   arrow/shared_aligned_buffer.mojo    SharedAlignedBuffer.copy_from_view
#   arrow/shared_aligned_buffer.mojo    SharedAlignedBuffer.copy_from_view_at
#   collections/byte_view.mojo          ByteView.copy_from_view_at
#
# ⚠ OTHER SITES CALL `fast_copy_bytes` TOO — the variable-width gather in
# `helpers/compiler_helpers.mojo` and the PLAIN decoder in `komira_parquet`.
# Do not read a green here as covering them.
#
# # Why the comparison is whole-ARENA
#
# Same reason as the byte oracle: the risk in a hand-rolled copy is the EDGES.
# `_copy_large_unrolled` writes an unaligned 32 B head, realigns, and anchors
# an OVERLAPPING 32 B tail store at `n - 32`. A range-only check cannot see a
# splattered byte outside `[dst_off, dst_off + n)`. So the destination is
# pre-filled with a guard byte and EVERY byte of it is checked — the copied
# window against the source pattern, everything else against the guard.
#
# # Source pattern
#
# Byte `i` is `((i * 167) + 13) & 0xFF` — position-dependent with no repeat at
# any stride the copy uses, so a read from the wrong source offset or a write
# to the wrong destination offset MISMATCHES rather than landing on
# accidentally-correct bytes.
#
# Coverage:
#   C0  the AUTO-ladder thresholds hold the values the dispatch analysis
#       was done against.
#   C1  OwnedAlignedBuffer.copy_from_view      (dst offset 0, updates _length)
#   C2  OwnedAlignedBuffer.copy_from_view_at   (dst offset != 0)
#   C3  SharedAlignedBuffer.copy_from_view
#   C4  SharedAlignedBuffer.copy_from_view_at
#   C5  ByteView.copy_from_view_at
#   C6  VARIANT_AUTO across the `LIBC_MIN` handoff — the ONE arm of the
#       production ladder the byte oracle never reaches, because its ladder
#       stops at 65536 and `LIBC_MIN` is 262144.
#   C7  meta-test: `_assert_arena` is proven to FAIL on a one-byte overrun and
#       on a one-byte in-range corruption. Without it every PASS above would
#       be worth nothing.
#
# ⛔ WHAT THIS FILE CANNOT PIN, STATED SO NOBODY MISREADS THE GREEN.
# Non-temporal stores are unreachable from every call site because `nt_ok`
# defaults False and nothing outside `fast_copy.mojo` passes it. That is a
# property of the CALL SITES, not of this module, so no in-Mojo assertion can
# hold it. The falsifier is a word-anchored source search for `\bnt_ok\b`
# outside `komira_simd/fast_copy.mojo`, and it must come back EMPTY. If it
# ever finds a line, `VARIANT_AUTO` can select `vmovntdq` at that site and the
# NT-store caveat in `fast_copy.mojo`'s header applies to it.
#
# ⚠ THE WORD ANCHORS ARE LOAD-BEARING. An unanchored search SUBSTRING-matches
# `clie[nt_ok]`, `se[nt_ok]` and `_assert_hi[nt_ok]` and returns dozens of
# lines where the real answer is ZERO — a falsifier that is red on arrival is
# one nobody reads.
# =============================================================================

from std.memory import unsafe_memcpy
from std.testing import assert_equal, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_simd.fast_copy import (
    fast_copy_bytes,
    LIBC_MIN,
    ERMS_MIN,
    ERMS_MAX,
    MID_MAX,
    NT_MIN,
    SMALL_MAX,
)


# =============================================================================
# Helpers
# =============================================================================

# Byte written everywhere the copy must NOT touch.
comptime GUARD: UInt8 = 0xA5
# Guard padding on each side of the destination window.
comptime PAD: Int = 128


@always_inline
def _pattern(i: Int) -> UInt8:
    """Position-dependent source byte. See module header."""
    return UInt8(((i * 167) + 13) & 0xFF)


def _make_src(total: Int) -> OwnedAlignedBuffer:
    """A source buffer carrying the position-dependent pattern."""
    var b = OwnedAlignedBuffer(total)
    for i in range(total):
        b.write_u8_at(i, _pattern(i))
    return b^


def _make_guarded_dst(total: Int) -> OwnedAlignedBuffer:
    """A destination buffer filled entirely with the guard byte."""
    var b = OwnedAlignedBuffer(total)
    for i in range(total):
        b.write_u8_at(i, GUARD)
    return b^


def _assert_arena(
    v: ByteView[_],
    total: Int,
    dst_off: Int,
    n: Int,
    src_off: Int,
    label: String,
) raises -> None:
    """Whole-arena check: `[dst_off, dst_off+n)` must equal the source pattern
    starting at `src_off`; EVERY other byte must still be the guard."""
    assert_equal(v.len(), total, "arena view length")
    for i in range(total):
        var got = v.read_u8_at(i)
        var in_range = i >= dst_off and i < dst_off + n
        var want = GUARD
        if in_range:
            want = _pattern(src_off + (i - dst_off))
        if got != want:
            var region = String("GUARD-OVERRUN")
            if in_range:
                region = String("IN-RANGE")
            print(
                "MISMATCH site=", label,
                " total=", total, " dst_off=", dst_off, " n=", n,
                " src_off=", src_off, " at idx=", i, " (", region, ")",
                " got=", Int(got), " want=", Int(want),
            )
            assert_true(
                False,
                "a buffer-copy call site diverged from stdlib memcpy",
            )


# The size ladder crosses every boundary of the production AUTO dispatch:
# the `_copy_small` arms (<4, <8, <16, <32), the `_copy_mid` arms (<=64,
# <=128), and the `_copy_large_unrolled` 128 B main loop / 32 B drain / 32 B
# overlapping tail. `LIBC_MIN` is crossed separately in C6 — at 256 KiB a
# 144-case cross-product would dominate this test's wall for no extra signal.
def _ladder() -> List[Int]:
    return [
        0, 1, 2, 3, 4, 7, 8, 15, 16, 17, 31, 32, 33, 63, 64, 65,
        127, 128, 129, 130, 159, 160, 161, 255, 256, 257, 4095, 4096, 4097,
    ]


# Destination offsets spanning byte / 8 / 16 / the 32 B boundary the large
# path realigns to (31 and 33 are the head==1 and head==31 arms).
def _dst_offsets() -> List[Int]:
    return [0, 1, 7, 8, 15, 16, 31, 32, 33, 63]


# =============================================================================
# C0 — the ladder thresholds.
# =============================================================================
#
# The routing to `fast_copy_bytes` at the five sites is STRUCTURAL: there is no
# gate or `memcpy` else-arm to flip, so there is no constant to assert. Each of
# C1..C5 byte-compares its call site against an independently computed stdlib
# `memcpy` over a guarded arena, i.e. an ABSOLUTE oracle, not a differential
# against an alternative arm. ⚠ Consequently nothing here can distinguish
# `fast_copy_bytes` from stdlib `memcpy` at these sites -- a correct copy and a
# correct copy agree on every byte.


def test_auto_ladder_thresholds() raises -> None:
    """The AUTO dispatch thresholds this file's analysis was written against.

    Not arbitrary pinning: the claim `VARIANT_AUTO` never reaches a non-temporal
    store at any call site rests on `nt_ok` (see the header grep) AND on NT
    living above the libc handoff. A retune that moved `NT_MIN` below
    `LIBC_MIN`, or `LIBC_MIN` down into morsel-sized copies, changes which arm
    the five gated sites take and must be a deliberate edit here.

    The four values below are the whole assertion. The ORDERING they satisfy
    (SMALL_MAX <= MID_MAX < LIBC_MIN <= NT_MIN) is deliberately NOT asserted
    separately: every one of these is a `comptime` constant, so an ordering
    check folds to `if True` at compile time and the compiler says so. It
    would read as a live invariant while testing nothing.

    ⛔ AND THAT IS WHY THIS FUNCTION IS NOT THE LADDER'S REGRESSION TEST, AND
    MUST NOT BE MISTAKEN FOR ONE. `assert_equal(LIBC_MIN, 262144)` stays green
    through a real class of defect, because such a defect is not a wrong
    NUMBER — the number is right and the ARM it points at stops being the
    fast one underneath it (for example when a hermetic toolchain links a
    compiler-runtime `memmove` in place of glibc's). What pins the routing is
    `test_fast_copy_erms_band.test_route_ladder`, which asserts WHICH ARM a
    size takes, through the ladder the dispatch itself calls. This function's
    job is narrower: the five call sites' analysis rests on NT living above
    the libc handoff, so a retune that moved these has to be a deliberate
    edit HERE as well as there."""
    assert_equal(SMALL_MAX, 32, "SMALL_MAX")
    assert_equal(MID_MAX, 128, "MID_MAX")
    assert_equal(LIBC_MIN, 262144, "LIBC_MIN")
    assert_equal(NT_MIN, 4194304, "NT_MIN")
    # The ERMS band. It is asserted here for the same reason
    # the four above are: `VARIANT_AUTO` now reaches `rep movsb` before it
    # reaches either `memmove` or the NT arm, so the claim this file makes
    # about which arm the five gated sites take depends on these two values.
    assert_equal(ERMS_MIN, 131072, "ERMS_MIN")
    assert_equal(ERMS_MAX, 16777216, "ERMS_MAX")
    print("C0b AUTO ladder thresholds: PASS")


# =============================================================================
# C1 / C2 — OwnedAlignedBuffer.
# =============================================================================


def test_oab_copy_from_view() raises -> None:
    """`copy_from_view` copies to offset 0 and sets `_length = count`. The
    arena beyond `count` must be untouched, so `_length` is restored before
    the whole-arena read."""
    var sizes = _ladder()
    var src = _make_src(4097 + 64)

    for si in range(len(sizes)):
        var n = sizes[si]
        var total = n + PAD
        var dst = _make_guarded_dst(total)
        dst.copy_from_view(src.view_range_ro(0, n))
        assert_equal(dst.len(), n, "copy_from_view must set _length = count")
        dst.set_length(Int64(total))
        _assert_arena(
            dst.view_range_ro(0, total), total, 0, n, 0,
            String("OwnedAlignedBuffer.copy_from_view"),
        )

    print("C1 OwnedAlignedBuffer.copy_from_view: PASS")


def test_oab_copy_from_view_at() raises -> None:
    """`copy_from_view_at` writes at a non-zero destination offset and does NOT
    touch `_length`. Guarded on BOTH sides."""
    var sizes = _ladder()
    var offs = _dst_offsets()
    var src = _make_src(4097 + 64)

    for si in range(len(sizes)):
        var n = sizes[si]
        for oi in range(len(offs)):
            var dst_off = PAD + offs[oi]
            var src_off = offs[oi] & 7
            var total = dst_off + n + PAD
            var dst = _make_guarded_dst(total)
            dst.copy_from_view_at(dst_off, src.view_range_ro(src_off, n))
            assert_equal(
                dst.len(), total,
                "copy_from_view_at must NOT change _length",
            )
            _assert_arena(
                dst.view_range_ro(0, total), total, dst_off, n, src_off,
                String("OwnedAlignedBuffer.copy_from_view_at"),
            )

    print("C2 OwnedAlignedBuffer.copy_from_view_at: PASS")


# =============================================================================
# C3 / C4 — SharedAlignedBuffer.
# =============================================================================


def _shared(total: Int) -> SharedAlignedBuffer[HeapRegion]:
    """Guard-filled SharedAlignedBuffer via the canonical from_owned path."""
    return SharedAlignedBuffer[HeapRegion].from_owned(_make_guarded_dst(total))


def test_sab_copy_from_view() raises -> None:
    var sizes = _ladder()
    var src = _make_src(4097 + 64)

    for si in range(len(sizes)):
        var n = sizes[si]
        var total = n + PAD
        var dst = _shared(total)
        dst.copy_from_view(src.view_range_ro(0, n))
        assert_equal(dst.len(), n, "copy_from_view must set _length = count")
        dst.set_length(Int64(total))
        _assert_arena(
            dst.view_range_ro(0, total), total, 0, n, 0,
            String("SharedAlignedBuffer.copy_from_view"),
        )

    print("C3 SharedAlignedBuffer.copy_from_view: PASS")


def test_sab_copy_from_view_at() raises -> None:
    var sizes = _ladder()
    var offs = _dst_offsets()
    var src = _make_src(4097 + 64)

    for si in range(len(sizes)):
        var n = sizes[si]
        for oi in range(len(offs)):
            var dst_off = PAD + offs[oi]
            var src_off = offs[oi] & 7
            var total = dst_off + n + PAD
            var dst = _shared(total)
            dst.copy_from_view_at(dst_off, src.view_range_ro(src_off, n))
            assert_equal(
                dst.len(), total,
                "copy_from_view_at must NOT change _length",
            )
            _assert_arena(
                dst.view_range_ro(0, total), total, dst_off, n, src_off,
                String("SharedAlignedBuffer.copy_from_view_at"),
            )

    print("C4 SharedAlignedBuffer.copy_from_view_at: PASS")


# =============================================================================
# C5 — ByteView.copy_from_view_at (the codec literal-emit spelling).
# =============================================================================


def _bv_copy(mut dst: OwnedAlignedBuffer, off: Int, src: ByteView[_]) -> None:
    """Drive the ByteView site: take a MUTABLE view of `dst` and copy through
    it. Scoped in a helper so the mutable borrow ends before the read-back."""
    dst.view_mut().copy_from_view_at(off, src)


def test_byte_view_copy_from_view_at() raises -> None:
    var sizes = _ladder()
    var offs = _dst_offsets()
    var src = _make_src(4097 + 64)

    for si in range(len(sizes)):
        var n = sizes[si]
        for oi in range(len(offs)):
            var dst_off = PAD + offs[oi]
            var src_off = offs[oi] & 7
            var total = dst_off + n + PAD
            var dst = _make_guarded_dst(total)
            _bv_copy(dst, dst_off, src.view_range_ro(src_off, n))
            _assert_arena(
                dst.view_range_ro(0, total), total, dst_off, n, src_off,
                String("ByteView.copy_from_view_at"),
            )

    print("C5 ByteView.copy_from_view_at: PASS")


# =============================================================================
# C6 — the VARIANT_AUTO `LIBC_MIN` handoff.
#
# The byte oracle's ladder stops at 65536, so the production arm
# `n >= LIBC_MIN -> _copy_libc` is DISPATCHED TO by nothing it runs. The arm's
# implementation is covered there (as forced `VARIANT_LIBC`); what is not
# covered is AUTO actually taking it, and the sizes at which it does. The five
# gated sites copy whole Arrow buffers, so they cross this boundary routinely
# — a 64K-row Int32 offsets buffer is 262 148 bytes, four bytes over it.
# =============================================================================


def test_auto_crosses_libc_handoff() raises -> None:
    """VARIANT_AUTO must be byte-identical to stdlib memcpy on both sides of
    the `LIBC_MIN` handoff, with no write outside `[dst_off, dst_off+n)`."""
    var sizes: List[Int] = [LIBC_MIN - 1, LIBC_MIN, LIBC_MIN + 1]
    var offs: List[Int] = [0, 1, 31, 32]

    var src_total = LIBC_MIN + 1 + 64
    var src = List[UInt8](length=src_total, fill=0)
    for i in range(src_total):
        src[i] = _pattern(i)

    for si in range(len(sizes)):
        var n = sizes[si]
        for oi in range(len(offs)):
            var dst_off = PAD + offs[oi]
            var src_off = offs[oi] & 7
            var total = dst_off + n + PAD

            var mine = List[UInt8](length=total, fill=GUARD)
            var oracle = List[UInt8](length=total, fill=GUARD)

            unsafe_memcpy(
                dest=oracle.unsafe_ptr() + dst_off,
                src=src.unsafe_ptr() + src_off,
                count=n,
            )
            fast_copy_bytes(
                Span[UInt8, origin_of(mine)](
                    unsafe_ptr=mine.unsafe_ptr() + dst_off, length=n
                ),
                Span[UInt8, origin_of(src)](
                    unsafe_ptr=src.unsafe_ptr() + src_off, length=n
                ),
            )

            for i in range(total):
                if mine[i] != oracle[i]:
                    var region = String("GUARD-OVERRUN")
                    if i >= dst_off and i < dst_off + n:
                        region = String("IN-RANGE")
                    print(
                        "MISMATCH AUTO@LIBC_MIN n=", n, " dst_off=", dst_off,
                        " src_off=", src_off, " at idx=", i, " (", region, ")",
                        " mine=", Int(mine[i]), " oracle=", Int(oracle[i]),
                    )
                    assert_true(
                        False,
                        "VARIANT_AUTO diverged from stdlib memcpy across the"
                        " LIBC_MIN handoff",
                    )

    print("C6 VARIANT_AUTO across the LIBC_MIN handoff: PASS")


# =============================================================================
# C7 — meta-test: the arena checker can actually fail.
#
# `_assert_arena` raises, so it cannot be called in the failing direction and
# asserted on. This re-implements its comparison inline over a deliberately
# corrupted arena and asserts the comparison FINDS the corruption — the same
# shape as the byte oracle's O3, over this file's own checker.
# =============================================================================


def _arena_diverges(
    v: ByteView[_], total: Int, dst_off: Int, n: Int, src_off: Int
) -> Bool:
    """`_assert_arena`'s predicate, in the boolean direction."""
    for i in range(total):
        var want = GUARD
        if i >= dst_off and i < dst_off + n:
            want = _pattern(src_off + (i - dst_off))
        if v.read_u8_at(i) != want:
            return True
    return False


def test_arena_checker_detects_corruption() raises -> None:
    """A correct copy must compare clean; a 1-byte write just past the window,
    a 1-byte write just before it, and a 1-byte flip INSIDE it must each be
    caught. If any of these were missed, C1-C5 would be vacuous."""
    var n = 200
    var dst_off = PAD
    var total = dst_off + n + PAD
    var src = _make_src(n + 64)

    var dst = _make_guarded_dst(total)
    dst.copy_from_view_at(dst_off, src.view_range_ro(0, n))

    # Positive control: the real copy compares clean.
    assert_true(
        not _arena_diverges(dst.view_range_ro(0, total), total, dst_off, n, 0),
        "meta-test setup: a correct copy must compare clean",
    )

    # Overrun one byte past the copied window.
    dst.write_u8_at(dst_off + n, GUARD ^ 0xFF)
    assert_true(
        _arena_diverges(dst.view_range_ro(0, total), total, dst_off, n, 0),
        "arena check FAILED to detect a 1-byte overrun past the window",
    )
    dst.write_u8_at(dst_off + n, GUARD)

    # Underrun one byte before the copied window.
    dst.write_u8_at(dst_off - 1, GUARD ^ 0xFF)
    assert_true(
        _arena_diverges(dst.view_range_ro(0, total), total, dst_off, n, 0),
        "arena check FAILED to detect a 1-byte underrun before the window",
    )
    dst.write_u8_at(dst_off - 1, GUARD)

    # Corrupt one byte INSIDE the copied window (a wrong-source-offset read
    # looks like this, not like an overrun).
    var mid = dst_off + (n >> 1)
    dst.write_u8_at(mid, dst.read_u8_at(mid) ^ 0xFF)
    assert_true(
        _arena_diverges(dst.view_range_ro(0, total), total, dst_off, n, 0),
        "arena check FAILED to detect a 1-byte corruption inside the window",
    )

    print("C7 arena checker meta-test (the check can fail): PASS")


# =============================================================================
# Entrypoint
# =============================================================================


def main() raises -> None:
    test_arena_checker_detects_corruption()
    test_auto_ladder_thresholds()
    test_oab_copy_from_view()
    test_oab_copy_from_view_at()
    test_sab_copy_from_view()
    test_sab_copy_from_view_at()
    test_byte_view_copy_from_view_at()
    test_auto_crosses_libc_handoff()
    print("fast_copy call-site pin: ALL PASS")
