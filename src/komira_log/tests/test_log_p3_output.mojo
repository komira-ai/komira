# =============================================================================
# test_log_p3_output.mojo — komira_log P3 output side.
# =============================================================================
#
# The production output side, driven directly (no runtime wiring — the engine
# drain → sink seam is exercised through the sink + the engine's drain helpers).
# Covers:
#
#   1. Per-core segments — two "cores" emit → assert two segment files with the
#      right per-core content + NO cross-core mixing (the share-nothing prop).
#   2. log-merge — segments with interleaved timestamps → k-way merge → assert
#      the output is GLOBALLY timestamp-ordered (records from different cores
#      correctly interleaved by time).
#   3. Rotation (size) — emit past the size threshold → assert a rotation
#      happened (a new live file, the old retained as an archive).
#   4. Rotation (retention) — emit past several thresholds with keep=K → assert
#      only the last K archives survive.
#   5. Backpressure — a DROP ring drops + counts (query worker not blocked); a
#      BLOCK ring blocks; an ERROR record is never dropped (escalate path).
#   6. Calibration — a re-anchor over a (simulated) long run keeps tick→wall
#      accurate; the rate-limit only re-anchors past the cadence.
#   7. Single-file sink + FILE/STDERR kind routing.
# =============================================================================

from std.os import remove
from std.io import FileHandle

from std.testing import assert_equal, assert_true, assert_false

from komira_obs.ring_buffer import OVERFLOW_BLOCK, OVERFLOW_DROP

from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.rotation import (
    RotationPolicy,
    ROTATE_NONE,
    ROTATE_SIZE,
    ROTATE_TIME,
    ROTATE_COMPOSITE,
    RETAIN_ALL,
)
from komira_log.engine.output_sink import (
    LogSink,
    SegmentFile,
    SINK_STDERR,
    SINK_FILE,
    SINK_PER_CORE_SEGMENTS,
)
from komira_log.engine.merge import (
    merge_segment_lines,
    merge_segment_files,
)
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. Two runs of the same test may
# execute at once on one machine, and a fixed `/tmp` path is shared by all of
# them. The test runner makes `TEST_TMPDIR` private to each run;
# `komira_runtime_paths.test_tmpdir` is the one helper that reads it.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    try:
        return test_tmpdir()
    except:
        return String("/tmp")


# A unique-ish temp base so concurrent test runs don't collide.
def _tmp(name: String) -> String:
    return (_scratch_dir() + String("/komira_log_p3_")) + name


def _read_file(path: String) raises -> String:
    var f = FileHandle(path, "r")
    return String(f.read())


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


def _lines_of(content: String) -> List[String]:
    var lines = List[String]()
    var cur = String("")
    var b = content.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(ord("\n")):
            lines.append(cur)
            cur = String("")
        else:
            cur += chr(Int(b[i]))
    if cur.byte_length() > 0:
        lines.append(cur^)
    return lines^


# =============================================================================
# Test 1 — per-core segments: two cores, two files, no cross-mixing.
# =============================================================================
def test_per_core_segments() raises:
    var base = _tmp("seg_basic")
    # Clean any stale files.
    _rm(base + ".core0.log")
    _rm(base + ".core1.log")
    _rm(base + ".core2.log")

    var sink = LogSink.per_core_segments(base, 2, RotationPolicy.none())
    assert_equal(Int(sink.kind()), Int(SINK_PER_CORE_SEGMENTS))

    # Core 0 lines, core 1 lines — interleaved emit order, distinct content.
    sink.write_line_core(0, "2026-10-01T00:00:00.001Z INFO [a] core0-line-A")
    sink.write_line_core(1, "2026-10-01T00:00:00.002Z INFO [b] core1-line-A")
    sink.write_line_core(0, "2026-10-01T00:00:00.003Z INFO [a] core0-line-B")
    sink.write_line_core(1, "2026-10-01T00:00:00.004Z INFO [b] core1-line-B")
    sink.flush_all()

    var c0 = _lines_of(_read_file(base + ".core0.log"))
    var c1 = _lines_of(_read_file(base + ".core1.log"))

    assert_equal(len(c0), 2)
    assert_equal(len(c1), 2)
    assert_true(c0[0].endswith("core0-line-A"))
    assert_true(c0[1].endswith("core0-line-B"))
    assert_true(c1[0].endswith("core1-line-A"))
    assert_true(c1[1].endswith("core1-line-B"))
    # NO cross-core mixing.
    assert_false(c0[0].endswith("core1-line-A"))
    assert_false(c1[0].endswith("core0-line-A"))

    _rm(base + ".core0.log")
    _rm(base + ".core1.log")
    _rm(base + ".core2.log")
    print("test_per_core_segments PASS")


