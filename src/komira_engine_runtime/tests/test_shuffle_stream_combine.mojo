# =============================================================================
# test_shuffle_stream_combine.mojo
#   Phase B3 tests for `stream_combine_segment` — the producer STREAM-COMBINE
#   (distributed-shuffle).
# =============================================================================
#
# B3 replaces Phase A's one-shot SegWriter PUT with a STREAMING multipart write
# (open_write once -> per-partition append_bytes->take->write_at -> dense trailer
# -> close_write) whose peak RAM is bounded to ~one partition encode-buffer + one
# multipart part (NOT the whole producer output). It DRIVES the B2
# `ShuffleCombineBuffer` as the per-partition encode accumulator and REUSES the
# objectstore `.seg` dense-trailer codec.
#
# Three tests, in falsifying order of importance:
#
#   1. BYTE-IDENTITY vs SegWriter (THE load-bearing contract) — stream-combine R
#      partitions over the LocalFs FileSystem (multipart write path) -> read the
#      whole `.seg` bytes back; build the SAME `.seg` via Phase A's `write_segment`
#      -> assert the two byte blobs are BYTE-FOR-BYTE IDENTICAL. This is the
#      contract that lets `read_shuffle_partition`/`SegReader` consume a
#      stream-combined `.seg` UNCHANGED. Any drift in body order, dense-slot
#      accounting, or trailer/footer bytes fails this.
#
#   2. ROUND-TRIP via SegReader — stream-combine -> for each p, read partition p
#      back via SegReader (the resolve/get_range path) -> assert == the input
#      slice. Includes an EMPTY MIDDLE partition (zero-length slot) and asserts it
#      reads ZERO bytes AND that its non-empty neighbors read correctly (no slice
#      shift from the empty middle's dense slot).
#
#   3. BOUNDED RAM (the B3 guarantee) — drive R partitions of B bytes each through
#      the combine; assert the `ShuffleCombineBuffer.high_water()` stays ~one
#      partition slice (the LARGEST single partition), NOT the R×B sum. Peak
#      bounded by the largest single partition is the B3 property. (Scoping note:
#      the FULL 2 GB single-oversized-partition spill is B4; the bounded-RAM GATE
#      is B5. B3 proves the per-partition encode buffer never accumulates the sum.)
#
# Determinism: LocalFs ONLY (multipart write surface) + LocalFsConditionalStore
# (the SegReader read-back). NO wall-clock / network.
#
# COVERAGE GAP (flagged for the cloud path): this suite is LocalFs-ONLY, so the
# S3 ">= 1 uploaded part" corner is NOT exercised here. On S3, `close_write`
# raises "no parts uploaded" if zero parts were issued (s3_fs.mojo); the
# stream-combine relies on the ALWAYS-non-empty dense trailer (24*R + 16 bytes)
# becoming the trailing remainder part so an all-empty producer (every partition
# zero-length) still uploads >= 1 part. LocalFs has no such requirement, so that
# invariant is unguarded by this suite — it needs an S3Fs (or all-empty-producer)
# test on the cloud path.
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_true

from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink

from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.path import Path
from komira_shuffle.entry import PartitionSlot
from komira_shuffle.segment import (
    SegWriter,
    SegReader,
    write_segment,
)

from komira_engine_runtime.spill.shuffle_stream_combine import (
    ListPartitionSource,
    stream_combine_segment,
    stream_combine_segment_instrumented,
)
from komira_libc.posix import _read_env


# ---------------------------------------------------------------------------
# Scratch files go under $TEST_TMPDIR (set by the test runner, unique per
# action), else $TMPDIR; a fixed path would be shared by concurrent runs of
# this test. `_read_env` rather than `std.os.getenv`: komira_libc.posix owns
# the one `getenv` declaration in the link.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    return d


# -----------------------------------------------------------------------------
# Scratch root + byte helpers (mirrors the Phase-A harness shape).
# -----------------------------------------------------------------------------
def _scratch_root(tag: String) raises -> String:
    var t = UInt64(perf_counter_ns())
    return (
        (_scratch_dir() + String("/komira_shuffle_streamcombine_"))
        + tag
        + String("_")
        + String(t)
    )


