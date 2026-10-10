"""komira_db_postgres.wire: a blocking PgConnection call that hits a truncated
backend message closes the connection (komira#1086).

NO DATABASE SERVER. A socketpair carries a real TLS 1.3 session: the server
end is an in-process s2n connection holding the throwaway komira_http_core
leaf certificate, the client end is the PgReactorStream a PgConnection
owns. The server writes a whole reply up front; the PgConnection call then
reads it through a BlockingRuntime reactor exactly as it would read a
server's reply.

Each reply carries one truncated message (komira#1086 makes the decoder
raise) followed by the rest of a normal result: a well-formed DataRow
"stale", CommandComplete and ReadyForQuery. Once the call raises, those
messages are still unread. If the connection stayed open, the next query()
would read them and return the "stale" row as its own result. So each case
checks:

  - the call raises with the decoder's "truncated" text;
  - closed() is True afterwards;
  - a second query() raises "connection is closed" instead of returning a
    row.

Cases: query() with a truncated DataRow and with a truncated RowDescription;
prepare() with a truncated ParameterDescription and with a truncated
RowDescription; query_prepared() with a truncated DataRow and with a
truncated RowDescription. That is every decoder call in the blocking paths.

The control case sends the same reply with every message well-formed:
query() returns its rows and the connection stays open. That shows the
harness delivers a reply the connection can read, so a red case is the
connection's behaviour, not the harness's.

main runs every case and raises after the last one if any failed.
"""

from std.ffi import external_call
from std.pathlib import Path
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.tcp_stream import TcpStream
from komira_http_core.tls import (
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    last_s2n_errno,
    s2n_strerror_message,
    tls_init,
)

from komira_db_postgres.wire.connection import PgConnection, PreparedStatement
from komira_db_postgres.wire.pg_tls import PgReactorStream
from komira_db_postgres.wire.pg_types import OID_TEXT, PgValue
from komira_db_postgres.wire.pgwire import (
    put_i16_be,
    put_i32_be,
    MSG_BIND_COMPLETE,
    MSG_CMD_COMPLETE,
    MSG_DATA_ROW,
    MSG_NO_DATA,
    MSG_PARAM_DESC,
    MSG_PARSE_COMPLETE,
    MSG_READY,
    MSG_ROW_DESC,
)

comptime _AF_UNIX: Int32 = 1
comptime _SOCK_STREAM: Int32 = 1

comptime _QUERY = 0
comptime _PREPARE = 1
comptime _QUERY_PREPARED = 2

comptime BRT = BlockingRuntime[NoopSink]


# -----------------------------------------------------------------------------
# Fixtures + libc helpers
# -----------------------------------------------------------------------------
def _leaf_cert() raises -> String:
    return Path(
        "src/komira_http_core/tests/fixtures/tls/leaf_cert.pem"
    ).read_text()


def _leaf_key() raises -> String:
    return Path(
        "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
    ).read_text()


def _socketpair() raises -> Tuple[Int32, Int32]:
    var sv = Array[Int32, 2](fill=Int32(-1))
    # SAFETY: `sv` is a live local array of two Int32 for the whole call;
    # socketpair writes exactly two Int32 into it and keeps no pointer.
    var sv_ptr = UnsafePointer(to=sv).unsafe_origin_cast[
        MutUntrackedOrigin
    ]().bitcast[Int32]()
    var rc = external_call["socketpair", Int32](
        _AF_UNIX, _SOCK_STREAM, Int32(0), sv_ptr,
    )
    if rc != Int32(0):
        raise Error("socketpair() returned " + String(Int(rc)))
    return (sv[0], sv[1])


def _close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def _set_nonblock(fd: Int32) raises:
    var rc = external_call["komira_fcntl_set_nonblock", Int32](fd)
    if rc < Int32(0):
        raise Error("_set_nonblock returned " + String(Int(rc)))


def _handshake(mut server: TlsConnection, mut client: TlsConnection) raises:
    """Alternate the two handshakes until both are DONE."""
    var sv_done = False
    var cl_done = False
    for _ in range(256):
        if not sv_done:
            var o = server.handshake()
            if o == TLS_OUTCOME_ERROR:
                raise Error(
                    "server handshake: "
                    + s2n_strerror_message(last_s2n_errno())
                )
            sv_done = o == TLS_OUTCOME_DONE
        if not cl_done:
            var o = client.handshake()
            if o == TLS_OUTCOME_ERROR:
                raise Error(
                    "client handshake: "
                    + s2n_strerror_message(last_s2n_errno())
                )
            cl_done = o == TLS_OUTCOME_DONE
        if sv_done and cl_done:
            return
    raise Error("handshake did not finish in 256 rounds")


