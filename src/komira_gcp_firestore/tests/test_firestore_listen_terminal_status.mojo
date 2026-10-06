# =============================================================================
# test_firestore_listen_terminal_status.mojo — how the Firestore Listen client
#   reads the END of its stream: the gRPC status, the HTTP status, a reset, a
#   GOAWAY, a dropped connection and a truncated message.
# =============================================================================
#
# `FirestoreListenClient` drives its own HTTP/2 receive loop (it does not go
# through komira_grpc's `GrpcClient`), so the terminal-status rules GrpcClient
# applies have to hold here on their own. Every case below replays a scripted
# server (SETTINGS, response HEADERS, DATA, trailers, RST_STREAM, GOAWAY) off a
# `ScriptedStream`; nothing opens a socket.
#
# What each test proves, and the defect it catches:
#
#   * open, trailers-only `grpc-status: 3`: `open` raises `[grpc:3]` with the
#     percent-decoded message. Catches: a failed Listen read as an open stream
#     (the stream then ends at once, the source reconnects, and the watch is
#     idle forever with the server's reason thrown away).
#   * open, `:status 503` with an HTML body: `open` raises `[grpc:14]` (the
#     spec's HTTP-to-gRPC table). Catches: the HTTP status not checked.
#   * end on trailers carrying `grpc-status: 7`: the stream's terminal status
#     is 7 with its decoded message. Catches: a non-OK status dropped at end
#     of stream.
#   * end on a DATA frame with no trailers: INTERNAL; trailers without a
#     `grpc-status`: UNKNOWN. Catches: a missing status read as a clean end.
#   * RST_STREAM(CANCEL) and RST_STREAM(ENHANCE_YOUR_CALM) mid-stream, with
#     the connection held open: the stream ends at once, CANCELLED and
#     RESOURCE_EXHAUSTED. Catches: a reset stream left waiting for bytes that
#     never come, and a reset code read through the wrong row.
#   * RST_STREAM(REFUSED_STREAM) before the response head: `open` raises
#     `[grpc:14]` and the client keeps that status after the raise. Catches:
#     the pre-head end raised without a status.
#   * GOAWAY excluding the stream, connection held open: the stream ends,
#     UNAVAILABLE naming the GOAWAY. Catches: the same wait on a stream the
#     server will not process.
#   * the connection closes with no END_STREAM: UNAVAILABLE; after a GOAWAY
#     that did NOT exclude the stream, the same, with the GOAWAY's context.
#   * DATA before the response head (a malformed response this client
#     refuses with its own RST_STREAM), and trailers without END_STREAM:
#     INTERNAL naming the malformation. Catches: a refused stream that never
#     ends, or ends as "connection closed".
#   * a trailers-only `grpc-status: 0`: `open` returns, the status is 0, and
#     the first poll reports the end. Catches: open raising on an OK answer.
#   * a head then an empty END_STREAM, and a trailers-only head with no
#     `grpc-status`: `open` raises UNKNOWN (#454's missing-status rule).
#   * `grpc-status: 0` after a partial message: INTERNAL. Catches: the tail of
#     a truncated envelope silently dropped.
#   * a clean `grpc-status: 0` end is OK (the control), and polling again
#     after the end keeps that status.
#   * a non-ASCII `grpc-message` (raw UTF-8 and an invalid byte) does not
#     abort the process, and the status code still reads.
#
# The rules on h2 state no script reaches (a reset this client sent, a stream
# the state does not hold, every RST_STREAM code) are in
# test_firestore_listen_terminal_rules.mojo.
# =============================================================================

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_core.codec.h2.frame import (
    H2_ERR_CANCEL,
    H2_ERR_ENHANCE_YOUR_CALM,
    H2_ERR_NO_ERROR,
    H2_ERR_REFUSED_STREAM,
    SettingsEntry,
    encode_data_frame,
    encode_goaway_frame,
    encode_headers_frame,
    encode_rst_stream_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedStream

from komira_protobuf.writer import (
    pb_write_message_field,
    pb_write_varint_field,
)

from komira_grpc import (
    GRPC_STATUS_OK,
    GRPC_STATUS_CANCELLED,
    GRPC_STATUS_UNKNOWN,
    GRPC_STATUS_INVALID_ARGUMENT,
    GRPC_STATUS_DEADLINE_EXCEEDED,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_ALREADY_EXISTS,
    GRPC_STATUS_PERMISSION_DENIED,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    GRPC_STATUS_FAILED_PRECONDITION,
    GRPC_STATUS_ABORTED,
    GRPC_STATUS_OUT_OF_RANGE,
    GRPC_STATUS_UNIMPLEMENTED,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_DATA_LOSS,
    GRPC_STATUS_UNAUTHENTICATED,
)

from komira_gcp_firestore.firestore_listen_proto import TCT_CURRENT
from komira_gcp_firestore.firestore_listen_client import (
    FirestoreListenClient,
    encode_grpc_envelope,
)

comptime _RT = PerCoreAsyncRuntime[NoopSink]
comptime _SID = UInt32(1)  # the first client stream id
comptime LRESP_TARGET_CHANGE = 2  # ListenResponse.target_change
comptime TC_TARGET_CHANGE_TYPE = 1  # TargetChange.target_change_type


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _target_change_envelope() -> List[UInt8]:
    """One gRPC envelope carrying ListenResponse{target_change{CURRENT}}."""
    var tc = List[UInt8]()
    pb_write_varint_field(tc, TC_TARGET_CHANGE_TYPE, UInt64(TCT_CURRENT))
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_TARGET_CHANGE, tc)
    return encode_grpc_envelope(resp^)


