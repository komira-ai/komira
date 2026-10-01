# =============================================================================
# json_value.mojo — a minimal JSON object scanner for the proto3-JSON decoder.
# =============================================================================
#
# `Proto3JsonWire`'s decode side needs to walk a JSON object and look up a
# field by its proto3 lowerCamelCase `json_name`. A record-oriented JSONL
# parser (one record per line, schema-driven) is not a general object
# cursor, so this package carries a small, self-contained recursive JSON
# value model.
#
# `JsonValue` is a tagged value: Null / Bool / Number (kept as its raw text,
# so int64-as-string vs number is preserved for the proto3 mapping) / String
# (already unescaped) / Array / Object. It is built by `parse_json_value`,
# a straightforward recursive-descent parser. The proto3-JSON DECODE path is
# off the hot codec path (debuggability format), so a clean recursive parser
# is the right tradeoff over a SIMD structural index.
#
# Encapsulation: owned recursive value built from owned `String` / `List`
# storage; no pointers. The recursive `Array` / `Object` arms box their
# children in `List[JsonValue]` — `JsonValue` is finitely sized because the
# recursion goes through the heap-backed `List`, not an inline field.
# =============================================================================


# JSON value kind tags.
comptime JSON_NULL: Int = 0
comptime JSON_BOOL: Int = 1
comptime JSON_NUMBER: Int = 2
comptime JSON_STRING: Int = 3
comptime JSON_ARRAY: Int = 4
comptime JSON_OBJECT: Int = 5


