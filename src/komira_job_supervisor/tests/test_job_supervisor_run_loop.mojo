# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_run_loop.mojo
#   The run loop between two beats: a job's exit and a stop signal are noticed
#   within a second, not at the next beat.
# =============================================================================
#
#   test_a_job_that_ends_between_beats_is_noticed_within_seconds
#       With a 30 s heartbeat interval, a job that exits after 2 s ends the
#       run in at most 5 s (the loop checks for the exit every second
#       between beats; a loop that checked every 10 s would take about 10 s),
#       COMPLETED, after two RUNNING beats.
#   test_a_stop_signal_between_beats_ends_the_run_at_once
#       With a 30 s interval, a SIGTERM that arrives 1 s into the interval
#       stops the job then, not at the next beat: CANCELLED, naming SIGTERM,
#       in at most 5 s.
#
# No store and no heartbeat endpoint: the reporter records each beat.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_clock import now_ns
from komira_objectstore import InMemoryConditionalStore

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


comptime _SEC: UInt64 = 1_000_000_000


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
    var t0 = now_ns()
    var phase = run_job_supervisor[Recorder, InMemoryConditionalStore](
        _shell(String("mid-interval"), String("sleep 2"), 30), Recorder(beats), None, None
    )
    var took_s = Int((now_ns() - t0) // _SEC)
    assert_true(phase == JobSupervisorPhase.completed(), "COMPLETED")
    assert_true(
        took_s <= 5, "noticed within a second of the 2 s exit: " + String(took_s)
    )
    assert_equal(_count(beats[], String("RUNNING|")), 2, "the first two beats only")
    assert_equal(beats[][len(beats[]) - 1], String("COMPLETED|"))
    print("  test_a_job_that_ends_between_beats_is_noticed_within_seconds: PASS")


def test_a_stop_signal_between_beats_ends_the_run_at_once() raises:
    var beats = ArcPointer[List[String]](List[String]())
    var t0 = now_ns()
    var phase = run_job_supervisor[Recorder, InMemoryConditionalStore](
        _shell(
            String("stop-mid-interval"),
            String("sleep 1; kill -TERM $PPID; exec sleep 30"),
            30,
        ),
        Recorder(beats),
        None,
        None,
    )
    var took_s = Int((now_ns() - t0) // _SEC)
    assert_true(phase == JobSupervisorPhase.cancelled(), "CANCELLED")
    assert_true(
        took_s <= 5, "stopped within a second of the 1 s signal: " + String(took_s)
    )
    var last = beats[][len(beats[]) - 1]
    assert_equal(
        last, String("CANCELLED|the supervisor received SIGTERM; the job was stopped")
    )
    assert_equal(_count(beats[], String("RUNNING|")), 2)
    print("  test_a_stop_signal_between_beats_ends_the_run_at_once: PASS")


def main() raises:
    print("test_job_supervisor_run_loop:")
    test_a_job_that_ends_between_beats_is_noticed_within_seconds()
    test_a_stop_signal_between_beats_ends_the_run_at_once()
    print("test_job_supervisor_run_loop: ALL PASS")
