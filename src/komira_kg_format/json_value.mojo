# =============================================================================
# json_value -- a small recursive-descent JSON value tree and parser.
# =============================================================================
#
# Reads one JSON text into a tree that is navigated by key and index: used for a
# model's chat-completion envelope and for the extraction payload the model
# emits inside `choices[0].message.content` (a JSON string inside a JSON string,
# two parse levels over arbitrary keys). It is a thin general reader with no
# schema and no column machinery; for per-record JSONL use `komira_json`.
#
# GRAMMAR: RFC 8259 objects, arrays, strings, numbers, true, false, null. A
# number must match the RFC grammar exactly (`-?(0|[1-9][0-9]*)(.[0-9]+)?
# ([eE][+-]?[0-9]+)?`); a raw control character inside a string is refused;
# the escapes are \" \\ \/ \b \f \n \r \t and \uXXXX, where a UTF-16
# surrogate pair makes one code point and a lone surrogate is refused. Nesting
# deeper than `JSON_MAX_DEPTH` is refused, so a hostile input cannot exhaust the
# stack. Text after the root value, other than white space, is refused.
#
# It is not a streaming parser and not tuned for speed: response bodies are
# kilobytes, parsed once per call.
#
# OWNERSHIP: owned `String` and `List` only. The recursive shape is a flat node
# arena (`List`) addressed by index, so no node owns another and the tree needs
# no self-referential field. A `JsonValue` is a handle (a node index plus a
# borrow of the `JsonDoc`) and cannot outlive the document.
# =============================================================================

from .utf8_check import bytes_are_utf8


# The deepest nesting of arrays and objects the parser accepts.
comptime JSON_MAX_DEPTH: Int = 128


# Node kind tags. A JSON value is exactly one of these.
comptime JSON_NULL: Int = 0
comptime JSON_BOOL: Int = 1
comptime JSON_NUMBER: Int = 2
comptime JSON_STRING: Int = 3
comptime JSON_ARRAY: Int = 4
comptime JSON_OBJECT: Int = 5


# -----------------------------------------------------------------------------
# _JsonNode — one node in the flat arena. The recursive shape is encoded by
# index references, NOT nested ownership:
#   * STRING / NUMBER carry their text in `text` (number kept as text so the
#     consumer chooses Int / Float parsing).
#   * BOOL carries 0/1 in `bool_val`.
#   * ARRAY carries its element node-indices in `child_idx`.
#   * OBJECT carries its keys in `obj_keys` and the matching value node-indices
#     in `child_idx` (parallel lists; same length).
# Copyable+Movable POD-ish: only String + List[String] + List[Int] + Int fields
# (all Copyable), so the arena List[_JsonNode] is valid.
# -----------------------------------------------------------------------------
@fieldwise_init
struct _JsonNode(Copyable, Movable):
    var kind: Int
    var text: String
    var bool_val: Int
    var child_idx: List[Int]
    var obj_keys: List[String]

    @staticmethod
    def make_null() -> _JsonNode:
        return _JsonNode(JSON_NULL, String(""), 0, List[Int](), List[String]())

    @staticmethod
    def make_bool(v: Bool) -> _JsonNode:
        return _JsonNode(
            JSON_BOOL, String(""), 1 if v else 0, List[Int](), List[String]()
        )

    @staticmethod
    def make_number(var t: String) -> _JsonNode:
        return _JsonNode(JSON_NUMBER, t^, 0, List[Int](), List[String]())

    @staticmethod
    def make_string(var t: String) -> _JsonNode:
        return _JsonNode(JSON_STRING, t^, 0, List[Int](), List[String]())

    @staticmethod
    def make_array() -> _JsonNode:
        return _JsonNode(JSON_ARRAY, String(""), 0, List[Int](), List[String]())

    @staticmethod
    def make_object() -> _JsonNode:
        return _JsonNode(
            JSON_OBJECT, String(""), 0, List[Int](), List[String]()
        )


