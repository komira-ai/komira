# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_run_loop.mojo
#   The run loop between two beats: a job's exit and a stop signal are noticed
#   between beats, not at the next beat.
# =============================================================================
#
# Both tests run the loop on a manual clock (`ManualLoopClock`): the loop's
# one-second waits move the clock by one second each and take no time, and the
# tests count what the loop did. What the real child does is gated on an event
# the test controls, never on time.
#
#   test_a_job_that_ends_between_beats_is_noticed_within_seconds
#       With a 3600 s heartbeat interval, a job that waits for a file the
#       reporter creates with the second RUNNING beat (the first after the
#       spawn) and then exits ends the run COMPLETED, after two RUNNING beats.
#       Every wait the loop made is one second: it checks for the exit every
#       second between beats, where a loop that checked every 10 s would wait
#       10000 ms once, and one that checked only at the next beat 3600000 ms.
#       The COMPLETED beat comes less than the interval after that beat on the
#       manual clock, and the clock moved by exactly the waits made.
#   test_a_stop_signal_between_beats_stops_the_job_before_its_next_wait
#       With a 120 s interval, the job prints "signalling", creates a file
#       and waits to be killed. The clock's first wait, which comes after the
#       second RUNNING beat, waits for that file (the job's line is then in
#       the pipe) and sends SIGTERM to the supervisor, as a platform stopping
#       its container does. The run ends CANCELLED, naming SIGTERM, after two
#       RUNNING beats; its logs.txt holds "signalling" and nothing else; the
#       loop made no wait after the signal (it took the stop in the same
#       pass: a loop that took the stop only every few waits, or only at the
#       next beat, makes at least one), and the clock moved by exactly the
#       one second waited. CANCELLED proves the stop came before the job's
#       own end, and no signal is left latched afterwards, so the stop took
#       this one.
#
# No heartbeat endpoint: the reporter records each beat. The stop test
# reads logs.txt from an in-memory log store; the other has no store.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env
from komira_objectstore import (
    InMemoryConditionalStore,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_supervisor.pid1 import take_stop_signal
from komira_supervisor.proc_ffi import SIGTERM, proc_kill

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisorConfig,
    JobSupervisorPhase,
    LoopClock,
    ManualLoopClock,
    SupervisorHeartbeat,
    run_job_supervisor_with_clock,
)


comptime _CLOCK_START_NS: Int = 7_000_000_000
"""Where the manual clock stands when a run starts."""
comptime _SEC_NS: Int = 1_000_000_000


def _yield():
    """Give the thread up for a millisecond; nothing depends on how long."""
    _ = external_call["usleep", Int32](UInt32(1000))


struct Recorder(HeartbeatReporter):
    var beats: ArcPointer[List[String]]

    def __init__(out self, beats: ArcPointer[List[String]]):
        self.beats = beats

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        return HeartbeatOutcome(True, False, 200)


struct ReleasingRecorder(HeartbeatReporter):
    """A Recorder that keeps each beat's time on the manual clock and creates
    `release` with the beat after the spawn (the second one)."""

    var beats: ArcPointer[List[String]]
    var at_ns: ArcPointer[List[Int]]
    var clock: ArcPointer[Int]
    var release: String

    def __init__(
        out self,
        beats: ArcPointer[List[String]],
        at_ns: ArcPointer[List[Int]],
        clock: ArcPointer[Int],
        release: String,
    ):
        self.beats = beats
        self.at_ns = at_ns
        self.clock = clock
        self.release = release

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        self.at_ns[].append(self.clock[])
        if len(self.beats[]) == 2:
            try:
                with open(self.release, "w") as f:
                    f.write("go")
            except:
                self.beats[].append(String("RELEASE-FAILED|"))
        return HeartbeatOutcome(True, False, 200)


struct StopWhenReadyClock(LoopClock):
    """A manual clock whose first wait sends SIGTERM to this process once
    `ready` exists, as a platform stopping a container does, and that counts
    the waits made after that."""

    var cell: ArcPointer[Int]
    var ready: String
    var signalled: Bool
    var waits_after_signal: Int

    def __init__(out self, cell: ArcPointer[Int], ready: String):
        self.cell = cell
        self.ready = ready
        self.signalled = False
        self.waits_after_signal = 0

    def now_ns(self) -> UInt64:
        return UInt64(self.cell[])

    def sleep_secs(mut self, secs: Int):
        if self.signalled:
            self.waits_after_signal += 1
        self.cell[] += secs * _SEC_NS
        if not self.signalled:
            # The job creates `ready` after its line is in the pipe; it is
            # the event this wait is for, so it has no bound of its own.
            while not exists(self.ready):
                _yield()
            _ = proc_kill(external_call["getpid", Int32](), SIGTERM)
            self.signalled = True

    def test_clock(self) -> Optional[ArcPointer[Int]]:
        return Optional[ArcPointer[Int]](self.cell)


def _shell(var name: String, script: String, interval: Int) -> JobSupervisorConfig:
    var argv = List[String]()
    argv.append(String("-c"))
    argv.append(script)
    return JobSupervisorConfig(
        name^,
        String("instance-1"),
        String("/bin/sh"),
        argv^,
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=interval,
    )


