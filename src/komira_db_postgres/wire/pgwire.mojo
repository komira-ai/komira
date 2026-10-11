# =============================================================================
# komira_db_postgres/wire/pgwire.mojo — pgwire-v3 message framing
# =============================================================================
#
# Postgres frontend/backend protocol v3 message encode/decode.
# Reference: https://www.postgresql.org/docs/16/protocol-message-formats.html
#
# Wire conventions:
#   * Int32 / Int16 are big-endian (network byte order).
#   * Most backend messages are: Type(1 byte) Length(Int32, includes itself)
#     Body. StartupMessage / SSLRequest have NO type byte (length-prefixed only).
#   * Strings are NUL-terminated (CString).
#
# Encapsulation: all surfaces are List[UInt8] / Span / String / typed scalars.
# ZERO UnsafePointer crosses any module boundary. The codec is pure value /
# Span work — no FFI, no raw pointers, and no Movable struct with
# heap-owning fields stored in a byte-slab.
# =============================================================================


# -----------------------------------------------------------------------------
# Big-endian integer helpers
# -----------------------------------------------------------------------------
def put_i32_be(mut buf: List[UInt8], v: Int32):
    var u = UInt32(v)
    buf.append(UInt8((u >> 24) & 0xFF))
    buf.append(UInt8((u >> 16) & 0xFF))
    buf.append(UInt8((u >> 8) & 0xFF))
    buf.append(UInt8(u & 0xFF))


def put_i16_be(mut buf: List[UInt8], v: Int16):
    var u = UInt16(v)
    buf.append(UInt8((u >> 8) & 0xFF))
    buf.append(UInt8(u & 0xFF))


def read_i32_be(buf: Span[UInt8, _], off: Int) -> Int32:
    var u = (
        (UInt32(Int(buf[off])) << 24)
        | (UInt32(Int(buf[off + 1])) << 16)
        | (UInt32(Int(buf[off + 2])) << 8)
        | UInt32(Int(buf[off + 3]))
    )
    return Int32(u)


def read_i16_be(buf: Span[UInt8, _], off: Int) -> Int16:
    var u = (UInt16(Int(buf[off])) << 8) | UInt16(Int(buf[off + 1]))
    return Int16(u)


def owned_utf8_string(bytes: List[UInt8]) -> String:
    """Build an OWNED String from `bytes`, interpreting them as raw UTF-8 and
    preserving every byte VERBATIM.

    Do NOT use `chr(Int(b))` accumulation here: `chr(b)` for any byte >= 0x80
    emits the CODEPOINT U+00XX as 2-byte UTF-8, so a multi-byte UTF-8 sequence
    (em-dash `e2 80 94`, accented char `c3 a9`, emoji `f0 9f 98 80`) gets
    DOUBLE-encoded — and because this helper sits on the PgRow text-read path
    that a typed DB layer may read a SECOND time, the corruption compounds to
    TWO rounds of promotion (double-UTF-8 mojibake:
    `e2 80 94` -> `c3 83 c2 a2 c3 82 c2 80 c3 82 c2 94`).

    `String(StringSlice(unsafe_from_utf8=Span(bytes)))` COPIES the bytes into a
    new owned String buffer (it does NOT adopt/alias the input) — so it both
    preserves the bytes verbatim AND returns an owned String that survives the
    caller's local `bytes` dropping (a borrowing form that aliased a dropped
    local turned the SCRAM salt's leading bytes into spaces)."""
    return String(StringSlice(unsafe_from_utf8=Span(bytes)))


def put_cstr(mut buf: List[UInt8], s: String):
    for b in s.as_bytes():
        buf.append(b)
    buf.append(0)


def put_bytes(mut buf: List[UInt8], data: Span[UInt8, _]):
    for b in data:
        buf.append(b)


# -----------------------------------------------------------------------------
# Frontend (client -> server) messages
# -----------------------------------------------------------------------------