# -----------------------------------------------------------------------------
# JsonDoc — the owning document: the node arena + the root node index. All
# `JsonValue` handles borrow into this doc. Parse once, query many.
# -----------------------------------------------------------------------------
struct JsonDoc(Movable):
    """A parsed JSON document: a flat arena of nodes + the root index.

    Build with `JsonDoc.parse(text)`. Navigate with `root()` then the
    `JsonValue` accessors (`get`, `at`, `len`, `as_string`, `as_bool`,
    `as_int`, `as_float`). All navigation is by node index into this doc's
    arena, so there is no self-referential ownership.
    """

    var _nodes: List[_JsonNode]
    var _root: Int

    def __init__(out self):
        """An empty doc whose root is JSON_NULL."""
        self._nodes = List[_JsonNode]()
        self._nodes.append(_JsonNode.make_null())
        self._root = 0

    @staticmethod
    def parse(text: String) raises -> JsonDoc:
        """Parse `text` into a JsonDoc. Raises on malformed JSON."""
        var p = _Parser(text)
        var doc = JsonDoc()
        # Reset the doc's arena (the default ctor seeded a null root).
        doc._nodes = List[_JsonNode]()
        doc._root = p.parse_into(doc._nodes)
        p.expect_end()
        return doc^

    def root(self) -> JsonValue[origin_of(self)]:
        """The root value handle."""
        return JsonValue[origin_of(self)](self, self._root)

    # ----- arena accessors (used by JsonValue, package-internal) -----
    def _node_kind(self, idx: Int) -> Int:
        return self._nodes[idx].kind

    def _node_text(self, idx: Int) -> String:
        return self._nodes[idx].text

    def _node_bool(self, idx: Int) -> Bool:
        return self._nodes[idx].bool_val != 0

    def _node_child_count(self, idx: Int) -> Int:
        return len(self._nodes[idx].child_idx)

    def _node_child_at(self, idx: Int, i: Int) -> Int:
        return self._nodes[idx].child_idx[i]

    def _node_obj_key_at(self, idx: Int, i: Int) -> String:
        return self._nodes[idx].obj_keys[i]


