# =============================================================================
# komira_db/db_value.mojo — backend-neutral logical value + column descriptor.
# =============================================================================
#
# The keystone runtime types the DbStorable codegen output
# compiles against. `DbValue` is the BACKEND-NEUTRAL logical value
# carrier over the closed logical-type set. It is NOT
# pg-OID-tagged — it names only a logical type; each backend driver (pg /
# sqlite) maps a DbValue to its native bind. The pg `PgValue` (which
# IS OID-tagged) is one *rendering* of a DbValue, produced by the pg driver.
#
# RELOCATION DISCIPLINE (the keystone constraint): a `DbValue` accumulates into a
# growing `List[DbValue]` in `to_row()`, so its element layout must be
# relocation-safe under the synthesized move/copy that `List` relocation triggers.
# Like `komira_db_postgres.wire.PgValue`, `DbValue` holds
# EXACTLY ONE heap field — `_text: String` — the canonical carrier value, and
# DERIVES every other rendering on demand. No second heap container, no nested
# heap container, no UnsafePointer. The TEXT[] elements are carried inside the
# single `_text` String as a `{a,b,c}` pg-array literal; `text_array_elements()`
# re-parses it. This keeps the doubly-nested-container relocation trap off the
# row path entirely (see the PgValue / PgRow banners).

#
# Encapsulation: every public surface here takes / returns String /
# typed scalars / InlineArray / List — ZERO UnsafePointer crosses any boundary.
# =============================================================================

from komira_db.timestamptz import Timestamptz


# =============================================================================
# LOGICAL_* — the backend-neutral logical type tags.
# =============================================================================
#
# A small closed `Int` tag set. These are LOGICAL types, not pg OIDs — the
# driver maps each onto its physical wire form (pg OID / sqlite affinity). The
# generated `column_types()` / `DbValue.null(...)` reference these by name.
comptime LOGICAL_UUID: Int = 0
comptime LOGICAL_TEXT: Int = 1
comptime LOGICAL_INT4: Int = 2
comptime LOGICAL_INT8: Int = 3
comptime LOGICAL_FLOAT8: Int = 4
comptime LOGICAL_FLOAT4: Int = 5
comptime LOGICAL_BOOL: Int = 6
comptime LOGICAL_BYTES: Int = 7
comptime LOGICAL_TIMESTAMPTZ: Int = 8
comptime LOGICAL_JSONB: Int = 9
comptime LOGICAL_TEXT_ARRAY: Int = 10


def logical_type_name(t: Int) -> StaticString:
    """A human-readable name for a logical type tag (diagnostics / DDL hints)."""
    if t == LOGICAL_UUID:
        return "UUID"
    elif t == LOGICAL_TEXT:
        return "TEXT"
    elif t == LOGICAL_INT4:
        return "INT4"
    elif t == LOGICAL_INT8:
        return "INT8"
    elif t == LOGICAL_FLOAT8:
        return "FLOAT8"
    elif t == LOGICAL_FLOAT4:
        return "FLOAT4"
    elif t == LOGICAL_BOOL:
        return "BOOL"
    elif t == LOGICAL_BYTES:
        return "BYTES"
    elif t == LOGICAL_TIMESTAMPTZ:
        return "TIMESTAMPTZ"
    elif t == LOGICAL_JSONB:
        return "JSONB"
    elif t == LOGICAL_TEXT_ARRAY:
        return "TEXT[]"
    return "UNKNOWN"


# =============================================================================
# DbColumn — the load-bearing column descriptor.
# =============================================================================
struct DbColumn(Movable, Copyable):
    """One column's schema identity: physical `name`, the stable protobuf
    `field_number` (the rename-safe column identity), its backend-
    neutral `logical_type` (one of LOGICAL_*), and `nullable`.

    Single heap field (`name: String`) — relocation-safe in a growing
    `List[DbColumn]` (the `column_types()` accumulation shape)."""

    var name: String
    var field_number: Int
    var logical_type: Int
    var nullable: Bool

    def __init__(
        out self,
        var name: String,
        field_number: Int,
        logical_type: Int,
        nullable: Bool,
    ):
        self.name = name^
        self.field_number = field_number
        self.logical_type = logical_type
        self.nullable = nullable


