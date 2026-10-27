# =============================================================================
# fast_copy.mojo — tuned byte-copy primitive (AVX2 / ERMS / non-temporal).
# =============================================================================
#
# Replacement for Mojo stdlib `memcpy` on the bulk-copy hot paths.
#
# # Why this module exists
#
# Stdlib `memcpy` on a runtime length is INLINE-EXPANDED on x86-64 into a
# single 32-byte vector loop:
#
#     vmovups ymm0,YMMWORD PTR [r10+rbx*1]     # load  32 B
#     vmovups YMMWORD PTR [r8+rbx*1],ymm0      # store 32 B
#     add     rbx,0x20
#     cmp     rbx,r11
#     jb      <loop>                           # <- 5 instrs / 32 B
#
# followed by a BYTE-AT-A-TIME scalar remainder loop:
#
#     movzx   ebx,BYTE PTR [r10+r11*1]
#     mov     BYTE PTR [r8+r11*1],bl
#     inc     r11
#     cmp     r9,r11
#     jne     <tail>                           # <- up to 31 iters
#
# So the lowering has: ZERO unroll, NO `rep movsb` (ERMS), NO non-temporal
# stores, and a scalar 1-byte/iteration tail of up to 31 iterations. A 33-byte
# copy costs 1 vector iteration + 1 scalar; a 63-byte copy costs 1 vector
# iteration + 31 scalar iterations. On copy-heavy scan and filter workloads
# that naive lowering is a large share of CPU time.
#
# # What this module provides
#
# Four copy strategies, each independently selectable at comptime so a
# size-ladder microbenchmark can measure them head-to-head rather than
# guessing which one wins where:
#
#   VARIANT_UNROLLED  — branchy small path, overlapping mid path, 128 B/iter
#                       4x-unrolled AVX2 main loop with 32 B-ALIGNED stores,
#                       and an OVERLAPPING VECTOR tail (kills the 31-iteration
#                       scalar remainder loop above).
#   VARIANT_NT        — as UNROLLED, but the main loop uses non-temporal
#                       (`vmovntdq`) stores to skip the read-for-ownership.
#                       Terminated by an `sfence`.
#   VARIANT_LIBC      — delegate to the linked `memmove`.
#   VARIANT_AUTO      — size-dispatched composition of the above.
#
# # NT-store caveat (READ THIS BEFORE OPTING IN)
#
# Non-temporal stores BYPASS the cache. They are a WIN when nothing reads the
# destination soon and a LOSS when the very next operator folds over it hot —
# the consumer then takes a full DRAM miss that a normal store would have
# served from L2. NT is therefore NEVER selected by `VARIANT_AUTO` on its own:
# a caller must opt in with `nt_ok=True`, asserting "nobody reads this soon".
# `vmovntdq` also REQUIRES a 32 B-aligned destination, which is why the large
# path aligns the destination before entering the main loop rather than
# assuming our AB[64] buffers arrive aligned.
#
# # Overlap semantics
#
# `fast_copy_bytes` has MEMCPY semantics: source and destination MUST NOT
# overlap, exactly like the stdlib `memcpy` it replaces. Use
# `fast_move_bytes` (`memmove`) when overlap is possible.
#
# # Encapsulation
#
# Public API takes `Span[UInt8, origin]` — no `UnsafePointer` crosses a module
# boundary. `Span.unsafe_ptr()` is extracted locally and confined to this
# module's internal helpers.
# =============================================================================

from std.atomic import fence, Ordering
from std.ffi import external_call
from std.memory import UnsafePointer
from std.sys.info import CompilationTarget
from std.sys._assembly import inlined_assembly
from std.sys.intrinsics import llvm_intrinsic


# =============================================================================
# `fast_copy_bytes` IS THE UNCONDITIONAL BULK-COPY KERNEL.
#
# The buffer-copy entry points (`OwnedAlignedBuffer` / `SharedAlignedBuffer`
# `copy_from_view` / `copy_from_view_at`, `ByteView.copy_from_view_at`), the
# variable-width gather, and the parquet PLAIN decoder call it directly.
#
# ⛔ DO NOT PUT A FLAG IN FRONT OF IT. Both spellings are broken here:
#
#   * `-D` / `is_defined[...]` CANNOT WORK. The call sites live in
#     the core packages, which ships as a prebuilt `.mojoc`, and a define passed
#     when building a consumer does not reach code inside an already-compiled
#     package. `is_defined[...]()` inside library code would be
#     UNCONDITIONALLY False — a dead flag that only looks like a flag.
#
#   * A runtime environment read is too expensive at these call sites. A
#     per-use `getenv` + strcmp + `__tls_get_addr` read per column per morsel
#     is a measurable share of a query's self-time, and
#     `ByteView.copy_from_view_at` is the snappy/zlib/zstd literal-emit path —
#     an environment read there would cost more than the copy it guards.
#
# To compare against stdlib `memcpy`, build a variant with stdlib `memcpy` at
# the call sites and check the two binaries actually differ before trusting
# any number.
# =============================================================================