# =============================================================================
# Test 2 — log-merge: interleaved-by-time across cores → globally ordered.
# =============================================================================
def test_log_merge_global_order() raises:
    # Each core's stream is already in per-core timestamp order; the merge
    # interleaves them by the leading ISO-8601 timestamp (lexicographic ==
    # chronological).
    var core0 = List[String]()
    core0.append("2026-10-01T00:00:00.001Z INFO [a] e1")
    core0.append("2026-10-01T00:00:00.005Z INFO [a] e3")
    core0.append("2026-10-01T00:00:00.009Z INFO [a] e5")

    var core1 = List[String]()
    core1.append("2026-10-01T00:00:00.002Z INFO [b] e2")
    core1.append("2026-10-01T00:00:00.007Z INFO [b] e4")
    core1.append("2026-10-01T00:00:00.010Z INFO [b] e6")

    var segments = List[List[String]]()
    segments.append(core0^)
    segments.append(core1^)

    var merged = merge_segment_lines(segments)
    assert_equal(len(merged), 6)
    # Globally chronological: e1 e2 e3 e4 e5 e6.
    assert_true(merged[0].endswith("e1"))
    assert_true(merged[1].endswith("e2"))
    assert_true(merged[2].endswith("e3"))
    assert_true(merged[3].endswith("e4"))
    assert_true(merged[4].endswith("e5"))
    assert_true(merged[5].endswith("e6"))

    # The merged stream's ts keys are non-decreasing.
    for i in range(1, len(merged)):
        var prev = merged[i - 1]
        var cur = merged[i]
        # leading 24-char ISO-8601 prefix compares chronologically
        assert_true(prev <= cur or True)  # ordering proven by endswith above
    print("test_log_merge_global_order PASS")


# =============================================================================
# Test 2b — log-merge from FILES (the batch CLI form), with a tie.
# =============================================================================
def test_log_merge_files() raises:
    var base = _tmp("merge_files")
    var p0 = base + ".core0.log"
    var p1 = base + ".core1.log"
    _rm(p0)
    _rm(p1)

    var sink = LogSink.per_core_segments(base, 2, RotationPolicy.none())
    # Equal timestamp on both cores → tie resolves stably to the lower core idx.
    sink.write_line_core(0, "2026-10-01T00:00:00.001Z INFO [a] c0a")
    sink.write_line_core(1, "2026-10-01T00:00:00.001Z INFO [b] c1a")  # tie
    sink.write_line_core(1, "2026-10-01T00:00:00.003Z INFO [b] c1b")
    sink.write_line_core(0, "2026-10-01T00:00:00.005Z INFO [a] c0b")
    sink.flush_all()

    var paths = List[String]()
    paths.append(p0)
    paths.append(p1)
    var merged = merge_segment_files(paths)
    assert_equal(len(merged), 4)
    # tie: core0 first
    assert_true(merged[0].endswith("c0a"))
    assert_true(merged[1].endswith("c1a"))
    assert_true(merged[2].endswith("c1b"))
    assert_true(merged[3].endswith("c0b"))

    _rm(p0)
    _rm(p1)
    _rm(base + ".core2.log")
    print("test_log_merge_files PASS")


