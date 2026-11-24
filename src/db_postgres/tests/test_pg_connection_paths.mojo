"""db_postgres.wire: the PgConnection and PgReactorStream paths a server
reply decides, driven with no database server.

A loopback TCP connection on a kernel-chosen port (port 0) carries a real
TLS 1.3 session: the server end is an in-process s2n connection holding
http_core's throwaway leaf certificate, the client end is the PgReactorStream
a PgConnection owns. The server writes a whole reply up
front; the call under test reads it through a BlockingRuntime reactor exactly
as it would read a real server's reply.

What each test holds:

  1. PreparedStatement.result_column_name returns each column's name and
     refuses an index below 0 or at the column count.
  2. prepare() over ParseComplete, ParameterDescription, RowDescription, a
     NoticeResponse and ReadyForQuery returns the statement's parameter OIDs,
     result OIDs and column names, and skips the notice.
  3. query_prepared() sends a Bind whose parameters are binary, a NULL as
     length -1, and returns the rows decoded with the RowDescription the
     server sent, which replaces the statement's own columns; a notice in the
     reply is skipped.
  4. prepare() and query_prepared() on a closed connection raise "connection
     is closed"; query_prepared() with a parameter count other than the
     statement's raises and sends nothing, so the connection stays usable.
  5. A reply larger than one read (rows spread over many TLS records, and one
     row larger than 64 KiB) comes back byte for byte.
  6. A server that sends half a message and then close_notify makes the call
     raise "connection closed by peer (EOF)".
  7. An ErrorResponse while draining to ReadyForQuery raises the second
     error. The drain reads at most 4096 messages: a ReadyForQuery as the
     4096th ends it (the call raises the server's error and the connection
     reads its next result); one after 4096 notices is never read, and the
     call raises "did not reach ReadyForQuery".
  8. PgReactorStream: send_all after close() raises the TLS error. The
     bounded retry loops give up with their named errors instead of spinning
     forever: send_all whose socket never drains raises "could not flush all
     bytes", and recv_some that never gets a byte raises "spun without
     progress". Each round parks the stream's own fd on the reactor; here that
     fd is either a socket whose peer is gone (the park returns at once: it
     is readable at EOF and writable) or -1 (the park returns without waiting), so the loop runs out.
"""

from std.ffi import external_call
from std.pathlib import Path
from std.testing import assert_equal, assert_true, assert_false

from async_rt.ops.waker_sink import NoopSink
from async_rt.runtime.blocking_runtime import BlockingRuntime
from async_rt.reactor.socket_setup import close_fd, set_so_rcvbuf, set_so_sndbuf
from async_rt.runtime.tcp_stream import TcpListener, TcpStream
from http_core.tls import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)

from db_postgres.wire.connection import PgConnection, PreparedStatement
from db_postgres.wire.pg_tls import PgReactorStream
from db_postgres.wire.pg_types import OID_INT4, OID_TEXT, PgValue
from db_postgres.wire.pgwire import (
    put_i16_be,
    put_i32_be,
    MSG_BIND_COMPLETE,
    MSG_CMD_COMPLETE,
    MSG_DATA_ROW,
    MSG_ERROR,
    MSG_NOTICE,
    MSG_PARAM_DESC,
    MSG_PARSE_COMPLETE,
    MSG_READY,
    MSG_ROW_DESC,
)

comptime BRT = BlockingRuntime[NoopSink]


# -----------------------------------------------------------------------------
# Fixtures + libc helpers
# -----------------------------------------------------------------------------
def _leaf_cert() raises -> String:
    return Path("src/http_core/tests/fixtures/tls/leaf_cert.pem").read_text()


def _leaf_key() raises -> String:
    return Path("src/http_core/tests/fixtures/tls/leaf_key.pem").read_text()


def _tcp_pair() raises -> Tuple[Int32, Int32]:
    """A connected loopback TCP pair on a kernel-chosen port (port 0), both
    ends non-blocking: (accepted end, connecting end). The caller owns and
    closes both fds."""
    var rt = BRT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var listener = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(1))
    var client = TcpStream.connect_loopback[NoopSink](
        reactor, listener.local_port()
    )
    var server = listener.accept[NoopSink](reactor)
    var pair = (server.release_fd(), client.release_fd())
    _ = rt^
    return pair