# =============================================================================
# Variant tags (comptime selectors — used by the size-ladder microbenchmark).
# =============================================================================

comptime VARIANT_AUTO: Int = 0
comptime VARIANT_UNROLLED: Int = 1
comptime VARIANT_NT: Int = 2
comptime VARIANT_LIBC: Int = 3


# =============================================================================
# Tuning thresholds.
#
# These are the DEFAULTS the size-ladder microbenchmark measures against; the
# bench forces each variant explicitly so the crossover points are observed
# rather than assumed.
# =============================================================================

# Sizes strictly below this use the branchy no-loop small path.
# A library `memmove` call is several times SLOWER than the inline path here —
# pure call overhead against a copy that is a couple of instructions. Never
# delegate small sizes.
comptime SMALL_MAX: Int = 32
# Sizes up to this use straight-line overlapping vector blocks (no loop);
# at 128 B this is about twice the throughput of stdlib `memcpy` or a
# library `memmove`.
comptime MID_MAX: Int = 128
# ⚠ WHICH `memmove` `_copy_libc` REACHES DEPENDS ON THE LINK. A binary built
# with a hermetic Zig/clang toolchain gets compiler_rt's `memmove` as a WEAK
# symbol DEFINED IN THE EXECUTABLE (`nm -D` -> `W memmove`, no PLT), and that
# body has ZERO 256-bit instructions and ZERO `rep movs` — its forward bulk
# loop is two `movups` pairs, 32 bytes per iteration. A binary that leaves the
# symbol undefined binds glibc's `__memmove_avx_unaligned_erms` through the
# PLT instead. Any measurement of `_copy_libc` has to say which binary it was
# taken in.
#
# At or above this, `VARIANT_AUTO` delegates to that `memmove`. It is now the
# LAST resort, reached only above `ERMS_MAX` — see `ERMS_MIN` below.
comptime LIBC_MIN: Int = 262144
# =============================================================================
# The ERMS band — `rep movsb`, and it is the only thing that beat a plain loop.
# =============================================================================
#
# Measured with a size-ladder microbenchmark on a Broadwell-EP Xeon (`avx2` +
# `erms`, no `fsrm`), aligned/unaligned x cold/hot destination tables.
#
# ⛔ THE FINDING THAT SETS THESE CONSTANTS IS A NEGATIVE ONE: **above ~128 KiB
# the loop body does not matter at all.** Three different loops — 32 B/iter with
# 2 memory ops, 32 B/iter with 2, and this module's 128 B/iter `_copy_large_
# unrolled` with 8 — land on the SAME throughput at every size >= 128 KiB
# (13.59 / 13.61 / 13.59 GB/s at 256 KiB; 5.25 / 5.24 / 5.26 at 64 MiB). The
# regime is bandwidth-limited: 13 GB/s on a 2.2 GHz core is 5.9 B/cycle, so
# compiler_rt's 6 instructions per 32 bytes is 1.1 IPC, nowhere near an issue
# limit. **Widening or unrolling the loop buys NOTHING here; routing this band
# to `_copy_large_unrolled` does not help.**
#
# What wins is a different INSTRUCTION, not a wider one. `rep movsb` under ERMS,
# against `_copy_large_unrolled` (aligned/cold | aligned/hot | unaligned/cold):
#
#   128 KiB  +21.4% | +10.0% | +14.5%
#   256 KiB  +22.7% |  +8.0% | +20.0%
#   512 KiB  +17.3% | +10.6% | +14.3%
#     1 MiB  +15.8% | +11.2% | +13.5%
#     4 MiB  +15.8% | +11.3% | +13.1%
#    16 MiB  +16.0% | +11.3% | +12.8%
#    64 MiB  -12.0% |  -9.7% |  -9.5%    <- the upper edge
#
# It wins in every table from 128 KiB through 16 MiB and never changes sign
# inside the band, which is what makes it a safe default where the NT arm is
# not.
#
# ⭐ THE CONTROL: glibc's `__memmove_avx_unaligned_erms`
# and raw `rep movsb` are NUMERICALLY IDENTICAL from 256 KiB to 4 MiB
# (16.51/16.67, 15.31/15.31, 15.11/15.11, 15.06/15.06 GB/s). They are the same
# instruction — glibc IS issuing `rep movsb` in that band — so the two arms are
# each other's control and they agree.
#
# ⚠ `ERMS_MIN` is 128 KiB and NOT lower: the measured crossover is between
# 64 KiB (all six arms tie at 23.8-24.2, i.e. `rep movsb`'s startup cost is
# already amortised but buys nothing) and 128 KiB. ERMS has a fixed startup
# overhead on Broadwell, so do NOT lower this without re-running the ladder at
# the sizes below 64 KiB, where a library `memmove` loses to the unrolled loop
# (e.g. at 16 KiB with a hot destination).
#
# ⚠ `ERMS_MAX` is INCLUSIVE and is the largest size MEASURED to win. 64 MiB was
# measured to LOSE; 32 MiB was never measured. The bound is deliberately placed
# on a measured point rather than interpolated between a win and a loss.
comptime ERMS_MIN: Int = 131072
comptime ERMS_MAX: Int = 16777216

