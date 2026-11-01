# =============================================================================
# byte_equal.mojo — SIMD byte-sequence EQUALITY (the `memcmp(a,b,n) == 0` shape).
# =============================================================================
#
# The byte-class package's equality primitive. `comparisons.byte_eq` answers
# "which LANES of these two vectors are equal"; this module answers "are these
# two byte SPANS equal", which is a different kernel: a bulk loop plus a tail
# that must not read outside either span.
#
# ⭐ WHY IT IS A KERNEL AND NOT A LIBC CALL — THE REASON IS THE TOOLCHAIN, NOT
# THE ALGORITHM. LLVM rewrites `memcmp(..) == 0` into `bcmp`. When the
# executable links compiler_rt's `bcmp` (a hermetic Zig/clang toolchain
# weak-DEFINES it in the executable, with no PLT entry and no relocation),
# that `bcmp` is a byte-at-a-time loop of about six instructions per byte —
# NOT glibc's vectorized `__memcmp_avx2_movbe` — and no `LD_PRELOAD` can
# change it. On string-key join probes that loop can dominate the whole
# run's instruction count; replacing it with this kernel removes it from
# the profile.
#
# # THE SHAPE
#
# A `W`-byte bulk loop, then ONE overlapping tail block anchored at the END of
# the span. **Overlap, not masking, is what removes the tail off-by-one**: the
# second block of each ladder rung starts at `n - w`, so the two blocks' union
# is exactly `[i, n)` whenever `rem <= 2*w`, which every rung's guard
# establishes. Nothing is read outside `[0, n)`.
#
#   | rem     | blocks compared               | covers `[i, n)` because |
#   |---------|-------------------------------|-------------------------|
#   | 0       | none                          | empty                   |
#   | w..2w-1 | `[i, i+w)` and `[n-w, n)`     | rem < 2w                |
#   | 1       | one byte at `i`               | trivially               |
#
# `rem < W` on entry to the ladder, and each rung halves `w`, so the guard
# `rem >= w` is always reached with `rem < 2w`. For a 56-byte key with W=32
# that is ONE 32-byte compare plus TWO 16-byte compares — three vector
# compares against the byte loop's 56 iterations.
#
# # WIDTH
#
# `comptime W = simd_width_of[DType.uint8]()` — NEON 16 / AVX2 32 / AVX-512 BW
# 64. Never hardcoded above native.
#
# # ARCHITECTURE — ⭐ ONE SPELLING, OPTIMAL ON BOTH, BY DISASSEMBLY
#
# The reduction ("does ANY lane of these two vectors differ") is the only
# arch-sensitive step, so it is the only place a `comptime if
# CompilationTarget.is_x86()` could live. **There is deliberately no
# dispatch — the obvious NEON fallback is a 15-instruction PESSIMISATION on
# x86 and buys nothing on ARM.** Both sequences below are emitted from the
# same source with `mojo build --emit asm`, one native and one cross
# (`--target-triple x86_64-unknown-linux-gnu --target-cpu raptorlake`: AVX2,
# no AVX-512, so `simd_width_of[uint8]() == 32`).
#
#   spelling                         x86-64 / AVX2 (W=32)      ARM64 NEON (W=16)
#   -------------------------------  ------------------------  -----------------
#   `any_true(a.ne(b))`   <- USED     vmovdqu / vpxor <mem> /   ldr q x2 / cmeq.16b
#                                     vptest / jcc              / mvn.16b / addp.2d
#                                     = 4 instrs per 32 B       / fmov / cbz
#                                                               = 7 instrs per 16 B
#   `reduce_max(a ^ b) != 0`          vpxor + a `vpmaxub`       ⭐ BYTE-IDENTICAL
#     (the "portable NEON" form)      shuffle tree: vpshufd /   to the row above.
#                                     vpmaxub x5 / vpsrld /     LLVM canonicalises
#                                     vpsrlw / vpshufb /        both to the same
#                                     vmovd / vpextrb / orb     7 instructions.
#                                     = 15 instrs per 16 B
#
# `horizontal_reduce.mojo` has `reduce_max` (the `vmaxvq_u8` half) and it is
# NOT used here, because `any_true` — the x86-optimal spelling — already
# reaches the canonical AArch64 `addp.2d` any-nonzero form. A dispatch here
# would add a second arm that is dead on one target and harmful on the other.
#
# # ⚠ `alignment=1` IS STATED ON EVERY LOAD AND IS LOAD-BEARING
#
# Arrow string data buffers are packed, so a slot begins at an arbitrary
# offset; a naturally-aligned W-byte load would fault.
#
# # ⛔ WHAT THIS MODULE DOES NOT FIX
#
# A shared kernel fixes the sites that call it EXPLICITLY. It does NOTHING for
# the compiler_rt `memcmp`/`memset`/`memcpy`/`memmove`/`bcmp` calls LLVM emits
# IMPLICITLY (struct initialisers, inlined copies); those only get a fast body
# from a strong libc symbol linked into the binary. The two fixes are
# COMPLEMENTARY, not alternatives.
#
# # ENCAPSULATION
#
# Public API takes `Span[UInt8, origin]` — **no raw `UnsafePointer` crosses a
# module boundary**. `Span.unsafe_ptr()` is extracted locally, confined to the
# kernel below under a `# SAFETY:` comment, and never escapes. No wildcard
# origins.
# =============================================================================