def _gone_peer_fd() raises -> Int32:
    """One end of a loopback TCP pair whose other end is closed: always
    readable (EOF) and writable, so a park on it returns at once."""
    var p = _tcp_pair()
    close_fd(p[1])
    return p[0]


def _server_config() raises -> TlsConfig:
    var c = TlsConfig()
    c.load_cert(_leaf_cert(), _leaf_key())
    return c^


def _client_config() raises -> TlsConfig:
    var c = TlsConfig()
    c.wipe_trust()
    c.disable_verify()
    return c^


def _wait_readable(fd_a: Int32, fd_b: Int32) raises:
    """Wait, without a timeout, until `fd_a` or `fd_b` (-1: not watched) is
    readable or has an error. TCP loopback delivers a segment to the peer
    asynchronously to the call that sent it."""
    # Two struct pollfd {int fd; short events; short revents}, as int32 pairs
    # on a little-endian host: the first word is the fd, the second holds
    # events (POLLIN, 1 on Linux and macOS) in its low half and revents (0)
    # in its high half. poll(2) skips an entry with a negative fd.
    var pfd = Array[Int32, 4](fill=Int32(0))
    pfd[0] = fd_a
    pfd[1] = Int32(1)
    pfd[2] = fd_b
    pfd[3] = Int32(1)
    # SAFETY: the pointer's origin is `pfd`, two struct pollfd on the stack
    # alive across the synchronous call, which writes only their revents and
    # keeps no pointer.
    if external_call["poll", Int32](pfd.unsafe_ptr(), UInt64(2), Int32(-1)) < 1:
        raise Error("poll() did not report a socket ready")


def _handshake(mut server: TlsConnection, mut client: TlsConnection) raises:
    """Alternate the two handshakes until both are DONE. A side blocked on
    read waits in poll for the peer's flight, so 256 rounds bounds protocol
    steps, not how fast loopback delivers."""
    var sv_done = False
    var cl_done = False
    for _ in range(256):
        var sv_wait = Int32(-1)
        var cl_wait = Int32(-1)
        if not sv_done:
            var o = server.handshake()
            assert_true(
                o != TLS_OUTCOME_ERROR,
                "server handshake: " + s2n_strerror_message(last_s2n_errno()),
            )
            sv_done = o == TLS_OUTCOME_DONE
            if o == TLS_OUTCOME_BLOCKED_ON_READ:
                sv_wait = server.fd()
        if not cl_done:
            var o = client.handshake()
            assert_true(
                o != TLS_OUTCOME_ERROR,
                "client handshake: " + s2n_strerror_message(last_s2n_errno()),
            )
            cl_done = o == TLS_OUTCOME_DONE
            if o == TLS_OUTCOME_BLOCKED_ON_READ:
                cl_wait = client.fd()
        if sv_done and cl_done:
            return
        if (sv_done or sv_wait >= 0) and (cl_done or cl_wait >= 0):
            _wait_readable(sv_wait, cl_wait)
    assert_true(False, "handshake did not finish in 256 rounds")


def _server_send(mut server: TlsConnection, data: List[UInt8]) raises:
    """Send all of `data`; the socket buffer takes every reply here whole."""
    var off = 0
    for _ in range(256):
        if off == len(data):
            return
        var res = server.send(Span[UInt8](data)[off : len(data)])
        assert_true(
            res[0] != TLS_OUTCOME_ERROR,
            "server send: " + s2n_strerror_message(last_s2n_errno()),
        )
        if res[1] > 0:
            off += res[1]
    assert_equal(off, len(data), "server send did not finish")


def _server_recv_all(mut server: TlsConnection) raises -> List[UInt8]:
    """Every plaintext byte the client has sent so far."""
    var out = List[UInt8]()
    for _ in range(4096):
        var buf = List[UInt8](capacity=65536)
        var res = server.recv(buf, 65536)
        if res[0] != TLS_OUTCOME_DONE or res[1] <= 0:
            return out^
        for i in range(res[1]):
            out.append(buf[i])
    return out^


# -----------------------------------------------------------------------------
# Backend message builders
# -----------------------------------------------------------------------------
def _ascii(mut out: List[UInt8], s: String):
    for c in s.as_bytes():
        out.append(c)