# ⚠ THE LADDER MEASURED ONE COPY AT A TIME. The engine's dominant in-band
# caller — the finalize concat (`streaming_concat`'s
# `_concat_fixed_column_into_range`) — is a fork-join wave where many workers
# run this instruction at once, and that concurrent regime is not covered by
# the table above. The trade-offs for it (`~{memory}` vs the no-RFO store
# path) are recorded at that call site.


# =============================================================================
# `fast_copy_route` — THE LADDER, AS A VALUE. One ladder, not two.
# =============================================================================
#
# ⛔ THIS IS NOT A MIRROR OF THE DISPATCH. `fast_copy_bytes` CALLS IT. That is
# deliberate and it is the whole point: a routing table written down twice
# drifts, and a test asserting on the copy reads as a live invariant while
# testing nothing.
#
# Asserting on CONSTANTS cannot catch the defect this exists to catch: a
# correct number pointing at an arm whose PREMISE has expired under it (for
# example a threshold calibrated against a `memmove` the link no longer
# provides). What a test has to pin is WHICH ARM a copy of a given size takes.
comptime ROUTE_NONE: Int = 0
comptime ROUTE_SMALL: Int = 1
comptime ROUTE_MID: Int = 2
comptime ROUTE_UNROLLED: Int = 3
comptime ROUTE_ERMS: Int = 4
comptime ROUTE_LIBC: Int = 5
comptime ROUTE_NT: Int = 6


@always_inline
def fast_copy_route[nt_ok: Bool = False](n: Int) -> Int:
    """Which arm `VARIANT_AUTO` selects for a non-overlapping copy of `n` bytes.

    `@always_inline` and branch-free of anything but `n`, so at a call site with
    a comptime-known size the whole chain folds away; `fast_copy_bytes` pays
    nothing for routing through it.

    On a non-x86 target `fast_copy_bytes` returns through `memmove` before it
    reaches the ladder, so this function describes the x86 dispatch only.
    """
    if n <= 0:
        return ROUTE_NONE
    if n < SMALL_MAX:
        return ROUTE_SMALL
    if n <= MID_MAX:
        return ROUTE_MID
    comptime if nt_ok:
        if n >= NT_MIN:
            return ROUTE_NT
    if n >= ERMS_MIN and n <= ERMS_MAX:
        return ROUTE_ERMS
    if n >= LIBC_MIN:
        return ROUTE_LIBC
    return ROUTE_UNROLLED
