# The dynamic symbol table defines exactly the four exports, and nothing else.
#
# A gate driver of //src/komira_so:libkomira. It has no dependency. The
# exports check proves the four names resolve; this proves no other name is
# defined. On Linux it reads ./libkomira.so as an ELF64 file, walks the
# SHT_DYNSYM section and lists every defined symbol: an `@export` the BUCK
# `exports` list omits, a symbol of a static C dependency, or a linker marker
# (`_init`, `_end`) shows up here unless the version script of `exports_exact`
# made it local. On macOS the dynamic table is not read (the exports list file
# of `exports_exact` is the guard there) and the driver only looks the linker
# markers up with dlsym.

from std.ffi import OwnedDLHandle
from std.pathlib import Path
from std.sys import CompilationTarget

comptime LIB = "./libkomira.dylib" if CompilationTarget.is_macos() else "./libkomira.so"
comptime SHT_DYNSYM = 11


def _u(data: List[UInt8], at: Int, n: Int) raises -> Int:
    """The little-endian unsigned integer of `n` bytes at `at`."""
    if at < 0 or at + n > len(data):
        raise Error("ELF read past the end of the file")
    var v = 0
    for i in range(n):
        v |= Int(data[at + i]) << (8 * i)
    return v


def _cstr(data: List[UInt8], at: Int) raises -> String:
    var out = List[UInt8]()
    var i = at
    while _u(data, i, 1) != 0:
        out.append(data[i])
        i += 1
    return String(unsafe_from_utf8=out)


def _defined_dynsyms(data: List[UInt8]) raises -> List[String]:
    if len(data) < 64 or _u(data, 0, 4) != 0x464C457F or _u(data, 4, 1) != 2:
        raise Error("not an ELF64 file")
    var shoff = _u(data, 0x28, 8)
    var shentsize = _u(data, 0x3A, 2)
    var shnum = _u(data, 0x3C, 2)
    var names = List[String]()
    var found = False
    for s in range(shnum):
        var sh = shoff + s * shentsize
        if _u(data, sh + 4, 4) != SHT_DYNSYM:
            continue
        found = True
        var off = _u(data, sh + 0x18, 8)
        var size = _u(data, sh + 0x20, 8)
        var strsh = shoff + _u(data, sh + 0x28, 4) * shentsize
        var stroff = _u(data, strsh + 0x18, 8)
        var count = size // 24
        for i in range(count):
            var sym = off + i * 24
            var name_at = _u(data, sym, 4)
            # Index 0 is the null symbol; shndx 0 is an import, not a definition.
            if name_at == 0 or _u(data, sym + 6, 2) == 0:
                continue
            names.append(_cstr(data, stroff + name_at))
    if not found:
        raise Error("the library has no dynamic symbol table")
    return names^


def _is_export(name: String) -> Bool:
    return (
        name == "komira_abi_version"
        or name == "komira_ctx_new"
        or name == "komira_ctx_free"
        or name == "komira_last_error"
    )


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var extra = 0

    comptime if CompilationTarget.is_macos():
        # The linker markers a link without an exports list would leave visible.
        for name in ["_init", "_fini", "_edata", "_end", "__bss_start"]:
            if lib.check_symbol(name):
                print("UNEXPECTED EXPORT: " + String(name))
                extra += 1
    else:
        var names = _defined_dynsyms(Path(LIB).read_bytes())
        var seen = 0
        for name in names:
            if _is_export(name):
                seen += 1
            else:
                print("UNEXPECTED EXPORT: " + name)
                extra += 1
        if seen != 4:
            raise Error("expected 4 defined exports, the symbol table has " + String(seen))
    if extra != 0:
        raise Error(String(extra) + " symbol(s) outside the four exports are defined")
    print("ok")
