# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_object_store.mojo
#   The binary fetch, the terminal writes, the live stdout stream and the
#   whole run loop, over an in-memory object store; the S3 store's verbs over
#   a scripted connector. No socket, no object service, no cloud.
# =============================================================================
#
# The supervisor takes its stores as any komira_objectstore
# `ConditionalWriteStore`, so `InMemoryConditionalStore` exercises every
# object-store path the supervisor has:
#
#   * the binary fetch verifies the digest in the key and writes an
#     executable; a mismatch is refused BEFORE anything is written;
#   * logs.txt and crash_report.json land under --log-prefix;
#   * the live stream writes `{prefix}/chunks/{n}.log` objects that
#     concatenate to the exact stdout;
#   * `run_job_supervisor` fetches, runs, heartbeats (an initial RUNNING and
#     one terminal phase), writes the record; a cancel reply stops the job
#     and reports CANCELLED; a --binary-key with no binary store is refused.
#
# The S3 store (s3_store.mojo) is driven over komira_http_core's
# `ScriptedConnector`, credentials from the default chain's environment arm
# (static, worthless values set below).
#
# EVERY ARM HAS A CONTROL.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env
from komira_crypto.hex import hex_lower_array_32
from komira_crypto.sha256 import sha256
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore import (
    InMemoryConditionalStore,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisorConfig,
    JobSupervisorPhase,
    LogStreamSink,
    SupervisorHeartbeat,
    download_binary,
    make_s3_store,
    run_job_supervisor,
    upload_crash_report,
    upload_logs,
)
from komira_job_supervisor.job_supervisor_state import FailureReport


comptime _ENDPOINT = "http://127.0.0.1:9000"


