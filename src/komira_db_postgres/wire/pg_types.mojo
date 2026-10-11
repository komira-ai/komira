# =============================================================================
# komira_db_postgres/wire/pg_types.mojo — PgValue / PgRow / PgRows / PgError
# =============================================================================
#
# The safe value / row / error types of the client. The SIMPLE-QUERY
# protocol returns DataRow columns in TEXT format, so the text row decoders
# parse the closed OID set from TEXT bytes:
#
#   UUID(2950), TEXT(25)/VARCHAR(1043), JSONB(3802), INT4(23), INT8(20),
#   TIMESTAMPTZ(1184), TEXT[](1009).
#
# The EXTENDED protocol uses BINARY format for params and results (the
# codecs live in pg_binary.mojo). The text decoders: INT4/INT8 parse decimal
# ASCII, UUID parses the canonical hyphenated hex, TEXT/JSONB are the raw
# bytes.
#
# Encapsulation: every public surface takes/returns String / typed scalars /
# InlineArray / List — ZERO UnsafePointer crosses any boundary. PgRow holds the
# raw column bytes in a FLAT single-level layout (one concatenated
# `_data: List[UInt8]` + an `_offsets: List[Int]` table), NOT a doubly-nested
# List[List[UInt8]]. This avoids a stale-heap hazard: a doubly-nested
# List[List[UInt8]] inside a Movable/Copyable struct that gets accumulated and
# relocated in a `List[PgRow]` is the shape where Mojo 1.0.0b1 mis-tracks the
# inner heap-buffer liveness on the synthesized move/copy and corrupts tcmalloc.
# row_from_data_message builds the flat layout directly off the wire so the
# doubly-nested container never exists on the row path. See the PgRow banner.
# =============================================================================

from komira_db_postgres.wire.pgwire import (
    ColumnDesc,
    BackendMessage,
    read_i16_be,
    read_i32_be,
    owned_utf8_string,
    data_row_truncated_error,
)
from komira_db_postgres.wire.pg_binary import (
    encode_int4_binary,
    encode_int8_binary,
    encode_text_binary,
    encode_uuid_binary,
    encode_jsonb_binary,
    encode_timestamptz_binary,
    encode_text_array_binary,
    decode_int4_binary,
    decode_int8_binary,
    decode_text_binary,
    decode_uuid_binary,
    decode_jsonb_binary,
    decode_timestamptz_binary,
    decode_text_array_binary,
    uuid_bytes_to_hex,
)


# Closed OID set.
comptime OID_BOOL: UInt32 = 16
comptime OID_BYTEA: UInt32 = 17
comptime OID_INT8: UInt32 = 20
comptime OID_INT4: UInt32 = 23
comptime OID_TEXT: UInt32 = 25
comptime OID_VARCHAR: UInt32 = 1043
comptime OID_JSONB: UInt32 = 3802
comptime OID_UUID: UInt32 = 2950
comptime OID_TIMESTAMPTZ: UInt32 = 1184
comptime OID_TEXT_ARRAY: UInt32 = 1009


# =============================================================================
# PgError — server ErrorResponse OR transport error.
# =============================================================================
struct PgError(Movable, Copyable):
    """A Postgres error: server-side ErrorResponse (severity + SQLSTATE +
    message) OR a transport-level failure (TLS/socket/timeout). The
    consumer funnels these into a descriptive string + SQLSTATE."""

    var severity: String
    var sqlstate: String
    var message: String
    var detail: String
    var is_transport: Bool  # True == transport failure (no SQLSTATE)

    def __init__(
        out self,
        var severity: String,
        var sqlstate: String,
        var message: String,
        var detail: String,
        is_transport: Bool,
    ):
        self.severity = severity^
        self.sqlstate = sqlstate^
        self.message = message^
        self.detail = detail^
        self.is_transport = is_transport

    @staticmethod
    def transport(var message: String) -> PgError:
        return PgError(
            String("FATAL"), String(""), message^, String(""), True
        )

    def to_string(self) -> String:
        if self.is_transport:
            return String("PgError[transport]: ") + self.message
        var s = String("PgError[") + self.severity + String(" ")
        s += self.sqlstate + String("]: ") + self.message
        if len(self.detail.as_bytes()) > 0:
            s += String(" (detail: ") + self.detail + String(")")
        return s^


