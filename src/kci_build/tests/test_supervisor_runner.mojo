# =============================================================================
# src/kci_build/tests/test_supervisor_runner.mojo
#   SupervisorRunner over real /bin/sh processes: both streams reach their
#   files byte for byte, every exit status comes back as itself (each bit of
#   the 0..255 range, so a decode that drops or clamps bits fails), the cwd
#   is applied, a run past its timeout is stopped and reported as timed out,
#   its timeout is read against an injectable clock (a moved clock stops
#   it, a frozen one never does), its `now_ns` is the monotonic clock, and an
#   explicit environment is exactly what the child sees (None
#   inherits).
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.pathlib import Path
from std.time import perf_counter_ns

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import RunClock, RunSpec, SupervisorRunner


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


def test_every_exit_status_comes_back_as_itself() raises:
    # kci's own exit numbers (2, 3, 4, ...) travel through here: a status
    # decoded to fewer bits, clamped or collapsed to 1 would misreport them.
    # 1, 2, 4, ..., 128 set each bit alone; 255 sets all eight.
    var d = _dir(String("statuses"))
    var runner = SupervisorRunner()
    for code in [1, 2, 4, 8, 16, 32, 64, 128, 255]:
        var r = runner.run(_sh(d, String("exit ") + String(code)))
        assert_equal(Int(r.exit_code), code, String("exit ") + String(code) + String(" came back as ") + r.describe())
        assert_false(r.signaled, String("exit ") + String(code))
        assert_false(r.timed_out, String("exit ") + String(code))
        assert_false(r.ok(), String("exit ") + String(code))


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


def _env_spec(d: String) -> RunSpec:
    return RunSpec(
        String("/usr/bin/env"), List[String](), d.copy(), 30, d + String("/out.txt"), d + String("/err.txt")
    )


def test_an_explicit_env_is_all_the_child_sees() raises:
    var d = _dir(String("env"))
    var runner = SupervisorRunner()
    var spec = _env_spec(d)
    var entries = List[String]()
    entries.append(String("PATH=/x"))
    entries.append(String("KCI_PROBE=1"))
    spec.set_env(entries^)
    var r = runner.run(spec)
    assert_true(r.ok(), r.describe())
    # `env` prints its environment: exactly the two entries, nothing inherited
    assert_equal(Path(spec.stdout_path).read_text(), String("PATH=/x\nKCI_PROBE=1\n"))


def test_no_env_inherits() raises:
    var d = _dir(String("inherit"))
    var runner = SupervisorRunner()
    var spec = _env_spec(d)
    var r = runner.run(spec)
    assert_true(r.ok(), r.describe())
    var out = Path(spec.stdout_path).read_text()
    # this test's own TMPDIR or TEST_TMPDIR reached the child
    var name = String("TEST_TMPDIR=")
    if getenv("TEST_TMPDIR").byte_length() == 0:
        name = String("TMPDIR=")
    assert_true(out.find(name) >= 0, out)
    assert_true(out.find(String("KCI_PROBE=")) < 0)


struct _StepClock(RunClock, Movable):
    """A clock the test moves: each reading returns the current time, then
    moves it on by `step_ns`. `last` is the latest reading handed out."""

    var at_ns: Int
    var step_ns: Int
    var last: Int

    def __init__(out self, step_ns: Int):
        self.at_ns = 0
        self.step_ns = step_ns
        self.last = 0

    def now_ns(mut self) -> Int:
        self.last = self.at_ns
        self.at_ns += self.step_ns
        return self.last


def test_a_run_past_its_timeout_is_stopped() raises:
    # The child sleeps far longer than the test could wait; the clock, not
    # the wall, carries the run past its 1 s timeout: 0.6 s per reading puts
    # the deadline at 1.0 s and the second reading after it at 1.8 s.
    var d = _dir(String("timeout"))
    var runner = SupervisorRunner(grace_ms=200)
    var clock = _StepClock(600_000_000)
    var r = runner.run_on(_sh(d, String("echo started; sleep 30"), timeout_s=1), clock)
    assert_true(r.timed_out)
    assert_false(r.ok())
    assert_equal(r.describe(), String("timed out"))
    # it was stopped on a reading past the deadline, never on one before it
    assert_true(clock.last > 1_000_000_000, String(clock.last))


def test_a_clock_that_stays_before_the_deadline_never_stops_the_child() raises:
    var d = _dir(String("frozen"))
    var runner = SupervisorRunner()
    var clock = _StepClock(0)
    var r = runner.run_on(_sh(d, String("echo done"), timeout_s=1), clock)
    assert_true(r.ok(), r.describe())
    assert_false(r.timed_out)
    assert_equal(clock.last, 0)


def test_its_clock_is_the_monotonic_clock() raises:
    # now_ns is what the per-change check's budget is read against: it is
    # perf_counter_ns (CLOCK_MONOTONIC). Two readings of the same clock come
    # in order, and both lie between two readings of perf_counter_ns around
    # them (the wall clock, a different origin, would not). Nothing here
    # measures how long anything took.
    var d = _dir(String("clock"))
    var runner = SupervisorRunner()
    var t0 = Int(perf_counter_ns())
    var before = runner.now_ns()
    var r = runner.run(_sh(d, String("true")))
    var after = runner.now_ns()
    var t1 = Int(perf_counter_ns())
    assert_true(r.ok())
    assert_true(t0 <= before and before <= after and after <= t1, String(t0) + String(" ") + String(before) + String(" ") + String(after) + String(" ") + String(t1))


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