# =============================================================================
# helpers
# =============================================================================
def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _text(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _tmp(name: String) raises -> String:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    return tmp + "/" + name


def _read_file(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _config(
    var job: String,
    var binary: String,
    var key: Optional[String],
    var sha: Optional[String],
    var download: String,
) -> JobSupervisorConfig:
    return JobSupervisorConfig(
        job^,
        String("instance-1"),
        binary^,
        List[String](),
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=1,
        binary_key=key^,
        binary_sha256=sha^,
        binary_download_path=download^,
        log_prefix=String("logs/run-1"),
        log_chunk_bytes=8,
        log_flush_secs=60,
    )


struct RecordingReporter(HeartbeatReporter):
    """Records every heartbeat's phase into a shared list, and answers
    `cancel` from the beat number `cancel_at` on (0 = never)."""

    var phases: ArcPointer[List[String]]
    var cancel_at: Int

    def __init__(out self, phases: ArcPointer[List[String]], cancel_at: Int):
        self.phases = phases
        self.cancel_at = cancel_at

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        self.phases[].append(String(hb.phase.wire_str()))
        var n = len(self.phases[])
        var cancel = self.cancel_at > 0 and n >= self.cancel_at
        return HeartbeatOutcome(True, cancel, 200)


# =============================================================================
# ARM 1: the binary fetch verifies, writes and makes executable.
# =============================================================================
def test_download_verifies_then_writes() raises:
    var script = String("#!/bin/sh\necho fetched\n")
    var sha = hex_lower_array_32(sha256(script.as_bytes()))
    var store = InMemoryConditionalStore()
    _ = store.put(Path.parse(String("bin/") + sha + "/binary"), _bytes(script))

    var path = _tmp(String("dl-ok/job/run"))
    var cfg = _config(
        String("j"), String("/unused"),
        Optional[String](String("bin/") + sha + "/binary"), None, path,
    )
    assert_equal(download_binary(cfg, store), path)
    assert_equal(_read_file(path), script)

    # CONTROL: an explicit digest that does not match is refused and nothing
    # is written.
    _ = store.put(Path.parse(String("bin/plain")), _bytes(script))
    var bad_path = _tmp(String("dl-bad/run"))
    var bad = _config(
        String("j"), String("/unused"),
        Optional[String](String("bin/plain")), Optional[String](String("0" * 64)),
        bad_path,
    )
    var refused = False
    try:
        _ = download_binary(bad, store)
    except e:
        refused = String(e).find(String("SHA-256 mismatch")) >= 0
    assert_true(refused, "a digest mismatch must be refused, naming it")
    assert_false(exists(bad_path), "a refused binary is never written")
    print("  test_download_verifies_then_writes: PASS")


# =============================================================================
# ARM 2: the terminal writes land under --log-prefix.
# =============================================================================
def test_terminal_writes_land_under_the_prefix() raises:
    var store = InMemoryConditionalStore()
    var cfg = _config(String("j"), String("/b"), None, None, String(""))
    var lines = List[String]()
    lines.append(String("out-1"))
    lines.append(String("err-1"))
    assert_true(upload_logs(cfg, store, lines), "logs.txt written")
    assert_equal(
        _text(store.get(Path.parse(String("logs/run-1/logs.txt")))),
        String("out-1\nerr-1"),
    )
    var tail = List[String]()
    tail.append(String('bad "quote"'))
    var fr = FailureReport(Optional[Int32](Int32(3)), None, tail^, None)
    assert_true(upload_crash_report(cfg, store, fr), "crash report written")
    var cr = _text(store.get(Path.parse(String("logs/run-1/crash_report.json"))))
    assert_true(cr.find(String('"job_name":"j"')) >= 0, cr)
    assert_true(cr.find(String('"instance_name":"instance-1"')) >= 0, cr)
    assert_true(cr.find(String('"exit_code":3')) >= 0, cr)
    assert_true(cr.find(String('bad \\"quote\\"')) >= 0, "escaped: " + cr)
    # CONTROL: no signal key when no signal killed the job.
    assert_false(cr.find(String('"signal"')) >= 0, cr)
    print("  test_terminal_writes_land_under_the_prefix: PASS")


# =============================================================================
# ARM 3: the live stream's chunks concatenate to the exact stdout.
# =============================================================================
def test_stream_chunks_concatenate_to_stdout() raises:
    var store = InMemoryConditionalStore()
    var sink = LogStreamSink(String("logs/s"), 8, 60_000, True)
    sink.feed_stdout(String("0123456789"), store)  # crosses 8: one chunk
    sink.feed_stdout(String("ab"), store)  # under 8: buffered
    assert_equal(sink.chunks_produced(), 1)
    sink.flush_final(store)
    assert_equal(sink.chunks_produced(), 2)
    var joined = _text(store.get(Path.parse(String("logs/s/chunks/0.log"))))
    joined += _text(store.get(Path.parse(String("logs/s/chunks/1.log"))))
    assert_equal(joined, String("0123456789ab"))

    # CONTROL: a disabled sink writes nothing.
    var off = LogStreamSink.disabled()
    off.feed_stdout(String("0123456789"), store)
    off.flush_final(store)
    assert_equal(off.chunks_produced(), 0)
    print("  test_stream_chunks_concatenate_to_stdout: PASS")


# =============================================================================
# ARM 4: the whole run loop over in-memory stores.
# =============================================================================
def test_run_fetches_runs_reports_and_writes() raises:
    var script = String("#!/bin/sh\necho RUN_MARKER_42\nexit 0\n")
    var sha = hex_lower_array_32(sha256(script.as_bytes()))
    var key = String("bin/") + sha + "/binary"
    var binary_store = SharedInMemoryConditionalStore()
    _ = binary_store.put(Path.parse(key), _bytes(script))
    # A clone shares the map, so the test reads what the run wrote.
    var log_store = SharedInMemoryConditionalStore()
    var reader = log_store.clone()

    var phases = ArcPointer[List[String]](List[String]())
    var path = _tmp(String("run-ok/job"))
    var cfg = _config(String("run-ok"), path, Optional[String](key), None, path)
    var phase = run_job_supervisor[RecordingReporter, SharedInMemoryConditionalStore](
        cfg^,
        RecordingReporter(phases, 0),
        Optional[SharedInMemoryConditionalStore](binary_store^),
        Optional[SharedInMemoryConditionalStore](log_store^),
    )
    assert_true(phase == JobSupervisorPhase.completed(), "exit 0 -> COMPLETED")
    assert_true(len(phases[]) >= 2, "an initial and a terminal heartbeat")
    assert_equal(phases[][0], String("RUNNING"), "the first beat is RUNNING")
    assert_equal(
        phases[][len(phases[]) - 1], String("COMPLETED"), "the last is terminal"
    )
    var logs = _text(reader.get(Path.parse(String("logs/run-1/logs.txt"))))
    assert_true(logs.find(String("RUN_MARKER_42")) >= 0, "logs.txt: " + logs)
    # The stream wrote at least one chunk (8-byte chunks), and chunk 0 starts
    # the job's stdout.
    var c0 = _text(reader.get(Path.parse(String("logs/run-1/chunks/0.log"))))
    assert_true(c0.startswith(String("RUN_MARK")), "chunk 0: " + c0)
    # CONTROL: COMPLETED writes no crash report.
    var no_crash = False
    try:
        _ = reader.get(Path.parse(String("logs/run-1/crash_report.json")))
    except:
        no_crash = True
    assert_true(no_crash, "CONTROL: no crash report for a COMPLETED job")
    print("  test_run_fetches_runs_reports_and_writes: PASS")


def test_run_writes_the_record_and_honours_cancel() raises:
    var script = String("#!/bin/sh\necho STREAMED_LINE\nexit 4\n")
    var sha = hex_lower_array_32(sha256(script.as_bytes()))
    var key = String("bin/") + sha + "/binary"
    var binary_store = InMemoryConditionalStore()
    _ = binary_store.put(Path.parse(key), _bytes(script))
    var phases = ArcPointer[List[String]](List[String]())
    var path = _tmp(String("run-fail/job"))
    var cfg = _config(String("run-fail"), path, Optional[String](key), None, path)
    var phase = run_job_supervisor[RecordingReporter, InMemoryConditionalStore](
        cfg^,
        RecordingReporter(phases, 0),
        Optional[InMemoryConditionalStore](binary_store^),
        None,
    )
    assert_true(phase == JobSupervisorPhase.failed(), "exit 4 -> FAILED")
    assert_equal(phases[][len(phases[]) - 1], String("FAILED"))

    # CANCEL: the second beat answers cancel; a long job is stopped.
    var sleeper = String("#!/bin/sh\nsleep 30\n")
    var ssha = hex_lower_array_32(sha256(sleeper.as_bytes()))
    var skey = String("bin/") + ssha + "/binary"
    var sstore = InMemoryConditionalStore()
    _ = sstore.put(Path.parse(skey), _bytes(sleeper))
    var cphases = ArcPointer[List[String]](List[String]())
    var cpath = _tmp(String("run-cancel/job"))
    var ccfg = _config(String("run-cancel"), cpath, Optional[String](skey), None, cpath)
    var cphase = run_job_supervisor[RecordingReporter, InMemoryConditionalStore](
        ccfg^,
        RecordingReporter(cphases, 2),
        Optional[InMemoryConditionalStore](sstore^),
        None,
    )
    assert_true(cphase == JobSupervisorPhase.cancelled(), "a cancel reply -> CANCELLED")
    assert_equal(cphases[][len(cphases[]) - 1], String("CANCELLED"))

    # REFUSAL: a --binary-key with no binary store is refused before spawning.
    var rcfg = _config(
        String("no-store"), String("/bin/true"),
        Optional[String](String("bin/x")), None, String(""),
    )
    var refused = False
    try:
        _ = run_job_supervisor[RecordingReporter, InMemoryConditionalStore](
            rcfg^, RecordingReporter(ArcPointer[List[String]](List[String]()), 0),
            None, None,
        )
    except e:
        refused = String(e).find(String("no binary store")) >= 0
    assert_true(refused, "a --binary-key with no binary store must be refused")
    print("  test_run_writes_the_record_and_honours_cancel: PASS")


# =============================================================================
# ARM 5: the S3 store's verbs over a scripted connector.
# =============================================================================
def _setenv(name: String, value: String):
    var n = name
    var v = value
    _ = external_call["setenv", Int32](
        n.as_c_string_slice().unsafe_ptr(), v.as_c_string_slice().unsafe_ptr(), Int32(1)
    )


def _response(status_line: String, etag: String, body: String) -> List[UInt8]:
    var head = String("HTTP/1.1 ") + status_line + "\r\n"
    if etag.byte_length() > 0:
        head += "ETag: " + etag + "\r\n"
    head += "Content-Length: " + String(body.byte_length()) + "\r\n\r\n"
    return _bytes(head + body)


def _mk_get_ok() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _response(String("200 OK"), String('"e-1"'), String("BODY"))
        )
    )