def _put_msg(mut out: List[UInt8], t: UInt8, body: List[UInt8]):
    out.append(t)
    put_i32_be(out, Int32(len(body) + 4))
    for b in body:
        out.append(b)


def _put_field(mut b: List[UInt8], name: String, oid: UInt32):
    _ascii(b, name)
    b.append(UInt8(0))
    put_i32_be(b, Int32(0))  # table OID
    put_i16_be(b, Int16(0))  # attnum
    put_i32_be(b, Int32(oid))  # type OID
    put_i16_be(b, Int16(-1))  # type size
    put_i32_be(b, Int32(-1))  # type modifier
    put_i16_be(b, Int16(1))  # format code: binary


def _row_desc(names: List[String], oids: List[UInt32]) -> List[UInt8]:
    var b = List[UInt8]()
    put_i16_be(b, Int16(len(names)))
    for i in range(len(names)):
        _put_field(b, names[i], oids[i])
    return b^


def _row_desc_one_text(name: String) -> List[UInt8]:
    var names = List[String]()
    names.append(name)
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    return _row_desc(names, oids)


def _param_desc(oids: List[UInt32]) -> List[UInt8]:
    var b = List[UInt8]()
    put_i16_be(b, Int16(len(oids)))
    for o in oids:
        put_i32_be(b, Int32(o))
    return b^


def _data_row_text(value: String) -> List[UInt8]:
    var b = List[UInt8]()
    put_i16_be(b, Int16(1))
    put_i32_be(b, Int32(len(value.as_bytes())))
    _ascii(b, value)
    return b^


def _data_row_int4_text(n: Int32, s: String) -> List[UInt8]:
    """Two binary columns: INT4 `n`, TEXT `s`."""
    var b = List[UInt8]()
    put_i16_be(b, Int16(2))
    put_i32_be(b, Int32(4))
    put_i32_be(b, n)
    put_i32_be(b, Int32(len(s.as_bytes())))
    _ascii(b, s)
    return b^


def _cmd_complete(tag: String) -> List[UInt8]:
    var b = List[UInt8]()
    _ascii(b, tag)
    b.append(UInt8(0))
    return b^


def _ready() -> List[UInt8]:
    var b = List[UInt8]()
    b.append(UInt8(ord("I")))
    return b^


def _empty() -> List[UInt8]:
    return List[UInt8]()


def _notice() -> List[UInt8]:
    """S NOTICE, M hello: a NoticeResponse the client skips."""
    var b = List[UInt8]()
    b.append(UInt8(ord("S")))
    _ascii(b, String("NOTICE"))
    b.append(UInt8(0))
    b.append(UInt8(ord("M")))
    _ascii(b, String("hello"))
    b.append(UInt8(0))
    b.append(UInt8(0))
    return b^


def _error_response(code: String, message: String) -> List[UInt8]:
    var b = List[UInt8]()
    b.append(UInt8(ord("S")))
    _ascii(b, String("ERROR"))
    b.append(UInt8(0))
    b.append(UInt8(ord("C")))
    _ascii(b, code)
    b.append(UInt8(0))
    b.append(UInt8(ord("M")))
    _ascii(b, message)
    b.append(UInt8(0))
    b.append(UInt8(0))
    return b^


def _stmt_one_text_column() -> PreparedStatement:
    """A statement with no parameters and one TEXT result column "a"."""
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(1)
    var name_bytes = List[UInt8]()
    name_bytes.append(UInt8(ord("a")))
    return PreparedStatement(
        String("s"), List[UInt32](), oids^, name_bytes^, offsets^
    )


def _stmt_two_params() -> PreparedStatement:
    """A statement named "s2" taking (INT4, TEXT), one TEXT result column."""
    var params = List[UInt32]()
    params.append(OID_INT4)
    params.append(OID_TEXT)
    var oids = List[UInt32]()
    oids.append(OID_TEXT)
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(1)
    var name_bytes = List[UInt8]()
    name_bytes.append(UInt8(ord("x")))
    return PreparedStatement(
        String("s2"), params^, oids^, name_bytes^, offsets^
    )


def _two_params() -> List[PgValue]:
    var p = List[PgValue]()
    p.append(PgValue(OID_INT4, False, String("7")))
    p.append(PgValue(OID_TEXT, True, String("")))
    return p^


