# =============================================================================
# test_byte_equal_simd.mojo — `komira_simd.byte_class.byte_equal` must
# answer EXACTLY what a byte-at-a-time walk answers, at every length, at every
# differing byte position, at every start residue mod 32.
# =============================================================================
#
# WHY THIS TEST EXISTS
# --------------------
# `bytes_equal` is a bulk loop plus ONE overlapping tail block anchored at the
# END of the span. Its characteristic defect is therefore not a crash and not
# a wrong length — it is a HOLE: a run of bytes in the middle that no block
# covers. A hole is INVISIBLE to every ordinary test, because equal inputs
# still compare equal and the only inputs it gets wrong are near-misses whose
# sole difference falls inside it. In production that is a silently mis-joined
# row, not a failure.
#
# So the load-bearing leg here is `test_every_byte_position_is_compared`: for
# EVERY length 0..80 and EVERY position p in [0, n), a pair differing at
# exactly p must compare UNEQUAL. Nothing weaker finds a hole.
#
# THE ORACLE IS INDEPENDENT OF BOTH IMPLEMENTATIONS.
# Every assertion below is against `want`, computed from HOW THE FIXTURE WAS
# BUILT ("I perturbed exactly one byte, so these must be unequal") — not from
# `bytes_equal_scalar`. The scalar reference is then checked against the same
# `want`, so a mutation to EITHER implementation is caught. A "new kernel ==
# old kernel" check would be blind to any defect the two share, and would let
# the reference rot into agreement with a broken kernel.
#
# ⚠ RUN MUTATION CHECKS ON x86-64, NOT ON ARM64.
# The tail ladder's top rungs are `comptime`-guarded on
# `simd_width_of[DType.uint8]()`: W is 32 on AVX2 x86-64, but 16 on
# darwin/arm64, where the 32-byte and 16-byte rungs are COMPILED OUT. A mutant
# that edits the 16-byte rung is therefore VACUOUSLY GREEN on arm64 — the
# mutated code is not emitted.
#
# The codegen claims in `byte_equal.mojo`'s header come from `mojo build
# --emit asm --target-triple x86_64-unknown-linux-gnu --target-cpu raptorlake`
# over a probe that wraps `bytes_equal` in a `@no_inline` function (an
# `@always_inline` callee emits no symbol of its own, so the wrapper IS the
# measurement instrument). Drop `--target-*` for the native ARM64 sequence.
# =============================================================================

from std.random import random_si64, seed
from std.sys.info import simd_width_of
from std.testing import assert_equal, assert_true, assert_false

from komira_simd.byte_class.byte_equal import (
    bytes_equal,
    bytes_equal_scalar,
)


# -----------------------------------------------------------------------------
# Fixture substrate.
#
# ⚠ ONE backing buffer, not a fresh `List` per case, and that is load-bearing.
# A fresh allocation lands on a malloc-aligned address every time, so a
# per-case `List` would test start residue 0 and nothing else — and residue is
# exactly what an `alignment=1` claim and an overlapping-tail ladder are about.
# Placing every value at a chosen offset inside one buffer sweeps the residues.
# -----------------------------------------------------------------------------

comptime _BACKING: Int = 8192


def _backing() -> List[UInt8]:
    var b = List[UInt8]()
    for i in range(_BACKING):
        # A non-repeating, non-ASCII-only fill: high bytes (>= 0x80) are
        # present throughout, which is what kills a signed-char comparison.
        b.append(UInt8((i * 37 + 11) % 256))
    return b^


def _write(mut buf: List[UInt8], off: Int, src: List[UInt8]) -> None:
    for k in range(len(src)):
        buf[off + k] = src[k]


