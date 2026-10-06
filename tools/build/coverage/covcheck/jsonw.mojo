"""A small JSON writer over komira_json's byte writers (which do the string
escaping): the caller opens containers, names each object member with
`key` and each array element with `item`, and the commas are placed here."""

from komira_json import write_i64_dec, write_json_bool, write_json_null, write_json_string


struct JsonOut(Movable):
    """A JSON document being written; `count` holds, per open container,
    how many members or elements it has so far."""

    var buf: List[UInt8]
    var count: List[Int]

    def __init__(out self):
        self.buf = List[UInt8]()
        self.count = List[Int]()

    def _next(mut self):
        var n = len(self.count)
        if n == 0:
            return
        if self.count[n - 1] > 0:
            self.buf.append(UInt8(44))
        self.count[n - 1] += 1

    def key(mut self, k: String):
        """The next member of the open object; its value follows."""
        self._next()
        write_json_string(self.buf, k)
        self.buf.append(UInt8(58))

    def item(mut self):
        """The next element of the open array; its value follows."""
        self._next()

    def begin_object(mut self):
        self.buf.append(UInt8(123))
        self.count.append(0)

    def end_object(mut self):
        _ = self.count.pop()
        self.buf.append(UInt8(125))

    def begin_array(mut self):
        self.buf.append(UInt8(91))
        self.count.append(0)

    def end_array(mut self):
        _ = self.count.pop()
        self.buf.append(UInt8(93))

    def str_value(mut self, s: String):
        write_json_string(self.buf, s)

    def int_value(mut self, v: Int):
        write_i64_dec(self.buf, Int64(v))

    def null_value(mut self):
        write_json_null(self.buf)

    def bool_value(mut self, b: Bool):
        write_json_bool(self.buf, b)

    def field_str(mut self, k: String, s: String):
        self.key(k)
        self.str_value(s)

    def field_int(mut self, k: String, v: Int):
        self.key(k)
        self.int_value(v)

    def field_opt(mut self, k: String, v: Int):
        """`v`, or null when it is negative (n/a)."""
        self.key(k)
        if v < 0:
            self.null_value()
        else:
            self.int_value(v)

    def text(self) -> String:
        return String(from_utf8_lossy=self.buf)