# =============================================================================
# PgValue — tagged param value (over the closed OID set).
# =============================================================================
#
# PgValue is the typed param carrier for BOTH wire paths:
#   * `as_text()`        — the TEXT-format rendering (simple-query / text Bind).
#   * `binary_body()`    — the BINARY-format value body (extended-protocol Bind
#                          with format code 1). Built eagerly at construction so
#                          the bind path is a pure copy with no per-bind encode
#                          branch. The TIMESTAMPTZ carrier value is microseconds
#                          since the UNIX epoch (binary_body converts to the pg
#                          2000-epoch); UUID is the canonical hyphenated hex
#                          (binary_body is the 16 raw bytes).
#
# ONE HEAP FIELD: PgValue holds EXACTLY ONE heap field — `_text: String` —
# and DERIVES the binary value body on demand (`binary_body()`) from `_text`
# + `oid`. Earlier shapes that added a SECOND heap field (`_bin: List[UInt8]`,
# or one flat `_buf: List[UInt8]`) crashed the LIVE bind path: after a
# `PgConnection` connect, building a `List[PgValue]` whose element owns a
# `List[UInt8]` (the ui8 dtype) pops a poisoned chunk off the same ui8 freelist
# that the connection's `_rbuf: List[UInt8]` recycles, SIGBUSing in
# `List[UInt8]::_realloc`. Keeping `_text: String` as the sole heap field
# avoids the ui8-freelist collision entirely; the
# binary body is a transient List returned from `binary_body()`, never a field.
# This is also the cleaner design: one canonical carrier value, two renderings.
struct PgValue(Movable, Copyable):
    """A typed Postgres parameter value. Tag-discriminated over the closed
    OID set. Holds the canonical value in ONE `String` field; `as_text()` is
    that String and `binary_body()` encodes the pg BINARY value body on demand
    from it. No UnsafePointer, single heap field (safe to relocate in a
    growing List[PgValue])."""

    var oid: UInt32
    var is_null: Bool
    var _text: String  # canonical carrier value (the TEXT rendering)

    def __init__(out self, oid: UInt32, is_null: Bool, var text: String):
        self.oid = oid
        self.is_null = is_null
        self._text = text^

    @staticmethod
    def text(var v: String) -> PgValue:
        return PgValue(OID_TEXT, False, v^)

    @staticmethod
    def jsonb(var v: String) -> PgValue:
        return PgValue(OID_JSONB, False, v^)

    @staticmethod
    def bytea(var raw: String) -> PgValue:
        """A `bytea` param whose canonical `_text` carrier holds the RAW blob
        bytes VERBATIM (Mojo String is byte-backed). The pg bytea BINARY value
        body IS the raw bytes with no header, so `binary_body()` emits `_text`'s
        bytes unchanged — a genuine binary bind (not a base64/hex TEXT literal)."""
        return PgValue(OID_BYTEA, False, raw^)

    @staticmethod
    def int4(v: Int32) -> PgValue:
        return PgValue(OID_INT4, False, String(Int(v)))

    @staticmethod
    def int8(v: Int64) -> PgValue:
        return PgValue(OID_INT8, False, String(Int(v)))

    @staticmethod
    def timestamptz_micros(v: Int64) -> PgValue:
        # `v` is microseconds since the UNIX epoch (the carrier value). The
        # binary form converts to the pg 2000-epoch in binary_body().
        return PgValue(OID_TIMESTAMPTZ, False, String(Int(v)))

    @staticmethod
    def uuid_hex(var v: String) -> PgValue:
        # Canonical hyphenated UUID hex string (8-4-4-4-12).
        return PgValue(OID_UUID, False, v^)

    @staticmethod
    def text_array(elements: List[String]) -> PgValue:
        # TEXT[] (OID 1009). Carrier is the pg array literal {a,b,c}; the
        # binary form re-parses this literal in binary_body(). Elements must
        # not contain ',' or '}' (simple labels / tags).
        var lit = String("{")
        for i in range(len(elements)):
            if i > 0:
                lit += ","
            lit += elements[i]
        lit += "}"
        return PgValue(OID_TEXT_ARRAY, False, lit^)

    @staticmethod
    def null(oid: UInt32) -> PgValue:
        return PgValue(oid, True, String(""))

    def as_text(self) -> String:
        return self._text

    def binary_body(self) raises -> List[UInt8]:
        """The BINARY-format value body (format code 1), DERIVED on demand from
        the canonical `_text` + `oid`. For a NULL value the list is empty and
        the Bind frame writes a -1 length instead."""
        if self.is_null:
            return List[UInt8]()
        return pg_param_binary(self.oid, self._text)