from std.sys.info import simd_width_of

from komira_simd.byte_class.horizontal_reduce import any_true


# =============================================================================
# Scalar reference — the correctness oracle.
# =============================================================================
#
# Mirrors `byte_memmem.find_needle_scalar`: an implementation-independent
# oracle the vector path is validated against, and the shape a reader can
# check the ladder's coverage argument by hand.

@always_inline
def bytes_equal_scalar[
    a_origin: Origin[mut=False],
    b_origin: Origin[mut=False],
](a: Span[UInt8, a_origin], b: Span[UInt8, b_origin]) -> Bool:
    """True iff `a` and `b` hold the same bytes. Byte-at-a-time reference.

    Contract (identical to `bytes_equal`):
      - different lengths -> False.
      - both empty -> True.

    This is the ORACLE, not a second production surface. It exists for the
    same reason `find_needle_scalar` does: a vector kernel whose only check is
    "agrees with itself" is blind to any defect it has always had.
    """
    var n = len(a)
    if n != len(b):
        return False
    for i in range(n):
        if a[i] != b[i]:
            return False
    return True


# =============================================================================
# The arch-dispatched reduction — "does any lane differ".
# =============================================================================

@always_inline
def _any_lane_differs[
    W: Int
](a: SIMD[DType.uint8, W], b: SIMD[DType.uint8, W]) -> Bool:
    """True iff at least one of the W byte lanes of `a` and `b` differs.

    ⭐ ONE SPELLING, DELIBERATELY. This is the only architecture-sensitive
    step in the kernel, so it is the only place a `comptime if
    CompilationTarget.is_x86()` could go. It is not there because the
    disassembly says it must not be — see the module header's
    "ARCHITECTURE" section for the two emitted sequences.

    x86-64 (raptorlake, AVX2, W=32): `vmovdqu` / `vpxor <mem>` (the b-side
    folds into the memory operand) / `vptest` / `jcc` — FOUR instructions per
    32 bytes, against compiler_rt `bcmp`'s ~192.

    ARM64 NEON (W=16): `ldr q` x2 / `cmeq.16b` / `mvn.16b` / `addp.2d` /
    `fmov` / `cbz` — the canonical AArch64 "any lane differs" sequence, seven
    instructions per 16 bytes against compiler_rt's 96. `vptest` has no NEON
    equivalent and none is needed: LLVM reaches the `addp.2d` any-nonzero form
    from this spelling directly.
    """
    return any_true(a.ne(b))


# =============================================================================
# The production kernel.
# =============================================================================

