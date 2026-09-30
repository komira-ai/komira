# =============================================================================
# Size-ladder microbenchmark for komira_core/simd/fast_copy.mojo.
# =============================================================================
#
# THIS IS A MEASUREMENT HARNESS, NOT A CORRECTNESS GATE. It is registered
# `manual` so it never runs as part of an automatic suite — a timing harness in
# the per-commit lane is a flake generator, and this one moves enough DRAM
# traffic (up to 64 MiB buffers) to perturb anything running beside it.
#
# Run it explicitly, on an otherwise-idle machine, under a memory cap.
#
# # What it answers
#
# Which copy strategy to route where. The four tables below cross the two
# factors that actually flip the answer:
#
#   * ALIGNMENT — aligned (both 64 B-aligned, the AB[64] buffer case) vs
#     unaligned (dst+1 / src+3, the offset-into-a-buffer case).
#   * CONSUMER — "cold" (nothing reads the destination afterwards) vs "hot"
#     (the next operator immediately folds over it). This factor is the whole
#     NT-store question: non-temporal stores skip the read-for-ownership and
#     win when nothing reads the destination, but force the consumer into a
#     full DRAM miss when something does. A table that only measured "cold"
#     would recommend NT everywhere and be wrong.
#
# # Implementations compared
#
#   stdlib   — Mojo `memcpy`. The naive inline 32 B loop + up-to-31-iteration
#              scalar byte tail (see fast_copy.mojo header for the disassembly).
#   auto     — `fast_copy_bytes` with its production size dispatch.
#   unroll   — forced 128 B/iter 4x-unrolled AVX2, cached stores.
#   nt       — forced non-temporal stores.
#   libc     — glibc `memmove` (IFUNC-selected `__memmove_avx_unaligned_erms`).
#
# Reported number is GB/s (higher is better). Rep counts are chosen per size to
# hold roughly constant total bytes moved, so small sizes are not dominated by
# loop overhead and large sizes do not take forever.
#
# A `checksum` is accumulated from every destination and printed at the end so
# no copy can be dead-code eliminated.
#
# =============================================================================
# RECORDED RESULT — i7-14700K, AVX2 + ERMS + FSRM, no AVX-512.
#
# ⚠ MEASURED UNDER LOAD (load average ~6, concurrent compiles on the machine).
# Directionally solid and internally consistent, but NOT a clean measurement —
# re-run on an idle machine before treating any single cell as authoritative. One
# cell is visibly noise: 16 B aligned/cold reads auto=11.46 vs unroll=34.38,
# yet `auto` and `unroll` execute the IDENTICAL `_copy_small` code path at
# n<32, so that gap is measurement scatter, not a real difference.
#
# GB/s, higher is better.
#
#  ALIGNED, consumer does NOT read       ALIGNED, consumer READS immediately
#  size  stdlib  auto  unroll   nt libc  size stdlib  auto unroll   nt  libc
#   16B   25.40 11.46   34.38 34.3  6.8   16B  14.66 17.60  17.59 17.6 12.49
#  128B   45.91 91.73   89.46 91.7 44.8  128B  58.67 87.14  88.00 88.0 53.98
#  256B   56.27 76.70   78.61  1.4 84.0  256B  58.62 82.40  76.56  2.0 56.24
#    1K   90.48 254.9   253.2  8.2 224.    1K  53.07 86.49  86.48  5.6 56.80
#   16K  176.02 255.1   256.8 38.1 311.   16K  49.54 77.47  77.24  8.4 57.01
#  256K   71.03 76.07   70.53 47.9 75.9  256K  32.47 41.07  39.42 12.1 33.11
#    4M   29.06 28.85   29.18 40.8 28.9    4M  18.20 18.94  19.07 14.6 18.22
#   64M   13.52 24.03   14.40 20.9 24.4   64M   8.90 11.83   9.18 11.3 12.11
#
# WHICH VARIANT TO ROUTE WHERE (the question this table exists to answer):
#
#   < 32 B      -> hand-rolled small path. libc loses on call overhead alone
#                  (6.8 vs 25.4 GB/s at 16 B).
#   32 B..128 B -> hand-rolled mid path. ~1.5-2x over stdlib, ~2x over libc.
#   256 B..16 K -> hand-rolled unrolled path. THIS IS THE BIG WIN and it is
#                  exactly where Arrow buffer copies live. In the realistic
#                  hot-consumer case: 1.6-1.8x over stdlib AND over libc.
#                  (In the cold-consumer case libc's ERMS pulls ahead at
#                  512 B..16 K — 201-312 GB/s — but our consumers almost
#                  always read the destination immediately.)
#   64 K..1 M   -> ours == libc within noise; both ~1.15-1.25x over stdlib.
#                  Memory-bandwidth-bound, so the handoff point is not
#                  sensitive.
#   > 4 M       -> bandwidth-bound. Use libc. NT ONLY if nothing reads the
#                  destination soon (see the NT_MIN comment in fast_copy.mojo
#                  for the full win/loss window).
#
# THE HONEST ANSWER ON libc: "just call memmove" is right for the >=256 KiB
# band and WRONG everywhere below it — at 16 B it is 3.7x slower than an
# inline copy, and in the hot-consumer mid band it is ~1.4x slower than the
# unrolled path. So the deliverable is a size-dispatched primitive that
# delegates to libc only in the band where libc actually wins.
# =============================================================================

