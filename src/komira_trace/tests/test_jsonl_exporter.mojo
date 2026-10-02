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

from komira_trace.tracer import Tracer
from komira_trace.exporter import (
    JsonlFileExporter,
    json_escape,
    trace_id_hex_128,
    format_span_json_line,
)
from komira_trace.span_record import SpanRecord
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
    return (test_tmpdir() + String("/komira_trace_test_")) + suffix + String(".jsonl")


def _read_lines(path: String) raises -> List[String]:
    """Read the JSONL file back. Returns the line list (newline-stripped)."""
    from std.io import FileHandle
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)  # SEEK_END
    var size = Int(f.seek(0, 1))
    _ = f.seek(0, 0)
    var raw = f.read_bytes(size)
    f.close()

    # Lines are rebuilt from the bytes read, copied verbatim, so a non-ASCII
    # name compares byte for byte (re-encoding each byte with `chr` would not).
    var lines = List[String]()
    var current = List[UInt8]()
    for i in range(len(raw)):
        var c = raw[i]
        if c == UInt8(10):  # '\n'
            lines.append(String(unsafe_from_utf8=Span(current)))
            current = List[UInt8]()
        else:
            current.append(c)
    if len(current) > 0:
        lines.append(String(unsafe_from_utf8=Span(current)))
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


def test_json_escape_passes_non_ascii_bytes_through() raises:
    """Bytes at or above 0x80 are copied untouched; only quote, backslash and
    control bytes are escaped."""
    var name = String("span-é中\"x\\y\n")
    var expected = String("span-é中\\\"x\\\\y\\n")
    var got = json_escape(name)
    assert_equal(got, expected)
    assert_equal(got.byte_length(), expected.byte_length())


def test_json_escape_control_bytes() raises:
    """Every byte below 0x20 is escaped: the short forms for \\n \\r \\t \\b
    \\f, `\\u00XX` for the rest. A raw control byte is invalid JSON."""
    var s = String("")
    for v in range(0, 32):
        var one = List[UInt8]()
        one.append(UInt8(v))
        s += String(unsafe_from_utf8=Span(one))
    var got = json_escape(s)
    var expected = String(
        "\\u0000\\u0001\\u0002\\u0003\\u0004\\u0005\\u0006\\u0007"
        "\\b\\t\\n\\u000b\\f\\r\\u000e\\u000f"
        "\\u0010\\u0011\\u0012\\u0013\\u0014\\u0015\\u0016\\u0017"
        "\\u0018\\u0019\\u001a\\u001b\\u001c\\u001d\\u001e\\u001f"
    )
    assert_equal(got, expected)
    print("  test_json_escape_control_bytes PASS")


def test_shared_span_line_formatter() raises:
    """The one formatter other packages call: key order and number rendering."""
    var hex = trace_id_hex_128(
        UInt64(0x0102030405060708), UInt64(0x090A0B0C0D0E0F10)
    )
    assert_equal(hex, String("0102030405060708090a0b0c0d0e0f10"))
    var line = format_span_json_line(hex, 7, 3, String("a.b"), 100, 250, 2, 1)
    assert_equal(
        line,
        String(
            "{\"trace_id\":\"0102030405060708090a0b0c0d0e0f10\",\"span_id\":7,"
            "\"parent_id\":3,\"name\":\"a.b\",\"start_ns\":100,\"end_ns\":250,"
            "\"worker_id\":2,\"flags\":1}"
        ),
    )


def test_non_ascii_span_name_round_trips_through_the_file() raises:
    """A non-ASCII span name is written byte for byte, both in the name
    registry meta line and in the span line. Re-encoding any byte (in the
    registry lookup, the registry flush, or the escape) turns it into
    mojibake and fails this."""
    var path = _make_tmp_path("non_ascii")
    var tracer = Tracer(num_workers=1, ring_capacity=64)
    tracer.install_mock_ids(trace_seed=UInt64(1), span_seed=UInt64(1))

    var s = tracer.start_span["span-é中"](worker_id=0)
    tracer.end_span(s, worker_id=0)

    var exporter = JsonlFileExporter(path)
    tracer.drain_into_jsonl(exporter)
    exporter.shutdown()

    var lines = _read_lines(path)
    var needle = String("\"name\":\"span-é中\"")
    var with_name = 0
    var meta_with_name = 0
    for li in range(len(lines)):
        if needle in lines[li]:
            with_name += 1
            if String("\"meta\":\"name\"") in lines[li]:
                meta_with_name += 1
    assert_equal(with_name, 2, "meta line and span line both carry the name")
    assert_equal(meta_with_name, 1, "exactly one of them is the meta line")
    print("  test_non_ascii_span_name_round_trips_through_the_file PASS")


def main() raises:
    print("test_jsonl_exporter")
    print("===================")
    test_drain_into_jsonl_writes_file()
    test_jsonl_first_char_is_brace()
    test_jsonl_contains_registered_name()
    test_json_escape_passes_non_ascii_bytes_through()
    test_json_escape_control_bytes()
    test_shared_span_line_formatter()
    test_non_ascii_span_name_round_trips_through_the_file()
    print()
    print("ALL TESTS PASS")
