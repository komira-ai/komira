"""Load commands of a thin 64-bit little-endian Mach-O file."""

from buildtools.bytes import slice_string


def _u32(b: List[UInt8], off: Int) raises -> Int:
    if off + 4 > len(b):
        raise Error("truncated Mach-O file")
    return Int(b[off]) | (Int(b[off + 1]) << 8) | (Int(b[off + 2]) << 16) | (Int(b[off + 3]) << 24)


def _hex(v: Int) -> String:
    var digits = String("0123456789abcdef")
    var out = String()
    var x = v
    if x == 0:
        return String("0x0")
    while x > 0:
        out = String(digits[byte = x % 16 : x % 16 + 1]) + out
        x = x // 16
    return "0x" + out


def macho_listing(b: List[UInt8]) raises -> String:
    """`header <cputype> <filetype>`, then one line per load command read:
    `load|id|rpath <name>` and `minos <major>.<minor>.<patch>`."""
    if len(b) < 32 or _u32(b, 0) != 0xFEEDFACF:
        raise Error("not a 64-bit little-endian Mach-O file")
    var cputype = _u32(b, 4)
    var filetype = _u32(b, 12)
    var ncmds = _u32(b, 16)
    var out = "header\t" + _hex(cputype) + "\t" + String(filetype) + "\n"
    var off = 32
    for _ in range(ncmds):
        var cmd = _u32(b, off)
        var size = _u32(b, off + 4)
        if size < 8 or off + size > len(b):
            raise Error("bad load command size at byte " + String(off))
        var kind = String("")
        if cmd == 0xC or cmd == 0x80000018 or cmd == 0x8000001F:
            kind = "load"
        elif cmd == 0xD:
            kind = "id"
        elif cmd == 0x8000001C:
            kind = "rpath"
        if kind.byte_length() > 0:
            var name_off = off + _u32(b, off + 8)
            var end = name_off
            while end < off + size and Int(b[end]) != 0:
                end += 1
            out += kind + "\t" + slice_string(b, name_off, end) + "\n"
        elif cmd == 0x32:
            var v = _u32(b, off + 12)
            out += "minos\t" + String(v >> 16) + "." + String((v >> 8) & 0xFF) + "." + String(v & 0xFF) + "\n"
        off += size
    return out^