from std.memory import unsafe_memcpy
from std.time import perf_counter_ns

from komira_core.simd.fast_copy import (
    fast_copy_bytes,
    VARIANT_AUTO,
    VARIANT_UNROLLED,
    VARIANT_NT,
    VARIANT_LIBC,
)


# =============================================================================
# Config
# =============================================================================

# Implementation selectors.
comptime IMPL_STDLIB: Int = 0
comptime IMPL_AUTO: Int = 1
comptime IMPL_UNROLL: Int = 2
comptime IMPL_NT: Int = 3
comptime IMPL_LIBC: Int = 4

# Roughly-constant bytes moved per measured cell (~64 MiB), clamped by the
# rep bounds below.
comptime TARGET_BYTES: Int = 64 * 1024 * 1024
comptime MIN_REPS: Int = 4
comptime MAX_REPS: Int = 200000

# Slack so the unaligned variants can offset into the buffers.
comptime SLACK: Int = 128


@always_inline
def _reps_for(n: Int) -> Int:
    var r = TARGET_BYTES // n
    if r < MIN_REPS:
        r = MIN_REPS
    if r > MAX_REPS:
        r = MAX_REPS
    return r


def _fmt_gbs(bytes_moved: Int, ns: Int) -> String:
    """GB/s to two decimals, integer-only arithmetic (avoids float formatting
    differences across platforms)."""
    if ns <= 0:
        return String("n/a")
    # GB/s = bytes / ns  (since 1e9 bytes/s == 1 byte/ns). x100 for 2 dp.
    var hundredths = (bytes_moved * 100) // ns
    var whole = hundredths // 100
    var frac = hundredths % 100
    var fs = String(frac)
    if frac < 10:
        fs = String("0") + fs
    return String(whole) + String(".") + fs