def _make_payload(n: Int, marker: UInt32) -> List[UInt8]:
    """Deterministic n-byte payload seeded by `marker`; distinct markers produce
    distinct content at every position (a stale/shifted byte surfaces as a
    mismatch)."""
    var out = List[UInt8]()
    out.reserve(n)
    for i in range(n):
        var v = (marker * UInt32(31) + UInt32(i)) & UInt32(0xFF)
        out.append(UInt8(Int(v)))
    return out^


def _bytes_eq(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _ensure_root(root: String) raises:
    """Create the scratch root directory. The LocalFs FileSystem writes to a RAW
    path and does NOT create parent dirs (RawWriteFd.open_truncate fails on a
    missing dir); LocalFsConditionalStore's ctor mkdir's its root, so
    constructing one creates the dir. We do this BEFORE the FS write so the
    stream-combine's open_write succeeds, then read back via the same store."""
    var store = LocalFsConditionalStore(root.copy())
    _ = store^


def _cleanup(root: String):
    try:
        var store = LocalFsConditionalStore(root.copy())
        var res = store.list_with_delimiter(Path.parse(String("")))
        for i in range(len(res.objects)):
            store.delete(Path.parse(res.objects[i].location))
        _ = store^
    except:
        pass


# Build R deterministic partition slices + their row counts. `empty_partitions`
# marks which partitions are zero-length (empty). Non-empty partition p gets
# `base_len` bytes seeded by a per-partition marker, row_count = `base_rows`.
def _make_partitions(
    r: Int, base_len: Int, base_rows: Int64, empty: List[Bool]
) -> Tuple[List[List[UInt8]], List[Int64]]:
    var slices = List[List[UInt8]]()
    var row_counts = List[Int64]()
    for p in range(r):
        if empty[p]:
            slices.append(List[UInt8]())  # zero-length body
            row_counts.append(Int64(0))
        else:
            var marker = UInt32(p + 1) * UInt32(2654435761 & 0xFFFF)
            slices.append(_make_payload(base_len, marker))
            row_counts.append(base_rows)
    return (slices^, row_counts^)


# Build the same `.seg` via Phase A's SegWriter/write_segment over the SAME R
# slices (the byte-identity oracle). The key is chosen with NO percent-encoded
# bytes so LocalFsConditionalStore._path_for_key(key) == root + "/" + key.
def _write_segwriter_seg(
    root: String, key: String, slices: List[List[UInt8]], row_counts: List[Int64]
) raises -> List[UInt8]:
    var store = LocalFsConditionalStore(root.copy())
    var w = SegWriter()
    for p in range(len(slices)):
        w.append_partition(slices[p], row_counts[p])
    _ = write_segment(store, Path.parse(key), w^)
    var whole = store.get(Path.parse(key))
    _ = store^
    return whole^


# -----------------------------------------------------------------------------
# Test 1 — BYTE-IDENTITY vs SegWriter (THE load-bearing contract).
# -----------------------------------------------------------------------------
def test_stream_combine_byte_identical_to_segwriter() raises:
    print("[test_stream_combine_byte_identical_to_segwriter] starting...")
    var root = _scratch_root(String("identity"))
    _ensure_root(root)
    var r = 4
    var base_len = 7000  # non-trivial body size (and not a part multiple)

    # Partitions: pid 1 is an EMPTY MIDDLE partition (zero-length slot). The rest
    # are non-empty with distinct content + a non-trivial row count.
    var empty = List[Bool]()
    empty.append(False)  # pid 0 non-empty
    empty.append(True)   # pid 1 EMPTY (middle)
    empty.append(False)  # pid 2 non-empty
    empty.append(False)  # pid 3 non-empty
    var parts = _make_partitions(r, base_len, Int64(13), empty)
    var slices = parts[0].copy()
    var row_counts = parts[1].copy()

    # ---- (A) STREAM-COMBINE via the LocalFs FileSystem (multipart write path).
    # Key with no percent-encoded bytes so the FS raw path == the store's
    # flat-encoded path for the same key (so SegReader/get reads the same file).
    var sc_key = String("streamcombine_p0.seg")
    var sc_path = root + "/" + sc_key
    var fs = LocalFs[NoopSink].new()
    var src = ListPartitionSource(slices.copy(), row_counts.copy())
    var slots = stream_combine_segment(fs, sc_path, src^)
    assert_equal(len(slots), r, "stream-combine returns R dense slots")

    # Read the stream-combined `.seg` whole bytes back (via the store -> the
    # same file the FS wrote).
    var store = LocalFsConditionalStore(root.copy())
    var sc_bytes = store.get(Path.parse(sc_key))
    _ = store^

    # ---- (B) The Phase-A SegWriter `.seg` over the SAME R slices (the oracle).
    var sw_bytes = _write_segwriter_seg(
        root, String("segwriter_oracle.seg"), slices, row_counts
    )

    # ---- THE CONTRACT: byte-for-byte identical.
    assert_equal(
        len(sc_bytes),
        len(sw_bytes),
        "stream-combine `.seg` length == SegWriter `.seg` length",
    )
    assert_true(
        _bytes_eq(sc_bytes, sw_bytes),
        "stream-combine `.seg` is BYTE-IDENTICAL to SegWriter `.seg`",
    )
    print(
        "  byte-identity: ",
        len(sc_bytes),
        " bytes, IDENTICAL to SegWriter",
    )
    _ = slices^
    _ = row_counts^
    _cleanup(root)
    print("[test_stream_combine_byte_identical_to_segwriter] PASS")


# -----------------------------------------------------------------------------
# Test 2 — ROUND-TRIP via SegReader (incl. empty middle partition).
# -----------------------------------------------------------------------------
def test_stream_combine_round_trip_via_segreader() raises:
    print("[test_stream_combine_round_trip_via_segreader] starting...")
    var root = _scratch_root(String("roundtrip"))
    _ensure_root(root)
    var r = 4
    var base_len = 5000

    # pid 2 is the EMPTY MIDDLE partition this time (zero-length slot between two
    # non-empty neighbors pid 1 and pid 3).
    var empty = List[Bool]()
    empty.append(False)
    empty.append(False)
    empty.append(True)   # pid 2 EMPTY (middle)
    empty.append(False)
    var parts = _make_partitions(r, base_len, Int64(9), empty)
    var slices = parts[0].copy()
    var row_counts = parts[1].copy()

    var sc_key = String("roundtrip_p0.seg")
    var sc_path = root + "/" + sc_key
    var fs = LocalFs[NoopSink].new()
    var src = ListPartitionSource(slices.copy(), row_counts.copy())
    var _slots = stream_combine_segment(fs, sc_path, src^)

    # Read EACH partition back via SegReader (the resolve/get_range path) and
    # assert byte-equal to the input slice. The empty middle reads ZERO bytes.
    var store = LocalFsConditionalStore(root.copy())
    var reader = SegReader[LocalFsConditionalStore](store.clone(), Path.parse(sc_key))

    for p in range(r):
        var back = reader.read_partition(p)
        if empty[p]:
            assert_equal(
                len(back),
                0,
                "empty MIDDLE partition " + String(p) + " reads ZERO bytes",
            )
        else:
            assert_true(
                _bytes_eq(back, slices[p]),
                "partition " + String(p) + " round-trips byte-identical",
            )
    _ = reader^
    _ = store^
    _ = slices^
    _ = row_counts^
    _cleanup(root)
    print("[test_stream_combine_round_trip_via_segreader] PASS")


# -----------------------------------------------------------------------------
# Test 3 — BOUNDED RAM (the B3 guarantee).
# -----------------------------------------------------------------------------
def test_stream_combine_bounded_ram() raises:
    print("[test_stream_combine_bounded_ram] starting...")
    var root = _scratch_root(String("bounded"))
    _ensure_root(root)

    # Drive R partitions of B bytes each through the combine. The B2 combine
    # buffer's high_water() must stay bounded to ~ONE partition slice (B), NOT
    # the R×B sum — `take()` frees the slice at each partition boundary so the
    # per-partition encode buffer never accumulates.
    #
    # SCOPING NOTE (in-test): peak bounded by the LARGEST single partition is the
    # B3 property. The FULL 2 GB single-oversized-partition SPILL is B4; the
    # bounded-RAM GATE (the 2 GB hot-partition assertion) is B5. B3 proves the
    # buffer never holds the sum — a uniform-then-skewed pair pins that.
    var r = 32
    var per_partition = 8192  # bytes per uniform partition slice

    var empty = List[Bool]()
    for _p in range(r):
        empty.append(False)
    var parts = _make_partitions(r, per_partition, Int64(1), empty)
    var slices = parts[0].copy()
    var row_counts = parts[1].copy()

    var sc_key = String("bounded_p0.seg")
    var sc_path = root + "/" + sc_key
    var fs = LocalFs[NoopSink].new()
    var src = ListPartitionSource(slices.copy(), row_counts.copy())
    var res = stream_combine_segment_instrumented(fs, sc_path, src^)

    var sum_all = r * per_partition  # what hw would be if take() never freed
    print("  R x B uniform: high_water()=", res.high_water, " bytes")
    print("    (sum of all R partitions would be ", sum_all, " bytes)")
    assert_equal(
        res.high_water,
        per_partition,
        "uniform: high_water == ONE partition slice (NOT the R×B sum)",
    )
    assert_true(
        res.high_water < sum_all,
        "uniform: high_water bounded below the R×B sum (take() freed each slice)",
    )

    # SKEWED: one HOT partition larger than the rest. The high-water must track
    # the single largest slice (the hot one), still bounded — never the sum.
    var hot_idx = r // 2
    var hot_len = per_partition * 8  # the hot partition
    var cold_len = 256
    var skew_slices = List[List[UInt8]]()
    var skew_rcs = List[Int64]()
    var skew_total = 0
    for p in range(r):
        var ln = hot_len if p == hot_idx else cold_len
        var marker = UInt32(p + 7) * UInt32(53)
        skew_slices.append(_make_payload(ln, marker))
        skew_rcs.append(Int64(1))
        skew_total += ln

    var sc_key2 = String("bounded_skew_p0.seg")
    var sc_path2 = root + "/" + sc_key2
    var fs2 = LocalFs[NoopSink].new()
    var src2 = ListPartitionSource(skew_slices.copy(), skew_rcs.copy())
    var res2 = stream_combine_segment_instrumented(fs2, sc_path2, src2^)

    print("  skewed: hot=", hot_len, " bytes; high_water()=", res2.high_water)
    print("    (sum of all skewed partitions would be ", skew_total, " bytes)")
    assert_equal(
        res2.high_water,
        hot_len,
        "skewed: high_water == the single HOT slice (NOT the sum)",
    )
    assert_true(
        res2.high_water < skew_total,
        "skewed: high_water bounded below the sum (peak = largest single slice)",
    )

    # Byte-identity STILL holds under the skewed drive (sanity: the instrumented
    # form produces the same `.seg` as SegWriter).
    var store = LocalFsConditionalStore(root.copy())
    var sc2_bytes = store.get(Path.parse(sc_key2))
    _ = store^
    var sw2_bytes = _write_segwriter_seg(
        root, String("bounded_skew_oracle.seg"), skew_slices, skew_rcs
    )
    assert_true(
        _bytes_eq(sc2_bytes, sw2_bytes),
        "skewed stream-combine `.seg` is BYTE-IDENTICAL to SegWriter",
    )

    _ = slices^
    _ = row_counts^
    _ = skew_slices^
    _ = skew_rcs^
    _cleanup(root)
    print("[test_stream_combine_bounded_ram] PASS")


def main() raises:
    print("====================================================")
    print(" stream_combine_segment — Phase B3 tests")
    print("   (streaming multipart `.seg` write; byte-identical")
    print("    to SegWriter; bounded per-partition RAM via B2)")
    print("====================================================")
    print()
    test_stream_combine_byte_identical_to_segwriter()
    test_stream_combine_round_trip_via_segreader()
    test_stream_combine_bounded_ram()
    print()
    print(
        "[test_shuffle_stream_combine] all 3 tests (byte-identity + round-trip"
        " + bounded-RAM) PASS"
    )