# At or above this AND with `nt_ok=True`, use non-temporal stores.
#
# This is why NT is opt-in rather than automatic: it is a win only in a
# narrow window, and catastrophic outside it (GB/s):
#
#   size   NT (cold)   ours (cold)  |  NT (hot)   stdlib (hot)
#   256 B      1.42          78.61  |     2.02          58.62   <- 40x LOSS
#     1 K      8.18         253.19  |     5.64          53.07   <- 30x LOSS
#     4 M     40.84          28.85  |    14.56          18.20   <- 1.4x win cold,
#    16 M     40.15          26.49  |    13.99          12.85      LOSS hot
#    64 M     20.86          24.03  |    11.32           8.90   <- LOSS even cold
#
# So: NT helps only for multi-MiB copies whose destination nobody reads soon,
# and even then it is beaten again by ~64 MiB. 4 MiB is the floor (1.4x at
# 4 MiB, in both the aligned and unaligned cold tables).
comptime NT_MIN: Int = 4194304


# =============================================================================
# Internal — raw-pointer workers.
#
# SAFETY: every helper below receives pointers extracted from the caller's
# `Span` inside THIS module. `count` is bounded by the caller's span lengths
# (checked in `fast_copy_bytes`). No pointer escapes this module.
# =============================================================================


@always_inline
def _copy_small(
    d: UnsafePointer[UInt8, MutUntrackedOrigin],
    s: UnsafePointer[UInt8, ImmUntrackedOrigin],
    n: Int,
) -> None:
    """Branchy overlapping head/tail copy for `n` < 32. No loop, no scalar
    remainder.

    Every arm loads BOTH ends before storing either, so the arms are correct
    for any `n` in their range without a per-byte loop. Mirrors glibc's
    small-size ladder.
    """
    if n >= 16:
        # 16..31 — two overlapping 16 B vectors.
        var a = s.load[width=16, alignment=1](0)
        var b = s.load[width=16, alignment=1](n - 16)
        d.store[alignment=1](0, a)
        d.store[alignment=1](n - 16, b)
        return
    if n >= 8:
        # 8..15 — two overlapping u64.
        var a = s.bitcast[UInt64]().load[alignment=1](0)
        var b = (s + (n - 8)).bitcast[UInt64]().load[alignment=1](0)
        d.bitcast[UInt64]().store[alignment=1](0, a)
        (d + (n - 8)).bitcast[UInt64]().store[alignment=1](0, b)
        return
    if n >= 4:
        # 4..7 — two overlapping u32.
        var a = s.bitcast[UInt32]().load[alignment=1](0)
        var b = (s + (n - 4)).bitcast[UInt32]().load[alignment=1](0)
        d.bitcast[UInt32]().store[alignment=1](0, a)
        (d + (n - 4)).bitcast[UInt32]().store[alignment=1](0, b)
        return
    if n <= 0:
        return
    # 1..3 — three overlapping byte loads. For n==1 all three alias index 0.
    var b0 = s[0]
    var bm = s[n >> 1]
    var bl = s[n - 1]
    d[0] = b0
    d[n >> 1] = bm
    d[n - 1] = bl


@always_inline
def _copy_mid(
    d: UnsafePointer[UInt8, MutUntrackedOrigin],
    s: UnsafePointer[UInt8, ImmUntrackedOrigin],
    n: Int,
) -> None:
    """Straight-line overlapping 32 B vector blocks for 32 <= `n` <= 128.

    No loop and no scalar tail: at most four loads then four stores, with the
    trailing pair anchored at `n - 32` / `n - 64` so any remainder is absorbed
    by overlap.
    """
    if n <= 64:
        var a = s.load[width=32, alignment=1](0)
        var b = s.load[width=32, alignment=1](n - 32)
        d.store[alignment=1](0, a)
        d.store[alignment=1](n - 32, b)
        return
    var a = s.load[width=32, alignment=1](0)
    var b = s.load[width=32, alignment=1](32)
    var c = s.load[width=32, alignment=1](n - 64)
    var e = s.load[width=32, alignment=1](n - 32)
    d.store[alignment=1](0, a)
    d.store[alignment=1](32, b)
    d.store[alignment=1](n - 64, c)
    d.store[alignment=1](n - 32, e)


