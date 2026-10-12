# =============================================================================
# test_shuffle_combine_buffer: `ShuffleCombineBuffer`, the per-partition
# encode buffer of the shuffle producer combine.
# =============================================================================
#
#   1. Destroy-recreate stress: 64+ cycles of construct -> append ->
#      take/reset -> destroy -> reconstruct, each cycle with a unique marker.
#      Bytes written in cycle N never appear in cycle N+1 and every cycle's
#      values are right. This is the shape that catches an owning field whose
#      storage outlives (or is reused under) its struct.
#   2. Bounded high-water: many partitions of many bytes through
#      append/take/reset; `high_water()` stays at the largest single partition,
#      not the sum. A `take()`/`reset()` that kept the live slice would grow
#      it to the sum and fail.
#   3. Round trip: append bytes -> take -> byte-identical to the input.
# =============================================================================

from std.time import perf_counter_ns

from komira_engine_runtime.spill.shuffle_combine_buffer import (
    ShuffleCombineBuffer,
)


# -----------------------------------------------------------------------------
# Helper — build a deterministic byte payload of length `n` seeded by `marker`.
# -----------------------------------------------------------------------------


def _make_payload(n: Int, marker: UInt32) -> List[UInt8]:
    """Build an `n`-byte payload whose content is a deterministic function of
    `marker` and the byte index. Distinct markers produce distinct content at
    every position, so a stale-byte bleed across cycles surfaces as a content
    mismatch."""
    var out = List[UInt8]()
    out.reserve(n)
    for i in range(n):
        # Mix the marker and the index so every (marker, i) pair is distinct
        # mod 256. (marker * 31 + i) covers the byte space densely.
        var v = (marker * UInt32(31) + UInt32(i)) & UInt32(0xFF)
        out.append(UInt8(Int(v)))
    return out^


def _expected_byte(i: Int, marker: UInt32) -> UInt8:
    """The byte `_make_payload` would produce at index `i` for `marker`."""
    var v = (marker * UInt32(31) + UInt32(i)) & UInt32(0xFF)
    return UInt8(Int(v))


# -----------------------------------------------------------------------------
# Test 1 — destroy-recreate stress.
# -----------------------------------------------------------------------------


def _test_destroy_recreate_stress() raises -> Int:
    """64+ construct/append/take-or-reset/DESTROY/reconstruct cycles, each with
    a UNIQUE marker. Asserts:
      * the bytes read back inside each cycle are exactly what was written that
        cycle (no stale-byte bleed from a prior cycle's allocation),
      * `take()` returns byte-identical content,
      * after `take()`/`reset()` the live count is 0 (the slice was released).

    Returns the number of failures (0 = pass)."""
    print("=== Test 1: destroy-recreate stress (64+ cycles) ===")
    var n_cycles: Int = 80  # > 64, exceeds the required floor
    var slice_len: Int = 4096  # one partition-slice-sized payload
    var failures: Int = 0

    for cycle in range(n_cycles):
        # Unique per-cycle marker so any tcmalloc byte-reuse across the
        # destroy-recreate boundary surfaces as a content mismatch.
        var marker = UInt32(cycle + 1) * UInt32(2654435761 & 0xFFFF)

        # ---- Construct (per map task) ------------------------------------
        var buf = ShuffleCombineBuffer()

        # ---- Append the partition slice ----------------------------------
        var payload = _make_payload(slice_len, marker)
        buf.append_bytes(Span(payload))

        if buf.len() != slice_len:
            failures += 1
            print(
                "  cycle ",
                cycle,
                " FAIL: live len ",
                buf.len(),
                " != ",
                slice_len,
            )

        # ---- take() the finalized slice; verify byte-identical -----------
        # Alternate take() vs reset() across cycles so BOTH per-partition
        # release paths are exercised under the destroy-recreate stress.
        if cycle % 2 == 0:
            var taken = buf.take()
            if len(taken) != slice_len:
                failures += 1
                print("  cycle ", cycle, " FAIL: taken len ", len(taken))
            else:
                # Verify every byte matches THIS cycle's marker — a stale
                # byte from cycle N-1's allocation would mismatch here.
                var bad: Int = 0
                for i in range(slice_len):
                    if taken[i] != _expected_byte(i, marker):
                        bad += 1
                if bad != 0:
                    failures += 1
                    print(
                        "  cycle ",
                        cycle,
                        " FAIL: ",
                        bad,
                        " stale/mismatched bytes in taken slice",
                    )
            # After take(), the live slice must be empty (released).
            if buf.len() != 0:
                failures += 1
                print(
                    "  cycle ", cycle, " FAIL: live len after take() != 0"
                )
        else:
            buf.reset()
            if buf.len() != 0:
                failures += 1
                print(
                    "  cycle ", cycle, " FAIL: live len after reset() != 0"
                )

        # ---- Re-append a SECOND distinct slice in the SAME buffer --------
        # This exercises take/reset -> re-fill within one buffer instance,
        # the per-R-partition reuse path. Use a second distinct marker.
        var marker2 = marker ^ UInt32(0xA5A5A5A5)
        var payload2 = _make_payload(slice_len, marker2)
        buf.append_bytes(Span(payload2))
        var taken2 = buf.take()
        var bad2: Int = 0
        for i in range(slice_len):
            if taken2[i] != _expected_byte(i, marker2):
                bad2 += 1
        if bad2 != 0:
            failures += 1
            print(
                "  cycle ",
                cycle,
                " FAIL: ",
                bad2,
                " stale/mismatched bytes in 2nd slice",
            )

        # ---- DESTROY (buf drops here at scope exit -> next iter reconstructs)
        # The OwnedPointer[List[UInt8]] drop frees the buffer; the next
        # cycle's construct gets fresh (possibly tcmalloc-reused) bytes.

    if failures == 0:
        print("  PASS: ", n_cycles, " cycles, no stale-byte bleed")
    return failures


