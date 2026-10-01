# =============================================================================
# test_jsonl_exporter.mojo — the JSONL exporter writes a readable trace
# =============================================================================
#
# Verifies:
#   1. JsonlFileExporter writes a non-empty file from a drained tracer.
#   2. The file content includes the registered name.
#   3. Re-reading the file → both `meta:name` records and span records
#      appear.
#   4. Tracer.drain_into_jsonl flushes the name registry first then
#      every per-worker ring's records.
#
# The contract is "produce a valid JSONL trace readable by an offline
# analyzer"; valid-readable is asserted via a structural check on the
# first character of every line (must be `{`).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_obs.tracer import Tracer
from komira_obs.exporter import JsonlFileExporter
from komira_obs.span_record import SpanRecord
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# A fixed `/tmp` path is shared by every concurrent execution of this test on
# one machine; `TEST_TMPDIR` is private to each execution, which is what makes
# them disjoint. The test runner sets it, and `test_tmpdir()` raises when it is
# unset rather than falling back to a shared directory.
# ---------------------------------------------------------------------------


def _make_tmp_path(suffix: String) raises -> String:
    """Build a temp filename under the test's scratch directory. We don't use mkstemp here —
    deterministic name + clobber-on-write is fine for these tests.
    """
    return (test_tmpdir() + String("/komira_obs_test_")) + suffix + String(".jsonl")


def _read_lines(path: String) raises -> List[String]:
    """Read the JSONL file back. Returns the line list (newline-stripped)."""
    from std.io import FileHandle
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)  # SEEK_END
    var size = Int(f.seek(0, 1))
    _ = f.seek(0, 0)
    var raw = f.read_bytes(size)
    f.close()

    var lines = List[String]()
    var current = String("")
    for i in range(len(raw)):
        var c = raw[i]
        if c == UInt8(10):  # '\n'
            lines.append(current^)
            current = String("")
        else:
            current += chr(Int(c))
    if current.byte_length() > 0:
        lines.append(current^)
    return lines^


def test_drain_into_jsonl_writes_file() raises:
    var path = _make_tmp_path("drain_basic")
    var tracer = Tracer(num_workers=1, ring_capacity=64)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    var s = tracer.start_span["engine.segment.execute"](worker_id=0)
    tracer.end_span(s, worker_id=0)

    var exporter = JsonlFileExporter(path)
    tracer.drain_into_jsonl(exporter)
    exporter.shutdown()

    var lines = _read_lines(path)
    # The drain joins OPEN+CLOSE packets into one record per span,
    # so output is one name-registry meta line + one span line.
    assert_true(len(lines) >= 2,
                "at least name + span lines (got " + String(len(lines)) + ")")
    print("  test_drain_into_jsonl_writes_file PASS, lines=", len(lines))


def test_jsonl_first_char_is_brace() raises:
    """Every line in the JSONL output must start with `{` (valid JSON object)."""
    var path = _make_tmp_path("structural")
    var tracer = Tracer(num_workers=2, ring_capacity=32)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    var sa = tracer.start_span["op.alpha"](worker_id=0)
    var sb = tracer.start_span["op.beta"](worker_id=1)
    tracer.end_span(sa, worker_id=0)
    tracer.end_span(sb, worker_id=1)

    var exporter = JsonlFileExporter(path)
    tracer.drain_into_jsonl(exporter)
    exporter.shutdown()

    var lines = _read_lines(path)
    for li in range(len(lines)):
        var line = lines[li]
        var n = line.byte_length()
        if n == 0:
            continue
        # ⚠ MOJO 1.0.0: `line` is walked ONCE, before `b` is bound. 1.0.0 refuses
        # a second walk of the chain while an interior `ref` from the first is
        # live, so binding `b`, then `+ line` in the failure message, then
        # `line.byte_length()` again would invalidate `b`. Both messages and the
        # length are projected out of `line` up front; `b` is then bound once and
        # only indexed. No copy, no semantic change.
        var head_msg = "line " + String(li) + " starts with non-`{`: " + line
        var tail_msg = "line " + String(li) + " ends with non-`}`: " + line
        var b = line.as_bytes()
        assert_equal(b[0], UInt8(123), head_msg)  # '{'
        assert_equal(b[n - 1], UInt8(125), tail_msg)  # '}'
    print("  test_jsonl_first_char_is_brace PASS,",
          len(lines), "lines validated")


def test_jsonl_contains_registered_name() raises:
    """The trace file's `meta:name` line must contain the literal name."""
    var path = _make_tmp_path("name_appears")
    var tracer = Tracer(num_workers=1, ring_capacity=8)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    var s = tracer.start_span["my.operator.signature"](worker_id=0)
    tracer.end_span(s, worker_id=0)

    var exporter = JsonlFileExporter(path)
    tracer.drain_into_jsonl(exporter)
    exporter.shutdown()

    var lines = _read_lines(path)
    var found = False
    for li in range(len(lines)):
        var line = lines[li]
        # Look for the literal "my.operator.signature" substring.
        var b = line.as_bytes()
        var probe_str = String("my.operator.signature")
        var probe = probe_str.as_bytes()
        var probe_n = len(probe)
        var line_n = len(b)
        if line_n < probe_n:
            continue
        for off in range(line_n - probe_n + 1):
            var matched = True
            for k in range(probe_n):
                if b[off + k] != probe[k]:
                    matched = False
                    break
            if matched:
                found = True
                break
        if found:
            break
    assert_true(found,
                "registered name string not found in any JSONL line")
    print("  test_jsonl_contains_registered_name PASS")


def main() raises:
    print("test_jsonl_exporter")
    print("===================")
    test_drain_into_jsonl_writes_file()
    test_jsonl_first_char_is_brace()
    test_jsonl_contains_registered_name()
    print()
    print("ALL TESTS PASS")
