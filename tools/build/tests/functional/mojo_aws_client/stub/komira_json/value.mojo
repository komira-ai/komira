"""A minimal JSON value: `JsonValue`, as komira_json's value.mojo.

The subset of komira_json's `JsonValue` API that generated AWS code calls,
with the same names and signatures. Objects keep their members in
insertion order; numbers keep their source text. `serialize()` writes
compact JSON.
"""

comptime JSON_NULL: Int = 0
comptime JSON_BOOL: Int = 1
comptime JSON_NUMBER: Int = 2
comptime JSON_STRING: Int = 3
comptime JSON_ARRAY: Int = 4
comptime JSON_OBJECT: Int = 5


struct JsonValue(Copyable, Movable):
    var kind: Int
    var bool_val: Bool
    var text: String
    var children: List[JsonValue]
    var keys: List[String]

    def __init__(out self):
        self.kind = JSON_NULL
        self.bool_val = False
        self.text = String("")
        self.children = List[JsonValue]()
        self.keys = List[String]()

    # An explicit destructor: Mojo 1.0's synthesised Deinitable check is not
    # co-inductive, so a struct holding a List of itself cannot prove itself.
    def __deinit__(deinit self):
        pass

    # An explicit deep copy constructor, as komira_json's: a defensive pin so
    # it can never become trivial. A synthesized one can be treated as
    # trivial by Mojo 1.0.0 for some layouts of a struct with an explicit
    # `__deinit__`, and `List.copy()` would then share the elements' heap
    # buffers with the originals. This layout does not trigger that;
    # test_logs_get_log_events.mojo asserts it at compile time.
    def __init__(out self, *, copy: Self):
        self.kind = copy.kind
        self.bool_val = copy.bool_val
        self.text = copy.text.copy()
        self.children = copy.children.copy()
        self.keys = copy.keys.copy()

    def copy(self) -> Self:
        return Self(copy=self)

    @staticmethod
    def empty_object() -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_OBJECT
        return v^

    @staticmethod
    def empty_array() -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_ARRAY
        return v^

    @staticmethod
    def from_bool(b: Bool) -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_BOOL
        v.bool_val = b
        return v^

    @staticmethod
    def from_i64(n: Int64) -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_NUMBER
        v.text = String(n)
        return v^

    @staticmethod
    def from_f64(x: Float64) -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_NUMBER
        v.text = String(x)
        return v^

    @staticmethod
    def from_string(var s: String) -> JsonValue:
        var v = JsonValue()
        v.kind = JSON_STRING
        v.text = s^
        return v^

    def is_null(self) -> Bool:
        return self.kind == JSON_NULL

    def as_bool(self) raises -> Bool:
        if self.kind != JSON_BOOL:
            raise Error("JsonError: not a boolean")
        return self.bool_val

    def as_string(self) raises -> String:
        if self.kind != JSON_STRING:
            raise Error("JsonError: not a string")
        return self.text

    def as_int64(self) raises -> Int64:
        """A Number or a String holding `[+-]?[0-9]+`; `1.0` is refused."""
        if self.kind != JSON_NUMBER and self.kind != JSON_STRING:
            raise Error("JsonError: not numeric")
        return parse_int64_text(self.text)

    def as_uint64(self) raises -> UInt64:
        """A Number or a String holding `+?[0-9]+`."""
        if self.kind != JSON_NUMBER and self.kind != JSON_STRING:
            raise Error("JsonError: not numeric")
        return parse_uint64_text(self.text)

    def has(self, key: String) -> Bool:
        if self.kind != JSON_OBJECT:
            return False
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return True
        return False

    def get(self, key: String) raises -> JsonValue:
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: get() on a non-object")
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return self.children[i].copy()
        raise Error(String("JsonError: no member ") + key)

    def num_members(self) -> Int:
        if self.kind != JSON_OBJECT:
            return 0
        return len(self.keys)

    def key_at(self, i: Int) raises -> String:
        if self.kind != JSON_OBJECT or i < 0 or i >= len(self.keys):
            raise Error("JsonError: key_at() out of range")
        return self.keys[i]

    def value_at(self, i: Int) raises -> JsonValue:
        if self.kind != JSON_OBJECT or i < 0 or i >= len(self.children):
            raise Error("JsonError: value_at() out of range")
        return self.children[i].copy()

    def array_len(self) -> Int:
        if self.kind != JSON_ARRAY:
            return 0
        return len(self.children)

    def element_at(self, i: Int) raises -> JsonValue:
        if self.kind != JSON_ARRAY or i < 0 or i >= len(self.children):
            raise Error("JsonError: element_at() out of range")
        return self.children[i].copy()

    def set_member(mut self, var key: String, var value: JsonValue) raises:
        if self.kind != JSON_OBJECT:
            raise Error("JsonError: set_member() on a non-object")
        self.keys.append(key^)
        self.children.append(value^)

    def push(mut self, var value: JsonValue) raises:
        if self.kind != JSON_ARRAY:
            raise Error("JsonError: push() on a non-array")
        self.children.append(value^)

    def serialize(self) -> String:
        if self.kind == JSON_NULL:
            return String("null")
        if self.kind == JSON_BOOL:
            return String("true") if self.bool_val else String("false")
        if self.kind == JSON_NUMBER:
            return self.text
        if self.kind == JSON_STRING:
            return _quote(self.text)
        var out = String("[") if self.kind == JSON_ARRAY else String("{")
        for i in range(len(self.children)):
            if i > 0:
                out += ","
            if self.kind == JSON_OBJECT:
                out += _quote(self.keys[i]) + ":"
            out += self.children[i].serialize()
        out += "]" if self.kind == JSON_ARRAY else "}"
        return out^