def pg_param_binary(oid: UInt32, text: String) raises -> List[UInt8]:
    """Encode the pg BINARY value body (format code 1) for a non-null param,
    given its OID + canonical text. The free-function form lets the bind path
    encode from LOCALS (no live `ref` into List[PgValue] held across the
    allocating encode — the prepared-statement bind-path corruption fix)."""
    if oid == OID_BOOL:
        # pg bool_recv: exactly 1 byte, 0x01 (true) / 0x00 (false). The carrier
        # text is the canonical "true"/"false" (DbValue.bool_val).
        var ob = List[UInt8]()
        ob.append(UInt8(1) if text == String("true") else UInt8(0))
        return ob^
    elif oid == OID_INT4:
        return encode_int4_binary(Int32(_parse_int64_text(text)))
    elif oid == OID_INT8:
        return encode_int8_binary(_parse_int64_text(text))
    elif oid == OID_TIMESTAMPTZ:
        return encode_timestamptz_binary(_parse_int64_text(text))
    elif oid == OID_UUID:
        return encode_uuid_binary(text)
    elif oid == OID_JSONB:
        return encode_jsonb_binary(text)
    elif oid == OID_TEXT_ARRAY:
        return encode_text_array_binary(_parse_array_literal(text))
    elif oid == OID_BYTEA:
        # bytea BINARY value body = the raw bytes with NO header. The `text`
        # carrier holds them verbatim (String is byte-backed), so the body is
        # exactly those bytes — a genuine binary bind.
        return encode_text_binary(text)
    else:  # OID_TEXT / OID_VARCHAR
        return encode_text_binary(text)


# =============================================================================
# Text decoders for the closed OID set (simple-query DataRow columns).
# =============================================================================
def _bytes_to_string(b: List[UInt8]) -> String:
    return owned_utf8_string(b)


def _parse_array_literal(lit: String) -> List[String]:
    """Parse a simple pg text array literal `{a,b,c}` into its elements. The
    closed-set contract is simple text labels (no embedded ',' / '}' / quoting
    — simple labels). Used by PgValue.binary_body for TEXT[]."""
    var out = List[String]()
    var b = lit.as_bytes()
    var n = len(b)
    var i = 0
    # Skip a leading '{'.
    if i < n and b[i] == UInt8(ord("{")):
        i += 1
    var cur = List[UInt8]()
    var any = False
    while i < n:
        var c = b[i]
        if c == UInt8(ord("}")):
            break
        if c == UInt8(ord(",")):
            out.append(owned_utf8_string(cur))
            cur = List[UInt8]()
            any = True
        else:
            cur.append(c)
            any = True
        i += 1
    # Flush the last element (only if the array was non-empty).
    if any or len(cur) > 0:
        out.append(owned_utf8_string(cur))
    return out^


def _parse_int64_text(s: String) raises -> Int64:
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        raise Error("PgRow: empty integer text")
    var i = 0
    var neg = False
    if b[0] == UInt8(ord("-")):
        neg = True
        i = 1
    elif b[0] == UInt8(ord("+")):
        i = 1
    var acc: Int64 = 0
    var any = False
    while i < n:
        var c = b[i]
        if c < UInt8(ord("0")) or c > UInt8(ord("9")):
            raise Error("PgRow: non-numeric byte in integer text")
        acc = acc * Int64(10) + Int64(Int(c) - ord("0"))
        any = True
        i += 1
    if not any:
        raise Error("PgRow: integer text had no digits")
    return -acc if neg else acc


