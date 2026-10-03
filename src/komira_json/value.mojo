# =============================================================================
# value.mojo: `JsonValue`, the JSON value model.
# =============================================================================
#
# `JsonValue` is a tagged value: Null / Bool / Number / String / Array /
# Object. A Number keeps its source text verbatim (`text`), so a caller can
# tell `1` from `1.0`, keep every digit of an integer wider than a Float64
# mantissa, and parse the text with the width it needs (`as_int64`,
# `as_uint64`, `as_float64`). A String holds its already-unescaped UTF-8
# content in `text`.
#
# A value comes from `parse_json_value` (parse.mojo) or is built with the
# constructors and builder verbs below, and renders with `serialize()`.
#
# Encapsulation: an owned recursive value over owned `String` / `List`
# storage; no pointers. The Array / Object arms keep their children in a
# heap-backed `List[JsonValue]`, which is what makes the recursive type
# finitely sized.
# =============================================================================

from .write import (
    write_json_string,
    write_json_null,
    write_json_bool,
    write_i64_dec,
    write_u64_dec,
    write_f64_dtoa,
    _is_nan_f64,
    _is_inf_f64,
)


# JSON value kind tags (`JsonValue.kind`).
comptime JSON_NULL: Int = 0
comptime JSON_BOOL: Int = 1
comptime JSON_NUMBER: Int = 2
comptime JSON_STRING: Int = 3
comptime JSON_ARRAY: Int = 4
comptime JSON_OBJECT: Int = 5


