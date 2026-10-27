# =============================================================================
# komira_job_supervisor/tests/e2e/test_job_supervisor_stream_logs_e2e.mojo --
# the supervisor streams a running job's stdout to a real MinIO in chunks.
# =============================================================================
#
# While the job runs, the supervisor writes its stdout to
# `{log_prefix}/chunks/{n}.log` each time the chunk threshold is crossed (2 KiB
# here). The test proves:
#   * at least one chunk is uploaded BEFORE the job exits (the live
#     property: `log_sink.uploaded_count >= 1` while `child_exited` is
#     still False). The job holds each burst's successor until the test has
#     seen a chunk written for it (a file per burst, created by the test), so
#     the first chunk is written while the job is waiting, by construction;
#   * the job produces at least two chunk objects, and the server lists at
#     least two under the prefix;
#   * the chunks, read back from the server in index order and
#     concatenated, equal the job's whole stdout, byte for byte.
#
# The test drives the supervisor directly (a log store, spawn_child_spec, the
# poll_and_drain / _tick_stream_timer loop run_job_supervisor runs), so no
# heartbeat endpoint is needed. The supervisor is on a manual clock that never
# moves, so no chunk is written by the flush interval: every chunk is written
# because the threshold was crossed or the job ended (the flush interval has
# its own test, test_the_stream_timer_flushes_a_quiet_chunk). Flags and
# verdicts as in test_job_supervisor_s3_e2e.mojo.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_job_supervisor.job_supervisor_config import JobSupervisorConfig
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase
from komira_supervisor.supervisor import ChildSpec

from komira_test_s3_adapter import scratch_root

from job_supervisor_minio_e2e import (
    E2eStore,
    E2eSupervisor,
    JobSupervisorTestBucket,
    SilentReporter,
    open_job_supervisor_test_bucket,
    point_job_supervisor_at,
    remove_if_present,
    sleep_ms,
    supervisor_store,
    text_of,
)


comptime _BURSTS = 6
comptime _BURST_WIDTH = 4000


def _stream_config(log_prefix: String) -> JobSupervisorConfig:
    """A log prefix and a 2 KiB chunk threshold, so each ~4 KiB burst
    flushes a chunk. The job is a ChildSpec.shell; no binary key."""
    return JobSupervisorConfig(
        String("job-stream"),
        String("test-instance-stream"),
        String("/bin/sh"),
        List[String](),
        String("http://127.0.0.1:1/beat"),
        log_prefix=String(log_prefix),
        log_chunk_bytes=2 * 1024,
        log_flush_secs=1,
    )


def test_stream_chunks_during_run(mut bucket: JobSupervisorTestBucket) raises:
    print("[stream-e2e] chunked stdout -> MinIO during the run")
    var log_prefix = bucket.key("job-stream-0001")

    # Six bursts of one ~4 KiB line, ~24 KiB in all. After burst i the job
    # waits for the file `<ack>i`, which the test creates once a chunk has
    # been written for it.
    var ack = scratch_root() + "/job-supervisor-e2e-" + String(bucket.run_id().value) + "-stream-ack-"
    var script = String(
        "i=0; while [ $i -lt 6 ]; do "
        "awk 'BEGIN{ s=\"\"; for(j=0;j<4000;j++) s=s \"X\"; "
        "print \"BURST\" \"'$i'\" \"_\" s }'; "
        "until [ -e '"
    ) + ack + String(
        "'$i ]; do sleep 0.02; done; "
        "i=$((i+1)); done"
    )

    # The log store is given at construction, so the first drained chunk
    # streams.
    var job_supervisor = E2eSupervisor(
        _stream_config(log_prefix),
        SilentReporter(),
        Optional[E2eStore](supervisor_store(bucket)),
    )
    # A clock that never moves: the flush interval never passes.
    job_supervisor.set_test_clock(ArcPointer[Int](0))
    job_supervisor.spawn_child_spec(ChildSpec.shell(script))

    var saw_chunk_before_exit = False
    var released = 0
    while not job_supervisor.child_exited:
        job_supervisor.poll_and_drain()
        if job_supervisor.child_exited:
            break
        job_supervisor._tick_stream_timer()
        var uploaded = job_supervisor.log_sink.uploaded_count
        if uploaded >= 1:
            saw_chunk_before_exit = True
        # Let the job write burst `released + 1` once a chunk has been written
        # for the bursts it has written so far.
        while released < _BURSTS and uploaded > released:
            with open(ack + String(released), "w") as f:
                f.write("go")
            released += 1
        sleep_ms(20)
    for i in range(_BURSTS):
        remove_if_present(ack + String(i))
    job_supervisor.analyze_exit()
    assert_true(job_supervisor.terminal_phase() == JobSupervisorPhase.completed(), "the job must be COMPLETED")
    assert_true(saw_chunk_before_exit, "no chunk was written before the job exited")

    var produced = job_supervisor.log_sink.chunks_produced()
    print("[stream-e2e]   chunks produced: " + String(produced))
    assert_true(produced >= 2, "expected >= 2 chunks, got " + String(produced))

    var prefix = log_prefix + "/chunks/"
    var listed = List[String]()
    bucket.client().list_keys(prefix, listed)
    print("[stream-e2e]   chunk objects listed: " + String(len(listed)))
    assert_true(len(listed) >= 2, "expected >= 2 chunk objects, listed " + String(len(listed)))
    assert_equal(len(listed), produced, "listed chunk objects != chunks produced")

    var reconstructed = List[UInt8]()
    for n in range(produced):
        var chunk = bucket.client().get(prefix + String(n) + ".log")
        reconstructed.extend(Span(chunk))

    var expected = String("")
    for i in range(_BURSTS):
        expected += String("BURST") + String(i) + "_"
        for _x in range(_BURST_WIDTH):
            expected += "X"
        expected += "\n"
    var got = text_of(reconstructed)
    assert_equal(got.byte_length(), expected.byte_length(), "reconstructed length")
    assert_true(got == expected, "the chunks do not reconstruct the job's stdout")
    print("[stream-e2e] PASS")


def main() raises:
    var bucket = open_job_supervisor_test_bucket(String("komira_job_supervisor:test_job_supervisor_stream_logs_e2e"))
    point_job_supervisor_at(bucket)
    try:
        test_stream_chunks_during_run(bucket)
    except e:
        var v = bucket.close()
        raise Error(String(e) + " (teardown: " + v.kind_name() + ")")
    var v = bucket.close()
    print("[stream-e2e] teardown verdict: " + v.kind_name())
    v.require_clean()
    print("[stream-e2e] ALL SCENARIOS PASS")
