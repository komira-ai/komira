"""A minimal JSON parser: `parse_json_value`, as komira_json's parse.mojo.

Strings support the `\\"`, `\\\\`, `\\/`, `\\n`, `\\t` and `\\r` escapes (no
`\\u`, which the fixture's bodies do not use, and which is refused rather
than mis-read); numbers keep their source text. Arrays and objects may
nest at most `max_depth` deep, as in komira_json.
"""

from .value import JSON_NUMBER, JsonValue

comptime JSON_DEFAULT_MAX_DEPTH: Int = 128
"""The nesting limit `parse_json_value` applies by default."""

comptime JSON_MAX_DEPTH: Int = 1000
"""The largest `max_depth` `parse_json_value` accepts."""


struct _Parser(Movable):
    var b: List[UInt8]
    var pos: Int
    var depth: Int
    var max_depth: Int

    def __init__(out self, s: String, max_depth: Int):
        self.b = List[UInt8]()
        for c in s.as_bytes():
            self.b.append(c)
        self.pos = 0
        self.depth = 0
        self.max_depth = max_depth

    def enter_container(mut self) raises:
        self.depth += 1
        if self.depth > self.max_depth:
            raise Error(
                String("JsonError: nesting deeper than ")
                + String(self.max_depth)
            )

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
            raise Error("JsonError: unexpected end of input")
        return self.b[self.pos]

    def expect(mut self, c: StaticString) raises:
        if self.peek() != UInt8(ord(c)):
            raise Error(String("JsonError: expected ") + c + " at byte " + String(self.pos))
        self.pos += 1

    def literal(mut self, word: StaticString) raises:
        for c in word.as_bytes():
            if self.peek() != c:
                raise Error(String("JsonError: bad literal at byte ") + String(self.pos))
            self.pos += 1

    def string(mut self) raises -> String:
        self.expect("\"")
        var out = List[UInt8]()
        while True:
            var c = self.peek()
            self.pos += 1
            if c == UInt8(ord("\"")):
                return String(unsafe_from_utf8=Span(out))
            if c == UInt8(ord("\\")):
                var e = self.peek()
                self.pos += 1
                if e == UInt8(ord("\"")) or e == UInt8(ord("\\")) or e == UInt8(ord("/")):
                    out.append(e)
                elif e == UInt8(ord("n")):
                    out.append(UInt8(ord("\n")))
                elif e == UInt8(ord("t")):
                    out.append(UInt8(ord("\t")))
                elif e == UInt8(ord("r")):
                    out.append(UInt8(ord("\r")))
                else:
                    raise Error("JsonError: unsupported escape (this stub has no \\u)")
            else:
                out.append(c)

    def value(mut self) raises -> JsonValue:
        self.ws()
        var c = self.peek()
        if c == UInt8(ord("{")):
            self.pos += 1
            self.enter_container()
            var obj = JsonValue.empty_object()
            self.ws()
            if self.peek() == UInt8(ord("}")):
                self.pos += 1
                self.depth -= 1
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
                self.depth -= 1
                return obj^
        if c == UInt8(ord("[")):
            self.pos += 1
            self.enter_container()
            var arr = JsonValue.empty_array()
            self.ws()
            if self.peek() == UInt8(ord("]")):
                self.pos += 1
                self.depth -= 1
                return arr^
            while True:
                arr.push(self.value())
                self.ws()
                if self.peek() == UInt8(ord(",")):
                    self.pos += 1
                    continue
                self.expect("]")
                self.depth -= 1
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
            raise Error(String("JsonError: unexpected byte at ") + String(start))
        var num = JsonValue()
        num.kind = JSON_NUMBER
        var text = String("")
        for i in range(start, self.pos):
            text += chr(Int(self.b[i]))
        num.text = text^
        return num^


def parse_json_value(
    s: String, max_depth: Int = JSON_DEFAULT_MAX_DEPTH
) raises -> JsonValue:
    """One JSON value, surrounded only by whitespace; anything else raises,
    as does nesting deeper than `max_depth` or a `max_depth` outside
    [0, `JSON_MAX_DEPTH`]."""
    if max_depth < 0 or max_depth > JSON_MAX_DEPTH:
        raise Error(String("JsonError: max_depth ") + String(max_depth) + " out of range")
    var p = _Parser(s, max_depth)
    var v = p.value()
    p.ws()
    if p.pos != len(p.b):
        raise Error(String("JsonError: trailing bytes at ") + String(p.pos))
    return v^
