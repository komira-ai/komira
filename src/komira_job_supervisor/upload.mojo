# =============================================================================
# komira_job_supervisor/upload.mojo: the terminal writes to the log store.
# =============================================================================
#
# When the job ends, the supervisor writes a durable record of it to the log
# object store the embedding binary supplied:
#
#   * `{log_prefix}/logs.txt`: the captured stdout lines, then the stderr
#     lines, joined with '\n' (the stdout capture is bounded by
#     --max-stdout-bytes; the full stdout is in the streamed chunks);
#   * on FAILED, `{log_prefix}/crash_report.json`: job_name, instance_name,
#     exit_code, signal, stderr_tail, panic_message and a UTC timestamp.
#
# Each is one unconditional `put` on any komira_objectstore
# `ConditionalWriteStore`. BEST-EFFORT: a failed write is logged and returns
# False; it never fails the supervisor, whose terminal heartbeat already
# carried the forensics.
#
# Owned String / List[UInt8] values only; no pointer type.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_job_supervisor.job_supervisor_config import JobSupervisorConfig
from komira_job_supervisor.job_supervisor_state import FailureReport
from komira_job_supervisor.clock_helper import utc_stamp_now

import komira_log as log
from komira_log import ArgStr, ArgI64


def json_escape(s: String) -> String:
    """`s` escaped for a JSON string literal: backslash, double quote,
    newline, carriage return and tab."""
    var out = String("")
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == UInt8(0x22):
            out += String('\\"')
        elif c == UInt8(0x5C):
            out += String("\\\\")
        elif c == UInt8(0x0A):
            out += String("\\n")
        elif c == UInt8(0x0D):
            out += String("\\r")
        elif c == UInt8(0x09):
            out += String("\\t")
        else:
            out += chr(Int(c))
    return out^


def build_crash_report_json(
    job_name: String,
    instance_name: String,
    failure: FailureReport,
) -> String:
    """The crash-report JSON body: job_name, instance_name, exit_code (iff
    the job exited), signal (iff a signal killed it), stderr_tail (always),
    panic_message (iff found) and timestamp ("YYYYMMDDTHHMMSSZ", UTC)."""
    var out = String('{"job_name":"')
    out += json_escape(job_name)
    out += String('","instance_name":"')
    out += json_escape(instance_name)
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
        out += json_escape(failure.stderr_tail[i])
        out += String('"')
    out += String("]")
    if failure.panic_message:
        out += String(',"panic_message":"')
        out += json_escape(failure.panic_message.value())
        out += String('"')
    out += String(',"timestamp":"')
    out += utc_stamp_now()
    out += String('"}')
    return out^


def _string_to_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def crash_report_key(config: JobSupervisorConfig) -> String:
    return config.log_prefix + String("/crash_report.json")


def logs_key(config: JobSupervisorConfig) -> String:
    return config.log_prefix + String("/logs.txt")


def upload_crash_report[
    S: ConditionalWriteStore,
](config: JobSupervisorConfig, store: S, failure: FailureReport) -> Bool:
    """Write `{log_prefix}/crash_report.json`. True on success; False, with a
    warning, on any failure."""
    var key = crash_report_key(config)
    try:
        var body = build_crash_report_json(
            config.job_name, config.instance_name, failure
        )
        _ = store.put(Path.parse(key), _string_to_bytes(body))
        log.info[
            "job supervisor upload: crash report -> {}", "komira_job_supervisor"
        ](ArgStr(key))
        return True
    except e:
        log.warn[
            "job supervisor upload: crash report write failed (best-effort): {}",
            "komira_job_supervisor",
        ](ArgStr(String(e)))
        return False


def upload_logs[
    S: ConditionalWriteStore,
](config: JobSupervisorConfig, store: S, log_lines: List[String]) -> Bool:
    """Write `{log_prefix}/logs.txt`: `log_lines` joined with '\\n'. True on
    success; False, with a warning, on any failure."""
    var key = logs_key(config)
    try:
        var body = String("")
        for i in range(len(log_lines)):
            if i > 0:
                body += String("\n")
            body += log_lines[i]
        _ = store.put(Path.parse(key), _string_to_bytes(body))
        log.info[
            "job supervisor upload: logs.txt ({} lines) -> {}",
            "komira_job_supervisor",
        ](ArgI64(Int64(len(log_lines))), ArgStr(key))
        return True
    except e:
        log.warn[
            "job supervisor upload: logs.txt write failed (best-effort): {}",
            "komira_job_supervisor",
        ](ArgStr(String(e)))
        return False