def _hex_nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + UInt8(10)
    raise Error("PgRow: invalid hex nibble in UUID")


def _parse_uuid_text(s: String) raises -> Array[UInt8, 16]:
    """Parse a canonical hyphenated UUID (e.g.
    "550e8400-e29b-41d4-a716-446655440000") into 16 bytes."""
    var b = s.as_bytes()
    var out = Array[UInt8, 16](fill=0)
    var oi = 0
    var i = 0
    var n = len(b)
    while i < n and oi < 16:
        if b[i] == UInt8(ord("-")):
            i += 1
            continue
        if i + 1 >= n:
            raise Error("PgRow: truncated UUID hex")
        var hi = _hex_nibble(b[i])
        var lo = _hex_nibble(b[i + 1])
        out[oi] = (hi << 4) | lo
        oi += 1
        i += 2
    if oi != 16:
        raise Error("PgRow: UUID did not yield 16 bytes")
    return out^


# =============================================================================
# PgRow — one result row. Column access by index (RowDescription order).
# =============================================================================
struct PgRow(Movable, Copyable):
    """One result row. Holds the per-column raw text bytes + NULL flags + the
    column OIDs (for type-checking the get_* calls). Column access by index;
    the caller knows the column order from the query.

    FLAT STORAGE: the per-column bytes are stored as ONE flat
    `_data: List[UInt8]` plus an `_offsets: List[Int]` table (len ncols+1),
    NOT as a doubly-nested `List[List[UInt8]]`. A `List[List[UInt8]]` is a
    doubly-nested heap container, and Mojo 1.0.0b1's synthesized move/copy of a
    struct owning one mis-tracks the inner heap-buffer liveness: when PgRows are
    accumulated and the backing `List[PgRow]` relocates them (growth realloc),
    the tcmalloc free-list corrupts -> SIGSEGV / SIGBUS in `List::_realloc` /
    `SLL_TryPop`. Flattening to a single `_data` buffer + `_offsets` removes the
    second level of heap nesting entirely: every field is now a single-level
    Movable/Copyable List with exactly one heap buffer, so relocation is a clean
    per-field move. Column `c`'s bytes are `_data[_offsets[c] : _offsets[c+1]]`.

    BINARY-FORMAT support: `_binary` records the column wire format
    (False == text, the simple-query path; True == binary, the
    extended-protocol path). The `get_*` getters are format-aware — they branch
    to the text decoder (`_parse_int64_text`, `_parse_uuid_text`) or the binary
    decoder (`decode_*_binary`) on the same flat `_data` bytes. The public
    getter API is identical on both paths. The extended protocol requests an
    ALL-binary or ALL-text result, so one row-level flag suffices.
    """

    var _data: List[UInt8]  # all column bytes, concatenated
    var _offsets: List[Int]  # len ncols+1; col c = [_offsets[c], _offsets[c+1])
    var _nulls: List[Bool]
    var _oids: List[UInt32]
    var _binary: Bool  # False == text columns, True == binary columns

    def __init__(
        out self,
        var data: List[UInt8],
        var offsets: List[Int],
        var nulls: List[Bool],
        var oids: List[UInt32],
    ):
        # FLAT constructor (TEXT format — the simple-query path). The per-column
        # bytes arrive already concatenated in `data` with column boundaries in
        # `offsets` (len ncols+1). No doubly-nested List[List[UInt8]] is ever
        # constructed on the row path (see row_from_data_message) — see the
        # struct docstring.
        self._data = data^
        self._offsets = offsets^
        self._nulls = nulls^
        self._oids = oids^
        self._binary = False

    def __init__(
        out self,
        var data: List[UInt8],
        var offsets: List[Int],
        var nulls: List[Bool],
        var oids: List[UInt32],
        binary: Bool,
    ):
        # Same FLAT layout; `binary` selects the column wire format used by the
        # get_* decoders (the extended-protocol path passes binary=True).
        self._data = data^
        self._offsets = offsets^
        self._nulls = nulls^
        self._oids = oids^
        self._binary = binary

    def col_count(self) -> Int:
        var n = len(self._offsets)
        return n - 1 if n > 0 else 0

    def is_null(self, col: Int) -> Bool:
        if col < 0 or col >= len(self._nulls):
            return True
        return self._nulls[col]

    def _col_bytes(self, col: Int) raises -> List[UInt8]:
        """Raw bytes of column `col` (bounds + NULL checked). Format-agnostic."""
        if col < 0 or col >= self.col_count():
            raise Error("PgRow: column index out of range")
        if self._nulls[col]:
            raise Error("PgRow: column is NULL (use is_null / get_opt_*)")
        var out = List[UInt8]()
        var start = self._offsets[col]
        var end = self._offsets[col + 1]
        for i in range(start, end):
            out.append(self._data[i])
        return out^

    def _col_text(self, col: Int) raises -> String:
        return _bytes_to_string(self._col_bytes(col))

    def get_text(self, col: Int) raises -> String:
        # TEXT / VARCHAR: text wire == raw UTF-8; binary wire == raw UTF-8.
        # Both are the same bytes, so a single path serves both formats.
        return self._col_text(col)

    def get_jsonb(self, col: Int) raises -> String:
        # Binary JSONB == 1 version byte + UTF-8; text JSONB == the raw text.
        if self._binary:
            return decode_jsonb_binary(Span[UInt8](self._col_bytes(col)))
        return self._col_text(col)

    def get_bool(self, col: Int) raises -> Bool:
        # BOOLEAN: binary wire is 1 byte (0x01 true / 0x00 false); text wire is
        # 't'/'f' (pg's bool text output). Both decode to the canonical Bool.
        if self._binary:
            var b = self._col_bytes(col)
            return len(b) > 0 and b[0] != UInt8(0)
        var t = self._col_text(col)
        return t == String("t") or t == String("true") or t == String("1")

    def get_int4(self, col: Int) raises -> Int32:
        if self._binary:
            return decode_int4_binary(Span[UInt8](self._col_bytes(col)))
        return Int32(self._parse_i64(col))

    def get_int8(self, col: Int) raises -> Int64:
        if self._binary:
            return decode_int8_binary(Span[UInt8](self._col_bytes(col)))
        return self._parse_i64(col)

    def _parse_i64(self, col: Int) raises -> Int64:
        return _parse_int64_text(self._col_text(col))

    def get_uuid(self, col: Int) raises -> Array[UInt8, 16]:
        if self._binary:
            return decode_uuid_binary(Span[UInt8](self._col_bytes(col)))
        return _parse_uuid_text(self._col_text(col))

    def get_uuid_hex(self, col: Int) raises -> String:
        """The canonical hyphenated UUID hex string. On the text path this is
        the raw column text; on the binary path it is rendered from the 16
        raw bytes."""
        if self._binary:
            return uuid_bytes_to_hex(Span[UInt8](self._col_bytes(col)))
        return self._col_text(col)

    def get_timestamptz_text(self, col: Int) raises -> String:
        # Simple-query TIMESTAMPTZ comes back as a formatted string (e.g.
        # "2030-01-15 12:00:00+00"). On the BINARY path there is no text form —
        # use get_timestamptz_micros instead; this raises to avoid handing back
        # mis-framed bytes as a string.
        if self._binary:
            raise Error(
                "PgRow.get_timestamptz_text: column is BINARY format; use"
                " get_timestamptz_micros"
            )
        return self._col_text(col)

    def get_timestamptz_micros(self, col: Int) raises -> Int64:
        """Microseconds since the UNIX epoch. BINARY path only (the wire form
        is the 8-byte pg-epoch integer, converted here)."""
        if not self._binary:
            raise Error(
                "PgRow.get_timestamptz_micros: column is TEXT format; use"
                " get_timestamptz_text"
            )
        return decode_timestamptz_binary(Span[UInt8](self._col_bytes(col)))

    def get_text_array(self, col: Int) raises -> List[String]:
        """TEXT[] element strings. BINARY path decodes the pg array_send
        header + elements; TEXT path is not parsed here (the text form is the
        `{a,b,c}` literal — use get_text and split if you need it)."""
        if not self._binary:
            raise Error(
                "PgRow.get_text_array: column is TEXT format; use get_text"
                " (the {a,b,c} array literal)"
            )
        return decode_text_array_binary(Span[UInt8](self._col_bytes(col)))

    def get_opt_text(self, col: Int) raises -> Optional[String]:
        if self.is_null(col):
            return Optional[String]()
        return Optional[String](self._col_text(col))

    def get_opt_int4(self, col: Int) raises -> Optional[Int32]:
        if self.is_null(col):
            return Optional[Int32]()
        return Optional[Int32](self.get_int4(col))

    def get_opt_int8(self, col: Int) raises -> Optional[Int64]:
        if self.is_null(col):
            return Optional[Int64]()
        return Optional[Int64](self.get_int8(col))


