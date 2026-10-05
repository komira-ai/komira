# =============================================================================
# komira_job_supervisor/tests/e2e/test_job_supervisor_s3_e2e.mojo -- the
# supervisor's object-store path against a real MinIO.
# =============================================================================
#
# The supervisor fetches a job binary from an embedded MinIO through its S3
# store (SHA-256 verified against the digest in its key, chmod 0o755), spawns
# it, captures its output, and writes `logs.txt`, or `crash_report.json` when
# the job fails; the test reads each object back from the server.
#
#   (1) a script that prints a marker and exits 0: COMPLETED, and the
#       written logs.txt holds the marker;
#   (2) a script that prints to stderr and exits 7: FAILED with exit code 7,
#       and the written crash_report.json holds `"exit_code":7` and the
#       stderr line.
#
# The test drives the supervisor's steps directly (download_binary,
# spawn_child, poll_and_drain, analyze_exit, upload_logs,
# upload_crash_report), not run_job_supervisor, so no heartbeat endpoint is
# needed.
#
# Flags (komira_test_bucket): `--test-minio-binary=<path>` names the pinned
# MinIO server binary, which the test starts on 127.0.0.1 and stops. With no
# flag the test SKIPS (exit 77); with `--test-s3-*` it is CANNOT_TELL (exit 3).
# Everything the run writes lives under its own prefix, and `close()` proves
# the prefix empty before the server stops; a verdict that is not CLEAN fails
# the test.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto.hex import hex_lower_array_32
from komira_crypto.sha256 import sha256

from komira_job_supervisor.job_supervisor_config import JobSupervisorConfig
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase
from komira_job_supervisor.boot import download_binary
from komira_job_supervisor.upload import upload_crash_report, upload_logs

from job_supervisor_minio_e2e import (
    E2eSupervisor,
    JobSupervisorTestBucket,
    SilentReporter,
    bytes_of,
    open_job_supervisor_test_bucket,
    point_job_supervisor_at,
    remove_if_present,
    scratch_root,
    sleep_ms,
    supervisor_store,
    text_of,
)


def _config(
    job_name: String, binary_key: String, log_prefix: String, download_path: String
) -> JobSupervisorConfig:
    """The object-store path's config: a binary key, a download path and a
    log prefix. The heartbeat URL points nowhere; no heartbeat is sent."""
    return JobSupervisorConfig(
        String(job_name),
        String("test-instance"),
        String(download_path),
        List[String](),
        String("http://127.0.0.1:1/beat"),
        binary_key=Optional[String](String(binary_key)),
        binary_download_path=String(download_path),
        log_prefix=String(log_prefix),
    )


def _put_job(mut bucket: JobSupervisorTestBucket, script: String) raises -> String:
    """Store `script` at `<prefix><sha256>/binary`; return its key."""
    var body = bytes_of(script)
    var key = bucket.key(hex_lower_array_32(sha256(body)) + "/binary")
    bucket.client().put(key, Span(body))
    return key^


def _run_to_exit(mut job_supervisor: E2eSupervisor) raises:
    job_supervisor.spawn_child()
    var spins = 0
    while not job_supervisor.child_exited and spins < 500:
        job_supervisor.poll_and_drain()
        if job_supervisor.child_exited:
            break
        sleep_ms(10)
        spins += 1
    assert_true(job_supervisor.child_exited, "the job did not exit")
    job_supervisor.analyze_exit()


def test_happy_download_run_upload(mut bucket: JobSupervisorTestBucket) raises:
    print("[s3-e2e] scenario 1: fetch -> run -> write logs.txt")
    var marker = String("HELLO_FROM_JOB_SUPERVISOR_JOB_42")
    var key = _put_job(bucket, String("#!/bin/sh\necho ") + marker + "\nexit 0\n")
    var prefix = bucket.key("job-happy-0001")
    var download_path = scratch_root() + "/job-supervisor-e2e-" + String(bucket.run_id().value) + "-happy.sh"
    var config = _config(String("job-happy"), key, prefix, download_path)

    var dl = supervisor_store(bucket)
    var local = download_binary(config, dl)
    assert_equal(local, download_path, "download path")

    var job_supervisor = E2eSupervisor(config^, SilentReporter(), None)
    _run_to_exit(job_supervisor)
    remove_if_present(download_path)
    assert_true(job_supervisor.terminal_phase() == JobSupervisorPhase.completed(), "exit 0 must be COMPLETED")

    var joined = String("")
    var captured = job_supervisor.log_lines()
    for i in range(len(captured)):
        joined += captured[i] + "\n"
    assert_true(joined.find(marker) >= 0, "the captured stdout lacks the marker")

    var up = supervisor_store(bucket)
    assert_true(upload_logs(job_supervisor.config, up, job_supervisor.log_lines()), "upload_logs returned False")

    var log_text = text_of(bucket.client().get(prefix + "/logs.txt"))
    assert_true(log_text.find(marker) >= 0, "logs.txt lacks the marker: '" + log_text + "'")
    print("[s3-e2e] scenario 1 PASS")


def test_failure_crash_report(mut bucket: JobSupervisorTestBucket) raises:
    print("[s3-e2e] scenario 2: exit 7 -> crash_report.json")
    var err_line = String("FATAL_JOB_ERROR_99")
    var key = _put_job(bucket, String("#!/bin/sh\necho ") + err_line + " 1>&2\nexit 7\n")
    var prefix = bucket.key("job-fail-0002")
    var download_path = scratch_root() + "/job-supervisor-e2e-" + String(bucket.run_id().value) + "-fail.sh"
    var config = _config(String("job-fail"), key, prefix, download_path)

    var dl = supervisor_store(bucket)
    _ = download_binary(config, dl)

    var job_supervisor = E2eSupervisor(config^, SilentReporter(), None)
    _run_to_exit(job_supervisor)
    remove_if_present(download_path)
    assert_true(job_supervisor.terminal_phase() == JobSupervisorPhase.failed(), "exit 7 must be FAILED")
    assert_true(Bool(job_supervisor.state.failure), "no failure report was built")
    assert_equal(Int(job_supervisor.state.failure.value().exit_code.value()), 7, "exit code")

    var up = supervisor_store(bucket)
    assert_true(
        upload_crash_report(job_supervisor.config, up, job_supervisor.state.failure.value().copy()),
        "upload_crash_report returned False",
    )

    var cr_text = text_of(bucket.client().get(prefix + "/crash_report.json"))
    assert_true(cr_text.find('"exit_code":7') >= 0, "crash_report.json lacks exit_code 7: '" + cr_text + "'")
    assert_true(cr_text.find(err_line) >= 0, "crash_report.json lacks the stderr line: '" + cr_text + "'")
    print("[s3-e2e] scenario 2 PASS")


def main() raises:
    var bucket = open_job_supervisor_test_bucket(String("komira_job_supervisor:test_job_supervisor_s3_e2e"))
    point_job_supervisor_at(bucket)
    try:
        test_happy_download_run_upload(bucket)
        test_failure_crash_report(bucket)
    except e:
        var v = bucket.close()
        raise Error(String(e) + " (teardown: " + v.kind_name() + ")")
    var v = bucket.close()
    print("[s3-e2e] teardown verdict: " + v.kind_name())
    v.require_clean()
    print("[s3-e2e] ALL SCENARIOS PASS")