def _quote(s: String) -> String:
    """`s` as a JSON string. Bytes are copied through unchanged, so UTF-8
    stays UTF-8; `"`, `\\` and every control byte below 0x20 are escaped."""
    comptime HEX = "0123456789abcdef"
    var out = List[UInt8]()
    out.append(UInt8(ord("\"")))
    for b in s.as_bytes():
        if b == UInt8(ord("\"")) or b == UInt8(ord("\\")):
            out.append(UInt8(ord("\\")))
            out.append(b)
        elif b == UInt8(ord("\n")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("n")))
        elif b == UInt8(ord("\t")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("t")))
        elif b == UInt8(ord("\r")):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("r")))
        elif b < 0x20:
            for c in String("\\u00").as_bytes():
                out.append(c)
            out.append(HEX.as_bytes()[Int(b >> 4)])
            out.append(HEX.as_bytes()[Int(b & 0x0F)])
        else:
            out.append(b)
    out.append(UInt8(ord("\"")))
    return String(unsafe_from_utf8=Span(out))


def _digits_to_u64(s: String, start: Int, limit: UInt64) raises -> UInt64:
    var b = s.as_bytes()
    if start >= len(b):
        raise Error("JsonError: integer text has no digits")
    var acc: UInt64 = 0
    for i in range(start, len(b)):
        var c = b[i]
        if c < 0x30 or c > 0x39:
            raise Error("JsonError: non-digit in integer text")
        var d = UInt64(Int(c) - 0x30)
        if acc > (limit - d) // UInt64(10):
            raise Error("JsonError: integer text out of range")
        acc = acc * UInt64(10) + d
    return acc


def parse_int64_text(s: String) raises -> Int64:
    """`[+-]?[0-9]+` as an Int64, as komira_json's `parse_int64_text`."""
    var b = s.as_bytes()
    if len(b) == 0:
        raise Error("JsonError: empty integer text")
    if b[0] == 0x2D:  # '-'
        var mag = _digits_to_u64(s, 1, UInt64(9223372036854775808))
        if mag == UInt64(9223372036854775808):
            return Int64(-9223372036854775808)
        return -(mag.cast[DType.int64]())
    var start = 1 if b[0] == 0x2B else 0  # '+'
    return _digits_to_u64(s, start, UInt64(9223372036854775807)).cast[
        DType.int64
    ]()


def parse_uint64_text(s: String) raises -> UInt64:
    """`+?[0-9]+` as a UInt64, as komira_json's `parse_uint64_text`."""
    var b = s.as_bytes()
    if len(b) == 0:
        raise Error("JsonError: empty unsigned-integer text")
    var start = 1 if b[0] == 0x2B else 0  # '+'
    return _digits_to_u64(s, start, UInt64(18446744073709551615))