def _server_send(mut server: TlsConnection, data: List[UInt8]) raises:
    """Send all of `data`; the reply is small, so the socket takes it whole."""
    var off = 0
    for _ in range(64):
        if off == len(data):
            return
        var res = server.send(Span[UInt8](data)[off : len(data)])
        if res[0] == TLS_OUTCOME_ERROR:
            raise Error(
                "server send: " + s2n_strerror_message(last_s2n_errno())
            )
        off += res[1]
    raise Error("server send did not finish")


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


def _row_desc_one_text(name: String) -> List[UInt8]:
    var b = List[UInt8]()
    put_i16_be(b, Int16(1))
    _ascii(b, name)
    b.append(UInt8(0))
    put_i32_be(b, Int32(0))  # table OID
    put_i16_be(b, Int16(0))  # attnum
    put_i32_be(b, Int32(OID_TEXT))  # type OID
    put_i16_be(b, Int16(-1))  # type size
    put_i32_be(b, Int32(-1))  # type modifier
    put_i16_be(b, Int16(0))  # format code
    return b^


def _row_desc_truncated() -> List[UInt8]:
    """Count 2, one complete field."""
    var b = _row_desc_one_text(String("a"))
    b[1] = UInt8(2)
    return b^


def _data_row_text(value: String) -> List[UInt8]:
    var b = List[UInt8]()
    put_i16_be(b, Int16(1))
    put_i32_be(b, Int32(len(value.as_bytes())))
    _ascii(b, value)
    return b^


def _data_row_truncated() -> List[UInt8]:
    """Count 1, the value declares 5 bytes and 3 follow (the issue's repro)."""
    var b = List[UInt8]()
    put_i16_be(b, Int16(1))
    put_i32_be(b, Int32(5))
    _ascii(b, String("abc"))
    return b^


def _param_desc_truncated() -> List[UInt8]:
    """Count 2, one OID."""
    var b = List[UInt8]()
    put_i16_be(b, Int16(2))
    put_i32_be(b, Int32(OID_TEXT))
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


def _tail(mut out: List[UInt8]):
    """The rest of a normal result after the message under test: a
    well-formed "stale" row, CommandComplete, ReadyForQuery."""
    _put_msg(out, MSG_DATA_ROW, _data_row_text(String("stale")))
    _put_msg(out, MSG_CMD_COMPLETE, _cmd_complete(String("SELECT 1")))
    _put_msg(out, MSG_READY, _ready())


# -----------------------------------------------------------------------------
# One case: a TLS session over a socketpair, a canned reply, one call
# -----------------------------------------------------------------------------
def _run(reply: List[UInt8], op: Int, expect_err: String, what: String) raises:
    """Serve `reply`, run `op` on a fresh PgConnection, and check the outcome.

    `expect_err` empty: the call must succeed with both rows ("ok" and
    "stale") and leave the connection open. Otherwise the call must raise with `expect_err` in its
    text, leave the connection closed, and refuse a second query()."""
    tls_init()
    var fds = _socketpair()
    var server_fd = fds[0]
    var client_fd = fds[1]
    _set_nonblock(server_fd)
    _set_nonblock(client_fd)

    var server_config = TlsConfig()
    server_config.load_cert(_leaf_cert(), _leaf_key())
    var server = TlsConnection(server_config)
    server.bind_fd(server_fd)

    var client_config = TlsConfig()
    client_config.wipe_trust()
    client_config.disable_verify()
    var client = TlsConnection.new_client(client_config)
    client.bind_fd(client_fd)
    client.set_server_name(String("localhost"))

    _handshake(server, client)
    _server_send(server, reply)

    # The client fd now belongs to the TcpStream inside the connection.
    var conn = PgConnection(
        PgReactorStream(client_config^, client^, TcpStream(client_fd))
    )
    var rt = BRT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var raised = String("")
    var rows_seen = -1
    try:
        if op == _QUERY:
            rows_seen = conn.query[BRT](reactor, String("SELECT a")).__len__()
        elif op == _PREPARE:
            _ = conn.prepare[BRT](reactor, String("SELECT a"))
            rows_seen = 0
        else:
            var oids = List[UInt32]()
            oids.append(OID_TEXT)
            var offsets = List[Int]()
            offsets.append(0)
            offsets.append(1)
            var name_bytes = List[UInt8]()
            name_bytes.append(UInt8(ord("a")))
            var stmt = PreparedStatement(
                String("s"), List[UInt32](), oids^, name_bytes^, offsets^
            )
            rows_seen = conn.query_prepared[BRT](
                reactor, stmt, List[PgValue]()
            ).__len__()
    except e:
        raised = String(e)

    if expect_err == "":
        assert_equal(raised, String(""), what + ": the call raised")
        assert_equal(rows_seen, 2, what + ": rows returned")
        assert_false(conn.closed(), what + ": connection left open")
    else:
        assert_true(
            raised.find(expect_err) >= 0,
            what + ": expected '" + expect_err + "', got '" + raised + "'",
        )
        assert_true(
            conn.closed(), what + ": connection closed after the error"
        )
        var again = String("")
        var stale_rows = -1
        try:
            stale_rows = conn.query[BRT](reactor, String("SELECT 1")).__len__()
        except e:
            again = String(e)
        assert_equal(stale_rows, -1, what + ": next query returned rows")
        assert_true(
            again.find("connection is closed") >= 0,
            what + ": next query: " + again,
        )

    conn.close()
    _ = conn^
    _ = rt^  # the reactor outlives the stream registered on it
    _ = server^
    _ = server_config^
    _close_fd(server_fd)
    print("  ok:", what)