def _count(beats: List[String], prefix: String) -> Int:
    var n = 0
    for i in range(len(beats)):
        if beats[i].startswith(prefix):
            n += 1
    return n


def _tmp(name: String) raises -> String:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    return tmp + "/" + name


def _text_at(store: SharedInMemoryConditionalStore, key: String) -> String:
    """The object's text, or "<absent>"."""
    try:
        var b = store.get(Path.parse(key))
        return String(unsafe_from_utf8=Span(b))
    except:
        return String("<absent>")


def test_a_job_that_ends_between_beats_is_noticed_within_seconds() raises:
    comptime INTERVAL = 3600
    var release = _tmp(String("between-beats-release"))
    assert_false(exists(release), "the release file exists before the run")
    var beats = ArcPointer[List[String]](List[String]())
    var at_ns = ArcPointer[List[Int]](List[Int]())
    var cell = ArcPointer[Int](_CLOCK_START_NS)
    var clock = ManualLoopClock(cell)
    # The job waits for the file the reporter creates with the beat after the
    # spawn, then exits: it is gated on that event, not on time.
    var phase = run_job_supervisor_with_clock[
        ReleasingRecorder, InMemoryConditionalStore, ManualLoopClock
    ](
        _shell(
            String("mid-interval"),
            String("until [ -e '") + release + String("' ]; do sleep 0.01; done"),
            INTERVAL,
        ),
        ReleasingRecorder(beats, at_ns, cell, release),
        None,
        None,
        clock,
    )
    assert_true(phase == JobSupervisorPhase.completed(), "COMPLETED")
    assert_equal(_count(beats[], String("RUNNING|")), 2, "the first two beats only")
    var n = len(beats[])
    assert_equal(beats[][n - 1], String("COMPLETED|"))
    assert_true(len(clock.slept_ms) >= 1, "the loop waited between the beats")
    for i in range(len(clock.slept_ms)):
        assert_equal(
            clock.slept_ms[i],
            1000,
            "every wait is one second, so the exit is checked every second",
        )
    # The COMPLETED beat is sent when the clock stands where the second beat
    # left it plus the waits made: less than the interval after it.
    var waited_ns = len(clock.slept_ms) * _SEC_NS
    assert_equal(cell[], at_ns[][1] + waited_ns, "the clock moved by the waits")
    assert_true(
        waited_ns < INTERVAL * _SEC_NS,
        "the exit was reported before the next beat was due",
    )
    # Beat 0 is sent before the spawn, beat 1 after it; the first wait comes
    # after beat 1.
    assert_equal(at_ns[][0], _CLOCK_START_NS, "no time passed before the spawn")
    print("  test_a_job_that_ends_between_beats_is_noticed_within_seconds: PASS")


def test_a_stop_signal_between_beats_stops_the_job_before_its_next_wait() raises:
    _ = take_stop_signal()  # nothing left over from before
    var ready = _tmp(String("stop-mid-interval-ready"))
    assert_false(exists(ready), "the ready file exists before the run")
    var beats = ArcPointer[List[String]](List[String]())
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var cell = ArcPointer[Int](_CLOCK_START_NS)
    var clock = StopWhenReadyClock(cell, ready)
    # The job prints a line, says so, and waits to be killed.
    var phase = run_job_supervisor_with_clock[
        Recorder, SharedInMemoryConditionalStore, StopWhenReadyClock
    ](
        _shell(
            String("stop-mid-interval"),
            String("echo signalling; : > '")
            + ready
            + String("'; while :; do sleep 1; done"),
            120,
        ),
        Recorder(beats),
        None,
        Optional[SharedInMemoryConditionalStore](store^),
        clock,
    )
    # The stop came before the job's own end, which never comes.
    assert_true(phase == JobSupervisorPhase.cancelled(), "CANCELLED")
    var last = beats[][len(beats[]) - 1]
    assert_equal(
        last, String("CANCELLED|the supervisor received SIGTERM; the job was stopped")
    )
    assert_equal(_count(beats[], String("RUNNING|")), 2)
    assert_true(clock.signalled, "the clock sent the signal")
    # The stop was taken in the pass that followed the signal: no wait came
    # after it, and the one wait moved the clock one second.
    assert_equal(clock.waits_after_signal, 0, "no wait after the signal")
    assert_equal(cell[], _CLOCK_START_NS + _SEC_NS, "one second was waited")
    # "signalling": the job was still running when it was stopped.
    assert_equal(
        _text_at(view, String("stop-mid-interval/logs.txt")),
        String("signalling"),
        "the job's output up to the signal",
    )
    # The stop took the signal: none is left latched (a stop that came from
    # anything else would leave it).
    assert_equal(take_stop_signal(), Int32(0), "the run took the SIGTERM")
    print("  test_a_stop_signal_between_beats_stops_the_job_before_its_next_wait: PASS")


def main() raises:
    print("test_job_supervisor_run_loop:")
    test_a_job_that_ends_between_beats_is_noticed_within_seconds()
    test_a_stop_signal_between_beats_stops_the_job_before_its_next_wait()
    print("test_job_supervisor_run_loop: ALL PASS")