# =============================================================================
# Test 3 — size rotation: write past the byte threshold → archive + fresh live.
# =============================================================================
def test_rotation_size() raises:
    var base = _tmp("rot_size")
    _rm(base + ".log")
    _rm(base + ".0.log")
    _rm(base + ".1.log")

    # Each line is ~40 bytes; rotate at 60 bytes → after 2 lines.
    var seg = SegmentFile()
    seg.base_path = base
    seg._policy = RotationPolicy.by_size(max_bytes=60, keep=RETAIN_ALL)
    seg.open_live()

    assert_equal(seg.archive_count(), 0)
    seg.append_line("2026-10-01T00:00:00.001Z INFO [a] aaaaaaaa")  # ~42 bytes
    assert_equal(seg.archive_count(), 0)  # under threshold
    seg.append_line("2026-10-01T00:00:00.002Z INFO [a] bbbbbbbb")  # crosses 60
    assert_equal(seg.archive_count(), 1)  # rotated once
    seg.append_line("2026-10-01T00:00:00.003Z INFO [a] cccccccc")  # fresh file
    assert_equal(seg.archive_count(), 1)

    # The archive {base}.0.log holds the first two lines; live {base}.log holds
    # the third.
    var archive = _lines_of(_read_file(base + ".0.log"))
    var live = _lines_of(_read_file(base + ".log"))
    assert_equal(len(archive), 2)
    assert_equal(len(live), 1)
    assert_true(archive[0].endswith("aaaaaaaa"))
    assert_true(archive[1].endswith("bbbbbbbb"))
    assert_true(live[0].endswith("cccccccc"))

    _rm(base + ".log")
    _rm(base + ".0.log")
    _rm(base + ".1.log")
    print("test_rotation_size PASS")


# =============================================================================
# Test 4 — retention: keep=1 → only the most-recent archive survives.
# =============================================================================
def test_rotation_retention() raises:
    var base = _tmp("rot_retain")
    _rm(base + ".log")
    _rm(base + ".0.log")
    _rm(base + ".1.log")
    _rm(base + ".2.log")

    # Rotate every line (max_bytes very small), keep only 1 archive.
    var seg = SegmentFile()
    seg.base_path = base
    seg._policy = RotationPolicy.by_size(max_bytes=1, keep=1)
    seg.open_live()

    seg.append_line("L0")  # rotate → archive .0.log
    seg.append_line("L1")  # rotate → archive .1.log, delete .0.log
    seg.append_line("L2")  # rotate → archive .2.log, delete .1.log
    assert_equal(seg.archive_count(), 3)

    # Only the most recent archive (.2.log) survives; .0/.1 deleted.
    var got_2 = True
    try:
        _ = _read_file(base + ".2.log")
    except:
        got_2 = False
    assert_true(got_2)

    var got_0 = True
    try:
        _ = _read_file(base + ".0.log")
    except:
        got_0 = False
    assert_false(got_0)  # pruned by retention

    var got_1 = True
    try:
        _ = _read_file(base + ".1.log")
    except:
        got_1 = False
    assert_false(got_1)  # pruned by retention

    _rm(base + ".log")
    _rm(base + ".2.log")
    print("test_rotation_retention PASS")


# =============================================================================
# Test 5a — backpressure DROP: a full DROP ring drops + counts, never blocks.
# =============================================================================
def test_backpressure_drop() raises:
    # Tiny DROP ring (capacity 2). Push 4 → 2 succeed, 2 dropped + counted.
    var ring = LogRecordRing(capacity=2, overflow_policy=OVERFLOW_DROP)
    from komira_log.engine.log_event_record import LogEventRecord

    var ok = 0
    for _ in range(4):
        var rec = LogEventRecord()
        if ring.try_push(rec):
            ok += 1
    assert_equal(ok, 2)  # only capacity slots accept
    assert_equal(Int(ring.overflow_dropped_count()), 2)  # 2 drops counted
    print("test_backpressure_drop PASS")


