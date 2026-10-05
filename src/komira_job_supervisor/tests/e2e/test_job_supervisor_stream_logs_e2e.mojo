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
#     still False);
#   * the job produces at least two chunk objects, and the server lists at
#     least two under the prefix;
#   * the chunks, read back from the server in index order and
#     concatenated, equal the job's whole stdout, byte for byte.
#
# The test drives the supervisor directly (a log store, spawn_child_spec, the
# poll_and_drain / _tick_stream_timer loop run_job_supervisor runs), so no
# heartbeat endpoint is needed. Flags and verdicts as in
# test_job_supervisor_s3_e2e.mojo.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_job_supervisor.job_supervisor_config import JobSupervisorConfig
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase
from komira_supervisor.supervisor import ChildSpec

from job_supervisor_minio_e2e import (
    E2eStore,
    E2eSupervisor,
    JobSupervisorTestBucket,
    SilentReporter,
    open_job_supervisor_test_bucket,
    point_job_supervisor_at,
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

    # Six bursts of one ~4 KiB line, 0.4 s apart: ~24 KiB over ~2.4 s.
    var script = String(
        "i=0; while [ $i -lt 6 ]; do "
        "awk 'BEGIN{ s=\"\"; for(j=0;j<4000;j++) s=s \"X\"; "
        "print \"BURST\" \"'$i'\" \"_\" s }'; "
        "i=$((i+1)); sleep 0.4; done"
    )

    # The log store is given at construction, so the first drained chunk
    # streams.
    var job_supervisor = E2eSupervisor(
        _stream_config(log_prefix),
        SilentReporter(),
        Optional[E2eStore](supervisor_store(bucket)),
    )
    job_supervisor.spawn_child_spec(ChildSpec.shell(script))

    var saw_chunk_before_exit = False
    var spins = 0
    while not job_supervisor.child_exited and spins < 2000:
        job_supervisor.poll_and_drain()
        if job_supervisor.child_exited:
            break
        job_supervisor._tick_stream_timer()
        if job_supervisor.log_sink.uploaded_count >= 1:
            saw_chunk_before_exit = True
        sleep_ms(20)
        spins += 1
    assert_true(job_supervisor.child_exited, "the job did not exit")
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
