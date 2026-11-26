from std.ffi import OwnedDLHandle
from std.sys import CompilationTarget

comptime MACOS = CompilationTarget.is_macos()
comptime LIB = "./spike_native.dylib" if MACOS else "./spike_native.so"
comptime OWNER = "libkomira_libc_native.1.dylib" if MACOS else "libkomira_libc_native.so.1"
# The name ld64 records for the owner (its install name, which the library's
# load command copies): tools/build/native/shared.bzl, `shared_names`.
comptime OWNER_INSTALL_NAME = "@rpath/libkomira_libc_native.1.dylib"

# Mach-O (mach-o/loader.h, mach-o/nlist.h).
comptime MH_MAGIC_64 = 0xFEEDFACF
comptime LC_SYMTAB = 0x2
comptime LC_LOAD_DYLIB = 0xC
comptime LC_LOAD_WEAK_DYLIB = 0x80000018
comptime LC_REEXPORT_DYLIB = 0x8000001F
comptime LC_LAZY_LOAD_DYLIB = 0x20
comptime LC_LOAD_UPWARD_DYLIB = 0x80000023
comptime LC_CODE_SIGNATURE = 0x1D
comptime N_STAB = 0xE0
comptime N_TYPE = 0x0E
comptime N_EXT = 0x01


def le(data: List[UInt8], at: Int, n: Int) -> Int:
    var v = 0
    for i in range(n):
        v |= Int(data[at + i]) << (8 * i)
    return v


def c_string(data: List[UInt8], at: Int) raises -> String:
    var end = at
    while data[end] != 0:
        end += 1
    return String(from_utf8=Span(data)[at:end])


def undefined_dynamic_symbols(path: String) raises -> List[String]:
    """The names the library's dynamic symbol table leaves undefined (ELF64,
    little endian): what its loader binds at load time."""
    var data = open(path, "r").read_bytes()
    var shoff = le(data, 0x28, 8)
    var shentsize = le(data, 0x3A, 2)
    var shnum = le(data, 0x3C, 2)
    var names = List[String]()
    for i in range(shnum):
        var sh = shoff + i * shentsize
        if le(data, sh + 4, 4) != 11:  # SHT_DYNSYM
            continue
        var offset = le(data, sh + 0x18, 8)
        var size = le(data, sh + 0x20, 8)
        var strtab = shoff + le(data, sh + 0x28, 4) * shentsize
        var str_offset = le(data, strtab + 0x18, 8)
        for s in range(size // 24):
            var sym = offset + s * 24
            if le(data, sym + 6, 2) == 0:  # SHN_UNDEF
                names.append(c_string(data, str_offset + le(data, sym, 4)))
    return names^


def macho_names_bound_to(path: String, install_name: String) raises -> List[String]:
    """The undefined external names (C names, without the `_` Mach-O
    prepends) that a thin 64-bit Mach-O library binds to the library it loads
    by `install_name`: each symbol's two-level library ordinal (the high byte
    of `n_desc`) counts the library's dylib load commands from 1. Raises when
    the file is not a 64-bit Mach-O, has no load command naming
    `install_name`, or carries no code signature (an arm64 dylib without one
    does not load)."""
    var data = open(path, "r").read_bytes()
    if le(data, 0, 4) != MH_MAGIC_64:
        raise Error(path + " is not a 64-bit Mach-O file")
    var ncmds = le(data, 16, 4)
    var at = 32  # sizeof(mach_header_64)
    var ordinal = 0
    var owner_ordinal = 0
    var signed = False
    var symoff = 0
    var nsyms = 0
    var stroff = 0
    for _ in range(ncmds):
        var cmd = le(data, at, 4)
        if (
            cmd == LC_LOAD_DYLIB
            or cmd == LC_LOAD_WEAK_DYLIB
            or cmd == LC_REEXPORT_DYLIB
            or cmd == LC_LAZY_LOAD_DYLIB
            or cmd == LC_LOAD_UPWARD_DYLIB
        ):
            ordinal += 1
            if c_string(data, at + le(data, at + 8, 4)) == install_name:
                owner_ordinal = ordinal
        elif cmd == LC_SYMTAB:
            symoff = le(data, at + 8, 4)
            nsyms = le(data, at + 12, 4)
            stroff = le(data, at + 16, 4)
        elif cmd == LC_CODE_SIGNATURE:
            signed = True
        at += le(data, at + 4, 4)
    if owner_ordinal == 0:
        raise Error(path + " has no load command for " + install_name + ": it is not linked to the owner")
    if not signed:
        raise Error(path + " has no LC_CODE_SIGNATURE")
    var names = List[String]()
    for s in range(nsyms):
        var sym = symoff + s * 16  # sizeof(nlist_64)
        var n_type = Int(data[sym + 4])
        if n_type & N_STAB != 0 or n_type & N_TYPE != 0 or n_type & N_EXT == 0:
            continue
        if (le(data, sym + 6, 2) >> 8) & 0xFF != owner_ordinal:
            continue
        var name = stroff + le(data, sym, 4)
        if data[name] == UInt8(ord("_")):
            names.append(c_string(data, name + 1))
    return names^


def main() raises:
    var lib = OwnedDLHandle(LIB)
    var got = lib.call["native_owner_write_probe", Int64](Int32(100))
    if got != 100:
        raise Error("native_owner_write_probe(100) is " + String(got) + ", not 100")
    # The owner's C is bound to the owner, not embedded. ELF: the library's
    # own dynamic symbol table leaves each name undefined. Mach-O: each name
    # is undefined and its two-level binding names the owner's install name.
    # Read before the owner is opened by name below, so a library that embeds
    # the C fails here (tests//negative/shared_lib:owner_embedded_bound).
    var bound: List[String]
    comptime if MACOS:
        bound = macho_names_bound_to(LIB, OWNER_INSTALL_NAME)
    else:
        bound = undefined_dynamic_symbols(LIB)
    var owned_symbols = ["komira_openat_creat", "komira_write_bytes", "komira_lseek_end"]
    for symbol in owned_symbols:
        var found = False
        for name in bound:
            if name == symbol:
                found = True
        if not found:
            raise Error(symbol + " is not bound to the owner's shared library: the owner's C is embedded")
    # The library is NEEDED on the owner's shared library, which the gate
    # staged in lib/: opening it by its SONAME (on macOS its file name) finds
    # that copy, the one the loader mapped for the edge.
    var owner = OwnedDLHandle(OWNER)
    if not owner.check_symbol("komira_openat_creat"):
        raise Error(OWNER + " does not define komira_openat_creat")
    # Keep the library open until here.
    if not lib.check_symbol("native_owner_write_probe"):
        raise Error("native_owner_write_probe is not exported")
    print("ok")