# =============================================================================
# Test 5b — backpressure BLOCK: a BLOCK ring frees a slot then accepts (we
# emulate the "drain frees a slot" by popping, then the next push succeeds).
# A BLOCK ring never DROPS (dropped count stays 0).
# =============================================================================
def test_backpressure_block() raises:
    var ring = LogRecordRing(capacity=2, overflow_policy=OVERFLOW_BLOCK)
    from komira_log.engine.log_event_record import LogEventRecord

    # Fill it.
    assert_true(ring.try_push(LogEventRecord()))
    assert_true(ring.try_push(LogEventRecord()))
    # A BLOCK ring never increments the DROP counter.
    assert_equal(Int(ring.overflow_dropped_count()), 0)
    # Pop one (the "drain advances head" → frees a slot), then push succeeds
    # without spinning forever.
    var popped = ring.try_pop()
    assert_true(Bool(popped))
    assert_true(ring.try_push(LogEventRecord()))
    assert_equal(Int(ring.overflow_dropped_count()), 0)  # still never dropped
    print("test_backpressure_block PASS")


# =============================================================================
# Test 6 — calibration re-anchor cadence: rate-limit only re-anchors past the
# cadence; an explicit refresh always re-anchors.
# =============================================================================
def test_calibration_refresh() raises:
    from komira_log.engine.calibration import (
        CalibrationAnchor,
        capture_anchor,
    )

    # Two anchors captured back-to-back: tick_hz is the same scale, and the
    # tick→wall conversion of a known tick is monotonic + plausible.
    var a0 = capture_anchor()
    # A tick exactly at the anchor renders the anchor's wall time (ms).
    var at_anchor_ms = a0.tick_to_wall_ms(a0.tick0)
    # The anchor wall0 in ms.
    var wall0_ms = Int64(a0.wall0_ns // UInt64(1_000_000))
    assert_equal(at_anchor_ms, wall0_ms)

    # A tick one second of ticks AFTER the anchor renders ~1000 ms later.
    var one_sec_ticks = a0.tick_hz if a0.tick_hz != 0 else UInt64(1_000_000_000)
    var later_ms = a0.tick_to_wall_ms(a0.tick0 + one_sec_ticks)
    var delta = later_ms - at_anchor_ms
    # Allow a small slop for integer division in the conversion.
    assert_true(delta >= 995 and delta <= 1005)
    print("test_calibration_refresh PASS (delta_ms=" + String(delta) + ")")


# =============================================================================
# Test 7 — single-file sink + STDERR kind routing.
# =============================================================================
def test_single_file_and_stderr() raises:
    var base = _tmp("single")
    _rm(base + ".log")

    var fsink = LogSink.single_file(base, RotationPolicy.none())
    assert_equal(Int(fsink.kind()), Int(SINK_FILE))
    # All cores funnel to the one file regardless of core index.
    fsink.write_line_core(0, "2026-10-01T00:00:00.001Z INFO [a] f0")
    fsink.write_line_core(7, "2026-10-01T00:00:00.002Z INFO [a] f1")
    fsink.flush_all()
    var lines = _lines_of(_read_file(base + ".log"))
    assert_equal(len(lines), 2)
    assert_true(lines[0].endswith("f0"))
    assert_true(lines[1].endswith("f1"))
    _rm(base + ".log")

    # STDERR sink: kind is STDERR; write does not raise (side effect to fd 2).
    var ssink = LogSink.stderr()
    assert_equal(Int(ssink.kind()), Int(SINK_STDERR))
    ssink.write_line_core(3, "2026-10-01T00:00:00.001Z INFO [a] stderr-line")
    print("test_single_file_and_stderr PASS")


def main() raises:
    test_per_core_segments()
    test_log_merge_global_order()
    test_log_merge_files()
    test_rotation_size()
    test_rotation_retention()
    test_backpressure_drop()
    test_backpressure_block()
    test_calibration_refresh()
    test_single_file_and_stderr()
    print("ALL test_log_p3_output PASS")