# -----------------------------------------------------------------------------
# Rigs: a handshaken TLS session over loopback TCP, the server half kept here
# -----------------------------------------------------------------------------
struct _PgRig(Movable):
    """The server half of one in-process TLS session, and a PgConnection
    owning the client half (its TcpStream owns the client fd)."""

    var server_config: TlsConfig
    var server: TlsConnection
    var server_fd: Int32
    var conn: PgConnection

    def __init__(out self) raises:
        tls_init()
        var fds = _tcp_pair()
        var server_config = _server_config()
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client_config = _client_config()
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        _handshake(server, client)
        self.conn = PgConnection(
            PgReactorStream(client_config^, client^, TcpStream(fds[1]))
        )
        self.server_config = server_config^
        self.server = server^
        self.server_fd = fds[0]


struct _StreamRig(Movable):
    """The server half of one in-process TLS session, and a PgReactorStream
    whose TLS connection is bound to the client fd while its TcpStream (the fd
    a park waits on) holds `park_fd`. The client fd is closed by the test."""

    var server_config: TlsConfig
    var server: TlsConnection
    var server_fd: Int32
    var client_fd: Int32
    var stream: PgReactorStream

    def __init__(out self, park_fd: Int32) raises:
        tls_init()
        var fds = _tcp_pair()
        var server_config = _server_config()
        var server = TlsConnection(server_config)
        server.bind_fd(fds[0])
        var client_config = _client_config()
        var client = TlsConnection.new_client(client_config)
        client.bind_fd(fds[1])
        client.set_server_name(String("localhost"))
        _handshake(server, client)
        self.stream = PgReactorStream(
            client_config^, client^, TcpStream(park_fd)
        )
        self.server_config = server_config^
        self.server = server^
        self.server_fd = fds[0]
        self.client_fd = fds[1]


def _done(var rig: _PgRig):
    var fd = rig.server_fd
    rig.conn.close()
    _ = rig^
    close_fd(fd)


def _done_stream(var rig: _StreamRig):
    var sfd = rig.server_fd
    var cfd = rig.client_fd
    _ = rig^
    close_fd(sfd)
    close_fd(cfd)


def _raised_by_query(mut rig: _PgRig, mut rt: BRT) -> String:
    """Run query("SELECT a") and return its error text ("" if none)."""
    ref reactor = rt.reactor()
    try:
        _ = rig.conn.query[BRT](reactor, String("SELECT a"))
    except e:
        return String(e)
    return String("")


def _raised_by_prepare(mut rig: _PgRig, mut rt: BRT) -> String:
    ref reactor = rt.reactor()
    try:
        _ = rig.conn.prepare[BRT](reactor, String("SELECT a"))
    except e:
        return String(e)
    return String("")


def _new_rt() raises -> BRT:
    return BRT.new(NoopSink(_placeholder=UInt8(0)))


# =============================================================================
# 1. PreparedStatement.result_column_name
# =============================================================================
def test_result_column_name_bounds() raises:
    var oids = List[UInt32]()
    oids.append(OID_INT4)
    oids.append(OID_TEXT)
    var data = List[UInt8]()
    _ascii(data, String("idname"))
    var offsets = List[Int]()
    offsets.append(0)
    offsets.append(2)
    offsets.append(6)
    var stmt = PreparedStatement(
        String("s"), List[UInt32](), oids^, data^, offsets^
    )
    assert_equal(stmt.result_column_count(), 2)
    assert_equal(stmt.result_column_name(0), String("id"))
    assert_equal(stmt.result_column_name(1), String("name"))
    for bad in [-1, 2]:
        var raised = String("")
        try:
            _ = stmt.result_column_name(bad)
        except e:
            raised = String(e)
        assert_equal(
            raised,
            String("PreparedStatement: result column index out of range"),
        )
    print("  ok: result_column_name in range and out of range")