@always_inline
def _copy_large_unrolled[
    nt: Bool
](
    d: UnsafePointer[UInt8, MutUntrackedOrigin],
    s: UnsafePointer[UInt8, ImmUntrackedOrigin],
    n: Int,
) -> None:
    """4x-unrolled 32 B AVX2 main loop (128 B/iter) for `n` > 128.

    Destination is aligned to 32 B before the main loop so the stores are
    aligned (a hard REQUIREMENT for the `nt=True` `vmovntdq` form). The tail
    is an OVERLAPPING vector store rather than stdlib's up-to-31-iteration
    scalar byte loop.

    When `nt` is True the main-loop stores are non-temporal and an `sfence`
    is issued before return so any subsequent consumer read is ordered.
    """
    # --- Head: one unaligned 32 B store, then advance to the 32 B boundary.
    # `n` > 128 guarantees this 32 B store is fully in range.
    d.store[alignment=1](0, s.load[width=32, alignment=1](0))
    var head = (32 - (Int(d) & 31)) & 31
    var off = head
    var remaining = n - off

    # --- Main loop: 128 B/iter, destination-aligned stores.
    while remaining >= 128:
        var v0 = s.load[width=32, alignment=1](off)
        var v1 = s.load[width=32, alignment=1](off + 32)
        var v2 = s.load[width=32, alignment=1](off + 64)
        var v3 = s.load[width=32, alignment=1](off + 96)

        comptime if nt:
            d.store[alignment=32, non_temporal=True](off, v0)
            d.store[alignment=32, non_temporal=True](off + 32, v1)
            d.store[alignment=32, non_temporal=True](off + 64, v2)
            d.store[alignment=32, non_temporal=True](off + 96, v3)
        else:
            d.store[alignment=32](off, v0)
            d.store[alignment=32](off + 32, v1)
            d.store[alignment=32](off + 64, v2)
            d.store[alignment=32](off + 96, v3)

        off += 128
        remaining -= 128

    # --- Drain whole 32 B blocks (always cached stores; the residue is small
    # and a consumer that reads it is served from L1 rather than DRAM).
    while remaining >= 32:
        d.store[alignment=32](off, s.load[width=32, alignment=1](off))
        off += 32
        remaining -= 32

    # --- Tail: ONE overlapping unaligned 32 B store anchored at the end.
    # Replaces stdlib's scalar byte loop. Rewrites at most 31 already-correct
    # bytes with identical values. `n` > 128 => `n - 32` >= 96 >= head, so the
    # store never precedes the region this call owns.
    if remaining > 0:
        d.store[alignment=1](n - 32, s.load[width=32, alignment=1](n - 32))

    comptime if nt:
        # Non-temporal stores are weakly ordered; fence before any consumer
        # read observes the destination.
        #
        # NOTE the intrinsic name: SFENCE is an **SSE1** instruction, so the
        # intrinsic is `llvm.x86.sse.sfence`. `llvm.x86.sse2.sfence` does not
        # exist (LFENCE/MFENCE are the SSE2 pair) and fails only at LLVM
        # lowering — "could not find LLVM intrinsic" — long after type
        # checking passes. A front-end-only compile check will NOT catch it.
        llvm_intrinsic["llvm.x86.sse.sfence", NoneType]()


@always_inline
def _copy_libc(
    d: UnsafePointer[UInt8, MutUntrackedOrigin],
    s: UnsafePointer[UInt8, ImmUntrackedOrigin],
    n: Int,
) -> None:
    """Delegate to the linked `memmove` (see `LIBC_MIN` for which one a
    given binary reaches).

    FFI-BOUNDARY: the untracked origins are confined to this FFI call.
    Neither pointer escapes it.
    """
    _ = external_call["memmove", UnsafePointer[UInt8, MutUntrackedOrigin]](
        d, s, n
    )


