# =============================================================================
# komira_db_postgres/wire/connection.mojo — PgConfig + PgConnection state machine
# =============================================================================
#
# `PgConnection`'s wire I/O rides the shared `komira_async` reactor
# (TcpStream + s2n TlsConnection over `Reactor[RT.Sink]`) via
# `PgReactorStream` — see pg_tls.mojo. Every would-block PARKS on the reactor
# instead of blocking in-syscall.
#
# THE RUNTIME IS THE CALLER'S: `PgConnection` does not own a runtime. Every
# wire-I/O method is METHOD-`[RT: Runtime]`-parametric and takes `mut reactor:
# Reactor[RT.Sink]` from the caller — the SAME shape `HttpClient.send[RT]`
# uses. `PgReactorStream` has no `[RT]` STRUCT parameter either (the struct
# holds no RT-dependent field); RT lives on the wire methods only. So ONE
# `PgConnection` is driven by a `BlockingRuntime[NoopSink]` reactor (the
# single-shot / test path) OR a `PerCoreAsyncRuntime` reactor (concurrent /
# pipelined reads — multiple connections' queries interleave on ONE reactor).
# The runtime choice lives at the TOP (the binary's main / the test) and is
# threaded down. RT is a METHOD parameter rather than a struct parameter (the
# HttpClient precedent), which keeps PgConnection a single concrete type and
# avoids monomorphizing the whole connection per runtime.
#
# PARK-BUFFER SAFETY: on a reactor park the `_rbuf` is LIVE across the yield.
# Every place a String / Span / byte-view is taken from `_rbuf` is audited:
#   * `_read_one_message` parses a message inside a TIGHT scope (the Span
#     borrow of `_rbuf` is fully DEAD before the next `recv_some` could park).
#     An overlapping borrow surfaced as an extended-protocol tcmalloc
#     corruption; scoping the borrow tightly removes the overlap.
#   * `PgReactorStream.recv_some` (pg_tls.mojo) decrypts into a stack-local
#     scratch InlineArray it OWNS, parks while ONLY scratch is live, and copies
#     the plaintext into `_rbuf` AFTER all parking is done. So `_rbuf` being
#     live across the park is benign — nothing reads/writes it during the yield.
# No borrowed slice of `_rbuf` (or of any caller buffer) ever escapes a park.
#
# Encapsulation: PgConnection owns the PgReactorStream (the socket); it does
# NOT own a runtime/reactor (the caller supplies it per call). NOT Copyable
# (single owner of the socket). The public surface returns PgRows / UInt64 /
# typed scalars — no UnsafePointer crosses any boundary. The read buffer is a
# plain List[UInt8] (no byte-slab).
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_db_postgres.wire.pg_tls import PgReactorStream, pg_reactor_connect
from komira_db_postgres.wire.pgwire import (
    BackendMessage,
    ColumnDesc,
    parse_one_message,
    first_message_byte_len,
    parse_row_description,
    parse_error_fields,
    command_tag,
    rows_affected_from_tag,
    owned_utf8_string,
    sasl_payload_string,
    auth_subcode,
    encode_startup,
    encode_sasl_initial,
    encode_sasl_response,
    encode_query,
    encode_parse,
    encode_bind,
    encode_describe_statement,
    encode_execute,
    encode_sync,
    encode_close_statement,
    parse_parameter_description,
    AUTH_OK,
    AUTH_SASL,
    AUTH_SASL_CONTINUE,
    AUTH_SASL_FINAL,
    MSG_AUTH,
    MSG_PARAM_STATUS,
    MSG_BACKEND_KEY,
    MSG_READY,
    MSG_ROW_DESC,
    MSG_DATA_ROW,
    MSG_CMD_COMPLETE,
    MSG_ERROR,
    MSG_NOTICE,
    MSG_EMPTY_QUERY,
    MSG_PARSE_COMPLETE,
    MSG_BIND_COMPLETE,
    MSG_CLOSE_COMPLETE,
    MSG_PARAM_DESC,
    MSG_NO_DATA,
)
from komira_db_postgres.wire.pg_types import (
    PgError,
    PgValue,
    PgRow,
    PgRows,
    row_from_data_message,
    binary_row_from_data_message,
    pg_param_binary,
)
from komira_db_postgres.wire.pgwire import ErrorFields
from komira_db_postgres.wire.scram import (
    make_client_nonce,
    compute_scram_client,
    verify_server_signature,
    scram_field,
)
from komira_encoding import base64_decode


