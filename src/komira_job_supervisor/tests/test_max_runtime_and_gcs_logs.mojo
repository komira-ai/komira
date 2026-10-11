# =============================================================================
# komira_job_supervisor/tests/test_max_runtime_and_gcs_logs.mojo
#   --max-runtime-secs stops the job and reports FAILED with a timeout
#   message; the entrypoint's gs:// log prefix writes the logs to GCS.
# =============================================================================
#
# ARM 1 (stepping): a job that would sleep 30 s, with a 3 s limit. At 2 s past
# the spawn (a stated instant, no waiting) nothing happens; at 3 s the child
# is stopped (SIGTERM), the phase is FAILED, the message names the limit and
# the failure report carries the signal; the terminal beat carries both.
# CONTROL: with no limit, an instant an hour later stops nothing.
#
# ARM 2 (the real loop): `run_job_supervisor` with a 1 s limit on the same
# job ends FAILED with the timeout message within seconds. A loop that never
# checked the limit would wait out the 30 s and report COMPLETED.
#
# ARM 3 (gs:// logs): the flags a launcher renders with
# `--log-prefix=gs://job-logs/runs/r-1` are parsed by EntrypointConfig, the
# store comes from `gcs_log_store` over the in-memory GCS backend, and a job
# that fails leaves logs.txt and crash_report.json under `runs/r-1/` in bucket
# `job-logs` (nothing at the job-name prefix).
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_clock import now_ns
from komira_objectstore import InMemoryConditionalStore
from komira_objectstore.path import Path
from komira_objectstore_gcs import FakeGcsStorageBackend, GcsConditionalStore

from komira_job_supervisor import (
    EntrypointConfig,
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisor,
    JobSupervisorConfig,
    SupervisorHeartbeat,
    gcs_log_store,
    run_job_supervisor,
)
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase


struct Recorder(HeartbeatReporter):
    """Records each beat as `PHASE|message` in a shared list."""

    var beats: ArcPointer[List[String]]

    def __init__(out self, beats: ArcPointer[List[String]]):
        self.beats = beats

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        return HeartbeatOutcome(True, False, 200)


def _sleeper(max_runtime_secs: Int) -> JobSupervisorConfig:
    var argv = List[String]()
    argv.append(String("-c"))
    argv.append(String("exec sleep 30"))
    return JobSupervisorConfig(
        String("sleeper"),
        String("instance-1"),
        String("/bin/sh"),
        argv^,
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=1,
        max_runtime_secs=max_runtime_secs,
    )


comptime _SEC: UInt64 = 1_000_000_000


def test_the_limit_stops_the_job_and_reports_it() raises:
    var beats = ArcPointer[List[String]](List[String]())
    var js = JobSupervisor[Recorder, InMemoryConditionalStore](
        _sleeper(3), Recorder(beats), None
    )
    js.spawn_child()
    var t0 = js.spawned_at_ns
    assert_false(
        js.enforce_max_runtime(t0 + 2 * _SEC, 5000), "2 s into a 3 s limit"
    )
    assert_false(js.child_exited, "the job still runs at 2 s")
    assert_true(js.enforce_max_runtime(t0 + 3 * _SEC, 5000), "stopped at 3 s")
    assert_true(js.child_exited, "the child was reaped")
    js.analyze_exit()
    assert_true(js.terminal_phase() == JobSupervisorPhase.failed(), "FAILED")
    assert_true(js.state.timed_out, "marked as a timeout")
    var msg = js.state.message.value()
    assert_true(msg.find(String("max runtime of 3 s exceeded")) >= 0, msg)
    assert_equal(
        js.state.failure.value().signal.value(), Int32(15), "stopped by SIGTERM"
    )
    _ = js.finalize_heartbeat()
    assert_equal(len(beats[]), 1)
    assert_true(
        beats[][0].startswith(String("FAILED|max runtime of 3 s exceeded")),
        "the terminal beat carries FAILED and the reason: " + beats[][0],
    )
    _ = js^

    # CONTROL: no limit, nothing is stopped however late it is.
    var free = JobSupervisor[Recorder, InMemoryConditionalStore](
        _sleeper(0), Recorder(ArcPointer[List[String]](List[String]())), None
    )
    free.spawn_child()
    assert_false(
        free.enforce_max_runtime(free.spawned_at_ns + 3600 * _SEC, 5000),
        "CONTROL: no limit stops nothing",
    )
    assert_false(free.child_exited, "CONTROL: still running")
    _ = free.supervisor.terminate(100)
    _ = free^
    print("  test_the_limit_stops_the_job_and_reports_it: PASS")