# =============================================================================
# PgRows — materialized result set.
# =============================================================================
struct PgRows(Movable):
    """A materialized result set: all DataRows buffered, so it suits small
    result sets (bounded by LIMIT). Iterable by index."""

    var _rows: List[PgRow]
    var _column_names: List[String]

    def __init__(
        out self, var rows: List[PgRow], var column_names: List[String]
    ):
        self._rows = rows^
        self._column_names = column_names^

    def __len__(self) -> Int:
        return len(self._rows)

    def row(ref self, i: Int) raises -> ref [origin_of(self._rows[i])] PgRow:
        if i < 0 or i >= len(self._rows):
            raise Error("PgRows: row index out of range")
        return self._rows[i]

    def column_count(self) -> Int:
        return len(self._column_names)

    def column_name(self, i: Int) raises -> String:
        if i < 0 or i >= len(self._column_names):
            raise Error("PgRows: column index out of range")
        return self._column_names[i]


# -----------------------------------------------------------------------------
# Parse a DataRow ('D') message body directly into a PgRow (one scope — no
# intermediate multi-field struct to partial-move out of).
# -----------------------------------------------------------------------------
def row_from_data_message(
    msg: BackendMessage, oids: List[UInt32]
) raises -> PgRow:
    """Parse a TEXT-format DataRow ('D') into a PgRow (simple-query path)."""
    return _row_from_data_message_fmt(msg, oids, False)