# -----------------------------------------------------------------------------
# Cases
# -----------------------------------------------------------------------------
def test_control_well_formed_reply() raises:
    var r = List[UInt8]()
    _put_msg(r, MSG_ROW_DESC, _row_desc_one_text(String("a")))
    _put_msg(r, MSG_DATA_ROW, _data_row_text(String("ok")))
    _tail(r)
    _run(r, _QUERY, String(""), String("query, well-formed reply"))


def test_query_truncated_data_row() raises:
    var r = List[UInt8]()
    _put_msg(r, MSG_ROW_DESC, _row_desc_one_text(String("a")))
    _put_msg(r, MSG_DATA_ROW, _data_row_truncated())
    _tail(r)
    _run(r, _QUERY, String("DataRow truncated"), String("query, DataRow"))


def test_query_truncated_row_description() raises:
    var r = List[UInt8]()
    _put_msg(r, MSG_ROW_DESC, _row_desc_truncated())
    _tail(r)
    _run(
        r,
        _QUERY,
        String("RowDescription truncated"),
        String("query, RowDescription"),
    )


def test_prepare_truncated_parameter_description() raises:
    var r = List[UInt8]()
    _put_msg(r, MSG_PARSE_COMPLETE, List[UInt8]())
    _put_msg(r, MSG_PARAM_DESC, _param_desc_truncated())
    _put_msg(r, MSG_NO_DATA, List[UInt8]())
    _tail(r)
    _run(
        r,
        _PREPARE,
        String("ParameterDescription truncated"),
        String("prepare, ParameterDescription"),
    )


def test_prepare_truncated_row_description() raises:
    var r = List[UInt8]()
    _put_msg(r, MSG_PARSE_COMPLETE, List[UInt8]())
    var no_params = List[UInt8]()
    put_i16_be(no_params, Int16(0))
    _put_msg(r, MSG_PARAM_DESC, no_params)
    _put_msg(r, MSG_ROW_DESC, _row_desc_truncated())
    _tail(r)
    _run(
        r,
        _PREPARE,
        String("RowDescription truncated"),
        String("prepare, RowDescription"),
    )


def test_query_prepared_truncated_data_row() raises:
    var r = List[UInt8]()
    _put_msg(r, MSG_BIND_COMPLETE, List[UInt8]())
    _put_msg(r, MSG_DATA_ROW, _data_row_truncated())
    _tail(r)
    _run(
        r,
        _QUERY_PREPARED,
        String("DataRow truncated"),
        String("query_prepared, DataRow"),
    )


def test_query_prepared_truncated_row_description() raises:
    var r = List[UInt8]()
    _put_msg(r, MSG_BIND_COMPLETE, List[UInt8]())
    _put_msg(r, MSG_ROW_DESC, _row_desc_truncated())
    _tail(r)
    _run(
        r,
        _QUERY_PREPARED,
        String("RowDescription truncated"),
        String("query_prepared, RowDescription"),
    )


def main() raises:
    var failed = List[String]()
    try:
        test_control_well_formed_reply()
    except e:
        print("FAIL control:", e)
        failed.append(String("control"))
    try:
        test_query_truncated_data_row()
    except e:
        print("FAIL query_data_row:", e)
        failed.append(String("query_data_row"))
    try:
        test_query_truncated_row_description()
    except e:
        print("FAIL query_row_description:", e)
        failed.append(String("query_row_description"))
    try:
        test_prepare_truncated_parameter_description()
    except e:
        print("FAIL prepare_parameter_description:", e)
        failed.append(String("prepare_parameter_description"))
    try:
        test_prepare_truncated_row_description()
    except e:
        print("FAIL prepare_row_description:", e)
        failed.append(String("prepare_row_description"))
    try:
        test_query_prepared_truncated_data_row()
    except e:
        print("FAIL query_prepared_data_row:", e)
        failed.append(String("query_prepared_data_row"))
    try:
        test_query_prepared_truncated_row_description()
    except e:
        print("FAIL query_prepared_row_description:", e)
        failed.append(String("query_prepared_row_description"))
    if len(failed) > 0:
        raise Error(
            "test_truncated_closes_connection: "
            + String(len(failed))
            + " failed"
        )
    print("test_truncated_closes_connection: all checks passed")