def test_the_run_loop_enforces_the_limit() raises:
    var beats = ArcPointer[List[String]](List[String]())
    var t0 = now_ns()
    var phase = run_job_supervisor[Recorder, InMemoryConditionalStore](
        _sleeper(1), Recorder(beats), None, None
    )
    var took_s = Int((now_ns() - t0) // _SEC)
    assert_true(phase == JobSupervisorPhase.failed(), "the loop stopped it: FAILED")
    assert_true(took_s < 20, "stopped long before the job's 30 s: " + String(took_s))
    var last = beats[][len(beats[]) - 1]
    assert_true(
        last.startswith(String("FAILED|max runtime of 1 s exceeded")), last
    )
    assert_true(beats[][0].startswith(String("RUNNING|")), "RUNNING first")
    print("  test_the_run_loop_enforces_the_limit: PASS")


def _mk_fake() -> FakeGcsStorageBackend:
    return FakeGcsStorageBackend()


def _flags() -> List[String]:
    var out = List[String]()
    out.append(String("--job-name=r-1"))
    out.append(String("--heartbeat-url=https://beats.example.com/v1/beat"))
    out.append(String("--heartbeat-credential-env=JOB_CREDENTIAL"))
    out.append(String("--max-runtime-secs=60"))
    out.append(String("--log-prefix=gs://job-logs/runs/r-1"))
    out.append(String("--job-binary=/bin/sh"))
    out.append(String("--"))
    out.append(String("-c"))
    out.append(String("echo GCS_LOG_MARKER; echo boom >&2; exit 3"))
    return out^


def test_the_logs_go_to_the_gs_prefix() raises:
    var cfg = EntrypointConfig.from_args(_flags())
    var store = gcs_log_store[FakeGcsStorageBackend](
        cfg.log, FakeGcsStorageBackend(), _mk_fake
    )
    assert_equal(store.bucket(), String("job-logs"), "the gs:// bucket")
    var js = JobSupervisor[Recorder, GcsConditionalStore[FakeGcsStorageBackend]](
        cfg^.into_job(),
        Recorder(ArcPointer[List[String]](List[String]())),
        Optional[GcsConditionalStore[FakeGcsStorageBackend]](store^),
    )
    js.spawn_child()
    var spins = 0
    while not js.child_exited and spins < 2000:
        js.poll_and_drain()
        _ = external_call["usleep", Int32](UInt32(2000))
        spins += 1
    assert_true(js.child_exited, "the job ran")
    js.analyze_exit()
    assert_true(js.terminal_phase() == JobSupervisorPhase.failed(), "exit 3")
    js.upload_terminal_artifacts()

    ref st = js.log_store.value()
    var logs = st.get(Path.parse(String("runs/r-1/logs.txt")))
    var text = String(unsafe_from_utf8=Span(logs))
    assert_true(text.find(String("GCS_LOG_MARKER")) >= 0, "logs.txt: " + text)
    _ = st.get(Path.parse(String("runs/r-1/crash_report.json")))
    var at_job_name = False
    try:
        _ = st.get(Path.parse(String("r-1/logs.txt")))
        at_job_name = True
    except:
        pass
    assert_false(at_job_name, "CONTROL: nothing under the bare job name")
    _ = js^
    print("  test_the_logs_go_to_the_gs_prefix: PASS")


def main() raises:
    test_the_limit_stops_the_job_and_reports_it()
    test_the_run_loop_enforces_the_limit()
    test_the_logs_go_to_the_gs_prefix()
    print("PASS test_max_runtime_and_gcs_logs")
