"""The members of an uncompressed tar archive.

Reads ustar headers with their `prefix` field, PAX extended headers (local
`x`, and global `g`, which apply to every later member) and GNU long names
(`L`, `K`), the way Python's tarfile does: a directory's name loses its
trailing `/`, a regular-file header whose name ends in `/` is a directory, and
the archive ends at the first all-zero header. A member's data is
[offset, offset + size) of the archive.
"""

from buildtools.bytes import slice_string, substr


struct TarMember(Copyable, Movable):
    var name: String
    var typeflag: Int
    var mode: Int
    var uid: Int
    var gid: Int
    var uname: String
    var gname: String
    var mtime: String
    var size: Int
    var offset: Int
    var linkname: String
    var pax_path: Bool

    def __init__(out self):
        self.name = String("")
        self.typeflag = 48
        self.mode = 0
        self.uid = 0
        self.gid = 0
        self.uname = String("")
        self.gname = String("")
        self.mtime = String("0")
        self.size = 0
        self.offset = 0
        self.linkname = String("")
        self.pax_path = False

    def is_file(self) -> Bool:
        # REGTYPE, AREGTYPE, CONTTYPE, GNU sparse.
        return self.typeflag == 48 or self.typeflag == 0 or self.typeflag == 55 or self.typeflag == 83

    def is_dir(self) -> Bool:
        return self.typeflag == 53


def _field(b: List[UInt8], start: Int, n: Int) -> String:
    """A NUL-terminated string field."""
    var end = start
    while end < start + n and Int(b[end]) != 0:
        end += 1
    return slice_string(b, start, end)


def _number(b: List[UInt8], start: Int, n: Int) raises -> Int:
    """An octal field, or base-256 when the high bit of its first byte is set.

    As tarfile's nti: up to the first NUL, spaces stripped, empty is 0.
    """
    if Int(b[start]) & 0x80 != 0:
        var v = Int(b[start]) & 0x7F
        if v & 0x40 != 0:
            raise Error("tar: negative base-256 number")
        for i in range(start + 1, start + n):
            v = (v << 8) | Int(b[i])
        return v
    var end = start
    while end < start + n and Int(b[end]) != 0:
        end += 1
    var i = start
    while i < end and Int(b[i]) == 32:
        i += 1
    while end > i and Int(b[end - 1]) == 32:
        end -= 1
    var v = 0
    while i < end:
        var c = Int(b[i])
        if c < 48 or c > 55:
            raise Error("tar: bad octal field at byte " + String(start))
        v = v * 8 + c - 48
        i += 1
    return v


def _is(b: List[UInt8], pos: Int, lit: String) -> Bool:
    var l = lit.as_bytes()
    for i in range(len(l)):
        if Int(b[pos + i]) != Int(l[i]):
            return False
    return True


struct _Pax(Copyable, Movable):
    var keys: List[String]
    var values: List[String]

    def __init__(out self):
        self.keys = List[String]()
        self.values = List[String]()

    def set(mut self, key: String, value: String):
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.values[i] = value
                return
        self.keys.append(key)
        self.values.append(value)

    def get(self, key: String) -> Int:
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return i
        return -1


def _parse_pax(b: List[UInt8], start: Int, size: Int, mut into: _Pax) raises:
    var i = start
    var end = start + size
    while i < end:
        var sp = i
        while sp < end and Int(b[sp]) != 32:
            sp += 1
        if sp >= end:
            if Int(b[i]) == 0:
                return
            raise Error("tar: bad PAX record")
        var length = 0
        for k in range(i, sp):
            var c = Int(b[k])
            if c < 48 or c > 57:
                raise Error("tar: bad PAX record length")
            length = length * 10 + c - 48
        if length <= 0 or i + length > end:
            raise Error("tar: bad PAX record length")
        var eq = sp + 1
        while eq < i + length and Int(b[eq]) != 61:
            eq += 1
        if eq >= i + length:
            raise Error("tar: PAX record without '='")
        var key = slice_string(b, sp + 1, eq)
        # The record ends in a newline, which is not part of the value.
        var value = slice_string(b, eq + 1, i + length - 1)
        into.set(key, value)
        i += length