@always_inline
def _copy_erms(
    d: UnsafePointer[UInt8, MutUntrackedOrigin],
    s: UnsafePointer[UInt8, ImmUntrackedOrigin],
    n: Int,
) -> None:
    """Copy `n` bytes with `rep movsb` (Enhanced REP MOVSB). NON-OVERLAPPING.

    The measured winner for `ERMS_MIN <= n <= ERMS_MAX`; see those constants for
    the table. On a CPU WITHOUT ERMS this is still CORRECT, just slow, which is
    why the band is entered only from the x86 arm of `VARIANT_AUTO`.

    # SAFETY — inline assembly. Every claim below is load-bearing.
    #
    #  * `rep movsb` reads `%rcx` bytes from `%rsi` to `%rdi` and ADVANCES all
    #    three registers. They are therefore CLOBBERED, not merely read.
    #    Declaring them as inputs would tell LLVM they survive the statement,
    #    which is a miscompile waiting to happen — so the three values are taken
    #    in ANY register ("r") and the template moves them into place, with
    #    `%rdi`/`%rsi`/`%rcx` in the CLOBBER list.
    #  * `~{memory}` is mandatory: the instruction writes memory LLVM cannot see
    #    through any operand, so without it a later load could be hoisted above
    #    the copy.
    #  * `~{dirflag}`: the x86-64 ABI guarantees DF is CLEAR at every
    #    instruction boundary, so `rep movsb` copies FORWARD. That is why this
    #    is `memcpy` semantics and NOT `memmove` semantics, and why
    #    `fast_move_bytes` — which promises overlap safety — must keep using
    #    `_copy_libc` and must never be routed here.
    #  * AT&T operand order (`movq src, dst`) is LLVM's default dialect. The
    #    emitted code was VERIFIED, not assumed: `mov %r12,%rdi / mov %r15,%rsi
    #    / mov %rbx,%rcx / rep movsb %ds:(%rsi),%es:(%rdi)`.
    #  * Neither pointer escapes this call; both are module-internal (same
    #    FFI-boundary rule as `_copy_libc` above).
    """
    comptime if CompilationTarget.is_x86():
        inlined_assembly[
            "movq $0, %rdi\nmovq $1, %rsi\nmovq $2, %rcx\nrep movsb",
            NoneType,
            constraints=(
                "r,r,r,~{rdi},~{rsi},~{rcx},~{memory},~{dirflag},~{fpsr},"
                "~{flags}"
            ),
            has_side_effect=True,
        ](d, s, n)
    else:
        # Unreachable from `VARIANT_AUTO` (the non-x86 arm returns earlier);
        # present so this function type-checks on every target.
        _copy_libc(d, s, n)


# =============================================================================
# Public API.
# =============================================================================


# =============================================================================
# nt_release_fence -- the barrier every non-temporal STORE SITE owes its reader
# =============================================================================


@always_inline
def nt_release_fence() -> None:
    """Order every preceding non-temporal store before anything that follows.

    ⛔ CALL THIS AT EVERY NT STORE SITE. It is not optional and it is not
    covered by the surrounding synchronisation "in practice". Non-temporal
    stores are WEAKLY ORDERED: they land in write-combining buffers that drain
    on their own schedule, outside the ordering the rest of the memory model
    gives you for free.

    ⚠ THE TRAP IS THAT IT USUALLY WORKS ANYWAY, ON x86, TODAY. A fork-join
    barrier ends in an atomic read-modify-write, and a LOCK-prefixed
    instruction has MFENCE semantics on x86 -- so an NT store published through
    such a barrier is, in fact, visible. Three reasons that is not a licence to
    omit the fence:
      * it is a property of the BARRIER's implementation, not of this store
        site, so it is silently lost when the barrier is rewritten -- and the
        failure mode is a torn read of somebody else's rows, under
        concurrency, with a correct row count;
      * it is a property of x86. On AArch64 `STNP` really can be reordered
        past a release store, and nothing at the barrier fixes it;
      * a `fence release` does NOT fix it on x86 either -- it lowers to
        NOTHING there, because the x86 memory model already gives release
        ordering for ORDINARY stores. That is the specific wrong answer a
        reader reaching for the portable spelling will land on.

    x86 gets the SSE1 `sfence`, which is exactly and only what is needed.
    ⚠ NOTE THE INTRINSIC NAME -- SFENCE is an **SSE1** instruction, so it is
    `llvm.x86.sse.sfence`. `llvm.x86.sse2.sfence` DOES NOT EXIST (LFENCE and
    MFENCE are the SSE2 pair) and fails only at LLVM lowering, long after type
    checking passes; a front-end compile check will not catch it. This is the
    same note `_copy_large_unrolled` carries, hoisted here because this is now
    the shared spelling.

    Everywhere else gets a SEQUENTIAL `fence`, which lowers to a real barrier
    (`dmb ish` on AArch64). Deliberately NOT `Ordering.RELEASE`, for the reason
    in the third bullet above.
    """
    comptime if CompilationTarget.is_x86():
        llvm_intrinsic["llvm.x86.sse.sfence", NoneType]()
    else:
        fence[Ordering.SEQUENTIAL]()