# =============================================================================
# 2. prepare() over a well-formed describe reply
# =============================================================================
def test_prepare_reads_params_columns_and_skips_notice() raises:
    var rig = _PgRig()
    var r = List[UInt8]()
    _put_msg(r, MSG_PARSE_COMPLETE, _empty())
    var pd = List[UInt32]()
    pd.append(OID_INT4)
    pd.append(OID_TEXT)
    _put_msg(r, MSG_PARAM_DESC, _param_desc(pd))
    var names = List[String]()
    names.append(String("id"))
    names.append(String("name"))
    _put_msg(r, MSG_ROW_DESC, _row_desc(names, pd))
    _put_msg(r, MSG_NOTICE, _notice())
    _put_msg(r, MSG_READY, _ready())
    _server_send(rig.server, r)

    var rt = _new_rt()
    ref reactor = rt.reactor()
    var stmt = rig.conn.prepare[BRT](reactor, String("SELECT id, name"))
    assert_equal(stmt.param_count(), 2)
    assert_equal(stmt.param_oids[0], OID_INT4)
    assert_equal(stmt.param_oids[1], OID_TEXT)
    assert_equal(stmt.result_column_count(), 2)
    assert_equal(len(stmt.result_oids), 2)
    assert_equal(stmt.result_oids[0], OID_INT4)
    assert_equal(stmt.result_oids[1], OID_TEXT)
    assert_equal(stmt.result_column_name(0), String("id"))
    assert_equal(stmt.result_column_name(1), String("name"))
    assert_false(rig.conn.closed())
    _done(rig^)
    _ = rt^
    print("  ok: prepare returns the described params and columns")


# =============================================================================
# 3. query_prepared(): the Bind it sends, the rows it returns
# =============================================================================
def _i16(b: List[UInt8], at: Int) -> Int:
    return Int(Int16(Int(b[at]) << 8 | Int(b[at + 1])))


def _i32(b: List[UInt8], at: Int) -> Int:
    return Int(
        Int32(
            Int(b[at]) << 24
            | Int(b[at + 1]) << 16
            | Int(b[at + 2]) << 8
            | Int(b[at + 3])
        )
    )


def _bind_params(sent: List[UInt8]) raises -> List[Int]:
    """From the client's bytes, the first message must be a Bind on the
    unnamed portal and statement "s2". Returns [n_formats, format..., n_params,
    then per parameter its length followed by its int4 value when the length
    is 4]."""
    assert_true(len(sent) > 5, "client sent a message")
    assert_equal(sent[0], UInt8(ord("B")), "first message is a Bind")
    var i = 5
    assert_equal(sent[i], UInt8(0), "unnamed portal")
    i += 1
    assert_equal(sent[i], UInt8(ord("s")))
    assert_equal(sent[i + 1], UInt8(ord("2")))
    assert_equal(sent[i + 2], UInt8(0))
    i += 3
    var out = List[Int]()

    var nf = _i16(sent, i)
    out.append(nf)
    i += 2
    for _ in range(nf):
        out.append(_i16(sent, i))
        i += 2
    var np = _i16(sent, i)
    out.append(np)
    i += 2
    for _ in range(np):
        var ln = _i32(sent, i)
        out.append(ln)
        i += 4
        if ln == 4:
            out.append(_i32(sent, i))
        if ln > 0:
            i += ln
    return out^


def test_query_prepared_binds_binary_params_and_uses_row_description() raises:
    var rig = _PgRig()
    var r = List[UInt8]()
    _put_msg(r, MSG_BIND_COMPLETE, _empty())
    var names = List[String]()
    names.append(String("n"))
    names.append(String("t"))
    var oids = List[UInt32]()
    oids.append(OID_INT4)
    oids.append(OID_TEXT)
    _put_msg(r, MSG_ROW_DESC, _row_desc(names, oids))
    _put_msg(r, MSG_DATA_ROW, _data_row_int4_text(Int32(7), String("seven")))
    _put_msg(r, MSG_NOTICE, _notice())
    _put_msg(r, MSG_DATA_ROW, _data_row_int4_text(Int32(-2), String("")))
    _put_msg(r, MSG_CMD_COMPLETE, _cmd_complete(String("SELECT 2")))
    _put_msg(r, MSG_READY, _ready())
    _server_send(rig.server, r)

    var rt = _new_rt()
    ref reactor = rt.reactor()
    var stmt = _stmt_two_params()
    var rows = rig.conn.query_prepared[BRT](reactor, stmt, _two_params())
    assert_equal(rows.__len__(), 2)
    assert_equal(rows.column_name(0), String("n"))
    assert_equal(rows.column_name(1), String("t"))
    assert_equal(Int(rows.row(0).get_int4(0)), 7)
    assert_equal(rows.row(0).get_text(1), String("seven"))
    assert_equal(Int(rows.row(1).get_int4(0)), -2)
    assert_equal(rows.row(1).get_text(1), String(""))
    assert_false(rig.conn.closed())

    # Both parameters binary (format 1); the INT4 as its 4 big-endian bytes,
    # the NULL as length -1 with no bytes.
    var bind = _bind_params(_server_recv_all(rig.server))
    var want = List[Int]()
    want.append(2)  # format codes
    want.append(1)
    want.append(1)
    want.append(2)  # parameters
    want.append(4)  # INT4: length 4, value 7
    want.append(7)
    want.append(-1)  # NULL
    assert_equal(len(bind), len(want), "bind fields")
    for k in range(len(want)):
        assert_equal(bind[k], want[k], "bind field " + String(k))
    _done(rig^)
    _ = rt^
    print("  ok: query_prepared binds binary params and decodes its rows")