def _pg_error_from_fields(ef: ErrorFields) -> String:
    """Build a descriptive PgError string from parsed ErrorResponse fields."""
    return PgError(
        ef.severity, ef.sqlstate, ef.message, ef.detail, False
    ).to_string()


# =============================================================================
# PgConfig — connection parameters.
# =============================================================================
struct PgConfig(Movable, Copyable):
    """Connection parameters. `require_tls` defaults True; `verify_cert`
    defaults False (accepts a self-signed dev certificate). A deployment that
    must authenticate the server sets verify_cert True."""

    var host: String  # IP literal or DNS name
    var port: UInt16
    var user: String
    var password: String
    var database: String
    var require_tls: Bool
    var verify_cert: Bool

    def __init__(
        out self,
        var host: String,
        port: UInt16,
        var user: String,
        var password: String,
        var database: String,
    ):
        self.host = host^
        self.port = port
        self.user = user^
        self.password = password^
        self.database = database^
        self.require_tls = True
        self.verify_cert = False


# =============================================================================
# PreparedStatement — a parsed + described server-side prepared statement.
# =============================================================================
struct PreparedStatement(Movable, Copyable):
    """A handle to a server-side prepared statement (created by
    `PgConnection.prepare`). Carries the statement name + the parameter type
    OIDs the server confirmed + the result column names / OIDs from the
    Describe reply. Reusable across many Bind/Execute round-trips.

    FLAT NAMES: the result column NAMES are stored flattened
    (`_rname_data: List[UInt8]` + `_rname_offsets: List[Int]`), NOT as a
    `List[String]`. A `List[String]` is a list of heap-owning elements (each
    String owns a buffer) — the same nested-heap-container family as
    `List[List[UInt8]]`. When `prepare()` returns this struct by value and it
    is moved into the caller's `stmt`, Mojo 1.0.0b1 mis-tracks the inner String
    buffers' liveness and corrupts tcmalloc (the crash was a `List::_realloc`
    SIGBUS on the NEXT allocation after the move). Every field here is now a
    SINGLE-level heap container (String + POD Lists), so the move is clean.
    """

    var name: String  # server-side statement name (unnamed == "")
    var param_oids: List[UInt32]  # confirmed parameter type OIDs (in order)
    var result_oids: List[UInt32]  # result column type OIDs
    # Flat result-column-name storage: name c == _rname_data[
    # _rname_offsets[c] : _rname_offsets[c+1]] (offsets len ncols+1).
    var _rname_data: List[UInt8]
    var _rname_offsets: List[Int]

    def __init__(
        out self,
        var name: String,
        var param_oids: List[UInt32],
        var result_oids: List[UInt32],
        var rname_data: List[UInt8],
        var rname_offsets: List[Int],
    ):
        self.name = name^
        self.param_oids = param_oids^
        self.result_oids = result_oids^
        self._rname_data = rname_data^
        self._rname_offsets = rname_offsets^

    def param_count(self) -> Int:
        return len(self.param_oids)

    def result_column_count(self) -> Int:
        var n = len(self._rname_offsets)
        return n - 1 if n > 0 else 0

    def result_column_name(self, c: Int) raises -> String:
        if c < 0 or c >= self.result_column_count():
            raise Error("PreparedStatement: result column index out of range")
        var out = List[UInt8]()
        for i in range(self._rname_offsets[c], self._rname_offsets[c + 1]):
            out.append(self._rname_data[i])
        return owned_utf8_string(out)