# =============================================================================
# DbValue — the backend-neutral logical value carrier.
# =============================================================================
#
# Tag-discriminated over the LOGICAL_* set. ONE heap field `_text` carries the
# canonical value; `is_null` flags a NULL. Typed constructors mirror the
# generated `to_row()` cascade:
#
#   DbValue.uuid(InlineArray[UInt8,16])  — 16 raw bytes, carried as canonical hex
#   DbValue.text(String)                 — UTF-8 text
#   DbValue.int4(Int32) / int8(Int64)    — decimal ASCII
#   DbValue.float8(Float64)/float4(Float32)
#   DbValue.bool_val(Bool)
#   DbValue.jsonb(String)                — proto3-canonical-JSON text
#   DbValue.timestamptz(Timestamptz)     — µs since UNIX epoch (decimal)
#   DbValue.text_array(List[T])          — pg {a,b,c} array literal
#   DbValue.null(LOGICAL_*)              — typed NULL
struct DbValue(Movable, Copyable):
    """A backend-neutral logical parameter value. Tag-discriminated over the
    LOGICAL_* logical-type set, with the canonical value held in ONE `String`
    field (`_text`). Each backend driver renders a DbValue to its native bind;
    the value never carries a pg OID (it is backend-neutral). Single heap field
    — relocation-safe in a growing `List[DbValue]`."""

    var logical_type: Int
    var is_null: Bool
    var _text: String  # the sole heap field — canonical carrier value

    def __init__(
        out self, logical_type: Int, is_null: Bool, var text: String
    ):
        self.logical_type = logical_type
        self.is_null = is_null
        self._text = text^

    # ---- typed constructors (the to_row value cascade targets) ----

    @staticmethod
    def uuid(bytes: Array[UInt8, 16]) -> DbValue:
        """A UUID value from its 16 big-endian bytes. Carried as the canonical
        hyphenated lowercase hex (backend-neutral text form)."""
        return DbValue(LOGICAL_UUID, False, _uuid_bytes_to_hex(bytes))

    @staticmethod
    def text(var v: String) -> DbValue:
        return DbValue(LOGICAL_TEXT, False, v^)

    @staticmethod
    def jsonb(var v: String) -> DbValue:
        return DbValue(LOGICAL_JSONB, False, v^)

    @staticmethod
    def int4(v: Int32) -> DbValue:
        return DbValue(LOGICAL_INT4, False, String(Int(v)))

    @staticmethod
    def int8(v: Int64) -> DbValue:
        return DbValue(LOGICAL_INT8, False, String(Int(v)))

    @staticmethod
    def float8(v: Float64) -> DbValue:
        return DbValue(LOGICAL_FLOAT8, False, String(v))

    @staticmethod
    def float4(v: Float32) -> DbValue:
        return DbValue(LOGICAL_FLOAT4, False, String(v))

    @staticmethod
    def bool_val(v: Bool) -> DbValue:
        return DbValue(LOGICAL_BOOL, False, String("true") if v else String("false"))

    @staticmethod
    def bytes(raw: List[UInt8]) -> DbValue:
        """A binary/blob value from its RAW bytes (a REAL binary parameter — NOT a
        base64-into-TEXT workaround). The bytes are carried VERBATIM in the sole
        `_text` String field (Mojo's String is byte-backed; `unsafe_from_utf8`
        copies the bytes in without codepoint promotion, so an arbitrary byte
        sequence — embedded NUL, non-UTF-8 — round-trips exactly). Each backend
        binds this as a native binary param: pg `bytea` / sqlite `BLOB` /
        Firestore `bytesValue` (base64 in the REST JSON). `DbRow.get_bytes(col)`
        reads the same raw bytes back. Single heap field — relocation-safe."""
        return DbValue(
            LOGICAL_BYTES, False, String(StringSlice(unsafe_from_utf8=Span(raw)))
        )

    @staticmethod
    def bytes_list(raw: List[UInt8]) -> DbValue:
        """A binary/blob value from an owned `List[UInt8]` — an alias for
        `DbValue.bytes` kept for call-site clarity where an owned list is on hand."""
        return DbValue.bytes(raw)

    @staticmethod
    def timestamptz(v: Timestamptz) -> DbValue:
        # Carrier value = microseconds since the UNIX epoch (decimal ASCII).
        return DbValue(LOGICAL_TIMESTAMPTZ, False, String(Int(v.micros)))

    @staticmethod
    def timestamptz_micros(v: Int64) -> DbValue:
        return DbValue(LOGICAL_TIMESTAMPTZ, False, String(Int(v)))

    @staticmethod
    def text_array(elements: List[String]) -> DbValue:
        """A TEXT[] value. Carried as the pg `{a,b,c}` array literal in the sole
        `_text` field (no second heap container — relocation-safe). The closed-set
        contract is simple text labels (no embedded ',' / '}')."""
        var lit = String("{")
        for i in range(len(elements)):
            if i > 0:
                lit += ","
            lit += elements[i]
        lit += "}"
        return DbValue(LOGICAL_TEXT_ARRAY, False, lit^)

    @staticmethod
    def text_array_int(elements: List[Int64]) -> DbValue:
        """A TEXT[] value over integer elements (e.g. a `repeated int64` →
        native array). Rendered as the
        `{1,2,3}` literal."""
        var lit = String("{")
        for i in range(len(elements)):
            if i > 0:
                lit += ","
            lit += String(Int(elements[i]))
        lit += "}"
        return DbValue(LOGICAL_TEXT_ARRAY, False, lit^)

    @staticmethod
    def null(logical_type: Int) -> DbValue:
        return DbValue(logical_type, True, String(""))

    # ---- accessors (driver-facing) ----

    def as_text(self) -> String:
        """The canonical text rendering — what a TEXT-format bind sends."""
        return self._text

    def as_bytes_owned(self) -> List[UInt8]:
        """The RAW bytes of a binary/blob value (the inverse of `DbValue.bytes`).
        Reads the sole `_text` carrier's bytes VERBATIM into an owned buffer — an
        arbitrary byte sequence round-trips exactly. Valid for any value (a TEXT
        value returns its UTF-8 bytes), but named for the LOGICAL_BYTES path."""
        var out = List[UInt8]()
        var b = self._text.as_bytes()
        for i in range(len(b)):
            out.append(b[i])
        return out^

    def text_array_elements(self) -> List[String]:
        """Re-parse the carried `{a,b,c}` literal back to its elements (the
        untyped-round-trip path; drivers may re-render natively)."""
        return _parse_array_literal(self._text)