struct JsonValue(Copyable, Movable):
    """A parsed JSON value — a tagged union over the six JSON kinds.

    A `Number` keeps its raw source text in `text` (so an int64 encoded as a
    JSON string and an int64 encoded as a number are both reachable — the
    proto3 mapping needs the distinction). A `String` keeps its already-
    unescaped content in `text`. `Object` keys live in `obj_keys`, values in
    `children`, positionally aligned. An `Array`'s elements live in `children`.
    """

    var kind: Int
    var bool_val: Bool
    var text: String
    var children: List[JsonValue]
    var obj_keys: List[String]

    # -- SOURCE LOCATORS (for a decoder diagnostic that names WHERE) --------
    #
    # A refusal that says only *what* is wrong ("unknown field") costs the
    # reader a manual search of the document. These two Ints are what let a
    # `JsonDecoder` refusal end in `(line N)`.
    #
    # `src_line` is the 1-based line the value's OWN first byte sits on.
    # `key_line` is the 1-based line the value's OBJECT KEY sits on — set
    # only on a value that is an object MEMBER, because that (not the value)
    # is where a reader looks for a misspelled field name. A multi-line
    # member (`"deploy":\n  {`) is exactly the case where the two differ.
    #
    # 0 means UNKNOWN — a synthesized value (`JsonValue.from_string(...)`)
    # has no source position, and a diagnostic must say so rather than
    # print a confident `line 0`.
    var src_line: Int
    var key_line: Int

    def __init__(out self):
        """A JSON null (the default)."""
        self.kind = JSON_NULL
        self.bool_val = False
        self.text = String("")
        self.children = List[JsonValue]()
        self.obj_keys = List[String]()
        self.src_line = 0
        self.key_line = 0

    def copy(self) -> Self:
        """Deep clone — `Copyable` conformance over the recursive children."""
        var out = JsonValue()
        out.kind = self.kind
        out.bool_val = self.bool_val
        out.text = self.text
        out.children = self.children.copy()
        out.obj_keys = self.obj_keys.copy()
        out.src_line = self.src_line
        out.key_line = self.key_line
        return out^

    @staticmethod
    def null() -> JsonValue:
        return JsonValue()

    @staticmethod
    def from_bool(b: Bool) -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_BOOL
        v.bool_val = b
        return v^

    @staticmethod
    def from_number(var raw: String) -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_NUMBER
        v.text = raw^
        return v^

    @staticmethod
    def from_string(var s: String) -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_STRING
        v.text = s^
        return v^

    @always_inline
    def is_null(self) -> Bool:
        return self.kind == JSON_NULL

    @always_inline
    def is_object(self) -> Bool:
        return self.kind == JSON_OBJECT

    @always_inline
    def is_array(self) -> Bool:
        return self.kind == JSON_ARRAY

    def get(self, key: String) raises -> JsonValue:
        """The object value for `key`; raises if `self` is not an object or
        the key is absent. The generated decoder calls `has(key)` first for
        proto3 absent-field semantics."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: get() on a non-object value")
        for i in range(len(self.obj_keys)):
            if self.obj_keys[i] == key:
                return self.children[i].copy()
        raise Error(String("JsonError: object has no key '") + key + "'")

    def has(self, key: String) -> Bool:
        """True if `self` is an object carrying `key`."""
        if self.kind != JSON_OBJECT:
            return False
        for i in range(len(self.obj_keys)):
            if self.obj_keys[i] == key:
                return True
        return False

    def as_int64(self) raises -> Int64:
        """The value as an Int64. proto3 JSON encodes int64/uint64 as a
        STRING and int32/uint32 as a number — both arrive here as raw text;
        a `String` value's text and a `Number` value's text both parse."""
        if self.kind != JSON_NUMBER and self.kind != JSON_STRING:
            raise Error("JsonError: as_int64() on a non-numeric value")
        return _parse_int64(self.text)

    def as_uint64(self) raises -> UInt64:
        """The value as a UInt64 (proto3 uint64 is a JSON string)."""
        if self.kind != JSON_NUMBER and self.kind != JSON_STRING:
            raise Error("JsonError: as_uint64() on a non-numeric value")
        return _parse_uint64(self.text)

    def as_float64(self) raises -> Float64:
        """The value as a Float64."""
        if self.kind != JSON_NUMBER and self.kind != JSON_STRING:
            raise Error("JsonError: as_float64() on a non-numeric value")
        return Float64(_atof(self.text))

    def as_bool(self) raises -> Bool:
        if self.kind != JSON_BOOL:
            raise Error("JsonError: as_bool() on a non-bool value")
        return self.bool_val

    def as_string(self) raises -> String:
        if self.kind != JSON_STRING:
            raise Error("JsonError: as_string() on a non-string value")
        return self.text

    # =========================================================================
    # Object enumeration + kind/number-shape accessors.
    # =========================================================================
    #
    # `has`/`get`/`as_*` cover lookup-by-key + typed extraction. A caller that
    # must WALK a document's members (key + value) and discriminate each
    # value's JSON kind — including int-vs-float for a JSON_NUMBER, as a
    # dynamic field-mapping translator does — uses these accessors instead.
    # They work for any object cursor over a parsed JsonValue.

    @always_inline
    def num_members(self) -> Int:
        """The number of members of an Object (0 for any non-object). Pairs with
        `key_at`/`value_at`/`value_kind` for positional enumeration."""
        if self.kind != JSON_OBJECT:
            return 0
        return len(self.obj_keys)

    def key_at(self, i: Int) raises -> String:
        """The i-th member key of an Object. Raises if `self` is not an object or
        `i` is out of range (fail-loud — the caller bounds via `num_members`)."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: key_at() on a non-object value")
        if i < 0 or i >= len(self.obj_keys):
            raise Error("JsonError: key_at() index out of range")
        return self.obj_keys[i]

    def value_at(self, i: Int) raises -> JsonValue:
        """The i-th member value of an Object (a deep clone, like `get`). Raises
        if `self` is not an object or `i` is out of range."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: value_at() on a non-object value")
        if i < 0 or i >= len(self.children):
            raise Error("JsonError: value_at() index out of range")
        return self.children[i].copy()

    def value_kind(self, i: Int) raises -> Int:
        """The JSON kind tag (JSON_NULL/.../JSON_OBJECT) of the i-th member value
        of an Object — read WITHOUT cloning the (possibly large) value. Raises if
        `self` is not an object or `i` is out of range."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: value_kind() on a non-object value")
        if i < 0 or i >= len(self.children):
            raise Error("JsonError: value_kind() index out of range")
        return self.children[i].kind

    @always_inline
    def array_len(self) -> Int:
        """The number of elements of an Array (0 for any non-array). Pairs with
        `element_at` for positional enumeration of a JSON array — the object
        analog is `num_members`/`value_at` (for example, a GCS JSON
        `objects.list` `items[]` walk)."""
        if self.kind != JSON_ARRAY:
            return 0
        return len(self.children)

    def element_at(self, i: Int) raises -> JsonValue:
        """The i-th element of an Array (a deep clone, like `get`/`value_at`).
        Raises if `self` is not an array or `i` is out of range (fail-loud — the
        caller bounds via `array_len`)."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonError: element_at() on a non-array value")
        if i < 0 or i >= len(self.children):
            raise Error("JsonError: element_at() index out of range")
        return self.children[i].copy()

    @always_inline
    def kind_tag(self) -> Int:
        """This value's JSON kind tag (JSON_NULL/.../JSON_OBJECT)."""
        return self.kind

    def is_integral_number(self) -> Bool:
        """True iff this is a JSON_NUMBER whose raw text is an integer.

        Integral means no `.`, `e`, or `E`. A JSON_NUMBER with a
        fraction/exponent is a float; any non-number returns False. (A field-mapping
        translator maps an integral number -> INT64 and a fractional/exponent
        number -> FLOAT64.)"""
        if self.kind != JSON_NUMBER:
            return False
        var src = self.text.as_bytes()
        for i in range(len(src)):
            var c = src[i]
            if c == 0x2E or c == 0x65 or c == 0x45:  # '.' / 'e' / 'E'
                return False
        return True

    # =========================================================================
    # Builder helpers — construct an Array / Object value tree to SERIALIZE.
    # =========================================================================
    #
    # The decode side parses a wire body into a JsonValue; these builder verbs
    # let the ENCODE side construct a JsonValue tree and `serialize()` it with
    # correct escaping. A response renderer that builds its bodies this way
    # rather than hand-concatenating JSON round-trips a payload containing
    # `\n` / `"` / a `\uXXXX` codepoint losslessly.

    @staticmethod
    def empty_object() -> JsonValue:
        """An empty JSON object (`{}`) — append members with `set_member`."""
        var v = JsonValue()
        v.kind = JSON_OBJECT
        return v^

    @staticmethod
    def empty_array() -> JsonValue:
        """An empty JSON array (`[]`) — append elements with `push`."""
        var v = JsonValue()
        v.kind = JSON_ARRAY
        return v^

    def set_member(mut self, var key: String, var value: JsonValue) raises:
        """Append a key/value member to an Object (positional-aligned). Raises
        if `self` is not an Object. It does NOT dedup keys — the caller builds a
        well-formed tree (no duplicate keys)."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: set_member() on a non-object value")
        self.obj_keys.append(key^)
        self.children.append(value^)

    def push(mut self, var value: JsonValue) raises:
        """Append an element to an Array. Raises if `self` is not an Array."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonError: push() on a non-array value")
        self.children.append(value^)

    # =========================================================================
    # serialize() — render the value tree to a compact JSON String.
    # =========================================================================
    #
    # Correct escaping of String values (the `\n` / `"` / control-char +
    # backslash classes per RFC 8259 §7). Numbers emit their raw text verbatim
    # (the parser kept the source text; a builder-constructed Number passes its
    # own already-formatted text). No trailing whitespace, no pretty-printing —
    # a minimal-bytes wire body. Recurses through the heap-backed `children`
    # (finitely sized; no inline recursion).

    def serialize(self) -> String:
        var out = String("")
        self._serialize_into(out)
        return out^

    def _serialize_into(self, mut out: String):
        if self.kind == JSON_NULL:
            out += "null"
        elif self.kind == JSON_BOOL:
            out += "true" if self.bool_val else "false"
        elif self.kind == JSON_NUMBER:
            # The raw number text the parser captured (or a builder-supplied
            # already-formatted number). Empty guard -> "0" (defensive).
            if self.text.byte_length() == 0:
                out += "0"
            else:
                out += self.text
        elif self.kind == JSON_STRING:
            _append_json_string(out, self.text)
        elif self.kind == JSON_ARRAY:
            out += "["
            for i in range(len(self.children)):
                if i > 0:
                    out += ","
                self.children[i]._serialize_into(out)
            out += "]"
        else:  # JSON_OBJECT
            out += "{"
            for i in range(len(self.obj_keys)):
                if i > 0:
                    out += ","
                _append_json_string(out, self.obj_keys[i])
                out += ":"
                self.children[i]._serialize_into(out)
            out += "}"

    # An explicit destructor breaks the non-co-inductive Deinitable check on
    # this struct's recursive self-reference (Mojo 1.0.0). Field destructors
    # still run; ownership is unchanged.
    def __deinit__(deinit self):
        pass