# -----------------------------------------------------------------------------
# JsonValue — a borrowing handle to one node in a JsonDoc. Cheap (a ref + an
# Int index). Navigation methods return new handles into the same doc.
# -----------------------------------------------------------------------------
struct JsonValue[doc_origin: Origin[mut=False]](Copyable, Movable):
    """A handle to one node in a JsonDoc. Borrows the doc immutably.

    Accessors:
      * `kind()` — one of the JSON_* tags.
      * `is_null()` / `is_object()` / `is_array()` / `is_string()`.
      * `get(key)` — object field by key (raises if not an object / missing).
      * `has(key)` — True iff this is an object with that key.
      * `at(i)` — array element by index (raises if not an array / OOB).
      * `len()` — array element count (0 for non-arrays).
      * `as_string()` / `as_bool()` / `as_int()` / `as_float()` — leaf reads.
    """

    # SAFETY: a borrow of the owning `JsonDoc`, held as a `Pointer` with the
    # document's own immutable origin (`doc_origin`), so the compiler keeps the
    # document alive while any handle exists. The field is private and appears in
    # no public signature; callers pass and receive `ref` and handles.
    var _doc: Pointer[JsonDoc, Self.doc_origin]
    var _idx: Int

    def __init__(out self, ref [Self.doc_origin]doc: JsonDoc, idx: Int):
        self._doc = Pointer(to=doc)
        self._idx = idx

    def kind(self) -> Int:
        return self._doc[]._node_kind(self._idx)

    def is_null(self) -> Bool:
        return self.kind() == JSON_NULL

    def is_object(self) -> Bool:
        return self.kind() == JSON_OBJECT

    def is_array(self) -> Bool:
        return self.kind() == JSON_ARRAY

    def is_string(self) -> Bool:
        return self.kind() == JSON_STRING

    def has(self, key: String) -> Bool:
        """True iff this is an object carrying `key`."""
        if self.kind() != JSON_OBJECT:
            return False
        var n = self._doc[]._node_child_count(self._idx)
        for i in range(n):
            if self._doc[]._node_obj_key_at(self._idx, i) == key:
                return True
        return False

    def get(self, key: String) raises -> JsonValue[Self.doc_origin]:
        """Object field by key. Raises if not an object or key absent."""
        if self.kind() != JSON_OBJECT:
            raise Error("JsonValue.get: not an object (key='" + key + "')")
        var n = self._doc[]._node_child_count(self._idx)
        for i in range(n):
            if self._doc[]._node_obj_key_at(self._idx, i) == key:
                var child = self._doc[]._node_child_at(self._idx, i)
                return JsonValue[Self.doc_origin](self._doc[], child)
        raise Error("JsonValue.get: missing key '" + key + "'")

    def len(self) -> Int:
        """Array element count (0 if not an array)."""
        if self.kind() != JSON_ARRAY:
            return 0
        return self._doc[]._node_child_count(self._idx)

    def num_fields(self) -> Int:
        """The number of key/value fields in an OBJECT (0 for a non-object). Pairs
        with `field_key_at(i)` / `field_value_at(i)` to iterate an object whose
        keys are not known ahead of time (for example a record's user-named
        `properties`)."""
        if self.kind() != JSON_OBJECT:
            return 0
        return self._doc[]._node_child_count(self._idx)

    def field_key_at(self, i: Int) raises -> String:
        """The KEY of the i-th field of an OBJECT. Raises if not an object or the
        index is out of bounds."""
        if self.kind() != JSON_OBJECT:
            raise Error("JsonValue.field_key_at: not an object")
        var n = self._doc[]._node_child_count(self._idx)
        if i < 0 or i >= n:
            raise Error("JsonValue.field_key_at: index out of bounds")
        return self._doc[]._node_obj_key_at(self._idx, i)

    def field_value_at(self, i: Int) raises -> JsonValue[Self.doc_origin]:
        """The VALUE handle of the i-th field of an OBJECT. Raises if not an
        object or the index is out of bounds."""
        if self.kind() != JSON_OBJECT:
            raise Error("JsonValue.field_value_at: not an object")
        var n = self._doc[]._node_child_count(self._idx)
        if i < 0 or i >= n:
            raise Error("JsonValue.field_value_at: index out of bounds")
        var child = self._doc[]._node_child_at(self._idx, i)
        return JsonValue[Self.doc_origin](self._doc[], child)

    def at(self, i: Int) raises -> JsonValue[Self.doc_origin]:
        """Array element by index. Raises if not an array or out of bounds."""
        if self.kind() != JSON_ARRAY:
            raise Error("JsonValue.at: not an array")
        var n = self._doc[]._node_child_count(self._idx)
        if i < 0 or i >= n:
            raise Error("JsonValue.at: index out of bounds")
        var child = self._doc[]._node_child_at(self._idx, i)
        return JsonValue[Self.doc_origin](self._doc[], child)

    def as_string(self) raises -> String:
        """The string value. Raises if not a string."""
        if self.kind() != JSON_STRING:
            raise Error("JsonValue.as_string: not a string")
        return self._doc[]._node_text(self._idx)

    def as_bool(self) raises -> Bool:
        """The bool value. Raises if not a bool."""
        if self.kind() != JSON_BOOL:
            raise Error("JsonValue.as_bool: not a bool")
        return self._doc[]._node_bool(self._idx)

    def as_int(self) raises -> Int:
        """The number value parsed as Int. Raises if not a number."""
        if self.kind() != JSON_NUMBER:
            raise Error("JsonValue.as_int: not a number")
        return Int(self._doc[]._node_text(self._idx))

    def as_float(self) raises -> Float64:
        """The number value parsed as Float64. Raises if not a number."""
        if self.kind() != JSON_NUMBER:
            raise Error("JsonValue.as_float: not a number")
        return Float64(self._doc[]._node_text(self._idx))

    def as_string_or(self, default: String) -> String:
        """The string value, or `default` if this is not a string."""
        if self.kind() != JSON_STRING:
            return default
        return self._doc[]._node_text(self._idx)


