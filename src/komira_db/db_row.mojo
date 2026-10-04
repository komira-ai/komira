# =============================================================================
# komira_db/db_row.mojo — the UNTYPED backend-neutral result row.
# =============================================================================
#
# `DbRow` is the untyped surface the typed `DbStorable.from_row`
# reads through. It re-surfaces `komira_db_postgres.wire.PgRow`'s flat, relocation-safe layout
# (the untyped row is PgRow lightly re-surfaced): per-column
# bytes are ONE flat `_data: List[UInt8]` + an `_offsets: List[Int]` table (len
# ncols+1), plus `_nulls` / per-column logical type tags — NOT a doubly-nested
# `List[List[UInt8]]` (a nested heap container is not safe to relocate inside
# a growing List). Column `c`'s bytes are
# `_data[_offsets[c] : _offsets[c+1]]`.
#
# The typed getters mirror the generated `from_row` cascade:
#   get_uuid / get_text / get_int4 / get_int8 / get_jsonb / get_timestamptz /
#   get_text_array  + their get_opt_* nullable variants.
# Plus an untyped escape surface: logical_type(col) / raw_bytes(col)
# / is_null(col) + a column-name -> index map.
#
# A row can be constructed directly from logical values (the
# driver-agnostic carrier path used by the unit / round-trip test). The pg /
# sqlite drivers build a DbRow from their native column bytes; the
# getter API is identical regardless of who populated it.
#
# Encapsulation: every public surface takes / returns String /
# typed scalars / InlineArray / List — ZERO UnsafePointer crosses any boundary.
# =============================================================================

from komira_db.db_value import (
    DbValue,
    LOGICAL_UUID,
    LOGICAL_TEXT,
    LOGICAL_INT4,
    LOGICAL_INT8,
    LOGICAL_TIMESTAMPTZ,
    LOGICAL_JSONB,
    LOGICAL_TEXT_ARRAY,
    logical_type_name,
)
from komira_db.timestamptz import Timestamptz