def _append_json_string(mut out: String, s: String):
    """Append `s` as a correctly-escaped JSON string literal (with the
    surrounding double-quotes) to `out`. Escapes the RFC 8259 §7 mandatory
    set: `"` `\\` and the C0 control range (\\b \\f \\n \\r \\t named, the rest
    as `\\u00XX`). The input is treated as UTF-8 bytes already valid in their
    multibyte form (only the ASCII control + quote + backslash bytes need
    escaping; UTF-8 continuation bytes >= 0x80 pass through verbatim).

    Byte-fidelity: the escaped content is accumulated into a `List[UInt8]`
    and every non-escaped byte is copied VERBATIM (including all UTF-8
    continuation bytes >= 0x80), then appended to `out` once as an owned
    String. This mirrors the byte-level `proto3_json._write_json_string`.
    Appending each non-escaped byte via `out += chr(Int(c))` would be wrong:
    for any byte >= 0x80 it emits the CODEPOINT U+00XX re-encoded as 2-byte
    UTF-8 — double-encoding every multibyte sequence (e.g. em-dash `e2 80 94` -> `c3 a2 c2 80 c2 94`,
    the classic Latin-1<->UTF-8 double-encode)."""
    var hexdigits = "0123456789abcdef"
    var hb = hexdigits.as_bytes()
    var buf = List[UInt8]()
    buf.append(0x22)  # opening '"'
    var src = s.as_bytes()
    for i in range(len(src)):
        var c = src[i]
        if c == 0x22:  # '"'
            buf.append(0x5C)
            buf.append(0x22)
        elif c == 0x5C:  # '\'
            buf.append(0x5C)
            buf.append(0x5C)
        elif c == 0x08:  # backspace
            buf.append(0x5C)
            buf.append(0x62)  # 'b'
        elif c == 0x0C:  # form feed
            buf.append(0x5C)
            buf.append(0x66)  # 'f'
        elif c == 0x0A:  # newline
            buf.append(0x5C)
            buf.append(0x6E)  # 'n'
        elif c == 0x0D:  # carriage return
            buf.append(0x5C)
            buf.append(0x72)  # 'r'
        elif c == 0x09:  # tab
            buf.append(0x5C)
            buf.append(0x74)  # 't'
        elif c < 0x20:  # other C0 control -> \u00XX
            buf.append(0x5C)
            buf.append(0x75)  # 'u'
            buf.append(0x30)  # '0'
            buf.append(0x30)  # '0'
            buf.append(hb[(Int(c) >> 4) & 0xF])
            buf.append(hb[Int(c) & 0xF])
        else:
            # >= 0x20 and not " or \\ — includes every UTF-8 byte >= 0x80
            # (multibyte continuation bytes): copied through VERBATIM.
            buf.append(c)
    buf.append(0x22)  # closing '"'
    out += String(unsafe_from_utf8=Span(buf))