# SSLRequest: 8 bytes — length=8, code=80877103. No type byte. Postgres
# replies a single byte 'S' (accept) or 'N' (refuse). After 'S', the TLS
# handshake begins on the same socket.
def encode_ssl_request() -> List[UInt8]:
    var buf = List[UInt8]()
    put_i32_be(buf, 8)
    put_i32_be(buf, 80877103)
    return buf^


# StartupMessage: length, protocol 0x00030000 (v3.0 == 196608), then key/value
# CStrings, terminated by an extra NUL. No type byte.
def encode_startup(user: String, database: String) -> List[UInt8]:
    var body = List[UInt8]()
    put_i32_be(body, 196608)  # protocol version 3.0
    put_cstr(body, String("user"))
    put_cstr(body, user)
    put_cstr(body, String("database"))
    put_cstr(body, database)
    body.append(0)  # terminating empty key

    var out = List[UInt8]()
    put_i32_be(out, Int32(len(body) + 4))  # length includes itself
    put_bytes(out, Span[UInt8](body))
    return out^


# SASLInitialResponse ('p'): mechanism CString, Int32 length of client-first,
# client-first-message bytes.
def encode_sasl_initial(mechanism: String, client_first: String) -> List[UInt8]:
    var body = List[UInt8]()
    put_cstr(body, mechanism)
    var cf = client_first.as_bytes()
    put_i32_be(body, Int32(len(cf)))
    put_bytes(body, cf)

    var out = List[UInt8]()
    out.append(UInt8(ord("p")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, Span[UInt8](body))
    return out^


# SASLResponse ('p'): just the client-final-message bytes (no mechanism).
def encode_sasl_response(client_final: String) -> List[UInt8]:
    var body = client_final.as_bytes()
    var out = List[UInt8]()
    out.append(UInt8(ord("p")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, body)
    return out^


# Query ('Q'): simple-query protocol, one NUL-terminated SQL string.
def encode_query(sql: String) -> List[UInt8]:
    var body = List[UInt8]()
    put_cstr(body, sql)
    var out = List[UInt8]()
    out.append(UInt8(ord("Q")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, Span[UInt8](body))
    return out^


# Terminate ('X'): graceful session close. No body.
def encode_terminate() -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(ord("X")))
    put_i32_be(out, 4)  # length includes itself; empty body
    return out^


# -----------------------------------------------------------------------------
# Extended query protocol — frontend messages.
#
# Flow: Parse -> Bind -> Describe -> Execute -> Sync. The backend replies
# ParseComplete('1') / BindComplete('2') / [ParameterDescription('t')] /
# RowDescription('T') or NoData('n') / DataRow('D')* / CommandComplete('C') /
# ReadyForQuery('Z'). All multi-byte ints are big-endian; strings are CStrings.
# -----------------------------------------------------------------------------

# Parse ('P'): name CString (empty == unnamed), query CString, Int16
# parameter-type count, then that many Int32 type OIDs (0 == let the server
# infer). We pass the param OIDs explicitly so the server expects our binary
# encodings for the closed set.
def encode_parse(
    stmt_name: String, query: String, param_oids: List[UInt32]
) -> List[UInt8]:
    var body = List[UInt8]()
    put_cstr(body, stmt_name)
    put_cstr(body, query)
    put_i16_be(body, Int16(len(param_oids)))
    for o in param_oids:
        put_i32_be(body, Int32(o))
    var out = List[UInt8]()
    out.append(UInt8(ord("P")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, Span[UInt8](body))
    return out^


# Bind ('B'): portal CString, stmt CString, Int16 param-format-code count +
# codes, Int16 param-value count + (Int32 len + bytes | -1 for NULL), Int16
# result-format-code count + codes.
#
# FLAT param passing: the encoded value bodies arrive as ONE concatenated
# `param_data: List[UInt8]` plus a FLAT `param_offsets: List[Int]` table (len
# nparams+1), NOT a doubly-nested `List[List[UInt8]]`. A `List[List[UInt8]]`
# built by appending inner Lists is a stale-heap hazard — the outer List's
# growth realloc relocates the inner heap Lists and Mojo 1.0.0b1 mis-tracks
# their buffer liveness, corrupting tcmalloc (the same shape PgRow is
# flattened to avoid; it crashed the binary bind path here). Param
# `i`'s bytes are `param_data[param_offsets[i] : param_offsets[i+1]]`; a NULL
# is signalled by `param_nulls[i]` (a -1 length is written, the bytes ignored).
# `all_binary` True requests an all-binary result (one result format code 1).
def encode_bind(
    portal_name: String,
    stmt_name: String,
    param_formats: List[Int16],
    param_data: List[UInt8],
    param_offsets: List[Int],
    param_nulls: List[Bool],
    all_binary: Bool,
) -> List[UInt8]:
    var body = List[UInt8]()
    put_cstr(body, portal_name)
    put_cstr(body, stmt_name)
    # Parameter format codes.
    put_i16_be(body, Int16(len(param_formats)))
    for f in param_formats:
        put_i16_be(body, f)
    # Parameter values (read from the flat data + offsets layout).
    var nparams = len(param_offsets) - 1 if len(param_offsets) > 0 else 0
    put_i16_be(body, Int16(nparams))
    for i in range(nparams):
        var is_null = param_nulls[i] if i < len(param_nulls) else False
        if is_null:
            put_i32_be(body, Int32(-1))
        else:
            var start = param_offsets[i]
            var end = param_offsets[i + 1]
            put_i32_be(body, Int32(end - start))
            for j in range(start, end):
                body.append(param_data[j])
    # Result format codes: one code applied to all columns (0 text / 1 binary).
    put_i16_be(body, Int16(1))
    put_i16_be(body, Int16(1) if all_binary else Int16(0))
    var out = List[UInt8]()
    out.append(UInt8(ord("B")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, Span[UInt8](body))
    return out^


# Describe ('D'): kind byte ('S' statement | 'P' portal), name CString.
def encode_describe_statement(stmt_name: String) -> List[UInt8]:
    var body = List[UInt8]()
    body.append(UInt8(ord("S")))
    put_cstr(body, stmt_name)
    var out = List[UInt8]()
    out.append(UInt8(ord("D")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, Span[UInt8](body))
    return out^


def encode_describe_portal(portal_name: String) -> List[UInt8]:
    var body = List[UInt8]()
    body.append(UInt8(ord("P")))
    put_cstr(body, portal_name)
    var out = List[UInt8]()
    out.append(UInt8(ord("D")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, Span[UInt8](body))
    return out^


# Execute ('E'): portal CString, Int32 max rows (0 == no limit / fetch all).
def encode_execute(portal_name: String, max_rows: Int32) -> List[UInt8]:
    var body = List[UInt8]()
    put_cstr(body, portal_name)
    put_i32_be(body, max_rows)
    var out = List[UInt8]()
    out.append(UInt8(ord("E")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, Span[UInt8](body))
    return out^


# Sync ('S'): no body. Closes the implicit transaction and asks the server to
# emit ReadyForQuery.
def encode_sync() -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(ord("S")))
    put_i32_be(out, 4)
    return out^


# Close ('C'): kind byte ('S' statement | 'P' portal), name CString. Frees a
# prepared statement / portal server-side.
def encode_close_statement(stmt_name: String) -> List[UInt8]:
    var body = List[UInt8]()
    body.append(UInt8(ord("S")))
    put_cstr(body, stmt_name)
    var out = List[UInt8]()
    out.append(UInt8(ord("C")))
    put_i32_be(out, Int32(len(body) + 4))
    put_bytes(out, Span[UInt8](body))
    return out^


# Flush ('H'): no body. Forces the server to flush its output buffer without
# the transaction-closing semantics of Sync.
def encode_flush() -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(ord("H")))
    put_i32_be(out, 4)
    return out^


# -----------------------------------------------------------------------------
# Backend (server -> client) message framing
# -----------------------------------------------------------------------------

# Authentication request ('R') sub-codes (the Int32 right after the length).
comptime AUTH_OK: Int32 = 0
comptime AUTH_SASL: Int32 = 10  # AuthenticationSASL (mechanism list follows)
comptime AUTH_SASL_CONTINUE: Int32 = 11  # server-first-message follows
comptime AUTH_SASL_FINAL: Int32 = 12  # server-final (v=...) follows

# Backend message type bytes (used by the connection state machine).
comptime MSG_AUTH: UInt8 = UInt8(ord("R"))  # Authentication*
comptime MSG_PARAM_STATUS: UInt8 = UInt8(ord("S"))  # ParameterStatus
comptime MSG_BACKEND_KEY: UInt8 = UInt8(ord("K"))  # BackendKeyData
comptime MSG_READY: UInt8 = UInt8(ord("Z"))  # ReadyForQuery
comptime MSG_ROW_DESC: UInt8 = UInt8(ord("T"))  # RowDescription
comptime MSG_DATA_ROW: UInt8 = UInt8(ord("D"))  # DataRow
comptime MSG_CMD_COMPLETE: UInt8 = UInt8(ord("C"))  # CommandComplete
comptime MSG_ERROR: UInt8 = UInt8(ord("E"))  # ErrorResponse
comptime MSG_NOTICE: UInt8 = UInt8(ord("N"))  # NoticeResponse
comptime MSG_EMPTY_QUERY: UInt8 = UInt8(ord("I"))  # EmptyQueryResponse

# Extended-protocol backend message types.
comptime MSG_PARSE_COMPLETE: UInt8 = UInt8(ord("1"))  # ParseComplete
comptime MSG_BIND_COMPLETE: UInt8 = UInt8(ord("2"))  # BindComplete
comptime MSG_CLOSE_COMPLETE: UInt8 = UInt8(ord("3"))  # CloseComplete
comptime MSG_PARAM_DESC: UInt8 = UInt8(ord("t"))  # ParameterDescription
comptime MSG_NO_DATA: UInt8 = UInt8(ord("n"))  # NoData (Describe on a non-SELECT)
comptime MSG_PORTAL_SUSPENDED: UInt8 = UInt8(ord("s"))  # PortalSuspended


struct BackendMessage(Movable, Copyable):
    """One framed backend message: type byte + body (NOT including the
    5-byte type+length header).

    Heap note: `body: List[UInt8]` is heap-owning, but BackendMessage is
    NEVER stored in a byte-backed slab — it lives only in a transient
    `List[BackendMessage]` (a normal Mojo List, Copyable element, no
    wildcard-origin cast). So the byte-slab stale-pointer hazard does not
    apply.
    """

    var msg_type: UInt8
    var body: List[UInt8]

    def __init__(out self, msg_type: UInt8, var body: List[UInt8]):
        self.msg_type = msg_type
        self.body = body^


struct ParsedMessages(Movable):
    """Result of parsing as many complete messages as `data` contains, plus
    the count of bytes consumed (so the caller can retain the tail)."""

    var messages: List[BackendMessage]
    var consumed: Int

    def __init__(out self, var messages: List[BackendMessage], consumed: Int):
        self.messages = messages^
        self.consumed = consumed


def parse_backend_messages(data: Span[UInt8, _]) -> ParsedMessages:
    """Parse zero-or-more complete typed backend messages from `data`.

    Stops at the first incomplete message (header or body not fully
    present). Returns parsed messages + the number of bytes consumed; the
    caller retains data[consumed:] for the next read.
    """
    var out = List[BackendMessage]()
    var off = 0
    var n = len(data)
    while off + 5 <= n:
        var msg_type = data[off]
        var length = Int(read_i32_be(data, off + 1))  # includes the 4 len bytes
        var total = 1 + length  # type byte + length-counted region
        if off + total > n:
            break  # incomplete message; wait for more bytes
        var body = List[UInt8]()
        var body_start = off + 5
        var body_end = off + total
        for i in range(body_start, body_end):
            body.append(data[i])
        out.append(BackendMessage(msg_type, body^))
        off += total
    return ParsedMessages(out^, off)


def first_message_byte_len(data: Span[UInt8, _]) -> Int:
    """Byte length of the FIRST complete backend message in `data`, or 0 if
    `data` does not yet hold one complete message. (type byte + Int32
    length-field which includes itself)."""
    if len(data) < 5:
        return 0
    var length = Int(read_i32_be(data, 1))
    var total = 1 + length
    if total > len(data):
        return 0
    return total


def parse_one_message(data: Span[UInt8, _]) -> BackendMessage:
    """Parse exactly the FIRST complete backend message from `data`. The
    caller MUST first check `first_message_byte_len(data) > 0`; a 0 result
    means data does not yet hold one complete message. Returns the message by
    value (move-only). Avoids wrapping in a multi-field struct (which would
    require a partial-move of a single heap field on extraction)."""
    var total = first_message_byte_len(data)
    if total == 0:
        return BackendMessage(UInt8(0), List[UInt8]())
    var msg_type = data[0]
    var body = List[UInt8]()
    for i in range(5, total):
        body.append(data[i])
    return BackendMessage(msg_type, body^)


def auth_subcode(msg: BackendMessage) -> Int32:
    """For an 'R' (Authentication*) message, the Int32 auth sub-code that
    is the first 4 bytes of the body."""
    return read_i32_be(Span[UInt8](msg.body), 0)


def body_as_string(msg: BackendMessage) -> String:
    """Interpret the message body as raw UTF-8 (used for SASL continue/final
    payloads)."""
    var _bb = List[UInt8]()
    for _i in range(len(msg.body)):
        _bb.append(msg.body[_i])
    return owned_utf8_string(_bb)


def sasl_payload_string(msg: BackendMessage) -> String:
    """For an AuthenticationSASLContinue / AuthenticationSASLFinal 'R'
    message, return the SASL payload (the body after the 4-byte sub-code)
    as a UTF-8 String."""
    var sf = List[UInt8]()
    var n = len(msg.body)
    for i in range(4, n):
        sf.append(msg.body[i])
    return owned_utf8_string(sf)


# -----------------------------------------------------------------------------
# CommandComplete tag parse — yields rows_affected for execute().
# -----------------------------------------------------------------------------
#
# The CommandComplete body is a NUL-terminated command tag, e.g.
#   "INSERT 0 1", "UPDATE 3", "DELETE 2", "SELECT 5", "BEGIN", "COMMIT".
# rows_affected is the LAST space-separated integer token. For INSERT the
# tag is "INSERT <oid> <rows>" so the last token is the row count; for the
# others it is "<verb> <rows>". Tags with no trailing integer (BEGIN /
# COMMIT / ROLLBACK) yield 0.
def command_tag(msg: BackendMessage) -> String:
    """The NUL-terminated command tag string from a CommandComplete body."""
    var bytes = List[UInt8]()
    var n = len(msg.body)
    for i in range(n):
        if msg.body[i] == UInt8(0):
            break
        bytes.append(msg.body[i])
    return owned_utf8_string(bytes)


def rows_affected_from_tag(tag: String) -> UInt64:
    """Parse rows_affected from a CommandComplete tag. The row count is the
    last space-separated integer token; returns 0 if the tag has no trailing
    integer (BEGIN / COMMIT / ROLLBACK / SET)."""
    var b = tag.as_bytes()
    var n = len(b)
    # Find the last space.
    var last_space = -1
    for i in range(n):
        if b[i] == UInt8(ord(" ")):
            last_space = i
    if last_space < 0:
        return UInt64(0)
    # Parse digits after the last space.
    var acc: UInt64 = 0
    var any_digit = False
    for i in range(last_space + 1, n):
        var c = b[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            return UInt64(0)  # non-numeric trailing token (e.g. "EMPTY")
        any_digit = True
        acc = acc * UInt64(10) + UInt64(Int(c) - ord("0"))
    if not any_digit:
        return UInt64(0)
    return acc


# -----------------------------------------------------------------------------
# RowDescription / DataRow decode (simple-query text format).
# -----------------------------------------------------------------------------
#
# RowDescription ('T') body:
#   Int16  field count
#   per field: name CString, Int32 table OID, Int16 column attnum,
#              Int32 type OID, Int16 type size, Int32 type modifier,
#              Int16 format code
struct ColumnDesc(Movable, Copyable):
    """One RowDescription column: name + type OID + format code."""

    var name: String
    var type_oid: UInt32
    var format_code: Int16

    def __init__(
        out self, var name: String, type_oid: UInt32, format_code: Int16
    ):
        self.name = name^
        self.type_oid = type_oid
        self.format_code = format_code


def parse_row_description(msg: BackendMessage) raises -> List[ColumnDesc]:
    """Parse a RowDescription ('T') message into a list of ColumnDesc.
    Raises when the body ends before the field count or a declared field."""
    var cols = List[ColumnDesc]()
    var b = Span[UInt8](msg.body)
    var n = len(b)
    if n < 2:
        raise Error("pgwire: RowDescription truncated: body under 2 bytes")
    var field_count = Int(read_i16_be(b, 0))
    var off = 2
    for f in range(field_count):
        # name CString
        var name_bytes = List[UInt8]()
        while off < n and b[off] != UInt8(0):
            name_bytes.append(b[off])
            off += 1
        if off >= n:
            raise Error(
                "pgwire: RowDescription truncated: field "
                + String(f)
                + " of "
                + String(field_count)
                + " has no NUL-terminated name"
            )
        off += 1  # skip NUL
        if off + 18 > n:
            raise Error(
                "pgwire: RowDescription truncated: field "
                + String(f)
                + " of "
                + String(field_count)
                + " needs 18 bytes after its name, "
                + String(n - off)
                + " present"
            )
        # table OID (4) + attnum (2)
        off += 6
        var type_oid = UInt32(read_i32_be(b, off))
        off += 4
        # type size (2) + type modifier (4)
        off += 6
        var format_code = read_i16_be(b, off)
        off += 2
        var name = owned_utf8_string(name_bytes)
        cols.append(ColumnDesc(name^, type_oid, format_code))
    return cols^


# ParameterDescription ('t') body: Int16 param count, then that many Int32
# parameter type OIDs. Emitted by the server in response to Describe-statement.
def parse_parameter_description(msg: BackendMessage) raises -> List[UInt32]:
    """Parse a ParameterDescription ('t') message into the list of parameter
    type OIDs the server inferred / confirmed for a prepared statement.
    Raises when the body ends before the count or a declared OID."""
    var oids = List[UInt32]()
    var b = Span[UInt8](msg.body)
    var n = len(b)
    if n < 2:
        raise Error(
            "pgwire: ParameterDescription truncated: body under 2 bytes"
        )
    var count = Int(read_i16_be(b, 0))
    var off = 2
    for p in range(count):
        if off + 4 > n:
            raise Error(
                "pgwire: ParameterDescription truncated: "
                + String(count)
                + " OIDs declared, body ends at OID "
                + String(p)
            )
        oids.append(UInt32(read_i32_be(b, off)))
        off += 4
    return oids^


# DataRow ('D') body:
#   Int16  column count
#   per column: Int32 length (-1 == NULL), then `length` bytes.
# Returns the raw per-column byte payloads. NULL columns are represented by
# an empty list at that index with the corresponding `is_null` bit set.
struct RawDataRow(Movable):
    """One DataRow: per-column raw bytes + per-column NULL flags."""

    var columns: List[List[UInt8]]
    var nulls: List[Bool]

    def __init__(
        out self, var columns: List[List[UInt8]], var nulls: List[Bool]
    ):
        self.columns = columns^
        self.nulls = nulls^

    def col_count(self) -> Int:
        return len(self.columns)


def data_row_truncated_error(
    col: Int, col_count: Int, declared: Int, present: Int
) -> Error:
    """The protocol error for a DataRow body that ends before column `col`
    (of `col_count`): before its 4-byte length when `declared` < 0, else
    inside its `declared`-byte value with `present` bytes left. Shared by
    `parse_data_row` and the PgRow builder in pg_types."""
    var at = (
        String("column ") + String(col) + " of " + String(col_count)
    )
    if declared < 0:
        return Error(
            "pgwire: DataRow truncated: body ends before the length of " + at
        )
    return Error(
        "pgwire: DataRow truncated: "
        + at
        + " declares "
        + String(declared)
        + " bytes, "
        + String(present)
        + " present"
    )


def parse_data_row(msg: BackendMessage) raises -> RawDataRow:
    """Parse a DataRow ('D') message into per-column raw byte payloads.
    Raises when the body ends before the column count, a column length or a
    column value."""
    var columns = List[List[UInt8]]()
    var nulls = List[Bool]()
    var b = Span[UInt8](msg.body)
    var n = len(b)
    if n < 2:
        raise Error("pgwire: DataRow truncated: body under 2 bytes")
    var col_count = Int(read_i16_be(b, 0))
    var off = 2
    for c in range(col_count):
        if off + 4 > n:
            raise data_row_truncated_error(c, col_count, -1, 0)
        var col_len = Int(read_i32_be(b, off))
        off += 4
        var col_bytes = List[UInt8]()
        if col_len < 0:
            nulls.append(True)
        else:
            if col_len > n - off:
                raise data_row_truncated_error(c, col_count, col_len, n - off)
            nulls.append(False)
            for i in range(off, off + col_len):
                col_bytes.append(b[i])
            off += col_len
        columns.append(col_bytes^)
    return RawDataRow(columns^, nulls^)


# -----------------------------------------------------------------------------
# ErrorResponse / NoticeResponse field parse.
# -----------------------------------------------------------------------------
#
# ErrorResponse ('E') / NoticeResponse ('N') body: a sequence of
# (field-type-byte, value-CString) pairs, terminated by a zero field byte.
# Field type bytes: 'S' severity, 'V' non-localized severity, 'C' SQLSTATE,
# 'M' message, 'D' detail, 'H' hint, etc.
struct ErrorFields(Movable, Copyable):
    """Parsed ErrorResponse / NoticeResponse fields (the subset we surface)."""

    var severity: String
    var sqlstate: String
    var message: String
    var detail: String

    def __init__(
        out self,
        var severity: String,
        var sqlstate: String,
        var message: String,
        var detail: String,
    ):
        self.severity = severity^
        self.sqlstate = sqlstate^
        self.message = message^
        self.detail = detail^


def parse_error_fields(msg: BackendMessage) -> ErrorFields:
    """Parse an ErrorResponse ('E') / NoticeResponse ('N') body into the
    severity / SQLSTATE / message / detail fields we surface."""
    var severity = String("")
    var sqlstate = String("")
    var message = String("")
    var detail = String("")
    var b = Span[UInt8](msg.body)
    var n = len(b)
    var off = 0
    while off < n:
        var field_type = b[off]
        off += 1
        if field_type == UInt8(0):
            break
        var val_bytes = List[UInt8]()
        while off < n and b[off] != UInt8(0):
            val_bytes.append(b[off])
            off += 1
        off += 1  # skip NUL
        var val = owned_utf8_string(val_bytes)
        if field_type == UInt8(ord("S")) or field_type == UInt8(ord("V")):
            severity = val^
        elif field_type == UInt8(ord("C")):
            sqlstate = val^
        elif field_type == UInt8(ord("M")):
            message = val^
        elif field_type == UInt8(ord("D")):
            detail = val^
    return ErrorFields(severity^, sqlstate^, message^, detail^)