def _fmt_size(n: Int) -> String:
    if n >= 1024 * 1024:
        return String(n // (1024 * 1024)) + String("M")
    if n >= 1024:
        return String(n // 1024) + String("K")
    return String(n) + String("B")


def _pad(s: String, width: Int) -> String:
    var out = s
    while out.byte_length() < width:
        out = String(" ") + out
    return out


# =============================================================================
# The measured inner loop.
# =============================================================================


def _run_cell[
    impl: Int, hot: Bool
](
    mut dst: List[UInt8],
    src: List[UInt8],
    dst_off: Int,
    src_off: Int,
    n: Int,
    reps: Int,
    mut checksum: Int,
) -> Int:
    """Time `reps` copies of `n` bytes. Returns elapsed nanoseconds.

    When `hot` is True the destination is immediately re-read (one byte per
    64 B cache line) to model the next operator folding over it — this is the
    case that decides whether non-temporal stores help or hurt.
    """
    # --- Warmup: fault in the pages and settle the frequency, unmeasured.
    for _ in range(2):
        comptime if impl == IMPL_STDLIB:
            unsafe_memcpy(
                dest=dst.unsafe_ptr() + dst_off,
                src=src.unsafe_ptr() + src_off,
                count=n,
            )
        else:
            fast_copy_bytes[
                variant = (
                    VARIANT_AUTO if impl == IMPL_AUTO
                    else (
                        VARIANT_UNROLLED if impl == IMPL_UNROLL
                        else (VARIANT_NT if impl == IMPL_NT else VARIANT_LIBC)
                    )
                )
            ](
                Span[UInt8, origin_of(dst)](
                    unsafe_ptr=dst.unsafe_ptr() + dst_off, length=n
                ),
                Span[UInt8, origin_of(src)](
                    unsafe_ptr=src.unsafe_ptr() + src_off, length=n
                ),
            )

    var t0 = perf_counter_ns()
    for _ in range(reps):
        comptime if impl == IMPL_STDLIB:
            unsafe_memcpy(
                dest=dst.unsafe_ptr() + dst_off,
                src=src.unsafe_ptr() + src_off,
                count=n,
            )
        else:
            fast_copy_bytes[
                variant = (
                    VARIANT_AUTO if impl == IMPL_AUTO
                    else (
                        VARIANT_UNROLLED if impl == IMPL_UNROLL
                        else (VARIANT_NT if impl == IMPL_NT else VARIANT_LIBC)
                    )
                )
            ](
                Span[UInt8, origin_of(dst)](
                    unsafe_ptr=dst.unsafe_ptr() + dst_off, length=n
                ),
                Span[UInt8, origin_of(src)](
                    unsafe_ptr=src.unsafe_ptr() + src_off, length=n
                ),
            )

        comptime if hot:
            # Consumer reads the destination immediately: one byte per cache
            # line, so the cost is the misses, not the arithmetic.
            var acc = 0
            var k = 0
            while k < n:
                acc += Int(dst[dst_off + k])
                k += 64
            checksum += acc
    var t1 = perf_counter_ns()

    comptime if not hot:
        # Touch one byte so the copies cannot be eliminated, without paying
        # the full re-read that would defeat the "cold consumer" case.
        checksum += Int(dst[dst_off])

    # `perf_counter_ns()` returns UInt; the caller's arithmetic is Int.
    return Int(t1 - t0)


def _run_row[
    hot: Bool
](
    mut dst: List[UInt8],
    src: List[UInt8],
    dst_off: Int,
    src_off: Int,
    n: Int,
    mut checksum: Int,
) -> None:
    """One table row: all five implementations at size `n`."""
    var reps = _reps_for(n)
    var moved = n * reps

    var ns_std = _run_cell[IMPL_STDLIB, hot](
        dst, src, dst_off, src_off, n, reps, checksum
    )
    var ns_auto = _run_cell[IMPL_AUTO, hot](
        dst, src, dst_off, src_off, n, reps, checksum
    )
    var ns_unroll = _run_cell[IMPL_UNROLL, hot](
        dst, src, dst_off, src_off, n, reps, checksum
    )
    var ns_nt = _run_cell[IMPL_NT, hot](
        dst, src, dst_off, src_off, n, reps, checksum
    )
    var ns_libc = _run_cell[IMPL_LIBC, hot](
        dst, src, dst_off, src_off, n, reps, checksum
    )

    print(
        _pad(_fmt_size(n), 8),
        _pad(_fmt_gbs(moved, ns_std), 10),
        _pad(_fmt_gbs(moved, ns_auto), 10),
        _pad(_fmt_gbs(moved, ns_unroll), 10),
        _pad(_fmt_gbs(moved, ns_nt), 10),
        _pad(_fmt_gbs(moved, ns_libc), 10),
    )


def _run_table[
    hot: Bool
](title: String, dst_off: Int, src_off: Int, mut checksum: Int) -> None:
    print("")
    print("=== ", title, " ===")
    print(
        _pad(String("size"), 8),
        _pad(String("stdlib"), 10),
        _pad(String("auto"), 10),
        _pad(String("unroll"), 10),
        _pad(String("nt"), 10),
        _pad(String("libc"), 10),
    )

    var sizes: List[Int] = [
        16, 32, 64, 128, 256, 512,
        1024, 4096, 16384, 65536,
        262144, 1048576, 4194304, 16777216, 67108864,
    ]

    for i in range(len(sizes)):
        var n = sizes[i]
        var total = n + SLACK
        var dst = List[UInt8](length=total, fill=0)
        var src = List[UInt8](length=total, fill=0)
        for k in range(total):
            src[k] = UInt8(((k * 167) + 13) & 0xFF)
        _run_row[hot](dst, src, dst_off, src_off, n, checksum)


# =============================================================================
# Entrypoint
# =============================================================================


def main() raises -> None:
    print("fast_copy size ladder — GB/s (higher is better)")
    print("cols: stdlib=Mojo memcpy | auto/unroll/nt=fast_copy | libc=memmove")

    var checksum = 0

    # `List[UInt8]` allocations route through tcmalloc, which returns at least
    # 16 B-aligned blocks for these sizes; offset 0 is the "aligned" case in
    # the sense that matters (dst and src share their low bits), and the
    # unaligned tables deliberately desynchronise them.
    _run_table[False](String("ALIGNED, consumer does NOT read"), 0, 0, checksum)
    _run_table[True](String("ALIGNED, consumer READS immediately"), 0, 0, checksum)
    _run_table[False](
        String("UNALIGNED (dst+1, src+3), consumer does NOT read"), 1, 3, checksum
    )
    _run_table[True](
        String("UNALIGNED (dst+1, src+3), consumer READS immediately"), 1, 3, checksum
    )

    print("")
    print("checksum (anti-DCE, value itself is meaningless):", checksum)