def _settings(mut out: List[UInt8]):
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)


def _headers(
    mut hpack: HpackEncoder,
    var fields: List[HpackHeader],
    end_stream: Bool,
    mut out: List[UInt8],
):
    var block = hpack.encode_block(fields^)
    encode_headers_frame(
        _SID, block^, end_stream=end_stream, end_headers=True, out=out
    )


def _grpc_head(mut hpack: HpackEncoder, mut out: List[UInt8]):
    """`:status 200` + `content-type: application/grpc`, no END_STREAM."""
    var h = List[HpackHeader]()
    h.append(HpackHeader(String(":status"), String("200")))
    h.append(HpackHeader(String("content-type"), String("application/grpc")))
    _headers(hpack, h^, False, out)


def _status_trailers(
    mut hpack: HpackEncoder,
    status: String,
    message: String,
    mut out: List[UInt8],
):
    """A trailers block ending the stream: `grpc-status` (+ `grpc-message`
    when `message` is not empty)."""
    var t = List[HpackHeader]()
    t.append(HpackHeader(String("grpc-status"), status))
    if message.byte_length() > 0:
        t.append(HpackHeader(String("grpc-message"), message))
    _headers(hpack, t^, True, out)


def _client(
    var script: List[UInt8], pending_after_script: Int = 0
) -> FirestoreListenClient[ScriptedStream]:
    """A client over `script`. `pending_after_script` > 0 holds the
    connection open (reads answer Pending) that many times after the script
    instead of reading EOF, so an end can only come from the script itself."""
    var shared = ArcPointer[List[UInt8]](List[UInt8]())
    var stream = ScriptedStream.from_read_script_with_capture(script^, shared)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    if pending_after_script > 0:
        stream.set_pending_after_script(pending_after_script)
    return FirestoreListenClient[ScriptedStream](
        stream^, String("firestore.googleapis.com"), String("fake-token")
    )


def _open(
    mut client: FirestoreListenClient[ScriptedStream],
    mut reactor: Reactor[NoopSink],
) raises:
    var docs = List[String]()
    docs.append(String("projects/p/databases/d/documents/c/doc0"))
    client.open[_RT](reactor, String("projects/p/databases/d"), docs, 7)


def _open_error(var script: List[UInt8]) raises -> String:
    """Open a client over `script`; the raised text, or "" if open returned."""
    var reactor = _make_reactor()
    var client = _client(script^)
    try:
        _open(client, reactor)
    except e:
        return String(e)
    return String("")


def _poll_to_end(
    mut client: FirestoreListenClient[ScriptedStream],
    mut reactor: Reactor[NoopSink],
) raises -> Int:
    """Poll until the client reports the stream ended; the event count."""
    var n = 0
    for _ in range(64):
        var events = client.poll_progress[_RT](reactor, max_wall_us=2_000_000)
        n += len(events)
        if client.last_poll_ended():
            return n
    raise Error("the stream never ended")


def _run_to_end(var script: List[UInt8]) raises -> FirestoreListenClient[
    ScriptedStream
]:
    """Open over `script`, poll to the end, and hand the ended client back."""
    var reactor = _make_reactor()
    var client = _client(script^)
    _open(client, reactor)
    _ = _poll_to_end(client, reactor)
    return client^


# -----------------------------------------------------------------------------
# open: a failed Listen is raised, not opened.
# -----------------------------------------------------------------------------