# =============================================================================
# Scalar text parsers — shared by JsonValue accessors and the JSON parser.
# =============================================================================


def _parse_int64(s: String) raises -> Int64:
    """Parse a signed decimal integer text into Int64."""
    var n = s.byte_length()
    if n == 0:
        raise Error("JsonError: empty integer text")
    var i = 0
    var neg = False
    var first = UInt8(ord(s[byte=0]))
    if first == 0x2D:  # '-'
        neg = True
        i = 1
    elif first == 0x2B:  # '+'
        i = 1
    if i >= n:
        raise Error("JsonError: integer text has no digits")
    var acc: Int64 = 0
    while i < n:
        var b = UInt8(ord(s[byte=i]))
        if b < 0x30 or b > 0x39:
            raise Error("JsonError: non-digit in integer text")
        acc = acc * 10 + Int64(Int(b) - 0x30)
        i += 1
    return -acc if neg else acc


def _parse_uint64(s: String) raises -> UInt64:
    """Parse an unsigned decimal integer text into UInt64."""
    var n = s.byte_length()
    if n == 0:
        raise Error("JsonError: empty unsigned-integer text")
    var i = 0
    if UInt8(ord(s[byte=0])) == 0x2B:  # tolerate a leading '+'
        i = 1
    if i >= n:
        raise Error("JsonError: unsigned-integer text has no digits")
    var acc: UInt64 = 0
    while i < n:
        var b = UInt8(ord(s[byte=i]))
        if b < 0x30 or b > 0x39:
            raise Error("JsonError: non-digit in unsigned-integer text")
        acc = acc * 10 + UInt64(Int(b) - 0x30)
        i += 1
    return acc