def _fill(v: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(UInt8(v))
    return out^


def _check(
    buf: List[UInt8], a_off: Int, b_off: Int, n: Int, want: Bool, ctx: String
) raises -> None:
    """Assert BOTH implementations against `want` — the answer derived from how
    the fixture was constructed, independent of either implementation."""
    var sa = Span(buf)[a_off : a_off + n]
    var sb = Span(buf)[b_off : b_off + n]
    assert_equal(bytes_equal(sa, sb), want, "bytes_equal: " + ctx)
    assert_equal(
        bytes_equal_scalar(sa, sb), want, "bytes_equal_scalar: " + ctx
    )


# -----------------------------------------------------------------------------
# T1 — empty spans and length mismatch (the two O(1) contract arms).
# -----------------------------------------------------------------------------

def test_empty_and_length_mismatch() raises:
    var buf = _backing()

    # Both empty -> equal, from two DIFFERENT (and differently-aligned)
    # offsets, so a "compares the pointers" mutant cannot pass.
    var e0 = Span(buf)[0:0]
    var e1 = Span(buf)[37:37]
    assert_true(bytes_equal(e0, e1), "empty == empty")
    assert_true(bytes_equal_scalar(e0, e1), "empty == empty (scalar)")

    # Length mismatch -> unequal, EVEN WHEN THE COMMON PREFIX IS IDENTICAL.
    # This is the leg that kills a "compare min(len_a, len_b)" mutant.
    _write(buf, 100, _fill(0x41, 40))
    _write(buf, 200, _fill(0x41, 40))
    for n_a in range(0, 40):
        for d in range(1, 5):
            var n_b = n_a + d
            if n_b > 40:
                continue
            var sa = Span(buf)[100 : 100 + n_a]
            var sb = Span(buf)[200 : 200 + n_b]
            assert_false(
                bytes_equal(sa, sb),
                "len " + String(n_a) + " vs " + String(n_b),
            )
            assert_false(
                bytes_equal_scalar(sa, sb),
                "len " + String(n_a) + " vs " + String(n_b) + " (scalar)",
            )

    # Empty vs non-empty, both directions.
    assert_false(bytes_equal(Span(buf)[0:0], Span(buf)[100:101]), "0 vs 1")
    assert_false(bytes_equal(Span(buf)[100:101], Span(buf)[0:0]), "1 vs 0")


# -----------------------------------------------------------------------------
# T2 — exact boundary lengths, both equal and unequal.
#
# 16 / 32 / 64 are the bulk-loop and rung widths; +-1 around each is where an
# off-by-one in a guard lives. 0 and 1 are the degenerate arms.
# -----------------------------------------------------------------------------

def test_exact_boundary_lengths() raises:
    var buf = _backing()
    var lens = List[Int]()
    for v in [0, 1, 2, 3, 4, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 96,
              127, 128, 129]:
        lens.append(v)

    for li in range(len(lens)):
        var n = lens[li]
        # Deliberately unaligned, and DIFFERENTLY unaligned on the two sides,
        # so an "assumes both sides share a residue" mutant cannot pass.
        var a_off = 1 + (n % 31)
        var b_off = 2048 + 7 + (n % 17)
        var v = _fill(0x00, n)
        for k in range(n):
            v[k] = UInt8((k * 91 + 5) % 256)
        _write(buf, a_off, v)
        _write(buf, b_off, v)
        _check(buf, a_off, b_off, n, True, "equal n=" + String(n))
        if n == 0:
            continue
        # Perturb the FIRST byte, then the LAST byte, then a middle byte.
        var probes = List[Int]()
        probes.append(0)
        probes.append(n - 1)
        probes.append(n // 2)
        for pi in range(len(probes)):
            var p = probes[pi]
            buf[b_off + p] = buf[b_off + p] ^ UInt8(0xFF)
            _check(
                buf, a_off, b_off, n, False,
                "n=" + String(n) + " differ at " + String(p),
            )
            buf[b_off + p] = buf[b_off + p] ^ UInt8(0xFF)


# -----------------------------------------------------------------------------
# T3 — embedded NUL and high bytes.
#
# An embedded 0x00 kills a `strcmp`/`strncmp` substitution (which would stop
# at the NUL and call two differing spans equal). High bytes kill a
# signed-char comparison and any "test the sign of a three-way result" mutant.
# -----------------------------------------------------------------------------

def test_embedded_nul_and_high_bytes() raises:
    var buf = _backing()
    var n = 48
    var a_off = 3
    var b_off = 1024 + 5

    var v = _fill(0x00, n)
    for k in range(n):
        v[k] = UInt8(0x80 + (k % 0x7F))
    v[0] = 0x00
    v[5] = 0x00
    v[n - 1] = 0xFF
    v[n // 2] = 0x00
    _write(buf, a_off, v)
    _write(buf, b_off, v)
    _check(buf, a_off, b_off, n, True, "nul+high equal")

    # Differ ONLY after the first embedded NUL. `strcmp` would say equal.
    buf[b_off + 20] = 0x7F
    _check(buf, a_off, b_off, n, False, "differ after embedded NUL")
    buf[b_off + 20] = v[20]

    # 0x00 vs 0x80 at one position: the pair a signed comparison confuses.
    buf[b_off + 5] = 0x80
    _check(buf, a_off, b_off, n, False, "0x00 vs 0x80")
    buf[b_off + 5] = 0x00

    # 0x7F vs 0x80 — adjacent unsigned, opposite sign as signed chars.
    buf[a_off + 9] = 0x7F
    buf[b_off + 9] = 0x80
    _check(buf, a_off, b_off, n, False, "0x7F vs 0x80")


# -----------------------------------------------------------------------------
# T4 — ⭐ THE HOLE DETECTOR.
#
# For EVERY length 0..80 and EVERY position p in [0, n), a pair differing at
# exactly p must compare UNEQUAL. This is the only leg that can see a mid-span
# hole, and a mutant that skips a mid-span block is GREEN under every other
# leg in this file and RED here.
#
# ⚠ The per-length guard offset is not decoration. It walks each case's start
# offset across residues mod 32, so the bulk loop's entry alignment varies.
# Without it, a given length's slot would sit at a fixed residue and whole
# classes of tail geometry would never be exercised. The residue coverage is
# ASSERTED at the end of the leg, because a guard formula that silently misses
# residues turns this into a weaker test than it claims to be — the first
# formula tried here, `1 + (n % 31)`, covered 31 of 32 and that assertion is
# what found it.
# -----------------------------------------------------------------------------

def test_every_byte_position_is_compared() raises:
    var buf = _backing()
    var residues_seen = List[Int]()
    for _ in range(32):
        residues_seen.append(0)

    var cases = 0
    for n in range(0, 81):
        # `n % 32`, not `1 + (n % 31)`: the latter covers residues 1..31 and
        # NEVER residue 0, which the non-vacuity assertion below caught.
        var guard = n % 32
        var a_off = guard
        var b_off = 4096 + guard
        residues_seen[a_off % 32] = 1

        var v = _fill(0x61, n)
        for k in range(n):
            v[k] = UInt8((k * 53 + 17) % 256)
        _write(buf, a_off, v)
        _write(buf, b_off, v)
        _check(buf, a_off, b_off, n, True, "sweep equal n=" + String(n))
        cases += 1

        for p in range(n):
            buf[b_off + p] = buf[b_off + p] ^ UInt8(0x5A)
            _check(
                buf, a_off, b_off, n, False,
                "sweep n=" + String(n) + " p=" + String(p),
            )
            buf[b_off + p] = buf[b_off + p] ^ UInt8(0x5A)
            cases += 1

    # NON-VACUITY: 0..80 with a 1 + (n % 31) guard must actually cover every
    # residue mod 32, or this leg is not the unaligned test it claims to be.
    var covered = 0
    for r in range(32):
        covered += residues_seen[r]
    assert_equal(covered, 32, "start residues mod 32 covered")
    assert_equal(cases, 3321, "byte-position sweep case count")


# -----------------------------------------------------------------------------
# T5 — every start residue mod 32 on BOTH sides independently, at the lengths
# where the tail ladder does the most work.
#
# T4 varies the residue with the length; this leg holds the length fixed and
# varies the residue, so a defect that needs (residue r, length n) jointly is
# reachable from two directions.
# -----------------------------------------------------------------------------

def test_all_start_residues() raises:
    var buf = _backing()
    var lens = List[Int]()
    for v in [17, 25, 31, 33, 47, 56, 63]:
        lens.append(v)

    for li in range(len(lens)):
        var n = lens[li]
        for ra in range(32):
            for rb in range(0, 32, 7):
                var a_off = 64 + ra
                var b_off = 2048 + rb
                var v = _fill(0, n)
                for k in range(n):
                    v[k] = UInt8((k * 29 + ra + rb) % 256)
                _write(buf, a_off, v)
                _write(buf, b_off, v)
                _check(
                    buf, a_off, b_off, n, True,
                    "residue equal n=" + String(n) + " ra=" + String(ra),
                )
                # Differ at the position most likely to fall in a tail hole:
                # just past the last full bulk block.
                var w = simd_width_of[DType.uint8]()
                var p = (n // w) * w
                if p >= n:
                    p = n - 1
                buf[b_off + p] = buf[b_off + p] ^ UInt8(0x33)
                _check(
                    buf, a_off, b_off, n, False,
                    "residue differ n=" + String(n) + " ra=" + String(ra)
                    + " p=" + String(p),
                )


# -----------------------------------------------------------------------------
# T6 — a long-shared-prefix join-key shape.
#
# `48 + (d % 17)` bytes with a long shared prefix, differing ONLY in the LAST
# byte. On such keys a 4-byte prefix separates EXACTLY 0.0% of keys,
# so a prefix-only compare is a wrong-answer mutant that a random corpus would
# never catch.
# -----------------------------------------------------------------------------

def test_c5_shaped_keys_common_prefix() raises:
    var buf = _backing()
    for d in range(17):
        var n = 48 + d
        var a_off = 11 + d
        var b_off = 3000 + (d * 3)
        var v = _fill(0x78, n)
        var pre = String("sa_key_common_prefix_")
        var pb = pre.as_bytes()
        for k in range(len(pb)):
            if k < n:
                v[k] = pb[k]
        v[n - 1] = UInt8(0x41)
        _write(buf, a_off, v)
        _write(buf, b_off, v)
        _check(buf, a_off, b_off, n, True, "c5 equal n=" + String(n))
        buf[b_off + n - 1] = UInt8(0x42)
        _check(buf, a_off, b_off, n, False, "c5 last-byte differ n=" + String(n))


# -----------------------------------------------------------------------------
# T7 — randomized fuzz against the scalar reference AND against construction.
# -----------------------------------------------------------------------------

def test_randomized_fuzz() raises:
    seed(20260908)
    var buf = _backing()
    for _it in range(4000):
        var n = Int(random_si64(0, 200))
        var a_off = Int(random_si64(0, 900))
        var b_off = 3500 + Int(random_si64(0, 900))
        var v = _fill(0, n)
        for k in range(n):
            v[k] = UInt8(Int(random_si64(0, 255)))
        _write(buf, a_off, v)
        _write(buf, b_off, v)
        var flip = Int(random_si64(0, 1))
        var want = True
        if flip == 1 and n > 0:
            var p = Int(random_si64(0, Int64(n - 1)))
            buf[b_off + p] = buf[b_off + p] ^ UInt8(0x01)
            want = False
        _check(
            buf, a_off, b_off, n, want,
            "fuzz n=" + String(n) + " it=" + String(_it),
        )


def main() raises:
    test_empty_and_length_mismatch()
    test_exact_boundary_lengths()
    test_embedded_nul_and_high_bytes()
    test_every_byte_position_is_compared()
    test_all_start_residues()
    test_c5_shaped_keys_common_prefix()
    test_randomized_fuzz()
    print("test_byte_equal_simd: ALL PASS")