# -----------------------------------------------------------------------------
# _Parser — recursive-descent JSON parser over a String. Emits nodes into a
# caller-owned arena and returns the root index. Internal to this module.
# -----------------------------------------------------------------------------
struct _Parser(Movable):
    var _bytes: List[UInt8]
    var _pos: Int
    var _len: Int
    var _depth: Int

    def __init__(out self, text: String):
        self._bytes = List[UInt8]()
        var src = text.as_bytes()
        for i in range(len(src)):
            self._bytes.append(src[i])
        self._pos = 0
        self._len = len(self._bytes)
        self._depth = 0

    def _peek(self) -> Int:
        if self._pos >= self._len:
            return -1
        return Int(self._bytes[self._pos])

    def _advance(mut self) -> Int:
        var c = self._peek()
        self._pos += 1
        return c

    def _skip_ws(mut self):
        while self._pos < self._len:
            var c = Int(self._bytes[self._pos])
            # space, tab, newline, carriage return.
            if c == 32 or c == 9 or c == 10 or c == 13:
                self._pos += 1
            else:
                break

    def parse_into(mut self, mut arena: List[_JsonNode]) raises -> Int:
        """Parse one value at the current position; emit nodes into `arena`;
        return the root node index."""
        self._skip_ws()
        var c = self._peek()
        if c == -1:
            raise Error("JSON parse: unexpected end of input")
        if c == ord("{"):
            return self._parse_object(arena)
        if c == ord("["):
            return self._parse_array(arena)
        if c == ord('"'):
            var s = self._parse_string_text()
            arena.append(_JsonNode.make_string(s^))
            return len(arena) - 1
        if c == ord("t") or c == ord("f"):
            return self._parse_bool(arena)
        if c == ord("n"):
            return self._parse_null(arena)
        # number (digit or '-').
        if c == ord("-") or (c >= ord("0") and c <= ord("9")):
            return self._parse_number(arena)
        raise Error(
            "JSON parse: unexpected char '" + chr(c) + "' at pos "
            + String(self._pos)
        )

    def _enter(mut self) raises:
        self._depth += 1
        if self._depth > JSON_MAX_DEPTH:
            raise Error(
                "JSON parse: nesting deeper than " + String(JSON_MAX_DEPTH)
            )

    def _parse_object(mut self, mut arena: List[_JsonNode]) raises -> Int:
        # Consume '{'.
        _ = self._advance()
        self._enter()
        var node = _JsonNode.make_object()
        self._skip_ws()
        if self._peek() == ord("}"):
            _ = self._advance()
            self._depth -= 1
            arena.append(node^)
            return len(arena) - 1
        while True:
            self._skip_ws()
            if self._peek() != ord('"'):
                raise Error("JSON parse: expected string key in object")
            var key = self._parse_string_text()
            self._skip_ws()
            if self._advance() != ord(":"):
                raise Error("JSON parse: expected ':' after object key")
            var val_idx = self.parse_into(arena)
            node.obj_keys.append(key^)
            node.child_idx.append(val_idx)
            self._skip_ws()
            var sep = self._advance()
            if sep == ord("}"):
                break
            if sep != ord(","):
                raise Error("JSON parse: expected ',' or '}' in object")
        self._depth -= 1
        arena.append(node^)
        return len(arena) - 1

    def _parse_array(mut self, mut arena: List[_JsonNode]) raises -> Int:
        # Consume '['.
        _ = self._advance()
        self._enter()
        var node = _JsonNode.make_array()
        self._skip_ws()
        if self._peek() == ord("]"):
            _ = self._advance()
            self._depth -= 1
            arena.append(node^)
            return len(arena) - 1
        while True:
            var val_idx = self.parse_into(arena)
            node.child_idx.append(val_idx)
            self._skip_ws()
            var sep = self._advance()
            if sep == ord("]"):
                break
            if sep != ord(","):
                raise Error("JSON parse: expected ',' or ']' in array")
        self._depth -= 1
        arena.append(node^)
        return len(arena) - 1

    def _parse_bool(mut self, mut arena: List[_JsonNode]) raises -> Int:
        if self._peek() == ord("t"):
            self._match_literal("true")
            arena.append(_JsonNode.make_bool(True))
        else:
            self._match_literal("false")
            arena.append(_JsonNode.make_bool(False))
        return len(arena) - 1

    def _parse_null(mut self, mut arena: List[_JsonNode]) raises -> Int:
        self._match_literal("null")
        arena.append(_JsonNode.make_null())
        return len(arena) - 1

    def _match_literal(mut self, lit: String) raises:
        var lb = lit.as_bytes()
        for i in range(len(lb)):
            if self._advance() != Int(lb[i]):
                raise Error("JSON parse: bad literal, expected '" + lit + "'")

    def _digits(mut self) -> Int:
        """Consume a run of ASCII digits; return how many."""
        var n = 0
        while self._pos < self._len:
            var c = Int(self._bytes[self._pos])
            if c < ord("0") or c > ord("9"):
                break
            self._pos += 1
            n += 1
        return n

    def _parse_number(mut self, mut arena: List[_JsonNode]) raises -> Int:
        """RFC 8259 number: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?"""
        var start = self._pos
        if self._peek() == ord("-"):
            self._pos += 1
        if self._peek() == ord("0"):
            self._pos += 1
        elif self._digits() == 0:
            raise Error("JSON parse: bad number at pos " + String(start))
        if self._peek() == ord("."):
            self._pos += 1
            if self._digits() == 0:
                raise Error("JSON parse: bad fraction at pos " + String(start))
        if self._peek() == ord("e") or self._peek() == ord("E"):
            self._pos += 1
            if self._peek() == ord("+") or self._peek() == ord("-"):
                self._pos += 1
            if self._digits() == 0:
                raise Error("JSON parse: bad exponent at pos " + String(start))
        var text = self._slice(start, self._pos)
        arena.append(_JsonNode.make_number(text^))
        return len(arena) - 1

    def _parse_string_text(mut self) raises -> String:
        """Parse a JSON string starting at its opening quote and return the
        decoded text.

        The content is accumulated as raw bytes and the `String` is built once,
        so multi-byte UTF-8 in the input passes through unchanged (a per-byte
        `chr` would promote each continuation byte to a code point and double
        it). Only a `\\uXXXX` escape encodes a code point. The finished bytes
        are checked as UTF-8 before they become a `String`.
        """
        if self._advance() != ord('"'):
            raise Error("JSON parse: expected opening '\"'")
        var buf = List[UInt8]()
        while True:
            var c = self._advance()
            if c == -1:
                raise Error("JSON parse: unterminated string")
            if c == ord('"'):
                break
            if c < 0x20:
                raise Error(
                    "JSON parse: raw control character in string at pos "
                    + String(self._pos - 1)
                )
            if c == ord("\\"):
                var e = self._advance()
                if e == ord('"'):
                    buf.append(UInt8(0x22))
                elif e == ord("\\"):
                    buf.append(UInt8(0x5C))
                elif e == ord("/"):
                    buf.append(UInt8(0x2F))
                elif e == ord("n"):
                    buf.append(UInt8(0x0A))
                elif e == ord("r"):
                    buf.append(UInt8(0x0D))
                elif e == ord("t"):
                    buf.append(UInt8(0x09))
                elif e == ord("b"):
                    buf.append(UInt8(0x08))
                elif e == ord("f"):
                    buf.append(UInt8(0x0C))
                elif e == ord("u"):
                    var cp = self._parse_hex4()
                    if cp >= 0xD800 and cp <= 0xDBFF:
                        # A high surrogate must be followed by \uDC00..\uDFFF.
                        if self._advance() != ord("\\") or self._advance() != ord(
                            "u"
                        ):
                            raise Error("JSON parse: lone high surrogate")
                        var lo = self._parse_hex4()
                        if lo < 0xDC00 or lo > 0xDFFF:
                            raise Error("JSON parse: lone high surrogate")
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    elif cp >= 0xDC00 and cp <= 0xDFFF:
                        raise Error("JSON parse: lone low surrogate")
                    _append_utf8_from_codepoint(buf, cp)
                else:
                    raise Error("JSON parse: bad escape")
            else:
                # A raw byte (ASCII, or a UTF-8 lead or continuation byte):
                # appended verbatim.
                buf.append(UInt8(c))
        if not bytes_are_utf8(Span(buf)):
            raise Error("JSON parse: string is not valid UTF-8")
        return String(unsafe_from_utf8=Span(buf))

    def _parse_hex4(mut self) raises -> Int:
        var v = 0
        for _ in range(4):
            var c = self._advance()
            var d: Int
            if c >= ord("0") and c <= ord("9"):
                d = c - ord("0")
            elif c >= ord("a") and c <= ord("f"):
                d = c - ord("a") + 10
            elif c >= ord("A") and c <= ord("F"):
                d = c - ord("A") + 10
            else:
                raise Error("JSON parse: bad \\u hex digit")
            v = v * 16 + d
        return v

    def _slice(self, start: Int, end: Int) -> String:
        var out = String("")
        for i in range(start, end):
            out += chr(Int(self._bytes[i]))
        return out^

    def expect_end(mut self) raises:
        """After the root value, only trailing whitespace is allowed."""
        self._skip_ws()
        if self._pos < self._len:
            raise Error(
                "JSON parse: trailing characters after root value at pos "
                + String(self._pos)
            )


# -----------------------------------------------------------------------------
# _append_utf8_from_codepoint -- append a code point (0..0x10FFFF, never a
# surrogate: the caller has refused those) to `buf` as its UTF-8 bytes.
# -----------------------------------------------------------------------------
def _append_utf8_from_codepoint(mut buf: List[UInt8], cp: Int):
    if cp < 0x80:
        buf.append(UInt8(cp))
    elif cp < 0x800:
        buf.append(UInt8(0xC0 | (cp >> 6)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        buf.append(UInt8(0xE0 | (cp >> 12)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        buf.append(UInt8(0xF0 | (cp >> 18)))
        buf.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        buf.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        buf.append(UInt8(0x80 | (cp & 0x3F)))