def test_open_trailers_only_failure_raises() raises:
    """Firestore's own answer to a Listen without its routing header: one
    HEADERS frame, `:status 200`, `grpc-status: 3`, END_STREAM."""
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    var h = List[HpackHeader]()
    h.append(HpackHeader(String(":status"), String("200")))
    h.append(HpackHeader(String("content-type"), String("application/grpc")))
    h.append(HpackHeader(String("grpc-status"), String("3")))
    h.append(
        HpackHeader(
            String("grpc-message"),
            String("Missing%20required%20http%20header%20%28%27database%27%29"),
        )
    )
    _headers(hpack, h^, True, out)
    var err = _open_error(out^)
    assert_true(
        err.startswith(String("[grpc:3] ")),
        String("open read a trailers-only grpc-status 3 as an open stream: '")
        + err + "'",
    )
    assert_true(
        String("Missing required http header ('database')") in err,
        String("grpc-message was not percent-decoded: '") + err + "'",
    )


def test_open_http_503_raises_unavailable() raises:
    """An edge proxy's 503 page: no grpc-status, so the spec's table says
    UNAVAILABLE, and the HTTP status stays in the message."""
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    var h = List[HpackHeader]()
    h.append(HpackHeader(String(":status"), String("503")))
    h.append(HpackHeader(String("content-type"), String("text/html")))
    _headers(hpack, h^, False, out)
    var page = List[UInt8](String("<html>busy</html>").as_bytes())
    encode_data_frame(_SID, page^, end_stream=True, out=out)
    var err = _open_error(out^)
    assert_true(
        err.startswith(String("[grpc:14] ")),
        String("open accepted :status 503: '") + err + "'",
    )
    assert_true(String("status=503") in err, err)


# -----------------------------------------------------------------------------
# End of an open stream: the terminal status the client records.
# -----------------------------------------------------------------------------


def test_end_on_trailers_with_a_non_ok_status() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    _status_trailers(hpack, String("7"), String("caf%C3%A9%20denied"), out)
    var reactor = _make_reactor()
    var client = _client(out^)
    _open(client, reactor)
    var n = _poll_to_end(client, reactor)
    assert_equal(n, 1, "the message before the trailers was not delivered")
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_PERMISSION_DENIED))
    assert_equal(client.terminal_message(), String("café denied"))
    assert_true(
        client.terminal_error_text().startswith(String("[grpc:7] ")),
        client.terminal_error_text(),
    )


def test_end_on_data_without_trailers_is_internal() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=True, out=out)
    var client = _run_to_end(out^)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_INTERNAL))
    assert_true(
        String("missing grpc-status") in client.terminal_message(),
        client.terminal_message(),
    )


def test_trailers_without_a_status_are_unknown() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    var t = List[HpackHeader]()
    t.append(HpackHeader(String("x-trailer"), String("1")))
    _headers(hpack, t^, True, out)
    var client = _run_to_end(out^)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_UNKNOWN))
    assert_true(
        String("missing grpc-status") in client.terminal_message(),
        client.terminal_message(),
    )


def test_rst_stream_ends_the_stream_as_cancelled() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    encode_rst_stream_frame(_SID, H2_ERR_CANCEL, out)
    # The connection stays open after the RST (no EOF for a million reads),
    # so only the RST can end the stream within these few polls. A loop that
    # ignored the reset would time out every poll and never end.
    var reactor = _make_reactor()
    var client = _client(out^, pending_after_script=1_000_000)
    _open(client, reactor)
    var ended = False
    for _ in range(3):
        _ = client.poll_progress[_RT](reactor, max_wall_us=500_000)
        if client.last_poll_ended():
            ended = True
            break
    assert_true(ended, "a reset Listen stream did not end the receive loop")
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_CANCELLED))
    assert_true(
        String("RST_STREAM") in client.terminal_message(),
        client.terminal_message(),
    )


def test_goaway_excluding_the_stream_is_unavailable() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    var debug = List[UInt8](String("max_age").as_bytes())
    encode_goaway_frame(UInt32(0), H2_ERR_NO_ERROR, debug^, out)
    # Held open after the GOAWAY: only the GOAWAY can end the stream.
    var client = _held_open_to_end(out^)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_UNAVAILABLE))
    assert_true(
        String("sent GOAWAY excluding") in client.terminal_message(),
        client.terminal_message(),
    )
    assert_true(
        String("goaway_debug='max_age'") in client.terminal_message(),
        client.terminal_message(),
    )