def binary_row_from_data_message(
    msg: BackendMessage, oids: List[UInt32]
) raises -> PgRow:
    """Parse a BINARY-format DataRow ('D') into a PgRow (extended-protocol
    path). The wire framing is identical to the text path — Int16 column count,
    then per column Int32 length (-1 == NULL) + bytes — only the column-value
    INTERPRETATION differs, which the PgRow `_binary` flag selects at get_*
    time. So this shares the framing parser; the format flag is the only delta.
    """
    return _row_from_data_message_fmt(msg, oids, True)


def _row_from_data_message_fmt(
    msg: BackendMessage, oids: List[UInt32], binary: Bool
) raises -> PgRow:
    """Parse a DataRow ('D') message into a PgRow over the given column OIDs.
    DataRow body: Int16 column count, then per column Int32 length (-1 ==
    NULL) followed by `length` bytes. `binary` selects the column wire format.

    Builds the FLAT PgRow storage directly (one concatenated `data` buffer +
    an `offsets` table) — it never materializes a doubly-nested
    `List[List[UInt8]]`, which is the move/copy hazard described on PgRow.
    Raises when the body ends before the column count, a column length or a
    column value (a self-inconsistent message, never a partial read: the
    caller framed it by its length header).
    """
    var data = List[UInt8]()
    var offsets = List[Int]()
    offsets.append(0)
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
        if col_len < 0:
            nulls.append(True)
        else:
            if col_len > n - off:
                raise data_row_truncated_error(c, col_count, col_len, n - off)
            nulls.append(False)
            for i in range(off, off + col_len):
                data.append(b[i])
            off += col_len
        offsets.append(len(data))
    var oids_copy = List[UInt32]()
    for o in oids:
        oids_copy.append(o)
    return PgRow(data^, offsets^, nulls^, oids_copy^, binary)