struct JsonValue(Copyable, Movable):
    """A JSON value: a tagged union over the six JSON kinds.

    A Number keeps its raw source text in `text`; a String keeps its
    unescaped content in `text`. An Object's keys live in `obj_keys` and its
    values in `children`, positionally aligned, in document order (duplicate
    keys are kept; `get` returns the first). An Array's elements live in
    `children`.
    """

    var kind: Int
    var bool_val: Bool
    var text: String
    var children: List[JsonValue]
    var obj_keys: List[String]

    # Source locators, so a consumer's diagnostic can name WHERE.
    #
    # `src_line` is the 1-based line the value's own first byte is on.
    # `key_line` is the 1-based line of the value's object KEY, set only on
    # an object member: that, not the value, is where a reader looks for a
    # misspelled field name, and the two differ for `"k":\n  {...}`.
    #
    # 0 means UNKNOWN: a value built in code has no source position, and a
    # diagnostic must say so rather than print `line 0`.
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

    def __init__(out self, *, copy: Self):
        """Deep copy, field by field, recursing through `children`.

        Explicit so the type never has a trivial copy constructor: Mojo
        1.0.0 can treat a synthesized one as trivial for some layouts of a
        struct with an explicit `__deinit__`, and `List.copy()` then
        memcpys the elements, sharing their heap buffers with the
        originals (tests/test_json_list_copy.mojo)."""
        self.kind = copy.kind
        self.bool_val = copy.bool_val
        self.text = copy.text.copy()
        self.children = copy.children.copy()
        self.obj_keys = copy.obj_keys.copy()
        self.src_line = copy.src_line
        self.key_line = copy.key_line

    def copy(self) -> Self:
        """Deep clone (the `Copyable` conformance over the recursive
        children)."""
        return Self(copy=self)

    # =========================================================================
    # Scalar constructors.
    # =========================================================================

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
        """A Number whose text is `raw`, unchecked: `serialize()` writes it
        verbatim, so `raw` must already be a valid JSON number. To build a
        number from a typed value use `from_i64` / `from_u64` / `from_f64`."""
        var v = JsonValue()
        v.kind = JSON_NUMBER
        v.text = raw^
        return v^

    @staticmethod
    def from_i64(n: Int64) -> JsonValue:
        """A Number holding the decimal text of `n`."""
        var buf = List[UInt8]()
        write_i64_dec(buf, n)
        return JsonValue.from_number(String(unsafe_from_utf8=Span(buf)))

    @staticmethod
    def from_u64(n: UInt64) -> JsonValue:
        """A Number holding the decimal text of `n`."""
        var buf = List[UInt8]()
        write_u64_dec(buf, n)
        return JsonValue.from_number(String(unsafe_from_utf8=Span(buf)))

    @staticmethod
    def from_f64(x: Float64) -> JsonValue:
        """A Number holding the shortest round-trip text of `x`; NaN and
        +/-Inf have no JSON number form and give a Null (as
        `write_f64_dtoa` writes them)."""
        if _is_nan_f64(x) or _is_inf_f64(x):
            return JsonValue.null()
        var buf = List[UInt8]()
        write_f64_dtoa(buf, x)
        return JsonValue.from_number(String(unsafe_from_utf8=Span(buf)))

    @staticmethod
    def from_string(var s: String) -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_STRING
        v.text = s^
        return v^

    # =========================================================================
    # Kind tests.
    # =========================================================================

    @always_inline
    def kind_tag(self) -> Int:
        """This value's kind tag (JSON_NULL ... JSON_OBJECT)."""
        return self.kind

    @always_inline
    def is_null(self) -> Bool:
        return self.kind == JSON_NULL

    @always_inline
    def is_bool(self) -> Bool:
        return self.kind == JSON_BOOL

    @always_inline
    def is_number(self) -> Bool:
        return self.kind == JSON_NUMBER

    @always_inline
    def is_string(self) -> Bool:
        return self.kind == JSON_STRING

    @always_inline
    def is_array(self) -> Bool:
        return self.kind == JSON_ARRAY

    @always_inline
    def is_object(self) -> Bool:
        return self.kind == JSON_OBJECT

    def is_integral_number(self) -> Bool:
        """True iff this is a Number whose text has no `.`, `e` or `E`."""
        if self.kind != JSON_NUMBER:
            return False
        var src = self.text.as_bytes()
        for i in range(len(src)):
            var c = src[i]
            if c == 0x2E or c == 0x65 or c == 0x45:  # '.' / 'e' / 'E'
                return False
        return True

    # =========================================================================
    # Typed accessors. Each raises `JsonError: ...` on the wrong kind.
    # =========================================================================

    def as_bool(self) raises -> Bool:
        if self.kind != JSON_BOOL:
            raise Error("JsonError: as_bool() on a non-bool value")
        return self.bool_val

    def as_string(self) raises -> String:
        if self.kind != JSON_STRING:
            raise Error("JsonError: as_string() on a non-string value")
        return self.text

    def as_int64(self) raises -> Int64:
        """The value as an Int64. Both a Number and a String are accepted
        (proto3 JSON carries int64 as a string), through
        `parse_int64_text`: an optional sign and decimal digits only, so
        `1.0` and `1e3` are refused, and so is a value outside Int64."""
        if self.kind != JSON_NUMBER and self.kind != JSON_STRING:
            raise Error("JsonError: as_int64() on a non-numeric value")
        return parse_int64_text(self.text)

    def as_uint64(self) raises -> UInt64:
        """The value as a UInt64 (a Number or a String), through
        `parse_uint64_text`."""
        if self.kind != JSON_NUMBER and self.kind != JSON_STRING:
            raise Error("JsonError: as_uint64() on a non-numeric value")
        return parse_uint64_text(self.text)

    def as_float64(self) raises -> Float64:
        """The value as a Float64 (a Number or a String), through the
        stdlib `atof`. A Number's text is always valid JSON number text; a
        String's text is whatever `atof` accepts."""
        if self.kind != JSON_NUMBER and self.kind != JSON_STRING:
            raise Error("JsonError: as_float64() on a non-numeric value")
        return Float64(atof(self.text))

    # =========================================================================
    # Object access.
    # =========================================================================

    def has(self, key: String) -> Bool:
        """True iff `self` is an Object with a member `key`."""
        if self.kind != JSON_OBJECT:
            return False
        for i in range(len(self.obj_keys)):
            if self.obj_keys[i] == key:
                return True
        return False

    def get(self, key: String) raises -> JsonValue:
        """A copy of the value of the first member `key`. Raises if `self`
        is not an Object or has no such member."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: get() on a non-object value")
        for i in range(len(self.obj_keys)):
            if self.obj_keys[i] == key:
                return self.children[i].copy()
        raise Error(String("JsonError: object has no key '") + key + "'")

    @always_inline
    def num_members(self) -> Int:
        """The number of members of an Object (0 for any other kind)."""
        if self.kind != JSON_OBJECT:
            return 0
        return len(self.obj_keys)

    def key_at(self, i: Int) raises -> String:
        """The i-th member key of an Object. Raises if `self` is not an
        Object or `i` is out of range."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: key_at() on a non-object value")
        if i < 0 or i >= len(self.obj_keys):
            raise Error("JsonError: key_at() index out of range")
        return self.obj_keys[i]

    def value_at(self, i: Int) raises -> JsonValue:
        """A copy of the i-th member value of an Object. Raises if `self` is
        not an Object or `i` is out of range."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: value_at() on a non-object value")
        if i < 0 or i >= len(self.children):
            raise Error("JsonError: value_at() index out of range")
        return self.children[i].copy()

    def value_kind(self, i: Int) raises -> Int:
        """The kind tag of the i-th member value of an Object, read without
        copying the value. Raises if `self` is not an Object or `i` is out
        of range."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: value_kind() on a non-object value")
        if i < 0 or i >= len(self.children):
            raise Error("JsonError: value_kind() index out of range")
        return self.children[i].kind

    # =========================================================================
    # Array access.
    # =========================================================================

    @always_inline
    def array_len(self) -> Int:
        """The number of elements of an Array (0 for any other kind)."""
        if self.kind != JSON_ARRAY:
            return 0
        return len(self.children)

    def element_at(self, i: Int) raises -> JsonValue:
        """A copy of the i-th element of an Array. Raises if `self` is not
        an Array or `i` is out of range."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonError: element_at() on a non-array value")
        if i < 0 or i >= len(self.children):
            raise Error("JsonError: element_at() index out of range")
        return self.children[i].copy()

    # =========================================================================
    # Builders.
    # =========================================================================

    @staticmethod
    def empty_object() -> JsonValue:
        """`{}`; add members with `set_member`."""
        var v = JsonValue()
        v.kind = JSON_OBJECT
        return v^

    @staticmethod
    def empty_array() -> JsonValue:
        """`[]`; add elements with `push`."""
        var v = JsonValue()
        v.kind = JSON_ARRAY
        return v^

    def set_member(mut self, var key: String, var value: JsonValue) raises:
        """Append a member to an Object. Raises if `self` is not an Object.
        Keys are not de-duplicated: building a well-formed object is the
        caller's job."""
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: set_member() on a non-object value")
        self.obj_keys.append(key^)
        self.children.append(value^)

    def push(mut self, var value: JsonValue) raises:
        """Append an element to an Array. Raises if `self` is not an
        Array."""
        if self.kind != JSON_ARRAY:
            raise Error("JsonError: push() on a non-array value")
        self.children.append(value^)

    # =========================================================================
    # serialize(): compact JSON text.
    # =========================================================================
    #
    # No whitespace. Strings are escaped by `write_json_string`; a Number
    # writes its text verbatim (an empty text, which only a caller-built
    # value can have, writes `0`). Recursion follows the value (as do
    # `copy()` and destruction), so a caller-built tree must be of
    # reasonable depth; a parsed tree is at most `JSON_MAX_DEPTH` deep.

    def serialize(self) -> String:
        """The value as compact JSON text."""
        var buf = List[UInt8]()
        self.write_to(buf)
        return String(unsafe_from_utf8=Span(buf))

    def write_to(self, mut buf: List[UInt8]):
        """Append the value as compact JSON text to `buf`."""
        if self.kind == JSON_NULL:
            write_json_null(buf)
        elif self.kind == JSON_BOOL:
            write_json_bool(buf, self.bool_val)
        elif self.kind == JSON_NUMBER:
            if self.text.byte_length() == 0:
                buf.append(0x30)  # '0'
            else:
                buf.extend(Span(self.text.as_bytes()))
        elif self.kind == JSON_STRING:
            write_json_string(buf, self.text)
        elif self.kind == JSON_ARRAY:
            buf.append(0x5B)  # '['
            for i in range(len(self.children)):
                if i > 0:
                    buf.append(0x2C)  # ','
                self.children[i].write_to(buf)
            buf.append(0x5D)  # ']'
        else:  # JSON_OBJECT
            buf.append(0x7B)  # '{'
            for i in range(len(self.obj_keys)):
                if i > 0:
                    buf.append(0x2C)  # ','
                write_json_string(buf, self.obj_keys[i])
                buf.append(0x3A)  # ':'
                self.children[i].write_to(buf)
            buf.append(0x7D)  # '}'

    # An explicit destructor breaks the non-co-inductive Deinitable check on
    # this struct's recursive self-reference. Field destructors still run.
    def __deinit__(deinit self):
        pass