def test_close_after_a_goaway_that_kept_the_stream() raises:
    """GOAWAY(last=1) keeps stream 1; the connection then closes."""
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    var debug = List[UInt8](String("drain").as_bytes())
    encode_goaway_frame(_SID, H2_ERR_NO_ERROR, debug^, out)
    var client = _run_to_end(out^)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_UNAVAILABLE))
    assert_true(
        String("connection closed") in client.terminal_message(),
        client.terminal_message(),
    )
    assert_true(
        String("goaway_debug='drain'") in client.terminal_message(),
        client.terminal_message(),
    )


def test_connection_close_without_end_stream_is_unavailable() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    var client = _run_to_end(out^)  # the script then reads EOF
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_UNAVAILABLE))
    assert_true(
        String("connection closed") in client.terminal_message(),
        client.terminal_message(),
    )


def test_partial_message_before_an_ok_status_is_internal() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    var env = _target_change_envelope()
    var part = List[UInt8]()
    for i in range(len(env) - 2):  # all but the last two payload bytes
        part.append(env[i])
    encode_data_frame(_SID, part^, end_stream=False, out=out)
    _status_trailers(hpack, String("0"), String(""), out)
    var client = _run_to_end(out^)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_INTERNAL))
    assert_true(
        String("truncated") in client.terminal_message(),
        client.terminal_message(),
    )


def test_clean_ok_end_is_ok() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    _status_trailers(hpack, String("0"), String(""), out)
    var reactor = _make_reactor()
    var client = _client(out^)
    _open(client, reactor)
    _ = _poll_to_end(client, reactor)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_OK))
    # A poll after the end keeps the status it recorded.
    _ = client.poll_progress[_RT](reactor, max_wall_us=500_000)
    assert_true(client.last_poll_ended())
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_OK))


def test_non_ascii_grpc_message_does_not_abort() raises:
    """Raw UTF-8 and an invalid byte in `grpc-message` (the bytes #443 was
    about): the status still reads, and nothing indexes a String by byte."""
    var raw = List[UInt8](String("caf").as_bytes())
    raw.append(UInt8(0xC3))
    raw.append(UInt8(0xA9))
    raw.append(UInt8(0x20))
    raw.append(UInt8(0xFF))
    raw.append(UInt8(0x80))
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    _status_trailers(
        hpack, String("5"), String(unsafe_from_utf8=Span(raw)), out
    )
    var client = _run_to_end(out^)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_NOT_FOUND))
    assert_true(client.terminal_message().byte_length() > 0)


def _held_open_to_end(var script: List[UInt8]) raises -> FirestoreListenClient[
    ScriptedStream
]:
    """Open over `script` with the connection held open after it (Pending, not
    EOF), and poll at most three times: only the script can end the stream."""
    var reactor = _make_reactor()
    var client = _client(script^, pending_after_script=1_000_000)
    _open(client, reactor)
    for _ in range(3):
        _ = client.poll_progress[_RT](reactor, max_wall_us=500_000)
        if client.last_poll_ended():
            return client^
    raise Error("the stream did not end while the connection stayed open")


def _open_error_and_code(
    var script: List[UInt8], pending_after_script: Int = 0
) raises -> Tuple[String, Int]:
    """Open over `script`: the raised text ("" if open returned) and the
    client's terminal code after it."""
    var reactor = _make_reactor()
    var client = _client(script^, pending_after_script=pending_after_script)
    var err = String("")
    try:
        _open(client, reactor)
    except e:
        err = String(e)
    return (err, client.terminal_code())


def test_rst_enhance_your_calm_is_resource_exhausted() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    encode_rst_stream_frame(_SID, H2_ERR_ENHANCE_YOUR_CALM, out)
    var client = _held_open_to_end(out^)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_RESOURCE_EXHAUSTED))
    assert_true(
        String("RST_STREAM(11)") in client.terminal_message(),
        client.terminal_message(),
    )


def test_refused_before_the_head_raises_and_keeps_the_status() raises:
    var out = List[UInt8]()
    _settings(out)
    encode_rst_stream_frame(_SID, H2_ERR_REFUSED_STREAM, out)
    var r = _open_error_and_code(out^, pending_after_script=1_000_000)
    assert_true(
        String("stream ended before response head: [grpc:14] ") in r[0], r[0]
    )
    assert_true(String("RST_STREAM(7)") in r[0], r[0])
    assert_equal(r[1], Int(GRPC_STATUS_UNAVAILABLE))


