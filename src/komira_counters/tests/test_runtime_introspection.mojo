# =============================================================================
# komira_counters/tests/test_runtime_introspection.mojo -- the ON-mode hooks
# =============================================================================
#
# The library's BUCK sets `test_defines` to all three `KOMIRA_TRACE_*` gates,
# so in this test every hook is compiled in its ON form. (No other test of the
# package reads those defines.) Each test captures fd 1 into a file under
# $TEST_TMPDIR, calls the hooks, restores fd 1 and checks the emitted lines
# byte for byte.
#
# What is pinned:
#   * each hook's line format: prefix, key names, `=` and separators, and the
#     value it carries (bytes, label, task_type, op, type);
#   * `site=` is the CALLER's file and line: the test takes its own location
#     (`_here()`) on the line before each first call and requires the hook to
#     report exactly the next line of the same file, so a location off by a
#     constant fails; two calls on consecutive lines report consecutive lines;
#   * one line per call, in call order.
# =============================================================================

from std.ffi import external_call
from std.reflection import call_location
from std.testing import TestSuite, assert_equal, assert_true

from komira_counters.runtime_introspection import (
    TRACE_ARC,
    TRACE_TCMALLOC,
    TRACE_TRAMPOLINE,
    trace_alloc,
    trace_arc_dec,
    trace_arc_inc,
    trace_trampoline,
)
from komira_runtime_paths import test_tmpdir


def _capture_path(name: String) raises -> String:
    var pid = external_call["getpid", Int32]()
    return (
        test_tmpdir()
        + String("/komira_counters_trace_")
        + name
        + String(".")
        + String(Int(pid))
        + String(".log")
    )


def _begin_capture(path: String) raises -> Int32:
    """Points fd 1 at a fresh file `path`; returns the saved fd 1."""
    var saved = external_call["dup", Int32](Int32(1))
    if saved < Int32(0):
        raise Error("dup(1) failed")
    var p = path
    # SAFETY: the NUL-terminated view is owned by `p`, held alive across the
    # call; the kernel copies the path and the pointer does not escape.
    # `creat` is open(O_WRONLY|O_CREAT|O_TRUNC) under a symbol the stdlib's
    # `open` does not also declare.
    var fd = external_call["creat", Int32](
        p.as_c_string_slice().unsafe_ptr(), Int32(0o644)
    )
    if fd < Int32(0):
        raise Error("creat(capture) failed")
    _ = external_call["dup2", Int32](fd, Int32(1))
    _ = external_call["close", Int32](fd)
    return saved


def _end_capture(saved: Int32, path: String) raises -> List[String]:
    """Restores fd 1 and returns the captured lines (no trailing empty line)."""
    _ = external_call["dup2", Int32](saved, Int32(1))
    _ = external_call["close", Int32](saved)
    var text: String
    with open(path, "r") as f:
        text = f.read()
    var out = List[String]()
    for piece in text.split("\n"):
        out.append(String(piece))
    if len(out) > 0 and out[len(out) - 1] == "":
        _ = out.pop()
    return out^


def _site_of(line: String, key: String) raises -> Tuple[String, Int]:
    """The `<file>:<line>` after ` site=` (or a leading `site=`), as a pair."""
    var at = line.find(key)
    assert_true(at >= 0, String("no ") + key + String(" in: ") + line)
    var rest = String(line[byte=at + key.byte_length() :])
    var sp = rest.find(" ")
    var site = String(rest[byte=:sp]) if sp >= 0 else rest
    var colon = site.rfind(":")
    assert_true(colon > 0, String("no file:line in: ") + site)
    return (String(site[byte=:colon]), Int(String(site[byte=colon + 1 :])))


@always_inline("nodebug")
def _here() -> Tuple[String, Int]:
    """The file and line of the line that calls `_here()`.

    `call_location()` in an inlined function resolves to its caller, the same
    mechanism the hooks use, but computed here in the test, independently of
    the hook under test.
    """
    var loc = call_location()
    return (String(loc.file_name()), loc.line())


def test_gates_are_on_in_this_build() raises:
    # The defines reach this test; were they missing, every check below would
    # read an empty capture and fail, but this says why.
    assert_true(TRACE_TCMALLOC)
    assert_true(TRACE_TRAMPOLINE)
    assert_true(TRACE_ARC)