def _atof(s: String) raises -> Float64:
    """Parse a JSON number text into Float64 via the Mojo stdlib."""
    return atof(s)


# =============================================================================
# The recursive-descent JSON parser.
# =============================================================================


@always_inline
def _is_ws(b: UInt8) -> Bool:
    return b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D


def _skip_ws(b: List[UInt8], pos: Int) -> Int:
    """Advance past JSON whitespace."""
    var p = pos
    var n = len(b)
    while p < n and _is_ws(b[p]):
        p += 1
    return p


def _lit_eq(b: List[UInt8], pos: Int, lit: StringLiteral) -> Bool:
    """True if the bytes at `pos` equal the ASCII literal `lit`."""
    var s = String(lit)
    var ln = s.byte_length()
    if pos + ln > len(b):
        return False
    for k in range(ln):
        if b[pos + k] != UInt8(ord(s[byte=k])):
            return False
    return True


def _slice_string(b: List[UInt8], start: Int, end: Int) -> String:
    """The byte range `[start, end)` materialized as a String."""
    var out = List[UInt8]()
    for i in range(start, end):
        out.append(b[i])
    return String(unsafe_from_utf8=Span(out))


struct _ParseResult(Movable):
    """A parsed value + the position after it (internal threading struct).

    The heap-owning `JsonValue` is held in an `Optional` so `unwrap()` can
    extract it via `Optional.take()` — which leaves the field in a
    destructor-safe `None` state. This is the partial-move-safe primitive:
    a bare `JsonValue` field cannot be moved out
    of the middle of a struct that has a synthesized destructor."""

    var value: Optional[JsonValue]
    var new_pos: Int

    def __init__(out self, var value: JsonValue, new_pos: Int):
        self.value = Optional[JsonValue](value^)
        self.new_pos = new_pos

    def unwrap(mut self) -> JsonValue:
        """Extract the parsed value via `Optional.take()` (partial-move-safe).
        """
        return self.value.take()


struct _LineCursor(Copyable, Movable):
    """A MONOTONE byte-offset -> 1-based-line resolver.

    ⚠ WHY THIS IS NOT A `count_newlines(b, 0, pos)` HELPER. The naive form is
    O(pos) per query and the parser queries once per value, so a document with
    V values costs O(n*V) — quadratic on exactly the big machine-generated
    manifests this diagnostic exists to serve. The JSON parser only ever
    ADVANCES (no production rewinds), so a single cursor carried through the
    parse answers every query in O(n) TOTAL.

    The monotonicity is a PRECONDITION, not an assumption: `line_at` never
    walks backwards, so a hypothetical rewinding caller would get the line of
    the furthest point reached rather than a wrong-but-plausible smaller
    number. Every caller in this module queries at a non-decreasing offset.
    """

    var pos: Int
    """How many leading bytes have been counted."""
    var line: Int
    """The 1-based line number at `pos`."""

    def __init__(out self):
        self.pos = 0
        self.line = 1

    def line_at(mut self, b: List[UInt8], target: Int) -> Int:
        """The 1-based line of byte `target`. `target` must be >= `self.pos`."""
        var n = len(b)
        while self.pos < target and self.pos < n:
            if b[self.pos] == 0x0A:  # '\n'
                self.line += 1
            self.pos += 1
        return self.line


def parse_json_value(s: String) raises -> JsonValue:
    """Parse a complete JSON document into a `JsonValue`.

    Raises on malformed JSON or trailing non-whitespace content. The input
    `String` is materialized once into a `List[UInt8]` and the parser scans
    raw bytes — `ord(s[byte=i])` asserts on a non-codepoint-boundary index
    for a multibyte-UTF-8 document, so byte-level scanning is required.

    Every produced `JsonValue` carries its 1-based source line (`src_line`,
    and `key_line` for an object member) so a decoder refusal can name WHERE.
    """
    var bytes = List[UInt8]()
    var src = s.as_bytes()
    for i in range(len(src)):
        bytes.append(src[i])
    var lines = _LineCursor()
    var r = _parse_value(bytes, _skip_ws(bytes, 0), lines)
    var tail = _skip_ws(bytes, r.new_pos)
    if tail != len(bytes):
        raise Error("JsonError: trailing content after JSON document")
    return r.unwrap()


