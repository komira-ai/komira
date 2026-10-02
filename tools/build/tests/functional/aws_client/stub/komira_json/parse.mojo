"""A minimal JSON parser: `parse_json_value`, as komira_json's parse.mojo.

Strings support the `\\"`, `\\\\`, `\\/`, `\\n`, `\\t` and `\\r` escapes (no
`\\u`, which the fixture's bodies do not use, and which is refused rather
than mis-read); numbers keep their source text.
"""

from .value import JSON_NUMBER, JsonValue


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
                    raise Error("JsonError: unsupported escape (this stub has no \\u)")
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
            raise Error(String("JsonError: unexpected byte at ") + String(start))
        var num = JsonValue()
        num.kind = JSON_NUMBER
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
        raise Error(String("JsonError: trailing bytes at ") + String(p.pos))
    return v^