# =============================================================================
# Local helpers — keep this module self-contained (no cross-pkg pointer flow).
# =============================================================================
def _uuid_bytes_to_hex(b: Array[UInt8, 16]) -> String:
    """Canonical 8-4-4-4-12 lowercase hyphenated UUID from 16 bytes."""
    var out = String()
    for i in range(16):
        var v = Int(b[i])
        out += _hex_digit_lower(v >> 4)
        out += _hex_digit_lower(v & 0x0F)
        if i == 3 or i == 5 or i == 7 or i == 9:
            out += "-"
    return out^


def _hex_digit_lower(nibble: Int) -> String:
    if nibble < 10:
        return String(chr(ord("0") + nibble))
    return String(chr(ord("a") + (nibble - 10)))


def _parse_array_literal(lit: String) -> List[String]:
    """Parse a simple pg text array literal `{a,b,c}` into its elements (the
    closed-set contract: simple labels, no embedded ',' / '}' / quoting)."""
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
    # Verbatim bytes -> owned String (copies). NOT chr()-per-byte: chr maps a
    # byte >= 0x80 to a two-byte codepoint, so a non-ASCII element came back
    # double-encoded (`Zürich` as `ZÃ¼rich`). The bytes are slices of a valid
    # UTF-8 `_text` cut at ASCII ',' / '}', so they are valid UTF-8 themselves.
    return String(StringSlice(unsafe_from_utf8=Span(b)))