# =============================================================================
# Integer text parsers.
# =============================================================================

comptime _INT64_MAX_MAG: UInt64 = 9223372036854775807
comptime _INT64_MIN_MAG: UInt64 = 9223372036854775808
comptime _UINT64_MAX: UInt64 = 18446744073709551615


def _digits_to_u64(s: String, start: Int, limit: UInt64) raises -> UInt64:
    """The decimal digits of `s[start:]` as a UInt64, refusing any
    non-digit and any value above `limit`."""
    var b = s.as_bytes()
    var n = len(b)
    if start >= n:
        raise Error("JsonError: integer text has no digits")
    var acc: UInt64 = 0
    for i in range(start, n):
        var c = b[i]
        if c < 0x30 or c > 0x39:
            raise Error("JsonError: non-digit in integer text")
        var d = UInt64(Int(c) - 0x30)
        if acc > (limit - d) // UInt64(10):
            raise Error("JsonError: integer text out of range")
        acc = acc * UInt64(10) + d
    return acc


def parse_int64_text(s: String) raises -> Int64:
    """Parse `[+-]?[0-9]+` into an Int64, refusing anything else and any
    value outside [Int64.MIN, Int64.MAX]. (A leading `+` and leading zeros
    are accepted here: this parses a number's or a string's text, which the
    JSON parser has already checked where it was a Number.)"""
    var b = s.as_bytes()
    if len(b) == 0:
        raise Error("JsonError: empty integer text")
    if b[0] == 0x2D:  # '-'
        var mag = _digits_to_u64(s, 1, _INT64_MIN_MAG)
        if mag == _INT64_MIN_MAG:
            return Int64(-9223372036854775808)
        return -(mag.cast[DType.int64]())
    var start = 1 if b[0] == 0x2B else 0  # '+'
    return _digits_to_u64(s, start, _INT64_MAX_MAG).cast[DType.int64]()


def parse_uint64_text(s: String) raises -> UInt64:
    """Parse `+?[0-9]+` into a UInt64, refusing anything else (a `-` sign
    included) and any value above UInt64.MAX."""
    var b = s.as_bytes()
    if len(b) == 0:
        raise Error("JsonError: empty unsigned-integer text")
    var start = 1 if b[0] == 0x2B else 0  # '+'
    return _digits_to_u64(s, start, _UINT64_MAX)