def test_data_before_the_head_is_refused_as_internal() raises:
    """DATA before any HEADERS is malformed (RFC 9113 §8.1); h2_client
    refuses it with its own RST_STREAM(PROTOCOL_ERROR) and records no reset
    code, only the malformation."""
    var out = List[UInt8]()
    _settings(out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    var r = _open_error_and_code(out^, pending_after_script=1_000_000)
    assert_true(String("[grpc:13] ") in r[0], r[0])
    assert_true(String("malformed") in r[0], r[0])
    assert_equal(r[1], Int(GRPC_STATUS_INTERNAL))


def test_trailers_without_end_stream_are_refused_as_internal() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, _target_change_envelope(), end_stream=False, out=out)
    var t = List[HpackHeader]()
    t.append(HpackHeader(String("grpc-status"), String("0")))
    _headers(hpack, t^, False, out)  # a trailer section must end the stream
    var client = _held_open_to_end(out^)
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_INTERNAL))
    assert_true(
        String("malformed") in client.terminal_message(),
        client.terminal_message(),
    )


def test_open_trailers_only_ok_does_not_raise() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    var h = List[HpackHeader]()
    h.append(HpackHeader(String(":status"), String("200")))
    h.append(HpackHeader(String("content-type"), String("application/grpc")))
    h.append(HpackHeader(String("grpc-status"), String("0")))
    _headers(hpack, h^, True, out)
    var reactor = _make_reactor()
    var client = _client(out^)
    _open(client, reactor)  # an OK answer is not a failure
    assert_equal(client.terminal_code(), Int(GRPC_STATUS_OK))
    var events = client.poll_progress[_RT](reactor, max_wall_us=500_000)
    assert_equal(len(events), 0)
    assert_true(client.last_poll_ended())


def test_open_trailers_only_without_a_status_is_unknown() raises:
    """`:status 200` + END_STREAM in one HEADERS, no grpc-status: UNKNOWN."""
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    var h = List[HpackHeader]()
    h.append(HpackHeader(String(":status"), String("200")))
    h.append(HpackHeader(String("content-type"), String("application/grpc")))
    _headers(hpack, h^, True, out)
    var r = _open_error_and_code(out^)
    assert_true(r[0].startswith(String("[grpc:2] ")), r[0])
    assert_true(String("missing grpc-status") in r[0], r[0])
    assert_equal(r[1], Int(GRPC_STATUS_UNKNOWN))


def test_open_head_then_empty_end_is_unknown() raises:
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    _grpc_head(hpack, out)
    encode_data_frame(_SID, List[UInt8](), end_stream=True, out=out)
    var r = _open_error_and_code(out^)
    assert_true(r[0].startswith(String("[grpc:2] ")), r[0])
    assert_true(String("missing grpc-status") in r[0], r[0])
    assert_equal(r[1], Int(GRPC_STATUS_UNKNOWN))


def test_open_http_503_keeps_the_status() raises:
    """A non-200 head on a stream still open: open raises, and the client's
    terminal status says the same thing."""
    var out = List[UInt8]()
    var hpack = HpackEncoder(max_table_size=4096)
    _settings(out)
    var h = List[HpackHeader]()
    h.append(HpackHeader(String(":status"), String("503")))
    h.append(HpackHeader(String("content-type"), String("text/html")))
    _headers(hpack, h^, False, out)
    var r = _open_error_and_code(out^, pending_after_script=1_000_000)
    assert_true(r[0].startswith(String("[grpc:14] ")), r[0])
    assert_equal(r[1], Int(GRPC_STATUS_UNAVAILABLE))


def main() raises:
    print("test_firestore_listen_terminal_status")
    test_open_trailers_only_failure_raises()
    test_open_http_503_raises_unavailable()
    test_end_on_trailers_with_a_non_ok_status()
    test_end_on_data_without_trailers_is_internal()
    test_trailers_without_a_status_are_unknown()
    test_rst_stream_ends_the_stream_as_cancelled()
    test_goaway_excluding_the_stream_is_unavailable()
    test_connection_close_without_end_stream_is_unavailable()
    test_partial_message_before_an_ok_status_is_internal()
    test_clean_ok_end_is_ok()
    test_non_ascii_grpc_message_does_not_abort()
    test_close_after_a_goaway_that_kept_the_stream()
    test_rst_enhance_your_calm_is_resource_exhausted()
    test_refused_before_the_head_raises_and_keeps_the_status()
    test_data_before_the_head_is_refused_as_internal()
    test_trailers_without_end_stream_are_refused_as_internal()
    test_open_trailers_only_ok_does_not_raise()
    test_open_trailers_only_without_a_status_is_unknown()
    test_open_head_then_empty_end_is_unknown()
    test_open_http_503_keeps_the_status()
    print("ALL PASS")
