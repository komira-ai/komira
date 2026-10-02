"""A minimal JSON value: `JsonValue`, as komira_json's value.mojo.

Only the API generated AWS code calls. Objects keep their members in
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

    def copy(self) -> Self:
        var out = JsonValue()
        out.kind = self.kind
        out.bool_val = self.bool_val
        out.text = self.text
        out.children = self.children.copy()
        out.keys = self.keys.copy()
        return out^

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
        if self.kind != JSON_NUMBER:
            raise Error("JsonError: not a number")
        return Int64(atol(self.text))

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
    var out = String("\"")
    for b in s.as_bytes():
        if b == UInt8(ord("\"")):
            out += "\\\""
        elif b == UInt8(ord("\\")):
            out += "\\\\"
        elif b == UInt8(ord("\n")):
            out += "\\n"
        elif b == UInt8(ord("\t")):
            out += "\\t"
        elif b == UInt8(ord("\r")):
            out += "\\r"
        else:
            out += chr(Int(b))
    out += "\""
    return out^