@always_inline
def fast_copy_bytes[
    dst_o: Origin[mut=True],
    src_mut: Bool,
    src_o: Origin[mut=src_mut], //,
    variant: Int = VARIANT_AUTO,
    nt_ok: Bool = False,
](
    dst: Span[UInt8, dst_o],
    src: Span[UInt8, src_o],
) -> None:
    """Copy `len(src)` bytes from `src` to `dst`. MEMCPY semantics — the two
    regions MUST NOT overlap.

    Parameters:
        variant: Force a specific strategy (`VARIANT_*`). Defaults to
            `VARIANT_AUTO`, which dispatches on size. The forced variants
            exist so the size-ladder microbenchmark can measure each strategy
            in isolation.
        nt_ok: Caller asserts nothing reads `dst` soon, permitting
            non-temporal stores for very large copies. DEFAULT FALSE — NT is
            a LOSS when the next operator folds over the destination hot.

    On a non-x86 target every variant falls through to `memmove`, which is
    correct everywhere and already tuned per-arch by libc.
    """
    var n = len(src)
    debug_assert(
        len(dst) >= n,
        "fast_copy_bytes: dst span shorter than src span",
    )
    if n <= 0:
        return

    var d = dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()
    # `get_immutable()` first: `unsafe_origin_cast` preserves mutability, so a
    # mutable-origin source (the common shape at our call sites, where the
    # source view is carved out of a writable buffer) cannot cast straight to
    # an immutable origin.
    var s = src.as_imm().unsafe_ptr().unsafe_origin_cast[
        ImmUntrackedOrigin
    ]()

    comptime if not CompilationTarget.is_x86():
        # No AVX2 to exploit; libc's per-arch tuned memmove is the best
        # available and is always correct.
        _copy_libc(d, s, n)
        return

    comptime if variant == VARIANT_LIBC:
        _copy_libc(d, s, n)
        return

    # Small + mid are strategy-independent: the branchy and straight-line
    # forms beat every alternative below 128 B, including a libc call whose
    # overhead alone exceeds the copy.
    if n < SMALL_MAX:
        _copy_small(d, s, n)
        return
    if n <= MID_MAX:
        _copy_mid(d, s, n)
        return

    comptime if variant == VARIANT_UNROLLED:
        _copy_large_unrolled[False](d, s, n)
        return
    comptime if variant == VARIANT_NT:
        _copy_large_unrolled[True](d, s, n)
        return

    # VARIANT_AUTO large-size ladder. The decision lives in `fast_copy_route`
    # so that a test can pin WHICH ARM a size takes; this is the only consumer
    # of that decision, and there is no second copy of the ladder.
    var route = fast_copy_route[nt_ok](n)
    if route == ROUTE_NT:
        _copy_large_unrolled[True](d, s, n)
        return
    # The ERMS band sits ABOVE the two arms below it because it beats both
    # everywhere inside it — the unrolled loop by 8-23%, and `memmove` by more
    # (compiler_rt's `memmove` was measured INDISTINGUISHABLE from the unrolled
    # loop above 128 KiB). See `ERMS_MIN`.
    if route == ROUTE_ERMS:
        _copy_erms(d, s, n)
        return
    if route == ROUTE_LIBC:
        _copy_libc(d, s, n)
        return
    _copy_large_unrolled[False](d, s, n)


@always_inline
def fast_move_bytes[
    dst_o: Origin[mut=True],
    src_mut: Bool,
    src_o: Origin[mut=src_mut], //,
](
    dst: Span[UInt8, dst_o],
    src: Span[UInt8, src_o],
) -> None:
    """Overlap-SAFE copy (MEMMOVE semantics). Delegates to `memmove`.

    Use when source and destination may overlap; `fast_copy_bytes` is
    undefined in that case exactly as stdlib `memcpy` is.

    ⛔ IT MUST NEVER BE ROUTED THROUGH THE ERMS BAND. `rep movsb` copies
    FORWARD (the x86-64 ABI guarantees DF is clear at every instruction
    boundary), so it is `memcpy` semantics and would silently corrupt a
    backward-overlapping move. This function is the one caller of `_copy_libc`
    that is about SEMANTICS rather than speed.

    ⚠ Which `memmove` this reaches depends on the link (see `LIBC_MIN`): a
    hermetic toolchain build reaches compiler_rt's memmove, statically
    defined in the executable. The overlap GUARANTEE holds either way —
    both are correct memmoves — but no performance claim about this call may
    assume glibc.
    """
    var n = len(src)
    if n <= 0:
        return
    _copy_libc(
        dst.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
        src.as_imm().unsafe_ptr().unsafe_origin_cast[
            ImmUntrackedOrigin
        ](),
        n,
    )