@always_inline
def bytes_equal[
    a_origin: Origin[mut=False],
    b_origin: Origin[mut=False],
](a: Span[UInt8, a_origin], b: Span[UInt8, b_origin]) -> Bool:
    """True iff `a` and `b` hold the same bytes. Vector-width at a time.

    Value-identical to `bytes_equal_scalar` for every input; that equivalence
    is the subject of the package's `test_byte_equal_simd` test.

    Contract:
      - different lengths -> False (the O(1) short-circuit; callers that
        already know the lengths are equal pay one predictable branch).
      - both empty -> True.

    SAFETY: reads only `[a.unsafe_ptr(), +n)` and `[b.unsafe_ptr(), +n)` where
    `n == len(a) == len(b)`, established by the length check above the first
    load. Every ladder rung reads `[i, i+w)` under the guard `w <= rem`
    (so `i + w <= n`) and `[n-w, n)` with `w <= rem <= n` (so `n - w >= 0`).
    Neither pointer escapes this function.
    """
    var n = len(a)
    if n != len(b):
        return False
    if n <= 0:
        return True

    comptime W = simd_width_of[DType.uint8]()

    # SAFETY: both pointers are bounded by their own Span's length, which the
    # check above proved equal to `n`. See the per-rung argument in the
    # docstring; nothing below reads outside `[0, n)` on either side.
    var ap = a.unsafe_ptr()
    var bp = b.unsafe_ptr()

    var i = 0
    while i + W <= n:
        var av = (ap + i).load[width=W, alignment=1]()
        var bv = (bp + i).load[width=W, alignment=1]()
        if _any_lane_differs[W](av, bv):
            return False
        i += W

    var rem = n - i
    if rem == 0:
        return True

    # The overlapping tail ladder. Each rung's guard `rem >= w` is reached only
    # with `rem < 2*w` (from the bulk loop for the first rung, from the
    # previous rung's failed guard thereafter), so `[i, i+w) U [n-w, n)` is
    # exactly `[i, n)`.
    comptime if W >= 64:
        if rem >= 32:
            var a0 = (ap + i).load[width=32, alignment=1]()
            var b0 = (bp + i).load[width=32, alignment=1]()
            if _any_lane_differs[32](a0, b0):
                return False
            var a1 = (ap + n - 32).load[width=32, alignment=1]()
            var b1 = (bp + n - 32).load[width=32, alignment=1]()
            return not _any_lane_differs[32](a1, b1)
    comptime if W >= 32:
        if rem >= 16:
            var a0 = (ap + i).load[width=16, alignment=1]()
            var b0 = (bp + i).load[width=16, alignment=1]()
            if _any_lane_differs[16](a0, b0):
                return False
            var a1 = (ap + n - 16).load[width=16, alignment=1]()
            var b1 = (bp + n - 16).load[width=16, alignment=1]()
            return not _any_lane_differs[16](a1, b1)
    comptime if W >= 16:
        if rem >= 8:
            var a0 = (ap + i).load[width=8, alignment=1]()
            var b0 = (bp + i).load[width=8, alignment=1]()
            if _any_lane_differs[8](a0, b0):
                return False
            var a1 = (ap + n - 8).load[width=8, alignment=1]()
            var b1 = (bp + n - 8).load[width=8, alignment=1]()
            return not _any_lane_differs[8](a1, b1)
    if rem >= 4:
        var a0 = (ap + i).load[width=4, alignment=1]()
        var b0 = (bp + i).load[width=4, alignment=1]()
        if _any_lane_differs[4](a0, b0):
            return False
        var a1 = (ap + n - 4).load[width=4, alignment=1]()
        var b1 = (bp + n - 4).load[width=4, alignment=1]()
        return not _any_lane_differs[4](a1, b1)
    if rem >= 2:
        var a0 = (ap + i).load[width=2, alignment=1]()
        var b0 = (bp + i).load[width=2, alignment=1]()
        if _any_lane_differs[2](a0, b0):
            return False
        var a1 = (ap + n - 2).load[width=2, alignment=1]()
        var b1 = (bp + n - 2).load[width=2, alignment=1]()
        return not _any_lane_differs[2](a1, b1)
    return (ap + i)[] == (bp + i)[]
