# =============================================================================
# test_cov_dispatch_round_parks.mojo: `serve_read_round_dispatch` writing a
# refusal or an interim into a full socket
# =============================================================================
#
# The round runs against a plain `ConnEntry` on one end of an AF_UNIX
# socketpair in this process. Before the request is sent, the server's end
# is filled with '.' bytes until the kernel answers EAGAIN; the client never
# reads them, and on a socketpair nothing frees that space but a read, so
# the round's next write parks for certain.
#
# Groups (and the defect each would catch):
#   P  a 400 for a malformed head, a 417 for a refused expectation, a 400
#      for bad chunk framing and an interim 100 Continue that cannot be
#      written now: not parked (lost, or the connection dropped), parked
#      with the wrong bytes, the round not reporting the connection alive,
#      or a refused request dispatched.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.completion_queue import (
    INTEREST_READ,
    RegistrationHandle,
)
from komira_async.reactor.reactor import Reactor
from komira_async.reactor.socket_io import try_io_write
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.tcp_stream import TcpStream
from komira_http_core.codec import HttpRequest, HttpResponse
from komira_http_core.codec.h1.limits import ParseLimits
from komira_http_core.codec.h1.parser import (
    build_100_continue_bytes,
    build_error_response_bytes,
)
from komira_http_server.connection import (
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    REQ_BUF_BYTES,
)
from komira_http_server.dispatch import (
    RequestDispatcher,
    serve_read_round_dispatch,
)

comptime _Rt = BlockingRuntime[NoopSink]


struct _Counting(RequestDispatcher):
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        self.calls += 1
        return HttpResponse.ok(String("ok"))


def _socketpair() raises -> Array[Int32, 2]:
    var pair = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: `pair` is a stack local that outlives the call; socketpair(2)
    # writes two ints into it and retains nothing.
    var rc = external_call["socketpair", Int32](
        Int32(1), Int32(1), Int32(0), pair.unsafe_ptr()
    )
    if rc < 0:
        raise Error("socketpair(AF_UNIX, SOCK_STREAM) failed")
    for i in range(2):
        if external_call["komira_fcntl_set_nonblock", Int32](pair[i]) < 0:
            raise Error("set_nonblock failed")
    return pair^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _text(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _parked_after(request: String, expect_continue: Bool) raises -> Tuple[String, Int]:
    """Fill the server end, send `request`, run one round; return the parked
    bytes and the dispatcher's call count. The round must keep the
    connection and leave it waiting to write."""
    var fds = _socketpair()
    var entry = ConnEntry(
        stream=TcpStream(fds[0]),
        reg=RegistrationHandle(_fd=fds[0], _interest_set=INTEREST_READ),
    )
    var junk = List[UInt8](length=512, fill=UInt8(0x2E))
    var filled = False
    for _ in range(100000):
        var r = try_io_write(fds[0], Span(junk))
        if r.is_would_block():
            filled = True
            break
        if not r.is_ready():
            raise Error("the fill failed")
    assert_true(filled, "the socket never filled")
    var req = _bytes(request)
    var rc = external_call["send", Int64](
        fds[1], req.unsafe_ptr(), UInt64(len(req)), Int32(0)
    )
    assert_equal(Int(rc), len(req))
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var io = Array[UInt8, REQ_BUF_BYTES](fill=UInt8(0))
    var d = _Counting()
    var reqs = Int64(0)
    var sent = Int64(0)
    var alive = serve_read_round_dispatch[_Counting, _Rt](
        entry,
        reactor,
        io,
        ParseLimits.defaults(),
        expect_continue,
        d,
        reqs,
        sent,
        String(""),
    )
    assert_true(alive, "the round dropped a connection whose write parked")
    assert_equal(entry._state, CONN_STATE_WAITING_FOR_WRITABLE)
    assert_equal(sent, Int64(0), "a parked write was counted as sent")
    var parked = List[UInt8]()
    for i in range(entry._pending_len):
        parked.append(entry._pending_buf[entry._pending_off + i])
    _ = external_call["close", Int32](fds[1])
    _ = entry^
    return (_text(parked), d.calls)


def _error(status: Int) -> String:
    var b = List[UInt8]()
    build_error_response_bytes(UInt16(status), b)
    return _text(b)


def test_malformed_head_parks_its_400() raises:
    """RFC 9112 section 5.1: whitespace before a field's colon is a 400."""
    var r = _parked_after(
        "GET / HTTP/1.1\r\nHost: example.com\r\nAccept : x\r\n\r\n", True
    )
    assert_equal(r[0], _error(400))
    assert_equal(r[1], 0)


def test_refused_expectation_parks_its_417() raises:
    var r = _parked_after(
        "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
        "Content-Length: 5\r\n\r\nhello",
        False,
    )
    assert_equal(r[0], _error(417))
    assert_equal(r[1], 0)


def test_bad_chunk_framing_parks_its_400() raises:
    var r = _parked_after(
        "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked"
        "\r\n\r\nzz\r\nnope\r\n0\r\n\r\n",
        True,
    )
    assert_equal(r[0], _error(400))
    assert_equal(r[1], 0)


def test_interim_continue_parks() raises:
    """Only the interim's own parking is asserted: what becomes of the
    request behind it is the dispatch half of komira-ai/komira#947."""
    var r = _parked_after(
        "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n"
        "Content-Length: 5\r\n\r\nhello",
        True,
    )
    var want = List[UInt8]()
    build_100_continue_bytes(want)
    assert_equal(r[0], _text(want))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