# =============================================================================
# PgConnection — one server session.
# =============================================================================
struct PgConnection(Movable, Deinitable):
    """One Postgres server session over SCRAM-over-TLS, riding the shared
    `komira_async` reactor. Owns the encrypted stream. NOT Copyable (single
    owner of the socket). Move via `^`.

    STRUCTURE: the wire I/O is METHOD-`[RT]`-parametric (every public
    method takes `mut reactor: Reactor[RT.Sink]` from the caller) and
    `PgReactorStream` is a single concrete type (its wire methods carry RT).
    `PgConnection` owns NO runtime/reactor — the runtime choice lives at the
    top (the binary's main / the test) and threads down through the caller's
    database layer. This is what makes concurrent reads possible: N
    connections' queries interleave on ONE caller-supplied
    `PerCoreAsyncRuntime` reactor.
    """

    var _stream: PgReactorStream
    var _closed: Bool
    # Persistent read buffer + a consumed-offset cursor. Messages are parsed
    # out of `_rbuf` starting at `_rpos`; we compact (drop the consumed prefix)
    # only when the cursor has advanced far into the buffer. This avoids
    # rebuilding the whole buffer on every message.
    var _rbuf: List[UInt8]
    var _rpos: Int
    # Monotonic counter for auto-generated prepared-statement names so each
    # `prepare` gets a distinct server-side name on one connection.
    var _stmt_seq: UInt64

    def __init__(
        out self,
        var stream: PgReactorStream,
    ):
        self._stream = stream^
        self._closed = False
        self._rbuf = List[UInt8]()
        self._rpos = 0
        self._stmt_seq = 0

    # -------------------------------------------------------------------------
    # connect — the full handshake.
    # -------------------------------------------------------------------------
    @staticmethod
    def connect[
        RT: Runtime,
    ](
        mut reactor: Reactor[RT.Sink], var config: PgConfig
    ) raises -> PgConnection:
        """Open a connection: TCP -> SSLRequest -> TLS 1.3 -> StartupMessage
        -> SCRAM-SHA-256 -> AuthenticationOk -> ReadyForQuery. Returns a
        connection in the IDLE state, ready for execute / query.

        Dials over the CALLER's `reactor` via the shared `pg_reactor_connect[RT]`
        path (parking on the reactor at every would-block), then drives the
        startup + SCRAM exchange on the same reactor. The runtime is the
        caller's (a `BlockingRuntime` for single-shot callers and tests, a
        `PerCoreAsyncRuntime` for concurrent reads)."""
        var stream = pg_reactor_connect[RT](
            reactor,
            config.host,
            config.port,
            config.host,  # SNI = host (s2n accepts/ignores for IP literals)
            config.require_tls,
            config.verify_cert,
        )
        var conn = PgConnection(stream^)
        conn._startup_and_auth[RT](
            reactor, config.user, config.password, config.database
        )
        return conn^

    def _startup_and_auth[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        user: String,
        password: String,
        database: String,
    ) raises:
        """Send StartupMessage, drive the SCRAM-SHA-256 exchange to
        AuthenticationOk, then drain to ReadyForQuery. Drives the `[RT]` wire
        path with the caller's reactor."""
        # ── StartupMessage. ──
        self._send_all[RT](reactor, Span[UInt8](encode_startup(user, database)))

        # ── Read AuthenticationSASL (mechanism list). ──
        var sasl_msg = self._read_until_type[RT](reactor, MSG_AUTH)
        var sub = auth_subcode(sasl_msg)
        if sub != AUTH_SASL:
            raise self._maybe_error(
                sasl_msg,
                String("expected AuthenticationSASL, got auth subcode ")
                + String(Int(sub)),
            )

        # ── client-first. ──
        var client_nonce = make_client_nonce()
        var client_first_bare = String("n=") + user + ",r=" + client_nonce
        var client_first = String("n,,") + client_first_bare
        self._send_all[RT](
            reactor,
            Span[UInt8](
                encode_sasl_initial(String("SCRAM-SHA-256"), client_first)
            ),
        )

        # ── Read AuthenticationSASLContinue (server-first). ──
        var cont_msg = self._read_until_type[RT](reactor, MSG_AUTH)
        var cont_sub = auth_subcode(cont_msg)
        if cont_sub != AUTH_SASL_CONTINUE:
            raise self._maybe_error(
                cont_msg,
                String("expected SASLContinue, got auth subcode ")
                + String(Int(cont_sub)),
            )
        var server_first = sasl_payload_string(cont_msg)

        var combined_nonce = scram_field(server_first, String("r="))
        # Anti-MITM: the server nonce MUST start with our client nonce.
        if not _starts_with(combined_nonce, client_nonce):
            raise Error(
                "SCRAM: server nonce does not start with client nonce "
                "(possible MITM)"
            )
        var salt_b64 = scram_field(server_first, String("s="))
        var iter_str = scram_field(server_first, String("i="))
        var salt = base64_decode(salt_b64)
        var iterations = atol(iter_str)

        # ── client-final + ClientProof. ──
        var client_final_no_proof = String("c=biws,r=") + combined_nonce
        var auth_message = (
            client_first_bare
            + ","
            + server_first
            + ","
            + client_final_no_proof
        )
        var proof = compute_scram_client(
            password, Span[UInt8](salt), iterations, auth_message
        )
        var client_final = (
            client_final_no_proof + ",p=" + proof.client_proof_b64
        )
        self._send_all[RT](
            reactor, Span[UInt8](encode_sasl_response(client_final))
        )

        # ── Read AuthenticationSASLFinal (server-final v=) then
        #    AuthenticationOk. They may arrive in one TLS record. ──
        var final_msg = self._read_until_type[RT](reactor, MSG_AUTH)
        var final_sub = auth_subcode(final_msg)
        if final_sub == AUTH_SASL_FINAL:
            var server_final = sasl_payload_string(final_msg)
            var v_b64 = scram_field(server_final, String("v="))
            if len(v_b64.as_bytes()) == 0:
                raise Error(
                    "SCRAM: server-final missing v= (got '"
                    + server_final + "')"
                )
            # MANDATORY server-signature verify (constant-time).
            var ok = verify_server_signature(proof.server_signature, v_b64)
            if not ok:
                raise Error(
                    "SCRAM: server signature verification FAILED — "
                    "rejecting connection (server impersonation?)"
                )
            # Now read AuthenticationOk.
            var ok_msg = self._read_until_type[RT](reactor, MSG_AUTH)
            var ok_sub = auth_subcode(ok_msg)
            if ok_sub != AUTH_OK:
                raise self._maybe_error(
                    ok_msg,
                    String("expected AuthenticationOk, got subcode ")
                    + String(Int(ok_sub)),
                )
        elif final_sub == AUTH_OK:
            raise Error(
                "SCRAM: server skipped AuthenticationSASLFinal (no v= to "
                "verify) — rejecting"
            )
        else:
            raise self._maybe_error(
                final_msg,
                String("expected SASLFinal, got auth subcode ")
                + String(Int(final_sub)),
            )

        # ── Drain ParameterStatus* + BackendKeyData -> ReadyForQuery. ──
        self._drain_to_ready[RT](reactor)

    # -------------------------------------------------------------------------
    # query / execute — simple-query protocol.
    # -------------------------------------------------------------------------
    def query[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], sql: String) raises -> PgRows:
        """Run a SQL statement (simple-query protocol) and return all rows.
        Results are text-format over the closed OID set."""
        if self._closed:
            raise Error("PgConnection.query: connection is closed")
        self._send_all[RT](reactor, Span[UInt8](encode_query(sql)))
        var rows = List[PgRow]()
        var col_names = List[String]()
        var col_oids = List[UInt32]()
        var got_desc = False
        var done = False
        while not done:
            var msg = self._read_one_message[RT](reactor)
            var t = msg.msg_type
            if t == MSG_ROW_DESC:
                try:
                    var cols = parse_row_description(msg)
                    col_names = List[String]()
                    col_oids = List[UInt32]()
                    for c in cols:
                        col_names.append(c.name)
                        col_oids.append(c.type_oid)
                except e:
                    raise self._close_on_malformed(e^)
                got_desc = True
            elif t == MSG_DATA_ROW:
                try:
                    rows.append(row_from_data_message(msg, col_oids))
                except e:
                    raise self._close_on_malformed(e^)
            elif t == MSG_CMD_COMPLETE:
                pass  # tag available; row count via execute()
            elif t == MSG_EMPTY_QUERY:
                pass
            elif t == MSG_ERROR:
                var ef = parse_error_fields(msg)
                self._drain_to_ready[RT](reactor)
                raise Error(_pg_error_from_fields(ef))
            elif t == MSG_NOTICE:
                pass  # log-and-ignore
            elif t == MSG_READY:
                done = True
            else:
                pass  # ParameterStatus etc. — ignore mid-query
        _ = got_desc
        return PgRows(rows^, col_names^)

    def execute[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], sql: String) raises -> UInt64:
        """Run a statement (simple-query) and return rows_affected from the
        CommandComplete tag. For INSERT/UPDATE/DELETE."""
        if self._closed:
            raise Error("PgConnection.execute: connection is closed")
        self._send_all[RT](reactor, Span[UInt8](encode_query(sql)))
        var affected: UInt64 = 0
        var done = False
        while not done:
            var msg = self._read_one_message[RT](reactor)
            var t = msg.msg_type
            if t == MSG_CMD_COMPLETE:
                affected = rows_affected_from_tag(command_tag(msg))
            elif t == MSG_ERROR:
                var ef = parse_error_fields(msg)
                self._drain_to_ready[RT](reactor)
                raise Error(_pg_error_from_fields(ef))
            elif t == MSG_READY:
                done = True
            else:
                pass
        return affected

    # -------------------------------------------------------------------------
    # prepare / query_prepared / execute_prepared — extended query protocol.
    # -------------------------------------------------------------------------
    def prepare[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], sql: String
    ) raises -> PreparedStatement:
        """Parse + Describe a statement server-side and return a reusable
        handle. Sends Parse -> Describe(statement) -> Sync; reads
        ParseComplete, ParameterDescription, RowDescription | NoData,
        ReadyForQuery."""
        if self._closed:
            raise Error("PgConnection.prepare: connection is closed")
        self._stmt_seq += 1
        var name = String("komira_pg_stmt_") + String(Int(self._stmt_seq))

        var empty_oids = List[UInt32]()
        var msg = List[UInt8]()
        _append_bytes(msg, encode_parse(name, sql, empty_oids))
        _append_bytes(msg, encode_describe_statement(name))
        _append_bytes(msg, encode_sync())
        self._send_all[RT](reactor, Span[UInt8](msg))

        var param_oids = List[UInt32]()
        var result_oids = List[UInt32]()
        var rname_data = List[UInt8]()
        var rname_offsets = List[Int]()
        rname_offsets.append(0)
        var done = False
        while not done:
            var m = self._read_one_message[RT](reactor)
            var t = m.msg_type
            if t == MSG_PARSE_COMPLETE:
                pass
            elif t == MSG_PARAM_DESC:
                try:
                    param_oids = parse_parameter_description(m)
                except e:
                    raise self._close_on_malformed(e^)
            elif t == MSG_ROW_DESC:
                try:
                    var cols = parse_row_description(m)
                    for ci in range(len(cols)):
                        ref c = cols[ci]
                        result_oids.append(c.type_oid)
                        var nb = c.name.as_bytes()
                        for bi in range(len(nb)):
                            rname_data.append(nb[bi])
                        rname_offsets.append(len(rname_data))
                except e:
                    raise self._close_on_malformed(e^)
            elif t == MSG_NO_DATA:
                pass  # statement returns no rows (e.g. INSERT/UPDATE/DELETE)
            elif t == MSG_ERROR:
                var ef = parse_error_fields(m)
                self._drain_to_ready[RT](reactor)
                raise Error(_pg_error_from_fields(ef))
            elif t == MSG_READY:
                done = True
            else:
                pass  # NoticeResponse / ParameterStatus — ignore
        return PreparedStatement(
            name^, param_oids^, result_oids^, rname_data^, rname_offsets^
        )

    def _send_bind_execute[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        stmt: PreparedStatement,
        params: List[PgValue],
    ) raises:
        """Bind the params in BINARY format, request BINARY results, Execute,
        Sync. Shared by query_prepared / execute_prepared."""
        if self._closed:
            raise Error("PgConnection: connection is closed")
        if len(params) != stmt.param_count() and stmt.param_count() != 0:
            raise Error(
                "PgConnection: prepared statement expects "
                + String(stmt.param_count())
                + " params, got "
                + String(len(params))
            )
        # FLAT layout: concatenate each param's binary body into ONE flat
        # `param_data` + an `offsets` table — never build a doubly-nested
        # `List[List[UInt8]]`.
        var formats = List[Int16]()
        var param_data = List[UInt8]()
        var offsets = List[Int]()
        offsets.append(0)
        var nulls = List[Bool]()
        for pi in range(len(params)):
            var p_oid = params[pi].oid
            var p_null = params[pi].is_null
            var p_text = params[pi].as_text()
            formats.append(Int16(1))  # binary
            nulls.append(p_null)
            if not p_null:
                var body = pg_param_binary(p_oid, p_text)
                for b in body:
                    param_data.append(b)
            offsets.append(len(param_data))
        var portal = String("")  # unnamed portal
        var msg = List[UInt8]()
        _append_bytes(
            msg,
            encode_bind(
                portal, stmt.name, formats, param_data, offsets, nulls, True
            ),
        )
        _append_bytes(msg, encode_execute(portal, Int32(0)))  # 0 == all rows
        _append_bytes(msg, encode_sync())
        self._send_all[RT](reactor, Span[UInt8](msg))

    def query_prepared[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        stmt: PreparedStatement,
        params: List[PgValue],
    ) raises -> PgRows:
        """Bind + Execute a prepared statement with BINARY params, returning
        all rows decoded from the BINARY result format."""
        self._send_bind_execute[RT](reactor, stmt, params)
        var rows = List[PgRow]()
        var col_names = List[String]()
        for c in range(stmt.result_column_count()):
            col_names.append(stmt.result_column_name(c))
        var col_oids = List[UInt32]()
        for o in stmt.result_oids:
            col_oids.append(o)
        var done = False
        while not done:
            var m = self._read_one_message[RT](reactor)
            var t = m.msg_type
            if t == MSG_BIND_COMPLETE:
                pass
            elif t == MSG_ROW_DESC:
                try:
                    var cols = parse_row_description(m)
                    if len(cols) > 0:
                        col_names = List[String]()
                        col_oids = List[UInt32]()
                        for c in cols:
                            col_names.append(c.name)
                            col_oids.append(c.type_oid)
                except e:
                    raise self._close_on_malformed(e^)
            elif t == MSG_DATA_ROW:
                try:
                    rows.append(binary_row_from_data_message(m, col_oids))
                except e:
                    raise self._close_on_malformed(e^)
            elif t == MSG_CMD_COMPLETE:
                pass
            elif t == MSG_EMPTY_QUERY:
                pass
            elif t == MSG_ERROR:
                var ef = parse_error_fields(m)
                self._drain_to_ready[RT](reactor)
                raise Error(_pg_error_from_fields(ef))
            elif t == MSG_READY:
                done = True
            else:
                pass  # NoticeResponse / ParameterStatus — ignore
        return PgRows(rows^, col_names^)

    def execute_prepared[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        stmt: PreparedStatement,
        params: List[PgValue],
    ) raises -> UInt64:
        """Bind + Execute a prepared statement for its rows_affected (the
        CommandComplete tag), discarding any rows. For INSERT/UPDATE/DELETE."""
        self._send_bind_execute[RT](reactor, stmt, params)
        var affected: UInt64 = 0
        var done = False
        while not done:
            var m = self._read_one_message[RT](reactor)
            var t = m.msg_type
            if t == MSG_CMD_COMPLETE:
                affected = rows_affected_from_tag(command_tag(m))
            elif t == MSG_ERROR:
                var ef = parse_error_fields(m)
                self._drain_to_ready[RT](reactor)
                raise Error(_pg_error_from_fields(ef))
            elif t == MSG_READY:
                done = True
            else:
                pass
        return affected

    def close_prepared[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], stmt: PreparedStatement
    ) raises:
        """Free the server-side prepared statement (Close-statement + Sync)."""
        if self._closed:
            return
        var msg = List[UInt8]()
        _append_bytes(msg, encode_close_statement(stmt.name))
        _append_bytes(msg, encode_sync())
        self._send_all[RT](reactor, Span[UInt8](msg))
        var done = False
        while not done:
            var m = self._read_one_message[RT](reactor)
            var t = m.msg_type
            if t == MSG_CLOSE_COMPLETE:
                pass
            elif t == MSG_ERROR:
                var ef = parse_error_fields(m)
                self._drain_to_ready[RT](reactor)
                raise Error(_pg_error_from_fields(ef))
            elif t == MSG_READY:
                done = True
            else:
                pass

    def close(mut self):
        """Best-effort close: TLS close_notify + fd close (no Terminate wire
        message). `close` is reactor-FREE so teardown paths and pool
        placeholders work without threading a reactor. The server reclaims the
        session on fd close regardless; the graceful `Terminate` frame was
        always best-effort (a swallowed-error send), so dropping it costs only
        a slightly less tidy server log line, not correctness. The TLS
        close_notify + fd close happen in `_stream.close()` / TcpStream.__del__
        — neither needs a reactor (close_notify is a synchronous s2n call; the
        fd close is a raw syscall)."""
        if self._closed:
            return
        self._stream.close()
        self._closed = True

    # -------------------------------------------------------------------------
    # Internal wire helpers — drive the PgReactorStream with the CALLER's
    # reactor (a method parameter threaded down from the public path, not an
    # internally-owned runtime).
    # -------------------------------------------------------------------------
    def _send_all[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], data: Span[UInt8, _]
    ) raises:
        """Send all `data` over the encrypted stream, driving the caller's
        reactor. PARK-BUFFER: `data` is the caller's live pgwire encode buffer;
        no slice of it escapes the park inside PgReactorStream.send_all."""
        self._stream.send_all[RT](reactor, data)

    def _recv_some_into_rbuf[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], max_bytes: Int
    ) raises -> Int:
        """Read more bytes from the stream into `_rbuf`, driving the caller's
        reactor. PARK-BUFFER: the recv decrypts into the stream's OWN stack
        scratch and copies into `_rbuf` only AFTER all parking is done (see
        PgReactorStream.recv_some) — no borrowed slice of `_rbuf` is held
        across the park."""
        return self._stream.recv_some[RT](reactor, self._rbuf, max_bytes)

    # -------------------------------------------------------------------------
    # NON-BLOCKING read path (alongside the blocking path above). This lets a
    # poll-shaped `PgQueryOp` (which OWNS this connection by value across
    # reactor parks) advance the read ONE non-blocking step at a time,
    # returning PENDING instead of parking the worker thread. The
    # framing-cursor state lives in the op's own `PgReadFrame` (NOT in
    # `_conn._rbuf`) — `try_recv_chunk` returns the freshly-decrypted plaintext
    # as an OWNED List the op feeds to its frame, so the s2n mid-record state
    # inside `_stream` stays alive for the whole op (the op owns this
    # connection) while the framing cursor lives in ONE place. No Span/ref
    # crosses a park; the recv never parks (PENDING is returned and the op
    # re-parks the FRAME on the reactor).
    # -------------------------------------------------------------------------
    def try_recv_chunk[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], max_bytes: Int
    ) raises -> Tuple[UInt8, UInt8, List[UInt8]]:
        """Non-blocking single decrypt attempt into a FRESH local buffer, whose
        OWNED bytes are returned. Returns `(status, blocked, bytes)`:
          * PG_RECV_DONE   — `bytes` holds >= 1 freshly-decrypted plaintext
                             bytes; `blocked` is 0.
          * PG_RECV_EOF    — peer close_notify; `bytes` is empty.
          * PG_RECV_PENDING — would-block; `bytes` is empty; `blocked` is the
                             TLS direction the op parks the fd on.

        Decrypts into a method-local `chunk: List[UInt8]` (NOT `_conn._rbuf`) so
        the op's `PgReadFrame` owns the only framing cursor. The local buffer is
        moved out — no borrow escapes. This never parks."""
        var chunk = List[UInt8]()
        var res = self._stream.try_recv_some[RT](reactor, chunk, max_bytes)
        var status = res[0]
        var blocked = res[2]
        return (status, blocked, chunk^)

    def send_bind_execute_prepared[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        stmt: PreparedStatement,
        params: List[PgValue],
    ) raises:
        """Public wrapper over `_send_bind_execute` so a poll-shaped op (in a
        sibling module) can kick off the Bind/Execute/Sync send for a
        pre-prepared statement, then drive the read non-blocking via
        `try_recv_chunk`. The send itself parks on the reactor on would-block
        (a send is small; the READ is what is poll-shaped, because it is the
        serialization point)."""
        self._send_bind_execute[RT](reactor, stmt, params)

    def send_simple_query[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink], sql: String) raises:
        """Public wrapper over the simple-query SEND so a poll-shaped op (in a
        sibling module — e.g. the transactional `PgTxAsyncOp`) can kick off a
        simple-query statement (`BEGIN` / `COMMIT` / `ROLLBACK`, or any one-shot
        SQL) and then drive the READ non-blocking via `try_recv_chunk`, identical
        to `send_bind_execute_prepared` for the prepared path. The SEND parks on
        would-block (a control-statement send is tiny). The op owns this
        connection by value across every park, so the s2n mid-record state stays
        pinned. Used to drive the TX framing (BEGIN / COMMIT /
        ROLLBACK) on the SAME held connection the prepared INSERT/SELECT run on."""
        if self._closed:
            raise Error("PgConnection.send_simple_query: connection is closed")
        self._send_all[RT](reactor, Span[UInt8](encode_query(sql)))

    def drain_to_ready_blocking[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        """Public wrapper over `_drain_to_ready` so an op can drain a connection
        back to ReadyForQuery on an error path (or to recycle the lease) without
        reaching into the private helper from a sibling module."""
        self._drain_to_ready[RT](reactor)

    @always_inline
    def closed(self) -> Bool:
        return self._closed

    @always_inline
    def stream_fd(self) -> Int32:
        """The underlying connection fd (read+write end of the PG socket). A
        plain Int32 — no pointer crosses any boundary. A poll-shaped op parks
        on read-readiness of this fd. -1 if the stream has no real fd."""
        return self._stream.fd()

    # -------------------------------------------------------------------------
    # Internal message-read helpers — a small framing buffer over the stream.
    # -------------------------------------------------------------------------
    def _available(self) -> Int:
        """Unconsumed bytes in the read buffer."""
        return len(self._rbuf) - self._rpos

    def _compact(mut self):
        """Drop the consumed prefix [0:_rpos) from _rbuf, resetting _rpos to 0.
        Builds a fresh List holding only the unconsumed tail."""
        if self._rpos == 0:
            return
        var tail = List[UInt8]()
        for i in range(self._rpos, len(self._rbuf)):
            tail.append(self._rbuf[i])
        self._rbuf = tail^
        self._rpos = 0

    def _read_one_message[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises -> BackendMessage:
        """Read exactly one complete backend message from the persistent read
        buffer, reading more bytes from the stream as needed. Advances _rpos
        past the consumed message; compacts the buffer when fully drained.

        PARK-BUFFER (load-bearing): the message length + parse happen inside a
        TIGHT scope so the Span borrow of self._rbuf is fully DEAD before we
        mutate self (`_rpos +=`, `_rbuf = ...`) AND before the next
        `_recv_some_into_rbuf` could park. Holding a Span borrow of self._rbuf
        across the self-mutation OR across the recv park is an aliasing hazard;
        scoping the borrow tightly removes the overlap."""
        var guard = 0
        while guard < 1_000_000:
            var consumed = first_message_byte_len(
                Span[UInt8](self._rbuf)[self._rpos : len(self._rbuf)]
            )
            if consumed > 0:
                var msg = parse_one_message(
                    Span[UInt8](self._rbuf)[self._rpos : len(self._rbuf)]
                )
                self._rpos += consumed
                if self._rpos == len(self._rbuf):
                    self._rbuf = List[UInt8]()
                    self._rpos = 0
                elif self._rpos > 65536:
                    self._compact()
                return msg^
            # Need more bytes. Compact first so recv appends contiguously and
            # the cursor stays small. The Span borrow above is dead here, so
            # the recv (which may PARK on the reactor) holds no _rbuf slice.
            self._compact()
            var n = self._recv_some_into_rbuf[RT](reactor, 16384)
            if n == 0:
                raise Error(
                    "PgConnection: connection closed by peer (EOF) while "
                    "awaiting a message"
                )
            guard += 1
        raise Error("PgConnection: read loop spun without progress")

    def _read_until_type[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], want: UInt8
    ) raises -> BackendMessage:
        """Read messages until one of type `want` arrives. Intervening
        ErrorResponse is raised; ParameterStatus / Notice are skipped."""
        var guard = 0
        while guard < 4096:
            var msg = self._read_one_message[RT](reactor)
            if msg.msg_type == want:
                return msg^
            if msg.msg_type == MSG_ERROR:
                var ef = parse_error_fields(msg)
                raise Error(_pg_error_from_fields(ef))
            guard += 1
        raise Error("PgConnection: did not see expected message type")

    def _drain_to_ready[
        RT: Runtime,
    ](mut self, mut reactor: Reactor[RT.Sink]) raises:
        """Read until a ReadyForQuery ('Z') message, discarding the rest."""
        var guard = 0
        while guard < 4096:
            var msg = self._read_one_message[RT](reactor)
            if msg.msg_type == MSG_READY:
                return
            if msg.msg_type == MSG_ERROR:
                var ef = parse_error_fields(msg)
                raise Error(_pg_error_from_fields(ef))
            guard += 1
        raise Error("PgConnection: did not reach ReadyForQuery")

    def _close_on_malformed(mut self, var e: Error) -> Error:
        """Close the connection after a backend message failed to decode
        (a body shorter than the counts and lengths it declares, komira#1086)
        and hand back `e` for the caller to raise.

        The rest of that result (more DataRows, CommandComplete,
        ReadyForQuery) is still unread. Left open, the connection would hand
        those leftovers to the next `query` as its own result. A server that
        sent a self-inconsistent message gives no basis for reading on to
        ReadyForQuery, so the connection is closed instead: any later call
        raises "connection is closed". An ErrorResponse is different (the
        server is in step), and those paths drain to ReadyForQuery instead."""
        self.close()
        return e^

    def _maybe_error(
        self, msg: BackendMessage, fallback: String
    ) -> Error:
        """If `msg` is an ErrorResponse, build a PgError-string Error;
        otherwise use `fallback`."""
        if msg.msg_type == MSG_ERROR:
            var ef = parse_error_fields(msg)
            return Error(_pg_error_from_fields(ef))
        return Error(fallback)


# -----------------------------------------------------------------------------
# Free helpers.
# -----------------------------------------------------------------------------
def _append_bytes(mut dst: List[UInt8], src: List[UInt8]):
    """Append every byte of `src` into `dst`. Used to concatenate the
    extended-protocol frames (Parse+Describe+Sync, Bind+Execute+Sync,
    Close+Sync) into one outbound buffer WITHOUT the `List += List` rvalue
    idiom."""
    for b in src:
        dst.append(b)


def _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True