def test_query_prepared_keeps_statement_columns_without_row_description() raises:
    """No RowDescription in the reply: the statement's own column "a" names
    the result."""
    var rig = _PgRig()
    var r = List[UInt8]()
    _put_msg(r, MSG_BIND_COMPLETE, _empty())
    _put_msg(r, MSG_DATA_ROW, _data_row_text(String("v")))
    _put_msg(r, MSG_CMD_COMPLETE, _cmd_complete(String("SELECT 1")))
    _put_msg(r, MSG_READY, _ready())
    _server_send(rig.server, r)
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var stmt = _stmt_one_text_column()
    var rows = rig.conn.query_prepared[BRT](reactor, stmt, List[PgValue]())
    assert_equal(rows.__len__(), 1)
    assert_equal(rows.column_name(0), String("a"))
    assert_equal(rows.row(0).get_text(0), String("v"))
    _done(rig^)
    _ = rt^
    print("  ok: query_prepared keeps the statement's columns")


# =============================================================================
# 4. Refusals before anything is sent
# =============================================================================
def test_closed_connection_refuses_prepare_and_query_prepared() raises:
    var rig = _PgRig()
    rig.conn.close()
    assert_true(rig.conn.closed())
    var rt = _new_rt()
    assert_equal(
        _raised_by_prepare(rig, rt),
        String("PgConnection.prepare: connection is closed"),
    )
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = rig.conn.query_prepared[BRT](
            reactor, _stmt_one_text_column(), List[PgValue]()
        )
    except e:
        raised = String(e)
    assert_equal(raised, String("PgConnection: connection is closed"))
    _done(rig^)
    _ = rt^
    print("  ok: a closed connection refuses prepare and query_prepared")


def test_query_prepared_wrong_param_count_sends_nothing() raises:
    var rig = _PgRig()
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var one = List[PgValue]()
    one.append(PgValue(OID_INT4, False, String("1")))
    var raised = String("")
    try:
        _ = rig.conn.query_prepared[BRT](reactor, _stmt_two_params(), one)
    except e:
        raised = String(e)
    assert_equal(
        raised,
        String("PgConnection: prepared statement expects 2 params, got 1"),
    )
    assert_false(rig.conn.closed(), "a refused bind leaves it open")
    assert_equal(len(_server_recv_all(rig.server)), 0, "nothing was sent")

    # The connection is still in step: a query reads its own reply.
    var r = List[UInt8]()
    _put_msg(r, MSG_ROW_DESC, _row_desc_one_text(String("a")))
    _put_msg(r, MSG_DATA_ROW, _data_row_text(String("after")))
    _put_msg(r, MSG_CMD_COMPLETE, _cmd_complete(String("SELECT 1")))
    _put_msg(r, MSG_READY, _ready())
    _server_send(rig.server, r)
    var rows = rig.conn.query[BRT](reactor, String("SELECT a"))
    assert_equal(rows.__len__(), 1)
    assert_equal(rows.row(0).get_text(0), String("after"))
    _done(rig^)
    _ = rt^
    print("  ok: a wrong parameter count is refused before sending")