def _apply(mut m: TarMember, pax: _Pax) raises:
    for i in range(len(pax.keys)):
        var k = pax.keys[i]
        var v = pax.values[i]
        if k == "path":
            m.name = v
            m.pax_path = True
        elif k == "linkpath":
            m.linkname = v
        elif k == "uname":
            m.uname = v
        elif k == "gname":
            m.gname = v
        elif k == "mtime":
            m.mtime = v
        elif k == "uid":
            m.uid = atol(v)
        elif k == "gid":
            m.gid = atol(v)
        elif k == "size":
            m.size = atol(v)


def _blocks(n: Int) -> Int:
    return (n + 511) // 512 * 512


def read_tar(b: List[UInt8]) raises -> List[TarMember]:
    var out = List[TarMember]()
    var glob = _Pax()
    var local = _Pax()
    var long_name = String("")
    var long_link = String("")
    var has_long_name = False
    var has_long_link = False
    var pos = 0
    var n = len(b)
    while pos + 512 <= n:
        var zero = True
        for i in range(pos, pos + 512):
            if Int(b[i]) != 0:
                zero = False
                break
        if zero:
            return out^
        var t = Int(b[pos + 156])
        var size = _number(b, pos + 124, 12)
        var data = pos + 512
        if data + size > n:
            raise Error("tar: member at byte " + String(pos) + " runs past the end")
        if t == 120:  # x
            _parse_pax(b, data, size, local)
            pos = data + _blocks(size)
            continue
        if t == 103:  # g
            _parse_pax(b, data, size, glob)
            pos = data + _blocks(size)
            continue
        if t == 76:  # L
            long_name = _field(b, data, size)
            has_long_name = True
            pos = data + _blocks(size)
            continue
        if t == 75:  # K
            long_link = _field(b, data, size)
            has_long_link = True
            pos = data + _blocks(size)
            continue
        var m = TarMember()
        m.typeflag = t
        m.name = _field(b, pos, 100)
        m.mode = _number(b, pos + 100, 8)
        m.uid = _number(b, pos + 108, 8)
        m.gid = _number(b, pos + 116, 8)
        m.size = size
        m.mtime = String(_number(b, pos + 136, 12))
        m.linkname = _field(b, pos + 157, 100)
        var posix = _is(b, pos + 257, "ustar") and Int(b[pos + 262]) == 0
        if _is(b, pos + 257, "ustar"):
            m.uname = _field(b, pos + 265, 32)
            m.gname = _field(b, pos + 297, 32)
        if posix and _is(b, pos + 263, "00"):
            var prefix = _field(b, pos + 345, 155)
            if prefix.byte_length() > 0:
                m.name = prefix + "/" + m.name
        if has_long_name:
            m.name = long_name
            has_long_name = False
        if has_long_link:
            m.linkname = long_link
            has_long_link = False
        _apply(m, glob)
        _apply(m, local)
        local = _Pax()
        if data + m.size > n:
            raise Error("tar: " + m.name + " runs past the end of the archive")
        if m.typeflag == 0 and m.name.endswith("/"):
            m.typeflag = 53
        if m.is_dir():
            while m.name.byte_length() > 1 and m.name.endswith("/"):
                m.name = substr(m.name, 0, m.name.byte_length() - 1)
        m.offset = data
        # Only these carry data blocks: regular files, and types tarfile
        # does not know (it skips their size too).
        var known = (
            t == 49 or t == 50 or t == 51 or t == 52 or t == 53 or t == 54
        )
        if m.is_file() or not known:
            pos = data + _blocks(m.size)
        else:
            pos = data
        out.append(m^)
    # Like tarfile, an archive may end without its zero blocks.
    return out^