def test_trace_alloc_names_the_caller_site_and_bytes() raises:
    var path = _capture_path("alloc")
    var saved = _begin_capture(path)
    var here = _here()
    trace_alloc(4096)
    trace_alloc(0)
    var lines = _end_capture(saved, path)
    assert_equal(len(lines), 2)
    var a = _site_of(lines[0], "site=")
    var b = _site_of(lines[1], "site=")
    assert_true(
        a[0].endswith("test_runtime_introspection.mojo"),
        String("site file is not the caller's: ") + a[0],
    )
    assert_equal(b[0], a[0])
    # The absolute line: the first call sits on the line after `_here()`.
    assert_equal(a[0], here[0])
    assert_equal(a[1], here[1] + 1)
    # Consecutive call lines: the location is the call's, not the hook's.
    assert_equal(b[1], a[1] + 1)
    var site_a = a[0] + String(":") + String(a[1])
    var site_b = b[0] + String(":") + String(b[1])
    assert_equal(lines[0], String("[TRACE_TCMALLOC] site=") + site_a + String(" bytes=4096"))
    assert_equal(lines[1], String("[TRACE_TCMALLOC] site=") + site_b + String(" bytes=0"))


def test_labeled_trace_alloc_puts_the_label_first() raises:
    var path = _capture_path("alloc_labeled")
    var saved = _begin_capture(path)
    var here = _here()
    trace_alloc["arrow_ipc.driver_enter"](123)
    trace_alloc["x"](7)
    var lines = _end_capture(saved, path)
    assert_equal(len(lines), 2)
    var a = _site_of(lines[0], " site=")
    var b = _site_of(lines[1], " site=")
    assert_true(
        a[0].endswith("test_runtime_introspection.mojo"),
        String("site file is not the caller's: ") + a[0],
    )
    # The absolute line: the first call sits on the line after `_here()`.
    assert_equal(a[0], here[0])
    assert_equal(a[1], here[1] + 1)
    # Consecutive call lines: the location is the call's, not the hook's.
    assert_equal(b[1], a[1] + 1)
    var site_a = a[0] + String(":") + String(a[1])
    var site_b = b[0] + String(":") + String(b[1])
    assert_equal(
        lines[0],
        String("[TRACE_TCMALLOC] label=arrow_ipc.driver_enter site=")
        + site_a
        + String(" bytes=123"),
    )
    assert_equal(
        lines[1],
        String("[TRACE_TCMALLOC] label=x site=") + site_b + String(" bytes=7"),
    )


def test_trace_trampoline_names_the_caller_site_and_task_type() raises:
    var path = _capture_path("trampoline")
    var saved = _begin_capture(path)
    var here = _here()
    trace_trampoline["_state_trampoline_for"]()
    trace_trampoline["_task_trampoline"]()
    var lines = _end_capture(saved, path)
    assert_equal(len(lines), 2)
    var a = _site_of(lines[0], "site=")
    var b = _site_of(lines[1], "site=")
    assert_true(
        a[0].endswith("test_runtime_introspection.mojo"),
        String("site file is not the caller's: ") + a[0],
    )
    # The absolute line: the first call sits on the line after `_here()`.
    assert_equal(a[0], here[0])
    assert_equal(a[1], here[1] + 1)
    # Consecutive call lines: the location is the call's, not the hook's.
    assert_equal(b[1], a[1] + 1)
    var site_a = a[0] + String(":") + String(a[1])
    var site_b = b[0] + String(":") + String(b[1])
    assert_equal(
        lines[0],
        String("[TRACE_TRAMPOLINE] site=")
        + site_a
        + String(" task_type=_state_trampoline_for"),
    )
    assert_equal(
        lines[1],
        String("[TRACE_TRAMPOLINE] site=")
        + site_b
        + String(" task_type=_task_trampoline"),
    )


def test_trace_arc_inc_and_dec_lines() raises:
    var path = _capture_path("arc")
    var saved = _begin_capture(path)
    trace_arc_inc["AggLayout"]()
    trace_arc_dec["AggLayout"]()
    trace_arc_dec["_VyukovMpmcQueue"]()
    trace_arc_inc["_VyukovMpmcQueue"]()
    var lines = _end_capture(saved, path)
    assert_equal(len(lines), 4)
    assert_equal(lines[0], "[TRACE_ARC] op=inc type=AggLayout")
    assert_equal(lines[1], "[TRACE_ARC] op=dec type=AggLayout")
    assert_equal(lines[2], "[TRACE_ARC] op=dec type=_VyukovMpmcQueue")
    # A second type for `inc` too, so a hook printing a fixed name fails.
    assert_equal(lines[3], "[TRACE_ARC] op=inc type=_VyukovMpmcQueue")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