# =============================================================================
# 5. A reply larger than one read
# =============================================================================
def test_large_reply_arrives_intact() raises:
    """40 rows of 1000 bytes (spread over several TLS records, so a message
    straddles a read), then one 70000-byte row and one more short row: the
    long row and the row after it are read together, past 64 KiB."""
    var rig = _PgRig()
    var r = List[UInt8]()
    _put_msg(r, MSG_ROW_DESC, _row_desc_one_text(String("a")))
    for k in range(40):
        var v = String("")
        for _ in range(1000):
            v += String(chr(ord("a") + k % 26))
        _put_msg(r, MSG_DATA_ROW, _data_row_text(v))
    var big = String("")
    for k in range(70000):
        big += String(chr(ord("0") + k % 10))
    _put_msg(r, MSG_DATA_ROW, _data_row_text(big))
    _put_msg(r, MSG_DATA_ROW, _data_row_text(String("tail")))
    _put_msg(r, MSG_CMD_COMPLETE, _cmd_complete(String("SELECT 42")))
    _put_msg(r, MSG_READY, _ready())
    _server_send(rig.server, r)

    var rt = _new_rt()
    ref reactor = rt.reactor()
    var rows = rig.conn.query[BRT](reactor, String("SELECT a"))
    assert_equal(rows.__len__(), 42)
    for k in range(40):
        var got = rows.row(k).get_text(0)
        assert_equal(len(got.as_bytes()), 1000, "row " + String(k))
        var want = UInt8(ord("a") + k % 26)
        for b in got.as_bytes():
            assert_equal(b, want, "row " + String(k))
    assert_equal(rows.row(40).get_text(0), big)
    assert_equal(rows.row(41).get_text(0), String("tail"))
    assert_false(rig.conn.closed())
    _done(rig^)
    _ = rt^
    print("  ok: a reply larger than one read arrives intact")


