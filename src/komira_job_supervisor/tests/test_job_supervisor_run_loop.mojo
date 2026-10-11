# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_run_loop.mojo
#   The run loop between two beats: a job's exit and a stop signal are noticed
#   between beats, not at the next beat.
# =============================================================================
#
#   test_a_job_that_ends_between_beats_is_noticed_within_seconds
#       With a 30 s heartbeat interval, a job that exits after 2 s ends the
#       run COMPLETED, after two RUNNING beats, and the COMPLETED beat is sent
#       less than 8 s after the first beat after the spawn: the loop checks
#       for the exit every second between beats, where a loop that checked
#       every 10 s would send it about 10 s after, and one that checked only
#       at the next beat about 30 s after. The time is read between two beats,
#       so the start-up before the spawn and the teardown after the last beat
#       (what a slow or instrumented build stretches most) are not in it.
#   test_a_stop_signal_between_beats_ends_the_run_at_once
#       With a 120 s interval, the job prints a line, then sends SIGTERM to
#       the supervisor 2 s in, then sleeps 60 s. The run ends CANCELLED,
#       naming SIGTERM, after two RUNNING beats, and its logs.txt holds the
#       line. No wall-clock bound: the job itself is the clock. The line
#       proves the job was still running when it sent the signal (a stop
#       before the signal kills it during its first sleep, before it prints);
#       CANCELLED proves the stop came before the job's own end 60 s after
#       the signal (a loop that ignored the signal, or took it only at the
#       next beat 120 s in, sees the job exit 0: COMPLETED); and no signal
#       is left latched afterwards, so the stop took this one.
#
# No heartbeat endpoint: the reporter records each beat. The stop test
# reads logs.txt from an in-memory log store; the other has no store.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_clock import now_ns
from komira_objectstore import (
    InMemoryConditionalStore,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_supervisor.pid1 import take_stop_signal

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisorConfig,
    JobSupervisorPhase,
    SupervisorHeartbeat,
    run_job_supervisor,
)


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


struct TimedRecorder(HeartbeatReporter):
    """A Recorder that also keeps each beat's monotonic time."""

    var beats: ArcPointer[List[String]]
    var at_ns: ArcPointer[List[UInt64]]

    def __init__(
        out self, beats: ArcPointer[List[String]], at_ns: ArcPointer[List[UInt64]]
    ):
        self.beats = beats
        self.at_ns = at_ns

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        self.at_ns[].append(now_ns())
        return HeartbeatOutcome(True, False, 200)


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


def test_a_job_that_ends_between_beats_is_noticed_within_seconds() raises:
    var beats = ArcPointer[List[String]](List[String]())
    var at_ns = ArcPointer[List[UInt64]](List[UInt64]())
    var phase = run_job_supervisor[TimedRecorder, InMemoryConditionalStore](
        _shell(String("mid-interval"), String("sleep 2"), 30),
        TimedRecorder(beats, at_ns),
        None,
        None,
    )
    assert_true(phase == JobSupervisorPhase.completed(), "COMPLETED")
    assert_equal(_count(beats[], String("RUNNING|")), 2, "the first two beats only")
    var n = len(beats[])
    assert_equal(beats[][n - 1], String("COMPLETED|"))
    # Beat 0 is sent before the spawn, beat 1 after it.
    var ms = Int((at_ns[][n - 1] - at_ns[][1]) // 1_000_000)
    assert_true(
        ms < 8000,
        "the 2 s exit was reported "
        + String(ms)
        + " ms after the spawn's beat, not between beats",
    )
    print("  test_a_job_that_ends_between_beats_is_noticed_within_seconds: PASS")


def _text_at(store: SharedInMemoryConditionalStore, key: String) -> String:
    """The object's text, or "<absent>"."""
    try:
        var b = store.get(Path.parse(key))
        return String(unsafe_from_utf8=Span(b))
    except:
        return String("<absent>")


def test_a_stop_signal_between_beats_ends_the_run_at_once() raises:
    _ = take_stop_signal()  # nothing left over from before
    var beats = ArcPointer[List[String]](List[String]())
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var phase = run_job_supervisor[Recorder, SharedInMemoryConditionalStore](
        _shell(
            String("stop-mid-interval"),
            String("sleep 2; echo signalling; kill -TERM $PPID; exec sleep 60"),
            120,
        ),
        Recorder(beats),
        None,
        Optional[SharedInMemoryConditionalStore](store^),
    )
    # The stop came before the job's own end, 60 s after the signal.
    assert_true(phase == JobSupervisorPhase.cancelled(), "CANCELLED")
    var last = beats[][len(beats[]) - 1]
    assert_equal(
        last, String("CANCELLED|the supervisor received SIGTERM; the job was stopped")
    )
    assert_equal(_count(beats[], String("RUNNING|")), 2)
    # The job was still running when it sent the signal: the stop came after.
    assert_equal(
        _text_at(view, String("stop-mid-interval/logs.txt")),
        String("signalling"),
        "the job printed before it signalled, so it was not stopped before",
    )
    # The stop took the signal: none is left latched (a stop that came from
    # anything else would leave it).
    assert_equal(take_stop_signal(), Int32(0), "the run took the SIGTERM")
    print("  test_a_stop_signal_between_beats_ends_the_run_at_once: PASS")


def main() raises:
    print("test_job_supervisor_run_loop:")
    test_a_job_that_ends_between_beats_is_noticed_within_seconds()
    test_a_stop_signal_between_beats_ends_the_run_at_once()
    print("test_job_supervisor_run_loop: ALL PASS")