def _mk_put_denied() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _response(
                String("403 Forbidden"),
                String(""),
                String("<Error><Code>AccessDenied</Code></Error>"),
            )
        )
    )


def test_the_s3_store_verbs() raises:
    _setenv(String("AWS_ACCESS_KEY_ID"), String("AKIAIOSFODNN7EXAMPLE"))
    _setenv(
        String("AWS_SECRET_ACCESS_KEY"),
        String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
    )
    var store = make_s3_store[ScriptedConnector](
        _mk_get_ok, String("bin"), String("us-east-1"), Optional[String](String(_ENDPOINT))
    )
    assert_equal(_text(store.get(Path.parse(String("job/binary")))), String("BODY"))

    # CONTROL: a 403 on PUT is an error the caller sees.
    var denied = make_s3_store[ScriptedConnector](
        _mk_put_denied, String("logs"), String("us-east-1"), Optional[String](String(_ENDPOINT))
    )
    var raised = False
    try:
        _ = denied.put(Path.parse(String("j/logs.txt")), _bytes(String("x")))
    except:
        raised = True
    assert_true(raised, "a 403 PutObject must raise")
    print("  test_the_s3_store_verbs: PASS")


def main() raises:
    print("test_job_supervisor_object_store:")
    test_download_verifies_then_writes()
    test_terminal_writes_land_under_the_prefix()
    test_stream_chunks_concatenate_to_stdout()
    test_run_fetches_runs_reports_and_writes()
    test_run_writes_the_record_and_honours_cancel()
    test_the_s3_store_verbs()
    print("test_job_supervisor_object_store: ALL PASS")