# =============================================================================
# DbRow — one untyped result row, columns by index (query / RowDescription
# order). Flat single-level storage (relocation-safe in a growing List[DbRow]).
# =============================================================================
struct DbRow(Movable, Copyable):
    """One result row over backend-neutral logical columns. Holds per-column
    text bytes in a flat `_data` + `_offsets` table, NULL flags, and per-column
    logical type tags. Column access by index; the typed getters decode the
    flat bytes per logical type. Single-level heap fields only — relocation-safe."""

    var _data: List[UInt8]  # all column bytes, concatenated (canonical text form)
    var _offsets: List[Int]  # len ncols+1; col c = [_offsets[c], _offsets[c+1])
    var _nulls: List[Bool]
    var _logical_types: List[Int]
    var _column_names: List[String]

    def __init__(
        out self,
        var data: List[UInt8],
        var offsets: List[Int],
        var nulls: List[Bool],
        var logical_types: List[Int],
        var column_names: List[String],
    ):
        self._data = data^
        self._offsets = offsets^
        self._nulls = nulls^
        self._logical_types = logical_types^
        self._column_names = column_names^

    @staticmethod
    def from_values(
        values: List[DbValue], column_names: List[String]
    ) -> DbRow:
        """Build a DbRow from a row of logical DbValues (the driver-agnostic
        path used by the unit / round-trip test, and the model the pg / sqlite
        drivers mirror from their native columns). Concatenates each value's
        canonical text into the flat `_data` buffer + `_offsets` table — no
        doubly-nested container is ever materialized."""
        var data = List[UInt8]()
        var offsets = List[Int]()
        offsets.append(0)
        var nulls = List[Bool]()
        var ltypes = List[Int]()
        for i in range(len(values)):
            ref v = values[i]
            nulls.append(v.is_null)
            ltypes.append(v.logical_type)
            if not v.is_null:
                var b = v.as_text().as_bytes()
                for j in range(len(b)):
                    data.append(b[j])
            offsets.append(len(data))
        return DbRow(data^, offsets^, nulls^, ltypes^, column_names.copy())

    # ---- untyped escape surface ----

    def col_count(self) -> Int:
        var n = len(self._offsets)
        return n - 1 if n > 0 else 0

    def is_null(self, col: Int) -> Bool:
        if col < 0 or col >= len(self._nulls):
            return True
        return self._nulls[col]

    def logical_type(self, col: Int) raises -> Int:
        if col < 0 or col >= len(self._logical_types):
            raise Error("DbRow: column index out of range")
        return self._logical_types[col]

    def column_name(self, col: Int) raises -> String:
        if col < 0 or col >= len(self._column_names):
            raise Error("DbRow: column index out of range")
        return self._column_names[col]

    def column_index(self, name: String) -> Int:
        """The index of column `name`, or -1 if absent (the column-name -> index
        map the untyped path uses)."""
        for i in range(len(self._column_names)):
            if self._column_names[i] == name:
                return i
        return -1

    def raw_bytes(self, col: Int) raises -> List[UInt8]:
        """The raw canonical bytes of column `col` (bounds + NULL checked)."""
        if col < 0 or col >= self.col_count():
            raise Error("DbRow: column index out of range")
        if self._nulls[col]:
            raise Error("DbRow: column is NULL (use is_null / get_opt_*)")
        var out = List[UInt8]()
        var start = self._offsets[col]
        var end = self._offsets[col + 1]
        for i in range(start, end):
            out.append(self._data[i])
        return out^

    # ---- typed getters (the from_row decode cascade targets) ----

    def _col_text(self, col: Int) raises -> String:
        # Preserve the raw column bytes VERBATIM as UTF-8. `chr(Int(b))` would
        # promote every byte >= 0x80 to its codepoint (2-byte UTF-8), double-
        # encoding multi-byte text. Because this DbRow re-surface reads bytes
        # that the PgRow getter already produced, a chr() here compounds into
        # a second round of double-UTF-8 mojibake. The

        # unsafe_from_utf8 constructor COPIES into an owned String buffer.
        var b = self.raw_bytes(col)
        return String(StringSlice(unsafe_from_utf8=Span(b)))

    def get_text(self, col: Int) raises -> String:
        return self._col_text(col)

    def get_jsonb(self, col: Int) raises -> String:
        return self._col_text(col)

    def get_int4(self, col: Int) raises -> Int32:
        return Int32(_parse_i64(self._col_text(col)))

    def get_int8(self, col: Int) raises -> Int64:
        return _parse_i64(self._col_text(col))

    def get_uuid(self, col: Int) raises -> Array[UInt8, 16]:
        return _parse_uuid_text(self._col_text(col))

    def get_uuid_hex(self, col: Int) raises -> String:
        return self._col_text(col)

    def get_timestamptz(self, col: Int) raises -> Timestamptz:
        return Timestamptz(_parse_i64(self._col_text(col)))

    def get_timestamptz_micros(self, col: Int) raises -> Int64:
        return _parse_i64(self._col_text(col))

    def get_text_array(self, col: Int) raises -> List[String]:
        return _parse_array_literal(self._col_text(col))

    def get_bytes(self, col: Int) raises -> List[UInt8]:
        """The RAW bytes of a binary/blob (LOGICAL_BYTES) column — the inverse of
        `DbValue.bytes`. Returns the verbatim column bytes (bounds + NULL checked);
        an arbitrary byte sequence (embedded NUL, non-UTF-8) round-trips exactly.
        The driver populated `_data` with the raw blob bytes (pg `bytea` binary
        body / sqlite BLOB / Firestore base64-decoded), so a byte-read here is the
        exact write-side buffer. Synonym for `raw_bytes(col)` with the typed-getter
        name the from_row cascade uses."""
        return self.raw_bytes(col)

    # ---- nullable variants ----

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

    def get_opt_timestamptz(self, col: Int) raises -> Optional[Timestamptz]:
        if self.is_null(col):
            return Optional[Timestamptz]()
        return Optional[Timestamptz](self.get_timestamptz(col))

    def get_opt_jsonb(self, col: Int) raises -> Optional[String]:
        if self.is_null(col):
            return Optional[String]()
        return Optional[String](self._col_text(col))

    def get_opt_bytes(self, col: Int) raises -> Optional[List[UInt8]]:
        if self.is_null(col):
            return Optional[List[UInt8]]()
        return Optional[List[UInt8]](self.get_bytes(col))