# -----------------------------------------------------------------------------
# Test 2 — bounded high-water under many-partitions x many-bytes.
# -----------------------------------------------------------------------------


def _test_bounded_high_water() raises -> Int:
    """Drive R partitions x B bytes through one buffer with a take()/reset()
    at each partition boundary; assert `high_water()` is bounded to ~one
    partition slice, NOT the sum of all partitions.

    Toggle check (documented): if take()/reset() did NOT free the live slice,
    the live count would accumulate to R*B and high_water() would reach R*B.
    The assertion that high_water() == max single partition size (NOT R*B)
    falsifies a non-releasing reset.

    Returns the number of failures (0 = pass)."""
    print("=== Test 2: bounded high-water (R partitions x B bytes) ===")
    var failures: Int = 0
    var R: Int = 64  # number of radix partitions
    var per_partition: Int = 8192  # bytes per partition slice
    var total_appended: Int = 0

    var buf = ShuffleCombineBuffer()

    for p in range(R):
        var marker = UInt32(p + 1) * UInt32(101)
        var payload = _make_payload(per_partition, marker)
        buf.append_bytes(Span(payload))
        total_appended += per_partition
        # Drain at the partition boundary (the §2.1 stream-combine shape).
        var taken = buf.take()
        if len(taken) != per_partition:
            failures += 1
            print("  partition ", p, " FAIL: taken len ", len(taken))
        # Live slice released -> live count back to 0.
        if buf.len() != 0:
            failures += 1
            print("  partition ", p, " FAIL: live len after take() != 0")

    var hw = buf.high_water()
    var sum_all = R * per_partition  # what hw would be if reset never freed

    print("  total bytes streamed: ", total_appended)
    print("  high_water(): ", hw, " bytes")
    print("  (sum of all partitions would be: ", sum_all, " bytes)")

    # The high-water must be bounded to ~one partition slice (the largest
    # single slice held), NOT the sum of all R partitions.
    if hw != per_partition:
        failures += 1
        print(
            "  FAIL: high_water ",
            hw,
            " != one partition slice ",
            per_partition,
        )
    if hw >= sum_all:
        failures += 1
        print(
            "  FAIL: high_water ",
            hw,
            " reached the unbounded sum ",
            sum_all,
            " -> reset did not free",
        )

    # Also verify a SKEWED distribution: one hot partition larger than the
    # rest. high_water must track the single largest slice, still bounded.
    var buf2 = ShuffleCombineBuffer()
    var hot: Int = per_partition * 4  # the hot partition
    var cold: Int = 256
    var skew_total: Int = 0
    for p in range(R):
        var sz = hot if p == R // 2 else cold
        var marker = UInt32(p + 7) * UInt32(53)
        var payload = _make_payload(sz, marker)
        buf2.append_bytes(Span(payload))
        skew_total += sz
        _ = buf2.take()
    var hw2 = buf2.high_water()
    print("  skewed: hot partition ", hot, " bytes; high_water(): ", hw2)
    if hw2 != hot:
        failures += 1
        print("  FAIL: skewed high_water ", hw2, " != hot slice ", hot)
    if hw2 >= skew_total:
        failures += 1
        print(
            "  FAIL: skewed high_water ",
            hw2,
            " reached the unbounded sum ",
            skew_total,
        )

    if failures == 0:
        print("  PASS: high_water bounded to one partition slice (not sum)")
    return failures


