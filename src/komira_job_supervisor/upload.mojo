# =============================================================================
# komira_job_supervisor/upload.mojo — S3 crash-report + log upload (the terminal write).
# =============================================================================
#
# The deployment-real terminal-write path (crash-report + log upload):
# on a terminal phase, the job supervisor pushes forensics to the log bucket so the
# control plane has a durable record after the pod is gone:
#
#   * On FAILED: a crash-report JSON to `{log_bucket}/{job_id}/crash_report.json`
#     (job_id / exit_code / signal / stderr_tail / panic_message / pod_name /
#     timestamp).
#   * Logs (MVP): the captured stdout/stderr ring as a single object
#     `{log_bucket}/{job_id}/logs.txt`. Streaming / chunked + the stderr-separate
#     path is a DEFERRED hardening (note below).
#
# Both writes go through `JobSupervisorS3Client.put_object` (one PutObject; the small
# JSON / text objects need no multipart upload).
#
# BEST-EFFORT: an upload failure must NOT crash the job supervisor's terminal path — the
# heartbeat already carried the forensics to the job-manager DB; the S3 objects
# are a supplementary durable record. `upload_crash_report` / `upload_logs`
# return a Bool (True on success) and swallow errors with a stderr log.
#
# ENCAPSULATION + gap6: the JSON body is built as an owned String; the upload
# bytes are an owned `List[UInt8]`. No UnsafePointer crosses any boundary; no
# wildcard origin. Mojo 1.0.0b1.
# =============================================================================

from komira_job_supervisor.s3_client import JobSupervisorS3Client
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.kernel_tcp import KernelTcpConnector

from komira_job_supervisor.job_supervisor_config import JobSupervisorConfig
from komira_job_supervisor.job_supervisor_state import FailureReport
from komira_job_supervisor.clock_helper import amz_stamps_now
from komira_job_supervisor.heartbeat_client import _json_escape

import komira_log as log
from komira_log import ArgStr, ArgI64


# =============================================================================
# §1 — crash-report JSON builder.
# =============================================================================
def build_crash_report_json(
    job_id: String,
    pod_name: String,
    failure: FailureReport,
) -> String:
    """Build the crash-report JSON body. Fields:

      job_id        — the hyphenated job UUID.
      pod_name      — this pod's name.
      exit_code     — the child's exit code (present iff it exited normally).
      signal        — the terminating signal (present iff killed by signal).
      stderr_tail   — the last N stderr lines (always present, possibly empty).
      panic_message — the extracted panic line, if any.
      timestamp     — the SigV4-style UTC timestamp (YYYYMMDDTHHMMSSZ) at
                      upload time (from the same clock helper the signer uses).

    Reuses `heartbeat_client._json_escape` for string escaping so the body
    matches the heartbeat `failure` sub-object's escaping exactly."""
    var stamps = amz_stamps_now()
    var out = String('{"job_id":"')
    out += _json_escape(job_id)
    out += String('","pod_name":"')
    out += _json_escape(pod_name)
    out += String('"')

    if failure.exit_code:
        out += String(',"exit_code":')
        out += String(Int(failure.exit_code.value()))

    if failure.signal:
        out += String(',"signal":')
        out += String(Int(failure.signal.value()))

    out += String(',"stderr_tail":[')
    for i in range(len(failure.stderr_tail)):
        if i > 0:
            out += String(",")
        out += String('"')
        out += _json_escape(failure.stderr_tail[i])
        out += String('"')
    out += String("]")

    if failure.panic_message:
        out += String(',"panic_message":"')
        out += _json_escape(failure.panic_message.value())
        out += String('"')

    out += String(',"timestamp":"')
    out += stamps.amz_date
    out += String('"}')
    return out^


# =============================================================================
# §2 — _string_to_bytes — owned String -> owned List[UInt8].
# =============================================================================
def _string_to_bytes(s: String) -> List[UInt8]:
    """Copy a String's UTF-8 bytes into an owned List[UInt8] for upload."""
    var out = List[UInt8]()
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^


# =============================================================================
# §3 — upload_crash_report — put `{log_bucket}/{job_id}/crash_report.json`.
# =============================================================================
def upload_crash_report[
    C: Connector,
](
    config: JobSupervisorConfig,
    mut s3_client: JobSupervisorS3Client[C],
    failure: FailureReport,
) -> Bool:
    """Upload the crash-report JSON to
    `{log_bucket}/{job_id}/crash_report.json`. BEST-EFFORT — returns True on
    success, False (with a stderr log) on any failure (the heartbeat already
    carried the forensics to the DB). No-op (returns False) if no log bucket
    is configured."""
    if not config.log_bucket:
        return False
    var bucket = config.log_bucket.value()
    var key = config.job_id + String("/crash_report.json")
    try:
        var body = build_crash_report_json(
            config.job_id, config.pod_name, failure
        )
        s3_client.put_object(bucket, key, _string_to_bytes(body))
        log.info[
            "job supervisor upload: crash_report.json -> s3://{}/{}", "komira_job_supervisor"
        ](ArgStr(bucket), ArgStr(key))
        return True
    except e:
        log.warn[
            "job supervisor upload: crash_report upload failed (best-effort): {}",
            "komira_job_supervisor",
        ](ArgStr(String(e)))
        return False


# =============================================================================
# §4 — upload_logs — put `{log_bucket}/{job_id}/logs.txt` (MVP single object).
# =============================================================================
def upload_logs[
    C: Connector,
](
    config: JobSupervisorConfig,
    mut s3_client: JobSupervisorS3Client[C],
    log_lines: List[String],
) -> Bool:
    """Upload the captured log lines as a single object
    `{log_bucket}/{job_id}/logs.txt`. BEST-EFFORT — returns True on success.

    MVP: ONE object joining the lines with '\\n'. Streaming / chunked upload
    (`{job_id}/chunks/{n}.log`) and the stderr-separate path are DEFERRED
    hardening. No-op (returns False)
    if no log bucket is configured."""
    if not config.log_bucket:
        return False
    var bucket = config.log_bucket.value()
    var key = config.job_id + String("/logs.txt")
    try:
        var body = String("")
        for i in range(len(log_lines)):
            if i > 0:
                body += String("\n")
            body += log_lines[i]
        s3_client.put_object(bucket, key, _string_to_bytes(body))
        log.info[
            "job supervisor upload: logs.txt ({} lines) -> s3://{}/{}", "komira_job_supervisor"
        ](ArgI64(Int64(len(log_lines))), ArgStr(bucket), ArgStr(key))
        return True
    except e:
        log.warn[
            "job supervisor upload: logs upload failed (best-effort): {}",
            "komira_job_supervisor",
        ](ArgStr(String(e)))
        return False
