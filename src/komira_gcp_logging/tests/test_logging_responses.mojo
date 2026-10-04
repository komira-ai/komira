# The answer to `entries.list`, read by the generated client: a 200 whose
# body is a `ListLogEntriesResponse` in proto3 JSON, sent through the
# client over komira_http_core's ScriptedConnector (no socket), and each
# decoded field compared with the value written here.
#
# The bodies are hand-written in the form the Cloud Logging v2 REST
# reference gives for `ListLogEntriesResponse` and `LogEntry`: the three
# payload arms (`textPayload`, `jsonPayload`, `protoPayload` with its
# `@type`), RFC 3339 timestamps, severity as its enum name, `resource`
# with its labels, `httpRequest.latency` as a Duration string,
# `sourceLocation.line` as an int64 string, and `nextPageToken`.
#
# The read is lenient, as a client of a service newer than its pinned
# protos must be: an unknown key is skipped and an unknown severity name
# reads as DEFAULT. A severity given as its number, a timestamp with nine
# fractional digits or a numeric offset, and a payload that itself holds a
# `nextPageToken` key are read as the spec says. A filter that matches nothing answers with no
# `entries` key at all, or an empty body (a 204 included); each is a page
# with no entries.
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_logging.log_severity import LogSeverity
from komira_gcp_logging.logging import (
    ListLogEntriesRequest,
    ListLogEntriesResponse,
    LoggingServiceV2Client,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_wkt.structpb import VALUE_KIND_NUMBER, VALUE_KIND_STRING


comptime _RT = BlockingRuntime[NoopSink]

# 2026-09-12T10:00:00Z and one second later, in Unix seconds.
comptime _T0: Int64 = 1789207200
comptime _T1: Int64 = 1789207201


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _list(body: String) raises -> ListLogEntriesResponse:
    """`list_log_entries` answered with a 200 carrying `body`."""
    var http = HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok(body)))
    )
    var c = LoggingServiceV2Client[ScriptedConnector, StaticTokenSource](
        http^, StaticTokenSource(String("test-access-token"))
    )
    var names = List[String]()
    names.append(String("projects/demo-project"))
    var req = ListLogEntriesRequest(
        names^, String(""), String("timestamp asc"), Int32(3), String("")
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    return c.list_log_entries[_RT](req, reactor)


comptime _PAGE = (
    '{"entries":['
    # A Cloud Run job's stdout line.
    + '{"logName":"projects/demo-project/logs/run.googleapis.com%2Fstdout",'
    + '"resource":{"type":"cloud_run_job","labels":{"job_name":"build",'
    + '"location":"us-central1","project_id":"demo-project"}},'
    + '"textPayload":"step 1 of 3",'
    + '"timestamp":"2026-09-12T10:00:00.123456Z",'
    + '"receiveTimestamp":"2026-09-12T10:00:01Z",'
    + '"severity":"INFO","insertId":"abc123",'
    + '"labels":{"run.googleapis.com/execution_name":"build-x7k2p"}},'
    # A structured line, with trace context.
    + '{"logName":"projects/demo-project/logs/run.googleapis.com%2Fstderr",'
    + '"jsonPayload":{"message":"boom","attempt":2},'
    + '"timestamp":"2026-09-12T10:00:01Z","severity":"ERROR",'
    + '"insertId":"abc124",'
    + '"trace":"projects/demo-project/traces/0af7651916cd43dd8448eb211c80319c",'
    + '"spanId":"b7ad6b7169203331","traceSampled":true},'
    # An audit-style entry: a typed payload, a request, an operation, a
    # source location and a split.
    + '{"logName":"projects/demo-project/logs/cloudaudit.googleapis.com%2Factivity",'
    + '"protoPayload":{"@type":"type.googleapis.com/google.cloud.audit.AuditLog",'
    + '"methodName":"google.cloud.run.v2.Jobs.RunJob"},'
    + '"timestamp":"2026-09-12T10:00:01Z","severity":"NOTICE",'
    + '"insertId":"abc125",'
    + '"httpRequest":{"requestMethod":"POST","status":200,"latency":"0.250s",'
    + '"responseSize":"1024"},'
    + '"operation":{"id":"op-1","producer":"run.googleapis.com","first":true},'
    + '"sourceLocation":{"file":"main.go","line":"42","function":"main.run"},'
    + '"split":{"uid":"s-1","index":0,"totalSplits":2}}'
    + '],'
    + '"nextPageToken":"EAA4+/=xQ"}'
)


def test_a_page_of_three_entries() raises:
    var page = _list(_PAGE)
    assert_equal(len(page.entries), 3)
    assert_equal(page.next_page_token, "EAA4+/=xQ")

    ref e0 = page.entries[0]
    assert_equal(
        e0.log_name, "projects/demo-project/logs/run.googleapis.com%2Fstdout"
    )
    assert_true(Bool(e0.text_payload))
    assert_equal(e0.text_payload.value(), "step 1 of 3")
    assert_false(Bool(e0.json_payload))
    assert_false(Bool(e0.proto_payload))
    assert_equal(e0.timestamp.value().seconds, _T0)
    assert_equal(e0.timestamp.value().nanos, Int32(123456000))
    assert_equal(e0.receive_timestamp.value().seconds, _T1)
    assert_equal(e0.receive_timestamp.value().nanos, Int32(0))
    assert_equal(e0.severity.value, LogSeverity.INFO)
    assert_equal(e0.insert_id, "abc123")
    assert_equal(e0.resource.value().type, "cloud_run_job")
    assert_equal(len(e0.resource.value().labels), 3)
    assert_equal(e0.resource.value().labels["job_name"], "build")
    assert_equal(e0.resource.value().labels["location"], "us-central1")
    assert_equal(e0.labels["run.googleapis.com/execution_name"], "build-x7k2p")
    assert_false(Bool(e0.http_request))

    ref e1 = page.entries[1]
    assert_false(Bool(e1.text_payload))
    assert_true(Bool(e1.json_payload))
    ref s = e1.json_payload.value()
    assert_equal(len(s.keys), 2)
    assert_equal(s.keys[0], "message")
    assert_equal(s.values[0].kind, VALUE_KIND_STRING)
    assert_equal(s.values[0].string_value, "boom")
    assert_equal(s.keys[1], "attempt")
    assert_equal(s.values[1].kind, VALUE_KIND_NUMBER)
    assert_equal(s.values[1].number_value, 2.0)
    assert_equal(e1.severity.value, LogSeverity.ERROR)
    assert_equal(e1.timestamp.value().seconds, _T1)
    assert_equal(
        e1.trace, "projects/demo-project/traces/0af7651916cd43dd8448eb211c80319c"
    )
    assert_equal(e1.span_id, "b7ad6b7169203331")
    assert_true(e1.trace_sampled)

    ref e2 = page.entries[2]
    assert_true(Bool(e2.proto_payload))
    assert_false(Bool(e2.text_payload))
    ref a = e2.proto_payload.value()
    assert_equal(a.type_url, "type.googleapis.com/google.cloud.audit.AuditLog")
    assert_true(a.json_members.has("methodName"))
    assert_equal(
        a.json_members.get("methodName").as_string(),
        "google.cloud.run.v2.Jobs.RunJob",
    )
    assert_equal(e2.severity.value, LogSeverity.NOTICE)
    ref h = e2.http_request.value()
    assert_equal(h.request_method, "POST")
    assert_equal(h.status, Int32(200))
    assert_equal(h.response_size, Int64(1024))
    assert_equal(h.latency.value().seconds, Int64(0))
    assert_equal(h.latency.value().nanos, Int32(250000000))
    ref op = e2.operation.value()
    assert_equal(op.id, "op-1")
    assert_equal(op.producer, "run.googleapis.com")
    assert_true(op.first)
    assert_false(op.last)
    ref loc = e2.source_location.value()
    assert_equal(loc.file, "main.go")
    assert_equal(loc.line, Int64(42))
    assert_equal(loc.function, "main.run")
    ref sp = e2.split.value()
    assert_equal(sp.uid, "s-1")
    assert_equal(sp.index, Int32(0))
    assert_equal(sp.total_splits, Int32(2))


def test_unknown_fields_and_names_are_skipped() raises:
    # A key these protos do not declare, at the top and inside an entry, and
    # a severity name they do not know.
    var page = _list(
        '{"entries":[{"textPayload":"x","severity":"SEVERITY_FROM_LATER",'
        + '"addedLater":{"a":[1,2,{"b":null}]}}],'
        + '"nextPageToken":"t2","alsoAddedLater":true}'
    )
    assert_equal(len(page.entries), 1)
    assert_equal(page.entries[0].text_payload.value(), "x")
    assert_equal(page.entries[0].severity.value, LogSeverity.DEFAULT)
    assert_equal(page.next_page_token, "t2")


def test_nothing_matched() raises:
    # The service omits `entries` when nothing matches, and may still hand
    # back a token while it scans; neither is an error.
    var page = _list("{}")
    assert_equal(len(page.entries), 0)
    assert_equal(page.next_page_token, "")
    var scanning = _list('{"nextPageToken":"still-scanning"}')
    assert_equal(len(scanning.entries), 0)
    assert_equal(scanning.next_page_token, "still-scanning")


def test_spec_forms_of_severity_and_timestamp() raises:
    # proto3 JSON accepts an enum as its number (500 is ERROR) as well as its
    # name; RFC 3339 allows nine fractional digits and a numeric offset, and
    # 12:00:01+02:00 is the same instant as 10:00:01Z.
    var page = _list(
        '{"entries":[{"textPayload":"a","severity":500,'
        + '"timestamp":"2026-09-12T10:00:00.123456789Z"},'
        + '{"textPayload":"b","severity":"WARNING",'
        + '"timestamp":"2026-09-12T12:00:01+02:00"}]}'
    )
    assert_equal(len(page.entries), 2)
    assert_equal(page.entries[0].severity.value, LogSeverity.ERROR)
    assert_equal(page.entries[0].timestamp.value().seconds, _T0)
    assert_equal(page.entries[0].timestamp.value().nanos, Int32(123456789))
    assert_equal(page.entries[1].severity.value, LogSeverity.WARNING)
    assert_equal(page.entries[1].timestamp.value().seconds, _T1)
    assert_equal(page.entries[1].timestamp.value().nanos, Int32(0))


def test_a_payload_key_is_not_the_page_token() raises:
    # A log line is the writer's data: a `nextPageToken` key inside a
    # jsonPayload (or a payload's `entries`) is a Struct member, never the
    # response's own token, and a page with no top-level token has none.
    var page = _list(
        '{"entries":[{"jsonPayload":{"nextPageToken":"from-a-log-line",'
        + '"entries":[1]},"severity":"INFO"}]}'
    )
    assert_equal(len(page.entries), 1)
    assert_equal(page.next_page_token, "")
    ref s = page.entries[0].json_payload.value()
    assert_equal(len(s.keys), 2)
    assert_equal(s.keys[0], "nextPageToken")
    assert_equal(s.values[0].string_value, "from-a-log-line")
    var with_token = _list(
        '{"entries":[{"jsonPayload":{"nextPageToken":"from-a-log-line"}}],'
        + '"nextPageToken":"the-real-one"}'
    )
    assert_equal(with_token.next_page_token, "the-real-one")


def test_no_content_is_an_empty_page() raises:
    # 204 is inside the 2xx range the client accepts; with no body it is a
    # page with no entries, not an error.
    var http = HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script(
                _bytes("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
            )
        )
    )
    var c = LoggingServiceV2Client[ScriptedConnector, StaticTokenSource](
        http^, StaticTokenSource(String("test-access-token"))
    )
    var names = List[String]()
    names.append(String("projects/demo-project"))
    var req = ListLogEntriesRequest(
        names^, String(""), String("timestamp asc"), Int32(3), String("")
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var page = c.list_log_entries[_RT](req, reactor)
    assert_equal(len(page.entries), 0)
    assert_equal(page.next_page_token, "")


def test_empty_body_is_an_empty_page() raises:
    var page = _list("")
    assert_equal(len(page.entries), 0)
    assert_equal(page.next_page_token, "")


def main() raises:
    test_a_page_of_three_entries()
    test_unknown_fields_and_names_are_skipped()
    test_nothing_matched()
    test_empty_body_is_an_empty_page()
    test_spec_forms_of_severity_and_timestamp()
    test_a_payload_key_is_not_the_page_token()
    test_no_content_is_an_empty_page()
    print("OK")