# -----------------------------------------------------------------------------
# Test 3 — round-trip byte-identity.
# -----------------------------------------------------------------------------


def _test_round_trip() raises -> Int:
    """append bytes -> take -> assert byte-identical to input, across several
    sizes including empty + multi-append-into-one-slice."""
    print("=== Test 3: round-trip byte-identity ===")
    var failures: Int = 0

    # Single append, several sizes (incl. 0 and 1).
    var sizes = List[Int]()
    sizes.append(0)
    sizes.append(1)
    sizes.append(255)
    sizes.append(4096)
    sizes.append(65537)
    for si in range(len(sizes)):
        var n = sizes[si]
        var marker = UInt32(n + 1) * UInt32(union_seed())
        var payload = _make_payload(n, marker)
        var buf = ShuffleCombineBuffer()
        buf.append_bytes(Span(payload))
        if buf.len() != n:
            failures += 1
            print("  size ", n, " FAIL: live len ", buf.len())
        var taken = buf.take()
        if len(taken) != n:
            failures += 1
            print("  size ", n, " FAIL: taken len ", len(taken))
        else:
            var bad: Int = 0
            for i in range(n):
                if taken[i] != _expected_byte(i, marker):
                    bad += 1
            if bad != 0:
                failures += 1
                print("  size ", n, " FAIL: ", bad, " byte mismatches")

    # Multiple appends accumulate into ONE slice, then take() returns the
    # concatenation (the per-partition sub-table-chunk accumulation shape).
    var buf2 = ShuffleCombineBuffer()
    var chunk_a = _make_payload(1000, UInt32(11))
    var chunk_b = _make_payload(500, UInt32(22))
    var chunk_c = _make_payload(1500, UInt32(33))
    buf2.append_bytes(Span(chunk_a))
    buf2.append_bytes(Span(chunk_b))
    buf2.append_bytes(Span(chunk_c))
    var concat = buf2.take()
    var expected_len = 1000 + 500 + 1500
    if len(concat) != expected_len:
        failures += 1
        print("  multi-append FAIL: len ", len(concat), " != ", expected_len)
    else:
        var bad: Int = 0
        for i in range(1000):
            if concat[i] != _expected_byte(i, UInt32(11)):
                bad += 1
        for i in range(500):
            if concat[1000 + i] != _expected_byte(i, UInt32(22)):
                bad += 1
        for i in range(1500):
            if concat[1500 + i] != _expected_byte(i, UInt32(33)):
                bad += 1
        if bad != 0:
            failures += 1
            print("  multi-append FAIL: ", bad, " byte mismatches in concat")

    if failures == 0:
        print("  PASS: round-trip byte-identical across all sizes")
    return failures


def union_seed() -> UInt32:
    """Small fixed seed for the round-trip marker mixing (kept out of the
    hot helper so the marker for size 0 is still distinct)."""
    return UInt32(2246822519 & 0xFFFF)


# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------


def main() raises:
    print("====================================================")
    print(" ShuffleCombineBuffer tests")
    print("   (concrete-origin OwnedPointer[List[UInt8]] field;")
    print("    destroy-recreate + bounded high-water)")
    print("====================================================")
    print()

    var t0 = perf_counter_ns()
    var total_failures: Int = 0

    total_failures += _test_destroy_recreate_stress()
    print()
    total_failures += _test_bounded_high_water()
    print()
    total_failures += _test_round_trip()
    print()

    var elapsed_ms = (perf_counter_ns() - t0) // 1_000_000
    print("====================================================")
    if total_failures == 0:
        print(" ALL TESTS PASSED (", elapsed_ms, " ms)")
    else:
        print(" ", total_failures, " FAILURES (", elapsed_ms, " ms)")
    print("====================================================")

    if total_failures != 0:
        raise Error(
            "ShuffleCombineBuffer tests: "
            + String(total_failures)
            + " failures"
        )