def _parse_value(
    b: List[UInt8], pos: Int, mut lines: _LineCursor
) raises -> _ParseResult:
    """Parse one JSON value starting at `pos` (whitespace already skipped)."""
    var n = len(b)
    # Resolved BEFORE descending: `pos` is this value's leftmost byte, and
    # the cursor is monotone, so it must be read before any nested parse
    # advances it.
    var here = lines.line_at(b, pos)
    if pos >= n:
        raise Error("JsonError: unexpected end of input")
    var c = b[pos]
    if c == 0x7B:  # '{'
        return _with_line(_parse_object(b, pos, lines), here)
    if c == 0x5B:  # '['
        return _with_line(_parse_array(b, pos, lines), here)
    if c == 0x22:  # '"'
        var sr = _parse_string(b, pos)
        var sr_pos = sr.new_pos
        return _with_line(
            _ParseResult(JsonValue.from_string(sr.unwrap()), sr_pos), here
        )
    if c == 0x74:  # 't' — true
        if _lit_eq(b, pos, "true"):
            return _with_line(
                _ParseResult(JsonValue.from_bool(True), pos + 4), here
            )
        raise Error("JsonError: malformed literal (expected 'true')")
    if c == 0x66:  # 'f' — false
        if _lit_eq(b, pos, "false"):
            return _with_line(
                _ParseResult(JsonValue.from_bool(False), pos + 5), here
            )
        raise Error("JsonError: malformed literal (expected 'false')")
    if c == 0x6E:  # 'n' — null
        if _lit_eq(b, pos, "null"):
            return _with_line(_ParseResult(JsonValue.null(), pos + 4), here)
        raise Error("JsonError: malformed literal (expected 'null')")
    # Otherwise a number: '-' or a digit.
    if c == 0x2D or (c >= 0x30 and c <= 0x39):
        return _with_line(_parse_number(b, pos), here)
    raise Error("JsonError: unexpected character at value start")


def _with_line(var r: _ParseResult, line: Int) -> _ParseResult:
    """Stamp `line` onto the parsed value — ONE place, so no production of
    `_parse_value` can return an unstamped value by omission."""
    var new_pos = r.new_pos
    var v = r.unwrap()
    v.src_line = line
    return _ParseResult(v^, new_pos)


struct _StringResult(Movable):
    var value: Optional[String]
    var new_pos: Int

    def __init__(out self, var value: String, new_pos: Int):
        self.value = Optional[String](value^)
        self.new_pos = new_pos

    def unwrap(mut self) -> String:
        """Extract the parsed string via `Optional.take()` (partial-move-safe).
        """
        return self.value.take()


def _parse_string(b: List[UInt8], pos: Int) raises -> _StringResult:
    """Parse a JSON string literal starting at the opening `"`; the returned
    value is the UNESCAPED content."""
    var n = len(b)
    var p = pos + 1  # past the opening quote
    var out = List[UInt8]()
    while p < n:
        var c = b[p]
        if c == 0x22:  # closing '"'
            return _StringResult(String(unsafe_from_utf8=Span(out)), p + 1)
        if c == 0x5C:  # backslash escape
            p += 1
            if p >= n:
                raise Error("JsonError: dangling escape in string")
            var e = b[p]
            if e == 0x22:
                out.append(0x22)
            elif e == 0x5C:
                out.append(0x5C)
            elif e == 0x2F:  # '/'
                out.append(0x2F)
            elif e == 0x6E:  # 'n'
                out.append(0x0A)
            elif e == 0x72:  # 'r'
                out.append(0x0D)
            elif e == 0x74:  # 't'
                out.append(0x09)
            elif e == 0x62:  # 'b'
                out.append(0x08)
            elif e == 0x66:  # 'f'
                out.append(0x0C)
            elif e == 0x75:  # '\uXXXX'
                if p + 4 >= n:
                    raise Error("JsonError: truncated \\u escape")
                var cp = _hex4(b, p + 1)
                _append_utf8(out, cp)
                p += 4
            else:
                raise Error("JsonError: unknown string escape")
            p += 1
        else:
            out.append(c)
            p += 1
    raise Error("JsonError: unterminated string")