# =============================================================================
# DbRows — a materialized backend-neutral result set.
# =============================================================================
struct DbRows(Movable):
    """A materialized result set: all rows buffered (control-plane result sets
    are bounded by LIMIT). Iterable by index; exposes the column-name list."""

    var _rows: List[DbRow]
    var _column_names: List[String]

    def __init__(out self, var rows: List[DbRow], var column_names: List[String]):
        self._rows = rows^
        self._column_names = column_names^

    def __len__(self) -> Int:
        return len(self._rows)

    # ⚠ MOJO-1.0.0: `List.__getitem__` now returns `ref[<list origin>["element"]]`, a
    # NESTED origin, so `ref [self._rows]` (the list's own origin) is rejected as
    # incompatible. `origin_of(self._rows[0])` IS that element origin spelled from
    # here — a comptime projection; no runtime index happens.
    def row(ref self, i: Int) raises -> ref [origin_of(self._rows[0])] DbRow:
        if i < 0 or i >= len(self._rows):
            raise Error("DbRows: row index out of range")
        return self._rows[i]

    def column_count(self) -> Int:
        return len(self._column_names)

    def column_name(self, i: Int) raises -> String:
        if i < 0 or i >= len(self._column_names):
            raise Error("DbRows: column index out of range")
        return self._column_names[i]

    def column_index(self, name: String) -> Int:
        for i in range(len(self._column_names)):
            if self._column_names[i] == name:
                return i
        return -1


# =============================================================================
# Local decode helpers (self-contained — no cross-pkg pointer flow).
# =============================================================================
def _parse_i64(s: String) raises -> Int64:
    var b = s.as_bytes()
    var n = len(b)
    if n == 0:
        raise Error("DbRow: empty integer text")
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
            raise Error("DbRow: non-numeric byte in integer text")
        acc = acc * Int64(10) + Int64(Int(c) - ord("0"))
        any = True
        i += 1
    if not any:
        raise Error("DbRow: integer text had no digits")
    return -acc if neg else acc


def _hex_nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return c - UInt8(ord("A")) + UInt8(10)
    raise Error("DbRow: invalid hex nibble in UUID")


def _parse_uuid_text(s: String) raises -> Array[UInt8, 16]:
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
            raise Error("DbRow: truncated UUID hex")
        var hi = _hex_nibble(b[i])
        var lo = _hex_nibble(b[i + 1])
        out[oi] = (hi << 4) | lo
        oi += 1
        i += 2
    if oi != 16:
        raise Error("DbRow: UUID did not yield 16 bytes")
    return out^


def _parse_array_literal(lit: String) -> List[String]:
    var out = List[String]()
    var b = lit.as_bytes()
    var n = len(b)
    var i = 0
    if i < n and b[i] == UInt8(ord("{")):
        i += 1
    var cur = List[UInt8]()
    var any = False
    while i < n:
        var c = b[i]
        if c == UInt8(ord("}")):
            break
        if c == UInt8(ord(",")):
            out.append(_owned_utf8(cur))
            cur = List[UInt8]()
            any = True
        else:
            cur.append(c)
            any = True
        i += 1
    if any or len(cur) > 0:
        out.append(_owned_utf8(cur))
    return out^


def _owned_utf8(b: List[UInt8]) -> String:
    # Verbatim raw-UTF-8 -> owned String (copies the bytes). NOT chr()-per-byte:
    # chr(byte>=0x80) double-encodes (the double-UTF-8 mojibake class).
    return String(StringSlice(unsafe_from_utf8=Span(b)))