# =============================================================================
# 6. The server closes mid-message
# =============================================================================
def test_close_notify_mid_message_raises_eof() raises:
    var rig = _PgRig()
    var r = List[UInt8]()
    _put_msg(r, MSG_ROW_DESC, _row_desc_one_text(String("a")))
    var half = List[UInt8]()
    _put_msg(half, MSG_DATA_ROW, _data_row_text(String("cut short")))
    for i in range(len(half) // 2):
        r.append(half[i])
    _server_send(rig.server, r)
    _ = rig.server.shutdown()  # close_notify; the client never answers it
    var rt = _new_rt()
    assert_equal(
        _raised_by_query(rig, rt),
        String(
            "PgConnection: connection closed by peer (EOF) while awaiting a"
            " message"
        ),
    )
    _done(rig^)
    _ = rt^
    print("  ok: close_notify mid-message raises EOF")


# =============================================================================
# 7. Draining to ReadyForQuery after an ErrorResponse
# =============================================================================
def test_error_while_draining_raises_the_second_error() raises:
    var rig = _PgRig()
    var r = List[UInt8]()
    _put_msg(
        r, MSG_ERROR, _error_response(String("42P01"), String("first"))
    )
    _put_msg(
        r, MSG_ERROR, _error_response(String("57P01"), String("second"))
    )
    _put_msg(r, MSG_READY, _ready())
    _server_send(rig.server, r)
    var rt = _new_rt()
    assert_equal(
        _raised_by_prepare(rig, rt), String("PgError[ERROR 57P01]: second")
    )
    _done(rig^)
    _ = rt^
    print("  ok: an error while draining raises that error")


def _error_notices_ready(n_notices: Int) -> List[UInt8]:
    """ErrorResponse "first", `n_notices` NoticeResponses, then ReadyForQuery,
    then a well-formed result whose one row is "next"."""
    var r = List[UInt8]()
    _put_msg(
        r, MSG_ERROR, _error_response(String("42P01"), String("first"))
    )
    for _ in range(n_notices):
        _put_msg(r, MSG_NOTICE, _notice())
    _put_msg(r, MSG_READY, _ready())
    _put_msg(r, MSG_ROW_DESC, _row_desc_one_text(String("a")))
    _put_msg(r, MSG_DATA_ROW, _data_row_text(String("next")))
    _put_msg(r, MSG_CMD_COMPLETE, _cmd_complete(String("SELECT 1")))
    _put_msg(r, MSG_READY, _ready())
    return r^


def test_drain_reaches_ready_after_4095_messages() raises:
    """The drain reads at most 4096 messages: a ReadyForQuery that is the
    4096th still ends it, the call raises the server's error, and the
    connection reads its next result."""
    var rig = _PgRig()
    _server_send(rig.server, _error_notices_ready(4095))
    var rt = _new_rt()
    assert_equal(
        _raised_by_prepare(rig, rt), String("PgError[ERROR 42P01]: first")
    )
    assert_false(rig.conn.closed())
    ref reactor = rt.reactor()
    var rows = rig.conn.query[BRT](reactor, String("SELECT a"))
    assert_equal(rows.__len__(), 1)
    assert_equal(rows.row(0).get_text(0), String("next"))
    _done(rig^)
    _ = rt^
    print("  ok: a drain reaches ReadyForQuery as its 4096th message")


def test_drain_gives_up_before_a_4097th_message() raises:
    """4096 notices before the ReadyForQuery: the drain gives up rather than
    reading the 4097th message."""
    var rig = _PgRig()
    _server_send(rig.server, _error_notices_ready(4096))
    var rt = _new_rt()
    assert_equal(
        _raised_by_prepare(rig, rt),
        String("PgConnection: did not reach ReadyForQuery"),
    )
    _done(rig^)
    _ = rt^
    print("  ok: a drain gives up after 4096 messages")


# =============================================================================
# 8. PgReactorStream: send and receive failures
# =============================================================================
def test_send_after_close_raises_tls_error() raises:
    var rig = _StreamRig(_gone_peer_fd())
    rig.stream.close()
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var data = List[UInt8]()
    _ascii(data, String("SELECT 1"))
    var raised = String("")
    try:
        rig.stream.send_all[BRT](reactor, Span[UInt8](data))
    except e:
        raised = String(e)
    assert_true(
        raised.startswith("pg_tls.send_all: TLS error (s2n_errno="),
        "got: " + raised,
    )
    _done_stream(rig^)
    _ = rt^
    print("  ok: send after close raises the TLS error")


def test_send_that_never_flushes_gives_up() raises:
    """The server never reads, so the socket fills and every send blocks on
    write; each park (on a socket whose peer is gone) returns at once."""
    var rig = _StreamRig(_gone_peer_fd())
    # Small socket buffers, so the 4 MiB cannot all sit in the kernel.
    set_so_sndbuf(rig.client_fd, Int32(4096))
    set_so_rcvbuf(rig.server_fd, Int32(4096))
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var data = List[UInt8](length=4 << 20, fill=UInt8(0x5A))
    var raised = String("")
    try:
        rig.stream.send_all[BRT](reactor, Span[UInt8](data))
    except e:
        raised = String(e)
    assert_equal(raised, String("pg_tls.send_all: could not flush all bytes"))
    _done_stream(rig^)
    _ = rt^
    print("  ok: a send that never flushes gives up")


def _recv_with_nothing_sent(park_fd: Int32) raises -> String:
    var rig = _StreamRig(park_fd)
    var rt = _new_rt()
    ref reactor = rt.reactor()
    var into = List[UInt8]()
    var raised = String("")
    try:
        _ = rig.stream.recv_some[BRT](reactor, into, 16384)
    except e:
        raised = String(e)
    assert_equal(len(into), 0, "nothing was received")
    _done_stream(rig^)
    _ = rt^
    return raised^


def test_recv_with_nothing_sent_gives_up() raises:
    var want = String("pg_tls.recv_some: spun without progress")
    assert_equal(_recv_with_nothing_sent(_gone_peer_fd()), want, "real fd")
    assert_equal(_recv_with_nothing_sent(Int32(-1)), want, "fd -1")
    print("  ok: a receive with nothing sent gives up")


def main() raises:
    print("== db_postgres.wire connection paths ==")
    test_result_column_name_bounds()
    test_prepare_reads_params_columns_and_skips_notice()
    test_query_prepared_binds_binary_params_and_uses_row_description()
    test_query_prepared_keeps_statement_columns_without_row_description()
    test_closed_connection_refuses_prepare_and_query_prepared()
    test_query_prepared_wrong_param_count_sends_nothing()
    test_large_reply_arrives_intact()
    test_close_notify_mid_message_raises_eof()
    test_error_while_draining_raises_the_second_error()
    test_drain_reaches_ready_after_4095_messages()
    test_drain_gives_up_before_a_4097th_message()
    test_send_after_close_raises_tls_error()
    test_send_that_never_flushes_gives_up()
    test_recv_with_nothing_sent_gives_up()
    print("== PASSED ==")