def _hex4(b: List[UInt8], pos: Int) raises -> Int:
    """Parse a 4-hex-digit code unit."""
    var acc = 0
    for k in range(4):
        var c = b[pos + k]
        var d: Int
        if c >= 0x30 and c <= 0x39:
            d = Int(c) - 0x30
        elif c >= 0x41 and c <= 0x46:
            d = Int(c) - 0x41 + 10
        elif c >= 0x61 and c <= 0x66:
            d = Int(c) - 0x61 + 10
        else:
            raise Error("JsonError: bad hex digit in \\u escape")
        acc = (acc << 4) | d
    return acc


def _append_utf8(mut out: List[UInt8], cp: Int):
    """Append a Unicode code point to `out` as UTF-8 (BMP — no surrogate
    pairing; sufficient for the proto3-JSON field-name / value corpus)."""
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _parse_number(b: List[UInt8], pos: Int) raises -> _ParseResult:
    """Parse a JSON number — keep its raw text verbatim."""
    var n = len(b)
    var p = pos
    # Sign.
    if p < n and b[p] == 0x2D:
        p += 1
    # Integer / fraction / exponent — accept the JSON number grammar
    # liberally; the value accessors do the strict parse.
    while p < n:
        var c = b[p]
        var num_char = (
            (c >= 0x30 and c <= 0x39)
            or c == 0x2E  # '.'
            or c == 0x65  # 'e'
            or c == 0x45  # 'E'
            or c == 0x2B  # '+'
            or c == 0x2D  # '-'
        )
        if not num_char:
            break
        p += 1
    if p == pos:
        raise Error("JsonError: empty number")
    return _ParseResult(JsonValue.from_number(_slice_string(b, pos, p)), p)


def _parse_array(
    b: List[UInt8], pos: Int, mut lines: _LineCursor
) raises -> _ParseResult:
    """Parse a JSON array starting at `[`."""
    var n = len(b)
    var p = _skip_ws(b, pos + 1)
    var arr = JsonValue()
    arr.kind = JSON_ARRAY
    if p < n and b[p] == 0x5D:  # ']'
        return _ParseResult(arr^, p + 1)
    while True:
        var elem = _parse_value(b, _skip_ws(b, p), lines)
        var elem_pos = elem.new_pos
        arr.children.append(elem.unwrap())
        p = _skip_ws(b, elem_pos)
        if p >= n:
            raise Error("JsonError: unterminated array")
        var c = b[p]
        if c == 0x2C:  # ','
            p += 1
            continue
        if c == 0x5D:  # ']'
            return _ParseResult(arr^, p + 1)
        raise Error("JsonError: expected ',' or ']' in array")


def _parse_object(
    b: List[UInt8], pos: Int, mut lines: _LineCursor
) raises -> _ParseResult:
    """Parse a JSON object starting at `{`."""
    var n = len(b)
    var p = _skip_ws(b, pos + 1)
    var obj = JsonValue()
    obj.kind = JSON_OBJECT
    if p < n and b[p] == 0x7D:  # '}'
        return _ParseResult(obj^, p + 1)
    while True:
        p = _skip_ws(b, p)
        if p >= n or b[p] != 0x22:
            raise Error("JsonError: expected object key string")
        # The KEY's line, resolved at the key's opening quote and BEFORE the
        # value is parsed (the cursor is monotone).
        var key_line = lines.line_at(b, p)
        var key = _parse_string(b, p)
        p = _skip_ws(b, key.new_pos)
        if p >= n or b[p] != 0x3A:  # ':'
            raise Error("JsonError: expected ':' after object key")
        var valr = _parse_value(b, _skip_ws(b, p + 1), lines)
        var valr_pos = valr.new_pos
        obj.obj_keys.append(key.unwrap())
        var child = valr.unwrap()
        child.key_line = key_line
        obj.children.append(child^)
        p = _skip_ws(b, valr_pos)
        if p >= n:
            raise Error("JsonError: unterminated object")
        var c = b[p]
        if c == 0x2C:  # ','
            p += 1
            continue
        if c == 0x7D:  # '}'
            return _ParseResult(obj^, p + 1)
        raise Error("JsonError: expected ',' or '}' in object")
