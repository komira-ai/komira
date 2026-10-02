"""A minimal JSON value and parser: the API generated AWS code calls.

Objects keep their members in insertion order; numbers keep their source
text; strings support the `\\"`, `\\\\`, `\\/`, `\\n`, `\\t` and `\\r` escapes
(no `\\u`, which the fixture's bodies do not use, and which is refused
rather than mis-read). `serialize()` writes compact JSON.
"""

comptime _NULL = 0
comptime _BOOL = 1
comptime _NUMBER = 2
comptime _STRING = 3
comptime _ARRAY = 4
comptime _OBJECT = 5


struct JsonValue(Copyable, Movable):
    var kind: Int
    var bool_val: Bool
    var text: String
    var children: List[JsonValue]
    var keys: List[String]

    def __init__(out self):
        self.kind = _NULL
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
        v.kind = _OBJECT
        return v^

    @staticmethod
    def empty_array() -> JsonValue:
        var v = JsonValue()
        v.kind = _ARRAY
        return v^

    @staticmethod
    def from_bool(b: Bool) -> JsonValue:
        var v = JsonValue()
        v.kind = _BOOL
        v.bool_val = b
        return v^

    @staticmethod
    def from_i64(n: Int64) -> JsonValue:
        var v = JsonValue()
        v.kind = _NUMBER
        v.text = String(n)
        return v^

    @staticmethod
    def from_f64(x: Float64) -> JsonValue:
        var v = JsonValue()
        v.kind = _NUMBER
        v.text = String(x)
        return v^

    @staticmethod
    def from_string(var s: String) -> JsonValue:
        var v = JsonValue()
        v.kind = _STRING
        v.text = s^
        return v^

    def is_null(self) -> Bool:
        return self.kind == _NULL

    def as_bool(self) raises -> Bool:
        if self.kind != _BOOL:
            raise Error("json_value: not a boolean")
        return self.bool_val

    def as_string(self) raises -> String:
        if self.kind != _STRING:
            raise Error("json_value: not a string")
        return self.text

    def as_int64(self) raises -> Int64:
        if self.kind != _NUMBER:
            raise Error("json_value: not a number")
        return Int64(atol(self.text))

    def has(self, key: String) -> Bool:
        if self.kind != _OBJECT:
            return False
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return True
        return False

    def get(self, key: String) raises -> JsonValue:
        if self.kind != _OBJECT:
            raise Error("json_value: get() on a non-object")
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return self.children[i].copy()
        raise Error(String("json_value: no member ") + key)

    def array_len(self) -> Int:
        if self.kind != _ARRAY:
            return 0
        return len(self.children)

    def element_at(self, i: Int) raises -> JsonValue:
        if self.kind != _ARRAY or i < 0 or i >= len(self.children):
            raise Error("json_value: element_at() out of range")
        return self.children[i].copy()

    def set_member(mut self, var key: String, var value: JsonValue) raises:
        if self.kind != _OBJECT:
            raise Error("json_value: set_member() on a non-object")
        self.keys.append(key^)
        self.children.append(value^)

    def push(mut self, var value: JsonValue) raises:
        if self.kind != _ARRAY:
            raise Error("json_value: push() on a non-array")
        self.children.append(value^)

    def serialize(self) -> String:
        if self.kind == _NULL:
            return String("null")
        if self.kind == _BOOL:
            return String("true") if self.bool_val else String("false")
        if self.kind == _NUMBER:
            return self.text
        if self.kind == _STRING:
            return _quote(self.text)
        var out = String("[") if self.kind == _ARRAY else String("{")
        for i in range(len(self.children)):
            if i > 0:
                out += ","
            if self.kind == _OBJECT:
                out += _quote(self.keys[i]) + ":"
            out += self.children[i].serialize()
        out += "]" if self.kind == _ARRAY else "}"
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


