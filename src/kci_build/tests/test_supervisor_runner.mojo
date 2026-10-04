# =============================================================================
# src/kci_build/tests/test_supervisor_runner.mojo
#   SupervisorRunner over real /bin/sh processes: both streams reach their
#   files byte for byte, the exit status comes back, the cwd is applied, and a
#   run past its timeout is stopped and reported as timed out.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.pathlib import Path
from std.time import perf_counter_ns

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import RunSpec, SupervisorRunner


def _dir(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/ksr_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d


def _sh(d: String, script: String, timeout_s: Int = 30) -> RunSpec:
    var argv = List[String]()
    argv.append(String("-c"))
    argv.append(script)
    return RunSpec(
        String("/bin/sh"), argv^, d.copy(), timeout_s, d + String("/out.txt"), d + String("/err.txt")
    )


def test_streams_exit_code_and_cwd() raises:
    var d = _dir(String("basic"))
    var runner = SupervisorRunner()
    var spec = _sh(d, String("printf 'to out\\n'; echo here > cwd_marker.txt; printf 'to err' >&2; exit 3"))
    var r = runner.run(spec)
    assert_equal(Int(r.exit_code), 3)
    assert_false(r.signaled)
    assert_false(r.timed_out)
    assert_false(r.ok())
    assert_equal(r.describe(), String("exit 3"))
    assert_equal(Path(spec.stdout_path).read_text(), String("to out\n"))
    assert_equal(Path(d + String("/cwd_marker.txt")).read_text(), String("here\n"))
    assert_equal(Path(spec.stderr_path).read_text(), String("to err"))
    assert_equal(r.stderr_tail, String("to err"))


def test_a_large_stderr_keeps_only_its_tail() raises:
    var d = _dir(String("large"))
    var runner = SupervisorRunner()
    # ~75 KiB on each stream: more than a 64 KiB pipe buffer, so both must be drained.
    var line = String("a line of ninety-odd bytes, repeated until both pipes overflow their buffers.......")
    var spec = _sh(
        d,
        String("i=0; while [ $i -lt 800 ]; do echo '")
        + line
        + String("'; echo '")
        + line
        + String("' >&2; i=$((i+1)); done; echo LAST >&2"),
    )
    var r = runner.run(spec)
    assert_true(r.ok())
    assert_equal(len(Path(spec.stdout_path).read_bytes()), 800 * (line.byte_length() + 1))
    assert_equal(len(Path(spec.stderr_path).read_bytes()), 800 * (line.byte_length() + 1) + 5)
    assert_true(r.stderr_tail.byte_length() <= 4096)
    assert_true(r.stderr_tail.endswith(String("LAST\n")))


def test_a_run_past_its_timeout_is_stopped() raises:
    var d = _dir(String("timeout"))
    var runner = SupervisorRunner(grace_ms=200)
    var t0 = perf_counter_ns()
    var r = runner.run(_sh(d, String("echo started; sleep 30"), timeout_s=1))
    var waited_ms = Int((perf_counter_ns() - t0) // 1_000_000)
    assert_true(r.timed_out)
    assert_false(r.ok())
    assert_equal(r.describe(), String("timed out"))
    assert_true(waited_ms < 10000)


def test_a_missing_binary_raises() raises:
    var d = _dir(String("missing"))
    var runner = SupervisorRunner()
    var spec = RunSpec(
        String("/nonexistent/buck2"), List[String](), d.copy(), 5, d + String("/o"), d + String("/e")
    )
    var raised = False
    try:
        _ = runner.run(spec)
    except e:
        raised = String(e).startswith(String("cannot start '/nonexistent/buck2'"))
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
