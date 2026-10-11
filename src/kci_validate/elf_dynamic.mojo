# =============================================================================
# src/kci_validate/elf_dynamic.mojo -- the dynamic section of an installed
#   shared library, read from its bytes: NEEDED, SONAME, RUNPATH/RPATH and
#   the flags.
# =============================================================================
#
# `read_dynamic(bytes, what)` reads a 64-bit little-endian ELF file's one
# SHT_DYNAMIC section and the string table it links (sh_link), as
# tools/build/package/pack/conda_lib.zig `needed` does on the packer side, so
# the two read the same entries:
#
#   DT_NEEDED (1)    each name, in order          -> `needed`
#   DT_SONAME (14)   the name                     -> `soname`
#   DT_RPATH (15)    each `:`-separated entry     -> `rpath`
#   DT_SYMBOLIC (16) present                      -> `symbolic_tag`
#   DT_RUNPATH (29)  each `:`-separated entry     -> `runpath`
#   DT_FLAGS (30)    the value                    -> `flags`
#
# `has_df_symbolic()` is DF_SYMBOLIC (0x2) in DT_FLAGS or a DT_SYMBOLIC tag:
# what `-Bsymbolic` leaves (the build's check 6).
#
# REFUSED (raises naming `what`): not a 64-bit little-endian ELF file;
# section header entries that are not 64 bytes; no dynamic section, or two;
# the dynamic section linking no section; any header, table or name outside
# the file or its string table; a name with no terminating NUL. Every offset
# is checked against the length before it is read: a truncated or hostile
# file is a refusal, never a crash.
#
# Pure: bytes in, values out. Encapsulation: owned values; no pointer, no
# wildcard origin.
# =============================================================================

comptime DT_NULL: Int = 0
comptime DT_NEEDED: Int = 1
comptime DT_SONAME: Int = 14
comptime DT_RPATH: Int = 15
comptime DT_SYMBOLIC: Int = 16
comptime DT_RUNPATH: Int = 29
comptime DT_FLAGS: Int = 30
comptime DF_SYMBOLIC: Int = 0x2
comptime SHT_DYNAMIC: Int = 6


struct ElfDynamic(Copyable, Movable):
    """What an ELF shared object's dynamic section says (file header).

    Layout: owned Strings, Lists and Ints. No pointer field."""

    var needed: List[String]
    var soname: String
    var rpath: List[String]
    var runpath: List[String]
    var flags: Int
    var symbolic_tag: Bool

    def __init__(out self):
        self.needed = List[String]()
        self.soname = String("")
        self.rpath = List[String]()
        self.runpath = List[String]()
        self.flags = 0
        self.symbolic_tag = False

    def has_df_symbolic(self) -> Bool:
        return (self.flags & DF_SYMBOLIC) != 0 or self.symbolic_tag


def _rd(b: List[UInt8], off: Int, n: Int, what: String) raises -> Int:
    """The `n`-byte little-endian unsigned value at `off` (n <= 8; a value
    above Int's range is refused as out of the file anyway)."""
    if off < 0 or n > len(b) or off > len(b) - n:
        raise Error(what + String(": ELF: a header or table points past the end of the file"))
    var v = 0
    for i in range(n - 1, -1, -1):
        v = (v << 8) | Int(b[off + i])
    if n == 8 and Int(b[off + 7]) >= 0x80:
        raise Error(what + String(": ELF: an offset or size is out of range"))
    return v


def _name(strtab_off: Int, strtab_size: Int, b: List[UInt8], at: Int, what: String) raises -> String:
    if at < 0 or at >= strtab_size:
        raise Error(what + String(": ELF: a name points outside the dynamic string table"))
    var out = String("")
    var i = strtab_off + at
    var end = strtab_off + strtab_size
    while i < end:
        var c = Int(b[i])
        if c == 0:
            return out^
        out += chr(c)
        i += 1
    raise Error(what + String(": ELF: a name has no terminating NUL"))


def _split_path(s: String) -> List[String]:
    var out = List[String]()
    var parts = s.split(String(":"))
    for i in range(len(parts)):
        out.append(String(parts[i]))
    return out^


def read_dynamic(b: List[UInt8], what: String) raises -> ElfDynamic:
    """The dynamic section of the ELF bytes `b` (file header); `what` names
    the file in refusals."""
    if (
        len(b) < 64 or Int(b[0]) != 0x7F or Int(b[1]) != 0x45 or Int(b[2]) != 0x4C or Int(b[3]) != 0x46
        or Int(b[4]) != 2 or Int(b[5]) != 1
    ):
        raise Error(what + String(": not a 64-bit little-endian ELF file"))
    var shoff = _rd(b, 0x28, 8, what)
    var shentsize = _rd(b, 0x3A, 2, what)
    var shnum = _rd(b, 0x3C, 2, what)
    if shentsize != 64:
        raise Error(what + String(": ELF: section header entries are not 64 bytes"))
    var d = ElfDynamic()
    var seen = False
    for i in range(shnum):
        var sh = shoff + i * 64
        if _rd(b, sh + 4, 4, what) != SHT_DYNAMIC:
            continue
        if seen:
            raise Error(what + String(": ELF: two dynamic sections"))
        seen = True
        var off = _rd(b, sh + 0x18, 8, what)
        var size = _rd(b, sh + 0x20, 8, what)
        var link = _rd(b, sh + 0x28, 4, what)
        if link >= shnum:
            raise Error(what + String(": ELF: the dynamic section links no section"))
        var str_sh = shoff + link * 64
        var str_off = _rd(b, str_sh + 0x18, 8, what)
        var str_size = _rd(b, str_sh + 0x20, 8, what)
        if str_off > len(b) or len(b) - str_off < str_size:
            raise Error(what + String(": ELF: the dynamic string table points past the end of the file"))
        var at = 0
        while at + 16 <= size:
            var tag = _rd(b, off + at, 8, what)
            var val = _rd(b, off + at + 8, 8, what)
            at += 16
            if tag == DT_NULL:
                break
            if tag == DT_NEEDED:
                d.needed.append(_name(str_off, str_size, b, val, what))
            elif tag == DT_SONAME:
                d.soname = _name(str_off, str_size, b, val, what)
            elif tag == DT_RPATH:
                d.rpath.extend(_split_path(_name(str_off, str_size, b, val, what)))
            elif tag == DT_RUNPATH:
                d.runpath.extend(_split_path(_name(str_off, str_size, b, val, what)))
            elif tag == DT_SYMBOLIC:
                d.symbolic_tag = True
            elif tag == DT_FLAGS:
                d.flags = val
    if not seen:
        raise Error(what + String(": ELF: no dynamic section (not a shared object)"))
    return d^