struct _Parser(Movable):
    var b: List[UInt8]
    var pos: Int

    def __init__(out self, s: String):
        self.b = List[UInt8]()
        for c in s.as_bytes():
            self.b.append(c)
        self.pos = 0

    def ws(mut self):
        while self.pos < len(self.b) and (
            self.b[self.pos] == UInt8(ord(" "))
            or self.b[self.pos] == UInt8(ord("\n"))
            or self.b[self.pos] == UInt8(ord("\t"))
            or self.b[self.pos] == UInt8(ord("\r"))
        ):
            self.pos += 1

    def peek(self) raises -> UInt8:
        if self.pos >= len(self.b):
            raise Error("json_value: unexpected end of input")
        return self.b[self.pos]

    def expect(mut self, c: StaticString) raises:
        if self.peek() != UInt8(ord(c)):
            raise Error(String("json_value: expected ") + c + " at byte " + String(self.pos))
        self.pos += 1

    def literal(mut self, word: StaticString) raises:
        for c in word.as_bytes():
            if self.peek() != c:
                raise Error(String("json_value: bad literal at byte ") + String(self.pos))
            self.pos += 1

    def string(mut self) raises -> String:
        self.expect("\"")
        var out = String("")
        while True:
            var c = self.peek()
            self.pos += 1
            if c == UInt8(ord("\"")):
                return out^
            if c == UInt8(ord("\\")):
                var e = self.peek()
                self.pos += 1
                if e == UInt8(ord("\"")) or e == UInt8(ord("\\")) or e == UInt8(ord("/")):
                    out += chr(Int(e))
                elif e == UInt8(ord("n")):
                    out += "\n"
                elif e == UInt8(ord("t")):
                    out += "\t"
                elif e == UInt8(ord("r")):
                    out += "\r"
                else:
                    raise Error("json_value: unsupported escape (this stub has no \\u)")
            else:
                out += chr(Int(c))

    def value(mut self) raises -> JsonValue:
        self.ws()
        var c = self.peek()
        if c == UInt8(ord("{")):
            self.pos += 1
            var obj = JsonValue.empty_object()
            self.ws()
            if self.peek() == UInt8(ord("}")):
                self.pos += 1
                return obj^
            while True:
                self.ws()
                var key = self.string()
                self.ws()
                self.expect(":")
                obj.set_member(key^, self.value())
                self.ws()
                if self.peek() == UInt8(ord(",")):
                    self.pos += 1
                    continue
                self.expect("}")
                return obj^
        if c == UInt8(ord("[")):
            self.pos += 1
            var arr = JsonValue.empty_array()
            self.ws()
            if self.peek() == UInt8(ord("]")):
                self.pos += 1
                return arr^
            while True:
                arr.push(self.value())
                self.ws()
                if self.peek() == UInt8(ord(",")):
                    self.pos += 1
                    continue
                self.expect("]")
                return arr^
        if c == UInt8(ord("\"")):
            return JsonValue.from_string(self.string())
        if c == UInt8(ord("t")):
            self.literal("true")
            return JsonValue.from_bool(True)
        if c == UInt8(ord("f")):
            self.literal("false")
            return JsonValue.from_bool(False)
        if c == UInt8(ord("n")):
            self.literal("null")
            return JsonValue()
        var start = self.pos
        while self.pos < len(self.b) and (
            (self.b[self.pos] >= UInt8(ord("0")) and self.b[self.pos] <= UInt8(ord("9")))
            or self.b[self.pos] == UInt8(ord("-"))
            or self.b[self.pos] == UInt8(ord("."))
        ):
            self.pos += 1
        if self.pos == start:
            raise Error(String("json_value: unexpected byte at ") + String(start))
        var num = JsonValue()
        num.kind = _NUMBER
        var text = String("")
        for i in range(start, self.pos):
            text += chr(Int(self.b[i]))
        num.text = text^
        return num^


def parse_json_value(s: String) raises -> JsonValue:
    """One JSON value, surrounded only by whitespace; anything else raises."""
    var p = _Parser(s)
    var v = p.value()
    p.ws()
    if p.pos != len(p.b):
        raise Error(String("json_value: trailing bytes at ") + String(p.pos))
    return v^
